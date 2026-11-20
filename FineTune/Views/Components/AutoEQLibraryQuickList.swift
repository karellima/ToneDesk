// FineTune/Views/Components/AutoEQLibraryQuickList.swift
import SwiftUI

/// "My Profiles": one-click list of the user's library inside the AutoEQ popover.
struct AutoEQLibraryQuickList: View {
    let profiles: [AutoEQProfile]
    let selectedProfileID: String?
    let isCorrectionEnabled: Bool
    let onSelect: (AutoEQProfile) -> Void

    @State private var hoveredID: String?

    private let rowHeight: CGFloat = 26
    private let maxVisibleRows = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("My Profiles")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(DesignTokens.Colors.textSecondary)
                .padding(.horizontal, DesignTokens.Spacing.sm)
                .padding(.top, DesignTokens.Spacing.sm)
                .padding(.bottom, DesignTokens.Spacing.xs)

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(profiles) { profile in
                        row(profile)
                    }
                }
            }
            .frame(height: CGFloat(min(profiles.count, maxVisibleRows)) * rowHeight)
            .scrollIndicators(profiles.count > maxVisibleRows ? .automatic : .never)
        }
        .padding(.bottom, DesignTokens.Spacing.xs)
        .background {
            RoundedRectangle(cornerRadius: 10)
                .fill(DesignTokens.Colors.recessedBackground)
        }
    }

    private func row(_ profile: AutoEQProfile) -> some View {
        let isActive = profile.id == selectedProfileID
        return Button {
            onSelect(profile)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .semibold))
                    .opacity(isActive ? 1 : 0)
                    .foregroundStyle(isCorrectionEnabled ? DesignTokens.Colors.accentPrimary : DesignTokens.Colors.textSecondary)
                    .frame(width: 12)
                Text(profile.name)
                    .font(.system(size: 12, weight: isActive ? .semibold : .regular))
                    .foregroundStyle(DesignTokens.Colors.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Text(String(format: "%.1f dB · %d", profile.preampDB, profile.filters.count))
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(DesignTokens.Colors.textSecondary)
                    .help("Preamp · number of filters")
            }
            .padding(.horizontal, DesignTokens.Spacing.sm)
            .frame(height: rowHeight)
            .contentShape(Rectangle())
            .background {
                if hoveredID == profile.id {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.primary.opacity(0.08))
                        .padding(.horizontal, DesignTokens.Spacing.xxs)
                }
            }
        }
        .buttonStyle(.plain)
        .onHover { hoveredID = $0 ? profile.id : (hoveredID == profile.id ? nil : hoveredID) }
    }
}
