import Foundation

/// Creates the single process-wide journal off the main thread. All callers
/// share the same actor, while the journal's file lock still fences another
/// process or a stale store instance.
enum MacAudioProcessingStoreProvider {
    private static let rootDirectory: URL = {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        return applicationSupport.appendingPathComponent(
            "WhisperMate",
            isDirectory: true
        )
    }()

    private static let storeTask = Task.detached(priority: .utility) {
        let store = MacAudioProcessingStore(rootDirectory: rootDirectory)
        Task.detached(priority: .utility) {
            _ = await store.retryDeletedSourceCleanup()
        }
        return store
    }
    private static let unavailableStore = MacAudioProcessingStore(
        unavailableRootDirectory: rootDirectory
    )

    static func shared() async -> MacAudioProcessingStore {
        let gate = MacStoreProviderGate()
        return await withCheckedContinuation { continuation in
            gate.install(continuation)
            Task.detached(priority: .utility) {
                gate.resolve(await storeTask.value)
            }
            Task.detached(priority: .utility) {
                try? await Task.sleep(nanoseconds: 5_500_000_000)
                gate.resolve(unavailableStore)
            }
        }
    }
}

private final class MacStoreProviderGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<MacAudioProcessingStore, Never>?
    private var resolved = false

    func install(
        _ continuation: CheckedContinuation<MacAudioProcessingStore, Never>
    ) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()
    }

    func resolve(_ store: MacAudioProcessingStore) {
        lock.lock()
        guard !resolved, let continuation else {
            lock.unlock()
            return
        }
        resolved = true
        self.continuation = nil
        lock.unlock()
        continuation.resume(returning: store)
    }
}
