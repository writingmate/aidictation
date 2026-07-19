import Foundation
internal import Combine
import WhisperMateShared

/// On-device transcription service. The FluidAudio implementation lives in a
/// macOS 14+ runtime framework so the main app can still launch on macOS 12.
class ParakeetTranscriptionService: ObservableObject {
    static let shared = ParakeetTranscriptionService()

    enum ServiceState {
        case notInitialized
        case downloading
        case initializing
        case ready
        case transcribing
        case error(String)

        var isReady: Bool {
            if case .ready = self { return true }
            return false
        }
    }

    @Published var state: ServiceState = .notInitialized
    @Published var isModelDownloaded: Bool = false

    static var isRuntimeSupported: Bool {
        if #available(macOS 14.0, *) {
            return true
        }
        return false
    }

    static var unavailableMessage: String {
        "Local transcription requires macOS 14 or later"
    }

    private let runtimeBridgeSlot = RuntimeBridgeSlot()
    @MainActor private var runtimePublicationFence = RuntimeGenerationPublicationFence()

    private init() {}

    func initialize() async throws {
        guard Self.isRuntimeSupported else {
            await setUnavailableState()
            throw runtimeError(Self.unavailableMessage)
        }

        switch state {
        case .notInitialized, .error:
            break
        case .downloading, .initializing, .ready, .transcribing:
            DebugLog.info("Already initialized or in progress", context: "ParakeetTranscriptionService")
            return
        }

        let ownership = RuntimeBridgeAttemptOwnership(slot: runtimeBridgeSlot)
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let bridge = try loadRuntimeBridge()
            try Task.checkCancellation()
            guard let generation = ownership.reserve(bridge) else {
                if ownership.wasCancelled { throw CancellationError() }
                throw runtimeError("Offline transcription is already in progress.")
            }
            defer { ownership.release() }
            guard await registerRuntimeGeneration(
                generation,
                initialState: .downloading
            ) else {
                throw CancellationError()
            }

            do {
                DebugLog.info("Initializing Parakeet runtime...", context: "ParakeetTranscriptionService")
                try await initializeRuntimeBridge(bridge, ownership: ownership)
                await publishRuntimeState(
                    generation,
                    state: .ready,
                    isModelDownloaded: true
                )
                DebugLog.info("Parakeet model ready", context: "ParakeetTranscriptionService")
            } catch is CancellationError {
                ownership.cancel()
                await publishRuntimeState(
                    generation,
                    state: .notInitialized,
                    isModelDownloaded: false
                )
                throw CancellationError()
            } catch {
                DebugLog.error("Failed to initialize Parakeet: \(error.localizedDescription)", context: "ParakeetTranscriptionService")
                ownership.cancel()
                await publishRuntimeState(
                    generation,
                    state: .error(error.localizedDescription),
                    isModelDownloaded: false
                )
                throw error
            }
        } onCancel: {
            ownership.cancel()
        }
    }

    func transcribe(audioURL: URL) async throws -> String {
        guard Self.isRuntimeSupported else {
            await setUnavailableState()
            throw runtimeError(Self.unavailableMessage)
        }

        let ownership = RuntimeBridgeAttemptOwnership(slot: runtimeBridgeSlot)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let bridge = try loadRuntimeBridge()
            try Task.checkCancellation()
            guard let generation = ownership.reserve(bridge) else {
                if ownership.wasCancelled { throw CancellationError() }
                throw runtimeError("Offline transcription is already in progress.")
            }
            defer { ownership.release() }
            guard await registerRuntimeGeneration(generation) else {
                throw CancellationError()
            }

            do {
                try await initializeRuntimeBridge(bridge, ownership: ownership)
                guard await publishRuntimeState(generation, state: .transcribing) else {
                    throw CancellationError()
                }
                let text = try await transcribeWithRuntimeBridge(
                    bridge,
                    ownership: ownership,
                    audioPath: audioURL.path
                )
                await publishRuntimeState(generation, state: .ready)
                return text
            } catch is CancellationError {
                ownership.cancel()
                await publishRuntimeState(
                    generation,
                    state: .notInitialized,
                    isModelDownloaded: false
                )
                throw CancellationError()
            } catch {
                ownership.cancel()
                await publishRuntimeState(
                    generation,
                    state: .error(error.localizedDescription),
                    isModelDownloaded: false
                )
                throw error
            }
        } onCancel: {
            ownership.cancel()
        }
    }

    func transcribeDiarized(audioURL: URL) async throws -> String {
        guard Self.isRuntimeSupported else {
            await setUnavailableState()
            throw runtimeError(Self.unavailableMessage)
        }

        let ownership = RuntimeBridgeAttemptOwnership(slot: runtimeBridgeSlot)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let bridge = try loadRuntimeBridge()
            try Task.checkCancellation()
            guard let generation = ownership.reserve(bridge) else {
                if ownership.wasCancelled { throw CancellationError() }
                throw runtimeError("Offline transcription is already in progress.")
            }
            defer { ownership.release() }
            guard await registerRuntimeGeneration(generation) else {
                throw CancellationError()
            }

            do {
                try await initializeRuntimeBridge(bridge, ownership: ownership)
                guard await publishRuntimeState(generation, state: .transcribing) else {
                    throw CancellationError()
                }
                let text = try await transcribeDiarizedWithRuntimeBridge(
                    bridge,
                    ownership: ownership,
                    audioPath: audioURL.path
                )
                await publishRuntimeState(generation, state: .ready)
                return text
            } catch is CancellationError {
                ownership.cancel()
                await publishRuntimeState(
                    generation,
                    state: .notInitialized,
                    isModelDownloaded: false
                )
                throw CancellationError()
            } catch {
                ownership.cancel()
                await publishRuntimeState(
                    generation,
                    state: .error(error.localizedDescription),
                    isModelDownloaded: false
                )
                throw error
            }
        } onCancel: {
            ownership.cancel()
        }
    }

    func transcribeMeeting(audioURL: URL) async throws -> String {
        try await transcribeDiarized(audioURL: audioURL)
    }

    @MainActor
    func cleanup() {
        let invalidation = runtimeBridgeSlot.invalidateAndTake()

        _ = runtimePublicationFence.invalidate(invalidation.generation)
        state = .notInitialized
        isModelDownloaded = false

        if let bridge = invalidation.bridge {
            callVoidSelector("cleanupRuntime", on: bridge)
        }
    }

    @MainActor
    private func registerRuntimeGeneration(
        _ generation: UInt64,
        initialState: ServiceState? = nil
    ) -> Bool {
        guard runtimePublicationFence.register(generation) else { return false }
        if let initialState {
            state = initialState
        }
        return true
    }

    @MainActor
    @discardableResult
    private func publishRuntimeState(
        _ generation: UInt64,
        state newState: ServiceState,
        isModelDownloaded newDownloadState: Bool? = nil
    ) -> Bool {
        guard runtimePublicationFence.accepts(generation) else { return false }
        state = newState
        if let newDownloadState {
            isModelDownloaded = newDownloadState
        }
        return true
    }

    private func setUnavailableState() async {
        await MainActor.run {
            self.state = .error(Self.unavailableMessage)
            self.isModelDownloaded = false
        }
    }

    private func loadRuntimeBridge() throws -> NSObject {
        if let runtimeBridge = runtimeBridgeSlot.current() {
            return runtimeBridge
        }

        guard Self.isRuntimeSupported else {
            throw runtimeError(Self.unavailableMessage)
        }

        guard let frameworkURL = Bundle.main.privateFrameworksURL?.appendingPathComponent("ParakeetRuntime.framework"),
              let bundle = Bundle(url: frameworkURL)
        else {
            throw runtimeError("Parakeet runtime framework is missing")
        }

        if !bundle.isLoaded {
            do {
                try bundle.loadAndReturnError()
            } catch {
                throw runtimeError(error.localizedDescription)
            }
        }

        let runtimeClass: AnyClass? = NSClassFromString("ParakeetRuntime.ParakeetRuntimeBridge")
            ?? NSClassFromString("ParakeetRuntimeBridge")
        guard let bridgeClass = runtimeClass as? NSObject.Type else {
            throw runtimeError("Could not find Parakeet runtime bridge")
        }

        let bridge = bridgeClass.init()
        guard let installed = runtimeBridgeSlot.installIfEmpty(bridge) else {
            throw runtimeError("Offline runtime attempt identity is exhausted.")
        }
        return installed
    }

    private func initializeRuntimeBridge(
        _ bridge: NSObject,
        ownership: RuntimeBridgeAttemptOwnership
    ) async throws {
        let attemptID = UUID().uuidString
        let gate = RuntimeCallbackAttempt<Void>()
        let cancellation = RuntimeAttemptCancellation(
            bridge: bridge,
            attemptID: attemptID,
            bridgeOwnership: ownership
        )

        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard gate.install(continuation) else {
                    cancellation.cancel()
                    return
                }

                guard !Task<Never, Never>.isCancelled else {
                    gate.resolve(.failure(CancellationError()))
                    cancellation.cancel()
                    return
                }

                let selector = NSSelectorFromString("initializeAttempt:completion:")
                guard bridge.responds(to: selector),
                      let method = bridge.method(for: selector)
                else {
                    gate.resolve(.failure(self.runtimeError("Parakeet runtime does not support cancellable initialization")))
                    return
                }

                let completion: @convention(block) (Bool, NSString?) -> Void = { success, message in
                    if success {
                        gate.resolve(.success(()))
                    } else {
                        gate.resolve(.failure(self.runtimeError((message as String?) ?? "Parakeet initialization failed")))
                    }
                }

                typealias Function = @convention(c) (AnyObject, Selector, NSString, @escaping @convention(block) (Bool, NSString?) -> Void) -> Void
                unsafeBitCast(method, to: Function.self)(bridge, selector, attemptID as NSString, completion)
            }
        } onCancel: {
            gate.resolve(.failure(CancellationError()))
            cancellation.cancel()
        }
    }

    private func transcribeWithRuntimeBridge(
        _ bridge: NSObject,
        ownership: RuntimeBridgeAttemptOwnership,
        audioPath: String
    ) async throws -> String {
        try await performTextOperation(
            on: bridge,
            ownership: ownership,
            selectorName: "transcribeAudioAtPath:attemptID:completion:",
            audioPath: audioPath,
            failureMessage: "Parakeet transcription failed"
        )
    }

    private func transcribeDiarizedWithRuntimeBridge(
        _ bridge: NSObject,
        ownership: RuntimeBridgeAttemptOwnership,
        audioPath: String
    ) async throws -> String {
        try await performTextOperation(
            on: bridge,
            ownership: ownership,
            selectorName: "transcribeDiarizedAudioAtPath:attemptID:completion:",
            audioPath: audioPath,
            failureMessage: "Meeting transcription failed"
        )
    }

    private func performTextOperation(
        on bridge: NSObject,
        ownership: RuntimeBridgeAttemptOwnership,
        selectorName: String,
        audioPath: String,
        failureMessage: String
    ) async throws -> String {
        let attemptID = UUID().uuidString
        let gate = RuntimeCallbackAttempt<String>()
        let cancellation = RuntimeAttemptCancellation(
            bridge: bridge,
            attemptID: attemptID,
            bridgeOwnership: ownership
        )

        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
                guard gate.install(continuation) else {
                    cancellation.cancel()
                    return
                }

                guard !Task<Never, Never>.isCancelled else {
                    gate.resolve(.failure(CancellationError()))
                    cancellation.cancel()
                    return
                }

                let selector = NSSelectorFromString(selectorName)
                guard bridge.responds(to: selector),
                      let method = bridge.method(for: selector)
                else {
                    gate.resolve(.failure(self.runtimeError("Parakeet runtime does not support cancellable transcription")))
                    return
                }

                let completion: @convention(block) (NSString?, NSString?) -> Void = { text, message in
                    if let text {
                        gate.resolve(.success(text as String))
                    } else {
                        gate.resolve(.failure(self.runtimeError((message as String?) ?? failureMessage)))
                    }
                }

                typealias Function = @convention(c) (AnyObject, Selector, NSString, NSString, @escaping @convention(block) (NSString?, NSString?) -> Void) -> Void
                unsafeBitCast(method, to: Function.self)(bridge, selector, audioPath as NSString, attemptID as NSString, completion)
            }
        } onCancel: {
            gate.resolve(.failure(CancellationError()))
            cancellation.cancel()
        }
    }

    private func callVoidSelector(_ selectorName: String, on bridge: NSObject) {
        let selector = NSSelectorFromString(selectorName)
        guard bridge.responds(to: selector),
              let method = bridge.method(for: selector)
        else {
            return
        }

        typealias Function = @convention(c) (AnyObject, Selector) -> Void
        unsafeBitCast(method, to: Function.self)(bridge, selector)
    }

    private func runtimeError(_ message: String) -> NSError {
        NSError(
            domain: "ParakeetTranscriptionService",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}
