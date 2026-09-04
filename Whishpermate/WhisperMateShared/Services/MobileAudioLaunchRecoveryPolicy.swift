import Foundation

/// Launch-recovery decisions for the mobile audio processing store.
///
/// Directory fsync after a successful mkdir is durability insurance only.
/// iOS/APFS can fail that call even when the directory exists; store init
/// must not fall into the unavailable stub for that. Quarantine reset is a
/// separate last-resort path for a leftover `QUARANTINED` flag.
public enum MobileAudioLaunchRecoveryPolicy {
    public static var directoryCreationTreatsFsyncAsBestEffort: Bool {
        #if os(iOS)
            true
        #else
            false
        #endif
    }

    public static func acceptDirectoryCreationFsync(
        result: Int32,
        bestEffort: Bool = directoryCreationTreatsFsyncAsBestEffort
    ) -> Bool {
        result == 0 || bestEffort
    }
}
