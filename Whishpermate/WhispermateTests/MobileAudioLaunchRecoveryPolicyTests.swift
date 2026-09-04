import XCTest

/// Covers the launch-recovery policy that decides whether a failed directory
/// fsync after mkdir can brick iOS recording. Artsiom's 0.0.102 device never
/// created WhisperMate/MobileAudioProcessing because parent fsync threw.
final class MobileAudioLaunchRecoveryPolicyTests: XCTestCase {
    func testSuccessfulDirectoryFsyncIsAlwaysAccepted() {
        XCTAssertTrue(
            MobileAudioLaunchRecoveryPolicy.acceptDirectoryCreationFsync(
                result: 0,
                bestEffort: false
            )
        )
        XCTAssertTrue(
            MobileAudioLaunchRecoveryPolicy.acceptDirectoryCreationFsync(
                result: 0,
                bestEffort: true
            )
        )
    }

    func testIOSBestEffortAcceptsFailedDirectoryFsync() {
        XCTAssertTrue(
            MobileAudioLaunchRecoveryPolicy.acceptDirectoryCreationFsync(
                result: -1,
                bestEffort: true
            )
        )
    }

    func testRequiredDirectoryFsyncStillFailsClosed() {
        XCTAssertFalse(
            MobileAudioLaunchRecoveryPolicy.acceptDirectoryCreationFsync(
                result: -1,
                bestEffort: false
            )
        )
    }

    func testProductionDefaultMatchesPlatform() {
        #if os(iOS)
            XCTAssertTrue(MobileAudioLaunchRecoveryPolicy.directoryCreationTreatsFsyncAsBestEffort)
            XCTAssertTrue(MobileAudioLaunchRecoveryPolicy.acceptDirectoryCreationFsync(result: -1))
        #else
            XCTAssertFalse(MobileAudioLaunchRecoveryPolicy.directoryCreationTreatsFsyncAsBestEffort)
            XCTAssertFalse(MobileAudioLaunchRecoveryPolicy.acceptDirectoryCreationFsync(result: -1))
        #endif
    }
}
