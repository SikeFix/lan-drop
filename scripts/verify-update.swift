import CryptoKit
import Foundation

// Verify public release assets without reading the publisher's private Keychain
// key. The signed byte boundary follows Sparkle 2.10's SPUExtractSignedFeed.
struct VerificationError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

final class EnclosureParser: NSObject, XMLParserDelegate {
    var enclosures: [[String: String]] = []
    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String]) {
        if elementName == "enclosure" { enclosures.append(attributeDict) }
    }
}

func verify(plistPath: String, feedPath: String, archivePath: String) throws {
    let plistData = try Data(contentsOf: URL(fileURLWithPath: plistPath))
    guard let plist = try PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any],
          let keyString = plist["SUPublicEDKey"] as? String,
          let keyData = Data(base64Encoded: keyString), keyData.count == 32 else {
        throw VerificationError(message: "应用缺少有效的更新公钥。")
    }
    let key = try Curve25519.Signing.PublicKey(rawRepresentation: keyData)
    let feed = try Data(contentsOf: URL(fileURLWithPath: feedPath))
    let prefix = Data("<!-- sparkle-signatures:\n".utf8)
    guard let start = feed.range(of: prefix, options: .backwards),
          let end = feed.range(of: Data("-->".utf8), in: start.upperBound..<feed.endIndex),
          let metadata = String(data: feed[start.upperBound..<end.lowerBound], encoding: .utf8) else {
        throw VerificationError(message: "更新目录缺少签名。")
    }
    var fields: [String: String] = [:]
    for line in metadata.split(whereSeparator: \.isNewline) {
        guard let colon = line.firstIndex(of: ":") else { continue }
        let name = String(line[..<colon])
        guard fields[name] == nil else { throw VerificationError(message: "更新目录签名字段重复。") }
        fields[name] = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
    }
    let content = Data(feed[..<start.lowerBound])
    guard let encodedSignature = fields["edSignature"],
          let feedSignature = Data(base64Encoded: encodedSignature), feedSignature.count == 64,
          let encodedLength = fields["length"], let feedLength = UInt64(encodedLength),
          feedLength == UInt64(content.count), key.isValidSignature(feedSignature, for: content) else {
        throw VerificationError(message: "更新目录签名验证失败。")
    }
    let delegate = EnclosureParser()
    let parser = XMLParser(data: content)
    parser.shouldResolveExternalEntities = false
    parser.delegate = delegate
    guard parser.parse() else { throw VerificationError(message: "更新目录 XML 无效。") }
    let archiveURL = URL(fileURLWithPath: archivePath)
    let matches = delegate.enclosures.filter {
        guard let rawURL = $0["url"], let url = URL(string: rawURL) else { return false }
        return url.lastPathComponent == archiveURL.lastPathComponent
    }
    guard matches.count == 1, let enclosure = matches.first,
          let rawSignature = enclosure["sparkle:edSignature"],
          let archiveSignature = Data(base64Encoded: rawSignature), archiveSignature.count == 64,
          let rawLength = enclosure["length"], let expectedLength = UInt64(rawLength) else {
        throw VerificationError(message: "更新目录未包含唯一匹配的安装包。")
    }
    let archive = try Data(contentsOf: archiveURL, options: .mappedIfSafe)
    guard expectedLength == UInt64(archive.count), key.isValidSignature(archiveSignature, for: archive) else {
        throw VerificationError(message: "安装包签名验证失败。")
    }
    print("已验证更新目录和安装包的 Ed25519 签名：\(archiveURL.lastPathComponent)")
}

do {
    guard CommandLine.arguments.count == 4 else {
        throw VerificationError(message: "用法：swift scripts/verify-update.swift Info.plist appcast.xml 安装包.zip")
    }
    try verify(plistPath: CommandLine.arguments[1], feedPath: CommandLine.arguments[2], archivePath: CommandLine.arguments[3])
} catch {
    fputs("\(error.localizedDescription)\n", stderr)
    exit(1)
}
