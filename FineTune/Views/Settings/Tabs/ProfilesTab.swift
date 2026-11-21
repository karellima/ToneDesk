// FineTune/Views/Settings/Tabs/ProfilesTab.swift
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Settings › Profiles: the user's library of imported ParametricEQ profiles.
/// Import (files, folders, drag & drop), rename, duplicate, delete, favorite, reorder,
/// filter preview, A/B setup and backup.
@MainActor
struct ProfilesTab: View {
    @Bindable var settings: SettingsManager
    @Bindable var audioEngine: AudioEngine

    @State private var expandedIDs: Set<String> = []
    @State private var editingID: String?
    @State private var draftName = ""
    @State private var pendingDelete: AutoEQProfile?
    @State private var statusMessage: String?
    @State private var statusIsError = false
    @State private var isDropTargeted = false
    @AppStorage("abGraphMode") private var graphModeRaw: String = FrequencyResponseGraphView.Mode.overlay.rawValue

    private var graphMode: FrequencyResponseGraphView.Mode {
        FrequencyResponseGraphView.Mode(rawValue: graphModeRaw) ?? .overlay
    }

    private var graphModeBinding: Binding<FrequencyResponseGraphView.Mode> {
        Binding(
            get: { graphMode },
            set: { graphModeRaw = $0.rawValue }
        )
    }

    private var library: AutoEQLibrary { audioEngine.autoEQLibrary }

    private var activeOutputSampleRate: Double {
        guard let uid = audioEngine.autoEQTargetDeviceUID,
              let dev = audioEngine.deviceMonitor.device(for: uid),
              let rate = try? dev.id.readNominalSampleRate(),
              rate > 0 else { return 48_000 }
        return rate
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            toolbar
            abSection
            listSection
            footer
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .dropDestination(for: URL.self) { urls, _ in
            importURLs(urls)
            return true
        } isTargeted: { isDropTargeted = $0 }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6]))
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
        .confirmationDialog(
            "Delete “\(pendingDelete?.name ?? "")”?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let profile = pendingDelete { audioEngine.deleteLibraryProfile(id: profile.id) }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("The profile is removed from the library and from any device using it. Export a backup first if you may need it again.")
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Profile Library")
                    .font(.system(size: 15, weight: .semibold))
                Text(activeLine)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Import…", systemImage: "square.and.arrow.down") { presentImportPanel() }
                .help("Import ParametricEQ.txt files or whole folders")
            Menu {
                Button("Export Backup…") { presentExportPanel() }
                Button("Restore Backup…") { presentRestorePanel() }
            } label: {
                Label("Backup", systemImage: "archivebox")
            }
            .fixedSize()
        }
        .controlSize(.small)
    }

    private var activeLine: String {
        let device = audioEngine.autoEQTargetDeviceName ?? "no output device"
        if let active = audioEngine.activeAutoEQProfile, audioEngine.isActiveAutoEQEnabled {
            return "Active on \(device): \(active.name)"
        }
        return "Active on \(device): no correction"
    }

    // MARK: - A/B

    private var abSection: some View {
        let ab = audioEngine.autoEQAB
        let activeSlot = audioEngine.activeAutoEQABSlot
        let trims = ab.levelMatch ? audioEngine.autoEQABTrims : nil
        let profA = ab.profileA.flatMap { audioEngine.autoEQProfileManager.profile(for: $0) }
        let profB = ab.profileB.flatMap { audioEngine.autoEQProfileManager.profile(for: $0) }

        return SettingsSection("A/B Comparison") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    ABSlotCard(
                        slot: .a,
                        profile: profA,
                        profiles: library.profiles,
                        isPlaying: activeSlot == .a,
                        isConfigured: ab.isConfigured,
                        levelTrimDB: trims?.a,
                        onActivate: { activateABSlot(.a, ab: ab) },
                        onSelectProfile: { audioEngine.setAutoEQABProfile($0, slot: .a) }
                    )
                    ABSlotCard(
                        slot: .b,
                        profile: profB,
                        profiles: library.profiles,
                        isPlaying: activeSlot == .b,
                        isConfigured: ab.isConfigured,
                        levelTrimDB: trims?.b,
                        onActivate: { activateABSlot(.b, ab: ab) },
                        onSelectProfile: { audioEngine.setAutoEQABProfile($0, slot: .b) }
                    )
                }

                HStack(spacing: 10) {
                    Picker("Graph Mode", selection: graphModeBinding) {
                        Text("Overlay").tag(FrequencyResponseGraphView.Mode.overlay)
                        Text("Difference").tag(FrequencyResponseGraphView.Mode.difference)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()

                    Text("Click a side to listen. Your A/B shortcut also switches.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)

                    Spacer(minLength: 8)

                    Toggle("Level-match", isOn: Binding(
                        get: { ab.levelMatch },
                        set: { audioEngine.setAutoEQABLevelMatch($0) }
                    ))
                    .toggleStyle(.checkbox)
                    .help("Attenuates the louder profile (approximate LUFS, K-weighted pink noise) so you compare sound, not volume")
                }
                .controlSize(.small)

                if ab.isConfigured, let profA, let profB {
                    let curveA = FrequencyResponseCurve.evaluate(profile: profA, sampleRate: activeOutputSampleRate)
                    let curveB = FrequencyResponseCurve.evaluate(profile: profB, sampleRate: activeOutputSampleRate)
                    let peak = max(
                        curveA.map { abs($0.magnitudeDB) }.max() ?? 0,
                        curveB.map { abs($0.magnitudeDB) }.max() ?? 0
                    )
                    let maxDB: Double = peak <= 6 ? 7.5 : 18.0
                    let highlight: FrequencyResponseGraphView.Highlight? = switch activeSlot {
                    case .a: .primary
                    case .b: .secondary
                    case nil: nil
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        abGraphLegend(activeSlot: activeSlot)
                        FrequencyResponseGraphView(
                            primaryCurve: curveA,
                            secondaryCurve: curveB,
                            maxDB: maxDB,
                            height: 110,
                            highlight: highlight,
                            mode: graphMode,
                            showsLegend: false
                        )
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }

    private func activateABSlot(_ slot: AutoEQABSettings.Slot, ab: AutoEQABSettings) {
        guard ab.isConfigured else { return }
        guard audioEngine.activeAutoEQABSlot != slot else { return }
        if audioEngine.activeAutoEQABSlot == nil && slot == .b {
            audioEngine.selectAutoEQProfileForActiveDevice(ab.profileB)
        } else {
            audioEngine.toggleAutoEQAB()
        }
    }

    @ViewBuilder
    private func abGraphLegend(activeSlot: AutoEQABSettings.Slot?) -> some View {
        HStack(spacing: 14) {
            if graphMode == .overlay {
                HStack(spacing: 5) {
                    CurveSwatch(color: DesignTokens.Colors.accentPrimary, dashed: false, width: 12, lineWidth: 2)
                    Text("A")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.secondary)
                    if activeSlot == .a {
                        playingLegendDot
                    }
                }
                HStack(spacing: 5) {
                    CurveSwatch(color: Color(nsColor: .systemOrange), dashed: true, width: 12, lineWidth: 2)
                    Text("B")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.secondary)
                    if activeSlot == .b {
                        playingLegendDot
                    }
                }
            } else {
                Text("B − A")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color(nsColor: .systemOrange).opacity(0.6))
                        .frame(width: 8, height: 8)
                    Text("B louder")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(DesignTokens.Colors.accentPrimary.opacity(0.6))
                        .frame(width: 8, height: 8)
                    Text("A louder")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
    }

    private var playingLegendDot: some View {
        HStack(spacing: 3) {
            Circle()
                .fill(Color(nsColor: .systemGreen))
                .frame(width: 5, height: 5)
            Text("playing")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Color(nsColor: .systemGreen))
        }
    }

    // MARK: - List

    private var listSection: some View {
        Group {
            if library.profiles.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(library.profiles) { profile in
                        row(profile)
                    }
                    .onMove { library.move(fromOffsets: $0, toOffset: $1) }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text("Drop ParametricEQ.txt files or a folder here")
                .font(.system(size: 13, weight: .medium))
            Text("or use Import… — REW and Equalizer APO exports are supported")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .quaternaryLabelColor).opacity(0.15)))
    }

    @ViewBuilder
    private func row(_ profile: AutoEQProfile) -> some View {
        let isFavorite = settings.isAutoEQFavorite(id: profile.id)
        let isActive = audioEngine.isActiveAutoEQEnabled && audioEngine.activeAutoEQProfile?.id == profile.id
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Button {
                    if isFavorite {
                        settings.unfavoriteAutoEQProfile(id: profile.id)
                    } else {
                        settings.favoriteAutoEQProfile(id: profile.id)
                    }
                } label: {
                    Image(systemName: isFavorite ? "star.fill" : "star")
                        .foregroundStyle(isFavorite ? Color.yellow : Color.secondary)
                }
                .buttonStyle(.plain)
                .help(isFavorite ? "Remove from favorites" : "Add to favorites")
                .accessibilityLabel(isFavorite ? "Remove \(profile.name) from favorites" : "Add \(profile.name) to favorites")

                if editingID == profile.id {
                    TextField("Name", text: $draftName)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { commitRename(profile.id) }
                        .onExitCommand { editingID = nil }
                } else {
                    Text(profile.name)
                        .font(.system(size: 12, weight: isActive ? .semibold : .regular))
                        .lineLimit(1)
                        .onTapGesture(count: 2) { beginRename(profile) }
                }

                abBadge(for: profile.id)
                if isActive {
                    Text("Active")
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Capsule().fill(Color.accentColor.opacity(0.2)))
                }
                Spacer()
                Text(AutoEQStatusMenu.summary(profile))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
                Button {
                    if expandedIDs.contains(profile.id) {
                        expandedIDs.remove(profile.id)
                    } else {
                        expandedIDs.insert(profile.id)
                    }
                } label: {
                    Image(systemName: expandedIDs.contains(profile.id) ? "chevron.up" : "chevron.down")
                }
                .buttonStyle(.plain)
                .help("Show filters")
                .accessibilityLabel(expandedIDs.contains(profile.id) ? "Hide filters for \(profile.name)" : "Show filters for \(profile.name)")
            }
            if expandedIDs.contains(profile.id) {
                filterTable(profile)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Apply to \(audioEngine.autoEQTargetDeviceName ?? "Output")") {
                audioEngine.selectAutoEQProfileForActiveDevice(profile.id)
            }
            Divider()
            Button("Set as A") { audioEngine.setAutoEQABProfile(profile.id, slot: .a) }
            Button("Set as B") { audioEngine.setAutoEQABProfile(profile.id, slot: .b) }
            Divider()
            Button("Rename") { beginRename(profile) }
            Button("Duplicate") { library.duplicate(id: profile.id) }
            Divider()
            Button("Delete…", role: .destructive) { pendingDelete = profile }
        }
    }

    @ViewBuilder
    private func abBadge(for id: String) -> some View {
        let ab = audioEngine.autoEQAB
        if id == ab.profileA || id == ab.profileB {
            Text(id == ab.profileA ? "A" : "B")
                .font(.system(size: 10, weight: .bold))
                .frame(width: 16, height: 16)
                .background(Circle().fill(Color.secondary.opacity(0.25)))
        }
    }

    private func filterTable(_ profile: AutoEQProfile) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            FrequencyResponseGraphView(
                primaryCurve: FrequencyResponseCurve.evaluate(profile: profile, sampleRate: activeOutputSampleRate),
                height: 88
            )
            .padding(.top, 2)

            VStack(alignment: .leading, spacing: 1) {
                Text(String(format: "Preamp %.1f dB", profile.preampDB))
                ForEach(Array(profile.filters.enumerated()), id: \.offset) { index, filter in
                    Text(Self.describe(filter, index: index + 1))
                }
            }
            .font(.system(size: 11).monospaced())
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
        }
        .padding(.leading, 28)
    }

    static func describe(_ filter: AutoEQFilter, index: Int) -> String {
        let type: String
        switch filter.type {
        case .peaking: type = "PK "
        case .lowShelf: type = "LSC"
        case .highShelf: type = "HSC"
        }
        return String(format: "%2d  %@  %7.1f Hz  %+6.1f dB  Q %.2f",
                      index, type, filter.frequency, filter.gainDB, filter.q)
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let statusMessage {
                Text(statusMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(statusIsError ? Color.red : Color.secondary)
                    .textSelection(.enabled)
                    .lineLimit(4)
            }
            Text("Drag to reorder · double-click to rename · right-click for more. Assignments are also remembered by device name, so moving a USB device to another port keeps its profile.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Actions

    private func beginRename(_ profile: AutoEQProfile) {
        draftName = profile.name
        editingID = profile.id
    }

    private func commitRename(_ id: String) {
        if !audioEngine.renameLibraryProfile(id: id, to: draftName) {
            show("Name cannot be empty.", error: true)
        }
        editingID = nil
    }

    private func importURLs(_ urls: [URL]) {
        let summary = audioEngine.importIntoLibrary(urls)
        var lines = [summary.message]
        lines += summary.failures.prefix(3).map { "\($0.fileName): \($0.message)" }
        show(lines.joined(separator: "\n"), error: summary.imported.isEmpty && !summary.failures.isEmpty)
    }

    private func show(_ message: String, error: Bool) {
        statusMessage = message
        statusIsError = error
    }

    private func presentImportPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.plainText, .folder]
        panel.message = "Choose ParametricEQ.txt files or folders"
        panel.prompt = "Import"
        presentPanel(panel) { urls in
            guard !urls.isEmpty else { return }
            importURLs(urls)
        }
    }

    private func presentExportPanel() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.zip]
        let date = Date().formatted(.iso8601.year().month().day())
        panel.nameFieldStringValue = "ToneDesk Profiles \(date).zip"
        presentSavePanel(panel) { url in
            let count = library.profiles.count
            Task { @MainActor in
                do {
                    try await audioEngine.exportLibraryBackup(to: url)
                    show("Exported \(count) profiles to \(url.lastPathComponent)", error: false)
                } catch {
                    show("Export failed: \(error.localizedDescription)", error: true)
                }
            }
        }
    }

    private func presentRestorePanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.allowedContentTypes = [.zip, .folder]
        panel.message = "Choose a ToneDesk profile backup (.zip or folder)"
        panel.prompt = "Restore"
        presentPanel(panel) { urls in
            guard let url = urls.first else { return }
            Task { @MainActor in
                do {
                    let summary = try await audioEngine.importLibraryBackup(from: url)
                    show("Restore: " + summary.message, error: false)
                } catch {
                    show("Restore failed: \(error.localizedDescription)", error: true)
                }
            }
        }
    }

    private var settingsSheetHostWindow: NSWindow? {
        WindowFrontPresenter.settingsWindow
            ?? NSApp.windows.first(where: { $0.title == "ToneDesk Settings" && $0.isVisible })
    }

    private func presentPanel(_ panel: NSOpenPanel, onConfirm: @escaping ([URL]) -> Void) {
        if let host = settingsSheetHostWindow {
            WindowFrontPresenter.bringToFront(host)
            panel.beginSheetModal(for: host) { response in
                guard response == .OK else { return }
                onConfirm(panel.urls)
            }
        } else {
            WindowFrontPresenter.bringPanelToFront(panel)
            guard panel.runModal() == .OK else { return }
            onConfirm(panel.urls)
        }
    }

    private func presentSavePanel(_ panel: NSSavePanel, onConfirm: @escaping (URL) -> Void) {
        if let host = settingsSheetHostWindow {
            WindowFrontPresenter.bringToFront(host)
            panel.beginSheetModal(for: host) { response in
                guard response == .OK, let url = panel.url else { return }
                onConfirm(url)
            }
        } else {
            WindowFrontPresenter.bringPanelToFront(panel)
            guard panel.runModal() == .OK, let url = panel.url else { return }
            onConfirm(url)
        }
    }
}

// MARK: - A/B Slot Card

private struct ABSlotCard: View {
    let slot: AutoEQABSettings.Slot
    let profile: AutoEQProfile?
    let profiles: [AutoEQProfile]
    let isPlaying: Bool
    let isConfigured: Bool
    let levelTrimDB: Float?
    let onActivate: () -> Void
    let onSelectProfile: (String?) -> Void

    @State private var isHovered = false

    private var letter: String { slot == .a ? "A" : "B" }
    private var swatchColor: Color { slot == .a ? DesignTokens.Colors.accentPrimary : Color(nsColor: .systemOrange) }
    private var isDashed: Bool { slot == .b }
    private var green: Color { Color(nsColor: .systemGreen) }

    private var metadataLine: String {
        guard let profile else { return "Not assigned" }
        var parts: [String] = []
        if let levelTrimDB {
            parts.append(String(format: "Level %.1f dB", levelTrimDB))
        }
        parts.append(String(format: "Preamp %.1f dB", profile.preampDB))
        parts.append("\(profile.filters.count) \(profile.filters.count == 1 ? "filter" : "filters")")
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(letter)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.primary)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(Color.primary.opacity(0.12)))

                CurveSwatch(color: swatchColor, dashed: isDashed, width: 14, lineWidth: 2)

                if isPlaying {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(green)
                            .frame(width: 6, height: 6)
                            .shadow(color: green, radius: 3)
                        Text("Playing")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(green)
                    }
                }

                Spacer(minLength: 4)

                Menu {
                    Button("—") { onSelectProfile(nil) }
                    if !profiles.isEmpty {
                        Divider()
                    }
                    ForEach(profiles) { candidate in
                        Button {
                            onSelectProfile(candidate.id)
                        } label: {
                            if candidate.id == profile?.id {
                                Label(candidate.name, systemImage: "checkmark")
                            } else {
                                Text(candidate.name)
                            }
                        }
                    }
                } label: {
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 20)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(Color.primary.opacity(0.06))
                        )
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Choose profile for Slot \(letter)")
                .accessibilityLabel("Choose profile for Slot \(letter)")
            }

            Text(profile?.name ?? "Select profile…")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(profile == nil ? .secondary : .primary)
                .lineLimit(2)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(metadataLine)
                .font(.system(size: 10.5).monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(isPlaying ? green.opacity(0.06) : Color.primary.opacity(isHovered && isConfigured ? 0.06 : 0.04))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(
                    isPlaying ? green.opacity(0.85) : Color.primary.opacity(0.08),
                    lineWidth: 1
                )
        }
        .overlay {
            if isPlaying {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .stroke(green.opacity(0.16), lineWidth: 3)
                    .padding(-1.5)
                    .allowsHitTesting(false)
            }
        }
        .shadow(color: isPlaying ? green.opacity(0.22) : .clear, radius: 9)
        .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .onTapGesture {
            guard isConfigured else { return }
            onActivate()
        }
        .onHover { isHovered = $0 }
        .opacity(isConfigured ? 1.0 : 0.72)
        .animation(.easeOut(duration: 0.2), value: isPlaying)
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Slot \(letter), \(profile?.name ?? "None")")
        .accessibilityValue(isPlaying ? "Playing" : "")
        .accessibilityAddTraits(.isButton)
    }
}
