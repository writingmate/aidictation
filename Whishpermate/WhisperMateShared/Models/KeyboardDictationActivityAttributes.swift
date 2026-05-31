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

        public init(sessionID: String) {
            self.sessionID = sessionID
        }
    }
#endif
