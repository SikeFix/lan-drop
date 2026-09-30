import Foundation
import CryptoKit
import CommonCrypto
import Network

public enum LANError: Error, LocalizedError, Sendable {
    case notRunning
    case peerUnavailable
    case timeout
    case disconnected
    case authenticationFailed
    case invalidHandshake
    case invalidFrame
    case payloadTooLarge
    case duplicateConnection

    public var errorDescription: String? {
        switch self {
        case .notRunning: return "局域网服务尚未启动。"
        case .peerUnavailable: return "对方电脑暂时离线。"
        case .timeout: return "连接超时，请检查两台电脑是否连接同一局域网。"
        case .disconnected: return "连接已断开。"
        case .authenticationFailed: return "配对密码不一致，请在两台电脑上输入相同密码。"
        case .invalidHandshake: return "对方使用了不兼容的传输协议。"
        case .invalidFrame: return "收到的加密数据未通过完整性验证。"
        case .payloadTooLarge: return "传输数据块超过大小限制。"
        case .duplicateConnection: return "连接已存在。"
        }
    }
}

/// Protocol constants keep untrusted input bounded before allocation or decoding.
enum LANProtocol {
    static let version = 1
    static let serviceType = "_landrop._tcp"
    static let maxHelloBytes = 8_192
    static let maxPayloadBytes = 1_048_576
    static let maxFrameBytes = maxPayloadBytes + 17 + 16
    static let handshakeTimeout: TimeInterval = 12
    static let passwordIterations: UInt32 = 100_000

    static func tcpParameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 10
        tcp.keepaliveInterval = 3
        tcp.keepaliveCount = 3
        tcp.connectionTimeout = 8
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.includePeerToPeer = true
        return parameters
    }

    static func passwordKey(_ password: String) throws -> SymmetricKey {
        let input = Data(password.utf8)
        guard !input.isEmpty, input.count <= 4_096 else { throw LANError.invalidHandshake }
        let salt = Data("LanDrop authenticated pairing v1".utf8)
        var output = Data(count: 32)
        let status: Int32 = input.withUnsafeBytes { passwordBytes in
            salt.withUnsafeBytes { saltBytes in
                output.withUnsafeMutableBytes { outputBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBytes.baseAddress!.assumingMemoryBound(to: Int8.self),
                        input.count,
                        saltBytes.baseAddress!.assumingMemoryBound(to: UInt8.self),
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        passwordIterations,
                        outputBytes.baseAddress!.assumingMemoryBound(to: UInt8.self),
                        32
                    )
                }
            }
        }
        guard status == kCCSuccess else { throw LANError.invalidHandshake }
        return SymmetricKey(data: output)
    }

    static func transcript(client: Data, server: Data) -> Data {
        var result = Data("LanDrop handshake v1".utf8)
        result.appendBigEndian(UInt32(client.count))
        result.append(client)
        result.appendBigEndian(UInt32(server.count))
        result.append(server)
        return Data(SHA256.hash(data: result))
    }

    static func proof(transcript: Data, client: Bool, key: SymmetricKey) -> Data {
        var message = transcript
        message.append(client ? 0x01 : 0x02)
        return Data(HMAC<SHA256>.authenticationCode(for: message, using: key))
    }

    static func verifyProof(_ proof: Data, transcript: Data, client: Bool, key: SymmetricKey) -> Bool {
        var message = transcript
        message.append(client ? 0x01 : 0x02)
        return HMAC<SHA256>.isValidAuthenticationCode(proof, authenticating: message, using: key)
    }
}

struct HandshakeHello: Codable, Sendable {
    let version: Int
    let deviceID: UUID
    let name: String
    let initiator: Bool
    let publicKey: Data
    let nonce: Data

    func validate(expectedInitiator: Bool) throws {
        guard version == LANProtocol.version,
              initiator == expectedInitiator,
              publicKey.count == 32,
              nonce.count == 32,
              !name.isEmpty,
              name.utf8.count <= 256 else { throw LANError.invalidHandshake }
    }
}

/// Every direction has a distinct key and nonce prefix. Sequence numbers are implicit
/// in the ordered TCP stream and authenticated, so replay/reordering cannot succeed.
struct SessionCipher {
    private let key: SymmetricKey
    private let prefix: Data
    private(set) var sequence: UInt64 = 0

    init(key: SymmetricKey, noncePrefix: Data) {
        precondition(noncePrefix.count == 4)
        self.key = key
        self.prefix = noncePrefix
    }

    static func pair(sharedSecret: SharedSecret, passwordKey: SymmetricKey, transcript: Data, initiator: Bool) -> (send: SessionCipher, receive: SessionCipher) {
        let salt = passwordKey.withUnsafeBytes { Data($0) }
        let material = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: salt,
            sharedInfo: Data("LanDrop AES-GCM v1".utf8) + transcript,
            outputByteCount: 72
        ).withUnsafeBytes { Data($0) }
        let client = SessionCipher(key: SymmetricKey(data: material[0..<32]), noncePrefix: Data(material[64..<68]))
        let server = SessionCipher(key: SymmetricKey(data: material[32..<64]), noncePrefix: Data(material[68..<72]))
        return initiator ? (client, server) : (server, client)
    }

    mutating func seal(_ plaintext: Data) throws -> Data {
        guard plaintext.count <= LANProtocol.maxPayloadBytes + 17,
              sequence < UInt64.max else { throw LANError.payloadTooLarge }
        let (nonce, aad) = try context()
        let box = try AES.GCM.seal(plaintext, using: key, nonce: nonce, authenticating: aad)
        sequence += 1
        return box.ciphertext + box.tag
    }

    mutating func open(_ encrypted: Data) throws -> Data {
        guard encrypted.count >= 16,
              encrypted.count <= LANProtocol.maxFrameBytes,
              sequence < UInt64.max else { throw LANError.invalidFrame }
        let (nonce, aad) = try context()
        let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: encrypted.dropLast(16), tag: encrypted.suffix(16))
        do {
            let plain = try AES.GCM.open(box, using: key, authenticating: aad)
            sequence += 1
            return plain
        } catch {
            throw LANError.invalidFrame
        }
    }

    private func context() throws -> (AES.GCM.Nonce, Data) {
        var counter = Data()
        counter.appendBigEndian(sequence)
        var nonce = prefix
        nonce.append(counter)
        let aad = Data("LanDrop frame v1".utf8) + counter
        return (try AES.GCM.Nonce(data: nonce), aad)
    }
}

extension Data {
    mutating func appendBigEndian<T: FixedWidthInteger>(_ value: T) {
        var bigEndian = value.bigEndian
        Swift.withUnsafeBytes(of: &bigEndian) { append(contentsOf: $0) }
    }

    func uint32BigEndian() -> UInt32? {
        guard count == 4 else { return nil }
        return reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }
}
