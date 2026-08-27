import Foundation
public import Combine

public final class SharedParakeetTranscriptionService: ObservableObject {
    public static let shared = SharedParakeetTranscriptionService()

    public enum ServiceState {
        case notInitialized
        case downloading
        case initializing
        case ready
        case transcribing
        case error(String)
    }

    @Published public private(set) var state: ServiceState = .notInitialized
    @Published public private(set) var isModelDownloaded = false

    public static var isRuntimeSupported: Bool {
        #if os(iOS)
            if #available(iOS 17.0, *) {
                return true
            }
            return false
        #else
            if #available(macOS 14.0, *) {
                return true
            }
            return false
        #endif
    }

    public static var unavailableMessage: String {
        #if os(iOS)
            return "Offline mode is not available in this build."
        #else
            return "Offline mode requires macOS 14 or later."
        #endif
    }

    private var initializationTask: Task<Void, Error>?
    private let runtimeBridgeSlot = RuntimeBridgeSlot()
    @MainActor private var runtimePublicationFence = RuntimeGenerationPublicationFence()

    private init() {}

    public func initialize() async throws {
        guard Self.isRuntimeSupported else {
            await setUnavailableState()
            throw runtimeError(Self.unavailableMessage)
        }

        if let initializationTask {
            try await initializationTask.value
            return
        }

        let currentState = await MainActor.run { state }
        switch currentState {
        case .notInitialized, .error:
            break
        case .downloading, .initializing:
            return
        case .ready, .transcribing:
            return
        }

        let task = Task<Void, Error> {
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

                guard await registerRuntimeGeneration(generation, initialState: .downloading) else {
                    throw CancellationError()
                }

                do {
                    try await initializeRuntimeBridge(bridge, ownership: ownership)
                    await publishRuntimeState(generation, state: .ready, isModelDownloaded: true)
                } catch is CancellationError {
                    ownership.cancel()
                    await publishRuntimeState(generation, state: .notInitialized, isModelDownloaded: false)
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
        initializationTask = task

        do {
            try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            initializationTask = nil
        } catch {
            initializationTask = nil
            throw error
        }
    }

    public func transcribe(audioURL: URL) async throws -> String {
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
            guard await registerRuntimeGeneration(generation) else { throw CancellationError() }

            do {
                // Initializing the exact reserved bridge is idempotent when ready.
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
                await publishRuntimeState(generation, state: .notInitialized, isModelDownloaded: false)
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

    public func transcribeDiarized(audioURL: URL) async throws -> String {
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
            guard await registerRuntimeGeneration(generation) else { throw CancellationError() }

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
                await publishRuntimeState(generation, state: .notInitialized, isModelDownloaded: false)
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

    public func transcribeMeeting(audioURL: URL) async throws -> String {
        try await transcribeDiarized(audioURL: audioURL)
    }

    @MainActor
    public func cleanup() {
        let invalidation = runtimeBridgeSlot.invalidateAndTake()

        _ = runtimePublicationFence.invalidate(invalidation.generation)
        state = .notInitialized
        isModelDownloaded = false

        if let bridge = invalidation.bridge {
            callVoidSelector("cleanupRuntime", on: bridge)
        }
    }

    /// Clears cached model files and resets the service state, allowing a fresh download on next initialization.
    /// Use this to recover from a failed or corrupt model download.
    @MainActor
    public func clearModelCacheAndReset() {
        let invalidation = runtimeBridgeSlot.invalidateAndTake()

        _ = runtimePublicationFence.invalidate(invalidation.generation)
        state = .notInitialized
        isModelDownloaded = false
        initializationTask = nil

        if let bridge = invalidation.bridge {
            callVoidSelector("clearModelCache", on: bridge)
        } else {
            clearModelCacheFallback()
        }
    }

    private func clearModelCacheFallback() {
        let fm = FileManager.default

        #if os(iOS)
            if let cacheDir = fm.urls(for: .cachesDirectory, in: .userDomainMask).first {
                let ttsCache = cacheDir.appendingPathComponent("fluidaudio/Models")
                try? fm.removeItem(at: ttsCache)
            }
        #endif

        if let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let modelsDir = appSupport.appendingPathComponent("FluidAudio/Models")
            try? fm.removeItem(at: modelsDir)
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
            state = .error(Self.unavailableMessage)
            isModelDownloaded = false
        }
    }

    private func loadRuntimeBridge() throws -> NSObject {
        if let runtimeBridge = runtimeBridgeSlot.current() {
            return runtimeBridge
        }

        guard let bundle = runtimeFrameworkBundle() else {
            throw runtimeError("Offline mode is missing from this build.")
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
            throw runtimeError("Could not find the offline transcription runtime.")
        }

        let bridge = bridgeClass.init()
        guard let installed = runtimeBridgeSlot.installIfEmpty(bridge) else {
            throw runtimeError("Offline runtime attempt identity is exhausted.")
        }
        return installed
    }

    private func runtimeFrameworkBundle() -> Bundle? {
        let frameworkName = "ParakeetRuntime.framework"
        let appFrameworkURL = Bundle.main.privateFrameworksURL?.appendingPathComponent(frameworkName)
        let containingAppFrameworkURL = Bundle.main.bundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Frameworks")
            .appendingPathComponent(frameworkName)

        for frameworkURL in [appFrameworkURL, containingAppFrameworkURL].compactMap({ $0 }) {
            if let bundle = Bundle(url: frameworkURL) {
                return bundle
            }
        }

        return nil
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
                    gate.resolve(.failure(runtimeError("Offline runtime does not support cancellable initialization.")))
                    return
                }

                let completion: @convention(block) (Bool, NSString?) -> Void = { success, message in
                    if success {
                        gate.resolve(.success(()))
                    } else {
                        gate.resolve(.failure(self.runtimeError((message as String?) ?? "Offline model initialization failed.")))
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
            failureMessage: "Offline transcription failed."
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
            failureMessage: "Meeting transcription failed."
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
                    gate.resolve(.failure(runtimeError("Offline runtime does not support cancellable transcription.")))
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
            domain: "SharedParakeetTranscriptionService",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}
