// FineTune/Views/MenuBar/MenuBarIconImage+NSImage.swift
// AppKit bridge for MenuBarIconImage — kept separate so the value types
// file (MenuBarIconState.swift) stays AppKit-free and the Equatable
// conformances remain nonisolated under Swift 6 strict concurrency.

import AppKit

@MainActor
extension MenuBarIconImage {
    /// The status item is variable-length: icons of differing sizes resize it and shift every neighboring menu bar item.
    static let canvasSize = NSSize(width: 22, height: 18)

    func nsImage(accessibilityDescription: String = "ToneDesk") -> NSImage? {
        let source: NSImage?
        switch self {
        case .systemSymbol(let name):
            source = NSImage(systemSymbolName: name, accessibilityDescription: accessibilityDescription)
        case .asset(let name):
            source = NSImage(named: name)
        }
        guard let source else { return nil }

        let canvas = Self.canvasSize
        let scale = min(1, canvas.width / source.size.width, canvas.height / source.size.height)
        let drawRect = NSRect(
            x: (canvas.width - source.size.width * scale) / 2,
            y: (canvas.height - source.size.height * scale) / 2,
            width: source.size.width * scale,
            height: source.size.height * scale
        )
        let image = NSImage(size: canvas, flipped: false) { _ in
            source.draw(in: drawRect)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = accessibilityDescription
        return image
    }

    /// Fixed canvas width when the live VU level meter is rendered beside the icon.
    static let meterCanvasSize = NSSize(width: 32, height: 18)

    /// Renders the base menu bar icon alongside a crisp 2-bar live level meter.
    /// Stays a template image when silent/muted and switches to colored bars when audio plays.
    func nsImageWithMeter(level: Float, muted: Bool, accessibilityDescription: String = "ToneDesk") -> NSImage? {
        guard let baseIcon = nsImage(accessibilityDescription: accessibilityDescription) else { return nil }
        let clamped = muted || !level.isFinite ? 0.0 : max(0.0, min(1.0, Double(level)))
        let isActive = clamped > 0.02

        let canvas = Self.meterCanvasSize
        let image = NSImage(size: canvas, flipped: false) { _ in
            // Draw base icon on the left; when non-template (colored active meter), tint the
            // template glyph to `labelColor` via `.sourceIn` so it stays crisp in Dark & Light menu bars.
            let iconRect = NSRect(x: 0, y: 0, width: Self.canvasSize.width, height: Self.canvasSize.height)
            baseIcon.draw(in: iconRect)
            if isActive {
                NSColor.labelColor.setFill()
                iconRect.fill(using: .sourceIn)
            }

            // Draw two slim vertical meter bars on the right
            let barWidth: CGFloat = 3.0
            let barGap: CGFloat = 1.5
            let maxBarHeight: CGFloat = 13.0
            let barBottom: CGFloat = 2.5
            let startX: CGFloat = Self.canvasSize.width + 1.5

            // Slightly offset second bar for lively stereo feel
            let heights: [CGFloat] = [
                max(2.0, CGFloat(clamped) * maxBarHeight),
                max(2.0, CGFloat(min(1.0, clamped * 0.88)) * maxBarHeight)
            ]

            for (i, h) in heights.enumerated() {
                let x = startX + CGFloat(i) * (barWidth + barGap)
                // Track background
                let trackRect = NSRect(x: x, y: barBottom, width: barWidth, height: maxBarHeight)
                let trackPath = NSBezierPath(roundedRect: trackRect, xRadius: 1.0, yRadius: 1.0)
                NSColor.labelColor.withAlphaComponent(0.22).setFill()
                trackPath.fill()

                // Active level fill
                if isActive {
                    let fillRect = NSRect(x: x, y: barBottom, width: barWidth, height: h)
                    let fillPath = NSBezierPath(roundedRect: fillRect, xRadius: 1.0, yRadius: 1.0)
                    let fillColor: NSColor
                    if clamped > 0.85 {
                        fillColor = .systemRed
                    } else if clamped > 0.65 {
                        fillColor = .systemOrange
                    } else {
                        fillColor = .systemGreen
                    }
                    fillColor.setFill()
                    fillPath.fill()
                }
            }
            return true
        }
        image.isTemplate = !isActive
        image.accessibilityDescription = accessibilityDescription
        return image
    }
}
