import AudioToolbox
import CoreAudio
import Foundation

class AudioVolumeManager {
    private let stateLock = NSLock()
    private var activeGeneration: UUID?
    private var baselineVolume: Float?
    private var inFlightWorkers = 0
    private let targetVolumeLevel: Float = 0.3 // Set volume to 30% (0.0 to 1.0 scale)

    /// Starts a disposable volume adjustment. Core Audio never runs on the caller's
    /// thread, and a late adjustment compensates itself if recording has stopped.
    func lowerVolume() {
        let generation = UUID()
        stateLock.lock()
        activeGeneration = generation
        inFlightWorkers += 1
        stateLock.unlock()

        makeDisposableQueue().async { [self] in
            defer { finishWorker() }
            guard let currentVolume = getSystemVolume() else {
                DebugLog.info("Failed to get current volume", context: "AudioVolumeManager")
                return
            }

            stateLock.lock()
            if activeGeneration == generation, baselineVolume == nil {
                baselineVolume = currentVolume
            }
            let hasAuthoritativeVolume = activeGeneration != nil || baselineVolume != nil
            stateLock.unlock()

            guard hasAuthoritativeVolume else { return }
            convergeToAuthoritativeVolume()
        }
    }

    /// Invalidates any in-flight lowering immediately and restores in the
    /// background. A newer recording remains authoritative if it starts first.
    func restoreVolume() {
        stateLock.lock()
        activeGeneration = nil
        let shouldRestore = baselineVolume != nil
        if shouldRestore {
            inFlightWorkers += 1
        }
        stateLock.unlock()

        guard shouldRestore else { return }
        makeDisposableQueue().async { [self] in
            defer { finishWorker() }
            convergeToAuthoritativeVolume()
        }
    }

    /// Every worker re-reads the desired state after its uncancellable native set.
    /// Therefore the last native call to return also repairs any older side effect.
    private func convergeToAuthoritativeVolume() {
        while true {
            stateLock.lock()
            let desiredVolume = activeGeneration == nil ? baselineVolume : targetVolumeLevel
            stateLock.unlock()

            guard let desiredVolume else { return }
            setSystemVolume(desiredVolume)

            stateLock.lock()
            let latestDesiredVolume = activeGeneration == nil ? baselineVolume : targetVolumeLevel
            stateLock.unlock()
            guard latestDesiredVolume != desiredVolume else { return }
        }
    }

    private func finishWorker() {
        stateLock.lock()
        inFlightWorkers = max(0, inFlightWorkers - 1)
        if inFlightWorkers == 0, activeGeneration == nil {
            baselineVolume = nil
        }
        stateLock.unlock()
    }

    private func makeDisposableQueue() -> DispatchQueue {
        DispatchQueue(
            label: "ai.writingmate.audio-volume.\(UUID().uuidString)",
            qos: .utility
        )
    }

    // MARK: - Private Helpers

    private func getDefaultOutputDevice() -> AudioDeviceID? {
        var deviceID = AudioDeviceID(0)
        var propertySize = UInt32(MemoryLayout<AudioDeviceID>.size)

        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &propertySize,
            &deviceID
        )

        guard status == noErr else {
            DebugLog.info("Error getting default output device: \(status)", context: "AudioVolumeManager")
            return nil
        }

        return deviceID
    }

    private func getSystemVolume() -> Float? {
        guard let deviceID = getDefaultOutputDevice() else {
            return nil
        }

        var volume: Float = 0.0
        var propertySize = UInt32(MemoryLayout<Float>.size)

        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectGetPropertyData(
            deviceID,
            &propertyAddress,
            0,
            nil,
            &propertySize,
            &volume
        )

        guard status == noErr else {
            DebugLog.info("Error getting volume: \(status)", context: "AudioVolumeManager")
            return nil
        }

        return volume
    }

    private func setSystemVolume(_ volume: Float) {
        guard let deviceID = getDefaultOutputDevice() else {
            return
        }

        var newVolume = max(0.0, min(1.0, volume)) // Clamp between 0 and 1
        let propertySize = UInt32(MemoryLayout<Float>.size)

        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectSetPropertyData(
            deviceID,
            &propertyAddress,
            0,
            nil,
            propertySize,
            &newVolume
        )

        if status != noErr {
            DebugLog.info("Error setting volume: \(status)", context: "AudioVolumeManager")
        }
    }
}
