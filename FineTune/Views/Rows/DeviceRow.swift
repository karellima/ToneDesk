// FineTune/Views/Rows/DeviceRow.swift
import SwiftUI

/// A row displaying a device with volume controls.
/// Used in the Output Devices section.
///
/// Volume mapping depends on the device's `volumeBackend`:
/// - **Hardware**: Identity mapping (slider == HAL scalar). CoreAudio's VirtualMainVolume
///   scalar is already audio-tapered by the driver — IOAudioLevelControl applies a dB curve
///   by default (see `setLinearScale()` in IOAudioLevelControl.h). Empirically confirmed:
///   scalar 0.50 → −50 dB, scalar 0.10 → −90 dB (100 dB range, linear-in-dB).
/// - **DDC**: Identity mapping (slider == DDC 0–100 / 100). DDC writes VCP 0x62 (Audio
///   Speaker Volume) as an integer 0–100 directly to the monitor via I2C, bypassing the HAL
///   entirely. The monitor's firmware handles perceptual mapping internally. Identity matches
///   the OSD values users see on the physical display. MonitorControl uses the same approach.
/// - **Software**: VolumeMapping x² curve. Software gain is a linear PCM amplitude multiplier
///   that needs perceptual scaling (dr-lex.be, Discord perceptual).
///
/// See: IOAudioLevelControl.h, MCCS VCP 0x62, empirical ScalarToDecibels measurement.
struct DeviceRow: View {
    let device: AudioDevice
    let isDefault: Bool
    let volume: Float
    let isMuted: Bool
    /// The device's volume backend. Determines which slider ↔ value mapping to use.
    let volumeBackend: VolumeControlTier
    let onSetDefault: () -> Void
    let onVolumeChange: (Float) -> Void
    let onMuteToggle: () -> Void

    // AutoEQ (all optional — existing call sites work without them)
    let autoEQProfileName: String?
    let autoEQEnabled: Bool
    let onAutoEQToggle: ((Bool) -> Void)?
    let autoEQProfileManager: AutoEQProfileManager?
    let autoEQSelection: AutoEQSelection?
    let autoEQFavoriteIDs: Set<String>
    let onAutoEQSelect: ((AutoEQProfile?) -> Void)?
    let onAutoEQImport: (() -> Void)?
    let onAutoEQToggleFavorite: ((String) -> Void)?
    let autoEQImportError: String?
    let autoEQPreampEnabled: Bool
    let onAutoEQPreampToggle: (() -> Void)?
    /// User library profiles for one-click switching in the AutoEQ popover.
    let autoEQLibraryProfiles: [AutoEQProfile]
    let processing: DeviceAudioProcessingSettings
    let isParametricEQActive: Bool
    let isInspectorExpanded: Bool
    let onToggleInspector: (() -> Void)?
    let inspectorContent: (() -> AnyView)?
    let isFocused: Bool
    let iconOverrideSymbol: String?

    @State private var sliderValue: Double
    @State private var isEditing = false
    @State private var isInfoHovered = false
    @State private var suppressSliderAutoUnmute = false
    /// Suppresses write-back when slider is being synced from a device volume change.
    /// Breaks the quantization feedback loop on USB DACs with discrete dB steps.
    @State private var isUpdatingSliderFromDevice = false

    /// The displayed percentage value, matching EditablePercentage's formula.
    /// Used for icon and unmute logic so visual state stays consistent with the label.
    private var displayedPercentage: Int { Int(round(sliderValue * 100)) }

    /// Show muted icon when system muted OR displayed volume is 0%.
    /// Uses percentage threshold (not exact sliderValue == 0) because SwiftUI Slider
    /// and volume clamping can leave sliderValue at tiny non-zero values (e.g. 0.003)
    /// that display as "0%" but fail exact Double equality.
    private var showMutedIcon: Bool { isMuted || displayedPercentage == 0 }

    /// Default slider position to restore when unmuting from 0 (50%)
    private let defaultUnmuteVolume: Double = 0.5

    private var displayIcon: NSImage? {
        DeviceIconResolver.displayIcon(
            overrideSymbol: iconOverrideSymbol,
            automatic: device.icon,
            deviceName: device.name
        )
    }

    init(
        device: AudioDevice,
        isDefault: Bool,
        volume: Float,
        isMuted: Bool,
        volumeBackend: VolumeControlTier = .hardware,
        onSetDefault: @escaping () -> Void,
        onVolumeChange: @escaping (Float) -> Void,
        onMuteToggle: @escaping () -> Void,
        autoEQProfileName: String? = nil,
        autoEQEnabled: Bool = false,
        onAutoEQToggle: ((Bool) -> Void)? = nil,
        autoEQProfileManager: AutoEQProfileManager? = nil,
        autoEQSelection: AutoEQSelection? = nil,
        autoEQFavoriteIDs: Set<String> = [],
        onAutoEQSelect: ((AutoEQProfile?) -> Void)? = nil,
        onAutoEQImport: (() -> Void)? = nil,
        onAutoEQToggleFavorite: ((String) -> Void)? = nil,
        autoEQImportError: String? = nil,
        autoEQPreampEnabled: Bool = true,
        onAutoEQPreampToggle: (() -> Void)? = nil,
        autoEQLibraryProfiles: [AutoEQProfile] = [],
        processing: DeviceAudioProcessingSettings = .default,
        isParametricEQActive: Bool = false,
        isInspectorExpanded: Bool = false,
        onToggleInspector: (() -> Void)? = nil,
        inspectorContent: (() -> AnyView)? = nil,
        isFocused: Bool = false,
        iconOverrideSymbol: String? = nil
    ) {
        self.device = device
        self.isDefault = isDefault
        self.volume = volume
        self.isMuted = isMuted
        self.volumeBackend = volumeBackend
        self.onSetDefault = onSetDefault
        self.onVolumeChange = onVolumeChange
        self.onMuteToggle = onMuteToggle
        self.autoEQProfileName = autoEQProfileName
        self.autoEQEnabled = autoEQEnabled
        self.onAutoEQToggle = onAutoEQToggle
        self.autoEQProfileManager = autoEQProfileManager
        self.autoEQSelection = autoEQSelection
        self.autoEQFavoriteIDs = autoEQFavoriteIDs
        self.onAutoEQSelect = onAutoEQSelect
        self.onAutoEQImport = onAutoEQImport
        self.onAutoEQToggleFavorite = onAutoEQToggleFavorite
        self.autoEQImportError = autoEQImportError
        self.autoEQPreampEnabled = autoEQPreampEnabled
        self.onAutoEQPreampToggle = onAutoEQPreampToggle
        self.autoEQLibraryProfiles = autoEQLibraryProfiles
        self.processing = processing
        self.isParametricEQActive = isParametricEQActive
        self.isInspectorExpanded = isInspectorExpanded
        self.onToggleInspector = onToggleInspector
        self.inspectorContent = inspectorContent
        self.isFocused = isFocused
        self.iconOverrideSymbol = iconOverrideSymbol
        self._sliderValue = State(initialValue: Self.volumeToSlider(volume, backend: volumeBackend))
    }

    var body: some View {
        if onToggleInspector != nil {
            ExpandableGlassRow(isExpanded: isInspectorExpanded, isFocused: isFocused) {
                deviceHeader
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if !isDefault { onSetDefault() }
                    }
            } expandedContent: {
                if isInspectorExpanded, let inspectorContent {
                    inspectorContent()
                }
            }
        } else {
            deviceHeader
                .contentShape(Rectangle())
                .onTapGesture {
                    if !isDefault { onSetDefault() }
                }
                .hoverableRow(isFocused: isFocused)
        }
    }

    // MARK: - Device Header

    private var deviceHeader: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            // Tinted badge replaces the prior leading RadioButton.
            // Selection is now signalled by accent-colored gradient on the
            // badge plus bold device name; the row-level gesture in `body`
            // handles tap-to-set-default.
            DeviceBadge(icon: displayIcon, isSelected: isDefault)

            // Device name + optional AutoEQ profile subtitle / active badges + AutoEQ picker
            HStack(spacing: DesignTokens.Spacing.xs) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(device.name)
                        .font(DesignTokens.Typography.rowName)
                        .lineLimit(1)
                        .help(device.name)

                    let subtitle = Self.autoEQSubtitle(profileName: autoEQProfileName, isEnabled: autoEQEnabled)
                    let badges = (isParametricEQActive ? ["PEQ"] : []) + processing.activeBadges
                    if subtitle != nil || !badges.isEmpty {
                        if let subtitle, badges.count <= 1 {
                            HStack(spacing: 4) {
                                Text(subtitle)
                                    .font(DesignTokens.Typography.cardSource)
                                    .foregroundStyle(DesignTokens.Colors.textTertiary)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                ForEach(badges, id: \.self) { badge in
                                    badgePill(badge)
                                }
                            }
                        } else {
                            if let subtitle {
                                Text(subtitle)
                                    .font(DesignTokens.Typography.cardSource)
                                    .foregroundStyle(DesignTokens.Colors.textTertiary)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            }
                            if !badges.isEmpty {
                                BadgeFlowLayout(horizontalSpacing: 4, verticalSpacing: 2) {
                                    ForEach(badges, id: \.self) { badge in
                                        badgePill(badge)
                                    }
                                }
                                .padding(.top, subtitle != nil ? 1 : 0)
                            }
                        }
                    }
                }

                Spacer(minLength: 0)

                // AutoEQ picker inside the name area so slider length stays consistent
                if device.supportsAutoEQ,
                   let profileManager = autoEQProfileManager,
                   let onSelect = onAutoEQSelect,
                   let onImport = onAutoEQImport {
                    AutoEQPicker(
                        profileManager: profileManager,
                        profileName: autoEQProfileName,
                        selection: autoEQSelection,
                        favoriteIDs: autoEQFavoriteIDs,
                        onSelect: onSelect,
                        onImport: onImport,
                        onToggleFavorite: { id in onAutoEQToggleFavorite?(id) },
                        importError: autoEQImportError,
                        isCorrectionEnabled: autoEQEnabled,
                        onCorrectionToggle: onAutoEQToggle,
                        preampEnabled: autoEQPreampEnabled,
                        onPreampToggle: onAutoEQPreampToggle,
                        libraryProfiles: autoEQLibraryProfiles
                    )
                }

                if let onToggleInspector {
                    Button {
                        onToggleInspector()
                    } label: {
                        Image(systemName: isInspectorExpanded ? "info.circle.fill" : "info.circle")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(
                                isInspectorExpanded
                                    ? DesignTokens.Colors.interactiveActive
                                    : (isInfoHovered ? DesignTokens.Colors.interactiveHover : DesignTokens.Colors.textTertiary)
                            )
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .onHover { isInfoHovered = $0 }
                    .help("Device Inspector (Balance, Mono, Limit, Sample Rate)")
                    .accessibilityLabel("Inspect \(device.name)")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Mute button
            MuteButton(isMuted: showMutedIcon, levelFraction: sliderValue) {
                if showMutedIcon {
                    // Unmute: restore to default if displayed as 0%
                    if displayedPercentage == 0 {
                        suppressSliderAutoUnmute = isMuted
                        let target = processing.maxVolumeLimit.map { min(defaultUnmuteVolume, Double($0)) } ?? defaultUnmuteVolume
                        sliderValue = target
                    }
                    if isMuted {
                        onMuteToggle()  // Toggle system mute
                    }
                } else {
                    // Mute
                    onMuteToggle()  // Toggle system mute
                }
            }

            // Volume slider (Liquid Glass)
            LiquidGlassSlider(
                value: $sliderValue,
                onEditingChanged: { editing in
                    isEditing = editing
                }
            )
            .opacity(showMutedIcon ? 0.5 : 1.0)
            .onChange(of: sliderValue) { _, newValue in
                // Skip write-back when syncing from device (breaks USB DAC quantization spiral)
                if isUpdatingSliderFromDevice {
                    isUpdatingSliderFromDevice = false
                    return
                }
                let cappedSlider: Double
                if let limit = processing.maxVolumeLimit, limit < 0.995, newValue > Double(limit) {
                    cappedSlider = Double(limit)
                    isUpdatingSliderFromDevice = true
                    sliderValue = cappedSlider
                } else {
                    cappedSlider = newValue
                }
                onVolumeChange(Self.sliderToVolume(cappedSlider, backend: volumeBackend))
                if suppressSliderAutoUnmute {
                    suppressSliderAutoUnmute = false
                    return
                }
                // Auto-unmute when slider moved while muted
                if isMuted && cappedSlider > 0 {
                    onMuteToggle()
                }
            }
            .scrollWheelStep($sliderValue, in: 0.0...(processing.maxVolumeLimit.map(Double.init) ?? 1.0))

            // Editable volume percentage
            EditablePercentage(
                percentage: Binding(
                    get: { Int(round(sliderValue * 100)) },
                    set: { sliderValue = Double($0) / 100.0 }
                ),
                range: 0...100,
                isRowFocused: isFocused
            )
        }
        .frame(minHeight: DesignTokens.Dimensions.rowContentHeight)
        .onChange(of: volume) { _, newValue in
            // Only sync from external changes when user is NOT dragging
            guard !isEditing else { return }
            let newSlider = Self.volumeToSlider(newValue, backend: volumeBackend)
            guard newSlider != sliderValue else { return }
            isUpdatingSliderFromDevice = true
            sliderValue = newSlider
        }
    }

    private func badgePill(_ badge: String) -> some View {
        Text(badge)
            .font(DesignTokens.Typography.eqLabel)
            .foregroundStyle(DesignTokens.Colors.accentPrimary)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 4)
            .padding(.vertical, 0.5)
            .background(
                Capsule().fill(DesignTokens.Colors.accentPrimary.opacity(0.16))
            )
    }
}

/// Compact wrapping layout for device processing badges so pills keep their intrinsic
/// width and wrap cleanly to a second line in Compact mode instead of truncating to "…".
private struct BadgeFlowLayout: Layout {
    var horizontalSpacing: CGFloat = 4
    var verticalSpacing: CGFloat = 2

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > maxWidth {
                y += rowHeight + verticalSpacing
                x = 0
                rowHeight = 0
            }
            x += size.width
            totalWidth = max(totalWidth, x)
            x += horizontalSpacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: totalWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                y += rowHeight + verticalSpacing
                x = bounds.minX
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + horizontalSpacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

extension DeviceRow {
    // MARK: - Volume Mapping

    static func volumeToSlider(_ volume: Float, backend: VolumeControlTier) -> Double {
        VolumeMapping.sliderFraction(forSystemGain: volume, tier: backend)
    }

    static func sliderToVolume(_ slider: Double, backend: VolumeControlTier) -> Float {
        VolumeMapping.systemGain(forSliderFraction: slider, tier: backend)
    }

    // MARK: - Subtitle

    static func autoEQSubtitle(profileName: String?, isEnabled: Bool) -> String? {
        guard let profileName else { return nil }
        return isEnabled ? profileName : "\(profileName) (off)"
    }
}

// MARK: - Previews

#Preview("Device Row - Default") {
    PreviewContainer {
        VStack(spacing: 0) {
            DeviceRow(
                device: MockData.sampleDevices[0],
                isDefault: true,
                volume: 0.75,
                isMuted: false,
                onSetDefault: {},
                onVolumeChange: { _ in },
                onMuteToggle: {}
            )

            DeviceRow(
                device: MockData.sampleDevices[1],
                isDefault: false,
                volume: 1.0,
                isMuted: false,
                onSetDefault: {},
                onVolumeChange: { _ in },
                onMuteToggle: {}
            )

            DeviceRow(
                device: MockData.sampleDevices[2],
                isDefault: false,
                volume: 0.5,
                isMuted: true,
                onSetDefault: {},
                onVolumeChange: { _ in },
                onMuteToggle: {}
            )
        }
    }
}
