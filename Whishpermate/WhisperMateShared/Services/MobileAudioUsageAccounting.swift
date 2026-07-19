import Foundation

/// Drains one durable usage side effect without delaying recording recovery or terminal UI.
/// The recording ID is the stable local operation key; the store serializes competing callers.
@MainActor
public enum MobileAudioUsageAccounting {
    public static func flush(
        recordingID: UUID,
        store: MobileAudioProcessingStore = .shared,
        subscriptionManager: SubscriptionManager = .shared
    ) async {
        guard let lease = try? await store.beginUsageAccounting(recordingID: recordingID) else {
            return
        }

        let acknowledged = await subscriptionManager.recordWords(lease.wordCount)
        do {
            try await store.finishUsageAccounting(lease, acknowledged: acknowledged)
        } catch {
            DebugLog.warning(
                "Usage outbox acknowledgement could not be saved: \(error.localizedDescription)",
                context: "MobileAudioUsageAccounting"
            )
        }
    }
}
