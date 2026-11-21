// FineTune/Views/Components/DeviceParametricEQEditorView.swift
import SwiftUI

/// Interactive global parametric EQ editor for an output device.
/// Features a live draggable frequency-response graph (showing AutoEQ base + combined curve),
/// band selector pills, and fine numeric sliders for Type, Frequency, Gain, Q, and Preamp.
@MainActor
struct DeviceParametricEQEditorView: View {
    let deviceName: String
    let baseAutoEQ: AutoEQProfile?
    let eq: DeviceParametricEQ
    var sampleRate: Double = 48_000
    let onChange: (DeviceParametricEQ) -> Void
    var onSaveToLibrary: ((String, String) -> Void)? = nil

    @State private var selectedBandID: UUID?
    @State private var savedConfirmation = false

    private var activeBandIndex: Int? {
        if let id = selectedBandID, let idx = eq.bands.firstIndex(where: { $0.id == id }) {
            return idx
        }
        return eq.bands.isEmpty ? nil : 0
    }

    var body: some View {
        let curves = FrequencyResponseCurve.evaluateDeviceCurves(
            baseAutoEQ: baseAutoEQ,
            parametricEQ: eq,
            sampleRate: sampleRate
        )

        VStack(alignment: .leading, spacing: 6) {
            if curves.droppedBandCount > 0 {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(DesignTokens.Typography.caption)
                        .foregroundStyle(Color(nsColor: .systemOrange))
                    Text("\(AutoEQProfile.maxFilters)-filter ceiling reached: \(curves.droppedBandCount) PEQ band(s) omitted from audio and graph.")
                        .font(DesignTokens.Typography.caption)
                        .foregroundStyle(Color(nsColor: .systemOrange))
                }
            }
            // Top bar: Preamp + actions
            HStack(spacing: 6) {
                Text("Preamp")
                    .font(DesignTokens.Typography.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(DesignTokens.Colors.textSecondary)

                Slider(
                    value: Binding(
                        get: { Double(eq.preampDB) },
                        set: { val in
                            var updated = eq
                            updated.preampDB = DeviceParametricEQ.clampedPreamp(Float(val))
                            if !updated.isEnabled { updated.isEnabled = true }
                            onChange(updated)
                        }
                    ),
                    in: Double(DeviceParametricEQ.preampRangeDB.lowerBound)...Double(DeviceParametricEQ.preampRangeDB.upperBound),
                    step: 0.5
                )
                .controlSize(.mini)
                .frame(maxWidth: 95)
                .accessibilityLabel("Parametric EQ preamp")
                .accessibilityValue(String(format: "%+.1f dB", eq.preampDB))

                Text(String(format: "%+.1f dB", eq.preampDB))
                    .font(DesignTokens.Typography.eqLabel)
                    .foregroundStyle(DesignTokens.Colors.textSecondary)
                    .frame(width: 46, alignment: .trailing)

                Spacer(minLength: 4)

                Button {
                    var updated = eq
                    updated.addBand()
                    updated.isEnabled = true
                    selectedBandID = updated.bands.last?.id
                    onChange(updated)
                } label: {
                    Image(systemName: "plus")
                        .font(DesignTokens.Typography.caption)
                        .fontWeight(.semibold)
                }
                .buttonStyle(.plain)
                .disabled(eq.bands.count >= DeviceParametricEQ.maxBands)
                .help("Add filter band (up to \(DeviceParametricEQ.maxBands))")
                .accessibilityLabel("Add filter band")

                Button("Flat") {
                    var updated = eq
                    updated.resetFlat()
                    onChange(updated)
                }
                .buttonStyle(.plain)
                .font(DesignTokens.Typography.caption)
                .fontWeight(.medium)
                .foregroundStyle(DesignTokens.Colors.textSecondary)
                .help("Reset all band gains and preamp to 0 dB")

                if let onSaveToLibrary {
                    Button {
                        let name = "\(deviceName) EQ"
                        onSaveToLibrary(name, eq.exportParametricEQText())
                        savedConfirmation = true
                        Task { @MainActor in
                            try? await Task.sleep(for: .seconds(2))
                            savedConfirmation = false
                        }
                    } label: {
                        Image(systemName: savedConfirmation ? "checkmark" : "square.and.arrow.down")
                            .font(DesignTokens.Typography.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(savedConfirmation ? Color(nsColor: .systemGreen) : DesignTokens.Colors.accentPrimary)
                    }
                    .buttonStyle(.plain)
                    .disabled(eq.activeFilters.isEmpty)
                    .help("Save this curve to Profile Library")
                    .accessibilityLabel("Save curve to Profile Library")
                }
            }

            // Live interactive frequency response graph
            FrequencyResponseGraphView(
                primaryCurve: curves.combined,
                secondaryCurve: curves.base,
                primaryLabel: curves.base != nil ? "Combined" : nil,
                secondaryLabel: curves.base != nil ? "AutoEQ" : nil,
                height: 98,
                bands: eq.bands,
                selectedBandID: activeBandIndex.map { eq.bands[$0].id },
                onSelectBand: { selectedBandID = $0 },
                onDragBand: { id, freq, gain in
                    guard let idx = eq.bands.firstIndex(where: { $0.id == id }) else { return }
                    var updated = eq
                    updated.isEnabled = true
                    updated.bands[idx].isEnabled = true
                    updated.bands[idx].frequency = freq
                    updated.bands[idx].gainDB = gain
                    onChange(updated)
                }
            )

            // Band selector strip
            ScrollView(.horizontal) {
                HStack(spacing: 4) {
                    ForEach(Array(eq.bands.enumerated()), id: \.element.id) { index, band in
                        let isSel = activeBandIndex == index
                        Button {
                            selectedBandID = band.id
                        } label: {
                            Text("\(index + 1) · \(Self.shortFreq(band.frequency))")
                                .font(DesignTokens.Typography.eqLabel)
                                .fontWeight(isSel ? .semibold : .regular)
                                .foregroundStyle(isSel ? Color.white : (band.isEnabled ? DesignTokens.Colors.textSecondary : DesignTokens.Colors.textTertiary))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(
                                    Capsule().fill(isSel ? DesignTokens.Colors.accentPrimary : DesignTokens.Colors.glassFillStrong)
                                )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Band \(index + 1), \(Self.shortFreq(band.frequency)) hertz")
                        .accessibilityAddTraits(isSel ? .isSelected : [])
                    }
                }
            }
            .scrollIndicators(.never)

            // Selected band fine controls
            if let idx = activeBandIndex {
                selectedBandControls(index: idx)
            }
        }
    }

    @ViewBuilder
    private func selectedBandControls(index: Int) -> some View {
        let band = eq.bands[index]
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                Toggle("Enable band \(index + 1)", isOn: Binding(
                    get: { band.isEnabled },
                    set: { enabled in
                        var updated = eq
                        updated.bands[index].isEnabled = enabled
                        onChange(updated)
                    }
                ))
                .toggleStyle(.checkbox)
                .controlSize(.mini)
                .labelsHidden()
                .help("Enable/bypass band \(index + 1)")

                Picker("Filter type", selection: Binding(
                    get: { band.type },
                    set: { newType in
                        var updated = eq
                        updated.bands[index].type = newType
                        onChange(updated)
                    }
                )) {
                    Text("Peak").tag(AutoEQFilter.FilterType.peaking)
                    Text("Low Shelf").tag(AutoEQFilter.FilterType.lowShelf)
                    Text("High Shelf").tag(AutoEQFilter.FilterType.highShelf)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.mini)
                .frame(maxWidth: 196)

                Spacer(minLength: 4)

                if eq.bands.count > 1 {
                    Button {
                        var updated = eq
                        let removedID = updated.bands[index].id
                        updated.removeBand(id: removedID)
                        selectedBandID = updated.bands.first?.id
                        onChange(updated)
                    } label: {
                        Image(systemName: "trash")
                            .font(DesignTokens.Typography.caption)
                            .foregroundStyle(DesignTokens.Colors.textTertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Remove band \(index + 1)")
                    .accessibilityLabel("Remove band \(index + 1)")
                }
            }

            // Freq (log slider)
            HStack(spacing: 6) {
                Text("Freq")
                    .font(DesignTokens.Typography.cardSource)
                    .foregroundStyle(DesignTokens.Colors.textTertiary)
                    .frame(width: 28, alignment: .leading)
                Slider(
                    value: Binding(
                        get: { FrequencyResponseCurve.normalizedX(forFrequency: band.frequency) },
                        set: { nx in
                            var updated = eq
                            updated.isEnabled = true
                            updated.bands[index].frequency = FrequencyResponseCurve.frequency(forNormalizedX: nx)
                            onChange(updated)
                        }
                    ),
                    in: 0...1
                )
                .controlSize(.mini)
                .accessibilityLabel("Band \(index + 1) frequency")
                .accessibilityValue(Self.shortFreq(band.frequency) + " Hz")
                Text(Self.shortFreq(band.frequency) + " Hz")
                    .font(DesignTokens.Typography.eqLabel)
                    .foregroundStyle(DesignTokens.Colors.textSecondary)
                    .frame(width: 56, alignment: .trailing)
            }

            // Gain
            HStack(spacing: 6) {
                Text("Gain")
                    .font(DesignTokens.Typography.cardSource)
                    .foregroundStyle(DesignTokens.Colors.textTertiary)
                    .frame(width: 28, alignment: .leading)
                Slider(
                    value: Binding(
                        get: { Double(band.gainDB) },
                        set: { val in
                            var updated = eq
                            updated.isEnabled = true
                            updated.bands[index].isEnabled = true
                            updated.bands[index].gainDB = ParametricEQBand.clampedGain(Float(val))
                            onChange(updated)
                        }
                    ),
                    in: Double(ParametricEQBand.gainRangeDB.lowerBound)...Double(ParametricEQBand.gainRangeDB.upperBound),
                    step: 0.1
                )
                .controlSize(.mini)
                .accessibilityLabel("Band \(index + 1) gain")
                .accessibilityValue(String(format: "%+.1f dB", band.gainDB))
                Text(String(format: "%+.1f dB", band.gainDB))
                    .font(DesignTokens.Typography.eqLabel)
                    .foregroundStyle(abs(band.gainDB) >= 0.05 ? DesignTokens.Colors.accentPrimary : DesignTokens.Colors.textSecondary)
                    .frame(width: 56, alignment: .trailing)
            }

            // Q factor
            HStack(spacing: 6) {
                Text("Q")
                    .font(DesignTokens.Typography.cardSource)
                    .foregroundStyle(DesignTokens.Colors.textTertiary)
                    .frame(width: 28, alignment: .leading)
                Slider(
                    value: Binding(
                        get: { log10(max(0.1, band.q)) },
                        set: { logQ in
                            var updated = eq
                            updated.bands[index].q = ParametricEQBand.clampedQ(pow(10.0, logQ))
                            onChange(updated)
                        }
                    ),
                    in: log10(0.1)...log10(20.0)
                )
                .controlSize(.mini)
                .accessibilityLabel("Band \(index + 1) Q factor")
                .accessibilityValue(String(format: "%.2f", band.q))
                Text(String(format: "Q %.2f", band.q))
                    .font(DesignTokens.Typography.eqLabel)
                    .foregroundStyle(DesignTokens.Colors.textSecondary)
                    .frame(width: 56, alignment: .trailing)
            }
        }
    }

    private static func shortFreq(_ hz: Double) -> String {
        if hz >= 1000 {
            let k = hz / 1000.0
            return k >= 10 ? String(format: "%.0fk", k) : String(format: "%.1fk", k)
        }
        return String(format: "%.0f", hz)
    }
}
