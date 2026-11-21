// FineTune/Views/MenuBar/AutoEQStatusMenu.swift
import AppKit
import AudioToolbox

/// Right-click menu on the menu bar icon: one-click switching between library profiles
/// for the default output device, plus A/B controls. Rebuilt every time it opens.
///
/// Installed through `FluidMenuBarExtra(menu:)`, the package's public right-click hook.
@MainActor
final class AutoEQStatusMenu: NSObject, NSMenuDelegate {
    let menu = NSMenu(title: "EQ Profiles")
    private weak var engine: AudioEngine?

    /// Opens the Settings window (set by the popup once SwiftUI's `openSettings` is available).
    static var openSettingsAction: (() -> Void)?

    init(engine: AudioEngine) {
        self.engine = engine
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let engine else { return }

        let deviceName = engine.autoEQTargetDeviceName ?? "No output device"
        menu.addItem(header("Output · \(deviceName)"))

        // Quick mute + output device switcher directly from the right-click menu
        let defaultID = engine.deviceVolumeMonitor.defaultDeviceID
        if defaultID.isValid {
            let isMuted = engine.deviceVolumeMonitor.muteStates[defaultID] ?? false
            let muteItem = item(isMuted ? "Unmute \(deviceName)" : "Mute \(deviceName)", action: #selector(toggleDefaultMute))
            menu.addItem(muteItem)
        }
        let outputs = engine.prioritySortedOutputDevices
        if outputs.count > 1 {
            let switchItem = NSMenuItem(title: "Switch Output Device", action: nil, keyEquivalent: "")
            let sub = NSMenu(title: "Output Devices")
            for dev in outputs {
                let devItem = item(dev.name, action: #selector(selectOutputDevice(_:)))
                devItem.representedObject = dev.id
                devItem.state = (dev.id == defaultID) ? .on : .off
                sub.addItem(devItem)
            }
            switchItem.submenu = sub
            menu.addItem(switchItem)
        }

        menu.addItem(.separator())
        menu.addItem(header("EQ profile"))

        let active = engine.activeAutoEQProfile
        let enabled = engine.isActiveAutoEQEnabled
        let none = item("No correction", action: #selector(selectNone))
        none.state = (active == nil || !enabled) ? .on : .off
        menu.addItem(none)

        let library = engine.autoEQLibrary.profiles
        let favorites = engine.settingsManager.favoriteAutoEQProfileIDs
        if library.isEmpty {
            let empty = item("Library is empty — import profiles in Settings", action: nil)
            empty.isEnabled = false
            menu.addItem(empty)
        }
        for profile in library {
            let title = (favorites.contains(profile.id) ? "★ " : "") + profile.name
            let entry = item(title, action: #selector(selectProfile(_:)))
            entry.representedObject = profile.id
            entry.state = (enabled && active?.id == profile.id) ? .on : .off
            entry.toolTip = Self.summary(profile)
            menu.addItem(entry)
        }

        // Active profile from the AutoEQ database (not in the library)
        if let active, active.source != .imported {
            let entry = item(active.name, action: nil)
            entry.state = enabled ? .on : .off
            entry.isEnabled = false
            menu.addItem(entry)
        }

        menu.addItem(.separator())
        let next = item("Next Profile", action: #selector(nextProfile))
        next.isEnabled = !library.isEmpty
        menu.addItem(next)
        let previous = item("Previous Profile", action: #selector(previousProfile))
        previous.isEnabled = !library.isEmpty
        menu.addItem(previous)

        // A/B
        menu.addItem(.separator())
        let ab = engine.autoEQAB
        if ab.isConfigured,
           let a = ab.profileA.flatMap(engine.autoEQProfileManager.profile(for:)),
           let b = ab.profileB.flatMap(engine.autoEQProfileManager.profile(for:)) {
            let slot = engine.activeAutoEQABSlot
            let current = slot.map { $0 == .a ? "A" : "B" } ?? "–"
            menu.addItem(header("A/B · playing \(current)"))
            let itemA = item("A: \(a.name)", action: #selector(selectA))
            itemA.state = slot == .a ? .on : .off
            menu.addItem(itemA)
            let itemB = item("B: \(b.name)", action: #selector(selectB))
            itemB.state = slot == .b ? .on : .off
            menu.addItem(itemB)
            menu.addItem(item("Switch A ⇄ B", action: #selector(toggleAB)))
            let level = item("Level-match A/B", action: #selector(toggleLevelMatch))
            level.state = ab.levelMatch ? .on : .off
            if let trims = engine.autoEQABTrims {
                level.toolTip = String(format: "A %.1f dB · B %.1f dB", trims.a, trims.b)
            }
            menu.addItem(level)
        } else {
            let setup = item("A/B: choose A and B in Settings › Profiles", action: nil)
            setup.isEnabled = false
            menu.addItem(setup)
        }

        // Quick Configs (Audio Scenes)
        let scenes = engine.quickConfigs
        if !scenes.isEmpty {
            menu.addItem(.separator())
            let activeSceneID = engine.activeQuickConfigID
            menu.addItem(header(activeSceneID != nil ? "Quick Configs · ✓ last applied" : "Quick Configs"))
            for scene in scenes {
                let entry = item(scene.name, action: #selector(selectQuickConfig(_:)))
                entry.representedObject = scene.id
                entry.state = (scene.id == activeSceneID) ? .on : .off
                menu.addItem(entry)
            }
        }

        menu.addItem(.separator())
        menu.addItem(item("Manage Profile Library…", action: #selector(openLibrary)))
    }

    /// "Preamp −6.5 dB · 10 filters"
    static func summary(_ profile: AutoEQProfile) -> String {
        String(format: "Preamp %.1f dB · %d filter%@", profile.preampDB, profile.filters.count,
               profile.filters.count == 1 ? "" : "s")
    }

    // MARK: - Builders

    private func header(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func item(_ title: String, action: Selector?) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    // MARK: - Actions

    @objc private func toggleDefaultMute() {
        guard let engine else { return }
        let id = engine.deviceVolumeMonitor.defaultDeviceID
        guard id.isValid else { return }
        let muted = engine.deviceVolumeMonitor.muteStates[id] ?? false
        engine.deviceVolumeMonitor.setMute(for: id, to: !muted)
    }

    @objc private func selectOutputDevice(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? AudioDeviceID else { return }
        engine?.setDefaultOutputDevice(id)
    }

    @objc private func selectNone() { engine?.selectAutoEQProfileForActiveDevice(nil) }

    @objc private func selectProfile(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        engine?.selectAutoEQProfileForActiveDevice(id)
    }

    @objc private func nextProfile() { engine?.cycleAutoEQProfile(offset: 1) }
    @objc private func previousProfile() { engine?.cycleAutoEQProfile(offset: -1) }

    @objc private func selectA() { selectSlot(.a) }
    @objc private func selectB() { selectSlot(.b) }

    private func selectSlot(_ slot: AutoEQABSettings.Slot) {
        guard let engine else { return }
        var ab = engine.settingsManager.autoEQAB
        ab.active = slot
        engine.settingsManager.autoEQAB = ab
        engine.selectAutoEQProfileForActiveDevice(ab.activeProfileID)
    }

    @objc private func toggleAB() { engine?.toggleAutoEQAB() }

    @objc private func toggleLevelMatch() {
        guard let engine else { return }
        engine.setAutoEQABLevelMatch(!engine.autoEQAB.levelMatch)
    }

    @objc private func selectQuickConfig(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        engine?.applyQuickConfig(id: id)
    }

    @objc private func openLibrary() {
        NSApp.activate(ignoringOtherApps: true)
        SettingsNavigation.shared.requestedSection = "profiles"
        if let openSettings = Self.openSettingsAction {
            openSettings()
        } else {
            // Works even if the left-click popup has never been opened since launch.
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            WindowFrontPresenter.bringSettingsToFront()
        }
    }
}

/// Lets non-SwiftUI code ask the Settings window to show a specific tab.
@MainActor
@Observable
final class SettingsNavigation {
    static let shared = SettingsNavigation()
    /// Raw value of `SettingsRootView.Section` to select, consumed by the view.
    var requestedSection: String?
}
