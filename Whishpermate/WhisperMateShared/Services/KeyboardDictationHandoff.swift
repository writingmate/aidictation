import Foundation

public enum KeyboardDictationHandoff {
    public enum Command: String {
        case start
        case stop
    }

    public static let appGroupIdentifier = "group.com.whispermate.shared"
    public static let openAppNotification = Notification.Name("KeyboardDictationHandoffOpenApp")
    public static let stopAppNotification = Notification.Name("KeyboardDictationHandoffStopApp")

    private static let pendingCommandKey = "keyboardDictation.pendingCommand"
    private static let pendingCommandSessionIDKey = "keyboardDictation.pendingCommandSessionID"
    private static let pendingCommandTimestampKey = "keyboardDictation.pendingCommandTimestamp"
    private static let pendingTextKey = "keyboardDictation.pendingText"
    private static let pendingTextSessionIDKey = "keyboardDictation.pendingTextSessionID"
    private static let pendingTextTimestampKey = "keyboardDictation.pendingTextTimestamp"
    private static let activeSessionIDKey = "keyboardDictation.activeSessionID"
    private static let activeSessionTimestampKey = "keyboardDictation.activeSessionTimestamp"
    private static let meterSessionIDKey = "keyboardDictation.meterSessionID"
    private static let meterAudioLevelKey = "keyboardDictation.meterAudioLevel"
    private static let meterFrequencyBandsKey = "keyboardDictation.meterFrequencyBands"
    private static let meterTimestampKey = "keyboardDictation.meterTimestamp"
    private static let pendingTextTTL: TimeInterval = 120
    private static let pendingCommandTTL: TimeInterval = 30
    private static let activeSessionTTL: TimeInterval = 180
    private static let meterTTL: TimeInterval = 2

    public static var defaults: UserDefaults {
        UserDefaults(suiteName: appGroupIdentifier) ?? .standard
    }

    public static func makeDictationURL(sessionID: String) -> URL? {
        URL(string: "aidictation://keyboard-dictation?session=\(sessionID)")
    }

    public static func makeStopDictationURL(sessionID: String) -> URL? {
        URL(string: "aidictation://keyboard-dictation-stop?session=\(sessionID)")
    }

    @discardableResult
    public static func beginSession(sessionID: String = UUID().uuidString) -> String {
        let defaults = defaults
        defaults.set(sessionID, forKey: activeSessionIDKey)
        defaults.set(Date().timeIntervalSince1970, forKey: activeSessionTimestampKey)
        clearPendingText()
        clearPendingCommand()
        clearMeter()
        defaults.synchronize()
        return sessionID
    }

    public static func activeSessionID() -> String? {
        let defaults = defaults
        guard let sessionID = defaults.string(forKey: activeSessionIDKey), !sessionID.isEmpty else {
            return nil
        }

        let timestamp = defaults.double(forKey: activeSessionTimestampKey)
        if timestamp > 0, Date().timeIntervalSince1970 - timestamp > activeSessionTTL {
            clearActiveSession()
            return nil
        }

        return sessionID
    }

    public static func publish(command: Command, sessionID: String?) {
        let defaults = defaults
        defaults.set(command.rawValue, forKey: pendingCommandKey)
        defaults.set(Date().timeIntervalSince1970, forKey: pendingCommandTimestampKey)
        if let sessionID, !sessionID.isEmpty {
            defaults.set(sessionID, forKey: pendingCommandSessionIDKey)
            defaults.set(sessionID, forKey: activeSessionIDKey)
            defaults.set(Date().timeIntervalSince1970, forKey: activeSessionTimestampKey)
        } else {
            defaults.removeObject(forKey: pendingCommandSessionIDKey)
        }
        defaults.synchronize()
    }

    public static func consumePendingCommand() -> (command: Command, sessionID: String?)? {
        let defaults = defaults
        guard let rawCommand = defaults.string(forKey: pendingCommandKey),
              let command = Command(rawValue: rawCommand)
        else {
            return nil
        }

        let timestamp = defaults.double(forKey: pendingCommandTimestampKey)
        if timestamp > 0, Date().timeIntervalSince1970 - timestamp > pendingCommandTTL {
            clearPendingCommand()
            return nil
        }

        let sessionID = defaults.string(forKey: pendingCommandSessionIDKey)
        clearPendingCommand()
        return (command, sessionID)
    }

    public static func publish(text: String, sessionID: String?) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let defaults = defaults
        defaults.set(trimmed, forKey: pendingTextKey)
        defaults.set(Date().timeIntervalSince1970, forKey: pendingTextTimestampKey)
        if let sessionID, !sessionID.isEmpty {
            defaults.set(sessionID, forKey: pendingTextSessionIDKey)
        } else {
            defaults.removeObject(forKey: pendingTextSessionIDKey)
        }
        defaults.synchronize()
    }

    public static func publishMeter(audioLevel: Float, frequencyBands: [Float], sessionID: String?) {
        let defaults = defaults
        if let sessionID, !sessionID.isEmpty {
            defaults.set(sessionID, forKey: meterSessionIDKey)
        } else {
            defaults.removeObject(forKey: meterSessionIDKey)
        }
        defaults.set(Double(audioLevel), forKey: meterAudioLevelKey)
        defaults.set(frequencyBands.map(Double.init), forKey: meterFrequencyBandsKey)
        defaults.set(Date().timeIntervalSince1970, forKey: meterTimestampKey)
        defaults.synchronize()
    }

    public static func consumeMeter(for sessionID: String?) -> (audioLevel: Float, frequencyBands: [Float])? {
        let defaults = defaults
        let timestamp = defaults.double(forKey: meterTimestampKey)
        guard timestamp > 0, Date().timeIntervalSince1970 - timestamp <= meterTTL else {
            return nil
        }

        let meterSessionID = defaults.string(forKey: meterSessionIDKey)
        if let sessionID, let meterSessionID, meterSessionID != sessionID {
            return nil
        }

        let audioLevel = Float(defaults.double(forKey: meterAudioLevelKey))
        let bands = (defaults.array(forKey: meterFrequencyBandsKey) as? [Double])?.map(Float.init) ?? []
        guard !bands.isEmpty else {
            return nil
        }

        return (audioLevel, bands)
    }

    public static func consumePendingText(for sessionID: String?) -> String? {
        let defaults = defaults
        guard let text = defaults.string(forKey: pendingTextKey), !text.isEmpty else {
            return nil
        }

        let timestamp = defaults.double(forKey: pendingTextTimestampKey)
        if timestamp > 0, Date().timeIntervalSince1970 - timestamp > pendingTextTTL {
            clearPendingText()
            return nil
        }

        let pendingSessionID = defaults.string(forKey: pendingTextSessionIDKey)
        if let sessionID, let pendingSessionID, pendingSessionID != sessionID {
            return nil
        }

        clearPendingText()
        clearActiveSession()
        return text
    }

    public static func sessionID(from url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "session" })?
            .value
    }

    public static func clearPendingText() {
        let defaults = defaults
        defaults.removeObject(forKey: pendingTextKey)
        defaults.removeObject(forKey: pendingTextSessionIDKey)
        defaults.removeObject(forKey: pendingTextTimestampKey)
    }

    public static func clearPendingCommand() {
        let defaults = defaults
        defaults.removeObject(forKey: pendingCommandKey)
        defaults.removeObject(forKey: pendingCommandSessionIDKey)
        defaults.removeObject(forKey: pendingCommandTimestampKey)
    }

    public static func clearActiveSession() {
        let defaults = defaults
        defaults.removeObject(forKey: activeSessionIDKey)
        defaults.removeObject(forKey: activeSessionTimestampKey)
        clearMeter()
    }

    public static func clearMeter() {
        let defaults = defaults
        defaults.removeObject(forKey: meterSessionIDKey)
        defaults.removeObject(forKey: meterAudioLevelKey)
        defaults.removeObject(forKey: meterFrequencyBandsKey)
        defaults.removeObject(forKey: meterTimestampKey)
    }
}
