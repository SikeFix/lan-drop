import Foundation
import Network
import CryptoKit
import Security

/// Callback-based Network.framework operations can outlive a cancelled Swift task.
/// A locked one-shot completion gives every operation an actual deadline and makes
/// late framework callbacks harmless.
final class NetworkCompletion<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?

    init(_ continuation: CheckedContinuation<Value, Error>) { self.continuation = continuation }

    func finish(_ result: Result<Value, Error>) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(with: result)
    }
}

final class ConnectionIO: @unchecked Sendable {
    let connection: NWConnection
    private let queue = DispatchQueue(label: "LanDrop.connection", qos: .userInitiated)

    init(_ connection: NWConnection) { self.connection = connection }

    func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let completion = NetworkCompletion(continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: completion.finish(.success(()))
                case .failed(let error): completion.finish(.failure(error))
                case .cancelled: completion.finish(.failure(LANError.disconnected))
                default: break
                }
            }
            queue.asyncAfter(deadline: .now() + LANProtocol.handshakeTimeout) { [connection] in
                // Cancelling only on a still-pending timeout is essential: a connection
                // that became ready must remain alive after its deadline fires.
                completion.finishIfPending(.failure(LANError.timeout)) { connection.cancel() }
            }
            connection.start(queue: queue)
        }
    }

    func write(_ data: Data, timeout: TimeInterval? = 30) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let completion = NetworkCompletion(continuation)
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { completion.finish(.failure(error)) }
                else { completion.finish(.success(())) }
            })
            if let timeout {
                queue.asyncAfter(deadline: .now() + timeout) { [connection] in
                    completion.finishIfPending(.failure(LANError.timeout)) { connection.cancel() }
                }
            }
        }
    }

    func readExactly(_ count: Int, timeout: TimeInterval?) async throws -> Data {
        guard count > 0 else { return Data() }
        var result = Data()
        while result.count < count {
            let remaining = count - result.count
            let part: Data = try await withCheckedThrowingContinuation { continuation in
                let completion = NetworkCompletion(continuation)
                connection.receive(minimumIncompleteLength: 1, maximumLength: remaining) { content, _, complete, error in
                    if let error { completion.finish(.failure(error)) }
                    else if let content, !content.isEmpty { completion.finish(.success(content)) }
                    else if complete { completion.finish(.failure(LANError.disconnected)) }
                    else { completion.finish(.failure(LANError.invalidFrame)) }
                }
                if let timeout {
                    queue.asyncAfter(deadline: .now() + timeout) { [connection] in
                        completion.finishIfPending(.failure(LANError.timeout)) { connection.cancel() }
                    }
                }
            }
            result.append(part)
        }
        return result
    }

    func writeFrame(_ data: Data, timeout: TimeInterval? = 30) async throws {
        var framed = Data()
        framed.appendBigEndian(UInt32(data.count))
        framed.append(data)
        try await write(framed, timeout: timeout)
    }

    func readFrame(maximum: Int, timeout: TimeInterval?) async throws -> Data {
        let header = try await readExactly(4, timeout: timeout)
        guard let length = header.uint32BigEndian(), length > 0, length <= maximum else { throw LANError.invalidFrame }
        return try await readExactly(Int(length), timeout: timeout)
    }

    func cancel() { connection.cancel() }
}

extension NetworkCompletion {
    func finishIfPending(_ result: Result<Value, Error>, beforeResume: () -> Void) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        if let pending {
            beforeResume()
            pending.resume(with: result)
        }
    }
}

struct SessionIdentity: Sendable {
    let peer: Peer
    let tieBreaker: Data
}

actor ConnectionSession {
    nonisolated let id = UUID()
    nonisolated let initiator: Bool
    private let io: ConnectionIO
    private var sendCipher: SessionCipher?
    private var receiveCipher: SessionCipher?
    private var closed = false
    private struct PendingSend {
        let packet: WirePacket
        let continuation: CheckedContinuation<Void, Error>
    }
    private var pendingSends: [PendingSend] = []
    private var sending = false

    init(connection: NWConnection, initiator: Bool) {
        self.io = ConnectionIO(connection)
        self.initiator = initiator
    }

    func establish(deviceID: UUID, name: String, passwordKey: SymmetricKey, expectedPeerID: UUID?) async throws -> SessionIdentity {
        try await io.start()
        let watchdog = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(LANProtocol.handshakeTimeout * 1_000_000_000))
                await self?.close()
            } catch { }
        }
        defer { watchdog.cancel() }
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        var nonce = Data(count: 32)
        let randomResult = nonce.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        guard randomResult == errSecSuccess else { throw LANError.invalidHandshake }
        let local = HandshakeHello(version: LANProtocol.version, deviceID: deviceID, name: name, initiator: initiator,
                                   publicKey: privateKey.publicKey.rawRepresentation, nonce: nonce)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let localBytes = try encoder.encode(local)
        try await io.writeFrame(localBytes, timeout: LANProtocol.handshakeTimeout)
        let remoteBytes = try await io.readFrame(maximum: LANProtocol.maxHelloBytes, timeout: LANProtocol.handshakeTimeout)
        let remote = try JSONDecoder().decode(HandshakeHello.self, from: remoteBytes)
        try remote.validate(expectedInitiator: !initiator)
        guard remote.deviceID != deviceID,
              expectedPeerID == nil || expectedPeerID == remote.deviceID else { throw LANError.invalidHandshake }
        let transcript = initiator ? LANProtocol.transcript(client: localBytes, server: remoteBytes)
                                   : LANProtocol.transcript(client: remoteBytes, server: localBytes)
        let proof = LANProtocol.proof(transcript: transcript, client: initiator, key: passwordKey)
        try await io.writeFrame(proof, timeout: LANProtocol.handshakeTimeout)
        let remoteProof = try await io.readFrame(maximum: 32, timeout: LANProtocol.handshakeTimeout)
        guard LANProtocol.verifyProof(remoteProof, transcript: transcript, client: !initiator, key: passwordKey) else {
            throw LANError.authenticationFailed
        }
        let remoteKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: remote.publicKey)
        let sharedSecret = try privateKey.sharedSecretFromKeyAgreement(with: remoteKey)
        let pair = SessionCipher.pair(sharedSecret: sharedSecret, passwordKey: passwordKey, transcript: transcript, initiator: initiator)
        sendCipher = pair.send
        receiveCipher = pair.receive
        // Confirm that both sides possess the session keys before announcing a peer.
        let confirmation = try encrypt(Data([0x7f]))
        try await io.writeFrame(confirmation, timeout: LANProtocol.handshakeTimeout)
        let remoteConfirmation = try await io.readFrame(maximum: LANProtocol.maxFrameBytes, timeout: LANProtocol.handshakeTimeout)
        guard try decrypt(remoteConfirmation) == Data([0x7f]) else { throw LANError.invalidHandshake }
        return SessionIdentity(peer: Peer(id: remote.deviceID, name: remote.name), tieBreaker: initiator ? local.nonce : remote.nonce)
    }

    func readPacket() async throws -> WirePacket {
        guard !closed else { throw LANError.disconnected }
        let encrypted = try await io.readFrame(maximum: LANProtocol.maxFrameBytes, timeout: nil)
        let plain = try decrypt(encrypted)
        guard let kind = plain.first else { throw LANError.invalidFrame }
        switch kind {
        case 0:
            guard plain.count - 1 <= LANProtocol.maxPayloadBytes else { throw LANError.invalidFrame }
            return .control(Data(plain.dropFirst()))
        case 1:
            guard plain.count >= 17, plain.count - 17 <= LANProtocol.maxPayloadBytes else { throw LANError.invalidFrame }
            let bytes = [UInt8](plain[1..<17])
            let tuple: uuid_t = (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                                 bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15])
            return .chunk(transferID: UUID(uuid: tuple), data: Data(plain.dropFirst(17)))
        default: throw LANError.invalidFrame
        }
    }

    /// Reentrancy during Network.framework's asynchronous send must never let the
    /// next caller seal/send before the previous one. One drain owns the queue.
    func send(_ packet: WirePacket) async throws {
        guard !closed else { throw LANError.disconnected }
        try await withCheckedThrowingContinuation { continuation in
            pendingSends.append(PendingSend(packet: packet, continuation: continuation))
            if !sending {
                sending = true
                Task { await drainSends() }
            }
        }
    }

    private func drainSends() async {
        while !pendingSends.isEmpty {
            let pending = pendingSends.removeFirst()
            do {
                guard !closed else { throw LANError.disconnected }
                let plain = try serialize(pending.packet)
                let encrypted = try encrypt(plain)
                try await io.writeFrame(encrypted)
                pending.continuation.resume()
            } catch {
                pending.continuation.resume(throwing: error)
                close()
            }
        }
        sending = false
    }

    func close() {
        guard !closed else { return }
        closed = true
        io.cancel()
        let queued = pendingSends
        pendingSends.removeAll()
        for pending in queued { pending.continuation.resume(throwing: LANError.disconnected) }
    }

    private func serialize(_ packet: WirePacket) throws -> Data {
        switch packet {
        case .control(let data):
            guard data.count <= LANProtocol.maxPayloadBytes else { throw LANError.payloadTooLarge }
            return Data([0]) + data
        case .chunk(let transferID, let data):
            guard data.count <= LANProtocol.maxPayloadBytes else { throw LANError.payloadTooLarge }
            var result = Data([1])
            var value = transferID.uuid
            withUnsafeBytes(of: &value) { result.append(contentsOf: $0) }
            result.append(data)
            return result
        }
    }

    private func encrypt(_ plain: Data) throws -> Data {
        guard var cipher = sendCipher else { throw LANError.invalidHandshake }
        let encrypted = try cipher.seal(plain)
        sendCipher = cipher
        return encrypted
    }

    private func decrypt(_ encrypted: Data) throws -> Data {
        guard var cipher = receiveCipher else { throw LANError.invalidHandshake }
        let plain = try cipher.open(encrypted)
        receiveCipher = cipher
        return plain
    }
}
