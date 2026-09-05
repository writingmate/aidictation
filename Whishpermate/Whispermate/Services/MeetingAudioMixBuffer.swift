import Foundation

nonisolated final class MeetingAudioMixBuffer: @unchecked Sendable {
    enum BufferError: Error { case overflow }
    private let lock = NSLock()
    private var samples: [Float] = []
    private var readIndex = 0
    private var sealed = false
    private let capacity: Int

    init(capacity: Int = 160_000) { self.capacity = capacity }

    func append(_ input: UnsafeBufferPointer<Float>) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !sealed else { return }
        guard samples.count - readIndex + input.count <= capacity else { throw BufferError.overflow }
        if readIndex > capacity / 2 { samples.removeFirst(readIndex); readIndex = 0 }
        samples.append(contentsOf: input)
    }

    func mix(into output: UnsafeMutableBufferPointer<Float>) {
        lock.lock()
        defer { lock.unlock() }
        let count = min(output.count, samples.count - readIndex)
        for index in 0..<count {
            output[index] = max(-1, min(1, output[index] + samples[readIndex + index]))
        }
        readIndex += count
    }

    func sealAndDrain() -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        sealed = true
        let remaining = Array(samples[readIndex...])
        samples.removeAll()
        readIndex = 0
        return remaining
    }
}
