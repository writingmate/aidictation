import Foundation

/// Creates the single process-wide journal off the main thread. All callers
/// share the same actor, while the journal's file lock still fences another
/// process or a stale store instance.
enum MacAudioProcessingStoreProvider {
    private static let storeTask = Task.detached(priority: .utility) {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        let rootDirectory = applicationSupport.appendingPathComponent(
            "WhisperMate",
            isDirectory: true
        )
        return MacAudioProcessingStore(rootDirectory: rootDirectory)
    }

    static func shared() async -> MacAudioProcessingStore {
        await storeTask.value
    }
}
