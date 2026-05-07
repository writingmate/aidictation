import AppKit
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

    private enum Constants {
        static let wakeRecoveryDelays: [TimeInterval] = [0.5, 1.5, 3.0, 5.0, 8.0, 13.0]
    }

    @Published private(set) var inputDevices: [AudioDevice] = []
    @Published private(set) var selectedDevice: AudioDevice?
    @Published private(set) var automaticallySelectDevice: Bool

    var savedSelectedDeviceUID: String? {
        AppDefaults.shared.string(forKey: Keys.selectedAudioDeviceID)
    }

    private var screenWakeObserver: NSObjectProtocol?
    private var systemWakeObserver: NSObjectProtocol?
    private var wakeRecoveryWorkItem: DispatchWorkItem?
    private var wakeRecoveryGeneration = 0

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
        setupWakeRecovery()
    }

    deinit {
        wakeRecoveryWorkItem?.cancel()
        if let screenWakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(screenWakeObserver)
        }
        if let systemWakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(systemWakeObserver)
        }
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
            refreshDevices()
            _ = applyAutomaticDevice(forceNotify: true)
        } else {
            _ = applyPreferredOrAutomaticDevice()
        }
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

        if automaticallySelectDevice {
            return applyAutomaticDevice(forceNotify: false)
        }

        guard let savedUID = savedSelectedDeviceUID else {
            return applyAutomaticDevice(forceNotify: false)
        }

        guard let preferred = preferredInputDevice(for: savedUID) else {
            selectedDevice = nil
            DebugLog.info(
                "Preferred input device \(savedUID) is not available yet; keeping manual selection and waiting for reconnect",
                context: "AudioDeviceManager"
            )
            return nil
        }

        return apply(device: preferred, forceNotify: false)
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
    @discardableResult
    func reapplyPreferredDevice(forceNotify: Bool = false) -> AudioDevice? {
        refreshDevices()

        if automaticallySelectDevice {
            if let device = applyAutomaticDevice(forceNotify: forceNotify) {
                DebugLog.info("Automatic input device selected: \(device.name)", context: "AudioDeviceManager")
                return device
            }
            return nil
        }

        guard let savedUID = savedSelectedDeviceUID else {
            return applyAutomaticDevice(forceNotify: forceNotify)
        }

        guard let preferred = preferredInputDevice(for: savedUID) else {
            selectedDevice = nil
            DebugLog.info(
                "Preferred input device \(savedUID) is unavailable; not falling back to system default",
                context: "AudioDeviceManager"
            )
            return nil
        }

        DebugLog.info("Resolved preferred input device: \(preferred.name)", context: "AudioDeviceManager")
        return apply(device: preferred, forceNotify: forceNotify)
    }

    // MARK: - Private Methods

    private func currentSelectedDevice(in devices: [AudioDevice]) -> AudioDevice? {
        if !automaticallySelectDevice {
            guard let savedUID = savedSelectedDeviceUID else { return nil }
            return preferredInputDevice(for: savedUID, in: devices)
        }
        return getDefaultInputDevice() ?? bestAutomaticInputDevice(in: devices)
    }

    private func preferredInputDevice(for uniqueID: String, in devices: [AudioDevice]? = nil) -> AudioDevice? {
        let availableDevices = devices ?? inputDevices
        if let listedDevice = availableDevices.first(where: { $0.uniqueID == uniqueID }), isInputDeviceAlive(listedDevice.id) {
            return listedDevice
        }

        guard let deviceID = audioDeviceID(forUniqueID: uniqueID),
              deviceID != kAudioDeviceUnknown,
              hasInputStreams(deviceID: deviceID),
              isInputDeviceAlive(deviceID),
              let name = getDeviceName(deviceID: deviceID),
              let resolvedUID = getDeviceUID(deviceID: deviceID)
        else {
            return nil
        }

        return AudioDevice(id: deviceID, name: name, uniqueID: resolvedUID)
    }

    private func applyAutomaticDevice(forceNotify: Bool) -> AudioDevice? {
        guard let target = bestAutomaticInputDevice(in: inputDevices) else { return nil }
        return apply(device: target, forceNotify: forceNotify)
    }

    private func apply(device target: AudioDevice, forceNotify: Bool) -> AudioDevice? {
        let current = getDefaultInputDevice()
        let shouldNotify = forceNotify || current?.uniqueID != target.uniqueID

        if current?.uniqueID != target.uniqueID {
            DebugLog.info("Applying input device: \(target.name)", context: "AudioDeviceManager")
            guard setDefaultInputDevice(deviceID: target.id) else {
                refreshDevices()
                return selectedDevice
            }
        }

        selectedDevice = target

        if shouldNotify {
            NotificationCenter.default.post(
                name: NSNotification.Name("AudioInputDeviceChanged"),
                object: target.uniqueID
            )
        }

        return target
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

    private func isInputDeviceAlive(_ deviceID: AudioDeviceID) -> Bool {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var isAlive: UInt32 = 0
        var dataSize = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(
            deviceID,
            &propertyAddress,
            0,
            nil,
            &dataSize,
            &isAlive
        )

        return status == noErr && isAlive != 0
    }

    private func audioDeviceID(forUniqueID uniqueID: String) -> AudioDeviceID? {
        var uid = uniqueID as CFString
        var deviceID = AudioDeviceID(kAudioDeviceUnknown)

        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDeviceForUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize = UInt32(MemoryLayout<AudioValueTranslation>.size)
        let status = withUnsafeMutablePointer(to: &uid) { uidPointer in
            withUnsafeMutablePointer(to: &deviceID) { deviceIDPointer in
                var translation = AudioValueTranslation(
                    mInputData: UnsafeMutableRawPointer(uidPointer),
                    mInputDataSize: UInt32(MemoryLayout<CFString>.size),
                    mOutputData: UnsafeMutableRawPointer(deviceIDPointer),
                    mOutputDataSize: UInt32(MemoryLayout<AudioDeviceID>.size)
                )

                return AudioObjectGetPropertyData(
                    AudioObjectID(kAudioObjectSystemObject),
                    &propertyAddress,
                    0,
                    nil,
                    &dataSize,
                    &translation
                )
            }
        }

        guard status == noErr else { return nil }
        return deviceID
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

    private func setupWakeRecovery() {
        screenWakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.scheduleWakeRecovery(reason: "screens did wake", restart: true)
        }

        systemWakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.scheduleWakeRecovery(reason: "system did wake", restart: true)
        }
    }

    private func scheduleWakeRecovery(reason: String, restart: Bool) {
        if restart {
            wakeRecoveryGeneration += 1
            wakeRecoveryWorkItem?.cancel()
            DebugLog.info("Scheduling audio device wake recovery: \(reason)", context: "AudioDeviceManager")
        }

        guard !automaticallySelectDevice, savedSelectedDeviceUID != nil else { return }
        runWakeRecoveryAttempt(reason: reason, generation: wakeRecoveryGeneration, attempt: 0)
    }

    private func runWakeRecoveryAttempt(reason: String, generation: Int, attempt: Int) {
        guard attempt < Constants.wakeRecoveryDelays.count else { return }

        let delay = Constants.wakeRecoveryDelays[attempt]
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard generation == self.wakeRecoveryGeneration else { return }

            let resolvedDevice = self.reapplyPreferredDevice(forceNotify: true)
            NotificationCenter.default.post(
                name: NSNotification.Name("AudioDeviceListChanged"),
                object: nil
            )

            guard self.shouldContinueWakeRecovery(resolvedDevice: resolvedDevice) else {
                DebugLog.info("Audio device wake recovery finished after \(reason)", context: "AudioDeviceManager")
                return
            }

            self.runWakeRecoveryAttempt(reason: reason, generation: generation, attempt: attempt + 1)
        }

        wakeRecoveryWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func shouldContinueWakeRecovery(resolvedDevice: AudioDevice?) -> Bool {
        guard !automaticallySelectDevice, let savedUID = savedSelectedDeviceUID else { return false }
        return resolvedDevice?.uniqueID != savedUID
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
