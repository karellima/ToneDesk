// FineTune/Audio/Engine/AudioEngine+AutoEQLibrary.swift
import AudioToolbox
import Foundation

/// Fork additions: AutoEQ profile library, device-name fallback, quick switching and A/B.
/// Kept in its own file so upstream merges of AudioEngine.swift stay small.
extension AudioEngine {

    // MARK: - Device identity

    /// Port-independent key (manufacturer + name) for an output device, if known.
    func autoEQDeviceKey(for deviceUID: String) -> String? {
        guard let device = deviceMonitor.device(for: deviceUID) else { return nil }
        let manufacturer = try? device.id.readString(kAudioObjectPropertyManufacturer)
        return AutoEQDeviceKey.make(name: device.name, manufacturer: manufacturer)
    }

    /// Selection for a device by UID, falling back to its name/manufacturer.
    /// With `persist`, a name match is re-bound to the current UID.
    func resolvedAutoEQSelection(for deviceUID: String, persist: Bool = true) -> AutoEQSelection? {
        settingsManager.resolveAutoEQSelection(
            for: deviceUID, deviceKey: autoEQDeviceKey(for: deviceUID), persist: persist)
    }

    // MARK: - Active device

    /// The output device quick-switching and A/B act on: the system default output.
    var autoEQTargetDeviceUID: String? {
        deviceVolumeMonitor.defaultDeviceUID
    }

    /// Display name of the target device (for menus).
    var autoEQTargetDeviceName: String? {
        autoEQTargetDeviceUID.flatMap { deviceMonitor.device(for: $0)?.name }
    }

    /// Profile currently assigned to the target device (enabled or not).
    var activeAutoEQProfile: AutoEQProfile? {
        guard let uid = autoEQTargetDeviceUID,
              let selection = resolvedAutoEQSelection(for: uid, persist: false) else { return nil }
        return autoEQProfileManager.profile(for: selection.profileID)
    }

    var isActiveAutoEQEnabled: Bool {
        guard let uid = autoEQTargetDeviceUID else { return false }
        return resolvedAutoEQSelection(for: uid, persist: false)?.isEnabled ?? false
    }

    /// Applies a library profile to the target device (nil = no correction).
    func selectAutoEQProfileForActiveDevice(_ profileID: String?) {
        guard let uid = autoEQTargetDeviceUID else { return }
        setAutoEQProfile(for: uid, profileID: profileID)
    }

    /// Steps through the library in user order (wraps). Returns the new profile.
    @discardableResult
    func cycleAutoEQProfile(offset: Int) -> AutoEQProfile? {
        guard autoEQTargetDeviceUID != nil else { return nil }
        let next = autoEQLibrary.neighbor(of: activeAutoEQProfile?.id, offset: offset)
        if let next { selectAutoEQProfileForActiveDevice(next.id) }
        return next
    }

    // MARK: - A/B

    var autoEQAB: AutoEQABSettings { settingsManager.autoEQAB }

    func setAutoEQABProfile(_ profileID: String?, slot: AutoEQABSettings.Slot) {
        var ab = settingsManager.autoEQAB
        switch slot {
        case .a: ab.profileA = profileID
        case .b: ab.profileB = profileID
        }
        settingsManager.autoEQAB = ab
        reapplyAutoEQForActiveDevice()
    }

    func setAutoEQABLevelMatch(_ enabled: Bool) {
        var ab = settingsManager.autoEQAB
        ab.levelMatch = enabled
        settingsManager.autoEQAB = ab
        reapplyAutoEQForActiveDevice()
    }

    /// Switches to the other A/B slot and applies it to the target device.
    /// If the device is not currently on A or B, starts with A.
    @discardableResult
    func toggleAutoEQAB() -> AutoEQABSettings.Slot? {
        var ab = settingsManager.autoEQAB
        guard ab.isConfigured else { return nil }
        let currentID = activeAutoEQProfile?.id
        if currentID == ab.profileA || currentID == ab.profileB {
            ab.active = ab.active == .a ? .b : .a
        } else {
            ab.active = .a
        }
        settingsManager.autoEQAB = ab
        selectAutoEQProfileForActiveDevice(ab.activeProfileID)
        return ab.active
    }

    /// Which A/B slot is playing on the target device, if any.
    var activeAutoEQABSlot: AutoEQABSettings.Slot? {
        let ab = settingsManager.autoEQAB
        guard ab.isConfigured, let id = activeAutoEQProfile?.id else { return nil }
        if id == ab.profileA { return .a }
        if id == ab.profileB { return .b }
        return nil
    }

    /// Level-matching trims (dB, ≤ 0) for the configured A/B pair, or nil.
    var autoEQABTrims: (a: Float, b: Float)? {
        let ab = settingsManager.autoEQAB
        guard ab.isConfigured, ab.levelMatch,
              let idA = ab.profileA, let idB = ab.profileB,
              let a = autoEQProfileManager.profile(for: idA),
              let b = autoEQProfileManager.profile(for: idB) else { return nil }
        let trims = AutoEQLoudness.levelMatchTrims(a: a, b: b, includePreamp: settingsManager.autoEQPreampEnabled)
        return (trims.0, trims.1)
    }

    /// Profile as it should play: adds the A/B level-match trim when applicable.
    func autoEQProfileForPlayback(_ profile: AutoEQProfile) -> AutoEQProfile {
        let ab = settingsManager.autoEQAB
        guard let trims = autoEQABTrims else { return profile }
        var result = profile
        if profile.id == ab.profileA {
            result.levelTrimDB = trims.a
        } else if profile.id == ab.profileB {
            result.levelTrimDB = trims.b
        }
        return result
    }

    private func reapplyAutoEQForActiveDevice() {
        guard let uid = autoEQTargetDeviceUID else { return }
        applyAutoEQToTaps(for: uid)
    }

    // MARK: - Library edits that affect assignments

    /// Deletes a library profile and clears every assignment that used it.
    func deleteLibraryProfile(id: String) {
        let affected = deviceMonitor.outputDevices
            .map(\.uid)
            .filter { resolvedAutoEQSelection(for: $0, persist: false)?.profileID == id }
        autoEQLibrary.delete(id: id)
        settingsManager.removeAutoEQSelections(profileID: id)
        for uid in affected { applyAutoEQToTaps(for: uid) }
    }

    /// Renames a library profile and refreshes taps playing it (name only; no audio change).
    @discardableResult
    func renameLibraryProfile(id: String, to name: String) -> Bool {
        autoEQLibrary.rename(id: id, to: name)
    }

    /// Imports files/folders into the library. When `assignToActiveDevice` and exactly
    /// one profile was imported, it is applied to the target device.
    func importIntoLibrary(_ urls: [URL], assignToActiveDevice: Bool = false) -> AutoEQImportSummary {
        let summary = autoEQLibrary.importItems(at: urls)
        if assignToActiveDevice, summary.imported.count == 1 {
            selectAutoEQProfileForActiveDevice(summary.imported[0].id)
        }
        return summary
    }

    /// Restores a library backup and its favorites.
    func importLibraryBackup(from url: URL) throws -> AutoEQImportSummary {
        let result = try autoEQLibrary.importBackup(from: url)
        for id in result.favoriteIDs { settingsManager.favoriteAutoEQProfile(id: id) }
        return result.summary
    }

    func exportLibraryBackup(to url: URL) throws {
        try autoEQLibrary.exportBackup(to: url, favoriteIDs: settingsManager.favoriteAutoEQProfileIDs)
    }
}
extension AudioEngine: AutoEQShortcutHandling {}
