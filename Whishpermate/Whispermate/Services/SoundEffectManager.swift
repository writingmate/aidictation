import WhisperMateShared
import AVFoundation
import Foundation

/// Plays the short start/stop cues for a dictation.
///
/// The tones are synthesized once at launch rather than shipped as assets, so
/// there is no bundle payload and the timbre can be tuned in one place. Players
/// are built and `prepareToPlay()`-ed ahead of time for the same reason the
/// audio engine and overlay window are: anything built on the hotkey shows up
/// as latency the user feels.
///
/// The start cue is deliberately shorter than the capture start-up (~120ms), so
/// it has finished sounding before the microphone begins recording and cannot
/// bleed into the audio.
@MainActor
final class SoundEffectManager {
    // MARK: - Types

    private enum Cue {
        case start
        case stop
    }

    // MARK: - Keys

    private enum Keys {
        static let soundEffectsEnabled = "soundEffectsEnabled"
    }

    // MARK: - Constants

    private enum Constants {
        static let sampleRate: Double = 44_100

        /// A thump is a sine whose pitch collapses fast: `pitchFrom` decays to
        /// `pitchTo` with time constant `pitchTau`, while amplitude decays over
        /// `ampTau`. The pitch envelope is what makes it read as a struck body
        /// rather than a tone.
        struct Thump {
            let pitchFrom: Double
            let pitchTo: Double
            let pitchTau: Double
            let ampTau: Double
            let duration: TimeInterval
        }

        /// Start sits slightly higher than stop so the pair is distinguishable
        /// without becoming a melody.
        static let start = Thump(pitchFrom: 150, pitchTo: 62, pitchTau: 0.016, ampTau: 0.045, duration: 0.18)
        static let stop = Thump(pitchFrom: 125, pitchTo: 50, pitchTau: 0.018, ampTau: 0.055, duration: 0.20)

        /// Quiet by default — this fires many times a day.
        static let volume: Float = 0.30

        /// Sub-millisecond, only to keep the first sample from being a step
        /// discontinuity. Any longer and the attack stops sounding percussive.
        static let attackSeconds: TimeInterval = 0.0008
    }

    // MARK: - Public Properties

    /// User-facing toggle. Persisted; defaults to on.
    var isEnabled: Bool {
        get {
            if AppDefaults.shared.object(forKey: Keys.soundEffectsEnabled) == nil { return true }
            return AppDefaults.shared.bool(forKey: Keys.soundEffectsEnabled)
        }
        set { AppDefaults.shared.set(newValue, forKey: Keys.soundEffectsEnabled) }
    }

    // MARK: - Private Properties

    private var startPlayer: AVAudioPlayer?
    private var stopPlayer: AVAudioPlayer?

    // MARK: - Initialization

    static let shared = SoundEffectManager()

    private init() {}

    // MARK: - Public API

    /// Synthesizes and preloads both cues. Call once at launch.
    func prepare() {
        guard startPlayer == nil, stopPlayer == nil else { return }
        startPlayer = makePlayer(for: .start)
        stopPlayer = makePlayer(for: .stop)
        DebugLog.info("Sound cues prepared", context: "SoundEffectManager")
    }

    /// Rising cue, played the moment the hotkey goes down.
    func playStart() {
        play(startPlayer)
    }

    /// Falling cue, played when the hotkey is released.
    func playStop() {
        play(stopPlayer)
    }

    // MARK: - Private Methods

    private func play(_ player: AVAudioPlayer?) {
        guard isEnabled, let player else { return }
        // Rewind rather than allocate: back-to-back dictations reuse the player.
        player.currentTime = 0
        player.play()
    }

    private func makePlayer(for cue: Cue) -> AVAudioPlayer? {
        let spec: Constants.Thump = switch cue {
        case .start: Constants.start
        case .stop: Constants.stop
        }

        guard let data = renderThump(spec) else { return nil }
        do {
            let player = try AVAudioPlayer(data: data)
            player.volume = Constants.volume
            player.prepareToPlay()
            return player
        } catch {
            DebugLog.warning("Could not build cue player: \(error)", context: "SoundEffectManager")
            return nil
        }
    }

    /// Renders a thump as a 16-bit mono WAV.
    ///
    /// Phase is integrated rather than computed from a fixed frequency, because
    /// the frequency is changing every sample; evaluating `sin(2*pi*f*t)` with a
    /// moving `f` makes the phase jump and buzzes instead of thumping.
    private func renderThump(_ spec: Constants.Thump) -> Data? {
        let frameCount = Int(Constants.sampleRate * spec.duration)
        guard frameCount > 0 else { return nil }

        var samples = [Int16]()
        samples.reserveCapacity(frameCount)
        var phase = 0.0

        for frame in 0 ..< frameCount {
            let t = Double(frame) / Constants.sampleRate
            let frequency = spec.pitchTo + (spec.pitchFrom - spec.pitchTo) * exp(-t / spec.pitchTau)
            phase += 2 * Double.pi * frequency / Constants.sampleRate

            let amplitude = exp(-t / spec.ampTau)
            let attack = min(1.0, t / Constants.attackSeconds)
            let value = sin(phase) * amplitude * attack

            samples.append(Int16(max(-1, min(1, value)) * 30_000))
        }

        return wavData(samples: samples)
    }

    private func wavData(samples: [Int16]) -> Data {
        let byteCount = samples.count * MemoryLayout<Int16>.size
        var data = Data()

        func appendASCII(_ text: String) { data.append(contentsOf: Array(text.utf8)) }
        func appendUInt32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func appendUInt16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }

        appendASCII("RIFF")
        appendUInt32(UInt32(36 + byteCount))
        appendASCII("WAVE")
        appendASCII("fmt ")
        appendUInt32(16)
        appendUInt16(1) // PCM
        appendUInt16(1) // mono
        appendUInt32(UInt32(Constants.sampleRate))
        appendUInt32(UInt32(Constants.sampleRate) * 2) // byte rate
        appendUInt16(2) // block align
        appendUInt16(16) // bits per sample
        appendASCII("data")
        appendUInt32(UInt32(byteCount))
        samples.withUnsafeBufferPointer { data.append(contentsOf: UnsafeRawBufferPointer($0)) }
        return data
    }
}
