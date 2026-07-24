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

        let expectedName = "recording_\(recordingID.uuidString).m4a"
        let expectedURL = applicationSupport
            .appendingPathComponent("WhisperMate", isDirectory: true)
            .appendingPathComponent("Recordings", isDirectory: true)
            .appendingPathComponent(expectedName, isDirectory: false)
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
            named: "WhisperMate",
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
        let statResult = expectedName.withCString {
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

        let unlinkResult = expectedName.withCString {
            Darwin.unlinkat(recordingsDescriptor, $0, 0)
        }
        guard unlinkResult == 0 else {
            return errno == ENOENT ? .absent : .failed
        }
        return .removed
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
}
