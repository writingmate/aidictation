import Foundation
internal import Combine

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

    private var runtimeBridge: NSObject?

    private init() {}

    func initialize() async throws {
        guard Self.isRuntimeSupported else {
            await setUnavailableState()
            throw runtimeError(Self.unavailableMessage)
        }

        guard case .notInitialized = state else {
            DebugLog.info("Already initialized or in progress", context: "ParakeetTranscriptionService")
            return
        }

        await MainActor.run {
            self.state = .downloading
        }

        let bridge = try loadRuntimeBridge()

        do {
            DebugLog.info("Initializing Parakeet runtime...", context: "ParakeetTranscriptionService")
            try await initializeRuntimeBridge(bridge)
            await MainActor.run {
                self.state = .ready
                self.isModelDownloaded = true
            }
            DebugLog.info("Parakeet model ready", context: "ParakeetTranscriptionService")
        } catch {
            DebugLog.error("Failed to initialize Parakeet: \(error.localizedDescription)", context: "ParakeetTranscriptionService")
            await MainActor.run {
                self.state = .error(error.localizedDescription)
                self.isModelDownloaded = false
            }
            throw error
        }
    }

    func transcribe(audioURL: URL) async throws -> String {
        guard Self.isRuntimeSupported else {
            await setUnavailableState()
            throw runtimeError(Self.unavailableMessage)
        }

        if case .notInitialized = state {
            try await initialize()
        }

        let bridge = try loadRuntimeBridge()

        await MainActor.run {
            self.state = .transcribing
        }

        do {
            let text = try await transcribeWithRuntimeBridge(bridge, audioPath: audioURL.path)
            await MainActor.run {
                self.state = .ready
            }
            return text
        } catch {
            await MainActor.run {
                self.state = .error(error.localizedDescription)
            }
            throw error
        }
    }

    func cleanup() {
        let bridge = runtimeBridge
        runtimeBridge = nil

        if let bridge {
            callVoidSelector("cleanupRuntime", on: bridge)
        }

        Task { @MainActor in
            self.state = .notInitialized
            self.isModelDownloaded = false
        }
    }

    private func setUnavailableState() async {
        await MainActor.run {
            self.state = .error(Self.unavailableMessage)
            self.isModelDownloaded = false
        }
    }

    private func loadRuntimeBridge() throws -> NSObject {
        if let runtimeBridge {
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
        runtimeBridge = bridge
        return bridge
    }

    private func initializeRuntimeBridge(_ bridge: NSObject) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let selector = NSSelectorFromString("initializeWithCompletion:")
            guard bridge.responds(to: selector),
                  let method = bridge.method(for: selector)
            else {
                continuation.resume(throwing: self.runtimeError("Parakeet runtime does not support initialization"))
                return
            }

            let completion: @convention(block) (Bool, NSString?) -> Void = { success, message in
                if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: self.runtimeError((message as String?) ?? "Parakeet initialization failed"))
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
                continuation.resume(throwing: self.runtimeError("Parakeet runtime does not support transcription"))
                return
            }

            let completion: @convention(block) (NSString?, NSString?) -> Void = { text, message in
                if let text {
                    continuation.resume(returning: text as String)
                } else {
                    continuation.resume(throwing: self.runtimeError((message as String?) ?? "Parakeet transcription failed"))
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
            domain: "ParakeetTranscriptionService",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}
