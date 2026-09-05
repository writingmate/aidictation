import Foundation

nonisolated struct GoogleCalendarSummary: Codable, Identifiable, Equatable {
    let id: String
    let summary: String?
    let selected: Bool?
    let primary: Bool?
    let backgroundColor: String?
    var title: String { summary ?? id }
}

nonisolated enum GoogleCalendarSync {
    static func shouldRefresh(lastSynced: Date?, now: Date) -> Bool {
        guard let lastSynced else { return true }
        return now.timeIntervalSince(lastSynced) >= 15 * 60
    }

    static func isManagedAuthorizationURL(_ url: URL) -> Bool {
        url.scheme == "https" && url.host == "connect.composio.dev" && url.user == nil && url.password == nil
    }

    static func isAuthorizationCallback(_ url: URL, scheme: String, nonce: UUID) -> Bool {
        guard url.scheme == scheme, url.host == "google-calendar",
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        let states = (parts.queryItems ?? []).filter { $0.name == "state" }
        return states.count == 1 && states[0].value == nonce.uuidString
    }

    static func selectedIDs(calendars: [GoogleCalendarSummary], saved: [String]?) -> Set<String> {
        let available = Set(calendars.map(\.id))
        if let saved { return Set(saved).intersection(available) }
        return Set(calendars.filter { $0.selected == true || $0.primary == true }.map(\.id))
    }


}

nonisolated enum GoogleCalendarError: LocalizedError {
    case signIn, access, response, appSignIn, unavailable
    var errorDescription: String? {
        switch self {
        case .signIn: return "Google sign-in couldn’t be completed. Please try again."
        case .access: return "Allow calendar access to sync your meetings."
        case .response: return "Google Calendar couldn’t be refreshed. Your last synced meetings are still available."
        case .appSignIn: return "Sign in to AIDictation in General settings to connect your calendar."
        case .unavailable: return "Google Calendar connection is not available yet. Please try again later."
        }
    }
}
