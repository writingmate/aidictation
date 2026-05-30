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
    private var runtimeBridge: NSObject?

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
            await MainActor.run {
                state = .downloading
            }

            let bridge = try loadRuntimeBridge()

            do {
                try await initializeRuntimeBridge(bridge)
                await MainActor.run {
                    state = .ready
                    isModelDownloaded = true
                }
            } catch {
                await MainActor.run {
                    state = .error(error.localizedDescription)
                    isModelDownloaded = false
                }
                throw error
            }
        }
        initializationTask = task

        do {
            try await task.value
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

        let currentState = await MainActor.run { state }
        if case .notInitialized = currentState {
            try await initialize()
        } else if case .downloading = currentState {
            try await initialize()
        } else if case .initializing = currentState {
            try await initialize()
        }

        let bridge = try loadRuntimeBridge()

        await MainActor.run {
            state = .transcribing
        }

        do {
            let text = try await transcribeWithRuntimeBridge(bridge, audioPath: audioURL.path)
            await MainActor.run {
                state = .ready
            }
            return text
        } catch {
            await MainActor.run {
                state = .error(error.localizedDescription)
            }
            throw error
        }
    }

    public func transcribeDiarized(audioURL: URL) async throws -> String {
        guard Self.isRuntimeSupported else {
            await setUnavailableState()
            throw runtimeError(Self.unavailableMessage)
        }

        let currentState = await MainActor.run { state }
        if case .notInitialized = currentState {
            try await initialize()
        } else if case .downloading = currentState {
            try await initialize()
        } else if case .initializing = currentState {
            try await initialize()
        }

        let bridge = try loadRuntimeBridge()

        await MainActor.run {
            state = .transcribing
        }

        do {
            let text = try await transcribeDiarizedWithRuntimeBridge(bridge, audioPath: audioURL.path)
            await MainActor.run {
                state = .ready
            }
            return text
        } catch {
            await MainActor.run {
                state = .error(error.localizedDescription)
            }
            throw error
        }
    }

    public func transcribeMeeting(audioURL: URL) async throws -> String {
        try await transcribeDiarized(audioURL: audioURL)
    }

    public func cleanup() {
        let bridge = runtimeBridge
        runtimeBridge = nil

        if let bridge {
            callVoidSelector("cleanupRuntime", on: bridge)
        }

        Task { @MainActor in
            state = .notInitialized
            isModelDownloaded = false
        }
    }

    private func setUnavailableState() async {
        await MainActor.run {
            state = .error(Self.unavailableMessage)
            isModelDownloaded = false
        }
    }

    private func loadRuntimeBridge() throws -> NSObject {
        if let runtimeBridge {
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
        runtimeBridge = bridge
        return bridge
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

    private func initializeRuntimeBridge(_ bridge: NSObject) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let selector = NSSelectorFromString("initializeWithCompletion:")
            guard bridge.responds(to: selector),
                  let method = bridge.method(for: selector)
            else {
                continuation.resume(throwing: runtimeError("Offline runtime does not support initialization."))
                return
            }

            let completion: @convention(block) (Bool, NSString?) -> Void = { success, message in
                if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: self.runtimeError((message as String?) ?? "Offline model initialization failed."))
                }
            }

            typealias Function = @convention(c) (AnyObject, Selector, @escaping @convention(block) (Bool, NSString?) -> Void) -> Void
            unsafeBitCast(method, to: Function.self)(bridge, selector, completion)
        }
    }

    private func transcribeWithRuntimeBridge(_ bridge: NSObject, audioPath: String) async throws -> String {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            let selector = NSSelectorFromString("transcribeAudioAtPath:completion:")
            guard bridge.responds(to: selector),
                  let method = bridge.method(for: selector)
            else {
                continuation.resume(throwing: runtimeError("Offline runtime does not support transcription."))
                return
            }

            let completion: @convention(block) (NSString?, NSString?) -> Void = { text, message in
                if let text {
                    continuation.resume(returning: text as String)
                } else {
                    continuation.resume(throwing: self.runtimeError((message as String?) ?? "Offline transcription failed."))
                }
            }

            typealias Function = @convention(c) (AnyObject, Selector, NSString, @escaping @convention(block) (NSString?, NSString?) -> Void) -> Void
            unsafeBitCast(method, to: Function.self)(bridge, selector, audioPath as NSString, completion)
        }
    }

    private func transcribeDiarizedWithRuntimeBridge(_ bridge: NSObject, audioPath: String) async throws -> String {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            let selector = NSSelectorFromString("transcribeDiarizedAudioAtPath:completion:")
            guard bridge.responds(to: selector),
                  let method = bridge.method(for: selector)
            else {
                continuation.resume(throwing: runtimeError("Offline runtime does not support meeting transcription."))
                return
            }

            let completion: @convention(block) (NSString?, NSString?) -> Void = { text, message in
                if let text {
                    continuation.resume(returning: text as String)
                } else {
                    continuation.resume(throwing: self.runtimeError((message as String?) ?? "Meeting transcription failed."))
                }
            }

            typealias Function = @convention(c) (AnyObject, Selector, NSString, @escaping @convention(block) (NSString?, NSString?) -> Void) -> Void
            unsafeBitCast(method, to: Function.self)(bridge, selector, audioPath as NSString, completion)
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
