import AppKit
import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation
import IOKit
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
        static let deviceOperationTimeout: TimeInterval = 2.0
        static let virtualDeviceNameFragments = [
            "cadeviceaggregate",
            "aggregate",
            "multi-output",
            "blackhole",
            "loopback",
            "soundflower"
        ]
    }

    @Published private(set) var inputDevices: [AudioDevice] = []
    @Published private(set) var selectedDevice: AudioDevice?
    @Published private(set) var automaticallySelectDevice: Bool

    var savedSelectedDeviceUID: String? {
        AppDefaults.shared.string(forKey: Keys.selectedAudioDeviceID)
    }

    private var screenWakeObserver: NSObjectProtocol?
    private var systemWakeObserver: NSObjectProtocol?
    private var screenParametersObserver: NSObjectProtocol?
    private var wakeRecoveryWorkItem: DispatchWorkItem?
    private var deviceChangeWorkItem: DispatchWorkItem?
    private var wakeRecoveryGeneration = 0
    private var wakeOperationID: UUID?
    private var maintenanceOperationID: UUID?
    private var refreshOperationID: UUID?
    private var routeReconciliationNeeded = false
    private let capturePinLock = NSLock()
    private var capturePin: CaptureGraphPin?
    private var isRestoringPinnedDataSource = false

    private struct CaptureGraphPin {
        let recordingID: UUID
        let deviceID: AudioDeviceID
        let uniqueID: String
        let dataSource: UInt32?
        let listensForDataSource: Bool
        let listensForJack: Bool
    }

    // MARK: - Types

    struct AudioDevice: Identifiable, Equatable, Hashable, Sendable {
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

    struct CaptureSelectionSnapshot: Sendable {
        let automaticallySelectDevice: Bool
        let savedSelectedDeviceUID: String?
    }

    struct CaptureDeviceResolution: Sendable {
        let device: AudioDevice
        let availableDevices: [AudioDevice]
        let usedFallback: Bool
        /// HAL input data source (FourCC) at the moment capture resolved this
        /// device. Built-in mics often expose Internal vs jack sources on the
        /// same AudioDeviceID; pinning this value keeps I/O from following a
        /// mid-start source switch. Nil when the device has no data source.
        let inputDataSource: UInt32?
    }

    private struct DeviceApplyOutcome: Sendable {
        let devices: [AudioDevice]
        let target: AudioDevice?
        let usedFallback: Bool
        let routeChanged: Bool
        let applied: Bool
    }

    // MARK: - Initialization

    private init() {
        automaticallySelectDevice = AppDefaults.shared.object(forKey: Keys.automaticallySelectAudioDevice) as? Bool ?? true
        setupWakeRecovery()
        makeDisposableDeviceQueue(purpose: "listener").async { [weak self] in
            self?.setupDeviceChangeListener()
        }
        refreshDevices()
    }

    deinit {
        wakeRecoveryWorkItem?.cancel()
        deviceChangeWorkItem?.cancel()
        endCapturePinLocked(recordingID: nil, reason: "deinit")
        if let screenWakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(screenWakeObserver)
        }
        if let systemWakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(systemWakeObserver)
        }
        if let screenParametersObserver {
            NotificationCenter.default.removeObserver(screenParametersObserver)
        }
    }

    // MARK: - Public API

    /// Captures only user preference state. Potentially blocking Core Audio
    /// calls are deliberately excluded and run later on the disposable capture
    /// preparation lane.
    func makeCaptureSelectionSnapshot() -> CaptureSelectionSnapshot {
        CaptureSelectionSnapshot(
            automaticallySelectDevice: automaticallySelectDevice,
            savedSelectedDeviceUID: savedSelectedDeviceUID
        )
    }

    /// Resolves the already-applied recording input without mutating global route
    /// or published UI state. Recording preparation never changes the system
    /// default, so an abandoned attempt cannot overwrite a newer route.
    func resolveCaptureDevice(using snapshot: CaptureSelectionSnapshot) -> CaptureDeviceResolution? {
        let devices = getInputDevices()
        guard !devices.isEmpty else { return nil }

        let preferredDevice: AudioDevice?
        if snapshot.automaticallySelectDevice {
            preferredDevice = bestAutomaticInputDevice(in: devices)
        } else if let savedUID = snapshot.savedSelectedDeviceUID {
            preferredDevice = preferredInputDevice(for: savedUID, in: devices)
        } else {
            preferredDevice = nil
        }

        let usedFallback = !snapshot.automaticallySelectDevice && preferredDevice == nil
        guard let target = preferredDevice ?? bestAutomaticInputDevice(in: devices) else {
            return nil
        }

        guard getDefaultInputDevice()?.uniqueID == target.uniqueID else {
            return nil
        }

        return CaptureDeviceResolution(
            device: target,
            availableDevices: devices,
            usedFallback: usedFallback,
            inputDataSource: currentInputDataSource(deviceID: target.id)
        )
    }

    /// Binds `inputNode` to a specific HAL device and input data source so the
    /// graph does not follow later default-input or jack-source changes.
    @discardableResult
    func bindCaptureInputNode(
        _ inputNode: AVAudioInputNode,
        to resolution: CaptureDeviceResolution
    ) -> Bool {
        let device = resolution.device
        let boundToDevice = bindInputNode(inputNode, toDeviceID: device.id)
        if let dataSource = resolution.inputDataSource {
            let pinned = pinInputDataSource(deviceID: device.id, source: dataSource)
            if !pinned {
                DebugLog.info(
                    "Could not pin input data source for \(device.name)",
                    context: "AudioDeviceManager"
                )
            }
        }

        if boundToDevice {
            DebugLog.info(
                "Bound capture input to \(device.name) uid=\(device.uniqueID) dataSource=\(resolution.inputDataSource.map { fourCCString($0) } ?? "none")",
                context: "AudioDeviceManager"
            )
            SentryTelemetry.recordAudioDeviceEvent("capture_input_bound", device: device)
        } else {
            DebugLog.info(
                "Failed to bind capture input to \(device.name) uid=\(device.uniqueID)",
                context: "AudioDeviceManager"
            )
            SentryTelemetry.recordAudioDeviceEvent("capture_input_bind_failed", device: device)
        }
        return boundToDevice
    }

    /// Owns HAL data-source and jack listeners for one capture attempt so a
    /// built-in source switch cannot retarget the live graph.
    func beginCapturePin(recordingID: UUID, resolution: CaptureDeviceResolution) {
        endCapturePinLocked(recordingID: nil, reason: "replaced")
        deviceChangeWorkItem?.cancel()
        wakeRecoveryWorkItem?.cancel()

        var dataSourceAddress = inputDataSourcePropertyAddress()
        var jackAddress = inputJackPropertyAddress()
        let listensForDataSource = AudioObjectAddPropertyListener(
            resolution.device.id,
            &dataSourceAddress,
            pinnedInputPropertyChangedCallback,
            nil
        ) == noErr
        let listensForJack = AudioObjectAddPropertyListener(
            resolution.device.id,
            &jackAddress,
            pinnedInputPropertyChangedCallback,
            nil
        ) == noErr

        let pin = CaptureGraphPin(
            recordingID: recordingID,
            deviceID: resolution.device.id,
            uniqueID: resolution.device.uniqueID,
            dataSource: resolution.inputDataSource,
            listensForDataSource: listensForDataSource,
            listensForJack: listensForJack
        )
        capturePinLock.lock()
        capturePin = pin
        capturePinLock.unlock()

        DebugLog.info(
            "Capture pin started uid=\(pin.uniqueID) dataSource=\(pin.dataSource.map { fourCCString($0) } ?? "none") dataSourceListener=\(listensForDataSource) jackListener=\(listensForJack)",
            context: "AudioDeviceManager"
        )
        SentryTelemetry.recordAudioEngineEvent("capture_graph_pin_started")
    }

    func endCapturePin(recordingID: UUID? = nil) {
        endCapturePinLocked(recordingID: recordingID, reason: "ended")
    }

    /// Re-applies the pinned data source if HAL drifted after I/O start.
    @discardableResult
    func restorePinnedInputDataSourceIfNeeded() -> Bool {
        capturePinLock.lock()
        guard let pin = capturePin else {
            capturePinLock.unlock()
            return false
        }
        let deviceID = pin.deviceID
        let pinnedSource = pin.dataSource
        capturePinLock.unlock()
        return restorePinnedInputDataSource(
            deviceID: deviceID,
            pinnedSource: pinnedSource,
            reason: "explicit"
        )
    }

    var isCaptureGraphPinned: Bool {
        capturePinLock.lock()
        defer { capturePinLock.unlock() }
        return capturePin != nil
    }

    /// Publishes the already-resolved result after native preparation wins.
    /// No Core Audio calls occur here, so this cannot wedge the main run loop.
    func publishCaptureDeviceResolution(_ resolution: CaptureDeviceResolution) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.publishCaptureDeviceResolution(resolution)
            }
            return
        }

        inputDevices = resolution.availableDevices
        selectedDevice = resolution.device
        SentryTelemetry.recordAudioDeviceEvent(
            "recording_input_device",
            device: resolution.device,
            mode: resolution.usedFallback ? "fallback" : nil,
            fallback: resolution.usedFallback
        )
    }

    func refreshDevices(completion: (() -> Void)? = nil) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.refreshDevices(completion: completion)
            }
            return
        }

        let operationID = UUID()
        let snapshot = makeCaptureSelectionSnapshot()
        refreshOperationID = operationID
        makeDisposableDeviceQueue(purpose: "refresh").async { [weak self] in
            guard let self else { return }
            let devices = self.getInputDevices()
            let selected = self.selectedDevice(for: snapshot, in: devices)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.refreshOperationID == operationID else { return }
                self.inputDevices = devices
                self.selectedDevice = selected
                completion?()
            }
        }
    }

    func setAutomaticSelection(_ enabled: Bool) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.setAutomaticSelection(enabled)
            }
            return
        }

        automaticallySelectDevice = enabled
        AppDefaults.shared.set(enabled, forKey: Keys.automaticallySelectAudioDevice)
        if enabled {
            AppDefaults.shared.removeObject(forKey: Keys.selectedAudioDeviceID)
        }
        applyPreferredOrAutomaticDevice(forceNotify: true) { [weak self] device in
            SentryTelemetry.recordAudioDeviceEvent(
                "automatic_selection_changed",
                device: device ?? self?.selectedDevice,
                mode: enabled ? "automatic" : "manual"
            )
        }
    }

    func selectDevice(_ device: AudioDevice, completion: ((Bool) -> Void)? = nil) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.selectDevice(device, completion: completion)
            }
            return
        }

        // Persist the latest user intent before starting uncancellable Core Audio
        // work. Older completions may reconcile the route, but can never restore an
        // older preference.
        automaticallySelectDevice = false
        AppDefaults.shared.set(false, forKey: Keys.automaticallySelectAudioDevice)
        AppDefaults.shared.set(device.uniqueID, forKey: Keys.selectedAudioDeviceID)
        selectedDevice = device
        applyPreferredOrAutomaticDevice(forceNotify: true) { resolvedDevice in
            let success = resolvedDevice?.uniqueID == device.uniqueID
            if success {
                SentryTelemetry.recordAudioDeviceEvent("manual_input_selected", device: device, mode: "manual")
            }
            completion?(success)
        }
    }

    func applyPreferredOrAutomaticDevice(
        forceNotify: Bool = false,
        completion: ((AudioDevice?) -> Void)? = nil
    ) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.applyPreferredOrAutomaticDevice(
                    forceNotify: forceNotify,
                    completion: completion
                )
            }
            return
        }

        let operationID = UUID()
        let snapshot = makeCaptureSelectionSnapshot()
        maintenanceOperationID = operationID
        refreshOperationID = nil

        makeDisposableDeviceQueue(purpose: "apply").async { [weak self] in
            guard let self else { return }
            let outcome = self.applyDevicePreference(snapshot)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard self.maintenanceOperationID == operationID else {
                    if outcome.routeChanged, outcome.applied {
                        self.routeReconciliationNeeded = true
                        self.runPendingRouteReconciliationIfPossible()
                    }
                    completion?(nil)
                    return
                }

                self.maintenanceOperationID = nil
                self.inputDevices = outcome.devices
                guard outcome.applied, let target = outcome.target else {
                    self.selectedDevice = outcome.target
                    completion?(nil)
                    self.runPendingRouteReconciliationIfPossible()
                    return
                }

                self.selectedDevice = target
                SentryTelemetry.recordAudioDeviceEvent(
                    "input_applied",
                    device: target,
                    mode: outcome.usedFallback ? "fallback" : nil,
                    fallback: outcome.usedFallback
                )
                if forceNotify || outcome.routeChanged {
                    NotificationCenter.default.post(
                        name: NSNotification.Name("AudioInputDeviceChanged"),
                        object: target.uniqueID
                    )
                }
                completion?(target)
                self.runPendingRouteReconciliationIfPossible()
            }
        }
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
               isInputDeviceAlive(deviceID),
               let name = getDeviceName(deviceID: deviceID),
               let uid = getDeviceUID(deviceID: deviceID),
               !shouldHideFromInputDeviceList(deviceID: deviceID, name: name)
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
        // Writing the system default input is a slow Core Audio property set,
        // and it ran on every recording even when the device was already the
        // one we wanted. Skip the write when it would be a no-op.
        if let current = getDefaultInputDevice(), current.id == deviceID {
            DebugLog.info(
                "Default input already ID: \(deviceID); skipping redundant set",
                context: "AudioDeviceManager"
            )
            return true
        }

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

    /// Re-applies the user's preference without running Core Audio on the caller.
    func reapplyPreferredDevice(
        forceNotify: Bool = false,
        completion: ((AudioDevice?) -> Void)? = nil
    ) {
        applyPreferredOrAutomaticDevice(
            forceNotify: forceNotify,
            completion: completion
        )
    }

    // MARK: - Private Methods

    private func runPendingRouteReconciliationIfPossible() {
        guard maintenanceOperationID == nil, routeReconciliationNeeded else { return }
        guard !isCaptureGraphPinned else { return }
        routeReconciliationNeeded = false
        applyPreferredOrAutomaticDevice()
    }

    private func selectedDevice(
        for snapshot: CaptureSelectionSnapshot,
        in devices: [AudioDevice]
    ) -> AudioDevice? {
        if !snapshot.automaticallySelectDevice {
            guard let savedUID = snapshot.savedSelectedDeviceUID else { return nil }
            return preferredInputDevice(for: savedUID, in: devices)
                ?? bestAutomaticInputDevice(in: devices)
        }
        return bestAutomaticInputDevice(in: devices)
    }

    private func preferredInputDevice(for uniqueID: String, in devices: [AudioDevice]) -> AudioDevice? {
        if let listedDevice = devices.first(where: { $0.uniqueID == uniqueID }), isInputDeviceAlive(listedDevice.id) {
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

    private func applyDevicePreference(_ snapshot: CaptureSelectionSnapshot) -> DeviceApplyOutcome {
        let devices = getInputDevices()
        let preferred = snapshot.savedSelectedDeviceUID.flatMap {
            preferredInputDevice(for: $0, in: devices)
        }
        let usedFallback = !snapshot.automaticallySelectDevice && preferred == nil
        let target = snapshot.automaticallySelectDevice
            ? bestAutomaticInputDevice(in: devices)
            : preferred ?? bestAutomaticInputDevice(in: devices)

        guard let target else {
            return DeviceApplyOutcome(
                devices: devices,
                target: nil,
                usedFallback: usedFallback,
                routeChanged: false,
                applied: false
            )
        }

        let current = getDefaultInputDevice()
        let routeChanged = current?.uniqueID != target.uniqueID

        if routeChanged {
            DebugLog.info("Applying input device: \(target.name)", context: "AudioDeviceManager")
            guard setDefaultInputDevice(deviceID: target.id) else {
                SentryTelemetry.recordAudioDeviceEvent("input_apply_failed", device: target)
                return DeviceApplyOutcome(
                    devices: devices,
                    target: target,
                    usedFallback: usedFallback,
                    routeChanged: true,
                    applied: false
                )
            }
        }

        return DeviceApplyOutcome(
            devices: devices,
            target: target,
            usedFallback: usedFallback,
            routeChanged: routeChanged,
            applied: true
        )
    }

    private func makeDisposableDeviceQueue(purpose: String) -> DispatchQueue {
        DispatchQueue(
            label: "ai.writingmate.audio-device.\(purpose).\(UUID().uuidString)",
            qos: .utility
        )
    }

    private func bestAutomaticInputDevice(in devices: [AudioDevice]) -> AudioDevice? {
        let clamshellClosed = isClamshellClosed()

        if let defaultDevice = getDefaultInputDevice(),
           devices.contains(defaultDevice),
           !shouldAvoidAutomaticallySelecting(
               defaultDevice,
               clamshellClosed: clamshellClosed,
               availableDevices: devices
           )
        {
            return defaultDevice
        }

        let allowedCandidates = devices.filter { device in
            !shouldAvoidAutomaticallySelecting(
                device,
                clamshellClosed: clamshellClosed,
                availableDevices: devices
            )
        }

        let physicalCandidates = allowedCandidates.filter { device in
            let lowercasedName = device.name.lowercased()
            return !Constants.virtualDeviceNameFragments.contains { lowercasedName.contains($0) }
        }

        return physicalCandidates.first { device in
            let lowercasedName = device.name.lowercased()
            return lowercasedName.contains("microphone") || lowercasedName.contains("mic")
        } ?? physicalCandidates.first ?? allowedCandidates.first
    }

    private func shouldAvoidAutomaticallySelecting(
        _ device: AudioDevice,
        clamshellClosed: Bool,
        availableDevices: [AudioDevice]
    ) -> Bool {
        guard isBuiltInInputDevice(device.id) else { return false }
        return clamshellClosed
            || !hasActiveBuiltInDisplay()
            || shouldPreferExternalInputOverBuiltIn(availableDevices: availableDevices)
    }

    /// Returns whether the device is a built-in microphone.
    func isBuiltInDevice(_ device: AudioDevice) -> Bool {
        isBuiltInInputDevice(device.id)
    }

    private func isBuiltInInputDevice(_ deviceID: AudioDeviceID) -> Bool {
        if let transportType = getDeviceTransportType(deviceID: deviceID),
           transportType == kAudioDeviceTransportTypeBuiltIn
        {
            return true
        }

        guard let name = getDeviceName(deviceID: deviceID)?.lowercased() else { return false }
        return name.contains("built-in") || name.contains("macbook") || name.contains("internal microphone")
    }

    private func getDeviceTransportType(deviceID: AudioDeviceID) -> UInt32? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var transportType: UInt32 = 0
        var dataSize = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(
            deviceID,
            &propertyAddress,
            0,
            nil,
            &dataSize,
            &transportType
        )

        guard status == noErr else { return nil }
        return transportType
    }

    private func shouldHideFromInputDeviceList(deviceID: AudioDeviceID, name: String) -> Bool {
        if let transportType = getDeviceTransportType(deviceID: deviceID),
           transportType == kAudioDeviceTransportTypeAggregate
        {
            return true
        }

        let lowercasedName = name.lowercased()
        return Constants.virtualDeviceNameFragments.contains { lowercasedName.contains($0) }
    }

    private func isClamshellClosed() -> Bool {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != IO_OBJECT_NULL else { return false }
        defer { IOObjectRelease(service) }

        guard let property = IORegistryEntryCreateCFProperty(
            service,
            "AppleClamshellState" as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() else {
            return false
        }

        return (property as? Bool) ?? false
    }

    private func hasActiveBuiltInDisplay() -> Bool {
        var displayCount: UInt32 = 0
        let countStatus = CGGetActiveDisplayList(0, nil, &displayCount)
        guard countStatus == .success, displayCount > 0 else { return true }

        var displays = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        let listStatus = CGGetActiveDisplayList(displayCount, &displays, &displayCount)
        guard listStatus == .success else { return true }

        return displays.contains { CGDisplayIsBuiltin($0) != 0 }
    }

    private func hasActiveExternalDisplay() -> Bool {
        var displayCount: UInt32 = 0
        let countStatus = CGGetActiveDisplayList(0, nil, &displayCount)
        guard countStatus == .success, displayCount > 0 else { return false }

        var displays = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        let listStatus = CGGetActiveDisplayList(displayCount, &displays, &displayCount)
        guard listStatus == .success else { return false }

        return displays.contains { CGDisplayIsBuiltin($0) == 0 }
    }

    private func shouldPreferExternalInputOverBuiltIn(availableDevices: [AudioDevice]) -> Bool {
        hasActiveExternalDisplay() && availableDevices.contains { !isBuiltInInputDevice($0.id) }
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

        let devicesListenerStatus = AudioObjectAddPropertyListener(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            deviceListChangedCallback,
            nil
        )
        if devicesListenerStatus != noErr {
            DebugLog.info("Failed to register Core Audio device-list listener: \(devicesListenerStatus)", context: "AudioDeviceManager")
        }

        // Listen for default device changes
        propertyAddress.mSelector = kAudioHardwarePropertyDefaultInputDevice

        let defaultInputListenerStatus = AudioObjectAddPropertyListener(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            deviceListChangedCallback,
            nil
        )
        if defaultInputListenerStatus != noErr {
            DebugLog.info("Failed to register Core Audio default-input listener: \(defaultInputListenerStatus)", context: "AudioDeviceManager")
        }

    }

    func handleAudioHardwareChanged() {
        if MacCaptureGraphPinPolicy.shouldDeferHardwareReapply(isCapturePinned: isCaptureGraphPinned) {
            routeReconciliationNeeded = true
            DebugLog.info(
                "Deferring hardware reapply; capture graph is pinned",
                context: "AudioDeviceManager"
            )
            SentryTelemetry.recordAudioEngineEvent("hardware_changed_deferred_capture_pin")
            return
        }

        deviceChangeWorkItem?.cancel()
        SentryTelemetry.recordAudioEngineEvent("hardware_changed")

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if MacCaptureGraphPinPolicy.shouldDeferHardwareReapply(
                isCapturePinned: self.isCaptureGraphPinned
            ) {
                self.routeReconciliationNeeded = true
                return
            }

            // Re-apply saved device preference when devices change. AirPods and other
            // Bluetooth devices often emit a burst of Core Audio notifications while
            // connecting/disconnecting, so debounce before touching the default input.
            self.reapplyPreferredDevice { _ in
                NotificationCenter.default.post(
                    name: NSNotification.Name("AudioDeviceListChanged"),
                    object: nil
                )
            }
        }

        deviceChangeWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: workItem)
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

        screenParametersObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.scheduleWakeRecovery(reason: "screen parameters changed", restart: true)
        }
    }

    private func scheduleWakeRecovery(reason: String, restart: Bool) {
        if MacCaptureGraphPinPolicy.shouldDeferHardwareReapply(isCapturePinned: isCaptureGraphPinned) {
            routeReconciliationNeeded = true
            DebugLog.info(
                "Deferring audio device wake recovery during capture pin: \(reason)",
                context: "AudioDeviceManager"
            )
            return
        }

        if restart {
            wakeRecoveryGeneration += 1
            wakeOperationID = nil
            wakeRecoveryWorkItem?.cancel()
            DebugLog.info("Scheduling audio device wake recovery: \(reason)", context: "AudioDeviceManager")
        }

        guard automaticallySelectDevice || savedSelectedDeviceUID != nil else { return }
        runWakeRecoveryAttempt(reason: reason, generation: wakeRecoveryGeneration, attempt: 0)
    }

    private func runWakeRecoveryAttempt(reason: String, generation: Int, attempt: Int) {
        guard attempt < Constants.wakeRecoveryDelays.count else { return }

        let delay = Constants.wakeRecoveryDelays[attempt]
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard generation == self.wakeRecoveryGeneration else { return }
            if MacCaptureGraphPinPolicy.shouldDeferHardwareReapply(
                isCapturePinned: self.isCaptureGraphPinned
            ) {
                self.routeReconciliationNeeded = true
                return
            }

            let operationID = UUID()
            self.wakeOperationID = operationID
            self.reapplyPreferredDevice(forceNotify: true) { [weak self] resolvedDevice in
                guard let self,
                      generation == self.wakeRecoveryGeneration,
                      self.wakeOperationID == operationID
                else { return }

                self.wakeOperationID = nil
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

            DispatchQueue.main.asyncAfter(deadline: .now() + Constants.deviceOperationTimeout) { [weak self] in
                guard let self,
                      generation == self.wakeRecoveryGeneration,
                      self.wakeOperationID == operationID
                else { return }
                self.wakeOperationID = nil
                self.runWakeRecoveryAttempt(reason: reason, generation: generation, attempt: attempt + 1)
            }
        }

        wakeRecoveryWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func shouldContinueWakeRecovery(resolvedDevice: AudioDevice?) -> Bool {
        if automaticallySelectDevice {
            return resolvedDevice == nil
        }

        guard let savedUID = savedSelectedDeviceUID else { return false }
        guard let resolvedDevice else { return true }

        if resolvedDevice.uniqueID == savedUID {
            return false
        }

        return true
    }

    // MARK: - Capture Graph Pinning

    func handlePinnedInputPropertyChanged() {
        capturePinLock.lock()
        guard let pin = capturePin else {
            capturePinLock.unlock()
            return
        }
        let deviceID = pin.deviceID
        let pinnedSource = pin.dataSource
        capturePinLock.unlock()

        _ = restorePinnedInputDataSource(
            deviceID: deviceID,
            pinnedSource: pinnedSource,
            reason: "listener"
        )
    }

    private func bindInputNode(_ inputNode: AVAudioInputNode, toDeviceID deviceID: AudioDeviceID) -> Bool {
        var targetDeviceID = deviceID
        var didSetProperty = false

        if let audioUnit = inputNode.audioUnit {
            var currentDeviceID = AudioDeviceID(kAudioDeviceUnknown)
            var currentSize = UInt32(MemoryLayout<AudioDeviceID>.size)
            let getStatus = AudioUnitGetProperty(
                audioUnit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &currentDeviceID,
                &currentSize
            )
            if getStatus != noErr || currentDeviceID != deviceID {
                let setStatus = AudioUnitSetProperty(
                    audioUnit,
                    kAudioOutputUnitProperty_CurrentDevice,
                    kAudioUnitScope_Global,
                    0,
                    &targetDeviceID,
                    UInt32(MemoryLayout<AudioDeviceID>.size)
                )
                if setStatus != noErr {
                    DebugLog.info(
                        "AudioUnitSetProperty CurrentDevice failed status=\(setStatus)",
                        context: "AudioDeviceManager"
                    )
                } else {
                    didSetProperty = true
                }
            } else {
                didSetProperty = true
            }
        }

        let audioUnitDeviceID = inputNode.auAudioUnit.deviceID
        if audioUnitDeviceID != deviceID {
            inputNode.auAudioUnit.deviceID = deviceID
        }

        let boundDeviceID = inputNode.auAudioUnit.deviceID
        return didSetProperty || boundDeviceID == deviceID
    }

    private func pinInputDataSource(deviceID: AudioDeviceID, source: UInt32) -> Bool {
        setInputDataSource(deviceID: deviceID, source: source)
    }

    private func restorePinnedInputDataSource(
        deviceID: AudioDeviceID,
        pinnedSource: UInt32?,
        reason: String
    ) -> Bool {
        let current = currentInputDataSource(deviceID: deviceID)
        guard MacCaptureGraphPinPolicy.shouldRestoreInputDataSource(
            pinned: pinnedSource,
            current: current
        ), let pinnedSource else {
            return false
        }

        capturePinLock.lock()
        if isRestoringPinnedDataSource {
            capturePinLock.unlock()
            return false
        }
        isRestoringPinnedDataSource = true
        capturePinLock.unlock()
        defer {
            capturePinLock.lock()
            isRestoringPinnedDataSource = false
            capturePinLock.unlock()
        }

        let restored = setInputDataSource(deviceID: deviceID, source: pinnedSource)
        DebugLog.info(
            "Restored pinned input data source reason=\(reason) from=\(current.map(fourCCString) ?? "none") to=\(fourCCString(pinnedSource)) success=\(restored)",
            context: "AudioDeviceManager"
        )
        SentryTelemetry.recordAudioEngineEvent(
            restored ? "pinned_data_source_restored" : "pinned_data_source_restore_failed",
            reason: reason
        )
        return restored
    }

    private func endCapturePinLocked(recordingID: UUID?, reason: String) {
        capturePinLock.lock()
        if let recordingID, let pin = capturePin, pin.recordingID != recordingID {
            capturePinLock.unlock()
            return
        }
        let pin = capturePin
        capturePin = nil
        capturePinLock.unlock()

        guard let pin else { return }

        if pin.listensForDataSource {
            var address = inputDataSourcePropertyAddress()
            _ = AudioObjectRemovePropertyListener(
                pin.deviceID,
                &address,
                pinnedInputPropertyChangedCallback,
                nil
            )
        }
        if pin.listensForJack {
            var address = inputJackPropertyAddress()
            _ = AudioObjectRemovePropertyListener(
                pin.deviceID,
                &address,
                pinnedInputPropertyChangedCallback,
                nil
            )
        }

        DebugLog.info(
            "Capture pin \(reason) uid=\(pin.uniqueID)",
            context: "AudioDeviceManager"
        )
        SentryTelemetry.recordAudioEngineEvent("capture_graph_pin_ended", reason: reason)

        if reason == "ended" {
            DispatchQueue.main.async { [weak self] in
                self?.runPendingRouteReconciliationIfPossible()
            }
        }
    }

    private func currentInputDataSource(deviceID: AudioDeviceID) -> UInt32? {
        var propertyAddress = inputDataSourcePropertyAddress()
        var source: UInt32 = 0
        var dataSize = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(
            deviceID,
            &propertyAddress,
            0,
            nil,
            &dataSize,
            &source
        )
        guard status == noErr else { return nil }
        return source
    }

    @discardableResult
    private func setInputDataSource(deviceID: AudioDeviceID, source: UInt32) -> Bool {
        var propertyAddress = inputDataSourcePropertyAddress()
        var sourceCopy = source
        let dataSize = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectSetPropertyData(
            deviceID,
            &propertyAddress,
            0,
            nil,
            dataSize,
            &sourceCopy
        )
        return status == noErr
    }

    private func inputDataSourcePropertyAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDataSource,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private func inputJackPropertyAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyJackIsConnected,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private func fourCCString(_ value: UInt32) -> String {
        let bytes = [
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF)
        ]
        if bytes.allSatisfy({ (32...126).contains($0) }),
           let ascii = String(bytes: bytes, encoding: .ascii)
        {
            return ascii
        }
        return String(value)
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
        AudioDeviceManager.shared.handleAudioHardwareChanged()
    }
    return noErr
}

private func pinnedInputPropertyChangedCallback(
    _: AudioObjectID,
    _: UInt32,
    _: UnsafePointer<AudioObjectPropertyAddress>,
    _: UnsafeMutableRawPointer?
) -> OSStatus {
    DispatchQueue.main.async {
        AudioDeviceManager.shared.handlePinnedInputPropertyChanged()
    }
    return noErr
}
