import Foundation
import XCTest
@testable import LanDropCore

private actor TransferLog {
    var records: [UUID: TransferProgress] = [:]
    var peers: [Peer] = []
    var errors: [String] = []
    func add(_ event: TransferEvent) {
        switch event {
        case .progress(let record): records[record.id] = record
        case .peers(let list): peers = list
        case .error(let message): errors.append(message)
        case .status: break
        }
    }
    func completed(_ direction: TransferDirection) -> [TransferProgress] {
        records.values.filter { $0.state == .completed && $0.direction == direction }
    }
    func waiting() -> Int { records.values.filter { $0.state == .waiting }.count }
    func peerCount() -> Int { peers.count }
}

final class TransferEngineTests: XCTestCase {
    private let leftID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let rightID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!

    private func eventually(timeout: TimeInterval = 20, _ condition: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Timed out waiting for a real transfer event")
        throw NSError(domain: "TransferEngineTests", code: 1)
    }

    func testOfflineQueueStreamsFilesAndReceivesInBothDirections() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("EngineTest-\(UUID())")
        defer { try? FileManager.default.removeItem(at: base) }
        let leftDirectory = base.appendingPathComponent("left")
        let rightDirectory = base.appendingPathComponent("right")
        let sourceDirectory = base.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        let payload = Data((0..<(2 * 1024 * 1024 + 71)).map { UInt8(truncatingIfNeeded: $0 * 31) })
        let large = sourceDirectory.appendingPathComponent("报告 📨.bin")
        let empty = sourceDirectory.appendingPathComponent("empty.txt")
        try payload.write(to: large)
        try Data().write(to: empty)

        let leftService = LANService(discoveryEnabled: false)
        let rightService = LANService(discoveryEnabled: false)
        let left = try TransferEngine(directory: leftDirectory, service: leftService)
        let right = try TransferEngine(directory: rightDirectory, service: rightService)
        let leftLog = TransferLog()
        let rightLog = TransferLog()
        let leftObserver = Task { for await event in left.events { await leftLog.add(event) } }
        let rightObserver = Task { for await event in right.events { await rightLog.add(event) } }
        defer { leftObserver.cancel(); rightObserver.cancel(); leftService.stop(); rightService.stop() }

        try await left.start(deviceID: leftID, name: "书房 Mac", password: "test-password-2026")
        try await right.start(deviceID: rightID, name: "办公 Mac", password: "test-password-2026")
        await left.enqueue([large, empty])
        try await eventually { await leftLog.waiting() == 2 }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: rightDirectory.path), [])

        try await eventually { await rightService.listeningPortForTesting() != nil }
        let port = await rightService.listeningPortForTesting()!
        try await leftService.connectForTesting(port: port)
        try await eventually { await rightLog.completed(.receiving).count == 2 }
        try await eventually { await leftLog.completed(.sending).count == 2 }
        XCTAssertEqual(try Data(contentsOf: rightDirectory.appendingPathComponent("报告 📨.bin")), payload)
        XCTAssertEqual(try Data(contentsOf: rightDirectory.appendingPathComponent("empty.txt")), Data())

        // Same connection supports the reverse direction and duplicate filenames safely.
        await right.enqueue([large, empty])
        await left.enqueue([large])
        try await eventually { await leftLog.completed(.receiving).count == 2 }
        try await eventually { await rightLog.completed(.receiving).count == 3 }
        try await eventually { await leftLog.completed(.sending).count == 3 }
        try await eventually { await rightLog.completed(.sending).count == 2 }
        XCTAssertEqual(try Data(contentsOf: leftDirectory.appendingPathComponent("报告 📨.bin")), payload)
        XCTAssertEqual(try Data(contentsOf: rightDirectory.appendingPathComponent("报告 📨 (1).bin")), payload)
        let errors = await leftLog.errors + rightLog.errors
        XCTAssertTrue(errors.isEmpty, errors.joined(separator: ", "))
        await left.stop()
        await right.stop()
    }

    func testFolderIsDeliveredAsZipAndResetCancelsOfflineQueue() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("EngineFolder-\(UUID())")
        defer { try? FileManager.default.removeItem(at: base) }
        let folder = base.appendingPathComponent("素材", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("测试素材".utf8).write(to: folder.appendingPathComponent("原稿.txt"))
        let leftService = LANService(discoveryEnabled: false)
        let rightService = LANService(discoveryEnabled: false)
        let left = try TransferEngine(directory: base.appendingPathComponent("left"), service: leftService)
        let right = try TransferEngine(directory: base.appendingPathComponent("right"), service: rightService)
        let log = TransferLog()
        let observer = Task { for await event in right.events { await log.add(event) } }
        defer { observer.cancel(); leftService.stop(); rightService.stop() }
        try await left.start(deviceID: leftID, name: "Left", password: "folder-password")
        try await right.start(deviceID: rightID, name: "Right", password: "folder-password")
        try await eventually { await rightService.listeningPortForTesting() != nil }
        try await leftService.connectForTesting(port: await rightService.listeningPortForTesting()!)
        await left.enqueue([folder])
        try await eventually { await log.completed(.receiving).count == 1 }
        let received = await log.completed(.receiving)
        XCTAssertEqual(received.first?.filename, "素材.zip")
        let archive = try XCTUnwrap(received.first?.fileURL)
        XCTAssertGreaterThan(try Data(contentsOf: archive).count, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("原稿.txt").path))
        await left.stop()
        await right.stop()

        let offline = try TransferEngine(directory: base.appendingPathComponent("offline"), service: LANService(discoveryEnabled: false))
        let offlineLog = TransferLog()
        let offlineObserver = Task { for await event in offline.events { await offlineLog.add(event) } }
        defer { offlineObserver.cancel() }
        try await offline.start(deviceID: leftID, name: "Offline", password: "folder-password")
        await offline.enqueue([folder])
        try await eventually { await offlineLog.waiting() == 1 }
        await offline.stop()
        try await eventually { await offlineLog.records.values.first?.state == .failed }
    }
}
