#if os(iOS)
import Foundation

@MainActor
public enum MobileInstallationAnalytics {
    private struct Event: Codable {
        let event_id: String
        let installation_id: String
        let anonymous_id: String
        let platform: String
        let event_name: String
        let word_count: Int
        let user_id: String?
    }

    private static let installationKey = "mobileAnalyticsInstallationID"
    private static let anonymousKey = "mobileAnalyticsAnonymousID"
    private static let lastUserKey = "mobileAnalyticsLastUserID"
    private static let pendingKey = "pendingMobileInstallationEvents"
    private static var flushing = false
    private static var retryScheduled = false
    private static var lastSignedInUser: UUID?
    private static var lastOpenAt: Date?
    private static let defaults = UserDefaults(suiteName: KeyboardDictationHandoff.appGroupIdentifier) ?? AppDefaults.shared

    private static func storedID(for key: String) -> String? {
        if let stored = defaults.string(forKey: key), UUID(uuidString: stored) != nil {
            return stored
        }
        if let previous = AppDefaults.shared.string(forKey: key), UUID(uuidString: previous) != nil {
            defaults.set(previous, forKey: key)
            return previous
        }
        return nil
    }

    private static var installationID: String {
        if let stored = storedID(for: installationKey) {
            return stored
        }
        let created = UUID().uuidString.lowercased()
        defaults.set(created, forKey: installationKey)
        return created
    }

    private static var anonymousID: String {
        if let stored = storedID(for: anonymousKey) {
            return stored
        }
        let created = UUID().uuidString.lowercased()
        defaults.set(created, forKey: anonymousKey)
        return created
    }

    private static func rotateAnonymousID() {
        defaults.set(UUID().uuidString.lowercased(), forKey: anonymousKey)
    }

    private static var pending: [Event] {
        get {
            guard let data = defaults.data(forKey: pendingKey) else { return [] }
            return (try? JSONDecoder().decode([Event].self, from: data)) ?? []
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: pendingKey)
            }
        }
    }

    public static func start() {
        appOpened()
        Task { await flush() }
    }

    public static func appOpened() {
        let now = Date()
        if let lastOpenAt, now.timeIntervalSince(lastOpenAt) < 3 { return }
        lastOpenAt = now
        record("app_opened", eventID: UUID(), words: 0)
    }

    public static func signedIn(_ userID: UUID) {
        guard lastSignedInUser != userID else { return }
        let canonicalID = userID.uuidString.lowercased()
        if let previous = defaults.string(forKey: lastUserKey), previous != canonicalID {
            rotateAnonymousID()
        }
        defaults.set(canonicalID, forKey: lastUserKey)
        lastSignedInUser = userID
        record("signed_in", eventID: UUID(), words: 0)
    }

    public static func signedOut() {
        guard lastSignedInUser != nil else { return }
        lastSignedInUser = nil
        defaults.removeObject(forKey: lastUserKey)
        rotateAnonymousID()
    }

    @discardableResult
    public static func transcriptionCompleted(recordingID: UUID, words: Int) -> Bool {
        guard words > 0 else { return true }
        return record("transcription_completed", eventID: recordingID, words: words)
    }

    @discardableResult
    private static func record(_ name: String, eventID: UUID, words: Int) -> Bool {
        let id = eventID.uuidString.lowercased()
        var events = pending
        guard !events.contains(where: { $0.event_id == id }) else { return defaults.synchronize() }
        events.append(Event(
            event_id: id,
            installation_id: installationID,
            anonymous_id: anonymousID,
            platform: "ios",
            event_name: name,
            word_count: words,
            user_id: AuthManager.shared.currentUser?.userId.uuidString.lowercased()
        ))
        guard let data = try? JSONEncoder().encode(events) else { return false }
        defaults.set(data, forKey: pendingKey)
        guard defaults.synchronize() else { return false }
        Task { await flush() }
        return true
    }

    private static func flush() async {
        guard !flushing else { return }
        guard let origin = SecretsLoader.getValue(for: "SUPABASE_URL"),
              let url = URL(string: origin.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/api/installation-event")
        else { return }

        flushing = true
        defer { flushing = false }
        while let event = pending.first(where: {
            $0.user_id == nil || $0.user_id == AuthManager.shared.currentUser?.userId.uuidString.lowercased()
        }) {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 8
            request.setValue("application/json", forHTTPHeaderField: "content-type")
            request.httpBody = try? JSONEncoder().encode(event)
            if let userID = event.user_id {
                guard AuthManager.shared.currentUser?.userId.uuidString.lowercased() == userID,
                      let token = try? await AuthManager.shared.accessToken()
                else {
                    scheduleRetry()
                    return
                }
                request.setValue("Bearer \(token)", forHTTPHeaderField: "authorization")
            }

            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                guard let response = response as? HTTPURLResponse else {
                    scheduleRetry()
                    return
                }
                if !(200..<300).contains(response.statusCode) {
                    if (400..<500).contains(response.statusCode),
                       response.statusCode != 401, response.statusCode != 429 {
                        remove(event.event_id)
                        continue
                    }
                    scheduleRetry()
                    return
                }
                remove(event.event_id)
            } catch {
                scheduleRetry()
                return
            }
        }
    }

    private static func remove(_ eventID: String) {
        pending = pending.filter { $0.event_id != eventID }
    }

    private static func scheduleRetry() {
        guard !retryScheduled else { return }
        retryScheduled = true
        Task {
            try? await Task.sleep(nanoseconds: 60_000_000_000)
            retryScheduled = false
            await flush()
        }
    }
}
#endif
