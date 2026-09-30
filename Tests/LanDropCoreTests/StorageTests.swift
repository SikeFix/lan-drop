import CryptoKit
import Foundation
import XCTest
@testable import LanDropCore

final class StorageTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("LanDropStorageTests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func files(_ directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
    }

    private func receive(_ data: Data, name: String, store: IncomingFileStore) throws -> URL {
        let offer = TransferOffer(name: name, size: Int64(data.count))
        try store.begin(offer)
        try store.append(id: offer.id, data: data)
        return try store.finish(id: offer.id, sha256: digest(data))
    }

    func testStreamingReceiveIsHiddenUntilVerifiedAndKeepsExactBytes() throws {
        let store = try IncomingFileStore(directory: root.appendingPathComponent("received"))
        let first = Data(repeating: 0x01, count: 200_000)
        let second = Data(repeating: 0xfe, count: 170_000)
        let offer = TransferOffer(name: "照片.bin", size: Int64(first.count + second.count))
        let staging = try store.begin(offer)
        XCTAssertTrue(staging.lastPathComponent.hasPrefix("."))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.directory.appendingPathComponent("照片.bin").path))
        XCTAssertEqual(try store.append(id: offer.id, data: first), 200_000)
        XCTAssertEqual(try store.append(id: offer.id, data: second), 370_000)
        let allData = first + second
        let destination = try store.finish(id: offer.id, sha256: digest(allData))
        XCTAssertEqual(try Data(contentsOf: destination), allData)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
        XCTAssertEqual(try files(store.directory).map { $0.lastPathComponent }, [destination.lastPathComponent])
    }

    func testPathTraversalNamesCannotEscapeDestination() throws {
        let store = try IncomingFileStore(directory: root.appendingPathComponent("received"))
        for name in ["../outside.txt", "/tmp/outside.txt", "..\\outside.txt", "foo/bar.txt"] {
            let destination = try receive(Data("safe".utf8), name: name, store: store)
            XCTAssertEqual(destination.deletingLastPathComponent(), store.directory)
            XCTAssertFalse(destination.lastPathComponent.contains("/"))
            XCTAssertFalse(destination.lastPathComponent.contains("\\"))
            XCTAssertFalse(destination.lastPathComponent.hasPrefix("."))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("outside.txt").path))
        for name in ["", ".", "..", "bad\0name", String(repeating: "a", count: 256)] {
            XCTAssertThrowsError(try store.begin(TransferOffer(name: name, size: 0)))
        }
    }

    func testEmptyFileAndDuplicateNamesNeverOverwriteExistingFile() throws {
        let store = try IncomingFileStore(directory: root)
        let original = root.appendingPathComponent("report.txt")
        try Data("keep original".utf8).write(to: original)
        let received = try receive(Data(), name: "report.txt", store: store)
        XCTAssertEqual(received.lastPathComponent, "report (1).txt")
        XCTAssertEqual(try Data(contentsOf: original), Data("keep original".utf8))
        XCTAssertEqual(try Data(contentsOf: received), Data())

        let next = try receive(Data("new".utf8), name: "report.txt", store: store)
        XCTAssertEqual(next.lastPathComponent, "report (2).txt")
        XCTAssertEqual(try Data(contentsOf: received), Data())
    }

    func testExistingSymlinkIsNeverFollowedOrOverwritten() throws {
        let destination = root.appendingPathComponent("receive")
        let store = try IncomingFileStore(directory: destination)
        let original = root.appendingPathComponent("original.txt")
        try Data("original".utf8).write(to: original)
        try FileManager.default.createSymbolicLink(at: destination.appendingPathComponent("target.txt"), withDestinationURL: original)
        let received = try receive(Data("new".utf8), name: "target.txt", store: store)
        XCTAssertEqual(received.lastPathComponent, "target (1).txt")
        XCTAssertEqual(try Data(contentsOf: original), Data("original".utf8))
    }

    func testWrongChecksumAndTruncatedFileAreRemoved() throws {
        let store = try IncomingFileStore(directory: root)
        let corrupt = TransferOffer(name: "corrupt.txt", size: 3)
        let staging = try store.begin(corrupt)
        try store.append(id: corrupt.id, data: Data("abc".utf8))
        XCTAssertThrowsError(try store.finish(id: corrupt.id, sha256: String(repeating: "0", count: 64))) { error in
            XCTAssertEqual(error as? FileTransferError, .checksumMismatch)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
        XCTAssertTrue(try files(root).isEmpty)

        let truncated = TransferOffer(name: "truncated.txt", size: 10)
        try store.begin(truncated)
        try store.append(id: truncated.id, data: Data("abc".utf8))
        XCTAssertThrowsError(try store.finish(id: truncated.id, sha256: digest(Data("abc".utf8)))) { error in
            XCTAssertEqual(error as? FileTransferError, .sizeMismatch)
        }
        XCTAssertTrue(try files(root).isEmpty)
    }

    func testExcessBytesAndOversizedChunksCancelReceive() throws {
        let store = try IncomingFileStore(directory: root)
        let short = TransferOffer(name: "short.txt", size: 1)
        try store.begin(short)
        XCTAssertThrowsError(try store.append(id: short.id, data: Data([1, 2]))) { error in
            XCTAssertEqual(error as? FileTransferError, .sizeMismatch)
        }
        XCTAssertTrue(try files(root).isEmpty)
        let oversized = TransferOffer(name: "large.bin", size: 2_000_000)
        try store.begin(oversized)
        XCTAssertThrowsError(try store.append(id: oversized.id, data: Data(count: TransferLimits.maximumChunkSize + 1))) { error in
            XCTAssertEqual(error as? FileTransferError, .chunkTooLarge)
        }
        XCTAssertTrue(try files(root).isEmpty)
    }

    func testOfferLimitsDuplicateIDsAndCancellationCleanup() throws {
        let store = try IncomingFileStore(directory: root)
        XCTAssertThrowsError(try store.begin(TransferOffer(name: "negative", size: -1)))
        XCTAssertThrowsError(try store.begin(TransferOffer(name: "huge", size: TransferLimits.maximumFileSize + 1)))
        var offers: [TransferOffer] = []
        for index in 0..<TransferLimits.maximumPendingFiles {
            let offer = TransferOffer(name: "file\(index)", size: 10)
            try store.begin(offer)
            offers.append(offer)
        }
        XCTAssertThrowsError(try store.begin(offers[0])) { error in
            XCTAssertEqual(error as? FileTransferError, .duplicateTransfer)
        }
        XCTAssertThrowsError(try store.begin(TransferOffer(name: "one too many", size: 0))) { error in
            XCTAssertEqual(error as? FileTransferError, .tooManyTransfers)
        }
        store.cancel(id: offers[0].id)
        XCTAssertEqual(try files(root).count, TransferLimits.maximumPendingFiles - 1)
        try store.begin(TransferOffer(name: "new", size: 0))
        store.cancelAll()
        XCTAssertTrue(try files(root).isEmpty)
        XCTAssertThrowsError(try store.append(id: offers[0].id, data: Data()))
    }

    func testDeinitializationRemovesUnfinishedFiles() throws {
        var store: IncomingFileStore? = try IncomingFileStore(directory: root)
        try store?.begin(TransferOffer(name: "unfinished", size: 100))
        XCTAssertEqual(try files(root).count, 1)
        store = nil
        XCTAssertTrue(try files(root).isEmpty)
    }

    func testLongUnicodeNamesRemainUsableWhenRenamed() throws {
        let store = try IncomingFileStore(directory: root)
        let name = String(repeating: "文", count: 200) + ".txt"
        let first = try receive(Data(), name: name, store: store)
        let second = try receive(Data(), name: name, store: store)
        XCTAssertLessThanOrEqual(first.lastPathComponent.utf8.count, 255)
        XCTAssertLessThanOrEqual(second.lastPathComponent.utf8.count, 255)
        XCTAssertNotEqual(first, second)
    }

    func testPrepareRegularFileDoesNotRemoveSourceAndRejectsStandaloneSymlink() async throws {
        let source = root.appendingPathComponent("source.txt")
        try Data("hello".utf8).write(to: source)
        let prepared = try await FilePreparation.prepare(url: source)
        XCTAssertFalse(prepared.isTemporary)
        XCTAssertEqual(prepared.size, 5)
        prepared.cleanup()
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: source)
        do {
            _ = try await FilePreparation.prepare(url: alias)
            XCTFail("A standalone symlink must not be sent as its target")
        } catch {
            XCTAssertEqual(error as? FileTransferError, .unsupportedFile)
        }
    }

    func testPrepareDirectoryBuildsArchiveAndCleansOnlyTemporaryFiles() async throws {
        let folder = root.appendingPathComponent("资料", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        try Data("hello".utf8).write(to: folder.appendingPathComponent("file.txt"))
        let prepared = try await FilePreparation.prepare(url: folder)
        XCTAssertTrue(prepared.isTemporary)
        XCTAssertEqual(prepared.name, "资料.zip")
        XCTAssertGreaterThan(prepared.size, 0)
        let signature = try Data(contentsOf: prepared.url).prefix(4)
        XCTAssertEqual(Array(signature), [0x50, 0x4b, 0x03, 0x04])
        let archive = prepared.url
        prepared.cleanup()
        XCTAssertFalse(FileManager.default.fileExists(atPath: archive.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("file.txt").path))
    }

    func testCancelledPreparationDoesNotRemoveSource() async throws {
        let folder = root.appendingPathComponent("cancelled", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let source = folder.appendingPathComponent("file.txt")
        try Data("keep".utf8).write(to: source)
        let task = Task { try await FilePreparation.prepare(url: folder) }
        task.cancel()
        do {
            let prepared = try await task.value
            prepared.cleanup()
            XCTFail("Cancelled preparation must throw")
        } catch is CancellationError {
            XCTAssertEqual(try Data(contentsOf: source), Data("keep".utf8))
        }
    }
}
