import Foundation

/// Decides when a mobile app may ask the system for a store review.
///
/// The system dialog is quota-limited and may not appear, so it is never tied
/// to a button. A Settings row opens the store listing instead. The dialog is
/// reserved for a calm moment in the main app, after dictation has already
/// been useful on more than one day. Keyboard and shortcut sessions defer the
/// ask so it does not cover the app the user is typing in.
public struct ReviewPromptRecord: Equatable, Sendable {
    public var successfulDictations: Int
    public var distinctUsageDays: Int
    public var lastUsageDay: String
    public var firstSuccessAt: Date?
    public var promptAttempts: Int
    public var lastPromptAttemptAt: Date?
    public var suppressUntil: Date?
    public var lastOutcomeSucceeded: Bool

    public init(
        successfulDictations: Int = 0,
        distinctUsageDays: Int = 0,
        lastUsageDay: String = "",
        firstSuccessAt: Date? = nil,
        promptAttempts: Int = 0,
        lastPromptAttemptAt: Date? = nil,
        suppressUntil: Date? = nil,
        lastOutcomeSucceeded: Bool = false
    ) {
        self.successfulDictations = successfulDictations
        self.distinctUsageDays = distinctUsageDays
        self.lastUsageDay = lastUsageDay
        self.firstSuccessAt = firstSuccessAt
        self.promptAttempts = promptAttempts
        self.lastPromptAttemptAt = lastPromptAttemptAt
        self.suppressUntil = suppressUntil
        self.lastOutcomeSucceeded = lastOutcomeSucceeded
    }

    public static let empty = ReviewPromptRecord()
}

public enum ReviewPromptPolicy {
    public static let minimumSuccessfulDictations = 5
    public static let minimumDistinctUsageDays = 3
    public static let minimumAgeSinceFirstSuccess: TimeInterval = 3 * 24 * 60 * 60
    public static let cooldown: TimeInterval = 120 * 24 * 60 * 60
    public static let maximumPromptAttempts = 3
    public static let returnSuppression: TimeInterval = 30

    public static func dayKey(for date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    public static func notingDictation(
        _ record: ReviewPromptRecord,
        text: String,
        at date: Date,
        calendar: Calendar,
        deferPrompt: Bool
    ) -> ReviewPromptRecord {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return notingFailure(record) }

        var next = record
        next.successfulDictations += 1
        next.lastOutcomeSucceeded = true
        if next.firstSuccessAt == nil {
            next.firstSuccessAt = date
        }
        let day = dayKey(for: date, calendar: calendar)
        if day != next.lastUsageDay {
            next.distinctUsageDays += 1
            next.lastUsageDay = day
        }
        if deferPrompt {
            let until = date.addingTimeInterval(returnSuppression)
            if next.suppressUntil.map({ until > $0 }) ?? true {
                next.suppressUntil = until
            }
        }
        return next
    }

    public static func notingFailure(_ record: ReviewPromptRecord) -> ReviewPromptRecord {
        var next = record
        next.lastOutcomeSucceeded = false
        return next
    }

    public static func notingPromptAttempt(
        _ record: ReviewPromptRecord,
        at date: Date
    ) -> ReviewPromptRecord {
        var next = record
        next.promptAttempts += 1
        next.lastPromptAttemptAt = date
        return next
    }

    public static func shouldRequestReview(
        record: ReviewPromptRecord,
        at date: Date,
        hostIsAtRest: Bool
    ) -> Bool {
        guard hostIsAtRest, record.lastOutcomeSucceeded else { return false }
        guard record.successfulDictations >= minimumSuccessfulDictations else { return false }
        guard record.distinctUsageDays >= minimumDistinctUsageDays else { return false }
        guard let firstSuccessAt = record.firstSuccessAt,
              date.timeIntervalSince(firstSuccessAt) >= minimumAgeSinceFirstSuccess
        else { return false }
        guard record.promptAttempts < maximumPromptAttempts else { return false }
        if let lastPromptAttemptAt = record.lastPromptAttemptAt,
           date.timeIntervalSince(lastPromptAttemptAt) < cooldown {
            return false
        }
        if let suppressUntil = record.suppressUntil, date < suppressUntil {
            return false
        }
        return true
    }
}
