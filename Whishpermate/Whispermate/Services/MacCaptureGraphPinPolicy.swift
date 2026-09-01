import Foundation

/// Pure policy for pinning a macOS capture graph to one HAL device and input
/// data source. Core Audio calls stay in AudioDeviceManager; this type only
/// decides when a drifted source must be restored and when hardware reapply
/// must wait until the pin ends.
enum MacCaptureGraphPinPolicy {
    static func shouldRestoreInputDataSource(pinned: UInt32?, current: UInt32?) -> Bool {
        guard let pinned else { return false }
        return current != pinned
    }

    static func shouldDeferHardwareReapply(isCapturePinned: Bool) -> Bool {
        isCapturePinned
    }
}
