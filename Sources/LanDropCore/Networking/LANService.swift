import Foundation
import Network
import CryptoKit

public struct Peer: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let name: String

    public init(id: UUID, name: String) {
        self.id = id
        self.name = name
    }
}

public enum WirePacket: Sendable {
    case control(Data)
    case chunk(transferID: UUID, data: Data)
}

public enum LANEvent: Sendable {
    case peerConnected(Peer)
    case peerDisconnected(UUID)
    case packet(UUID, WirePacket)
    case status(String)
    case authenticationFailed(String)
}

/// The caller retains device identity and the shared password (normally in the
/// Keychain). Subsequent launches discover, authenticate and reconnect unattended.
public final class LANService: @unchecked Sendable {
    public let events: AsyncStream<LANEvent>
    private let runtime: LANRuntime

    public convenience init() { self.init(discoveryEnabled: true) }

    init(discoveryEnabled: Bool) {
        let queue = LANEventQueue()
        events = AsyncStream(unfolding: { await queue.next() }, onCancel: {
            Task { await queue.finish() }
        })
        runtime = LANRuntime(events: queue, discoveryEnabled: discoveryEnabled)
    }

    public func start(deviceID: UUID, name: String, password: String) async throws {
        try await runtime.start(deviceID: deviceID, name: name, password: password)
    }

    public func stop() {
        let runtime = runtime
        Task { await runtime.stop() }
    }

    public func send(_ packet: WirePacket, to peerID: UUID) async throws {
        try await runtime.send(packet, to: peerID)
    }

    func listeningPortForTesting() async -> UInt16? { await runtime.listeningPort }

    func connectForTesting(port: UInt16) async throws {
        try await runtime.connectForTesting(port: port)
    }

    func connectForTesting(to port: NWEndpoint.Port) async throws {
        try await connectForTesting(port: port.rawValue)
    }

    func startForTesting(deviceID: UUID, name: String, password: String) async throws -> NWEndpoint.Port {
        try await start(deviceID: deviceID, name: name, password: password)
        guard let port = await listeningPortForTesting(), let endpointPort = NWEndpoint.Port(rawValue: port) else {
            throw LANError.notRunning
        }
        return endpointPort
    }

    deinit {
        let runtime = runtime
        Task { await runtime.finish() }
    }
}

private actor LANRuntime {
    private struct Connected {
        let session: ConnectionSession
        let identity: SessionIdentity
    }

    private let events: LANEventQueue
    private let discoveryEnabled: Bool
    private let queue = DispatchQueue(label: "LanDrop.discovery", qos: .userInitiated)
    private var listener: NWListener?
    private var browser: NWBrowser?
    private var deviceID: UUID?
    private var deviceName = ""
    private var passwordKey: SymmetricKey?
    private var generation = UUID()
    private var sessions: [UUID: ConnectionSession] = [:]
    private var connected: [UUID: Connected] = [:]
    private var discovered: [UUID: NWEndpoint] = [:]
    private var attempts: [UUID: UUID] = [:]
    private var retryDelays: [UUID: UInt64] = [:]
    private var authenticationFailures = Set<String>()

    var listeningPort: UInt16? { listener?.port?.rawValue }

    init(events: LANEventQueue, discoveryEnabled: Bool) {
        self.events = events
        self.discoveryEnabled = discoveryEnabled
    }

    func start(deviceID: UUID, name: String, password: String) async throws {
        await stop()
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, trimmedName.utf8.count <= 256 else { throw LANError.invalidHandshake }
        let key = try LANProtocol.passwordKey(password)
        let parameters = LANProtocol.tcpParameters()
        let listener = try NWListener(using: parameters, on: .any)
        self.deviceID = deviceID
        self.deviceName = trimmedName
        self.passwordKey = key
        self.listener = listener
        let currentGeneration = generation
        if discoveryEnabled {
            listener.service = NWListener.Service(name: deviceID.uuidString, type: LANProtocol.serviceType)
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { await self?.accept(connection, generation: currentGeneration) }
        }
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let completion = NetworkCompletion(continuation)
                listener.stateUpdateHandler = { [weak self] state in
                    switch state {
                    case .ready: completion.finish(.success(()))
                    case .failed(let error):
                        completion.finish(.failure(error))
                        Task { await self?.listenerFailed(error.localizedDescription, generation: currentGeneration) }
                    case .cancelled: completion.finish(.failure(LANError.disconnected))
                    default: break
                    }
                }
                queue.asyncAfter(deadline: .now() + LANProtocol.handshakeTimeout) {
                    completion.finishIfPending(.failure(LANError.timeout)) { listener.cancel() }
                }
                listener.start(queue: queue)
            }
            guard generation == currentGeneration else { throw LANError.disconnected }
            if discoveryEnabled { startBrowser(generation: currentGeneration) }
            await events.send(.status("正在查找使用相同密码的电脑…"))
        } catch {
            if generation == currentGeneration { await stop() }
            throw error
        }
    }

    func stop() async {
        generation = UUID()
        listener?.cancel()
        browser?.cancel()
        listener = nil
        browser = nil
        deviceID = nil
        passwordKey = nil
        let oldSessions = Array(sessions.values)
        let oldPeers = Array(connected.keys)
        sessions.removeAll()
        connected.removeAll()
        discovered.removeAll()
        attempts.removeAll()
        retryDelays.removeAll()
        authenticationFailures.removeAll()
        await events.discardBufferedEvents()
        for session in oldSessions { await session.close() }
        for id in oldPeers { await events.send(.peerDisconnected(id)) }
    }

    func finish() async {
        await stop()
        await events.finish()
    }

    func send(_ packet: WirePacket, to peerID: UUID) async throws {
        guard deviceID != nil else { throw LANError.notRunning }
        guard let connection = connected[peerID] else { throw LANError.peerUnavailable }
        try await connection.session.send(packet)
    }

    func connectForTesting(port: UInt16) throws {
        guard deviceID != nil else { throw LANError.notRunning }
        let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        beginConnection(endpoint: endpoint, expectedPeerID: nil)
    }

    private func startBrowser(generation: UUID) {
        let parameters = LANProtocol.tcpParameters()
        let browser = NWBrowser(for: .bonjour(type: LANProtocol.serviceType, domain: nil), using: parameters)
        self.browser = browser
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let endpoints = results.map(\.endpoint)
            Task { await self?.discoveryChanged(endpoints, generation: generation) }
        }
        browser.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed(let error), .waiting(let error):
                Task { await self?.browserFailed(error.localizedDescription, generation: generation) }
            default: break
            }
        }
        browser.start(queue: queue)
    }

    private func discoveryChanged(_ endpoints: [NWEndpoint], generation: UUID) {
        guard self.generation == generation, let deviceID else { return }
        var next: [UUID: NWEndpoint] = [:]
        for endpoint in endpoints {
            guard case .service(let name, _, _, _) = endpoint,
                  let peerID = UUID(uuidString: name), peerID != deviceID else { continue }
            next[peerID] = endpoint
        }
        discovered = next
        for (peerID, endpoint) in discovered {
            guard deviceID.uuidString < peerID.uuidString,
                  connected[peerID] == nil, attempts[peerID] == nil else { continue }
            beginConnection(endpoint: endpoint, expectedPeerID: peerID)
        }
    }

    private func beginConnection(endpoint: NWEndpoint, expectedPeerID: UUID?) {
        guard sessions.count < 32 else { return }
        let parameters = LANProtocol.tcpParameters()
        let connection = NWConnection(to: endpoint, using: parameters)
        let session = ConnectionSession(connection: connection, initiator: true)
        if let expectedPeerID { attempts[expectedPeerID] = session.id }
        run(session, expectedPeerID: expectedPeerID)
    }

    private func accept(_ connection: NWConnection, generation: UUID) {
        guard self.generation == generation, deviceID != nil, sessions.count < 32 else { connection.cancel(); return }
        let session = ConnectionSession(connection: connection, initiator: false)
        run(session, expectedPeerID: nil)
    }

    private func run(_ session: ConnectionSession, expectedPeerID: UUID?) {
        guard let deviceID, let passwordKey else { return }
        let name = deviceName
        let currentGeneration = generation
        sessions[session.id] = session
        Task { [weak self] in
            var peerID: UUID?
            do {
                let identity = try await session.establish(deviceID: deviceID, name: name, passwordKey: passwordKey, expectedPeerID: expectedPeerID)
                peerID = identity.peer.id
                guard let self, await self.authenticated(session, identity: identity, generation: currentGeneration) else {
                    throw LANError.duplicateConnection
                }
                while !Task.isCancelled {
                    let packet = try await session.readPacket()
                    try await self.deliver(packet, from: identity.peer.id, sessionID: session.id, generation: currentGeneration)
                }
            } catch {
                await session.close()
                await self?.ended(sessionID: session.id, peerID: peerID, expectedPeerID: expectedPeerID, error: error, generation: currentGeneration)
            }
        }
    }

    private func authenticated(_ session: ConnectionSession, identity: SessionIdentity, generation: UUID) async -> Bool {
        guard self.generation == generation, let deviceID else { return false }
        let shouldInitiate = deviceID.uuidString < identity.peer.id.uuidString
        guard session.initiator == shouldInitiate else { return false }
        if let existing = connected[identity.peer.id] {
            guard identity.tieBreaker.lexicographicallyPrecedes(existing.identity.tieBreaker) else { return false }
            connected[identity.peer.id] = Connected(session: session, identity: identity)
            await existing.session.close()
        } else {
            connected[identity.peer.id] = Connected(session: session, identity: identity)
            guard await events.send(.peerConnected(identity.peer)) else { return false }
        }
        if attempts[identity.peer.id] == session.id { attempts[identity.peer.id] = nil }
        retryDelays[identity.peer.id] = nil
        authenticationFailures.remove(identity.peer.id.uuidString)
        return true
    }

    private func deliver(_ packet: WirePacket, from peerID: UUID, sessionID: UUID, generation: UUID) async throws {
        guard self.generation == generation, connected[peerID]?.session.id == sessionID else { throw LANError.disconnected }
        guard await events.send(.packet(peerID, packet)) else { throw LANError.disconnected }
    }

    private func ended(sessionID: UUID, peerID: UUID?, expectedPeerID: UUID?, error: Error, generation: UUID) async {
        guard self.generation == generation else { return }
        sessions[sessionID] = nil
        if let expectedPeerID, attempts[expectedPeerID] == sessionID { attempts[expectedPeerID] = nil }
        if let peerID, connected[peerID]?.session.id == sessionID {
            connected[peerID] = nil
            await events.send(.peerDisconnected(peerID))
        }
        if let error = error as? LANError, case .authenticationFailed = error {
            let failureKey = expectedPeerID?.uuidString ?? "incoming"
            if authenticationFailures.insert(failureKey).inserted {
                await events.send(.authenticationFailed(error.localizedDescription))
            }
        }
        if let reconnectID = expectedPeerID ?? peerID { scheduleReconnect(reconnectID, generation: generation) }
    }

    private func scheduleReconnect(_ peerID: UUID, generation: UUID) {
        guard let deviceID, deviceID.uuidString < peerID.uuidString,
              discovered[peerID] != nil, connected[peerID] == nil, attempts[peerID] == nil else { return }
        let delay = retryDelays[peerID] ?? 2
        retryDelays[peerID] = min(delay * 2, 30)
        Task { [weak self] in
            do { try await Task.sleep(nanoseconds: delay * 1_000_000_000) } catch { return }
            await self?.reconnect(peerID, generation: generation)
        }
    }

    private func reconnect(_ peerID: UUID, generation: UUID) {
        guard self.generation == generation, let endpoint = discovered[peerID],
              connected[peerID] == nil, attempts[peerID] == nil else { return }
        beginConnection(endpoint: endpoint, expectedPeerID: peerID)
    }

    private func listenerFailed(_ message: String, generation: UUID) async {
        guard self.generation == generation else { return }
        await events.send(.status("局域网监听失败：\(message)"))
    }

    private func browserFailed(_ message: String, generation: UUID) async {
        guard self.generation == generation else { return }
        await events.send(.status("发现电脑失败，请在系统设置中允许局域网访问：\(message)"))
    }
}
