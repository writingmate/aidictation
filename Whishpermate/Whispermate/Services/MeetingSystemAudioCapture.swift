@preconcurrency import AVFoundation
import ScreenCaptureKit

/// The microphone clocks the combined recording. Any queued Mac audio is
/// drained into the managed file before its native writer is closed.
nonisolated final class MeetingSystemAudioCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "ai.writingmate.meeting-system-audio")
    private var stream: SCStream?
    private var stopped = false
    private let audio = MeetingAudioMixBuffer()
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    var onFailure: (@Sendable (String) -> Void)?

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else { throw CaptureError.unavailable }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(seconds: 1, preferredTimescale: 1)
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 1
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        guard install(stream) else { throw CancellationError() }
        try await stream.startCapture()
        if isStopped {
            try? await stream.stopCapture()
            throw CancellationError()
        }
    }

    private func install(_ stream: SCStream) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped else { return false }
        self.stream = stream
        return true
    }

    private var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    func mix(into buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData?[0] else { return }
        audio.mix(into: UnsafeMutableBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }

    func stopAndDrain() throws -> AVAudioPCMBuffer? {
        let remaining: [Float] = try queue.sync {
            lock.lock()
            stopped = true
            let stream = self.stream
            self.stream = nil
            lock.unlock()
            if let stream { Task { try? await stream.stopCapture() } }
            if let converter {
                for _ in 0..<4 {
                    guard let tail = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024) else { throw CaptureError.unavailable }
                    var error: NSError?
                    let status = converter.convert(to: tail, error: &error) { _, inputStatus in
                        inputStatus.pointee = .endOfStream
                        return nil
                    }
                    if let error { throw error }
                    if let channel = tail.floatChannelData?[0], tail.frameLength > 0 {
                        try audio.append(UnsafeBufferPointer(start: channel, count: Int(tail.frameLength)))
                    }
                    if status == .endOfStream || tail.frameLength == 0 { return audio.sealAndDrain() }
                }
                throw CaptureError.unavailable
            }
            return audio.sealAndDrain()
        }
        guard !remaining.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(remaining.count)),
              let channel = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = AVAudioFrameCount(remaining.count)
        remaining.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: $0.count) }
        return buffer
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        guard !isStopped else { return }
        onFailure?("Mac audio capture stopped. The available recording was kept. Start a new recording to continue.")
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid, !isStopped,
              CMSampleBufferGetNumSamples(sampleBuffer) > 0 else { return }
        do {
            guard let description = sampleBuffer.formatDescription else { throw CaptureError.unavailable }
            let sourceFormat = AVAudioFormat(cmAudioFormatDescription: description)
            guard let source = AVAudioPCMBuffer(pcmFormat: sourceFormat,
                      frameCapacity: AVAudioFrameCount(sampleBuffer.numSamples)) else { throw CaptureError.unavailable }
            source.frameLength = source.frameCapacity
            guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0,
                frameCount: Int32(source.frameLength), into: source.mutableAudioBufferList) == noErr else { throw CaptureError.unavailable }
            if inputFormat != sourceFormat {
                converter = AVAudioConverter(from: sourceFormat, to: format)
                inputFormat = sourceFormat
            }
            guard let converter, let converted = AVAudioPCMBuffer(pcmFormat: format,
                frameCapacity: AVAudioFrameCount(ceil(Double(source.frameLength) * 16_000 / sourceFormat.sampleRate) + 64))
            else { throw CaptureError.unavailable }
            var supplied = false
            var error: NSError?
            converter.convert(to: converted, error: &error) { _, status in
                guard !supplied else { status.pointee = .noDataNow; return nil }
                supplied = true
                status.pointee = .haveData
                return source
            }
            if let error { throw error }
            guard let channel = converted.floatChannelData?[0] else { throw CaptureError.unavailable }
            try audio.append(UnsafeBufferPointer(start: channel, count: Int(converted.frameLength)))
        } catch {
            guard !isStopped else { return }
            onFailure?("Mac audio couldn’t be recorded completely. The available audio was kept. Try recording again.")
        }
    }

    private enum CaptureError: Error { case unavailable }
}
