import Darwin
import Foundation

public struct PreparedFile: Sendable {
    public let url: URL
    public let name: String
    public let size: Int64
    public let isTemporary: Bool
    private let temporaryDirectory: URL?

    init(url: URL, name: String, size: Int64, temporaryDirectory: URL? = nil) {
        self.url = url
        self.name = name
        self.size = size
        self.temporaryDirectory = temporaryDirectory
        self.isTemporary = temporaryDirectory != nil
    }

    /// Removes only an archive created for this transfer; the user's source stays intact.
    public func cleanup() {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
    }
}

public enum FilePreparation {
    /// Directory packages and folders are sent as a ZIP; receivers retain the archive.
    public static func prepare(url: URL) async throws -> PreparedFile {
        let cancellation = PreparationCancellation()
        return try await withTaskCancellationHandler(operation: {
            let file = try await Task.detached(priority: .utility) {
                try prepareSynchronously(url: url, cancellation: cancellation)
            }.value
            if Task.isCancelled {
                file.cleanup()
                throw CancellationError()
            }
            return file
        }, onCancel: { cancellation.cancel() })
    }

    private static func prepareSynchronously(url: URL, cancellation: PreparationCancellation) throws -> PreparedFile {
        try cancellation.check()
        guard url.isFileURL else { throw FileTransferError.invalidSource }
        let source = url.standardizedFileURL
        var metadata = stat()
        guard Darwin.lstat(source.path, &metadata) == 0 else {
            throw FileTransferError.unreadableFile
        }
        let kind = metadata.st_mode & mode_t(S_IFMT)
        guard kind != mode_t(S_IFLNK) else { throw FileTransferError.unsupportedFile }
        let filename = try TransferFileName.validateAndSanitize(source.lastPathComponent)
        if kind == mode_t(S_IFREG) {
            let size = try regularFileSize(source)
            return PreparedFile(url: source, name: filename, size: size)
        }
        guard kind == mode_t(S_IFDIR) else { throw FileTransferError.unsupportedFile }
        guard FileManager.default.isReadableFile(atPath: source.path) else {
            throw FileTransferError.unreadableFile
        }

        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LanDrop-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        do {
            let archiveName = TransferFileName.archiveName(filename)
            let archiveURL = temporaryDirectory.appendingPathComponent(archiveName)
            let errorURL = temporaryDirectory.appendingPathComponent("ditto-stderr.log")
            FileManager.default.createFile(atPath: errorURL.path, contents: nil)
            let errorHandle = try FileHandle(forWritingTo: errorURL)
            defer { try? errorHandle.close() }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            process.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", source.path, archiveURL.path]
            process.standardOutput = FileHandle.nullDevice
            // File-backed stderr avoids the deadlock caused by a full pipe during waitUntilExit.
            process.standardError = errorHandle
            try cancellation.check()
            try process.run()
            cancellation.setProcess(process)
            defer { cancellation.setProcess(nil) }
            process.waitUntilExit()
            try cancellation.check()
            guard process.terminationStatus == 0 else {
                let errors = try? FileHandle(forReadingFrom: errorURL)
                let data = try? errors?.read(upToCount: 4096)
                try? errors?.close()
                let message = data.flatMap { String(data: $0, encoding: .utf8) }?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                throw FileTransferError.archiveFailed(message?.isEmpty == false ? message! : "无法生成 ZIP 文件。")
            }
            try? FileManager.default.removeItem(at: errorURL)
            let size = try regularFileSize(archiveURL)
            return PreparedFile(url: archiveURL, name: archiveName, size: size, temporaryDirectory: temporaryDirectory)
        } catch {
            try? FileManager.default.removeItem(at: temporaryDirectory)
            throw error
        }
    }

    private static func regularFileSize(_ url: URL) throws -> Int64 {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw FileTransferError.unreadableFile }
        defer { Darwin.close(descriptor) }
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0,
              metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            throw FileTransferError.unsupportedFile
        }
        let size = Int64(metadata.st_size)
        guard size >= 0, size <= TransferLimits.maximumFileSize else { throw FileTransferError.invalidSize }
        return size
    }
}

private final class PreparationCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var isCancelled = false
    private var process: Process?

    func check() throws {
        lock.lock()
        defer { lock.unlock() }
        if isCancelled { throw CancellationError() }
    }

    func setProcess(_ process: Process?) {
        lock.lock()
        defer { lock.unlock() }
        self.process = process
        if isCancelled, let process, process.isRunning { process.terminate() }
    }

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        isCancelled = true
        if let process, process.isRunning { process.terminate() }
    }
}
