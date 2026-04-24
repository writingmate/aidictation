import Accelerate
import AVFoundation

class FrequencyAnalyzer {
    private let fftSize = 2048 // Larger FFT for better frequency resolution
    private var fftSetup: vDSP_DFT_Setup?
    private var window: [Float] = []
    private var previousBands: [Float] = []
    private let smoothingFactor: Float = 0.3 // Lower smoothing = more responsive to changes

    // Number of frequency bands to output
    let bandCount = 10

    init() {
        // Create FFT setup
        fftSetup = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(fftSize), .FORWARD)

        // Create Hann window for smoother frequency analysis
        window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))

        // Initialize previous bands
        previousBands = Array(repeating: 0.0, count: bandCount)
    }

    /// Analyze audio buffer and return frequency magnitudes for each band
    func analyze(buffer: AVAudioPCMBuffer) -> [Float] {
        guard let channelData = buffer.floatChannelData?[0],
              let fftSetup = fftSetup
        else {
            return Array(repeating: 0.0, count: bandCount)
        }

        let frameCount = Int(buffer.frameLength)
        let sampleCount = min(frameCount, fftSize)
        let sampleRate = Float(buffer.format.sampleRate)

        // Apply window function
        var windowed = [Float](repeating: 0, count: fftSize)
        vDSP_vmul(channelData, 1, window, 1, &windowed, 1, vDSP_Length(sampleCount))

        // Prepare for FFT
        var realParts = [Float](repeating: 0, count: fftSize)
        var imagParts = [Float](repeating: 0, count: fftSize)

        // Convert to split complex format
        windowed.withUnsafeBytes { bufferPtr in
            let complexPtr = bufferPtr.bindMemory(to: DSPComplex.self)
            realParts.withUnsafeMutableBufferPointer { realPtr in
                imagParts.withUnsafeMutableBufferPointer { imagPtr in
                    var splitComplex = DSPSplitComplex(realp: realPtr.baseAddress!, imagp: imagPtr.baseAddress!)
                    vDSP_ctoz(complexPtr.baseAddress!, 2, &splitComplex, 1, vDSP_Length(fftSize / 2))
                }
            }
        }

        // Perform FFT
        vDSP_DFT_Execute(fftSetup, realParts, imagParts, &realParts, &imagParts)

        // Calculate magnitudes
        var magnitudes = [Float](repeating: 0, count: fftSize / 2)
        realParts.withUnsafeMutableBufferPointer { realPtr in
            imagParts.withUnsafeMutableBufferPointer { imagPtr in
                var splitComplex = DSPSplitComplex(realp: realPtr.baseAddress!, imagp: imagPtr.baseAddress!)
                vDSP_zvabs(&splitComplex, 1, &magnitudes, 1, vDSP_Length(fftSize / 2))
            }
        }

        // DEBUG: Log raw spectrum info
        let maxMag = magnitudes.max() ?? 0
        let avgMag = magnitudes.reduce(0, +) / Float(magnitudes.count)
        print("[FreqAnalyzer] RAW SPECTRUM - Max: \(String(format: "%.4f", maxMag)), Avg: \(String(format: "%.4f", avgMag))")

        // Group into frequency bands focused on voice
        var bands = groupIntoBands(magnitudes: magnitudes, bandCount: bandCount, sampleRate: sampleRate)

        // DEBUG: Log voice band before processing
        let rawBandMax = bands.max() ?? 0
        let rawBandAvg = bands.reduce(0, +) / Float(bands.count)
        print("[FreqAnalyzer] VOICE BANDS RAW - Max: \(String(format: "%.4f", rawBandMax)), Avg: \(String(format: "%.4f", rawBandAvg))")

        // Apply noise gate - ignore very quiet signals
        let noiseGate: Float = 0.5 // Aggressive threshold to filter background noise
        bands = bands.map { max($0 - noiseGate, 0.0) }

        // Scale with fixed gain to preserve volume information
        let fixedGain: Float = 12.0 // Higher gain to compensate for aggressive noise gate
        bands = bands.map {
            let scaled = $0 * fixedGain
            return min(scaled, 1.0)
        }

        // DEBUG: Log after gain
        let gainedMax = bands.max() ?? 0
        let gainedAvg = bands.reduce(0, +) / Float(bands.count)
        print("[FreqAnalyzer] AFTER GAIN - Max: \(String(format: "%.4f", gainedMax)), Avg: \(String(format: "%.4f", gainedAvg))")

        // Apply asymmetric smoothing: fast attack, slow decay
        for i in 0 ..< bandCount {
            if bands[i] > previousBands[i] {
                // Attack: respond quickly (less smoothing)
                bands[i] = previousBands[i] * 0.1 + bands[i] * 0.9
            } else {
                // Decay: fall slowly (more smoothing)
                bands[i] = previousBands[i] * 0.6 + bands[i] * 0.4
            }
        }
        previousBands = bands

        // DEBUG: Final output
        let finalMax = bands.max() ?? 0
        let finalAvg = bands.reduce(0, +) / Float(bands.count)
        let nonZero = bands.filter { $0 > 0.01 }.count
        print("[FreqAnalyzer] FINAL - Max: \(String(format: "%.4f", finalMax)), Avg: \(String(format: "%.4f", finalAvg)), Active: \(nonZero)/\(bandCount)")
        print("---")

        return bands
    }

    /// Group FFT magnitudes into frequency bands focused on voice spectrum
    private func groupIntoBands(magnitudes: [Float], bandCount: Int, sampleRate: Float) -> [Float] {
        var bands = [Float](repeating: 0, count: bandCount)
        let magnitudeCount = magnitudes.count

        // Define voice frequency range (fundamentals + formants)
        let voiceStartHz: Float = 50.0 // Include lowest voice frequencies
        let voiceEndHz: Float = 2400.0 // Cut high frequencies (20% reduction)

        let nyquistFreq = sampleRate / 2.0 // Max frequency we can represent

        // Convert Hz to FFT bin indices
        let voiceRangeStart = Int((voiceStartHz / nyquistFreq) * Float(magnitudeCount))
        let voiceRangeEnd = Int((voiceEndHz / nyquistFreq) * Float(magnitudeCount))
        let voiceRangeWidth = voiceRangeEnd - voiceRangeStart

        // DEBUG: Log frequency range info (only once on first call)

        var debugOnce = true
        if debugOnce {
            debugOnce = false
            print("=== FREQUENCY ANALYZER SETUP ===")
            print("Sample Rate: \(Int(sampleRate)) Hz")
            print("Nyquist Frequency: \(Int(nyquistFreq)) Hz")
            print("FFT Size: \(magnitudeCount * 2)")
            print("Voice Range: \(Int(voiceStartHz))-\(Int(voiceEndHz)) Hz")
            print("Voice Bins: \(voiceRangeStart)-\(voiceRangeEnd) (of \(magnitudeCount))")
            print("Bins per Band: ~\(voiceRangeWidth / bandCount)")
            let hzPerBand = (voiceEndHz - voiceStartHz) / Float(bandCount)
            print("Hz per Band: ~\(Int(hzPerBand)) Hz")
            print("================================")
        }

        // Linear distribution in voice range
        for i in 0 ..< bandCount {
            let fraction = Float(i) / Float(bandCount)
            let startIndex = voiceRangeStart + Int(fraction * Float(voiceRangeWidth))
            let endIndex = voiceRangeStart + Int(Float(i + 1) / Float(bandCount) * Float(voiceRangeWidth))

            // Average magnitudes in this band
            if startIndex < voiceRangeEnd, endIndex <= voiceRangeEnd, startIndex < endIndex {
                let bandMagnitudes = magnitudes[startIndex ..< endIndex]
                bands[i] = bandMagnitudes.reduce(0, +) / Float(bandMagnitudes.count)
            }
        }

        return bands
    }

    deinit {
        if let setup = fftSetup {
            vDSP_DFT_DestroySetup(setup)
        }
    }
}
