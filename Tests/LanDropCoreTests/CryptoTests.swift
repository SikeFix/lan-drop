import XCTest
import CryptoKit
@testable import LanDropCore

final class CryptoTests: XCTestCase {
    private func makeCiphers() throws -> (SessionCipher, SessionCipher, SessionCipher) {
        let first = Curve25519.KeyAgreement.PrivateKey()
        let second = Curve25519.KeyAgreement.PrivateKey()
        let secret = try first.sharedSecretFromKeyAgreement(with: second.publicKey)
        let otherSecret = try second.sharedSecretFromKeyAgreement(with: first.publicKey)
        let passwordKey = try LANProtocol.passwordKey("shared password 中文")
        let transcript = LANProtocol.transcript(client: Data([1, 2]), server: Data([3, 4]))
        let client = SessionCipher.pair(sharedSecret: secret, passwordKey: passwordKey, transcript: transcript, initiator: true)
        let server = SessionCipher.pair(sharedSecret: otherSecret, passwordKey: passwordKey, transcript: transcript, initiator: false)
        return (client.send, server.receive, client.receive)
    }

    func testAuthenticatedEncryptionAndSeparateDirections() throws {
        var (sender, receiver, wrongDirection) = try makeCiphers()
        let message = Data("a confidential LAN file".utf8)
        let encrypted = try sender.seal(message)
        XCTAssertFalse(encrypted.contains(message))
        XCTAssertEqual(try receiver.open(encrypted), message)
        XCTAssertThrowsError(try wrongDirection.open(encrypted))
        XCTAssertEqual(sender.sequence, 1)
        XCTAssertEqual(receiver.sequence, 1)
    }

    func testCipherRejectsTamperAndReplay() throws {
        var (sender, receiver, _) = try makeCiphers()
        let encrypted = try sender.seal(Data(repeating: 0x33, count: 4096))
        var corrupted = encrypted
        corrupted[corrupted.startIndex + 4] ^= 1
        XCTAssertThrowsError(try receiver.open(corrupted))
        XCTAssertEqual(receiver.sequence, 0, "Failed authentication must not advance the sequence")
        _ = try receiver.open(encrypted)
        XCTAssertThrowsError(try receiver.open(encrypted), "Replayed encrypted frame must fail")
    }

    func testCipherRejectsReorderedFrames() throws {
        var (sender, receiver, _) = try makeCiphers()
        let first = try sender.seal(Data([1]))
        let second = try sender.seal(Data([2]))
        XCTAssertThrowsError(try receiver.open(second))
        XCTAssertEqual(try receiver.open(first), Data([1]))
        XCTAssertEqual(try receiver.open(second), Data([2]))
    }

    func testPasswordProofBindsPasswordTranscriptAndRole() throws {
        let key = try LANProtocol.passwordKey("correct password")
        let wrong = try LANProtocol.passwordKey("wrong password")
        let transcript = LANProtocol.transcript(client: Data("client".utf8), server: Data("server".utf8))
        let proof = LANProtocol.proof(transcript: transcript, client: true, key: key)
        XCTAssertTrue(LANProtocol.verifyProof(proof, transcript: transcript, client: true, key: key))
        XCTAssertFalse(LANProtocol.verifyProof(proof, transcript: transcript, client: true, key: wrong))
        XCTAssertFalse(LANProtocol.verifyProof(proof, transcript: transcript, client: false, key: key))
        let modified = LANProtocol.transcript(client: Data("attacker".utf8), server: Data("server".utf8))
        XCTAssertFalse(LANProtocol.verifyProof(proof, transcript: modified, client: true, key: key))
    }

    func testBoundedCipherAndPasswordInputs() throws {
        var (sender, receiver, _) = try makeCiphers()
        XCTAssertThrowsError(try sender.seal(Data(count: LANProtocol.maxPayloadBytes + 18)))
        XCTAssertThrowsError(try receiver.open(Data(count: LANProtocol.maxFrameBytes + 1)))
        XCTAssertThrowsError(try receiver.open(Data(count: 15)))
        XCTAssertThrowsError(try LANProtocol.passwordKey(""))
        XCTAssertThrowsError(try LANProtocol.passwordKey(String(repeating: "x", count: 4097)))
    }
}
