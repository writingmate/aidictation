import Foundation

nonisolated struct GoogleCalendarEvent: Decodable {
    struct Time: Decodable { let dateTime: String?; let date: String? }
    struct Attendee: Decodable {
        let isSelf: Bool?
        let responseStatus: String?
        enum CodingKeys: String, CodingKey { case isSelf = "self", responseStatus }
    }
    let id: String
    let summary: String?
    let status: String?
    let start: Time?
    let end: Time?
    let attendees: [Attendee]?

    var interval: DateInterval? {
        guard status != "cancelled", attendees?.contains(where: { $0.isSelf == true && $0.responseStatus == "declined" }) != true,
              let start = Self.date(start?.dateTime), let end = Self.date(end?.dateTime), end > start else { return nil }
        return DateInterval(start: start, end: end)
    }

    private static func date(_ value: String?) -> Date? {
        guard let value else { return nil }
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions.insert(.withFractionalSeconds)
        return formatter.date(from: value)
    }
}
