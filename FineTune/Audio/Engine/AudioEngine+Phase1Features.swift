// FineTune/Audio/Engine/AudioEngine+Phase1Features.swift
import AudioToolbox
import Foundation

/// Phase 1 additions: per-device stereo processing (balance/mono/L-R swap), per-app balance,
/// per-device max volume limit, Bluetooth Output-Only (A2DP guard), and Quick Configs (scenes).
extension AudioEngine {

    // MARK: - Per-Device Stereo Processing, Max Volume Limit & BT Output-Only

    func getDeviceAudioProcessing(for deviceUID: String) -> DeviceAudioProcessingSettings {
        settingsManager.getDeviceAudioProcessing(for: deviceUID)
    }

    func setDeviceAudioProcessing(for deviceUID: String, to processing: DeviceAudioProcessingSettings) {
        settingsManager.setDeviceAudioProcessing(for: deviceUID, to: processing)
        applyStereoProcessingToTaps(for: deviceUID)

        // Immediately clamp current device volume if a new max volume limit is below current level.
        if let limit = processing.maxVolumeLimit, limit < 0.995,
           let device = deviceMonitor.device(for: deviceUID) {
            let backend = outputVolumeBackend(for: device.id)
            let maxBackend = VolumeMapping.systemGain(forSliderFraction: Double(limit), tier: backend)
            let currentVolume = deviceVolumeMonitor.volumes[device.id] ?? 1.0
            if currentVolume > maxBackend {
                deviceVolumeMonitor.setVolume(for: device.id, to: maxBackend)
            }
        }

        // Immediately move input off Bluetooth if Output-Only was just enabled.
        if processing.bluetoothOutputOnly,
           let currentInputUID = deviceVolumeMonitor.defaultInputDeviceUID {
            _ = enforceBluetoothOutputOnlyIfNeeded(forInputUID: currentInputUID)
        }
    }

    // MARK: - Per-Device Global Parametric EQ

    func getDeviceParametricEQ(for deviceUID: String) -> DeviceParametricEQ {
        settingsManager.getDeviceParametricEQ(for: deviceUID)
    }

    func setDeviceParametricEQ(for deviceUID: String, to eq: DeviceParametricEQ) {
        settingsManager.setDeviceParametricEQ(for: deviceUID, to: eq)
        applyAutoEQToTaps(for: deviceUID)
    }

    // MARK: - Per-App Stereo Balance

    func getBalance(for app: AudioApp) -> Float {
        settingsManager.getAppBalance(for: app.persistenceIdentifier)
    }

    func setBalance(for app: AudioApp, to balance: Float) {
        settingsManager.setAppBalance(for: app.persistenceIdentifier, to: balance)
        applyStereoProcessingToTap(forPID: app.id)
    }

    // MARK: - Bluetooth Output-Only (A2DP Protection)

    /// True when `inputUID` is a Bluetooth input whose paired output device has
    /// `bluetoothOutputOnly` enabled (matched by UID or normalized device name).
    func isProtectedBluetoothInput(_ inputUID: String) -> Bool {
        guard let inputDevice = deviceMonitor.inputDevice(for: inputUID) else { return false }
        let transport = inputDevice.id.readTransportType()
        guard transport == .bluetooth || transport == .bluetoothLE else { return false }

        let inputNameLower = inputDevice.name.lowercased()
        return deviceMonitor.outputDevices.contains { output in
            guard settingsManager.getDeviceAudioProcessing(for: output.uid).bluetoothOutputOnly else { return false }
            if output.uid == inputUID { return true }
            return output.name.lowercased() == inputNameLower
        }
    }

    /// Returns true if `inputUID` is a protected Bluetooth headset mic (blocking macOS from
    /// dragging the headset into SCO/HFP), redirecting to the best non-BT mic when available.
    @discardableResult
    func enforceBluetoothOutputOnlyIfNeeded(forInputUID inputUID: String) -> Bool {
        guard isProtectedBluetoothInput(inputUID) else { return false }
        _ = switchToBestNonBluetoothInput()
        return true
    }

    /// Selects the highest-priority connected non-Bluetooth input device.
    @discardableResult
    func switchToBestNonBluetoothInput() -> Bool {
        let nonBTInputs = deviceMonitor.inputDevices.filter { device in
            let t = device.id.readTransportType()
            return t != .bluetooth && t != .bluetoothLE
        }
        guard !nonBTInputs.isEmpty else { return false }

        let target: AudioDevice
        if let lockedUID = settingsManager.lockedInputDeviceUID,
           let locked = nonBTInputs.first(where: { $0.uid == lockedUID }) {
            target = locked
        } else if let priorityMatch = settingsManager.inputDevicePriorityOrder
            .compactMap({ uid in nonBTInputs.first(where: { $0.uid == uid }) })
            .first {
            target = priorityMatch
        } else if let builtIn = nonBTInputs.first(where: { $0.id.readTransportType() == .builtIn }) {
            target = builtIn
        } else {
            target = nonBTInputs[0]
        }

        guard deviceVolumeMonitor.defaultInputDeviceUID != target.uid else { return false }
        return switchInputForOutputOnly(target)
    }

    private func switchInputForOutputOnly(_ device: AudioDevice) -> Bool {
        switchDefaultInputTrackingEcho(device)
    }

    // MARK: - Quick Configs (Audio Scenes)

    var quickConfigs: [AudioScene] {
        settingsManager.audioScenes
    }

    var activeQuickConfigID: UUID? {
        settingsManager.activeAudioSceneID
    }

    var activeQuickConfig: AudioScene? {
        guard let id = settingsManager.activeAudioSceneID else { return nil }
        return settingsManager.audioScenes.first { $0.id == id }
    }

    /// Captures the current system and app audio state into a new `AudioScene`.
    func captureCurrentQuickConfig(name: String, icon: String = "sparkles", id: UUID = UUID()) -> AudioScene {
        let defaultOutputUID = deviceVolumeMonitor.defaultDeviceUID
        let defaultOutputKey = defaultOutputUID.flatMap { autoEQDeviceKey(for: $0) }
        let defaultInputUID = deviceVolumeMonitor.defaultInputDeviceUID

        var deviceVolumes: [String: Float] = [:]
        var deviceAutoEQ: [String: AutoEQSelection] = [:]
        for device in deviceMonitor.outputDevices {
            if let vol = deviceVolumeMonitor.volumes[device.id] {
                deviceVolumes[device.uid] = vol
            }
            if let sel = resolvedAutoEQSelection(for: device.uid, persist: false) {
                deviceAutoEQ[device.uid] = sel
            }
        }

        var appVolumes: [String: Float] = [:]
        var appMutes: [String: Bool] = [:]
        var appBalances: [String: Float] = [:]
        var appDeviceRouting: [String: String] = [:]
        for app in apps {
            let key = app.persistenceIdentifier
            appVolumes[key] = volumeState.getVolume(for: app.id)
            appMutes[key] = volumeState.getMute(for: app.id)
            let bal = settingsManager.getAppBalance(for: key)
            if bal != 0 { appBalances[key] = bal }
            if let route = settingsManager.getDeviceRouting(for: key) {
                appDeviceRouting[key] = route
            }
        }

        return AudioScene(
            id: id,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            icon: icon,
            defaultOutputUID: defaultOutputUID,
            defaultOutputDeviceKey: defaultOutputKey,
            defaultInputUID: defaultInputUID,
            deviceVolumes: deviceVolumes,
            deviceAutoEQ: deviceAutoEQ,
            deviceProcessing: settingsManager.allDeviceAudioProcessing,
            deviceParametricEQ: settingsManager.allDeviceParametricEQ,
            appVolumes: appVolumes,
            appMutes: appMutes,
            appBalances: appBalances,
            appDeviceRouting: appDeviceRouting,
            loudnessCompensationEnabled: settingsManager.appSettings.loudnessCompensationEnabled,
            loudnessEqualizationEnabled: settingsManager.appSettings.loudnessEqualizationEnabled
        )
    }

    @discardableResult
    func saveQuickConfig(name: String, icon: String = "sparkles") -> AudioScene? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let scene = captureCurrentQuickConfig(name: trimmed, icon: icon)
        settingsManager.saveAudioScene(scene)
        settingsManager.activeAudioSceneID = scene.id
        return scene
    }

    func updateQuickConfig(id: UUID) {
        guard let existing = settingsManager.audioScenes.first(where: { $0.id == id }) else { return }
        let updated = captureCurrentQuickConfig(name: existing.name, icon: existing.icon, id: existing.id)
        settingsManager.saveAudioScene(updated)
    }

    func deleteQuickConfig(id: UUID) {
        settingsManager.deleteAudioScene(id: id)
    }

    func renameQuickConfig(id: UUID, to name: String) {
        settingsManager.renameAudioScene(id: id, to: name)
    }

    /// Applies a saved Quick Config snapshot to connected devices and running apps.
    func applyQuickConfig(id: UUID) {
        guard let scene = settingsManager.audioScenes.first(where: { $0.id == id }) else { return }

        // Devices explicitly represented in this snapshot
        let capturedDeviceUIDs = Set(scene.deviceVolumes.keys)
            .union(scene.deviceAutoEQ.keys)
            .union(scene.deviceProcessing.keys)
            .union(scene.deviceParametricEQ.keys)

        // 1. Per-device stereo processing, parametric EQ, max volume limits & BT Output-Only
        for device in deviceMonitor.outputDevices where capturedDeviceUIDs.contains(device.uid) {
            let processing = scene.deviceProcessing[device.uid] ?? .default
            settingsManager.setDeviceAudioProcessing(for: device.uid, to: processing)
            if let peq = scene.deviceParametricEQ[device.uid] {
                settingsManager.setDeviceParametricEQ(for: device.uid, to: peq)
            } else if !scene.deviceParametricEQ.isEmpty {
                settingsManager.setDeviceParametricEQ(for: device.uid, to: .default)
            }
        }

        // 2. Default output device (UID match first, then manufacturer+name key fallback)
        if let targetOutput = resolveOutputDevice(uid: scene.defaultOutputUID, deviceKey: scene.defaultOutputDeviceKey) {
            setDefaultOutputDevice(targetOutput.id)
        }

        // 3. Default input device (never lock onto a Bluetooth mic protected by Output-Only,
        //    even if no alternative non-BT mic is connected)
        if let inputUID = scene.defaultInputUID,
           let targetInput = deviceMonitor.inputDevice(for: inputUID) {
            if isProtectedBluetoothInput(inputUID) {
                _ = switchToBestNonBluetoothInput()
            } else {
                setLockedInputDevice(targetInput)
            }
        }

        // 4. Device volumes (automatically clamped by maxVolumeLimit inside DeviceVolumeMonitor)
        for (uid, vol) in scene.deviceVolumes {
            if let device = deviceMonitor.device(for: uid) {
                deviceVolumeMonitor.setVolume(for: device.id, to: vol)
            }
        }

        // 5. Per-device AutoEQ + Parametric EQ application for every device captured in the scene
        //    (including devices with only PEQ such as HDMI outputs without volume sliders)
        for device in deviceMonitor.outputDevices where capturedDeviceUIDs.contains(device.uid) {
            let sel = scene.deviceAutoEQ[device.uid]
            settingsManager.setAutoEQSelection(
                for: device.uid,
                deviceKey: autoEQDeviceKey(for: device.uid),
                to: sel
            )
            applyAutoEQToTaps(for: device.uid)
        }

        // 6. Per-app volume, mute, balance, and routing (only touch apps present in the scene)
        for app in apps {
            let key = app.persistenceIdentifier
            let appCaptured = scene.appVolumes[key] != nil
                || scene.appMutes[key] != nil
                || scene.appBalances[key] != nil
                || scene.appDeviceRouting[key] != nil
            guard appCaptured else { continue }

            if let vol = scene.appVolumes[key] {
                setVolume(for: app, to: vol)
            }
            if let muted = scene.appMutes[key] {
                setMute(for: app, to: muted)
            }
            if let bal = scene.appBalances[key] {
                setBalance(for: app, to: bal)
            } else if scene.appVolumes[key] != nil {
                setBalance(for: app, to: 0.0)
            }
            if let routedUID = scene.appDeviceRouting[key],
               deviceMonitor.device(for: routedUID) != nil {
                setDevice(for: app, deviceUID: routedUID)
            } else if scene.appVolumes[key] != nil {
                setDevice(for: app, deviceUID: nil)
            }
        }

        // 7. Loudness settings
        var appSettings = settingsManager.appSettings
        appSettings.loudnessCompensationEnabled = scene.loudnessCompensationEnabled
        appSettings.loudnessEqualizationEnabled = scene.loudnessEqualizationEnabled
        settingsManager.updateAppSettings(appSettings)
        setLoudnessCompensationEnabled(scene.loudnessCompensationEnabled)
        setLoudnessEqualizationEnabled(scene.loudnessEqualizationEnabled)

        applyStereoProcessingToAllTaps()
        settingsManager.activeAudioSceneID = scene.id
    }

    /// Steps to the next saved Quick Config (wraps around). Used by the global shortcut.
    @discardableResult
    func cycleQuickConfig() -> AudioScene? {
        let scenes = settingsManager.audioScenes
        guard !scenes.isEmpty else { return nil }
        let next: AudioScene
        if let activeID = settingsManager.activeAudioSceneID,
           let idx = scenes.firstIndex(where: { $0.id == activeID }) {
            next = scenes[(idx + 1) % scenes.count]
        } else {
            next = scenes[0]
        }
        applyQuickConfig(id: next.id)
        return next
    }

    private func resolveOutputDevice(uid: String?, deviceKey: String?) -> AudioDevice? {
        if let uid, let exact = deviceMonitor.device(for: uid) {
            return exact
        }
        if let deviceKey {
            return deviceMonitor.outputDevices.first { autoEQDeviceKey(for: $0.uid) == deviceKey }
        }
        return nil
    }
}
