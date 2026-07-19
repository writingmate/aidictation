import Foundation

#if os(iOS) && canImport(ActivityKit)
    import ActivityKit

    @available(iOS 16.2, *)
    public struct KeyboardDictationActivityAttributes: ActivityAttributes {
        public struct ContentState: Codable, Hashable {
            public var phase: Phase
            public var startedAt: Date

            public init(phase: Phase, startedAt: Date) {
                self.phase = phase
                self.startedAt = startedAt
            }
        }

        public enum Phase: String, Codable, Hashable {
            case listening
            case processing
        }

        public var sessionID: String
        public var attemptID: String
        public var generation: UInt64

        private enum CodingKeys: String, CodingKey {
            case sessionID
            case attemptID
            case generation
        }

        /// Compatibility initializer for an activity created by an older app build.
        public init(sessionID: String) {
            self.sessionID = sessionID
            attemptID = ""
            generation = 0
        }

        public init(identity: KeyboardDictationHandoff.AttemptIdentity) {
            sessionID = identity.sessionID
            attemptID = identity.attemptID
            generation = identity.generation
        }

        public init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            sessionID = try values.decode(String.self, forKey: .sessionID)
            attemptID = try values.decodeIfPresent(String.self, forKey: .attemptID) ?? ""
            generation = try values.decodeIfPresent(UInt64.self, forKey: .generation) ?? 0
        }

        public func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(sessionID, forKey: .sessionID)
            try values.encode(attemptID, forKey: .attemptID)
            try values.encode(generation, forKey: .generation)
        }
    }
#endif
