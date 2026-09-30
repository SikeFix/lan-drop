import XCTest
@testable import LanDropCore

private actor ReceivedPackets {
    private var controls: [Data] = []
    private var chunks: [(UUID, Data)] = []

    func append(_ packet: WirePacket) -> Int {
        switch packet {
        case .control(let data): controls.append(data)
        case .chunk(let id, let data): chunks.append((id, data))
        }
        return controls.count + chunks.count
    }

    func snapshots() -> ([Data], [(UUID, Data)]) { (controls, chunks) }
}

private actor BonjourProbe {
    private var connections: [UUID: Int] = [:]
    private var disconnections: [UUID: Int] = [:]
    private var statuses: [String] = []

    func record(_ event: LANEvent) {
        switch event {
        case .peerConnected(let peer): connections[peer.id, default: 0] += 1
        case .peerDisconnected(let id): disconnections[id, default: 0] += 1
        case .status(let status): statuses.append(status)
        default: break
        }
    }

    func connected(_ id: UUID) -> Int { connections[id, default: 0] }
    func disconnected(_ id: UUID) -> Int { disconnections[id, default: 0] }
    func messages() -> String { statuses.joined(separator: "\n") }
}

final class NetworkTests: XCTestCase {
    private let clientID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let serverID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!

    private func eventually(timeout: TimeInterval, condition: () async -> Bool) async throws -> Bool {
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(timeout * 1_000_000_000)
        repeat {
            if await condition() { return true }
            try await Task.sleep(nanoseconds: 50_000_000)
        } while DispatchTime.now().uptimeNanoseconds < deadline
        return await condition()
    }

    func testBonjourAutomaticallyDiscoversAndReconnectsAfterPeerRestart() async throws {
        let ids = [UUID(), UUID()].sorted { $0.uuidString < $1.uuidString }
        let lowerID = ids[0]
        let upperID = ids[1]
        let password = UUID().uuidString
        let lower = LANService()
        let upper = LANService()
        let restartedUpper = LANService()
        let lowerProbe = BonjourProbe()
        let upperProbe = BonjourProbe()
        let restartedProbe = BonjourProbe()
        let lowerEvents = Task { for await event in lower.events { await lowerProbe.record(event) } }
        let upperEvents = Task { for await event in upper.events { await upperProbe.record(event) } }
        let restartedEvents = Task { for await event in restartedUpper.events { await restartedProbe.record(event) } }
        defer {
            lowerEvents.cancel()
            upperEvents.cancel()
            restartedEvents.cancel()
            lower.stop()
            upper.stop()
            restartedUpper.stop()
        }
        try await lower.start(deviceID: lowerID, name: "Bonjour Lower Mac", password: password)
        try await upper.start(deviceID: upperID, name: "Bonjour Upper Mac", password: password)
        let automaticallyConnected = try await eventually(timeout: 10) {
            let lowerCount = await lowerProbe.connected(upperID)
            let upperCount = await upperProbe.connected(lowerID)
            return lowerCount == 1 && upperCount == 1
        }
        if !automaticallyConnected {
            let messages = await lowerProbe.messages() + "\n" + upperProbe.messages()
            if messages.contains("NoAuth") || messages.contains("PolicyDenied") || messages.contains("-65555") || messages.contains("-65570") {
                throw XCTSkip("This host denied local-network/mDNS access: \(messages)")
            }
            XCTFail("Bonjour must connect both peers automatically. Status: \(messages)")
            return
        }
        upper.stop()
        let observedDisconnect = try await eventually(timeout: 5) { await lowerProbe.disconnected(upperID) == 1 }
        XCTAssertTrue(observedDisconnect)
        try await restartedUpper.start(deviceID: upperID, name: "Bonjour Upper Mac", password: password)
        let automaticallyReconnected = try await eventually(timeout: 10) {
            let lowerCount = await lowerProbe.connected(upperID)
            let upperCount = await restartedProbe.connected(lowerID)
            return lowerCount == 2 && upperCount == 1
        }
        XCTAssertTrue(automaticallyReconnected, "The same paired device must reconnect without any user action")
    }

    func testLoopbackAuthenticationAndConcurrentBidirectionalStreaming() async throws {
        let client = LANService(discoveryEnabled: false)
        let server = LANService(discoveryEnabled: false)
        let clientConnected = expectation(description: "client authenticated server")
        let serverConnected = expectation(description: "server authenticated client")
        let clientReceived = expectation(description: "client received all packets")
        let serverReceived = expectation(description: "server received all packets")
        let disconnected = expectation(description: "client observed disconnect")
        let clientPackets = ReceivedPackets()
        let serverPackets = ReceivedPackets()
        let packetCount = 33
        let clientEvents = Task {
            for await event in client.events {
                switch event {
                case .peerConnected(let peer):
                    XCTAssertEqual(peer.id, self.serverID)
                    XCTAssertEqual(peer.name, "Server Mac")
                    clientConnected.fulfill()
                case .packet(_, let packet):
                    if await clientPackets.append(packet) == packetCount { clientReceived.fulfill() }
                case .peerDisconnected: disconnected.fulfill()
                case .authenticationFailed: XCTFail("Matching password must authenticate")
                default: break
                }
            }
        }
        let serverEvents = Task {
            for await event in server.events {
                switch event {
                case .peerConnected(let peer):
                    XCTAssertEqual(peer.id, self.clientID)
                    serverConnected.fulfill()
                case .packet(_, let packet):
                    if await serverPackets.append(packet) == packetCount { serverReceived.fulfill() }
                case .authenticationFailed: XCTFail("Matching password must authenticate")
                default: break
                }
            }
        }
        defer {
            clientEvents.cancel()
            serverEvents.cancel()
            client.stop()
            server.stop()
        }
        try await client.start(deviceID: clientID, name: "Client Mac", password: "test shared secret")
        let port = try await server.startForTesting(deviceID: serverID, name: "Server Mac", password: "test shared secret")
        try await client.connectForTesting(to: port)
        await fulfillment(of: [clientConnected, serverConnected], timeout: 6)

        let transferID = UUID()
        let bytes = Data((0..<262_144).map { UInt8($0 & 0xff) })
        try await withThrowingTaskGroup(of: Void.self) { group in
            for value in 0..<32 {
                group.addTask { try await client.send(.control(Data([UInt8(value)])), to: self.serverID) }
                group.addTask { try await server.send(.control(Data([UInt8(value)])), to: self.clientID) }
            }
            group.addTask { try await client.send(.chunk(transferID: transferID, data: bytes), to: self.serverID) }
            group.addTask { try await server.send(.chunk(transferID: transferID, data: bytes), to: self.clientID) }
            try await group.waitForAll()
        }
        await fulfillment(of: [clientReceived, serverReceived], timeout: 6)
        for capture in [clientPackets, serverPackets] {
            let (controls, chunks) = await capture.snapshots()
            XCTAssertEqual(controls.count, 32)
            XCTAssertEqual(Set(controls), Set((0..<32).map { Data([UInt8($0)]) }))
            XCTAssertEqual(chunks.count, 1)
            XCTAssertEqual(chunks.first?.0, transferID)
            XCTAssertEqual(chunks.first?.1, bytes)
        }
        server.stop()
        await fulfillment(of: [disconnected], timeout: 4)
        do {
            try await client.send(.control(Data()), to: serverID)
            XCTFail("Sending to a disconnected peer must fail")
        } catch { }
    }

    func testLoopbackRejectsWrongPasswordBeforePeerAnnouncement() async throws {
        let client = LANService(discoveryEnabled: false)
        let server = LANService(discoveryEnabled: false)
        let clientRejected = expectation(description: "client rejects password")
        let serverRejected = expectation(description: "server rejects password")
        let unexpectedPeer = expectation(description: "wrong password never connects")
        unexpectedPeer.isInverted = true
        let clientEvents = Task {
            for await event in client.events {
                switch event {
                case .authenticationFailed: clientRejected.fulfill()
                case .peerConnected: unexpectedPeer.fulfill()
                default: break
                }
            }
        }
        let serverEvents = Task {
            for await event in server.events {
                switch event {
                case .authenticationFailed: serverRejected.fulfill()
                case .peerConnected: unexpectedPeer.fulfill()
                default: break
                }
            }
        }
        defer {
            clientEvents.cancel()
            serverEvents.cancel()
            client.stop()
            server.stop()
        }
        try await client.start(deviceID: clientID, name: "Client", password: "correct")
        let port = try await server.startForTesting(deviceID: serverID, name: "Server", password: "incorrect")
        try await client.connectForTesting(to: port)
        await fulfillment(of: [clientRejected, serverRejected], timeout: 6)
        await fulfillment(of: [unexpectedPeer], timeout: 0.2)
    }

    func testOversizedPacketFailsWithoutHangingQueuedSends() async throws {
        let client = LANService(discoveryEnabled: false)
        let server = LANService(discoveryEnabled: false)
        let connected = expectation(description: "connection established")
        let observed = Task {
            for await event in client.events {
                if case .peerConnected = event { connected.fulfill() }
            }
        }
        defer { observed.cancel(); client.stop(); server.stop() }
        try await client.start(deviceID: clientID, name: "Client", password: "shared")
        let port = try await server.startForTesting(deviceID: serverID, name: "Server", password: "shared")
        try await client.connectForTesting(to: port)
        await fulfillment(of: [connected], timeout: 6)
        do {
            try await client.send(.control(Data(count: LANProtocol.maxPayloadBytes + 1)), to: serverID)
            XCTFail("Oversized plaintext must be rejected")
        } catch let error as LANError {
            guard case .payloadTooLarge = error else { return XCTFail("Unexpected error: \(error)") }
        }
    }
}
