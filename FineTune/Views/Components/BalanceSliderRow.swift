// FineTune/Views/Components/BalanceSliderRow.swift
import SwiftUI

/// Shared stereo L/R balance slider row used by both Device Inspector and per-app EQ panel.
struct BalanceSliderRow: View {
    let balance: Float
    let onChange: (Float) -> Void
    var labelWidth: CGFloat = 52
    var accessibilitySubject: String = "Stereo balance"

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.xs) {
            Text("Balance")
                .font(DesignTokens.Typography.pickerText)
                .foregroundStyle(DesignTokens.Colors.textSecondary)
                .frame(width: labelWidth, alignment: .leading)

            Text("L")
                .font(DesignTokens.Typography.eqLabel)
                .foregroundStyle(DesignTokens.Colors.textTertiary)
                .accessibilityHidden(true)

            Slider(
                value: Binding(
                    get: { Double(balance) },
                    set: { onChange(DeviceAudioProcessingSettings.clampedBalance(Float($0))) }
                ),
                in: -1.0...1.0
            )
            .controlSize(.mini)
            .accessibilityLabel(accessibilitySubject)
            .accessibilityValue(Self.label(for: balance))

            Text("R")
                .font(DesignTokens.Typography.eqLabel)
                .foregroundStyle(DesignTokens.Colors.textTertiary)
                .accessibilityHidden(true)

            Button {
                onChange(0.0)
            } label: {
                Text(Self.label(for: balance))
                    .font(DesignTokens.Typography.eqLabel)
                    .foregroundStyle(abs(balance) >= 0.02 ? DesignTokens.Colors.accentPrimary : DesignTokens.Colors.textSecondary)
                    .frame(width: 44, alignment: .trailing)
            }
            .buttonStyle(.plain)
            .help("Click to reset balance to center")
            .accessibilityLabel("Reset balance to center")
            .accessibilityValue(Self.label(for: balance))
        }
    }

    /// Human-readable balance readout ("Center", "L 30%", "R 15%").
    nonisolated static func label(for balance: Float) -> String {
        let pct = Int(round(abs(balance) * 100))
        if pct < 1 { return "Center" }
        return balance < 0 ? "L \(pct)%" : "R \(pct)%"
    }

    /// Compact pill badge text ("L30", "R15") or `nil` when centered.
    nonisolated static func compactBadge(for balance: Float) -> String? {
        let pct = Int(round(abs(balance) * 100))
        guard pct >= 1 else { return nil }
        return balance < 0 ? "L\(pct)" : "R\(pct)"
    }
}
