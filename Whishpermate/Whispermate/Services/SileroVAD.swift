import AVFoundation
import CoreML
import Foundation

/// Direct CoreML wrapper for Silero VAD model
class SileroVAD {
    private var model: MLModel?
    private let modelURL: URL

    init() {
        // Model is in Resources/Models directory
        let bundle = Bundle.main

        // Try multiple paths to find the model
        var modelPath: String?

        // First try: with directory
        modelPath = bundle.path(forResource: "silero-vad-unified-v6.0.0", ofType: "mlpackage", inDirectory: "Resources/Models")

        // Second try: without directory (if model is at root of bundle resources)
        if modelPath == nil {
            modelPath = bundle.path(forResource: "silero-vad-unified-v6.0.0", ofType: "mlpackage")
        }

        // Third try: look for .mlmodelc (pre-compiled)
        if modelPath == nil {
            modelPath = bundle.path(forResource: "silero-vad-unified-v6.0.0", ofType: "mlmodelc", inDirectory: "Resources/Models")
        }

        // Fourth try: .mlmodelc without directory
        if modelPath == nil {
            modelPath = bundle.path(forResource: "silero-vad-unified-v6.0.0", ofType: "mlmodelc")
        }

        guard let foundPath = modelPath else {
            DebugLog.info("❌ Could not find VAD model in bundle. Searched for .mlpackage and .mlmodelc", context: "SileroVAD")
            DebugLog.info("Bundle path: \(bundle.bundlePath)", context: "SileroVAD")
            DebugLog.info("Resources path: \(bundle.resourcePath ?? "none")", context: "SileroVAD")
            modelURL = URL(fileURLWithPath: "")
            return
        }

        DebugLog.info("✅ Found VAD model at: \(foundPath)", context: "SileroVAD")
        modelURL = URL(fileURLWithPath: foundPath)

        Task {
            await loadModel()
        }
    }

    private func loadModel() async {
        do {
            let config = MLModelConfiguration()
            if #available(macOS 13.0, *) {
                config.computeUnits = .cpuAndNeuralEngine
            } else {
                config.computeUnits = .cpuOnly
            }

            // First, compile the model if it's an mlpackage
            let compiledURL: URL
            if modelURL.pathExtension == "mlpackage" {
                DebugLog.info("📦 Compiling mlpackage model...", context: "SileroVAD")
                // compileModel is synchronous, not async
                compiledURL = try await Task.detached {
                    try MLModel.compileModel(at: self.modelURL)
                }.value
                DebugLog.info("✅ Model compiled to: \(compiledURL.path)", context: "SileroVAD")
            } else {
                compiledURL = modelURL
            }

            model = try MLModel(contentsOf: compiledURL, configuration: config)
            DebugLog.info("✅ Silero VAD model loaded", context: "SileroVAD")
        } catch {
            DebugLog.info("❌ Failed to load VAD model: \(error)", context: "SileroVAD")
        }
    }

    /// Analyze audio file for speech
    func analyzeAudio(url: URL, threshold: Float = 0.3) async throws -> Bool {
        // Ensure model is loaded
        if model == nil {
            await loadModel()
        }

        guard let model = model else {
            throw VADError.notInitialized
        }

        // Load and convert audio to 16kHz mono
        let samples = try loadAudio(url: url)

        // Process in chunks
        let chunkSize = 576 // Silero VAD v6 expects 576 samples
        var probabilities: [Float] = []

        // Initialize hidden state (1 x 128) - Silero VAD v6 state dimensions
        var hiddenState = try MLMultiArray(shape: [1, 128], dataType: .float32)
        for i in 0 ..< 128 {
            hiddenState[i] = 0.0
        }

        // Initialize cell state (1 x 128) - LSTM cell state
        var cellState = try MLMultiArray(shape: [1, 128], dataType: .float32)
        for i in 0 ..< 128 {
            cellState[i] = 0.0
        }

        for i in stride(from: 0, to: samples.count, by: chunkSize) {
            let end = min(i + chunkSize, samples.count)
            var chunk = Array(samples[i ..< end])

            // Pad if necessary
            if chunk.count < chunkSize {
                chunk.append(contentsOf: Array(repeating: Float(0), count: chunkSize - chunk.count))
            }

            // Create input array (1 x 576)
            let inputArray = try MLMultiArray(shape: [1, NSNumber(value: chunkSize)], dataType: .float32)
            for (index, value) in chunk.enumerated() {
                inputArray[index] = NSNumber(value: value)
            }

            // Run inference with state
            let input = try MLDictionaryFeatureProvider(dictionary: [
                "audio_input": inputArray,
                "hidden_state": hiddenState,
                "cell_state": cellState,
            ])
            let output = try await model.prediction(from: input)

            // Get probability from vad_output
            if let outputArray = output.featureValue(for: "vad_output")?.multiArrayValue {
                let prob = outputArray[0].floatValue
                probabilities.append(prob)
            }

            // Update states for next iteration
            if let newH = output.featureValue(for: "new_hidden_state")?.multiArrayValue {
                hiddenState = newH
            }
            if let newC = output.featureValue(for: "new_cell_state")?.multiArrayValue {
                cellState = newC
            }
        }

        // Calculate statistics
        guard !probabilities.isEmpty else { return false }

        let avgProb = probabilities.reduce(0, +) / Float(probabilities.count)
        let speechCount = probabilities.filter { $0 >= threshold }.count
        let speechRatio = Float(speechCount) / Float(probabilities.count)

        DebugLog.info(
            "VAD Analysis - Avg: \(String(format: "%.3f", avgProb)), " +
                "Ratio: \(String(format: "%.3f", speechRatio)) (\(speechCount)/\(probabilities.count))",
            context: "SileroVAD"
        )

        return avgProb >= threshold || speechRatio >= 0.1
    }

    private func loadAudio(url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat

        // Create 16kHz mono format
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        ) else {
            throw VADError.formatConversionFailed
        }

        // Read and convert
        guard let converter = AVAudioConverter(from: format, to: targetFormat) else {
            throw VADError.formatConversionFailed
        }

        let frameCount = UInt32(file.length)
        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw VADError.bufferAllocationFailed
        }

        try file.read(into: inputBuffer)

        let outputFrameCapacity = UInt32(Double(frameCount) * (16000.0 / format.sampleRate))
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: outputFrameCapacity
        ) else {
            throw VADError.bufferAllocationFailed
        }

        var error: NSError?
        converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            outStatus.pointee = .haveData
            return inputBuffer
        }

        if let error = error {
            throw VADError.conversionError(error)
        }

        // Extract samples
        guard let floatData = outputBuffer.floatChannelData?[0] else {
            throw VADError.bufferReadFailed
        }

        return Array(UnsafeBufferPointer(start: floatData, count: Int(outputBuffer.frameLength)))
    }
}
