import Foundation
#if canImport(WhisperMateShared)
import WhisperMateShared
#endif

/// Owns a recording's stream before app context is ready, including a stop
/// that arrives before connection. No audio is captured by this object.
nonisolated final class MacRealtimeStartupAudio: RealtimeTranscriptionStreaming, @unchecked Sendable {
    private let queue: DispatchQueue
    private let maximumBytes: Int
    private let finishGate: RealtimeTranscriptionFinishGate
    private var chunks: [Data] = []
    private var byteCount = 0
    private var client: (any RealtimeTranscriptionStreaming)?
    private var closed = false
    private var finishDeadline: TimeInterval?

    // Two seconds of the recorder's 24 kHz, mono, Int16 streaming format.
    init(maximumBytes: Int = 96_000) {
        self.maximumBytes = maximumBytes
        let queue = DispatchQueue(label: "ai.writingmate.realtime-startup")
        self.queue = queue
        finishGate = RealtimeTranscriptionFinishGate(queue: queue)
    }

    func start() {}

    var isConnected: Bool { queue.sync { client != nil && !closed } }

    func sendAudio(_ chunk: Data) { append(chunk) }

    func append(_ chunk: Data) {
        queue.sync {
            guard !closed, finishDeadline == nil, !chunk.isEmpty else { return }
            if let client {
                client.sendAudio(chunk)
            } else if chunk.count <= maximumBytes - byteCount {
                chunks.append(chunk)
                byteCount += chunk.count
            } else {
                closeOnQueue()
            }
        }
    }

    func connect(to client: any RealtimeTranscriptionStreaming) -> Bool {
        queue.sync {
            guard !closed, self.client == nil else { return false }
            self.client = client
            client.start()
            for chunk in chunks { client.sendAudio(chunk) }
            chunks.removeAll()
            byteCount = 0
            if let finishDeadline {
                client.requestFinish(timeout: max(0, finishDeadline - ProcessInfo.processInfo.systemUptime))
            }
            Task { [weak self, client] in
                let transcript = await client.awaitFinish()
                self?.queue.async { [weak self] in
                    self?.finishGate.resolve(with: transcript)
                }
            }
            return true
        }
    }

    func requestFinish(timeout: TimeInterval) {
        queue.sync {
            guard !closed, finishGate.begin(timeout: timeout, onTimeout: { [weak self] in
                self?.closeOnQueue()
            }) else { return }
            finishDeadline = ProcessInfo.processInfo.systemUptime + max(0, timeout)
            client?.requestFinish(timeout: timeout)
        }
    }

    func awaitFinish() async -> String? {
        await withCheckedContinuation { continuation in
            queue.async { self.finishGate.wait(continuation) }
        }
    }

    func discardPending() {
        queue.sync {
            if client == nil { closeOnQueue() }
        }
    }

    func close() {
        queue.sync { closeOnQueue() }
    }

    private func closeOnQueue() {
        guard !closed else { return }
        closed = true
        chunks.removeAll()
        byteCount = 0
        client?.close()
        finishGate.resolve(with: nil)
    }
}
