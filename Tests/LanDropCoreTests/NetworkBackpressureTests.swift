import Foundation
import XCTest
@testable import LanDropCore

final class NetworkBackpressureTests: XCTestCase {
    func testFullEventQueueSuspendsProducerAndPreservesPayload() async throws {
        let queue = LANEventQueue(maximumBytes: 1_048_576, maximumEvents: 1)
        let accepted = await queue.send(.status("first"))
        XCTAssertTrue(accepted)
        let peer = UUID()
        let transferID = UUID()
        let bytes = Data(repeating: 0x47, count: 1_048_576)
        let producer = Task { await queue.send(.packet(peer, .chunk(transferID: transferID, data: bytes))) }
        try await Task.sleep(nanoseconds: 20_000_000)
        let full = await queue.bufferingForTesting()
        XCTAssertEqual(full.events, 1)
        XCTAssertEqual(full.suspendedProducers, 1)
        XCTAssertLessThanOrEqual(full.bytes, 1_048_576)
        let first = await queue.next()
        guard case .status("first") = first else { return XCTFail("FIFO event was lost") }
        let produced = await producer.value
        XCTAssertTrue(produced)
        let next = await queue.next()
        guard case .packet(let source, .chunk(let id, let data)) = next else { return XCTFail("Queued chunk was lost") }
        XCTAssertEqual(source, peer)
        XCTAssertEqual(id, transferID)
        XCTAssertEqual(data, bytes)
        await queue.finish()
    }

    func testClosingQueueResumesBlockedProducerAndConsumer() async throws {
        let queue = LANEventQueue(maximumBytes: 1_048_576, maximumEvents: 1)
        _ = await queue.send(.status("first"))
        let producer = Task { await queue.send(.status("second")) }
        try await Task.sleep(nanoseconds: 20_000_000)
        await queue.finish()
        let produced = await producer.value
        XCTAssertFalse(produced)
        let ended = await queue.next()
        XCTAssertNil(ended)

        let empty = LANEventQueue()
        let consumer = Task { await empty.next() }
        try await Task.sleep(nanoseconds: 20_000_000)
        await empty.finish()
        let pending = await consumer.value
        XCTAssertNil(pending)
    }

    func testTerminalProgressCannotBeOverwrittenByLateIntermediateUpdate() async throws {
        for state in [TransferState.completed, .failed] {
            let queue = TransferProgressEventQueue()
            let id = UUID()
            var record = TransferProgress(id: id, filename: "file.bin", peerName: "Mac",
                direction: .sending, detail: "terminal", state: state, fileURL: nil,
                totalBytes: 100, transferredBytes: 100)
            await queue.send(.progress(record))
            record.state = .transferring
            record.detail = "late intermediate update"
            await queue.send(.progress(record))
            let delivered = await queue.next()
            guard case .progress(let terminal) = delivered else { return XCTFail("Missing terminal progress") }
            XCTAssertEqual(terminal.state, state)
            XCTAssertEqual(terminal.detail, "terminal")
            await queue.finish()
        }
    }
}
