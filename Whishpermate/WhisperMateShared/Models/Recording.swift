import Foundation

public struct Recording: Identifiable, Codable {
    public let id: UUID
    public let timestamp: Date
    public let transcription: String
    public let duration: TimeInterval?
    public let audioFileURL: URL?
    public let outputMode: TranscriptionOutputMode
    public let transcriptionOptions: TranscriptionOptions

    private enum CodingKeys: String, CodingKey {
        case id, timestamp, transcription, duration, audioFileURL, outputMode, transcriptionOptions
    }

    public init(id: UUID = UUID(), timestamp: Date = Date(), transcription: String, duration: TimeInterval? = nil, audioFileURL: URL? = nil, outputMode: TranscriptionOutputMode = .dictation, transcriptionOptions: TranscriptionOptions = .default) {
        self.id = id
        self.timestamp = timestamp
        self.transcription = transcription
        self.duration = duration
        self.audioFileURL = audioFileURL
        self.outputMode = outputMode
        self.transcriptionOptions = transcriptionOptions
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        transcription = try container.decode(String.self, forKey: .transcription)
        duration = try container.decodeIfPresent(TimeInterval.self, forKey: .duration)
        audioFileURL = try container.decodeIfPresent(URL.self, forKey: .audioFileURL)
        outputMode = try container.decodeIfPresent(TranscriptionOutputMode.self, forKey: .outputMode) ?? .dictation
        transcriptionOptions = try container.decodeIfPresent(TranscriptionOptions.self, forKey: .transcriptionOptions) ?? .default
    }

    public var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: timestamp)
    }

    public var formattedDuration: String? {
        guard let duration = duration else { return nil }
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        if minutes > 0 {
            return String(format: "%d:%02d", minutes, seconds)
        } else {
            return String(format: "%ds", seconds)
        }
    }
}
