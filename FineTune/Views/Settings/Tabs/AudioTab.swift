// FineTune/Views/Settings/Tabs/AudioTab.swift
import SwiftUI

@MainActor
struct AudioTab: View {
    @Bindable var settings: SettingsManager
    @Bindable var audioEngine: AudioEngine
    @Bindable var deviceVolumeMonitor: DeviceVolumeMonitor

    /// Memoized sorted output devices for the system-sounds picker.
    @State private var sortedOutputDevices: [AudioDevice] = []
    @State private var newSceneName = ""
    @State private var newSceneIcon = "sparkles"
    @State private var renamingSceneID: UUID?
    @State private var renameSceneDraft = ""
    @State private var pendingDeleteScene: AudioScene?
    @State private var pendingOverwriteScene: AudioScene?

    private var unifiedLoudnessToggleBinding: Binding<Bool> {
        Binding(
            get: {
                settings.appSettings.loudnessCompensationEnabled
                    && settings.appSettings.loudnessEqualizationEnabled
            },
            set: { isEnabled in
                settings.appSettings.setUnifiedLoudnessEnabled(isEnabled)
            }
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                volumeSection
                devicesSection
                quickConfigsSection
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.never)
        .onAppear { updateSortedDevices() }
        .onChange(of: audioEngine.outputDevices) { _, _ in updateSortedDevices() }
        .onChange(of: settings.appSettings.lockInputDevice) { oldValue, newValue in
            if !oldValue && newValue {
                audioEngine.handleInputLockEnabled()
            }
        }
        .onChange(of: settings.appSettings.loudnessCompensationEnabled) { _, newValue in
            audioEngine.setLoudnessCompensationEnabled(newValue)
        }
        .onChange(of: settings.appSettings.loudnessEqualizationEnabled) { _, newValue in
            audioEngine.setLoudnessEqualizationEnabled(newValue)
        }
        .confirmationDialog(
            pendingDeleteScene.map { "Delete “\($0.name)”?" } ?? "Delete Quick Config?",
            isPresented: Binding(
                get: { pendingDeleteScene != nil },
                set: { if !$0 { pendingDeleteScene = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let scene = pendingDeleteScene {
                Button("Delete", role: .destructive) {
                    audioEngine.deleteQuickConfig(id: scene.id)
                    pendingDeleteScene = nil
                }
            }
            Button("Cancel", role: .cancel) { pendingDeleteScene = nil }
        } message: {
            Text("This Quick Config will be permanently removed.")
        }
        .confirmationDialog(
            pendingOverwriteScene.map { "Update “\($0.name)”?" } ?? "Update Quick Config?",
            isPresented: Binding(
                get: { pendingOverwriteScene != nil },
                set: { if !$0 { pendingOverwriteScene = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let scene = pendingOverwriteScene {
                Button("Overwrite") {
                    audioEngine.updateQuickConfig(id: scene.id)
                    pendingOverwriteScene = nil
                }
            }
            Button("Cancel", role: .cancel) { pendingOverwriteScene = nil }
        } message: {
            Text("This replaces the saved Quick Config with your current audio setup.")
        }
    }

    // MARK: - Volume

    private var volumeSection: some View {
        SettingsSection("Volume") {
            SettingsRow(
                "Default Volume",
                description: "Initial volume for new apps"
            ) {
                VolumeSlider(
                    $settings.appSettings.defaultNewAppVolume,
                    range: 0.1...1.0,
                    width: 280
                )
            }
            SettingsRowDivider()
            SettingsRow(
                "Loudness Compensation",
                description: "Boost low frequencies at low volume"
            ) {
                Toggle("Loudness Compensation", isOn: unifiedLoudnessToggleBinding)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
            }
        }
    }

    // MARK: - Devices

    private var devicesSection: some View {
        SettingsSection("Devices") {
            SettingsRow(
                "Lock Input Device",
                description: "Prevent auto-switching when devices connect"
            ) {
                Toggle("Lock Input Device", isOn: $settings.appSettings.lockInputDevice)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
            }
            SettingsRowDivider()
            SettingsRow(
                "System Sounds",
                description: "Where alerts and effects play"
            ) {
                SystemSoundsDevicePicker(
                    devices: sortedOutputDevices,
                    deviceIconOverrides: audioEngine.settingsManager.deviceIconOverrides,
                    selectedDeviceUID: deviceVolumeMonitor.systemDeviceUID,
                    defaultDeviceUID: deviceVolumeMonitor.defaultDeviceUID,
                    isFollowingDefault: deviceVolumeMonitor.isSystemFollowingDefault,
                    onDeviceSelected: { deviceUID in
                        if let device = sortedOutputDevices.first(where: { $0.uid == deviceUID }) {
                            deviceVolumeMonitor.setSystemDeviceExplicit(device.id)
                        }
                    },
                    onSelectFollowDefault: {
                        deviceVolumeMonitor.setSystemFollowDefault()
                    }
                )
            }
            SettingsRowDivider()
            SettingsRow(
                "Alert Volume",
                description: "Volume for alerts and notifications"
            ) {
                VolumeSlider(
                    Binding(
                        get: { deviceVolumeMonitor.alertVolume },
                        set: { deviceVolumeMonitor.setAlertVolume($0) }
                    ),
                    range: 0...1,
                    width: 280
                )
            }
            .task {
                // No CoreAudio listener for alert volume — must poll via AppleScript.
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(2))
                    deviceVolumeMonitor.refreshAlertVolume()
                }
            }
        }
    }

    // MARK: - Quick Configs

    private var quickConfigsSection: some View {
        SettingsSection("Quick Configs") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Save complete snapshots of your current output, input, volumes, AutoEQ profiles, stereo processing, and app routing.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    Picker("Quick Config icon", selection: $newSceneIcon) {
                        ForEach(AudioScene.availableIcons, id: \.self) { symbol in
                            Image(systemName: symbol).tag(symbol)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 56)

                    TextField("New Quick Config name (e.g. Music on DAC, Calls)", text: $newSceneName)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { saveNewScene() }

                    Button("Save Current") { saveNewScene() }
                        .disabled(newSceneName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .controlSize(.small)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            let scenes = audioEngine.quickConfigs
            if !scenes.isEmpty {
                ForEach(scenes) { scene in
                    SettingsRowDivider()
                    quickConfigRow(scene)
                }
            }
        }
    }

    @ViewBuilder
    private func quickConfigRow(_ scene: AudioScene) -> some View {
        let isActive = audioEngine.activeQuickConfigID == scene.id
        HStack(spacing: 8) {
            Image(systemName: scene.icon)
                .font(.system(size: 12))
                .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
                .frame(width: 18)

            if renamingSceneID == scene.id {
                TextField("Name", text: $renameSceneDraft)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .onSubmit {
                        audioEngine.renameQuickConfig(id: scene.id, to: renameSceneDraft)
                        renamingSceneID = nil
                    }
                    .onExitCommand { renamingSceneID = nil }
            } else {
                Text(scene.name)
                    .font(.system(size: 12, weight: isActive ? .semibold : .regular))
                    .lineLimit(1)
                    .onTapGesture(count: 2) {
                        renameSceneDraft = scene.name
                        renamingSceneID = scene.id
                    }
            }

            if isActive {
                Text("Last applied")
                    .font(DesignTokens.Typography.caption)
                    .fontWeight(.semibold)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.accentColor.opacity(0.2)))
            }

            Spacer()

            HStack(spacing: 6) {
                Button("Apply") {
                    audioEngine.applyQuickConfig(id: scene.id)
                }

                Button("Update") {
                    pendingOverwriteScene = scene
                }
                .help("Overwrite this Quick Config with your current audio setup")
                .accessibilityLabel("Update \(scene.name)")

                Button {
                    renameSceneDraft = scene.name
                    renamingSceneID = scene.id
                } label: {
                    Image(systemName: "pencil")
                }
                .help("Rename Quick Config")
                .accessibilityLabel("Rename \(scene.name)")

                Button(role: .destructive) {
                    pendingDeleteScene = scene
                } label: {
                    Image(systemName: "trash")
                }
                .help("Delete Quick Config")
                .accessibilityLabel("Delete \(scene.name)")
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func saveNewScene() {
        let trimmed = newSceneName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        audioEngine.saveQuickConfig(name: trimmed, icon: newSceneIcon)
        newSceneName = ""
    }

    private func updateSortedDevices() {
        sortedOutputDevices = audioEngine.prioritySortedOutputDevices
    }
}
