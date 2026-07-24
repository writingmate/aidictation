import Foundation

/// Performs one non-idempotent usage side effect without delaying terminal UI. The store durably
/// claims the recording before this call receives it, so competing callers and restarts cannot
/// submit the same transcript twice.
@MainActor
public enum MobileAudioUsageAccounting {
    public static func flush(
        recordingID: UUID,
        historyManager: HistoryManager,
        store: MobileAudioProcessingStore = .shared,
        subscriptionManager: SubscriptionManager = .shared
    ) async {
        guard (try? await historyManager.containsDurably(recordingID: recordingID)) == true else {
            DebugLog.warning(
                "Word usage remains pending until the transcription is durably visible in History.",
                context: "MobileAudioUsageAccounting"
            )
            return
        }
        guard let lease = try? await store.beginUsageAccounting(recordingID: recordingID) else {
            return
        }

        let acknowledged = await subscriptionManager.recordWords(lease.wordCount)
        if !acknowledged {
            DebugLog.warning(
                "Word usage was not delivered after its one-time claim; it will not be retried.",
                context: "MobileAudioUsageAccounting"
            )
        }
    }
}
