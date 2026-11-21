// FineTune/Views/DesignSystem/PinnedPopupWindowController.swift
import AppKit

/// Allows pinning the `FluidMenuBarExtra` popup window open as a floating, draggable panel.
///
/// `FluidMenuBarExtraStatusItem` sets itself as `window.delegate` and dismisses the panel in
/// `windowDidResignKey(_:)`. While pinned, this proxy intercepts `windowDidResignKey(_:)` so
/// clicking outside does not hide the panel, while forwarding all other delegate callbacks and
/// restoring the original delegate immediately upon unpinning.
@MainActor
final class PinnedPopupWindowController: NSObject, NSWindowDelegate {
    static let shared = PinnedPopupWindowController()

    private(set) var isPinned = false
    /// Invoked whenever `isPinned` changes (including when the window is hidden via `orderOut`).
    var onPinStateChanged: ((Bool) -> Void)?

    private weak var pinnedWindow: NSWindow?
    private weak var originalDelegate: (any NSWindowDelegate)?
    private var originalLevel: NSWindow.Level = .popUpMenu
    private var visibilityObservation: NSKeyValueObservation?

    /// Finds the active `FluidMenuBarExtra` popup window, never returning Settings or other windows.
    static func locatePopupWindow() -> NSWindow? {
        NSApp.windows.first { String(describing: type(of: $0)).contains("FluidMenuBarExtra") }
    }

    /// Toggles pin state on the active FluidMenuBarExtra popup window.
    @discardableResult
    func togglePin(window: NSWindow?) -> Bool {
        if isPinned {
            unpin()
        } else if let target = window ?? Self.locatePopupWindow() {
            pin(target)
        }
        return isPinned
    }

    func pin(_ window: NSWindow) {
        guard !isPinned else { return }
        // Only wrap if not already our own proxy
        if window.delegate !== self {
            originalDelegate = window.delegate
            originalLevel = window.level
            window.delegate = self
        }
        pinnedWindow = window
        isPinned = true
        window.level = .floating
        window.isMovableByWindowBackground = true
        if !window.collectionBehavior.contains(.canJoinAllSpaces) {
            window.collectionBehavior.insert(.moveToActiveSpace)
        }

        // FluidMenuBarExtra dismisses via `orderOut(nil)` (not `close()`), so `windowWillClose`
        // never fires when the user clicks the status-bar icon to hide a pinned popup. Observing
        // `isVisible` ensures `unpin()` runs automatically if the panel is hidden externally.
        visibilityObservation?.invalidate()
        visibilityObservation = window.observe(\.isVisible, options: [.old, .new]) { [weak self] _, change in
            guard change.oldValue == true, change.newValue == false else { return }
            MainActor.assumeIsolated {
                self?.unpin()
            }
        }
        onPinStateChanged?(true)
    }

    func unpin(dismiss: Bool = false) {
        guard isPinned else { return }
        isPinned = false
        visibilityObservation?.invalidate()
        visibilityObservation = nil
        if let window = pinnedWindow {
            window.isMovableByWindowBackground = false
            window.level = originalLevel
            if let originalDelegate {
                window.delegate = originalDelegate
            }
            if dismiss, window.isVisible {
                window.resignKey()
            }
        }
        pinnedWindow = nil
        originalDelegate = nil
        onPinStateChanged?(false)
    }

    // MARK: - NSWindowDelegate forwarding

    func windowDidBecomeKey(_ notification: Notification) {
        originalDelegate?.windowDidBecomeKey?(notification)
    }

    func windowDidResignKey(_ notification: Notification) {
        // Swallow resign-key dismissal while pinned so the panel stays floating on screen.
        if !isPinned {
            originalDelegate?.windowDidResignKey?(notification)
        }
    }

    func windowWillClose(_ notification: Notification) {
        unpin()
        originalDelegate?.windowWillClose?(notification)
    }

    func windowDidResize(_ notification: Notification) {
        originalDelegate?.windowDidResize?(notification)
    }

    func windowDidMove(_ notification: Notification) {
        originalDelegate?.windowDidMove?(notification)
    }
}
