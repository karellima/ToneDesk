// FineTune/Views/MenuBar/MenuBarIconCoordinator.swift
// Owns NSStatusBarButton.image mutation. FluidMenuBarExtra sets the image
// once at init and never touches it again, so we locate the button by
// walking NSApp.windows for the NSStatusBarButton whose accessibilityTitle
// was set to "FineTune" by the library, and crossfade images directly.

import AppKit
import AudioToolbox
import Observation
import os

@MainActor
final class MenuBarIconCoordinator: MediaKeyIconFlashing {
    private let deviceVolumeMonitor: DeviceVolumeMonitor
    private let deviceProvider: any AudioDeviceProviding
    private let settings: SettingsManager
    private let logger = Logger(subsystem: "com.finetuneapp.FineTune", category: "MenuBarIconCoordinator")

    private weak var cachedButton: NSStatusBarButton?
    private var flashWorkItem: DispatchWorkItem?
    private var flashActiveSymbol: String?
    private var lastObservedDeviceID: AudioDeviceID?
    private var started = false

    /// Live peak audio level (0...1) for the optional menu-bar VU meter.
    var audioLevelProvider: (() -> Float)?
    /// Called when the user scrolls the mouse wheel directly over the menu bar icon.
    var onQuickVolumeDelta: ((Double) -> Void)?
    /// Called when the user Option-clicks or middle-clicks the menu bar icon.
    var onQuickMuteToggle: (() -> Void)?

    private var meterTimer: Timer?
    private var lastMeterBucket: Int = -1
    private var localStatusItemEventMonitor: Any?
    private var globalStatusItemEventMonitor: Any?

    init(
        deviceVolumeMonitor: DeviceVolumeMonitor,
        deviceProvider: any AudioDeviceProviding,
        settings: SettingsManager
    ) {
        self.deviceVolumeMonitor = deviceVolumeMonitor
        self.deviceProvider = deviceProvider
        self.settings = settings
    }

    /// Registers the local status-item event monitor eagerly so it precedes
    /// `FluidMenuBarExtraStatusItem`'s own local monitor in AppKit's FIFO dispatch
    /// queue. That ensures Option-click is intercepted and consumed before
    /// `FluidMenuBarExtra` can open the popup. Safe to call before `start()`.
    func installEarlyLocalMonitor() {
        guard localStatusItemEventMonitor == nil else { return }
        localStatusItemEventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.scrollWheel, .leftMouseDown, .otherMouseDown]
        ) { [weak self] event in
            guard let self else { return event }
            return self.handleLocalStatusItemEvent(event)
        }
    }

    /// Begin observing volume / mute / style and apply state to the menu bar button.
    /// Idempotent; safe to call from the app-init path even before the status item exists.
    func start() {
        guard !started else { return }
        started = true
        lastObservedDeviceID = deviceVolumeMonitor.defaultDeviceID
        installEarlyLocalMonitor()
        attemptInitialApply(retriesLeft: 20)
        scheduleApplyTracking()
        scheduleDeviceChangeTracking()
        syncQuickControlMonitor()
        syncMeterTimer()
    }

    /// Cancel pending work and drop references. Called on app termination.
    func stop() {
        flashWorkItem?.cancel()
        flashWorkItem = nil
        meterTimer?.invalidate()
        meterTimer = nil
        if let monitor = localStatusItemEventMonitor {
            NSEvent.removeMonitor(monitor)
            localStatusItemEventMonitor = nil
        }
        if let monitor = globalStatusItemEventMonitor {
            NSEvent.removeMonitor(monitor)
            globalStatusItemEventMonitor = nil
        }
        cachedButton = nil
    }

    /// Transient device-icon flash. Applies to every style; fires on media keys and device changes.
    /// If the same symbol is already flashing, extends the timer rather than restarting the fade —
    /// prevents mid-fade pops when device-change and media-key triggers coincide.
    func flashDevice() {
        let symbol = currentDeviceSymbol()
        let alreadyShowingSame = (flashActiveSymbol == symbol)
        flashActiveSymbol = symbol
        if !alreadyShowingSame {
            apply()
        }

        flashWorkItem?.cancel()
        let duration = flashDuration()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.flashActiveSymbol = nil
            self.apply()
        }
        flashWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: item)
    }

    // MARK: - State

    private func computeState() -> MenuBarIconState {
        if let symbol = flashActiveSymbol {
            return .deviceFlash(symbol: symbol)
        }
        let id = deviceVolumeMonitor.defaultDeviceID
        let volume = deviceVolumeMonitor.volumes[id] ?? 0
        let muted = deviceVolumeMonitor.muteStates[id] ?? false
        return MenuBarIconState.baseline(
            style: settings.appSettings.menuBarIconStyle,
            volume: volume,
            muted: muted,
            deviceSymbol: currentDeviceSymbol()
        )
    }

    private func currentDeviceSymbol() -> String {
        MenuBarDeviceIconResolver.resolveSymbol(
            priorityOrder: settings.devicePriorityOrder,
            outputDevices: deviceProvider.outputDevices,
            defaultDeviceID: deviceVolumeMonitor.defaultDeviceID,
            overrideForUID: { [settings] in settings.getDeviceIconOverride(for: $0) }
        )
    }

    private func flashDuration() -> TimeInterval {
        // Matches HUDWindowController.hideDelay so the icon and HUD fade in lockstep.
        return 1.1
    }

    // MARK: - Apply

    private func apply(animated: Bool = true) {
        guard let button = resolveButton() else { return }
        let state = computeState()
        let showMeter = settings.appSettings.showMenuBarMeter
        let id = deviceVolumeMonitor.defaultDeviceID
        let muted = deviceVolumeMonitor.muteStates[id] ?? false
        let volume = deviceVolumeMonitor.volumes[id] ?? 0
        let level = showMeter ? (audioLevelProvider?() ?? 0) : 0

        let image: NSImage?
        if showMeter {
            image = state.image.nsImageWithMeter(level: level, muted: muted)
        } else {
            image = state.image.nsImage()
        }
        guard let image else { return }
        if animated {
            addFadeTransition(to: button)
        }
        button.image = image

        if settings.appSettings.showMenuBarVolumeLabel {
            let tier = deviceVolumeMonitor.outputVolumeBackend(for: id)
            let slider = DeviceRow.volumeToSlider(volume, backend: tier)
            let pct = Int(round(slider * 100))
            let text = (muted || pct == 0) ? " Muted" : " \(pct)%"
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
                .foregroundColor: NSColor.labelColor
            ]
            button.imagePosition = .imageLeading
            button.attributedTitle = NSAttributedString(string: text, attributes: attrs)
        } else {
            button.imagePosition = .imageOnly
            if !button.title.isEmpty {
                button.title = ""
            }
        }
    }

    /// Computes a safe, trackpad-friendly volume slider delta for a single scroll event over the
    /// menu bar icon. Drops kinetic momentum tails, respects natural scroll direction, scales
    /// precise trackpad pixel deltas gently (vs discrete mouse-wheel detents), and caps any
    /// single event to ±6% to protect hearing.
    nonisolated static func scrollVolumeDelta(
        deltaY: CGFloat,
        hasPreciseDeltas: Bool,
        isDirectionInverted: Bool,
        isMomentumTail: Bool,
        discreteStep: Double
    ) -> Double {
        let sensitivity: Double = 0.0025
        let lineUnits: Double = max(1.0, (discreteStep * 0.5) / sensitivity)
        var probe: Double = 0.5
        ScrollWheelStep.apply(
            deltaY: deltaY,
            hasPreciseDeltas: hasPreciseDeltas,
            isDirectionInverted: isDirectionInverted,
            isMomentumTail: isMomentumTail,
            value: &probe,
            sensitivity: sensitivity,
            lineUnits: lineUnits,
            in: 0.0...1.0
        )
        let rawDelta = probe - 0.5
        return max(-0.06, min(0.06, rawDelta))
    }

    private func syncMeterTimer() {
        if settings.appSettings.showMenuBarMeter {
            guard meterTimer == nil else { return }
            lastMeterBucket = -1
            meterTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 15.0, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.tickMeter()
                }
            }
        } else {
            meterTimer?.invalidate()
            meterTimer = nil
            lastMeterBucket = -1
        }
    }

    private func tickMeter() {
        guard settings.appSettings.showMenuBarMeter else { return }
        let id = deviceVolumeMonitor.defaultDeviceID
        let muted = deviceVolumeMonitor.muteStates[id] ?? false
        let level = muted ? 0 : (audioLevelProvider?() ?? 0)
        // Quantize to 12 buckets (0...11) so silent idle state never redraws.
        let bucket = level > 0.02 ? min(11, max(1, Int(round(level * 11)))) : 0
        guard bucket != lastMeterBucket else { return }
        lastMeterBucket = bucket
        apply(animated: false)
    }

    /// Installs or removes the global event monitor for scroll-wheel volume + middle-click mute
    /// over the menu bar icon when another app is active. The local monitor stays registered in
    /// front of `FluidMenuBarExtraStatusItem`'s monitor and checks `menuBarQuickControlsEnabled`
    /// dynamically so toggling the preference never loses FIFO priority for Option-click.
    private func syncQuickControlMonitor() {
        if settings.appSettings.menuBarQuickControlsEnabled {
            installEarlyLocalMonitor()
            guard globalStatusItemEventMonitor == nil else { return }
            globalStatusItemEventMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.scrollWheel, .otherMouseDown]
            ) { [weak self] event in
                MainActor.assumeIsolated {
                    self?.handleGlobalStatusItemEvent(event)
                }
            }
        } else if let monitor = globalStatusItemEventMonitor {
            NSEvent.removeMonitor(monitor)
            globalStatusItemEventMonitor = nil
        }
    }

    private func handleLocalStatusItemEvent(_ event: NSEvent) -> NSEvent? {
        guard settings.appSettings.menuBarQuickControlsEnabled,
              let button = resolveButton(),
              let buttonWindow = button.window,
              buttonWindow.isVisible else {
            return event
        }

        let isOverStatusItem = Self.isPointerOverStatusItem(
            mouseLocation: NSEvent.mouseLocation,
            buttonWindowFrame: buttonWindow.frame,
            eventWindowMatchesButton: event.window === buttonWindow
        )
        guard isOverStatusItem else { return event }

        if event.type == .scrollWheel {
            applyScrollEvent(event)
            return nil
        }

        if Self.shouldToggleMute(
            eventType: event.type,
            buttonNumber: event.buttonNumber,
            modifierFlags: event.modifierFlags
        ) {
            onQuickMuteToggle?()
            return nil
        }

        return event
    }

    private func handleGlobalStatusItemEvent(_ event: NSEvent) {
        guard settings.appSettings.menuBarQuickControlsEnabled,
              let button = resolveButton(),
              let buttonWindow = button.window,
              buttonWindow.isVisible else {
            return
        }

        guard Self.isPointerOverStatusItem(
            mouseLocation: NSEvent.mouseLocation,
            buttonWindowFrame: buttonWindow.frame,
            eventWindowMatchesButton: false
        ) else {
            return
        }

        if event.type == .scrollWheel {
            applyScrollEvent(event)
        } else if Self.shouldToggleMute(
            eventType: event.type,
            buttonNumber: event.buttonNumber,
            modifierFlags: event.modifierFlags
        ) {
            onQuickMuteToggle?()
        }
    }

    private func applyScrollEvent(_ event: NSEvent) {
        let delta = Self.scrollVolumeDelta(
            deltaY: event.scrollingDeltaY,
            hasPreciseDeltas: event.hasPreciseScrollingDeltas,
            isDirectionInverted: event.isDirectionInvertedFromDevice,
            isMomentumTail: event.momentumPhase != [],
            discreteStep: settings.appSettings.volumeHotkeyStep.sliderDelta
        )
        guard abs(delta) > 0.0001 else { return }
        onQuickVolumeDelta?(delta)
    }

    nonisolated static func isPointerOverStatusItem(
        mouseLocation: NSPoint,
        buttonWindowFrame: NSRect,
        eventWindowMatchesButton: Bool
    ) -> Bool {
        eventWindowMatchesButton || buttonWindowFrame.contains(mouseLocation)
    }

    nonisolated static func shouldToggleMute(
        eventType: NSEvent.EventType,
        buttonNumber: Int,
        modifierFlags: NSEvent.ModifierFlags
    ) -> Bool {
        if eventType == .otherMouseDown {
            return buttonNumber == 2
        }
        if eventType == .leftMouseDown {
            return modifierFlags.contains(.option) && !modifierFlags.contains(.command)
        }
        return false
    }

    private func attemptInitialApply(retriesLeft: Int) {
        if resolveButton() != nil {
            apply()
            return
        }
        guard retriesLeft > 0 else {
            logger.error("Menu bar button not found after 20 tries (1s); icon will remain at FluidMenuBarExtra placeholder until next state change")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.attemptInitialApply(retriesLeft: retriesLeft - 1)
        }
    }

    private func scheduleApplyTracking() {
        withObservationTracking {
            let id = deviceVolumeMonitor.defaultDeviceID
            _ = deviceVolumeMonitor.volumes[id]
            _ = deviceVolumeMonitor.muteStates[id]
            _ = settings.appSettings.menuBarIconStyle
            _ = settings.appSettings.showMenuBarMeter
            _ = settings.appSettings.showMenuBarVolumeLabel
            _ = settings.appSettings.menuBarQuickControlsEnabled
            _ = settings.appSettings.hudStyle
            _ = settings.devicePriorityOrder
            // Deliberate dependency so the device-style icon refreshes when the user picks a new symbol; explicit because observation granularity is per stored property.
            _ = settings.deviceIconOverrides
            _ = deviceProvider.outputDevices
        } onChange: { [weak self] in
            // onChange fires in willSet — the tracked properties are still at their
            // pre-change values inside this closure. Re-register synchronously so the
            // next mutation isn't dropped, then defer apply() to a Task so it reads
            // committed (post-setter) values.
            MainActor.assumeIsolated { [weak self] in
                self?.scheduleApplyTracking()
            }
            Task { @MainActor [weak self] in
                self?.syncMeterTimer()
                self?.syncQuickControlMonitor()
                self?.apply()
            }
        }
    }

    private func scheduleDeviceChangeTracking() {
        withObservationTracking {
            _ = deviceVolumeMonitor.defaultDeviceID
        } onChange: { [weak self] in
            // See scheduleApplyTracking — deferred read so flashDevice sees the NEW
            // defaultDeviceID, not the pre-change value. Otherwise the flash shows
            // the old device's icon (e.g. AirPods while we just switched to MacBook).
            MainActor.assumeIsolated { [weak self] in
                self?.scheduleDeviceChangeTracking()
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                let newID = self.deviceVolumeMonitor.defaultDeviceID
                if let prev = self.lastObservedDeviceID, prev != newID, newID.isValid {
                    self.flashDevice()
                }
                self.lastObservedDeviceID = newID
            }
        }
    }

    // MARK: - Button + image

    private func resolveButton() -> NSStatusBarButton? {
        if let cached = cachedButton { return cached }
        for window in NSApp.windows {
            guard let contentView = window.contentView else { continue }
            if let button = findStatusBarButton(in: contentView, matching: "ToneDesk") {
                button.wantsLayer = true
                cachedButton = button
                return button
            }
        }
        return nil
    }

    private func findStatusBarButton(in view: NSView, matching title: String) -> NSStatusBarButton? {
        if let button = view as? NSStatusBarButton, button.accessibilityTitle() == title {
            return button
        }
        for subview in view.subviews {
            if let match = findStatusBarButton(in: subview, matching: title) {
                return match
            }
        }
        return nil
    }

    private func addFadeTransition(to button: NSStatusBarButton) {
        let transition = CATransition()
        transition.type = .fade
        transition.duration = 0.18
        transition.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        button.layer?.add(transition, forKey: "iconFade")
    }
}
