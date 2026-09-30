import Foundation

/// An authenticated transfer still validates this untrusted metadata before creating a file.
public struct TransferOffer: Codable, Sendable, Equatable {
    public let id: UUID
    public let name: String
    public let size: Int64

    public init(id: UUID = UUID(), name: String, size: Int64) {
        self.id = id
        self.name = name
        self.size = size
    }
}

public enum ControlMessage: Codable, Sendable, Equatable {
    case offer(TransferOffer)
    case ready(UUID)
    case received(id: UUID, bytes: Int64)
    case finish(id: UUID, sha256: String)
    case complete(UUID)
    case reject(id: UUID, reason: String)
    case cancel(UUID)
}

public enum TransferLimits {
    public static let maximumFileSize: Int64 = 1_000_000_000_000
    public static let maximumPendingFiles = 8
    public static let maximumChunkSize = 1_048_576
}

public enum FileTransferError: LocalizedError, Equatable {
    case invalidName
    case invalidSize
    case tooManyTransfers
    case duplicateTransfer
    case unknownTransfer
    case chunkTooLarge
    case sizeMismatch
    case checksumMismatch
    case invalidSource
    case unsupportedFile
    case unreadableFile
    case archiveFailed(String)
    case filesystem(String)

    public var errorDescription: String? {
        switch self {
        case .invalidName: return "文件名称无效。"
        case .invalidSize: return "文件大小无效或超过 1 TB。"
        case .tooManyTransfers: return "正在接收的文件过多，请稍后再试。"
        case .duplicateTransfer: return "该文件已经在接收中。"
        case .unknownTransfer: return "找不到正在接收的文件。"
        case .chunkTooLarge: return "文件数据块过大。"
        case .sizeMismatch: return "收到的文件大小与发送信息不一致。"
        case .checksumMismatch: return "文件校验失败，请重新发送。"
        case .invalidSource: return "请选择本机上的文件或文件夹。"
        case .unsupportedFile: return "仅支持普通文件和文件夹，无法发送单独的符号链接。"
        case .unreadableFile: return "无法读取所选文件。"
        case .archiveFailed(let details): return "文件夹打包失败：\(details)"
        case .filesystem(let details): return "无法保存文件：\(details)"
        }
    }
}

/// Keep names in one directory and under the filesystem's 255-byte component limit.
enum TransferFileName {
    static func validateAndSanitize(_ name: String) throws -> String {
        guard !name.isEmpty, name.count <= 255,
              name != ".", name != "..",
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { throw FileTransferError.invalidName }

        var result = name.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        // Do not make received files invisible in Finder.
        while result.hasPrefix(".") { result.removeFirst() }
        guard !result.isEmpty else { throw FileTransferError.invalidName }
        result = truncate(result, maximumBytes: 255)
        guard !result.isEmpty else { throw FileTransferError.invalidName }
        return result
    }

    static func uniqueCandidate(_ name: String, index: Int) -> String {
        guard index > 0 else { return name }
        let suffix = " (\(index))"
        let ext = (name as NSString).pathExtension
        if !ext.isEmpty, ext.utf8.count < 100 {
            let stem = (name as NSString).deletingPathExtension
            return truncate(stem, maximumBytes: 255 - suffix.utf8.count - ext.utf8.count - 1)
                + suffix + "." + ext
        }
        return truncate(name, maximumBytes: 255 - suffix.utf8.count) + suffix
    }

    static func archiveName(_ name: String) -> String {
        truncate(name, maximumBytes: 251) + ".zip"
    }

    private static func truncate(_ value: String, maximumBytes: Int) -> String {
        var result = ""
        var byteCount = 0
        for character in value {
            let text = String(character)
            let nextCount = text.utf8.count
            guard byteCount + nextCount <= maximumBytes else { break }
            result += text
            byteCount += nextCount
        }
        return result
    }
}
