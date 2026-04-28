import Foundation
import FluidAudio

@objc(ParakeetRuntimeBridge)
public final class ParakeetRuntimeBridge: NSObject {
    private var asrManager: AsrManager?
    private let audioConverter = AudioConverter()

    @objc public private(set) dynamic var stateRaw: String = "notInitialized"

    @objc(currentStateRaw)
    public func currentStateRaw() -> NSString {
        stateRaw as NSString
    }

    @objc(initializeWithCompletion:)
    public func initialize(completion: @escaping (Bool, NSString?) -> Void) {
        guard stateRaw == "notInitialized" || stateRaw.hasPrefix("error:") else {
            completion(stateRaw == "ready", nil)
            return
        }

        Task {
            do {
                stateRaw = "downloading"
                let downloadedModels = try await AsrModels.downloadAndLoad(version: .v3)

                stateRaw = "initializing"
                let manager = AsrManager(config: .default)
                try await manager.loadModels(downloadedModels)

                asrManager = manager
                stateRaw = "ready"
                completion(true, nil)
            } catch {
                let message = error.localizedDescription
                stateRaw = "error:\(message)"
                completion(false, message as NSString)
            }
        }
    }

    @objc(transcribeAudioAtPath:completion:)
    public func transcribeAudio(atPath path: NSString, completion: @escaping (NSString?, NSString?) -> Void) {
        guard let manager = asrManager else {
            completion(nil, "ASR manager not initialized")
            return
        }

        stateRaw = "transcribing"

        Task {
            do {
                let samples = try audioConverter.resampleAudioFile(path: path as String)
                var decoderState = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
                let result = try await manager.transcribe(samples, decoderState: &decoderState)

                stateRaw = "ready"
                completion(result.text as NSString, nil)
            } catch {
                let message = error.localizedDescription
                stateRaw = "error:\(message)"
                completion(nil, message as NSString)
            }
        }
    }

    @objc(cleanupRuntime)
    public func cleanupRuntime() {
        let manager = asrManager
        asrManager = nil
        stateRaw = "notInitialized"

        Task {
            await manager?.cleanup()
        }
    }
}
