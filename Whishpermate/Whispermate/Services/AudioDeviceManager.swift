import AVFoundation
import CoreAudio
import Foundation
import WhisperMateShared
internal import Combine

/// Manages audio input device enumeration and selection using Core Audio
class AudioDeviceManager: ObservableObject {
    static let shared = AudioDeviceManager()

    private enum Keys {
        static let selectedAudioDeviceID = "selectedAudioDeviceID"
        static let automaticallySelectAudioDevice = "automaticallySelectAudioDevice"
    }

    @Published private(set) var inputDevices: [AudioDevice] = []
    @Published private(set) var selectedDevice: AudioDevice?
    @Published private(set) var automaticallySelectDevice: Bool

    // MARK: - Types

    struct AudioDevice: Identifiable, Equatable, Hashable {
        let id: AudioDeviceID
        let name: String
        let uniqueID: String

        var localizedName: String { name }

        static func == (lhs: AudioDevice, rhs: AudioDevice) -> Bool {
            return lhs.uniqueID == rhs.uniqueID
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(uniqueID)
        }
    }

    // MARK: - Initialization

    private init() {
        automaticallySelectDevice = AppDefaults.shared.object(forKey: Keys.automaticallySelectAudioDevice) as? Bool ?? true
        refreshDevices()
        setupDeviceChangeListener()
    }

    // MARK: - Public API

    func refreshDevices() {
        inputDevices = getInputDevices()
        selectedDevice = currentSelectedDevice(in: inputDevices)
    }

    func setAutomaticSelection(_ enabled: Bool) {
        automaticallySelectDevice = enabled
        AppDefaults.shared.set(enabled, forKey: Keys.automaticallySelectAudioDevice)
        if enabled {
            AppDefaults.shared.removeObject(forKey: Keys.selectedAudioDeviceID)
        }
        _ = applyPreferredOrAutomaticDevice()
    }

    func selectDevice(_ device: AudioDevice) -> Bool {
        let success = setDefaultInputDevice(deviceID: device.id)
        guard success else {
            refreshDevices()
            return false
        }

        automaticallySelectDevice = false
        AppDefaults.shared.set(false, forKey: Keys.automaticallySelectAudioDevice)
        AppDefaults.shared.set(device.uniqueID, forKey: Keys.selectedAudioDeviceID)
        selectedDevice = device

        NotificationCenter.default.post(
            name: NSNotification.Name("AudioInputDeviceChanged"),
            object: device.uniqueID
        )
        return true
    }

    @discardableResult
    func applyPreferredOrAutomaticDevice() -> AudioDevice? {
        refreshDevices()

        let target: AudioDevice?
        if automaticallySelectDevice {
            target = bestAutomaticInputDevice(in: inputDevices)
        } else {
            target = selectedDevice ?? bestAutomaticInputDevice(in: inputDevices)
        }

        guard let target else { return nil }

        if getDefaultInputDevice()?.uniqueID != target.uniqueID {
            DebugLog.info("Applying input device: \(target.name)", context: "AudioDeviceManager")
            guard setDefaultInputDevice(deviceID: target.id) else {
                refreshDevices()
                return selectedDevice
            }
            NotificationCenter.default.post(
                name: NSNotification.Name("AudioInputDeviceChanged"),
                object: target.uniqueID
            )
        }

        selectedDevice = target
        return target
    }

    func getInputDevices() -> [AudioDevice] {
        var devices: [AudioDevice] = []

        // Get list of all audio devices
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &dataSize
        )

        guard status == noErr else { return devices }

        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        guard deviceCount > 0 else { return devices }
        var audioDevices = [AudioDeviceID](repeating: 0, count: deviceCount)

        let getDevicesStatus = audioDevices.withUnsafeMutableBytes { rawBuffer -> OSStatus in
            guard let baseAddress = rawBuffer.baseAddress else {
                return kAudioHardwareUnspecifiedError
            }

            return AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &propertyAddress,
                0,
                nil,
                &dataSize,
                baseAddress
            )
        }

        guard getDevicesStatus == noErr else { return devices }

        // Filter for input devices only
        for deviceID in audioDevices {
            if hasInputStreams(deviceID: deviceID),
               let name = getDeviceName(deviceID: deviceID),
               let uid = getDeviceUID(deviceID: deviceID)
            {
                devices.append(AudioDevice(id: deviceID, name: name, uniqueID: uid))
            }
        }

        return devices
    }

    func getDefaultInputDevice() -> AudioDevice? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var deviceID: AudioDeviceID = 0
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &dataSize,
            &deviceID
        )

        guard status == noErr,
              let name = getDeviceName(deviceID: deviceID),
              let uid = getDeviceUID(deviceID: deviceID)
        else {
            return nil
        }

        return AudioDevice(id: deviceID, name: name, uniqueID: uid)
    }

    func setDefaultInputDevice(deviceID: AudioDeviceID) -> Bool {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var deviceIDCopy = deviceID
        let dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)

        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            dataSize,
            &deviceIDCopy
        )

        if status == noErr {
            DebugLog.info("Successfully set default input device to ID: \(deviceID)", context: "AudioDeviceManager")
            return true
        } else {
            DebugLog.info("Failed to set default input device, status: \(status)", context: "AudioDeviceManager")
            return false
        }
    }

    /// Re-apply the user's preferred device when the device list changes (e.g. mic connected/disconnected)
    func reapplyPreferredDevice() {
        refreshDevices()

        if automaticallySelectDevice {
            if let device = applyPreferredOrAutomaticDevice() {
                DebugLog.info("Automatic input device selected: \(device.name)", context: "AudioDeviceManager")
            }
            return
        }

        guard let savedUID = AppDefaults.shared.string(forKey: Keys.selectedAudioDeviceID) else {
            _ = applyPreferredOrAutomaticDevice()
            return
        }

        if let preferred = inputDevices.first(where: { $0.uniqueID == savedUID }) {
            // Preferred device is available - ensure it's set as default
            let current = getDefaultInputDevice()
            if current?.uniqueID != preferred.uniqueID {
                DebugLog.info("Reconnected preferred device: \(preferred.name)", context: "AudioDeviceManager")
                _ = setDefaultInputDevice(deviceID: preferred.id)
                NotificationCenter.default.post(
                    name: NSNotification.Name("AudioInputDeviceChanged"),
                    object: preferred.uniqueID
                )
            }
            selectedDevice = preferred
        } else {
            // Preferred device disconnected - notify so AudioRecorder reinitializes with system default
            DebugLog.info("Preferred device disconnected, falling back to system default", context: "AudioDeviceManager")
            selectedDevice = bestAutomaticInputDevice(in: inputDevices)
            NotificationCenter.default.post(
                name: NSNotification.Name("AudioInputDeviceChanged"),
                object: nil
            )
        }
    }

    // MARK: - Private Methods

    private func currentSelectedDevice(in devices: [AudioDevice]) -> AudioDevice? {
        if !automaticallySelectDevice,
           let savedUID = AppDefaults.shared.string(forKey: Keys.selectedAudioDeviceID),
           let savedDevice = devices.first(where: { $0.uniqueID == savedUID })
        {
            return savedDevice
        }
        return getDefaultInputDevice() ?? bestAutomaticInputDevice(in: devices)
    }

    private func bestAutomaticInputDevice(in devices: [AudioDevice]) -> AudioDevice? {
        if let defaultDevice = getDefaultInputDevice(),
           devices.contains(defaultDevice)
        {
            return defaultDevice
        }

        let virtualNameFragments = ["blackhole", "loopback", "soundflower", "aggregate", "multi-output"]
        let physicalCandidates = devices.filter { device in
            let lowercasedName = device.name.lowercased()
            return !virtualNameFragments.contains { lowercasedName.contains($0) }
        }

        return physicalCandidates.first { device in
            let lowercasedName = device.name.lowercased()
            return lowercasedName.contains("microphone") || lowercasedName.contains("mic")
        } ?? physicalCandidates.first ?? devices.first
    }

    private func hasInputStreams(deviceID: AudioDeviceID) -> Bool {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(
            deviceID,
            &propertyAddress,
            0,
            nil,
            &dataSize
        )

        guard status == noErr, dataSize > 0 else { return false }

        let rawBuffer = UnsafeMutableRawBufferPointer.allocate(
            byteCount: Int(dataSize),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { rawBuffer.deallocate() }

        guard let baseAddress = rawBuffer.baseAddress else { return false }
        let getDataStatus = AudioObjectGetPropertyData(
            deviceID,
            &propertyAddress,
            0,
            nil,
            &dataSize,
            baseAddress
        )

        guard getDataStatus == noErr else { return false }

        let bufferListPointer = baseAddress.assumingMemoryBound(to: AudioBufferList.self)
        let bufferList = UnsafeMutableAudioBufferListPointer(bufferListPointer)
        return bufferList.contains { $0.mNumberChannels > 0 }
    }

    private func getDeviceName(deviceID: AudioDeviceID) -> String? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            deviceID,
            &propertyAddress,
            0,
            nil,
            &dataSize
        )

        guard status == noErr else { return nil }

        var name: Unmanaged<CFString>?
        status = AudioObjectGetPropertyData(
            deviceID,
            &propertyAddress,
            0,
            nil,
            &dataSize,
            &name
        )

        guard status == noErr, let name else { return nil }
        return name.takeUnretainedValue() as String
    }

    private func getDeviceUID(deviceID: AudioDeviceID) -> String? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            deviceID,
            &propertyAddress,
            0,
            nil,
            &dataSize
        )

        guard status == noErr else { return nil }

        var uid: Unmanaged<CFString>?
        status = AudioObjectGetPropertyData(
            deviceID,
            &propertyAddress,
            0,
            nil,
            &dataSize,
            &uid
        )

        guard status == noErr, let uid else { return nil }
        return uid.takeUnretainedValue() as String
    }

    // MARK: - Device Change Listener

    private func setupDeviceChangeListener() {
        // Listen for device list changes
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        AudioObjectAddPropertyListener(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            deviceListChangedCallback,
            nil
        )

        // Listen for default device changes
        propertyAddress.mSelector = kAudioHardwarePropertyDefaultInputDevice

        AudioObjectAddPropertyListener(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            deviceListChangedCallback,
            nil
        )
    }
}

// Callback for device changes
private func deviceListChangedCallback(
    _: AudioObjectID,
    _: UInt32,
    _: UnsafePointer<AudioObjectPropertyAddress>,
    _: UnsafeMutableRawPointer?
) -> OSStatus {
    DispatchQueue.main.async {
        // Re-apply saved device preference when devices change
        AudioDeviceManager.shared.reapplyPreferredDevice()

        NotificationCenter.default.post(
            name: NSNotification.Name("AudioDeviceListChanged"),
            object: nil
        )
    }
    return noErr
}
