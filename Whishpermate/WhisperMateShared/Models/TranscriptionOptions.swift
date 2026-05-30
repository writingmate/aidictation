import Foundation

public struct TranscriptionOptions: Codable, Equatable, Hashable, Sendable {
    public var diarization: Bool

    public init(diarization: Bool = false) {
        self.diarization = diarization
    }

    public static let `default` = TranscriptionOptions()
}
