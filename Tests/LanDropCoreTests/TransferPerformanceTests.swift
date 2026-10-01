import Foundation
import XCTest
@testable import LanDropCore

private actor PerformanceLog {
    private var latest: TransferProgress?
    private var records: [UUID: TransferProgress] = [:]
    private var peers = 0
    private var paused = false
    private var resumeContinuation: CheckedContinuation<Void, Never>?

    func record(_ event: TransferEvent) async {
        if paused { await withCheckedContinuation { resumeContinuation = $0 } }
        switch event {
        case .progress(let progress): latest = progress; records[progress.id] = progress
        case .peers(let values): peers = values.count
        default: break
        }
    }

    func snapshot() -> TransferProgress? { latest }
    func connected() -> Bool { peers > 0 }
    func pause() { paused = true }
    func resume() {
        paused = false
        resumeContinuation?.resume()
        resumeContinuation = nil
    }
    func terminals() -> Int { records.values.filter { $0.state == .completed || $0.state == .failed }.count }
    func active() -> Int { records.values.filter { $0.state == .waiting || $0.state == .transferring }.count }
    func count() -> Int { records.count }
}

/// Implements exactly the v1.0.0/1.0.1 wire receiver: cumulative .received after
/// each chunk, followed by checksum-verified .complete. Its single ACK scheduler
/// adds propagation delay without adding a serial sleep to the receive loop.
private actor DelayedLegacyReceiver {
    enum Fault: Equatable {
        case none, negativeACK, regressiveACK, aheadACK, dropACK
        case disconnect, reject, cancel, dropComplete
    }
    struct Snapshot {
        let savedURL: URL?
        let chunks: [Int]
        let largestACKQueue: Int
        let cancelled: Bool
        let completedFiles: Int
    }
    private struct Acknowledgment {
        let message: ControlMessage
        let peerID: UUID
        let due: UInt64
    }

    private let service: LANService
    private let store: IncomingFileStore
    private let delayNanoseconds: UInt64
    private let fault: Fault
    private var eventTask: Task<Void, Never>?
    private var acknowledgmentTask: Task<Void, Never>?
    private var acknowledgments: [Acknowledgment] = []
    private var peerID: UUID?
    private var savedURL: URL?
    private var chunkSizes: [Int] = []
    private var largestQueue = 0
    private var totalBytes: Int64 = 0
    private var cancelled = false
    private var ignoresChunks = false
    private var completedFiles = 0

    init(directory: URL, service: LANService, delayNanoseconds: UInt64, fault: Fault = .none) throws {
        self.service = service
        self.store = try IncomingFileStore(directory: directory)
        self.delayNanoseconds = delayNanoseconds
        self.fault = fault
    }

    func observe() {
        eventTask = Task { [weak self, service] in
            for await event in service.events { await self?.handle(event) }
        }
    }

    func stop() {
        eventTask?.cancel()
        acknowledgmentTask?.cancel()
        store.cancelAll()
        service.stop()
    }

    func snapshot() -> Snapshot {
        Snapshot(savedURL: savedURL, chunks: chunkSizes, largestACKQueue: largestQueue,
                 cancelled: cancelled, completedFiles: completedFiles)
    }

    private func handle(_ event: LANEvent) async {
        do {
            switch event {
            case .peerConnected(let peer): peerID = peer.id
            case .peerDisconnected:
                store.cancelAll()
                ignoresChunks = true
                acknowledgmentTask?.cancel()
                acknowledgments.removeAll()
            case .packet(let peer, .control(let data)):
                let message = try JSONDecoder().decode(ControlMessage.self, from: data)
                switch message {
                case .offer(let offer):
                    totalBytes = offer.size
                    _ = try store.begin(offer)
                    try await send(.ready(offer.id), peerID: peer)
                case .finish(let id, let hash):
                    savedURL = try store.finish(id: id, sha256: hash)
                    completedFiles += 1
                    if fault != .dropComplete { enqueue(.complete(id), peerID: peer) }
                case .cancel(let id):
                    store.cancel(id: id)
                    cancelled = true
                    ignoresChunks = true
                    acknowledgmentTask?.cancel()
                    acknowledgments.removeAll()
                default: break
                }
            case .packet(let peer, .chunk(let id, let data)):
                guard !ignoresChunks else { return }
                let bytes = try store.append(id: id, data: data)
                chunkSizes.append(data.count)
                if chunkSizes.count == 2 {
                    switch fault {
                    case .disconnect:
                        ignoresChunks = true
                        store.cancel(id: id)
                        service.stop()
                        return
                    case .reject, .cancel:
                        ignoresChunks = true
                        store.cancel(id: id)
                        let message: ControlMessage = fault == .reject ? .reject(id: id, reason: "receiver rejected transfer") : .cancel(id)
                        try await send(message, peerID: peer)
                        return
                    default: break
                    }
                }
                if fault == .dropACK { return }
                var acknowledged = bytes
                if chunkSizes.count == 1, fault == .negativeACK { acknowledged = -1 }
                if chunkSizes.count == 1, fault == .aheadACK { acknowledged = totalBytes }
                if chunkSizes.count == 2, fault == .regressiveACK { acknowledged = 0 }
                enqueue(.received(id: id, bytes: acknowledged), peerID: peer)
            default: break
            }
        } catch {
            XCTFail("Legacy receiver failed: \(error)")
        }
    }

    private func enqueue(_ message: ControlMessage, peerID: UUID) {
        guard acknowledgments.count < 128 else {
            XCTFail("RTT simulator must retain a bounded ACK queue")
            service.stop()
            return
        }
        acknowledgments.append(Acknowledgment(message: message, peerID: peerID,
            due: DispatchTime.now().uptimeNanoseconds + delayNanoseconds))
        largestQueue = max(largestQueue, acknowledgments.count)
        if acknowledgmentTask == nil {
            acknowledgmentTask = Task { [weak self] in await self?.drainAcknowledgments() }
        }
    }

    private func drainAcknowledgments() async {
        while !Task.isCancelled, let next = acknowledgments.first {
            let now = DispatchTime.now().uptimeNanoseconds
            if next.due > now {
                do { try await Task.sleep(nanoseconds: next.due - now) } catch { break }
            }
            guard !Task.isCancelled else { break }
            guard let current = acknowledgments.first, current.due == next.due,
                  current.message == next.message else { continue }
            acknowledgments.removeFirst()
            do { try await send(next.message, peerID: next.peerID) }
            catch { break }
        }
        acknowledgmentTask = nil
    }

    private func send(_ message: ControlMessage, peerID: UUID) async throws {
        try await service.send(.control(try JSONEncoder().encode(message)), to: peerID)
    }
}

final class TransferPerformanceTests: XCTestCase {
    private func eventually(timeout: TimeInterval = 15, _ condition: () async -> Bool) async throws {
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(timeout * 1_000_000_000)
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTFail("Timed out waiting for encrypted benchmark transfer")
        throw NSError(domain: "TransferPerformanceTests", code: 1)
    }

    private func withTransfer(size: Int = 16 * 1_048_576 + 17,
                              streaming: TransferStreamingConfiguration = .standard,
                              delay: UInt64 = 20_000_000,
                              fault: DelayedLegacyReceiver.Fault = .none,
                              body: (TransferEngine, PerformanceLog, DelayedLegacyReceiver, URL, Data, URL) async throws -> Void) async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("LanDropPerformance-\(UUID())")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let payload = Data(repeating: 0xa7, count: size)
        let source = base.appendingPathComponent("benchmark.bin")
        try payload.write(to: source)
        let senderService = LANService(discoveryEnabled: false)
        let receiverService = LANService(discoveryEnabled: false)
        let sender = try TransferEngine(directory: base.appendingPathComponent("sender"), service: senderService, streaming: streaming)
        let receiverDirectory = base.appendingPathComponent("receiver")
        let receiver = try DelayedLegacyReceiver(directory: receiverDirectory, service: receiverService,
                                                delayNanoseconds: delay, fault: fault)
        let log = PerformanceLog()
        let observer = Task { for await event in sender.events { await log.record(event) } }
        defer {
            observer.cancel()
            senderService.stop()
            receiverService.stop()
            Task { await log.resume(); await sender.stop(); await receiver.stop() }
            try? FileManager.default.removeItem(at: base)
        }
        await receiver.observe()
        let lowerID = UUID(uuidString: "00000000-0000-0000-0000-000000000011")!
        let upperID = UUID(uuidString: "00000000-0000-0000-0000-000000000022")!
        try await sender.start(deviceID: lowerID, name: "Benchmark sender", password: "benchmark-password")
        let port = try await receiverService.startForTesting(deviceID: upperID, name: "Legacy receiver", password: "benchmark-password")
        try await senderService.connectForTesting(to: port)
        try await eventually { await log.connected() }
        try await body(sender, log, receiver, source, payload, receiverDirectory)
        await sender.stop()
        await receiver.stop()
    }

    private func terminal(_ log: PerformanceLog) async throws -> TransferProgress {
        try await eventually {
            let progress = await log.snapshot()
            return progress?.state == .completed || progress?.state == .failed
        }
        let snapshot = await log.snapshot()
        return try XCTUnwrap(snapshot)
    }

    private func assertNoPendingWaiters(_ sender: TransferEngine) async throws {
        try await eventually {
            let state = await sender.streamingStateForTesting()
            let busy = await sender.hasPendingTransfers()
            return state.windows == 0 && state.waiters == 0 && !busy
        }
    }

    func testPipeliningUsesBoundedWindowAndCompletesWithLegacyReceiver() async throws {
        try await withTransfer { sender, log, receiver, source, payload, _ in
            await sender.enqueue([source])
            let record = try await self.terminal(log)
            XCTAssertEqual(record.state, .completed, record.detail)
            XCTAssertGreaterThan(record.bytesPerSecond, 0)
            XCTAssertTrue(record.bytesPerSecond.isFinite)
            let received = await receiver.snapshot()
            let destination = try XCTUnwrap(received.savedURL)
            XCTAssertEqual(try Data(contentsOf: destination), payload)
            XCTAssertEqual(received.chunks.max(), 1_048_576)
            XCTAssertGreaterThan(received.largestACKQueue, 1, "Several chunks must be sent before the first ACK")
            XCTAssertLessThanOrEqual(received.largestACKQueue, 8)
            let state = await sender.streamingStateForTesting()
            XCTAssertEqual(state.maximumInFlight, 8 * 1_048_576)
            try await self.assertNoPendingWaiters(sender)
        }
    }

    func testNegativeRegressiveAndAheadOfSentAcknowledgmentsFailAndCancel() async throws {
        for fault in [DelayedLegacyReceiver.Fault.negativeACK, .regressiveACK, .aheadACK] {
            try await withTransfer(fault: fault) { sender, log, receiver, source, _, directory in
                await sender.enqueue([source])
                let record = try await self.terminal(log)
                XCTAssertEqual(record.state, .failed)
                XCTAssertTrue(record.detail.contains("无效"), record.detail)
                try await self.eventually { await receiver.snapshot().cancelled }
                XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
                try await self.assertNoPendingWaiters(sender)
            }
        }
    }

    func testDisconnectDuringPipelineFailsAndDiscardsIncompleteFile() async throws {
        try await withTransfer(delay: 200_000_000, fault: .disconnect) { sender, log, _, source, _, directory in
            await sender.enqueue([source])
            let record = try await self.terminal(log)
            XCTAssertEqual(record.state, .failed)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
            try await self.assertNoPendingWaiters(sender)
        }
    }

    func testReceiverRejectAndCancelInterruptPipeline() async throws {
        for fault in [DelayedLegacyReceiver.Fault.reject, .cancel] {
            try await withTransfer(delay: 200_000_000, fault: fault) { sender, log, _, source, _, directory in
                await sender.enqueue([source])
                let record = try await self.terminal(log)
                XCTAssertEqual(record.state, .failed)
                XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
                try await self.assertNoPendingWaiters(sender)
            }
        }
    }

    func testNoAdvancingAcknowledgmentsTimesOutAndCleansWindow() async throws {
        let configuration = TransferStreamingConfiguration(timeoutNanoseconds: 120_000_000)
        try await withTransfer(streaming: configuration, fault: .dropACK) { sender, log, receiver, source, _, directory in
            await sender.enqueue([source])
            let record = try await self.terminal(log)
            XCTAssertEqual(record.state, .failed)
            XCTAssertTrue(record.detail.contains("超时"), record.detail)
            try await self.eventually { await receiver.snapshot().cancelled }
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
            let state = await sender.streamingStateForTesting()
            XCTAssertEqual(state.maximumInFlight, 8 * 1_048_576)
            try await self.assertNoPendingWaiters(sender)
        }
    }

    func testStopResumesSuspendedCreditWaiter() async throws {
        try await withTransfer(delay: 2_000_000_000) { sender, log, _, source, _, _ in
            await sender.enqueue([source])
            try await self.eventually { await sender.streamingStateForTesting().waiters == 1 }
            let busy = await sender.hasPendingTransfers()
            XCTAssertTrue(busy)
            await sender.stop()
            let record = try await self.terminal(log)
            XCTAssertEqual(record.state, .failed)
            try await self.assertNoPendingWaiters(sender)
        }
    }

    func testFinalChecksumCompleteAcknowledgmentIsRequired() async throws {
        let configuration = TransferStreamingConfiguration(timeoutNanoseconds: 200_000_000)
        try await withTransfer(size: 2 * 1_048_576, streaming: configuration, delay: 0,
                               fault: .dropComplete) { sender, log, receiver, source, payload, _ in
            await sender.enqueue([source])
            let record = try await self.terminal(log)
            XCTAssertEqual(record.state, .failed)
            XCTAssertTrue(record.detail.contains("超时"), record.detail)
            let received = await receiver.snapshot()
            let verifiedFile = try XCTUnwrap(received.savedURL)
            XCTAssertEqual(try Data(contentsOf: verifiedFile), payload,
                "A missing final ACK cannot discard a file already verified by the receiver")
            try await self.assertNoPendingWaiters(sender)
        }
    }

    func testPausedProgressConsumerReceivesAll200TerminalStates() async throws {
        try await withTransfer(size: 1, delay: 0) { sender, log, receiver, source, _, directory in
            await log.pause()
            await sender.enqueue(Array(repeating: source, count: 200))
            try await self.eventually { await receiver.snapshot().completedFiles == 200 }
            try await self.assertNoPendingWaiters(sender)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 200)
            await log.resume()
            try await self.eventually { await log.terminals() == 200 }
            let active = await log.active()
            XCTAssertEqual(active, 0, "A paused UI must not retain stale transferring rows after completion")
        }
    }

    func testLegacyStopAndWaitSenderIsAcceptedByModernReceiver() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("LegacySender-\(UUID())")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let payload = Data(repeating: 0x5b, count: 3 * 262_144 + 17)
        let source = base.appendingPathComponent("legacy.bin")
        try payload.write(to: source)
        let senderService = LANService(discoveryEnabled: false)
        let receiverService = LANService(discoveryEnabled: false)
        let sender = try TransferEngine(directory: base.appendingPathComponent("sender"),
            service: senderService, streaming: .legacy)
        let receiver = try TransferEngine(directory: base.appendingPathComponent("receiver"), service: receiverService)
        let senderLog = PerformanceLog()
        let receiverLog = PerformanceLog()
        let senderObserver = Task { for await event in sender.events { await senderLog.record(event) } }
        let receiverObserver = Task { for await event in receiver.events { await receiverLog.record(event) } }
        defer {
            senderObserver.cancel()
            receiverObserver.cancel()
            senderService.stop()
            receiverService.stop()
            Task { await sender.stop(); await receiver.stop() }
            try? FileManager.default.removeItem(at: base)
        }
        let lowerID = UUID(uuidString: "00000000-0000-0000-0000-000000000011")!
        let upperID = UUID(uuidString: "00000000-0000-0000-0000-000000000022")!
        try await sender.start(deviceID: lowerID, name: "Legacy sender", password: "legacy-test")
        try await receiver.start(deviceID: upperID, name: "Modern receiver", password: "legacy-test")
        try await senderService.connectForTesting(port: await receiverService.listeningPortForTesting()!)
        try await eventually { await senderLog.connected() }
        await sender.enqueue([source])
        let outgoing = try await terminal(senderLog)
        let incoming = try await terminal(receiverLog)
        XCTAssertEqual(outgoing.state, .completed)
        XCTAssertEqual(incoming.state, .completed)
        XCTAssertGreaterThan(outgoing.bytesPerSecond, 0)
        XCTAssertGreaterThan(incoming.bytesPerSecond, 0)
        let destination = try XCTUnwrap(incoming.fileURL)
        XCTAssertEqual(try Data(contentsOf: destination), payload)
        let statistics = await sender.streamingStateForTesting()
        XCTAssertLessThanOrEqual(statistics.maximumInFlight, 262_144)
        await sender.stop()
        await receiver.stop()
    }

    func testConcurrentEnqueueReservesWholeBatchBeforePublishing() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("EnqueueLimit-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = LANService(discoveryEnabled: false)
        let engine = try TransferEngine(directory: directory, service: service)
        let log = PerformanceLog()
        let observer = Task { for await event in engine.events { await log.record(event) } }
        defer { observer.cancel(); service.stop(); Task { await engine.stop() } }
        try await engine.start(deviceID: UUID(), name: "Offline Mac", password: "enqueue-limit")
        let source = directory.appendingPathComponent("queued.txt")
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await engine.enqueue(Array(repeating: source, count: 150)) }
            group.addTask { await engine.enqueue(Array(repeating: source, count: 150)) }
        }
        try await eventually { await log.count() == 150 }
        let count = await log.count()
        XCTAssertEqual(count, 150, "The second150-file batch must see the first batch's full reservation")
        await engine.stop()
    }

    /// Reproduce with LANDROP_RUN_BENCHMARK=1 swift test --filter
    /// TransferPerformanceTests.testArtificialRTTBenchmark
    func testArtificialRTTBenchmark() async throws {
        guard ProcessInfo.processInfo.environment["LANDROP_RUN_BENCHMARK"] == "1" else {
            throw XCTSkip("Opt-in throughput benchmark; set LANDROP_RUN_BENCHMARK=1")
        }
        var timings: [Double] = []
        for (mode, configuration) in [("legacy", TransferStreamingConfiguration.legacy), ("pipeline", .standard)] {
            try await withTransfer(size: 32 * 1_048_576, streaming: configuration) { sender, log, receiver, source, payload, _ in
                let started = DispatchTime.now().uptimeNanoseconds
                await sender.enqueue([source])
                let record = try await self.terminal(log)
                let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000_000
                XCTAssertEqual(record.state, .completed, record.detail)
                let received = await receiver.snapshot()
                let destination = try XCTUnwrap(received.savedURL)
                XCTAssertEqual(try Data(contentsOf: destination), payload)
                let mibPerSecond = Double(payload.count) / elapsed / 1_048_576
                print(String(format: "LANDROP_BENCHMARK mode=%@ bytes=%d rtt_ms=20 chunks=%d max_chunk=%d max_pending_acks=%d seconds=%.4f MiB_per_second=%.3f",
                    mode, payload.count, received.chunks.count, received.chunks.max() ?? 0,
                    received.largestACKQueue, elapsed, mibPerSecond))
                timings.append(elapsed)
            }
        }
        let speedup = timings[0] / timings[1]
        print(String(format: "LANDROP_BENCHMARK speedup=%.2fx", speedup))
        XCTAssertGreaterThan(speedup, 4, "A pipelined window must hide the simulated20ms RTT")
    }
}
