import Darwin
import Foundation

/// Deletes only the exact legacy recording child historically owned by the
/// macOS app. Decoded History URLs are untrusted input: an absolute outside
/// path, a different basename, or any symlinked app-owned ancestor is refused.
nonisolated enum MacHistoryAudioDeletion {
    enum Outcome: Equatable {
        case removed
        case absent
        case refused
        case failed
    }

    static func remove(
        recordingID: UUID,
        candidateURL: URL,
        applicationSupportDirectory: URL? = nil
    ) -> Outcome {
        let applicationSupport = applicationSupportDirectory
            ?? FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first
        guard let applicationSupport else { return .failed }

        let candidateName = candidateURL.lastPathComponent
        guard isAcceptedLegacyName(candidateName, recordingID: recordingID) else {
            return .refused
        }
        let expectedURL = applicationSupport
            .appendingPathComponent(applicationDirectoryName, isDirectory: true)
            .appendingPathComponent("Recordings", isDirectory: true)
            .appendingPathComponent(candidateName, isDirectory: false)
            .standardizedFileURL
        guard candidateURL.standardizedFileURL == expectedURL else {
            return .refused
        }

        let supportDescriptor = applicationSupport.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard supportDescriptor >= 0 else {
            return errno == ENOENT ? .absent : .refused
        }
        defer { _ = Darwin.close(supportDescriptor) }

        guard let appDescriptor = openDirectory(
            named: applicationDirectoryName,
            relativeTo: supportDescriptor
        ) else {
            return errno == ENOENT ? .absent : .refused
        }
        defer { _ = Darwin.close(appDescriptor) }

        guard let recordingsDescriptor = openDirectory(
            named: "Recordings",
            relativeTo: appDescriptor
        ) else {
            return errno == ENOENT ? .absent : .refused
        }
        defer { _ = Darwin.close(recordingsDescriptor) }

        var status = Darwin.stat()
        let statResult = candidateName.withCString {
            Darwin.fstatat(
                recordingsDescriptor,
                $0,
                &status,
                AT_SYMLINK_NOFOLLOW
            )
        }
        guard statResult == 0 else {
            return errno == ENOENT ? .absent : .failed
        }
        guard (status.st_mode & S_IFMT) == S_IFREG else {
            return .refused
        }

        let unlinkResult = candidateName.withCString {
            Darwin.unlinkat(recordingsDescriptor, $0, 0)
        }
        guard unlinkResult == 0 else {
            return errno == ENOENT ? .absent : .failed
        }
        return .removed
    }

    private static var applicationDirectoryName: String {
        Bundle.main.bundleIdentifier?.hasSuffix(".dev") == true
            ? "WhisperMate-Dev"
            : "WhisperMate"
    }

    private static func openDirectory(
        named name: String,
        relativeTo parent: Int32
    ) -> Int32? {
        guard !name.isEmpty, !name.contains("/") else { return nil }
        let descriptor = name.withCString {
            Darwin.openat(
                parent,
                $0,
                O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
            )
        }
        return descriptor >= 0 ? descriptor : nil
    }

    /// The app historically used `Date.timeIntervalSince1970` in these names
    /// before stable UUID filenames were introduced. Accept only that narrow,
    /// direct-child decimal shape; arbitrary decoded History basenames remain
    /// untrusted.
    private static func isAcceptedLegacyName(
        _ name: String,
        recordingID: UUID
    ) -> Bool {
        if name == "recording_\(recordingID.uuidString).m4a" {
            return true
        }

        let prefix = "recording_"
        let suffix = ".m4a"
        guard name.hasPrefix(prefix), name.hasSuffix(suffix) else { return false }
        let timestamp = String(name.dropFirst(prefix.count).dropLast(suffix.count))
        let parts = timestamp.split(
            separator: ".",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard parts.count == 1 || parts.count == 2,
              parts[0].count == 10,
              containsOnlyASCIIDigits(parts[0])
        else {
            return false
        }
        if parts.count == 2 {
            guard (1...9).contains(parts[1].count),
                  containsOnlyASCIIDigits(parts[1])
            else {
                return false
            }
        }
        return true
    }

    private static func containsOnlyASCIIDigits(_ value: Substring) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy { byte in
            byte >= 0x30 && byte <= 0x39
        }
    }
}
