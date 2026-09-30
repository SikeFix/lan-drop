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

public actor TransferEngine {
    public nonisolated let events: AsyncStream<TransferEvent>
    private let continuation: AsyncStream<TransferEvent>.Continuation
    private let service: LANService
    private let store: IncomingFileStore
    private var eventTask: Task<Void, Never>?
    private var sendTask: Task<Void, Never>?
    private var peers: [UUID: Peer] = [:]
    private var records: [UUID: TransferProgress] = [:]
    private var inboundOwners: [UUID: UUID] = [:]
    private var jobs: [Job] = []
    private var preferredPeerID: UUID?
    private var lastProgressUpdate: [UUID: Date] = [:]
    private var replies: [UUID: Reply] = [:]
    private var started = false
    private var generation: UInt64 = 0

    private struct Job { let id: UUID; let url: URL }
    private enum ReplyKind: Equatable { case ready, complete, chunk(Int64) }
    private struct Reply {
        let operationID: UUID
        let peerID: UUID
        let kind: ReplyKind
        let continuation: CheckedContinuation<Void, Error>
        let timeout: Task<Void, Never>
    }
    private enum EngineError: LocalizedError {
        case disconnected, timeout, rejected(String), fileChanged
        var errorDescription: String? {
            switch self {
            case .disconnected: return "设备连接已断开，文件未发送完成。"
            case .timeout: return "等待另一台 Mac 响应超时。"
            case .rejected(let reason): return reason
            case .fileChanged: return "文件在发送期间发生变化，请完成编辑后重新拖入。"
            }
        }
    }

    public init(directory: URL, service: LANService = LANService()) throws {
        var captured: AsyncStream<TransferEvent>.Continuation!
        events = AsyncStream(bufferingPolicy: .unbounded) { captured = $0 }
        continuation = captured
        self.service = service
        store = try IncomingFileStore(directory: directory)
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
            continuation.yield(.status("正在寻找使用相同密码的 Mac"))
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
        store.cancelAll()
        for (id, _) in inboundOwners { fail(id, reason: "配对已重置，接收已取消。") }
        inboundOwners.removeAll()
        for job in jobs { fail(job.id, reason: "配对已重置，发送已取消。") }
        jobs.removeAll()
        peers.removeAll()
        continuation.yield(.peers([]))
    }

    public func selectPeer(_ id: UUID?) {
        preferredPeerID = id
        beginSendingIfPossible()
    }

    public func enqueue(_ urls: [URL]) {
        guard started else {
            continuation.yield(.error("请先设置两台 Mac 共用的配对密码。"))
            return
        }
        guard jobs.count + urls.count <= 200 else {
            continuation.yield(.error("一次最多等待发送 200 个文件，请等待当前队列完成。"))
            return
        }
        for url in urls where url.isFileURL {
            let id = UUID()
            let record = TransferProgress(id: id, filename: url.lastPathComponent,
                peerName: "另一台 Mac", direction: .sending,
                detail: peers.isEmpty ? "等待设备连接，连接后自动发送" : "等待发送",
                state: .waiting, fileURL: nil, totalBytes: 0, transferredBytes: 0)
            records[id] = record
            continuation.yield(.progress(record))
            jobs.append(Job(id: id, url: url))
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
                fail(job.id, reason: error.localizedDescription)
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
        update(job.id) { $0.detail = "正在准备文件"; $0.peerName = peer.name }
        let prepared = try await FilePreparation.prepare(url: job.url)
        defer { prepared.cleanup() }
        try Task.checkCancellation()
        update(job.id) {
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
        while let chunk = try handle.read(upToCount: 256 * 1024), !chunk.isEmpty {
            try Task.checkCancellation()
            guard sent + Int64(chunk.count) <= prepared.size else { throw EngineError.fileChanged }
            try await requestPacket(.chunk(transferID: job.id, data: chunk), id: job.id,
                                    peerID: peer.id, expecting: .chunk(sent + Int64(chunk.count)))
            hash.update(data: chunk)
            sent += Int64(chunk.count)
            update(job.id, throttled: true) {
                $0.transferredBytes = sent; $0.detail = "正在发送"
            }
        }
        guard sent == prepared.size else { throw EngineError.fileChanged }
        var finalMetadata = stat()
        guard Darwin.fstat(descriptor, &finalMetadata) == 0,
              finalMetadata.st_size == metadata.st_size,
              finalMetadata.st_mtimespec.tv_sec == metadata.st_mtimespec.tv_sec,
              finalMetadata.st_mtimespec.tv_nsec == metadata.st_mtimespec.tv_nsec else {
            throw EngineError.fileChanged
        }
        update(job.id) { $0.transferredBytes = sent; $0.detail = "接收端正在校验文件" }
        let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
        try await request(.finish(id: job.id, sha256: digest), id: job.id,
                          peerID: peer.id, expecting: .complete)
        update(job.id) { $0.state = .completed; $0.detail = "已送达 \(peer.name)" }
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
                let timeout = Task { [weak self] in
                    do { try await Task.sleep(nanoseconds: 60_000_000_000) } catch { return }
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

    private func handle(_ event: LANEvent, generation currentGeneration: UInt64) async {
        guard started, currentGeneration == generation else { return }
        switch event {
        case .peerConnected(let peer):
            peers[peer.id] = peer
            continuation.yield(.peers(peers.values.sorted { $0.name < $1.name }))
            continuation.yield(.status("已连接，可直接拖入文件"))
            beginSendingIfPossible()
        case .peerDisconnected(let peerID):
            peers.removeValue(forKey: peerID)
            continuation.yield(.peers(peers.values.sorted { $0.name < $1.name }))
            if peers.isEmpty { continuation.yield(.status("等待另一台 Mac，连接后自动发送")) }
            for (id, reply) in replies where reply.peerID == peerID {
                resolve(id, error: EngineError.disconnected)
            }
            for (id, owner) in inboundOwners where owner == peerID {
                store.cancel(id: id)
                inboundOwners.removeValue(forKey: id)
                fail(id, reason: "设备连接中断，未保存不完整文件。")
            }
        case .status(let text):
            continuation.yield(.status(text))
        case .authenticationFailed:
            if peers.isEmpty { continuation.yield(.status("发现了其他设备，正在寻找使用相同密码的 Mac")) }
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
                        update(id, throttled: true) { $0.transferredBytes = received; $0.detail = "正在接收" }
                        try await sendControl(.received(id: id, bytes: received), to: peerID)
                    } catch {
                        store.cancel(id: id)
                        inboundOwners.removeValue(forKey: id)
                        fail(id, reason: error.localizedDescription)
                        try? await sendControl(.reject(id: id, reason: error.localizedDescription), to: peerID)
                    }
                }
            } catch {
                continuation.yield(.error("处理来自 \(peers[peerID]?.name ?? "另一台 Mac") 的文件失败：\(error.localizedDescription)"))
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
                let record = TransferProgress(id: offer.id, filename: offer.name,
                    peerName: peers[peerID]?.name ?? "另一台 Mac", direction: .receiving,
                    detail: "正在接收", state: .transferring, fileURL: nil,
                    totalBytes: offer.size, transferredBytes: 0)
                records[offer.id] = record
                continuation.yield(.progress(record))
                try await sendControl(.ready(offer.id), to: peerID)
            } catch {
                store.cancel(id: offer.id)
                inboundOwners.removeValue(forKey: offer.id)
                fail(offer.id, reason: error.localizedDescription)
                try await sendControl(.reject(id: offer.id, reason: error.localizedDescription), to: peerID)
            }
        case .ready(let id):
            if replies[id]?.peerID == peerID, replies[id]?.kind == .ready { resolve(id) }
        case .received(let id, let bytes):
            if replies[id]?.peerID == peerID, replies[id]?.kind == .chunk(bytes) { resolve(id) }
        case .finish(let id, let sha256):
            guard inboundOwners[id] == peerID else { return }
            do {
                let url = try store.finish(id: id, sha256: sha256)
                inboundOwners.removeValue(forKey: id)
                update(id) {
                    $0.state = .completed; $0.transferredBytes = $0.totalBytes
                    $0.fileURL = url; $0.detail = "已保存到下载文件夹"
                }
            } catch {
                store.cancel(id: id)
                inboundOwners.removeValue(forKey: id)
                fail(id, reason: error.localizedDescription)
                try await sendControl(.reject(id: id, reason: error.localizedDescription), to: peerID)
                return
            }
            // A lost acknowledgment must not invalidate a file already verified and saved.
            try? await sendControl(.complete(id), to: peerID)
        case .complete(let id):
            if replies[id]?.peerID == peerID, replies[id]?.kind == .complete { resolve(id) }
        case .reject(let id, let reason):
            if replies[id]?.peerID == peerID { resolve(id, error: EngineError.rejected(reason)) }
        case .cancel(let id):
            if inboundOwners[id] == peerID {
                store.cancel(id: id)
                inboundOwners.removeValue(forKey: id)
                fail(id, reason: "发送端取消了传输。")
            }
        }
    }

    private func sendControl(_ message: ControlMessage, to peerID: UUID) async throws {
        try await service.send(.control(try JSONEncoder().encode(message)), to: peerID)
    }

    private func fail(_ id: UUID, reason: String) {
        update(id) { $0.state = .failed; $0.detail = reason }
    }

    private func update(_ id: UUID, throttled: Bool = false,
                        mutate: (inout TransferProgress) -> Void) {
        guard var record = records[id] else { return }
        mutate(&record)
        records[id] = record
        if throttled, let last = lastProgressUpdate[id], Date().timeIntervalSince(last) < 0.08 { return }
        lastProgressUpdate[id] = Date()
        continuation.yield(.progress(record))
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
