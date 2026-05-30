import Foundation

public enum KeyboardDictationHandoff {
    public enum Command: String, Codable {
        case start
        case stop
        case shutdown
    }

    public static let appGroupIdentifier = "group.com.whispermate.shared"
    public static let openAppNotification = Notification.Name("KeyboardDictationHandoffOpenApp")
    public static let stopAppNotification = Notification.Name("KeyboardDictationHandoffStopApp")

    private static let pendingCommandKey = "keyboardDictation.pendingCommand"
    private static let pendingCommandSessionIDKey = "keyboardDictation.pendingCommandSessionID"
    private static let pendingCommandTimestampKey = "keyboardDictation.pendingCommandTimestamp"
    private static let pendingCommandQueueKey = "keyboardDictation.pendingCommandQueue"
    private static let pendingTextKey = "keyboardDictation.pendingText"
    private static let pendingTextSessionIDKey = "keyboardDictation.pendingTextSessionID"
    private static let pendingTextTimestampKey = "keyboardDictation.pendingTextTimestamp"
    private static let activeSessionIDKey = "keyboardDictation.activeSessionID"
    private static let activeSessionTimestampKey = "keyboardDictation.activeSessionTimestamp"
    private static let meterSessionIDKey = "keyboardDictation.meterSessionID"
    private static let meterAudioLevelKey = "keyboardDictation.meterAudioLevel"
    private static let meterFrequencyBandsKey = "keyboardDictation.meterFrequencyBands"
    private static let meterTimestampKey = "keyboardDictation.meterTimestamp"
    private static let appReadyTimestampKey = "keyboardDictation.appReadyTimestamp"
    private static let diagnosticsKey = "keyboardDictation.diagnostics"
    private static let pendingTextTTL: TimeInterval = 120
    private static let pendingCommandTTL: TimeInterval = 30
    private static let activeSessionTTL: TimeInterval = 180
    private static let meterTTL: TimeInterval = 2
    private static let appReadyTTL: TimeInterval = 2
    private static let diagnosticsLimit = 120

    private struct PendingCommand: Codable {
        let command: Command
        let sessionID: String?
        let timestamp: TimeInterval
    }

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
        DebugLog.info("beginSession sessionID=\(sessionID) appGroup=\(appGroupIdentifier)", context: "KEYBOARD_DIAG")
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
        let now = Date().timeIntervalSince1970
        var queue = loadPendingCommandQueue(from: defaults)
            .filter { now - $0.timestamp <= pendingCommandTTL }
        if let last = queue.last,
           last.command == command,
           last.sessionID == sessionID,
           now - last.timestamp < 2 {
            updateLegacyPendingCommand(command: command, sessionID: sessionID, timestamp: now, defaults: defaults)
            defaults.synchronize()
            DebugLog.info("dedupe command=\(command.rawValue) sessionID=\(sessionID ?? "nil") queueCount=\(queue.count)", context: "KEYBOARD_DIAG")
            return
        }

        queue.append(PendingCommand(command: command, sessionID: sessionID, timestamp: now))
        savePendingCommandQueue(queue, to: defaults)

        updateLegacyPendingCommand(command: command, sessionID: sessionID, timestamp: now, defaults: defaults)
        defaults.synchronize()
        DebugLog.info("publish command=\(command.rawValue) sessionID=\(sessionID ?? "nil") queueCount=\(queue.count)", context: "KEYBOARD_DIAG")
    }

    public static func consumePendingCommand() -> (command: Command, sessionID: String?)? {
        let defaults = defaults
        let now = Date().timeIntervalSince1970
        var queue = loadPendingCommandQueue(from: defaults)
            .filter { now - $0.timestamp <= pendingCommandTTL }
        if !queue.isEmpty {
            let pending = queue.removeFirst()
            savePendingCommandQueue(queue, to: defaults)
            if queue.isEmpty {
                clearLegacyPendingCommand(defaults)
            } else if let newest = queue.last {
                defaults.set(newest.command.rawValue, forKey: pendingCommandKey)
                defaults.set(newest.timestamp, forKey: pendingCommandTimestampKey)
                if let sessionID = newest.sessionID, !sessionID.isEmpty {
                    defaults.set(sessionID, forKey: pendingCommandSessionIDKey)
                } else {
                    defaults.removeObject(forKey: pendingCommandSessionIDKey)
                }
                defaults.synchronize()
            }
            DebugLog.info("consume queued command=\(pending.command.rawValue) sessionID=\(pending.sessionID ?? "nil") remaining=\(queue.count)", context: "KEYBOARD_DIAG")
            return (pending.command, pending.sessionID)
        }

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
        DebugLog.info("consume command=\(command.rawValue) sessionID=\(sessionID ?? "nil")", context: "KEYBOARD_DIAG")
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
        let now = Date().timeIntervalSince1970
        if let sessionID, !sessionID.isEmpty {
            defaults.set(sessionID, forKey: meterSessionIDKey)
            defaults.set(sessionID, forKey: activeSessionIDKey)
            defaults.set(now, forKey: activeSessionTimestampKey)
        } else {
            defaults.removeObject(forKey: meterSessionIDKey)
        }
        defaults.set(Double(audioLevel), forKey: meterAudioLevelKey)
        defaults.set(frequencyBands.map(Double.init), forKey: meterFrequencyBandsKey)
        defaults.set(now, forKey: meterTimestampKey)
        defaults.synchronize()
        if audioLevel > 0.02 {
            DebugLog.info("publish meter sessionID=\(sessionID ?? "nil") level=\(String(format: "%.3f", audioLevel)) bands=\(frequencyBands.count)", context: "KEYBOARD_DIAG")
        }
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

    public static func publishAppReady() {
        let defaults = defaults
        defaults.set(Date().timeIntervalSince1970, forKey: appReadyTimestampKey)
        defaults.synchronize()
    }

    public static func isAppReady() -> Bool {
        let timestamp = defaults.double(forKey: appReadyTimestampKey)
        return timestamp > 0 && Date().timeIntervalSince1970 - timestamp <= appReadyTTL
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
        defaults.removeObject(forKey: pendingCommandQueueKey)
        clearLegacyPendingCommand(defaults)
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

    public static func appendDiagnostic(_ message: String) {
        let defaults = defaults
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let entry = "\(timestamp) \(message)"
        var diagnostics = defaults.stringArray(forKey: diagnosticsKey) ?? []
        diagnostics.append(entry)
        if diagnostics.count > diagnosticsLimit {
            diagnostics.removeFirst(diagnostics.count - diagnosticsLimit)
        }
        defaults.set(diagnostics, forKey: diagnosticsKey)
        defaults.synchronize()
        DebugLog.info(entry, context: "KEYBOARD_DIAG")
    }

    public static func consumeDiagnostics() -> [String] {
        let defaults = defaults
        let diagnostics = defaults.stringArray(forKey: diagnosticsKey) ?? []
        guard !diagnostics.isEmpty else { return [] }
        defaults.removeObject(forKey: diagnosticsKey)
        defaults.synchronize()
        return diagnostics
    }

    private static func loadPendingCommandQueue(from defaults: UserDefaults) -> [PendingCommand] {
        guard let data = defaults.data(forKey: pendingCommandQueueKey),
              let queue = try? JSONDecoder().decode([PendingCommand].self, from: data)
        else {
            return []
        }
        return queue
    }

    private static func savePendingCommandQueue(_ queue: [PendingCommand], to defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(queue) else { return }
        defaults.set(data, forKey: pendingCommandQueueKey)
    }

    private static func clearLegacyPendingCommand(_ defaults: UserDefaults) {
        defaults.removeObject(forKey: pendingCommandKey)
        defaults.removeObject(forKey: pendingCommandSessionIDKey)
        defaults.removeObject(forKey: pendingCommandTimestampKey)
        defaults.synchronize()
    }

    private static func updateLegacyPendingCommand(command: Command, sessionID: String?, timestamp: TimeInterval, defaults: UserDefaults) {
        defaults.set(command.rawValue, forKey: pendingCommandKey)
        defaults.set(timestamp, forKey: pendingCommandTimestampKey)
        if let sessionID, !sessionID.isEmpty {
            defaults.set(sessionID, forKey: pendingCommandSessionIDKey)
            defaults.set(sessionID, forKey: activeSessionIDKey)
            defaults.set(timestamp, forKey: activeSessionTimestampKey)
        } else {
            defaults.removeObject(forKey: pendingCommandSessionIDKey)
        }
    }
}
