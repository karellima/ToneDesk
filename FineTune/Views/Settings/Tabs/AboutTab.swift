// FineTune/Views/Settings/Tabs/AboutTab.swift
import AppKit
import SwiftUI

@MainActor
struct AboutTab: View {
    private static let repoURL = URL(string: "https://github.com/karellima/ToneDesk")!
    private static let upstreamURL = URL(string: "https://github.com/ronitsingh10/FineTune")!

    private var versionShort: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
    }

    private var yearText: String {
        let startYear = 2026
        let currentYear = Calendar.current.component(.year, from: .now)
        return startYear == currentYear ? "\(startYear)" : "\(startYear)-\(currentYear)"
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage ?? NSImage())
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 96, height: 96)

                Text("ToneDesk")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(DesignTokens.Colors.textPrimary)

                Text("Version \(versionShort) (\(buildNumber))")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    AboutLinkChip(
                        label: "GitHub",
                        icon: "chevron.left.forwardslash.chevron.right",
                        hoverIcon: "chevron.left.forwardslash.chevron.right",
                        hoverColor: DesignTokens.Colors.accentPrimary,
                        url: Self.repoURL
                    )
                    AboutLinkChip(
                        label: "Based on FineTune",
                        icon: "arrow.triangle.branch",
                        hoverIcon: "arrow.triangle.branch",
                        hoverColor: Color(nsColor: .systemOrange),
                        url: Self.upstreamURL
                    )
                }
                .padding(.top, 4)
            }

            Spacer()

            footer
                .padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        Text("© \(yearText) Karel Cristian · Based on FineTune (GPL-3.0)")
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
    }
}
