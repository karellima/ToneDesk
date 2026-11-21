// FineTune/Views/DesignSystem/WindowFrontPresenter.swift
import AppKit

/// Brings FineTune's windows and file panels cleanly to the very front of all other apps.
///
/// FineTune runs as an `LSUIElement` menu-bar agent. Dismissing the menu-bar popup before
/// opening Settings lets macOS WindowServer asynchronously return focus to the previously
/// active app, leaving FineTune's window buried behind other windows. Keeping FineTune
/// active until the target window is key + `orderFrontRegardless()` prevents that race.
@MainActor
enum WindowFrontPresenter {
    /// Weak reference to the Settings `NSWindow`, registered by `WindowTitleBridge`.
    static weak var settingsWindow: NSWindow?

    /// Activates FineTune and raises `window` above every normal window on the active Space.
    static func bringToFront(_ window: NSWindow) {
        if !window.collectionBehavior.contains(.canJoinAllSpaces) {
            window.collectionBehavior.insert(.moveToActiveSpace)
        }
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)
    }

    /// Raises the Settings window to the front after SwiftUI opens/focuses it, then closes
    /// `popupWindow` (if different from Settings) so FineTune never drops to zero key windows
    /// mid-transition.
    static func bringSettingsToFront(dismissing popupWindow: NSWindow? = nil) {
        let popupToDismiss = popupWindow

        func apply() {
            guard let window = locateSettingsWindow() else { return }
            bringToFront(window)
            if let popupToDismiss, popupToDismiss !== window, popupToDismiss.isVisible {
                popupToDismiss.resignKey()
            }
        }

        // Next run-loop turn catches already-materialized and freshly created Settings windows.
        DispatchQueue.main.async {
            apply()
        }
        // Short follow-up wins any asynchronous WindowServer focus handoff triggered when a
        // FluidMenuBarExtra panel or status-item NSMenu finishes tearing down.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            guard let window = locateSettingsWindow(), window.isVisible else { return }
            if !NSApp.isActive || !window.isKeyWindow {
                bringToFront(window)
            }
        }
    }

    /// Presents an `NSOpenPanel`/`NSSavePanel` above all other windows (e.g. from the menu bar popup).
    static func bringPanelToFront(_ panel: NSSavePanel) {
        NSApp.activate(ignoringOtherApps: true)
        panel.orderFrontRegardless()
        panel.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            panel.orderFrontRegardless()
            panel.makeKeyAndOrderFront(nil)
        }
    }

    private static func locateSettingsWindow() -> NSWindow? {
        if let settingsWindow {
            return settingsWindow
        }
        return NSApp.windows.first { window in
            window.title == "ToneDesk Settings"
                || (window.identifier?.rawValue.localizedCaseInsensitiveContains("settings") ?? false)
        }
    }
}
