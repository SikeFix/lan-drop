import Foundation
import CryptoKit
import Darwin

public enum TransferDirection: String, Sendable { case sending, receiving }
public enum TransferState: String, Sendable { case waiting, transferring, completed, failed }

public struct TransferProgress: Identifiable, Sendable {
    public let id: UUID
    public var filename: String
    public var peerName: String
    public var direction: TransferDirection
    public var detail: String
    public var state: TransferState
    public var fileURL: URL?
    public var totalBytes: Int64
    public var transferredBytes: Int64
    public var bytesPerSecond: Double = 0
    public var fraction: Double {
        if state == .completed { return 1 }
        guard totalBytes > 0 else { return 0 }
        return min(1, Double(transferredBytes) / Double(totalBytes))
    }
}

public enum TransferEvent: Sendable {
    case progress(TransferProgress)
    case peers([Peer])
    case status(String)
    case error(String)
}

/// Coalesce undelivered progress by transfer ID without losing a terminal state.
/// If a consumer remains paused across hundreds of different files, suspend the
/// producer at the fixed limit rather than silently dropping completed/failed.
actor TransferProgressEventQueue {
    private enum Key: Hashable {
        case progress(UUID), peers, status, error(String)
    }
    private struct Item {
        let key: Key
        let event: TransferEvent
    }
    private struct Producer {
        let item: Item
        let continuation: CheckedContinuation<Bool, Never>
    }

    private let capacity = 512
    private var buffer: [Item] = []
    private var producers: [Producer] = []
    private var consumer: CheckedContinuation<TransferEvent?, Never>?
    private var finished = false

    func send(_ event: TransferEvent) async {
        guard !finished else { return }
        if let consumer {
            self.consumer = nil
            consumer.resume(returning: event)
            return
        }
        let item = Item(key: key(event), event: event)
        if let index = buffer.firstIndex(where: { $0.key == item.key }) {
            if preservesTerminal(buffer[index].event, incoming: event) { return }
            buffer[index] = item
            return
        }
        if let index = producers.firstIndex(where: { $0.item.key == item.key }) {
            if preservesTerminal(producers[index].item.event, incoming: event) { return }
            let superseded = producers.remove(at: index)
            superseded.continuation.resume(returning: true)
        }
        if buffer.count < capacity, producers.isEmpty {
            buffer.append(item)
            return
        }
        _ = await withCheckedContinuation { continuation in
            producers.append(Producer(item: item, continuation: continuation))
        }
    }

    func next() async -> TransferEvent? {
        if !buffer.isEmpty {
            let item = buffer.removeFirst()
            while buffer.count < capacity, !producers.isEmpty {
                let producer = producers.removeFirst()
                buffer.append(producer.item)
                producer.continuation.resume(returning: true)
            }
            return item.event
        }
        guard !finished, consumer == nil else { return nil }
        return await withCheckedContinuation { consumer = $0 }
    }

    func finish() {
        finished = true
        buffer.removeAll()
        let pending = producers
        producers.removeAll()
        for producer in pending { producer.continuation.resume(returning: false) }
        consumer?.resume(returning: nil)
        consumer = nil
    }

    private func key(_ event: TransferEvent) -> Key {
        switch event {
        case .progress(let progress): return .progress(progress.id)
        case .peers: return .peers
        case .status: return .status
        case .error(let error): return .error(error)
        }
    }

    private func preservesTerminal(_ previous: TransferEvent, incoming: TransferEvent) -> Bool {
        guard case .progress(let old) = previous, case .progress(let new) = incoming else { return false }
        return (old.state == .completed || old.state == .failed) &&
            (new.state == .waiting || new.state == .transferring)
    }
}

/// The wire format is unchanged: old receivers already acknowledge cumulative
/// bytes after every chunk. A fixed credit window hides LAN round-trip latency.
struct TransferStreamingConfiguration: Sendable {
    let chunkSize: Int
    let inFlightBytes: Int64
    let timeoutNanoseconds: UInt64

    init(chunkSize: Int = 1_048_576, inFlightBytes: Int64 = 8 * 1_048_576,
         timeoutNanoseconds: UInt64 = 60_000_000_000) {
        precondition(chunkSize > 0 && chunkSize <= TransferLimits.maximumChunkSize)
        precondition(inFlightBytes >= chunkSize && inFlightBytes <= 16 * 1_048_576)
        precondition(timeoutNanoseconds > 0)
        self.chunkSize = chunkSize
        self.inFlightBytes = inFlightBytes
        self.timeoutNanoseconds = timeoutNanoseconds
    }

    static let standard = TransferStreamingConfiguration()
    static let legacy = TransferStreamingConfiguration(chunkSize: 256 * 1024, inFlightBytes: 256 * 1024)
}

private struct TransferSpeedMeter {
    private let started = DispatchTime.now().uptimeNanoseconds
    private var sampledAt = DispatchTime.now().uptimeNanoseconds
    private var sampledBytes: Int64 = 0
    private var smoothed: Double = 0

    mutating func record(_ bytes: Int64) -> Double {
        let now = DispatchTime.now().uptimeNanoseconds
        let period = Double(now - sampledAt) / 1_000_000_000
        if period >= 0.25 {
            let measured = Double(max(0, bytes - sampledBytes)) / period
            smoothed = smoothed == 0 ? measured : smoothed * 0.6 + measured * 0.4
            sampledAt = now
            sampledBytes = bytes
        }
        let elapsed = Double(now - started) / 1_000_000_000
        return smoothed > 0 ? smoothed : Double(bytes) / max(elapsed, 0.001)
    }
}

public actor TransferEngine {
    public nonisolated let events: AsyncStream<TransferEvent>
    private let eventQueue: TransferProgressEventQueue
    private let service: LANService
    private let store: IncomingFileStore
    private let streaming: TransferStreamingConfiguration
    private var eventTask: Task<Void, Never>?
    private var sendTask: Task<Void, Never>?
    private var peers: [UUID: Peer] = [:]
    private var records: [UUID: TransferProgress] = [:]
    private var inboundOwners: [UUID: UUID] = [:]
    private var jobs: [Job] = []
    private var preferredPeerID: UUID?
    private var lastProgressUpdate: [UUID: Date] = [:]
    private var replies: [UUID: Reply] = [:]
    private var sendingWindows: [UUID: SendingWindow] = [:]
    private var receivingSpeeds: [UUID: TransferSpeedMeter] = [:]
    private var maximumObservedInFlight: Int64 = 0
    private var started = false
    private var generation: UInt64 = 0

    private struct Job { let id: UUID; let url: URL }
    private enum ReplyKind: Equatable { case ready, complete }
    private struct Reply {
        let operationID: UUID
        let peerID: UUID
        let kind: ReplyKind
        let continuation: CheckedContinuation<Void, Error>
        let timeout: Task<Void, Never>
    }
    /// At most one sender task and one credit waiter exist per file. The window
    /// retains counters, not payloads; TCP and the bounded receive queue hold data.
    private final class SendingWindow {
        let peerID: UUID
        let totalBytes: Int64
        var sent: Int64 = 0
        var acknowledged: Int64 = 0
        var lastAcknowledgment = DispatchTime.now().uptimeNanoseconds
        var failure: Error?
        var waiter: CreditWaiter?
        var watchdog: Task<Void, Never>?
        var speed = TransferSpeedMeter()

        init(peerID: UUID, totalBytes: Int64) {
            self.peerID = peerID
            self.totalBytes = totalBytes
        }
    }
    private struct CreditWaiter {
        let operationID: UUID
        let minimumAcknowledgment: Int64
        let continuation: CheckedContinuation<Void, Error>
    }
    private enum EngineError: LocalizedError {
        case disconnected, timeout, rejected(String), fileChanged, invalidAcknowledgment
        var errorDescription: String? {
            switch self {
            case .disconnected: return "设备连接已断开，文件未发送完成。"
            case .timeout: return "等待另一台 Mac 响应超时。"
            case .rejected(let reason): return reason
            case .fileChanged: return "文件在发送期间发生变化，请完成编辑后重新拖入。"
            case .invalidAcknowledgment: return "接收端返回了无效的传输进度，发送已取消。"
            }
        }
    }

    public init(directory: URL, service: LANService = LANService()) throws {
        try self.init(directory: directory, service: service, streaming: .standard)
    }

    init(directory: URL, service: LANService, streaming: TransferStreamingConfiguration) throws {
        let queue = TransferProgressEventQueue()
        events = AsyncStream(unfolding: { await queue.next() }, onCancel: {
            Task { await queue.finish() }
        })
        eventQueue = queue
        self.service = service
        self.streaming = streaming
        store = try IncomingFileStore(directory: directory)
    }

    public func hasPendingTransfers() -> Bool {
        !jobs.isEmpty || sendTask != nil || !inboundOwners.isEmpty
    }

    func streamingStateForTesting() -> (windows: Int, waiters: Int, maximumInFlight: Int64) {
        (sendingWindows.count, sendingWindows.values.filter { $0.waiter != nil }.count, maximumObservedInFlight)
    }

    public func start(deviceID: UUID, name: String, password: String) async throws {
        if started { await stop() }
        generation &+= 1
        let currentGeneration = generation
        started = true
        let stream = service.events
        eventTask = Task { [weak self] in
            for await event in stream {
                guard !Task.isCancelled else { break }
                await self?.handle(event, generation: currentGeneration)
            }
        }
        do {
            try await service.start(deviceID: deviceID, name: name, password: password)
            await eventQueue.send(.status("正在寻找使用相同密码的 Mac"))
        } catch {
            started = false
            eventTask?.cancel()
            eventTask = nil
            throw error
        }
    }

    public func stop() async {
        started = false
        generation &+= 1
        sendTask?.cancel()
        sendTask = nil
        eventTask?.cancel()
        eventTask = nil
        service.stop()
        for id in Array(replies.keys) { resolve(id, error: EngineError.disconnected) }
        for id in Array(sendingWindows.keys) { failWindow(id, error: EngineError.disconnected) }
        store.cancelAll()
        for (id, _) in inboundOwners { await fail(id, reason: "配对已重置，接收已取消。") }
        inboundOwners.removeAll()
        receivingSpeeds.removeAll()
        for job in jobs { await fail(job.id, reason: "配对已重置，发送已取消。") }
        jobs.removeAll()
        peers.removeAll()
        await eventQueue.send(.peers([]))
    }

    public func selectPeer(_ id: UUID?) {
        preferredPeerID = id
        beginSendingIfPossible()
    }

    public func enqueue(_ urls: [URL]) async {
        guard started else {
            await eventQueue.send(.error("请先设置两台 Mac 共用的配对密码。"))
            return
        }
        guard jobs.count + urls.count <= 200 else {
            await eventQueue.send(.error("一次最多等待发送 200 个文件，请等待当前队列完成。"))
            return
        }
        let currentGeneration = generation
        var publications: [TransferProgress] = []
        // Reserve the whole batch atomically before the first suspension. Another
        // enqueue must see every reserved job when enforcing the200-file limit.
        for url in urls where url.isFileURL {
            let id = UUID()
            let record = TransferProgress(id: id, filename: url.lastPathComponent,
                peerName: "另一台 Mac", direction: .sending,
                detail: peers.isEmpty ? "等待设备连接，连接后自动发送" : "等待发送",
                state: .waiting, fileURL: nil, totalBytes: 0, transferredBytes: 0)
            records[id] = record
            jobs.append(Job(id: id, url: url))
            publications.append(record)
        }
        for record in publications {
            guard started, currentGeneration == generation else { return }
            await eventQueue.send(.progress(record))
        }
        beginSendingIfPossible()
    }

    private var target: Peer? {
        if let preferredPeerID { return peers[preferredPeerID] }
        return peers.values.sorted { $0.id.uuidString < $1.id.uuidString }.first
    }

    private func beginSendingIfPossible() {
        guard started, sendTask == nil, !jobs.isEmpty, target != nil else { return }
        let currentGeneration = generation
        sendTask = Task { [weak self] in await self?.drainQueue(generation: currentGeneration) }
    }

    private func drainQueue(generation currentGeneration: UInt64) async {
        while started, currentGeneration == generation, !Task.isCancelled,
              !jobs.isEmpty, let peer = target {
            let job = jobs.removeFirst()
            do {
                try await sendFile(job, to: peer)
            } catch {
                await fail(job.id, reason: error.localizedDescription)
                try? await sendControl(.cancel(job.id), to: peer.id)
            }
        }
        guard currentGeneration == generation else { return }
        sendTask = nil
        beginSendingIfPossible()
    }

    private func sendFile(_ job: Job, to peer: Peer) async throws {
        try Task.checkCancellation()
        let access = job.url.startAccessingSecurityScopedResource()
        defer { if access { job.url.stopAccessingSecurityScopedResource() } }
        await update(job.id) { $0.detail = "正在准备文件"; $0.peerName = peer.name }
        let prepared = try await FilePreparation.prepare(url: job.url)
        defer { prepared.cleanup() }
        try Task.checkCancellation()
        await update(job.id) {
            $0.filename = prepared.name; $0.totalBytes = prepared.size
            $0.detail = "等待接收端准备"; $0.state = .transferring
        }
        let offer = TransferOffer(id: job.id, name: prepared.name, size: prepared.size)
        try await request(.offer(offer), id: job.id, peerID: peer.id, expecting: .ready)
        let descriptor = Darwin.open(prepared.url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw FileTransferError.unreadableFile }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0,
              metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              Int64(metadata.st_size) == prepared.size else { throw EngineError.fileChanged }
        var hash = SHA256()
        var sent: Int64 = 0
        let window = SendingWindow(peerID: peer.id, totalBytes: prepared.size)
        sendingWindows[job.id] = window
        window.watchdog = Task { [weak self, timeout = streaming.timeoutNanoseconds] in
            var delay = timeout
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: delay) } catch { break }
                guard let next = await self?.checkWindowTimeout(job.id) else { break }
                delay = next
            }
        }
        defer {
            window.watchdog?.cancel()
            sendingWindows.removeValue(forKey: job.id)
        }
        while sent < prepared.size {
            try Task.checkCancellation()
            let nextSize = min(Int64(streaming.chunkSize), prepared.size - sent)
            try await waitForAcknowledgment(job.id, minimum: max(0, sent + nextSize - streaming.inFlightBytes))
            if let failure = window.failure { throw failure }
            guard let chunk = try handle.read(upToCount: Int(nextSize)), !chunk.isEmpty else {
                throw EngineError.fileChanged
            }
            guard sent + Int64(chunk.count) <= prepared.size else { throw EngineError.fileChanged }
            hash.update(data: chunk)
            sent += Int64(chunk.count)
            if window.sent == window.acknowledged { window.lastAcknowledgment = DispatchTime.now().uptimeNanoseconds }
            // Publish issued bytes before the asynchronous send: a receiver may
            // return its ACK before Network.framework calls contentProcessed.
            window.sent = sent
            maximumObservedInFlight = max(maximumObservedInFlight, window.sent - window.acknowledged)
            try await service.send(.chunk(transferID: job.id, data: chunk), to: peer.id)
        }
        guard sent == prepared.size else { throw EngineError.fileChanged }
        try await waitForAcknowledgment(job.id, minimum: sent)
        if let failure = window.failure { throw failure }
        var finalMetadata = stat()
        guard Darwin.fstat(descriptor, &finalMetadata) == 0,
              finalMetadata.st_size == metadata.st_size,
              finalMetadata.st_mtimespec.tv_sec == metadata.st_mtimespec.tv_sec,
              finalMetadata.st_mtimespec.tv_nsec == metadata.st_mtimespec.tv_nsec else {
            throw EngineError.fileChanged
        }
        await update(job.id) { $0.transferredBytes = sent; $0.detail = "接收端正在校验文件" }
        let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
        try await request(.finish(id: job.id, sha256: digest), id: job.id,
                          peerID: peer.id, expecting: .complete)
        await update(job.id) { $0.state = .completed; $0.detail = "已送达 \(peer.name)" }
    }

    private func request(_ message: ControlMessage, id: UUID, peerID: UUID,
                         expecting kind: ReplyKind) async throws {
        let packet = WirePacket.control(try JSONEncoder().encode(message))
        try await requestPacket(packet, id: id, peerID: peerID, expecting: kind)
    }

    private func requestPacket(_ packet: WirePacket, id: UUID, peerID: UUID,
                               expecting kind: ReplyKind) async throws {
        try Task.checkCancellation()
        let operationID = UUID()
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (reply: CheckedContinuation<Void, Error>) in
                let timeout = Task { [weak self, timeoutNanoseconds = streaming.timeoutNanoseconds] in
                    do { try await Task.sleep(nanoseconds: timeoutNanoseconds) } catch { return }
                    await self?.resolve(id, error: EngineError.timeout, operationID: operationID)
                }
                replies[id] = Reply(operationID: operationID, peerID: peerID, kind: kind, continuation: reply, timeout: timeout)
                Task {
                    do { try await service.send(packet, to: peerID) }
                    catch { resolve(id, error: error, operationID: operationID) }
                }
            }
        }, onCancel: {
            Task { await self.resolve(id, error: CancellationError(), operationID: operationID) }
        })
    }

    private func resolve(_ id: UUID, error: Error? = nil, operationID: UUID? = nil) {
        if let operationID, replies[id]?.operationID != operationID { return }
        guard let reply = replies.removeValue(forKey: id) else { return }
        reply.timeout.cancel()
        if let error { reply.continuation.resume(throwing: error) }
        else { reply.continuation.resume() }
    }

    private func waitForAcknowledgment(_ id: UUID, minimum: Int64) async throws {
        try Task.checkCancellation()
        guard let window = sendingWindows[id] else { throw EngineError.disconnected }
        if let failure = window.failure { throw failure }
        if window.acknowledged >= minimum { return }
        let operationID = UUID()
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                window.waiter = CreditWaiter(operationID: operationID,
                    minimumAcknowledgment: minimum, continuation: continuation)
            }
        }, onCancel: {
            Task { await self.failWindow(id, error: CancellationError(), operationID: operationID) }
        })
    }

    private func acknowledge(_ id: UUID, bytes: Int64, peerID: UUID) async {
        guard let window = sendingWindows[id], window.peerID == peerID, window.failure == nil else { return }
        guard bytes >= window.acknowledged, bytes <= window.sent, bytes <= window.totalBytes else {
            failWindow(id, error: EngineError.invalidAcknowledgment)
            return
        }
        guard bytes > window.acknowledged else { return }
        window.acknowledged = bytes
        window.lastAcknowledgment = DispatchTime.now().uptimeNanoseconds
        let speed = window.speed.record(bytes)
        if let waiter = window.waiter, bytes >= waiter.minimumAcknowledgment {
            window.waiter = nil
            waiter.continuation.resume()
        }
        await update(id, throttled: true) {
            $0.transferredBytes = bytes; $0.bytesPerSecond = speed; $0.detail = "正在发送"
        }
    }

    private func failWindow(_ id: UUID, error: Error, operationID: UUID? = nil) {
        guard let window = sendingWindows[id] else { return }
        if let operationID, window.waiter?.operationID != operationID { return }
        guard window.failure == nil else { return }
        window.failure = error
        window.watchdog?.cancel()
        window.watchdog = nil
        if let waiter = window.waiter {
            window.waiter = nil
            waiter.continuation.resume(throwing: error)
        }
    }

    /// One watchdog per file checks inactivity. Valid advancing ACKs refresh a
    /// timestamp rather than creating/cancelling a timer for every data block.
    private func checkWindowTimeout(_ id: UUID) -> UInt64? {
        guard let window = sendingWindows[id], window.failure == nil else { return nil }
        let age = DispatchTime.now().uptimeNanoseconds - window.lastAcknowledgment
        if window.sent > window.acknowledged, age >= streaming.timeoutNanoseconds {
            failWindow(id, error: EngineError.timeout)
            return nil
        }
        return age < streaming.timeoutNanoseconds ? streaming.timeoutNanoseconds - age : streaming.timeoutNanoseconds
    }

    private func handle(_ event: LANEvent, generation currentGeneration: UInt64) async {
        guard started, currentGeneration == generation else { return }
        switch event {
        case .peerConnected(let peer):
            peers[peer.id] = peer
            await eventQueue.send(.peers(peers.values.sorted { $0.name < $1.name }))
            await eventQueue.send(.status("已连接，可直接拖入文件"))
            beginSendingIfPossible()
        case .peerDisconnected(let peerID):
            peers.removeValue(forKey: peerID)
            await eventQueue.send(.peers(peers.values.sorted { $0.name < $1.name }))
            if peers.isEmpty { await eventQueue.send(.status("等待另一台 Mac，连接后自动发送")) }
            for (id, reply) in replies where reply.peerID == peerID {
                resolve(id, error: EngineError.disconnected)
            }
            for (id, window) in sendingWindows where window.peerID == peerID {
                failWindow(id, error: EngineError.disconnected)
            }
            for (id, owner) in inboundOwners where owner == peerID {
                store.cancel(id: id)
                inboundOwners.removeValue(forKey: id)
                receivingSpeeds.removeValue(forKey: id)
                await fail(id, reason: "设备连接中断，未保存不完整文件。")
            }
        case .status(let text):
            await eventQueue.send(.status(text))
        case .authenticationFailed:
            if peers.isEmpty { await eventQueue.send(.status("发现了其他设备，正在寻找使用相同密码的 Mac")) }
        case .packet(let peerID, let packet):
            do {
                switch packet {
                case .control(let data):
                    let message = try JSONDecoder().decode(ControlMessage.self, from: data)
                    try await handleControl(message, from: peerID)
                case .chunk(let id, let data):
                    guard inboundOwners[id] == peerID else { return }
                    do {
                        let received = try store.append(id: id, data: data)
                        let speed = receivingSpeeds[id]?.record(received) ?? 0
                        await update(id, throttled: true) {
                            $0.transferredBytes = received; $0.bytesPerSecond = speed; $0.detail = "正在接收"
                        }
                        try await sendControl(.received(id: id, bytes: received), to: peerID)
                    } catch {
                        store.cancel(id: id)
                        inboundOwners.removeValue(forKey: id)
                        receivingSpeeds.removeValue(forKey: id)
                        await fail(id, reason: error.localizedDescription)
                        try? await sendControl(.reject(id: id, reason: error.localizedDescription), to: peerID)
                    }
                }
            } catch {
                await eventQueue.send(.error("处理来自 \(peers[peerID]?.name ?? "另一台 Mac") 的文件失败：\(error.localizedDescription)"))
            }
        }
    }

    private func handleControl(_ message: ControlMessage, from peerID: UUID) async throws {
        switch message {
        case .offer(let offer):
            guard inboundOwners[offer.id] == nil, replies[offer.id] == nil,
                  records[offer.id] == nil else {
                try await sendControl(.reject(id: offer.id, reason: "此传输编号已存在。"), to: peerID)
                return
            }
            do {
                _ = try store.begin(offer)
                inboundOwners[offer.id] = peerID
                receivingSpeeds[offer.id] = TransferSpeedMeter()
                let record = TransferProgress(id: offer.id, filename: offer.name,
                    peerName: peers[peerID]?.name ?? "另一台 Mac", direction: .receiving,
                    detail: "正在接收", state: .transferring, fileURL: nil,
                    totalBytes: offer.size, transferredBytes: 0)
                records[offer.id] = record
                await eventQueue.send(.progress(record))
                try await sendControl(.ready(offer.id), to: peerID)
            } catch {
                store.cancel(id: offer.id)
                inboundOwners.removeValue(forKey: offer.id)
                receivingSpeeds.removeValue(forKey: offer.id)
                await fail(offer.id, reason: error.localizedDescription)
                try await sendControl(.reject(id: offer.id, reason: error.localizedDescription), to: peerID)
            }
        case .ready(let id):
            if replies[id]?.peerID == peerID, replies[id]?.kind == .ready { resolve(id) }
        case .received(let id, let bytes):
            await acknowledge(id, bytes: bytes, peerID: peerID)
        case .finish(let id, let sha256):
            guard inboundOwners[id] == peerID else { return }
            do {
                let url = try store.finish(id: id, sha256: sha256)
                inboundOwners.removeValue(forKey: id)
                receivingSpeeds.removeValue(forKey: id)
                await update(id) {
                    $0.state = .completed; $0.transferredBytes = $0.totalBytes
                    $0.fileURL = url; $0.detail = "已保存到下载文件夹"
                }
            } catch {
                store.cancel(id: id)
                inboundOwners.removeValue(forKey: id)
                receivingSpeeds.removeValue(forKey: id)
                await fail(id, reason: error.localizedDescription)
                try await sendControl(.reject(id: id, reason: error.localizedDescription), to: peerID)
                return
            }
            // A lost acknowledgment must not invalidate a file already verified and saved.
            try? await sendControl(.complete(id), to: peerID)
        case .complete(let id):
            if replies[id]?.peerID == peerID, replies[id]?.kind == .complete { resolve(id) }
        case .reject(let id, let reason):
            if replies[id]?.peerID == peerID { resolve(id, error: EngineError.rejected(reason)) }
            if sendingWindows[id]?.peerID == peerID { failWindow(id, error: EngineError.rejected(reason)) }
        case .cancel(let id):
            if replies[id]?.peerID == peerID { resolve(id, error: EngineError.rejected("接收端取消了传输。")) }
            if sendingWindows[id]?.peerID == peerID { failWindow(id, error: EngineError.rejected("接收端取消了传输。")) }
            if inboundOwners[id] == peerID {
                store.cancel(id: id)
                inboundOwners.removeValue(forKey: id)
                receivingSpeeds.removeValue(forKey: id)
                await fail(id, reason: "发送端取消了传输。")
            }
        }
    }

    private func sendControl(_ message: ControlMessage, to peerID: UUID) async throws {
        try await service.send(.control(try JSONEncoder().encode(message)), to: peerID)
    }

    private func fail(_ id: UUID, reason: String) async {
        await update(id) { $0.state = .failed; $0.bytesPerSecond = 0; $0.detail = reason }
    }

    private func update(_ id: UUID, throttled: Bool = false,
                        mutate: (inout TransferProgress) -> Void) async {
        guard var record = records[id] else { return }
        mutate(&record)
        records[id] = record
        if throttled, let last = lastProgressUpdate[id], Date().timeIntervalSince(last) < 0.08 { return }
        lastProgressUpdate[id] = Date()
        await eventQueue.send(.progress(record))
        if record.state == .completed || record.state == .failed {
            let finished = records.values.filter { $0.state == .completed || $0.state == .failed }
            if finished.count > 100 {
                for stale in finished.prefix(finished.count - 100) where stale.id != id {
                    records.removeValue(forKey: stale.id)
                    lastProgressUpdate.removeValue(forKey: stale.id)
                }
            }
        }
    }
}
