import Foundation
import WhisperMateShared

enum TranscriptionStatus: String, Codable {
    case success
    case failed
    case retrying
}

struct Recording: Identifiable, Codable, Hashable {
    let id: UUID
    let timestamp: Date
    let audioFileURL: URL
    var transcription: String?
    var status: TranscriptionStatus
    var errorMessage: String?
    var retryCount: Int
    let duration: TimeInterval?
    var wordCount: Int?
    var outputMode: TranscriptionOutputMode
    var transcriptionOptions: TranscriptionOptions

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case id, timestamp, audioFilePath, transcription, status, errorMessage, retryCount, duration, wordCount, outputMode, transcriptionOptions
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        let path = try container.decode(String.self, forKey: .audioFilePath)
        audioFileURL = URL(fileURLWithPath: path)
        transcription = try container.decodeIfPresent(String.self, forKey: .transcription)
        status = try container.decode(TranscriptionStatus.self, forKey: .status)
        errorMessage = try container.decodeIfPresent(String.self, forKey: .errorMessage)
        retryCount = try container.decode(Int.self, forKey: .retryCount)
        duration = try container.decodeIfPresent(TimeInterval.self, forKey: .duration)
        wordCount = try container.decodeIfPresent(Int.self, forKey: .wordCount)
        outputMode = try container.decodeIfPresent(TranscriptionOutputMode.self, forKey: .outputMode) ?? .dictation
        transcriptionOptions = try container.decodeIfPresent(TranscriptionOptions.self, forKey: .transcriptionOptions) ?? .default
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encode(audioFileURL.path, forKey: .audioFilePath)
        try container.encodeIfPresent(transcription, forKey: .transcription)
        try container.encode(status, forKey: .status)
        try container.encodeIfPresent(errorMessage, forKey: .errorMessage)
        try container.encode(retryCount, forKey: .retryCount)
        try container.encodeIfPresent(duration, forKey: .duration)
        try container.encodeIfPresent(wordCount, forKey: .wordCount)
        try container.encode(outputMode, forKey: .outputMode)
        try container.encode(transcriptionOptions, forKey: .transcriptionOptions)
    }

    // MARK: - Hashable

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: Recording, rhs: Recording) -> Bool {
        lhs.id == rhs.id
    }

    // MARK: - Initialization

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        audioFileURL: URL,
        transcription: String? = nil,
        status: TranscriptionStatus = .success,
        errorMessage: String? = nil,
        retryCount: Int = 0,
        duration: TimeInterval? = nil,
        wordCount: Int? = nil,
        outputMode: TranscriptionOutputMode = .dictation,
        transcriptionOptions: TranscriptionOptions = .default
    ) {
        self.id = id
        self.timestamp = timestamp
        self.audioFileURL = audioFileURL
        self.transcription = transcription
        self.status = status
        self.errorMessage = errorMessage
        self.retryCount = retryCount
        self.duration = duration
        self.wordCount = wordCount
        self.outputMode = outputMode
        self.transcriptionOptions = transcriptionOptions
    }

    var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: timestamp)
    }

    var formattedDuration: String? {
        guard let duration = duration else { return nil }
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        if minutes > 0 {
            return String(format: "%d:%02d", minutes, seconds)
        } else {
            return String(format: "%ds", seconds)
        }
    }

    var isSuccessful: Bool {
        return status == .success
    }

    var isFailed: Bool {
        return status == .failed
    }

    var isNotes: Bool {
        outputMode == .notes
    }
}
