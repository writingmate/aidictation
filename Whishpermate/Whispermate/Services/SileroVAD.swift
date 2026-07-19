@preconcurrency import AVFoundation
import CoreML
import Foundation

/// Direct CoreML wrapper for Silero VAD model
actor SileroVAD {
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

        // Load lazily inside `analyzeAudio`. Long sources are rejected by the
        // metadata budget before an optional model is compiled or initialized.
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
                let packageURL = modelURL
                compiledURL = try await Task.detached {
                    try MLModel.compileModel(at: packageURL)
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

        let chunkSize = 576 // Silero VAD v6 expects 576 samples
        var hiddenState = try MLMultiArray(shape: [1, 128], dataType: .float32)
        for i in 0 ..< 128 {
            hiddenState[i] = 0.0
        }
        var cellState = try MLMultiArray(shape: [1, 128], dataType: .float32)
        for i in 0 ..< 128 {
            cellState[i] = 0.0
        }

        let file = try AVAudioFile(forReading: url)
        let sourceFormat = file.processingFormat
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ) else {
            throw VADError.formatConversionFailed
        }
        guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            throw VADError.formatConversionFailed
        }

        let sourceCapacity: AVAudioFrameCount = 8_192
        guard let inputBuffer = AVAudioPCMBuffer(
            pcmFormat: sourceFormat,
            frameCapacity: sourceCapacity
        ) else {
            throw VADError.bufferAllocationFailed
        }
        let ratio = targetFormat.sampleRate / sourceFormat.sampleRate
        let outputCapacity = AVAudioFrameCount(
            max(1, ceil(Double(sourceCapacity) * ratio) + 32)
        )
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: outputCapacity
        ) else {
            throw VADError.bufferAllocationFailed
        }

        var pendingSamples: [Float] = []
        pendingSamples.reserveCapacity(Int(outputCapacity) + chunkSize)
        var analyzedChunks = 0
        var maximumProbability: Float = 0

        while true {
            try Task.checkCancellation()
            inputBuffer.frameLength = 0
            try file.read(into: inputBuffer, frameCount: sourceCapacity)
            guard inputBuffer.frameLength > 0 else { break }

            outputBuffer.frameLength = 0
            var conversionError: NSError?
            let inputSupplier = AudioConverterInputSupplier(buffer: inputBuffer)
            let status = converter.convert(to: outputBuffer, error: &conversionError) { _, inputStatus in
                inputSupplier.next(status: inputStatus)
            }
            if let conversionError {
                throw VADError.conversionError(conversionError)
            }
            guard status != .error else { throw VADError.formatConversionFailed }
            guard let converted = outputBuffer.floatChannelData?[0] else {
                throw VADError.bufferReadFailed
            }
            pendingSamples.append(contentsOf: UnsafeBufferPointer(
                start: converted,
                count: Int(outputBuffer.frameLength)
            ))

            while pendingSamples.count >= chunkSize {
                try Task.checkCancellation()
                let chunk = Array(pendingSamples.prefix(chunkSize))
                pendingSamples.removeFirst(chunkSize)
                if let probability = try speechProbability(
                    for: chunk,
                    model: model,
                    hiddenState: &hiddenState,
                    cellState: &cellState
                ) {
                    analyzedChunks += 1
                    maximumProbability = max(maximumProbability, probability)
                    // VAD is a rejection optimization. One positive window is
                    // sufficient and lets long recordings stop decoding early.
                    if probability >= threshold {
                        DebugLog.info(
                            "VAD detected speech after \(analyzedChunks) streamed chunks",
                            context: "SileroVAD"
                        )
                        return true
                    }
                }
            }
        }

        if !pendingSamples.isEmpty {
            pendingSamples.append(
                contentsOf: repeatElement(0, count: chunkSize - pendingSamples.count)
            )
            if let probability = try speechProbability(
                for: pendingSamples,
                model: model,
                hiddenState: &hiddenState,
                cellState: &cellState
            ) {
                analyzedChunks += 1
                maximumProbability = max(maximumProbability, probability)
                if probability >= threshold { return true }
            }
        }

        DebugLog.info(
            "VAD found no speech in \(analyzedChunks) streamed chunks; max=\(String(format: "%.3f", maximumProbability))",
            context: "SileroVAD"
        )
        return false
    }

    private func speechProbability(
        for chunk: [Float],
        model: MLModel,
        hiddenState: inout MLMultiArray,
        cellState: inout MLMultiArray
    ) throws -> Float? {
        let inputArray = try MLMultiArray(
            shape: [1, NSNumber(value: chunk.count)],
            dataType: .float32
        )
        for (index, value) in chunk.enumerated() {
            inputArray[index] = NSNumber(value: value)
        }
        let input = try MLDictionaryFeatureProvider(dictionary: [
            "audio_input": inputArray,
            "hidden_state": hiddenState,
            "cell_state": cellState,
        ])
        let output = try model.prediction(from: input)
        if let newHidden = output.featureValue(for: "new_hidden_state")?.multiArrayValue {
            hiddenState = newHidden
        }
        if let newCell = output.featureValue(for: "new_cell_state")?.multiArrayValue {
            cellState = newCell
        }
        return output.featureValue(for: "vad_output")?.multiArrayValue?[0].floatValue
    }
}

private nonisolated final class AudioConverterInputSupplier: @unchecked Sendable {
    private let lock = NSLock()
    private let buffer: AVAudioPCMBuffer
    private var supplied = false

    init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    func next(
        status: UnsafeMutablePointer<AVAudioConverterInputStatus>
    ) -> AVAudioBuffer? {
        lock.lock()
        defer { lock.unlock() }
        guard !supplied else {
            status.pointee = .noDataNow
            return nil
        }
        supplied = true
        status.pointee = .haveData
        return buffer
    }
}
