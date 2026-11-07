import Foundation

/// Persists review-prompt eligibility for the iOS host app.
///
/// Counts live in the shared app group so a later keyboard-side success can
/// use the same record. The system review dialog itself is only requested
/// from the host app while that app is at rest.
public enum ReviewPromptStore {
    private static let lock = NSLock()
    private static let defaults = UserDefaults(suiteName: KeyboardDictationHandoff.appGroupIdentifier) ?? .standard

    private enum Keys {
        static let successfulDictations = "reviewPromptSuccessfulDictations"
        static let distinctUsageDays = "reviewPromptDistinctUsageDays"
        static let lastUsageDay = "reviewPromptLastUsageDay"
        static let firstSuccessAt = "reviewPromptFirstSuccessAt"
        static let promptAttempts = "reviewPromptAttempts"
        static let lastPromptAttemptAt = "reviewPromptLastPromptAttemptAt"
        static let suppressUntil = "reviewPromptSuppressUntil"
        static let lastOutcomeSucceeded = "reviewPromptLastOutcomeSucceeded"
    }

    public static func recordSuccessfulDictation(
        _ text: String,
        deferPrompt: Bool = false,
        at date: Date = Date(),
        calendar: Calendar = .current
    ) {
        update { record in
            ReviewPromptPolicy.notingDictation(
                record,
                text: text,
                at: date,
                calendar: calendar,
                deferPrompt: deferPrompt
            )
        }
    }

    public static func recordFailedDictation() {
        update { ReviewPromptPolicy.notingFailure($0) }
    }

    /// Records an attempt only when the host may ask right now.
    /// Concurrent callers cannot both win.
    public static func claimPromptAttemptIfEligible(
        hostIsAtRest: Bool,
        at date: Date = Date()
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let record = loadUnlocked()
        guard ReviewPromptPolicy.shouldRequestReview(
            record: record,
            at: date,
            hostIsAtRest: hostIsAtRest
        ) else { return false }
        saveUnlocked(ReviewPromptPolicy.notingPromptAttempt(record, at: date))
        return true
    }

    /// The onboarding step always shows the ask. This only decides whether the
    /// system dialog may be presented again, and records that it was.
    public static func beginOnboardingReview(at date: Date = Date()) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let record = loadUnlocked()
        guard record.promptAttempts < ReviewPromptPolicy.maximumPromptAttempts else { return false }
        if let lastPromptAttemptAt = record.lastPromptAttemptAt,
           date.timeIntervalSince(lastPromptAttemptAt) < ReviewPromptPolicy.cooldown {
            return false
        }
        saveUnlocked(ReviewPromptPolicy.notingPromptAttempt(record, at: date))
        return true
    }

    private static func update(_ transform: (ReviewPromptRecord) -> ReviewPromptRecord) {
        lock.lock()
        defer { lock.unlock() }
        saveUnlocked(transform(loadUnlocked()))
    }

    private static func loadUnlocked() -> ReviewPromptRecord {
        ReviewPromptRecord(
            successfulDictations: defaults.integer(forKey: Keys.successfulDictations),
            distinctUsageDays: defaults.integer(forKey: Keys.distinctUsageDays),
            lastUsageDay: defaults.string(forKey: Keys.lastUsageDay) ?? "",
            firstSuccessAt: date(forKey: Keys.firstSuccessAt),
            promptAttempts: defaults.integer(forKey: Keys.promptAttempts),
            lastPromptAttemptAt: date(forKey: Keys.lastPromptAttemptAt),
            suppressUntil: date(forKey: Keys.suppressUntil),
            lastOutcomeSucceeded: defaults.bool(forKey: Keys.lastOutcomeSucceeded)
        )
    }

    private static func saveUnlocked(_ record: ReviewPromptRecord) {
        defaults.set(record.successfulDictations, forKey: Keys.successfulDictations)
        defaults.set(record.distinctUsageDays, forKey: Keys.distinctUsageDays)
        defaults.set(record.lastUsageDay, forKey: Keys.lastUsageDay)
        set(record.firstSuccessAt, forKey: Keys.firstSuccessAt)
        defaults.set(record.promptAttempts, forKey: Keys.promptAttempts)
        set(record.lastPromptAttemptAt, forKey: Keys.lastPromptAttemptAt)
        set(record.suppressUntil, forKey: Keys.suppressUntil)
        defaults.set(record.lastOutcomeSucceeded, forKey: Keys.lastOutcomeSucceeded)
    }

    private static func date(forKey key: String) -> Date? {
        guard defaults.object(forKey: key) != nil else { return nil }
        return Date(timeIntervalSince1970: defaults.double(forKey: key))
    }

    private static func set(_ date: Date?, forKey key: String) {
        if let date {
            defaults.set(date.timeIntervalSince1970, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}
