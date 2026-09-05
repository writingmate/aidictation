import AppKit
import AuthenticationServices
import Foundation
import WhisperMateShared
internal import Combine

@MainActor
final class GoogleCalendarClient: ObservableObject {
    static let shared = GoogleCalendarClient()
    @Published private(set) var meetings: [MeetingCalendar.Meeting] = []
    @Published private(set) var calendars: [GoogleCalendarSummary] = []
    @Published private(set) var selectedCalendarIDs: Set<String> = []
    @Published private(set) var account: String?
    @Published private(set) var isConnecting = false
    @Published private(set) var isDisconnecting = false
    @Published private(set) var isRefreshing = false
    @Published private(set) var error: String?
    @Published private(set) var lastSynced: Date?
    @Published private var connectionID: String?
    var isConnected: Bool { connectionID != nil }

    private struct CalendarPage: Decodable { let items: [GoogleCalendarSummary]; let nextPageToken: String? }
    private struct EventPage: Decodable { let items: [GoogleCalendarEvent]; let nextPageToken: String? }
    private struct Connection: Codable { let id: String; let status: String }
    private struct Link: Decodable { let connectionID: String; let authorizationURL: URL }
    private struct Disconnection: Decodable { let disconnected: Bool }
    private struct Failure: Decodable { let error: String }
    private struct Cache: Codable {
        let userID: UUID
        let connectionID: String
        let calendars: [GoogleCalendarSummary]
        let meetings: [GoogleCalendarCachedMeeting]
        let selectedCalendarIDs: Set<String>
        let syncedAt: Date
    }

    private var cachedMeetings: [GoogleCalendarCachedMeeting] = []
    private let authorization = GoogleCalendarAuthorization()
    private var connectionTask: Task<Void, Never>?
    private var generation = UUID()
    private var refreshID = UUID()
    private var refreshTask: Task<Void, Never>?
    private var refreshLoop: Task<Void, Never>?
    private var subscriptions: Set<AnyCancellable> = []
    private let session: URLSession
    private let cacheURL: URL
    private var userID: UUID?
    private var selectionKey: String { "managedGoogleCalendarSelection." + (connectionID ?? "") }
    private var connectionKey: String { "managedGoogleCalendarConnection." + (userID?.uuidString ?? "") }

    private init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 40
        session = URLSession(configuration: config)
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier?.hasSuffix(".dev") == true ? "WhisperMate-Dev" : "WhisperMate")
        cacheURL = folder.appendingPathComponent("managed-google-calendar-cache.json")
        AuthManager.shared.$currentUser.map { $0?.id }.removeDuplicates()
            .receive(on: RunLoop.main).sink { [weak self] id in self?.restore(for: id) }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .debounce(for: .seconds(1), scheduler: RunLoop.main)
            .sink { [weak self] _ in Task { await self?.refreshIfNeeded() } }.store(in: &subscriptions)
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in Task { await self?.refreshIfNeeded() } }.store(in: &subscriptions)
        refreshLoop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshIfNeeded()
                do { try await Task.sleep(nanoseconds: 900_000_000_000) } catch { return }
            }
        }
    }

    func connect() async {
        guard !isConnecting, !isDisconnecting else { return }
        guard let userID = AuthManager.shared.currentUser?.id else { error = GoogleCalendarError.appSignIn.errorDescription; return }
        guard let window = NSApp.keyWindow ?? findMainWindow() else { error = GoogleCalendarError.signIn.errorDescription; return }
        if self.userID != userID { restore(for: userID) }
        let operation = UUID()
        generation = operation
        cancelRefresh()
        isConnecting = true
        error = nil
        let task = Task { await self.establishConnection(operation: operation, userID: userID, window: window) }
        connectionTask = task
        await task.value
        if generation == operation { isConnecting = false; connectionTask = nil }
    }

    private func establishConnection(operation: UUID, userID: UUID, window: NSWindow) async {
        var pendingID: String?
        let previousID = connectionID
        do {
            let link: Link = try await request([
                "action": "connect", "nonce": operation.uuidString,
                "channel": Bundle.main.bundleIdentifier?.hasSuffix(".dev") == true ? "development" : "production",
            ])
            pendingID = link.connectionID
            try Task.checkCancellation()
            guard generation == operation else { throw CancellationError() }
            try await authorization.signIn(url: link.authorizationURL, nonce: operation, presenting: window)
            let status: Connection = try await request(["action": "status", "connectionID": link.connectionID])
            guard status.status == "ACTIVE", status.id == link.connectionID else { throw GoogleCalendarError.access }
            try Task.checkCancellation()
            guard generation == operation, self.userID == userID else { throw CancellationError() }
            connectionID = link.connectionID
            UserDefaults.standard.set(link.connectionID, forKey: connectionKey)
            pendingID = nil
            cachedMeetings = []
            meetings = []
            calendars = []
            lastSynced = nil
            account = "Google Calendar"
            isConnecting = false
            await refresh()
            if let previousID, previousID != link.connectionID {
                let _: Disconnection? = try? await request(["action": "disconnect", "connectionID": previousID])
            }
        } catch {
            if generation == operation {
                let failure = error as NSError
                if !(error is CancellationError) && !(failure.domain == ASWebAuthenticationSessionError.errorDomain && failure.code == ASWebAuthenticationSessionError.canceledLogin.rawValue) {
                    self.error = error is MacNativeOperationDeadlineError
                        ? "Google sign-in timed out. Please try again."
                        : error.localizedDescription
                }
            }
        }
        if let pendingID {
            Task { let _: Disconnection? = try? await request(["action": "disconnect", "connectionID": pendingID]) }
        }
    }

    func disconnect() async {
        guard let id = connectionID, !isDisconnecting else { return }
        cancelConnection()
        cancelRefresh()
        let operation = generation
        isDisconnecting = true
        defer { if generation == operation { isDisconnecting = false } }
        do {
            let result: Disconnection = try await request(["action": "disconnect", "connectionID": id])
            guard generation == operation, result.disconnected else { return }
            UserDefaults.standard.removeObject(forKey: connectionKey)
            clearCalendar()
            try? FileManager.default.removeItem(at: cacheURL)
        } catch {
            guard generation == operation else { return }
            self.error = "Calendar couldn’t be disconnected. Please try again."
        }
    }

    func setCalendar(_ id: String, selected: Bool) {
        guard calendars.contains(where: { $0.id == id }) else { return }
        if selected { selectedCalendarIDs.insert(id) } else { selectedCalendarIDs.remove(id) }
        UserDefaults.standard.set(Array(selectedCalendarIDs).sorted(), forKey: selectionKey)
        cancelRefresh()
        updateDisplayedMeetings()
        Task { await refresh() }
    }

    private func refreshIfNeeded() async {
        updateDisplayedMeetings()
        guard GoogleCalendarSync.shouldRefresh(lastSynced: lastSynced, now: Date()) else { return }
        await refresh()
    }

    func refresh() async {
        guard connectionID != nil, !isConnecting, !isDisconnecting else { return }
        if let refreshTask { await refreshTask.value; return }
        let id = UUID()
        refreshID = id
        isRefreshing = true
        let task = Task<Void, Never> { [weak self] in await self?.sync(id: id) }
        refreshTask = task
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        if refreshID == id { refreshTask = nil; isRefreshing = false }
    }

    private func cancelRefresh() {
        refreshID = UUID()
        refreshTask?.cancel()
        refreshTask = nil
        isRefreshing = false
    }

    func cancelConnection() {
        generation = UUID()
        connectionTask?.cancel()
        authorization.cancel()
        connectionTask = nil
        isConnecting = false
        error = nil
    }

    func handle(_ url: URL) -> Bool { url.host == "google-calendar" }

    private func clearCalendar() {
        cachedMeetings = []
        connectionID = nil
        account = nil
        meetings = []
        calendars = []
        selectedCalendarIDs = []
        lastSynced = nil
        error = nil
    }

    private func restore(for id: UUID?) {
        guard userID != id else { return }
        cancelConnection()
        cancelRefresh()
        isDisconnecting = false
        clearCalendar()
        userID = id
        guard let id, let savedID = UserDefaults.standard.string(forKey: connectionKey) else { return }
        connectionID = savedID
        account = "Google Calendar"
        if let data = try? Data(contentsOf: cacheURL), let cache = try? JSONDecoder().decode(Cache.self, from: data),
           cache.userID == id, cache.connectionID == savedID {
            calendars = cache.calendars
            cachedMeetings = cache.meetings
            let selected = GoogleCalendarSync.selectedIDs(calendars: calendars,
                saved: UserDefaults.standard.stringArray(forKey: selectionKey))
            lastSynced = cache.selectedCalendarIDs == selected ? cache.syncedAt : nil
            account = calendars.first(where: { $0.primary == true })?.id ?? "Google Calendar"
        }
        selectedCalendarIDs = GoogleCalendarSync.selectedIDs(calendars: calendars,
            saved: UserDefaults.standard.stringArray(forKey: selectionKey))
        updateDisplayedMeetings()
        Task { await refreshIfNeeded() }
    }

    private func updateDisplayedMeetings() {
        meetings = GoogleCalendarSync.visibleMeetings(cachedMeetings, selected: selectedCalendarIDs, now: Date()).map {
            .init(id: $0.id, title: $0.title, start: $0.start, end: $0.end, color: NSColor.systemBlue.cgColor)
        }
    }

    private func sync(id: UUID) async {
        let operation = generation
        guard let connectionID, let userID else { return }
        let startedAt = Date()
        do {
            var available: [GoogleCalendarSummary] = []
            var nextPage: String?
            var seenPages = Set<String>()
            repeat {
                try checkDeadline(startedAt)
                var body = ["action": "calendars", "connectionID": connectionID]
                body["pageToken"] = nextPage
                let page: CalendarPage = try await request(body)
                available.append(contentsOf: page.items)
                nextPage = page.nextPageToken
                if let nextPage, !seenPages.insert(nextPage).inserted { throw GoogleCalendarError.response }
            } while nextPage != nil
            guard generation == operation, refreshID == id else { return }
            calendars = available
            account = available.first(where: { $0.primary == true })?.id ?? "Google Calendar"
            let selected = GoogleCalendarSync.selectedIDs(calendars: available,
                saved: UserDefaults.standard.stringArray(forKey: selectionKey))
            selectedCalendarIDs = selected
            updateDisplayedMeetings()
            var result: [GoogleCalendarCachedMeeting] = []
            for calendar in available where selected.contains(calendar.id) {
                nextPage = nil
                seenPages = []
                repeat {
                    try checkDeadline(startedAt)
                    var body = ["action": "events", "connectionID": connectionID, "calendarID": calendar.id]
                    body["pageToken"] = nextPage
                    let page: EventPage = try await request(body)
                    for event in page.items {
                        guard let interval = event.interval, interval.end > Date() else { continue }
                        result.append(.init(id: "google:\(calendar.id):\(event.id)", calendarID: calendar.id, title: event.summary ?? "Meeting",
                                            start: interval.start, end: interval.end))
                    }
                    nextPage = page.nextPageToken
                    if let nextPage, !seenPages.insert(nextPage).inserted { throw GoogleCalendarError.response }
                } while nextPage != nil
            }
            try Task.checkCancellation()
            guard generation == operation, refreshID == id else { return }
            let sorted = result.sorted { $0.start < $1.start }
            let syncedAt = Date()
            let cache = Cache(userID: userID, connectionID: connectionID, calendars: available, meetings: sorted, selectedCalendarIDs: selected, syncedAt: syncedAt)
            try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(cache).write(to: cacheURL, options: .atomic)
            cachedMeetings = sorted
            updateDisplayedMeetings()
            lastSynced = syncedAt
            error = nil
        } catch is CancellationError {
        } catch {
            guard generation == operation, refreshID == id else { return }
            self.error = error.localizedDescription
        }
    }

    private func checkDeadline(_ start: Date) throws {
        try Task.checkCancellation()
        guard Date().timeIntervalSince(start) < 90 else { throw GoogleCalendarError.response }
    }

    private func request<T: Decodable>(_ body: [String: String]) async throws -> T {
        guard let endpoint = SecretsLoader.getValue(for: "SUPABASE_URL"), let url = URL(string: endpoint), url.scheme == "https" else {
            throw GoogleCalendarError.unavailable
        }
        let owner = userID
        let token: String
        do { token = try await AuthManager.shared.accessToken() }
        catch { throw GoogleCalendarError.appSignIn }
        guard owner == userID, AuthManager.shared.currentUser?.id == owner else { throw CancellationError() }
        var request = URLRequest(url: url.appendingPathComponent("functions/v1/google-calendar"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(SecretsLoader.getValue(for: "SUPABASE_ANON_KEY"), forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let status = (response as? HTTPURLResponse)?.statusCode else { throw GoogleCalendarError.response }
        guard status == 200 else {
            if status == 401 { throw GoogleCalendarError.appSignIn }
            if let failure = try? JSONDecoder().decode(Failure.self, from: data) {
                throw NSError(domain: "GoogleCalendar", code: status, userInfo: [NSLocalizedDescriptionKey: failure.error])
            }
            throw GoogleCalendarError.response
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}
