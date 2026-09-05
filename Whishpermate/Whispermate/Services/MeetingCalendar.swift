import EventKit
import Foundation
internal import Combine

@MainActor
final class MeetingCalendar: ObservableObject {
    static let shared = MeetingCalendar()
    struct Meeting: Identifiable {
        let id: String
        let title: String
        let start: Date
        let end: Date
        let color: CGColor
    }
    @Published private(set) var meetings: [Meeting] = []
    @Published private(set) var hasAccess = false
    @Published private(set) var error: String?
    private let calendar = EKEventStore()
    private var observation: AnyCancellable?
    private var googleObservation: AnyCancellable?
    var isConnected: Bool { GoogleCalendarClient.shared.isConnected || hasAccess }

    private init() {
        observation = NotificationCenter.default.publisher(for: .EKEventStoreChanged)
            .receive(on: RunLoop.main).sink { [weak self] _ in self?.refresh() }
        googleObservation = GoogleCalendarClient.shared.$meetings
            .receive(on: RunLoop.main).sink { [weak self] _ in self?.refresh() }
        refresh()
    }

    func connect() async {
        do {
            let granted: Bool
            if #available(macOS 14.0, *) { granted = try await calendar.requestFullAccessToEvents() }
            else { granted = try await calendar.requestAccess(to: .event) }
            error = granted ? nil : "Allow calendar access in System Settings to see upcoming meetings."
            refresh()
        } catch {
            self.error = "Your calendars couldn’t be opened. You can still start a note."
        }
    }

    func refresh() {
        let status = EKEventStore.authorizationStatus(for: .event)
        if #available(macOS 14.0, *) { hasAccess = status == .fullAccess }
        else { hasAccess = status == .authorized }
        if GoogleCalendarClient.shared.isConnected {
            meetings = Array(GoogleCalendarClient.shared.meetings.prefix(5))
            return
        }
        guard hasAccess else { meetings = []; return }
        let now = Date()
        let predicate = calendar.predicateForEvents(withStart: now.addingTimeInterval(-3600),
            end: now.addingTimeInterval(7 * 24 * 60 * 60), calendars: nil)
        meetings = calendar.events(matching: predicate).filter { !$0.isAllDay && $0.endDate > now }
            .sorted { $0.startDate < $1.startDate }.prefix(3).map {
                Meeting(id: $0.calendarItemIdentifier + "-" + String($0.startDate.timeIntervalSince1970),
                        title: $0.title ?? "Meeting", start: $0.startDate, end: $0.endDate,
                        color: $0.calendar.cgColor)
            }
    }
}
