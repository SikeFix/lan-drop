import CryptoKit
import Darwin
import Foundation

/// Streams verified bytes into hidden files. All operations are serialized internally.
/// Final files appear only after both the advertised size and SHA-256 have been checked.
public final class IncomingFileStore: @unchecked Sendable {
    private final class PendingFile {
        let offer: TransferOffer
        let filename: String
        let stagingName: String
        let handle: FileHandle
        var received: Int64 = 0
        var hash = SHA256()

        init(offer: TransferOffer, filename: String, stagingName: String, handle: FileHandle) {
            self.offer = offer
            self.filename = filename
            self.stagingName = stagingName
            self.handle = handle
        }
    }

    public let directory: URL
    private let directoryDescriptor: Int32
    private let lock = NSLock()
    private var pending: [UUID: PendingFile] = [:]

    public init(directory: URL) throws {
        guard directory.isFileURL else { throw FileTransferError.invalidSource }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let resolved = directory.standardizedFileURL.resolvingSymlinksInPath()
        let descriptor = Darwin.open(resolved.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw Self.filesystemError() }
        self.directory = resolved
        self.directoryDescriptor = descriptor
    }

    deinit {
        for file in pending.values {
            try? file.handle.close()
            Darwin.unlinkat(directoryDescriptor, file.stagingName, 0)
        }
        Darwin.close(directoryDescriptor)
    }

    @discardableResult
    public func begin(_ offer: TransferOffer) throws -> URL {
        lock.lock()
        defer { lock.unlock() }
        let filename = try TransferFileName.validateAndSanitize(offer.name)
        guard offer.size >= 0, offer.size <= TransferLimits.maximumFileSize else {
            throw FileTransferError.invalidSize
        }
        guard pending[offer.id] == nil else { throw FileTransferError.duplicateTransfer }
        guard pending.count < TransferLimits.maximumPendingFiles else {
            throw FileTransferError.tooManyTransfers
        }
        let stagingName = ".landrop-\(offer.id.uuidString)-\(UUID().uuidString).partial"
        let descriptor = Darwin.openat(
            directoryDescriptor, stagingName,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            mode_t(S_IRUSR | S_IWUSR)
        )
        guard descriptor >= 0 else { throw Self.filesystemError() }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        pending[offer.id] = PendingFile(
            offer: offer, filename: filename, stagingName: stagingName, handle: handle
        )
        return directory.appendingPathComponent(stagingName)
    }

    @discardableResult
    public func append(id: UUID, data: Data) throws -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        guard let file = pending[id] else { throw FileTransferError.unknownTransfer }
        do {
            guard data.count <= TransferLimits.maximumChunkSize else {
                throw FileTransferError.chunkTooLarge
            }
            guard Int64(data.count) <= file.offer.size - file.received else {
                throw FileTransferError.sizeMismatch
            }
            try file.handle.write(contentsOf: data)
            file.hash.update(data: data)
            file.received += Int64(data.count)
            return file.received
        } catch {
            discard(id: id)
            throw error
        }
    }

    @discardableResult
    public func finish(id: UUID, sha256: String) throws -> URL {
        lock.lock()
        defer { lock.unlock() }
        guard let file = pending[id] else { throw FileTransferError.unknownTransfer }
        do {
            guard file.received == file.offer.size else { throw FileTransferError.sizeMismatch }
            let computedHash = file.hash.finalize().map { String(format: "%02x", $0) }.joined()
            guard sha256.count == 64, computedHash == sha256.lowercased() else {
                throw FileTransferError.checksumMismatch
            }
            try file.handle.synchronize()
            try file.handle.close()

            // linkat is an exclusive, atomic commit on this same filesystem. Unlike a
            // check-then-rename sequence, it never overwrites a file created concurrently.
            for index in 0..<10_000 {
                let candidate = TransferFileName.uniqueCandidate(file.filename, index: index)
                if Darwin.linkat(directoryDescriptor, file.stagingName, directoryDescriptor, candidate, 0) == 0 {
                    Darwin.unlinkat(directoryDescriptor, file.stagingName, 0)
                    pending.removeValue(forKey: id)
                    return directory.appendingPathComponent(candidate)
                }
                guard errno == EEXIST else { throw Self.filesystemError() }
            }
            throw FileTransferError.filesystem("同名文件过多，请整理接收文件夹。")
        } catch {
            discard(id: id)
            throw error
        }
    }

    public func cancel(id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        discard(id: id)
    }

    public func cancelAll() {
        lock.lock()
        defer { lock.unlock() }
        for id in Array(pending.keys) { discard(id: id) }
    }

    private func discard(id: UUID) {
        guard let file = pending.removeValue(forKey: id) else { return }
        try? file.handle.close()
        Darwin.unlinkat(directoryDescriptor, file.stagingName, 0)
    }

    private static func filesystemError() -> FileTransferError {
        FileTransferError.filesystem(String(cString: strerror(errno)))
    }
}
