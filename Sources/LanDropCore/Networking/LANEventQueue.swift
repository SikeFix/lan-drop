import Foundation

/// AsyncStream's continuation buffers cannot suspend their producer. An unfolding
/// stream over this queue supplies real backpressure: a session pauses its next
/// socket read when the app falls behind, instead of retaining an entire file.
actor LANEventQueue {
    private struct BufferedEvent {
        let event: LANEvent
        let bytes: Int
    }
    private struct Producer {
        let event: BufferedEvent
        let continuation: CheckedContinuation<Bool, Never>
    }

    private let maximumBytes: Int
    private let maximumEvents: Int
    private let maximumProducers = 64
    private var buffer: [BufferedEvent] = []
    private var bufferedBytes = 0
    private var producers: [Producer] = []
    private var consumer: CheckedContinuation<LANEvent?, Never>?
    private var finished = false

    init(maximumBytes: Int = 8 * 1_048_576, maximumEvents: Int = 128) {
        precondition(maximumBytes >= LANProtocol.maxPayloadBytes && maximumEvents > 0)
        self.maximumBytes = maximumBytes
        self.maximumEvents = maximumEvents
    }

    @discardableResult
    func send(_ event: LANEvent) async -> Bool {
        guard !finished else { return false }
        if let consumer {
            self.consumer = nil
            consumer.resume(returning: event)
            return true
        }
        let buffered = BufferedEvent(event: event, bytes: Self.cost(event))
        guard buffered.bytes <= maximumBytes else { return false }
        if producers.isEmpty, fits(buffered) {
            append(buffered)
            return true
        }
        guard producers.count < maximumProducers else { return false }
        return await withCheckedContinuation { continuation in
            producers.append(Producer(event: buffered, continuation: continuation))
        }
    }

    func next() async -> LANEvent? {
        if !buffer.isEmpty {
            let next = buffer.removeFirst()
            bufferedBytes -= next.bytes
            admitProducers()
            return next.event
        }
        guard !finished else { return nil }
        // LANService.events has one consumer, like its original AsyncStream.
        guard consumer == nil else { return nil }
        return await withCheckedContinuation { consumer = $0 }
    }

    func discardBufferedEvents() {
        buffer.removeAll(keepingCapacity: true)
        bufferedBytes = 0
        let pending = producers
        producers.removeAll(keepingCapacity: true)
        for producer in pending { producer.continuation.resume(returning: false) }
    }

    func finish() {
        finished = true
        discardBufferedEvents()
        consumer?.resume(returning: nil)
        consumer = nil
    }

    func bufferingForTesting() -> (bytes: Int, events: Int, suspendedProducers: Int) {
        (bufferedBytes, buffer.count, producers.count)
    }

    private func fits(_ event: BufferedEvent) -> Bool {
        buffer.count < maximumEvents && bufferedBytes + event.bytes <= maximumBytes
    }

    private func append(_ event: BufferedEvent) {
        buffer.append(event)
        bufferedBytes += event.bytes
    }

    private func admitProducers() {
        while let producer = producers.first, fits(producer.event) {
            producers.removeFirst()
            append(producer.event)
            producer.continuation.resume(returning: true)
        }
    }

    private static func cost(_ event: LANEvent) -> Int {
        switch event {
        case .packet(_, .control(let data)), .packet(_, .chunk(_, let data)): return max(256, data.count)
        default: return 256
        }
    }
}
