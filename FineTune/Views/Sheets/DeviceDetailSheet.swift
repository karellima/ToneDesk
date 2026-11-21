// FineTune/Views/Sheets/DeviceDetailSheet.swift
import SwiftUI
import os

@MainActor
struct DeviceDetailSheet: View {
    let device: AudioDevice
    let transportType: TransportType
    let autoDetectedTier: VolumeControlTier
    let currentOverride: VolumeControlTier?
    let onOverrideChange: (VolumeControlTier?) -> Void
    let processing: DeviceAudioProcessingSettings
    let onProcessingChange: ((DeviceAudioProcessingSettings) -> Void)?
    let parametricEQ: DeviceParametricEQ
    let baseAutoEQ: AutoEQProfile?
    let onParametricEQChange: ((DeviceParametricEQ) -> Void)?
    let onSavePEQToLibrary: ((String, String) -> Void)?
    let onEditEQExpanded: (() -> Void)?
    let onDismiss: () -> Void

    @State private var viewModel: DeviceInspectorViewModel
    @State private var isEditingParametricEQ = false

    private static let logger = Logger(subsystem: "com.finetuneapp.FineTune", category: "DeviceDetailSheet")

    init(
        device: AudioDevice,
        transportType: TransportType,
        autoDetectedTier: VolumeControlTier,
        currentOverride: VolumeControlTier?,
        onOverrideChange: @escaping (VolumeControlTier?) -> Void,
        processing: DeviceAudioProcessingSettings = .default,
        onProcessingChange: ((DeviceAudioProcessingSettings) -> Void)? = nil,
        parametricEQ: DeviceParametricEQ = .default,
        baseAutoEQ: AutoEQProfile? = nil,
        onParametricEQChange: ((DeviceParametricEQ) -> Void)? = nil,
        onSavePEQToLibrary: ((String, String) -> Void)? = nil,
        onEditEQExpanded: (() -> Void)? = nil,
        onDismiss: @escaping () -> Void
    ) {
        self.device = device
        self.transportType = transportType
        self.autoDetectedTier = autoDetectedTier
        self.currentOverride = currentOverride
        self.onOverrideChange = onOverrideChange
        self.processing = processing
        self.onProcessingChange = onProcessingChange
        self.parametricEQ = parametricEQ
        self.baseAutoEQ = baseAutoEQ
        self.onParametricEQChange = onParametricEQChange
        self.onSavePEQToLibrary = onSavePEQToLibrary
        self.onEditEQExpanded = onEditEQExpanded
        self.onDismiss = onDismiss
        self._viewModel = State(
            initialValue: DeviceInspectorViewModel(
                deviceID: device.id,
                uid: device.uid,
                transportType: transportType
            )
        )
    }

    private var isBluetooth: Bool {
        transportType == .bluetooth || transportType == .bluetoothLE
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            DeviceInspectorInfoGrid(
                info: viewModel.info,
                onSampleRateSelected: { rate in
                    viewModel.selectSampleRate(rate)
                }
            )

            if let error = viewModel.sampleRateError {
                errorBanner(error)
            }

            if let hogLine = DeviceInspectorInfo.formatHogModeOwner(
                viewModel.info.hogModeOwner,
                processName: viewModel.hogModeOwnerName
            ) {
                separator
                hogModeRow(hogLine)
            }

            if onParametricEQChange != nil {
                separator
                parametricEQSection
            }

            if onProcessingChange != nil {
                separator
                stereoControlsSection
                separator
                maxVolumeLimitSection
                if isBluetooth {
                    separator
                    bluetoothOutputOnlySection
                }
            }

            if Self.shouldShowToggle(autoTier: autoDetectedTier) {
                separator
                softwareToggle
                calloutText
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background {
            RoundedRectangle(cornerRadius: 10)
                .fill(DesignTokens.Colors.recessedBackground)
        }
        .padding(.horizontal, 2)
        .padding(.top, DesignTokens.Spacing.xs)
        .padding(.bottom, DesignTokens.Spacing.xs)
        .onAppear { viewModel.start() }
        .onDisappear { viewModel.stop() }
    }

    // MARK: - Device Parametric EQ

    private var parametricEQSection: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            HStack(spacing: DesignTokens.Spacing.xs) {
                Image(systemName: "waveform.path.ecg.rectangle")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(parametricEQ.isEffectivelyActive ? DesignTokens.Colors.accentPrimary : DesignTokens.Colors.textSecondary)

                Text("Global Parametric EQ")
                    .font(DesignTokens.Typography.pickerText)
                    .foregroundStyle(DesignTokens.Colors.textPrimary)

                Spacer(minLength: 0)

                Button {
                    let willExpand = !isEditingParametricEQ
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
                        isEditingParametricEQ.toggle()
                    }
                    if willExpand {
                        onEditEQExpanded?()
                    }
                } label: {
                    Text(isEditingParametricEQ ? "Done" : "Edit EQ")
                        .font(DesignTokens.Typography.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(DesignTokens.Colors.accentPrimary)
                }
                .buttonStyle(.plain)

                Toggle("Global Parametric EQ", isOn: Binding(
                    get: { parametricEQ.isEnabled },
                    set: { enabled in
                        var updated = parametricEQ
                        updated.isEnabled = enabled
                        onParametricEQChange?(updated)
                    }
                ))
                .toggleStyle(.switch)
                .scaleEffect(0.8)
                .labelsHidden()
            }

            if isEditingParametricEQ {
                DeviceParametricEQEditorView(
                    deviceName: device.name,
                    baseAutoEQ: baseAutoEQ,
                    eq: parametricEQ,
                    sampleRate: viewModel.info.sampleRate > 0 ? viewModel.info.sampleRate : 48_000,
                    onChange: { updated in onParametricEQChange?(updated) },
                    onSaveToLibrary: onSavePEQToLibrary
                )
                .id("peq-editor-\(device.uid)")
            } else if parametricEQ.isEffectivelyActive || baseAutoEQ != nil {
                let curves = FrequencyResponseCurve.evaluateDeviceCurves(
                    baseAutoEQ: baseAutoEQ,
                    parametricEQ: parametricEQ,
                    sampleRate: viewModel.info.sampleRate > 0 ? viewModel.info.sampleRate : 48_000
                )
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
                        isEditingParametricEQ = true
                    }
                    onEditEQExpanded?()
                } label: {
                    FrequencyResponseGraphView(
                        primaryCurve: curves.combined,
                        secondaryCurve: curves.base,
                        height: 54,
                        showAxisLabels: false
                    )
                }
                .buttonStyle(.plain)
                .help("Open the interactive Parametric EQ editor")
                .accessibilityLabel("Edit Global Parametric EQ for \(device.name)")
            }
        }
    }

    // MARK: - Stereo Controls (Balance, Mono, Swap L/R)

    private var stereoControlsSection: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            BalanceSliderRow(
                balance: processing.balance,
                onChange: { newBalance in
                    var updated = processing
                    updated.balance = newBalance
                    onProcessingChange?(updated)
                },
                accessibilitySubject: "\(device.name) stereo balance"
            )

            // Mono + Swap L/R compact pill toggles
            HStack(spacing: DesignTokens.Spacing.xs) {
                pillToggle(
                    title: "Mono",
                    systemImage: "waveform.path.ecg",
                    isOn: processing.isMono
                ) {
                    var updated = processing
                    updated.isMono.toggle()
                    onProcessingChange?(updated)
                }

                pillToggle(
                    title: "Swap L⇄R",
                    systemImage: "arrow.left.arrow.right",
                    isOn: processing.swapChannels
                ) {
                    var updated = processing
                    updated.swapChannels.toggle()
                    onProcessingChange?(updated)
                }

                Spacer(minLength: 0)
            }
        }
    }

    private func pillToggle(
        title: String,
        systemImage: String,
        isOn: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(DesignTokens.Typography.eqLabel)
                Text(title)
                    .font(DesignTokens.Typography.caption)
                    .fontWeight(.medium)
            }
            .foregroundStyle(isOn ? Color.white : DesignTokens.Colors.textSecondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background {
                Capsule()
                    .fill(isOn ? DesignTokens.Colors.accentPrimary : DesignTokens.Colors.glassFillStrong)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    // MARK: - Max Volume Limit

    private var maxVolumeLimitSection: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            HStack(spacing: DesignTokens.Spacing.xs) {
                Image(systemName: "shield.lefthalf.filled")
                    .font(DesignTokens.Typography.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(processing.maxVolumeLimit != nil ? DesignTokens.Colors.accentPrimary : DesignTokens.Colors.textSecondary)

                Text("Max Volume Limit")
                    .font(DesignTokens.Typography.pickerText)
                    .foregroundStyle(DesignTokens.Colors.textPrimary)

                Spacer(minLength: 0)

                if let limit = processing.maxVolumeLimit {
                    Text("≤ \(Int(round(limit * 100)))%")
                        .font(DesignTokens.Typography.eqLabel)
                        .foregroundStyle(DesignTokens.Colors.accentPrimary)
                }

                Toggle("Max Volume Limit", isOn: Binding(
                    get: { processing.maxVolumeLimit != nil },
                    set: { enabled in
                        var updated = processing
                        updated.maxVolumeLimit = enabled ? (processing.maxVolumeLimit ?? 0.70) : nil
                        onProcessingChange?(updated)
                    }
                ))
                .toggleStyle(.switch)
                .scaleEffect(0.8)
                .labelsHidden()
            }

            if let limit = processing.maxVolumeLimit {
                Slider(
                    value: Binding(
                        get: { Double(limit) },
                        set: { newVal in
                            var updated = processing
                            updated.maxVolumeLimit = DeviceAudioProcessingSettings.clampedMaxVolumeLimit(Float(newVal))
                            onProcessingChange?(updated)
                        }
                    ),
                    in: Double(DeviceAudioProcessingSettings.maxVolumeLimitRange.lowerBound)...Double(DeviceAudioProcessingSettings.maxVolumeLimitRange.upperBound),
                    step: 0.05
                )
                .controlSize(.mini)
                .accessibilityLabel("Max Volume Limit")
                .accessibilityValue("\(Int(round(limit * 100))) percent")
            }
        }
    }

    // MARK: - Bluetooth Output-Only

    private var bluetoothOutputOnlySection: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: DesignTokens.Spacing.xs) {
                Image(systemName: "mic.slash.fill")
                    .font(DesignTokens.Typography.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(processing.bluetoothOutputOnly ? DesignTokens.Colors.accentPrimary : DesignTokens.Colors.textSecondary)

                Text("Output Only (Keep Music Quality)")
                    .font(DesignTokens.Typography.pickerText)
                    .foregroundStyle(DesignTokens.Colors.textPrimary)

                Spacer(minLength: 0)

                Toggle("Output Only (Keep Music Quality)", isOn: Binding(
                    get: { processing.bluetoothOutputOnly },
                    set: { enabled in
                        var updated = processing
                        updated.bluetoothOutputOnly = enabled
                        onProcessingChange?(updated)
                    }
                ))
                .toggleStyle(.switch)
                .scaleEffect(0.8)
                .labelsHidden()
            }

            Text("Blocks macOS from switching to this headset's mic (SCO/HFP), keeping high-quality A2DP audio.")
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    static func balanceLabel(_ balance: Float) -> String {
        BalanceSliderRow.label(for: balance)
    }

    // MARK: - Auto badge

    private var autoBadge: some View {
        Text("Auto: \(Self.tierDisplayName(autoDetectedTier))")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(DesignTokens.Colors.textSecondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule()
                    .fill(DesignTokens.Colors.glassFillStrong)
            )
            .accessibilityLabel("Auto-detected volume control: \(Self.tierDisplayName(autoDetectedTier))")
    }

    // MARK: - Separator

    private var separator: some View {
        Rectangle()
            .fill(DesignTokens.Colors.separator)
            .frame(height: 0.5)
    }

    // MARK: - Hog mode row

    private func hogModeRow(_ text: String) -> some View {
        HStack(spacing: DesignTokens.Spacing.xs) {
            Image(systemName: "lock.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(DesignTokens.Colors.textSecondary)
            Text(text)
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.Colors.textSecondary)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(text)
    }

    // MARK: - Error banner

    private func errorBanner(_ text: String) -> some View {
        HStack(spacing: DesignTokens.Spacing.xs) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(DesignTokens.Colors.mutedIndicator)
            Text(text)
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.Colors.textSecondary)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(text)
    }

    // MARK: - Software Toggle

    @ViewBuilder
    private var softwareToggle: some View {
        HStack(spacing: DesignTokens.Spacing.xs) {
            autoBadge

            Text("Use ToneDesk's software volume")
                .font(DesignTokens.Typography.pickerText)
                .foregroundStyle(DesignTokens.Colors.textPrimary)

            Spacer(minLength: DesignTokens.Spacing.sm)

            Toggle("Use ToneDesk's software volume", isOn: useSoftwareBinding)
                .toggleStyle(.switch)
                .scaleEffect(0.8)
                .labelsHidden()
        }
    }

    /// OFF writes `nil` (clears the pin, re-runs auto-detect); ON pins `.software`.
    private var useSoftwareBinding: Binding<Bool> {
        Binding(
            get: { currentOverride == .some(.software) },
            set: { newValue in
                Self.logger.debug("Toggle flipped: uid=\(device.uid, privacy: .public) useSoftware=\(newValue, privacy: .public)")
                onOverrideChange(newValue ? .some(.software) : nil)
            }
        )
    }

    // MARK: - Callout

    private var calloutText: some View {
        Text("Turn on only if the volume slider doesn't work. ToneDesk remembers this for each device.")
            .font(DesignTokens.Typography.caption)
            .foregroundStyle(DesignTokens.Colors.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Helpers

    static func tierDisplayName(_ tier: VolumeControlTier) -> String {
        switch tier {
        case .hardware: return "Hardware"
        case .ddc: return "DDC"
        case .software: return "Software"
        }
    }

    /// Hidden when auto-tier is already `.software` — no alternative backend to switch to.
    static func shouldShowToggle(autoTier: VolumeControlTier) -> Bool {
        autoTier != .software
    }
}
