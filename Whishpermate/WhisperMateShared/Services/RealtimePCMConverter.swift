import AVFoundation
import Foundation

/// Converts capture buffers to the 24 kHz mono Int16 PCM the realtime
/// WebSocket clients expect. Conversion is serialized because AVAudioConverter
/// is not thread-safe.
public final class RealtimePCMConverter: @unchecked Sendable {
    public static let outputSampleRate: Double = 24_000

    private let lock = NSLock()
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    private var outputFormat: AVAudioFormat?

    public init() {}

    public static func makeOutputFormat() -> AVAudioFormat? {
        AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: outputSampleRate,
            channels: 1,
            interleaved: true
        )
    }

    public func chunk(from buffer: AVAudioPCMBuffer) -> Data? {
        guard let outputFormat = Self.makeOutputFormat() else { return nil }
        lock.lock()
        defer { lock.unlock() }

        let inputFormat = buffer.format
        let converter: AVAudioConverter
        if let cached = self.converter,
           self.inputFormat == inputFormat,
           self.outputFormat == outputFormat
        {
            converter = cached
        } else {
            guard let newConverter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
                return nil
            }
            self.converter = newConverter
            self.inputFormat = inputFormat
            self.outputFormat = outputFormat
            converter = newConverter
        }

        let ratio = outputFormat.sampleRate / inputFormat.sampleRate
        let frameCapacity = AVAudioFrameCount(
            max(1, ceil(Double(buffer.frameLength) * ratio) + 64)
        )
        guard let convertedBuffer = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: frameCapacity
        ) else { return nil }

        var conversionError: NSError?
        var didProvideInput = false
        let status = converter.convert(
            to: convertedBuffer,
            error: &conversionError
        ) { _, outStatus in
            if didProvideInput {
                outStatus.pointee = .noDataNow
                return nil
            }
            didProvideInput = true
            outStatus.pointee = .haveData
            return buffer
        }

        if conversionError != nil || status == .error {
            return nil
        }
        return Self.int16PCMData(from: convertedBuffer)
    }

    private static func int16PCMData(from buffer: AVAudioPCMBuffer) -> Data? {
        guard let channelData = buffer.int16ChannelData else { return nil }
        let byteCount = Int(buffer.frameLength) * MemoryLayout<Int16>.size
        guard byteCount > 0 else { return nil }
        return Data(bytes: channelData.pointee, count: byteCount)
    }
}
