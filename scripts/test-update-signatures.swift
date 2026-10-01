import CryptoKit
import Foundation

// A standalone regression for verify-update.swift. Keys are generated in memory
// for this run; only the public key and signed fixture bytes reach the temporary
// directory. This never opens Keychain or invokes Sparkle's signing tools.
struct SignatureTestError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct CommandResult {
    let status: Int32
    let output: String
}

func run(_ executable: URL, arguments: [String], in directory: URL) throws -> CommandResult {
    // File-backed output also keeps a failed compiler from filling a pipe.
    let logURL = directory.appendingPathComponent("command-\(UUID().uuidString).log")
    guard FileManager.default.createFile(atPath: logURL.path, contents: nil) else {
        throw SignatureTestError(message: "Unable to create command log.")
    }
    let log = try FileHandle(forWritingTo: logURL)
    defer { try? log.close() }
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    process.standardOutput = log
    process.standardError = log
    try process.run()
    process.waitUntilExit()
    let output = String(decoding: try Data(contentsOf: logURL), as: UTF8.self)
    return CommandResult(status: process.terminationStatus, output: output)
}

func publicKeyPlist(_ key: Curve25519.Signing.PublicKey) throws -> Data {
    try PropertyListSerialization.data(
        fromPropertyList: ["SUPublicEDKey": key.rawRepresentation.base64EncodedString()],
        format: .xml, options: 0)
}

func fixtureContent(archive: Data, key: Curve25519.Signing.PrivateKey,
                    archiveURL: URL, expectedLength: Int? = nil,
                    archiveSignature: Data? = nil) throws -> Data {
    let signature = try archiveSignature ?? key.signature(for: archive)
    // The earlier exact signing marker is ordinary, signed XML content. It
    // catches a verifier that accidentally chooses the first marker. UTF-8,
    // CRLF, and the final newline make byte counts differ from character counts.
    let content = "<?xml version=\"1.0\" encoding=\"utf-8\"?>\r\n" + """
    <!-- sparkle-signatures:
    fixture: this earlier comment is part of the signed XML
    -->
    <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
      <channel>
        <title>局域快传 — 临时更新验证</title>
        <item>
          <title>Fixture 1.2.3</title>
          <sparkle:version>123</sparkle:version>
          <enclosure url="\(archiveURL.absoluteString)" sparkle:edSignature="\(signature.base64EncodedString())" length="\(expectedLength ?? archive.count)" type="application/octet-stream" />
        </item>
      </channel>
    </rss>

    """
    return Data(content.utf8)
}

func signedFixture(_ content: Data, key: Curve25519.Signing.PrivateKey,
                   expectedLength: Int? = nil, crlfMetadata: Bool = false,
                   signature: Data? = nil) throws -> Data {
    let signature = try signature ?? key.signature(for: content)
    // Sparkle 2.10 common_cli/Signing.swift signs contentData first, then appends
    // this literal format. No production parsing or verifier code is reused.
    let footer: String
    if crlfMetadata {
        footer = "<!-- sparkle-signatures:\nedSignature:\t\(signature.base64EncodedString()) \r\nlength:\t\(expectedLength ?? content.count) \r\n-->\n"
    } else {
        footer = "<!-- sparkle-signatures:\nedSignature: \(signature.base64EncodedString())\nlength: \(expectedLength ?? content.count)\n-->\n"
    }
    return content + Data(footer.utf8)
}

do {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "landrop-update-signatures-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                           attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: directory) }

    let scriptURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
    let verifierURL = scriptURL.deletingLastPathComponent().appendingPathComponent("verify-update.swift")
    let binaryURL = directory.appendingPathComponent("verify-update")
    let compilation = try run(URL(fileURLWithPath: "/usr/bin/xcrun"),
        arguments: ["swiftc", "-swift-version", "5", verifierURL.path, "-o", binaryURL.path], in: directory)
    guard compilation.status == 0 else {
        throw SignatureTestError(message: "Verifier did not compile:\n\(compilation.output)")
    }

    let key = Curve25519.Signing.PrivateKey()
    let wrongKey = Curve25519.Signing.PrivateKey()
    let plist = try publicKeyPlist(key.publicKey)
    let wrongPlist = try publicKeyPlist(wrongKey.publicKey)
    let archive = Data((0..<257).map { UInt8($0 % 256) })
    let archiveName = "fixture 局域快传.zip"
    let archiveDownloadURL = URL(string: "https://example.invalid/releases/download/test/")!
        .appendingPathComponent(archiveName)
    let content = try fixtureContent(archive: archive, key: key, archiveURL: archiveDownloadURL)
    let feed = try signedFixture(content, key: key)
    let plistURL = directory.appendingPathComponent("Info.plist")
    let feedURL = directory.appendingPathComponent("appcast.xml")
    let archiveURL = directory.appendingPathComponent(archiveName)
    var passed = 0

    func expect(_ name: String, feed candidateFeed: Data = feed,
                archive candidateArchive: Data = archive, plist candidatePlist: Data = plist,
                succeeds: Bool, diagnostic: String? = nil) throws {
        try candidatePlist.write(to: plistURL)
        try candidateFeed.write(to: feedURL)
        try candidateArchive.write(to: archiveURL)
        let result = try run(binaryURL, arguments: [plistURL.path, feedURL.path, archiveURL.path], in: directory)
        guard result.status == (succeeds ? 0 : 1),
              diagnostic.map({ result.output.contains($0) }) ?? true else {
            throw SignatureTestError(message: "FAIL \(name): exit \(result.status)\n\(result.output)")
        }
        passed += 1
        print("PASS \(name)")
    }

    try expect("valid feed and archive, UTF-8 byte lengths, final signing marker", succeeds: true)
    try expect("CRLF and surrounding whitespace in signing fields",
               feed: signedFixture(content, key: key, crlfMetadata: true), succeeds: true)
    // SPUExtractSignedFeed.m intentionally discards the signing block and all
    // later bytes. Matching that boundary means trailing whitespace is valid.
    try expect("Sparkle-compatible unsigned trailing whitespace",
               feed: feed + Data(" \r\n\t".utf8), succeeds: true)

    for index in [0, archive.count / 2, archive.count - 1] {
        var modifiedArchive = archive
        modifiedArchive[index] ^= 1
        try expect("archive one-byte mutation at \(index)", archive: modifiedArchive,
                   succeeds: false, diagnostic: "安装包签名验证失败")
    }
    for index in [0, content.count / 2, content.count - 1] {
        var modifiedFeed = feed
        modifiedFeed[index] ^= 1
        try expect("signed feed one-byte mutation at \(index)", feed: modifiedFeed,
                   succeeds: false, diagnostic: "更新目录签名验证失败")
    }
    try expect("wrong public key", plist: wrongPlist,
               succeeds: false, diagnostic: "更新目录签名验证失败")
    try expect("wrong signed feed length",
               feed: signedFixture(content, key: key, expectedLength: content.count + 1),
               succeeds: false, diagnostic: "更新目录签名验证失败")

    var modifiedFeedSignature = try key.signature(for: content)
    modifiedFeedSignature[0] ^= 1
    try expect("damaged feed signature",
               feed: signedFixture(content, key: key, signature: modifiedFeedSignature),
               succeeds: false, diagnostic: "更新目录签名验证失败")
    let wrongArchiveLength = try fixtureContent(archive: archive, key: key,
        archiveURL: archiveDownloadURL, expectedLength: archive.count + 1)
    try expect("valid signed feed with wrong archive length",
               feed: signedFixture(wrongArchiveLength, key: key),
               succeeds: false, diagnostic: "安装包签名验证失败")
    let wrongArchiveSignature = try fixtureContent(archive: archive, key: key,
        archiveURL: archiveDownloadURL, archiveSignature: wrongKey.signature(for: archive))
    try expect("valid signed feed with archive signed by wrong key",
               feed: signedFixture(wrongArchiveSignature, key: key),
               succeeds: false, diagnostic: "安装包签名验证失败")
    try expect("missing final signature", feed: content,
               succeeds: false, diagnostic: "更新目录签名验证失败")

    print("Update signature regression passed: \(passed) cases; no Keychain access.")
} catch {
    fputs("\(error.localizedDescription)\n", stderr)
    exit(1)
}
