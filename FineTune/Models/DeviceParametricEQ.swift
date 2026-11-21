// FineTune/Models/DeviceParametricEQ.swift
import Foundation

/// A single editable band in a device's global parametric EQ.
nonisolated struct ParametricEQBand: Codable, Equatable, Identifiable, Sendable {
    var id: UUID = UUID()
    var isEnabled: Bool = true
    var type: AutoEQFilter.FilterType = .peaking
    var frequency: Double = 1000.0
    var gainDB: Float = 0.0
    var q: Double = 1.0

    static let frequencyRange: ClosedRange<Double> = 20...20_000
    static let gainRangeDB: ClosedRange<Float> = -18...18
    static let qRange: ClosedRange<Double> = 0.1...20.0

    init(
        id: UUID = UUID(),
        isEnabled: Bool = true,
        type: AutoEQFilter.FilterType = .peaking,
        frequency: Double = 1000.0,
        gainDB: Float = 0.0,
        q: Double = 1.0
    ) {
        self.id = id
        self.isEnabled = isEnabled
        self.type = type
        self.frequency = Self.clampedFrequency(frequency)
        self.gainDB = Self.clampedGain(gainDB)
        self.q = Self.clampedQ(q)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        type = try c.decodeIfPresent(AutoEQFilter.FilterType.self, forKey: .type) ?? .peaking
        frequency = Self.clampedFrequency(try c.decodeIfPresent(Double.self, forKey: .frequency) ?? 1000.0)
        gainDB = Self.clampedGain(try c.decodeIfPresent(Float.self, forKey: .gainDB) ?? 0.0)
        q = Self.clampedQ(try c.decodeIfPresent(Double.self, forKey: .q) ?? 1.0)
    }

    var asAutoEQFilter: AutoEQFilter {
        AutoEQFilter(type: type, frequency: frequency, gainDB: gainDB, q: q)
    }

    var shortTypeLabel: String {
        switch type {
        case .peaking: return "PK"
        case .lowShelf: return "LSC"
        case .highShelf: return "HSC"
        }
    }

    static func clampedFrequency(_ value: Double) -> Double {
        guard value.isFinite else { return 1000.0 }
        return max(frequencyRange.lowerBound, min(frequencyRange.upperBound, value))
    }

    static func clampedGain(_ value: Float) -> Float {
        guard value.isFinite else { return 0.0 }
        let clamped = max(gainRangeDB.lowerBound, min(gainRangeDB.upperBound, value))
        return abs(clamped) < 0.05 ? 0.0 : clamped
    }

    static func clampedQ(_ value: Double) -> Double {
        guard value.isFinite else { return 1.0 }
        return max(qRange.lowerBound, min(qRange.upperBound, value))
    }
}

/// Editable global parametric EQ stored per output device.
/// Combines seamlessly with any active AutoEQ profile in `AutoEQProcessor` (up to 64 total biquads).
nonisolated struct DeviceParametricEQ: Codable, Equatable, Sendable {
    var isEnabled: Bool = false
    var preampDB: Float = 0.0
    var bands: [ParametricEQBand] = DeviceParametricEQ.defaultBands()

    static let maxBands = 16
    static let preampRangeDB: ClosedRange<Float> = -18...12

    static let `default` = DeviceParametricEQ()

    init(
        isEnabled: Bool = false,
        preampDB: Float = 0.0,
        bands: [ParametricEQBand] = DeviceParametricEQ.defaultBands()
    ) {
        self.isEnabled = isEnabled
        self.preampDB = Self.clampedPreamp(preampDB)
        self.bands = bands.isEmpty ? Self.defaultBands() : Array(bands.prefix(Self.maxBands))
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
        preampDB = Self.clampedPreamp(try c.decodeIfPresent(Float.self, forKey: .preampDB) ?? 0.0)
        // Lossy per-band decode so one malformed band never drops the entire device EQ.
        var decodedBands: [ParametricEQBand] = []
        if c.contains(.bands), var unkeyed = try? c.nestedUnkeyedContainer(forKey: .bands) {
            while !unkeyed.isAtEnd {
                if let band = try? unkeyed.decode(ParametricEQBand.self) {
                    decodedBands.append(band)
                } else {
                    _ = try? unkeyed.decode(SkipElement.self)
                }
            }
        }
        bands = decodedBands.isEmpty ? Self.defaultBands() : Array(decodedBands.prefix(Self.maxBands))
    }

    private struct SkipElement: Decodable {
        init(from decoder: Decoder) throws {}
    }

    /// 5 musical default bands ready to tweak immediately (Low Shelf, Low-Mid, Mid, Presence, Air).
    static func defaultBands() -> [ParametricEQBand] {
        [
            ParametricEQBand(type: .lowShelf, frequency: 80, gainDB: 0, q: 0.71),
            ParametricEQBand(type: .peaking, frequency: 250, gainDB: 0, q: 1.0),
            ParametricEQBand(type: .peaking, frequency: 1000, gainDB: 0, q: 1.0),
            ParametricEQBand(type: .peaking, frequency: 4000, gainDB: 0, q: 1.2),
            ParametricEQBand(type: .highShelf, frequency: 10000, gainDB: 0, q: 0.71)
        ]
    }

    /// Enabled bands with non-zero gain that actually affect the audio signal.
    var activeFilters: [AutoEQFilter] {
        bands
            .filter { $0.isEnabled && abs($0.gainDB) >= 0.05 }
            .map(\.asAutoEQFilter)
    }

    /// True when enabled and applying a non-flat EQ curve or preamp offset.
    var isEffectivelyActive: Bool {
        isEnabled && (!activeFilters.isEmpty || abs(preampDB) >= 0.05)
    }

    /// True only when disabled, preamp is 0, AND bands still match the untouched default template
    /// (preserves user-customized band frequencies/types/Qs/counts even while gains are at 0 dB).
    var isDefaultFlat: Bool {
        guard !isEnabled, abs(preampDB) < 0.05 else { return false }
        let defaults = Self.defaultBands()
        guard bands.count == defaults.count else { return false }
        return zip(bands, defaults).allSatisfy { a, b in
            a.isEnabled == b.isEnabled
                && a.type == b.type
                && abs(a.frequency - b.frequency) < 0.01
                && abs(a.gainDB - b.gainDB) < 0.05
                && abs(a.q - b.q) < 0.001
        }
    }

    mutating func resetFlat() {
        preampDB = 0.0
        for i in bands.indices {
            bands[i].gainDB = 0.0
        }
    }

    mutating func addBand() {
        guard bands.count < Self.maxBands else { return }
        // Place new band in the largest log-frequency gap or at 1 kHz.
        let sortedFreqs = bands.map(\.frequency).sorted()
        var bestFreq = 1000.0
        var bestGap = 0.0
        let anchors = [30.0] + sortedFreqs + [16_000.0]
        for i in 0..<(anchors.count - 1) {
            let lo = log(anchors[i]), hi = log(anchors[i + 1])
            if hi - lo > bestGap {
                bestGap = hi - lo
                bestFreq = exp((lo + hi) * 0.5)
            }
        }
        let roundedFreq = bestFreq < 100 ? (bestFreq / 5).rounded() * 5 : (bestFreq / 10).rounded() * 10
        bands.append(ParametricEQBand(type: .peaking, frequency: roundedFreq, gainDB: 0, q: 1.41))
    }

    mutating func removeBand(id: UUID) {
        guard bands.count > 1 else { return }
        bands.removeAll { $0.id == id }
    }

    /// Exports this EQ in Equalizer APO / REW ParametricEQ.txt format so users can save it to their library.
    func exportParametricEQText() -> String {
        var lines: [String] = []
        lines.append(String(format: "Preamp: %.1f dB", preampDB))
        for (idx, band) in bands.enumerated() {
            let state = band.isEnabled ? "ON" : "OFF"
            lines.append(String(
                format: "Filter %d: %@ %@ Fc %.1f Hz Gain %.1f dB Q %.2f",
                idx + 1, state, band.shortTypeLabel, band.frequency, band.gainDB, band.q
            ))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Computes which active PEQ filters fit alongside `baseAutoEQ` under the 64-biquad ceiling,
    /// and how many active PEQ bands had to be omitted (used by both DSP and graph/UI warning).
    static func effectiveFilters(
        baseAutoEQ: AutoEQProfile?,
        parametricEQ: DeviceParametricEQ
    ) -> (applied: [AutoEQFilter], droppedCount: Int) {
        guard parametricEQ.isEnabled else { return ([], 0) }
        let allActive = parametricEQ.activeFilters
        let baseCount = baseAutoEQ?.filters.count ?? 0
        let availableSlots = max(0, AutoEQProfile.maxFilters - baseCount)
        let applied = Array(allActive.prefix(availableSlots))
        let dropped = max(0, allActive.count - applied.count)
        return (applied, dropped)
    }

    /// Merges a device's AutoEQ profile (optional) with its editable parametric EQ into a single
    /// `AutoEQProfile` cascade for `AutoEQProcessor` (respecting the 64-biquad ceiling).
    /// The device PEQ's preamp is stored in `fixedPreampDB` so toggling AutoEQ's preamp switch
    /// never bypasses the user's manual PEQ preamp.
    static func combinedProfile(
        deviceUID: String,
        baseAutoEQ: AutoEQProfile?,
        parametricEQ: DeviceParametricEQ
    ) -> AutoEQProfile? {
        guard parametricEQ.isEffectivelyActive else {
            return baseAutoEQ
        }
        let (appliedPEQ, _) = effectiveFilters(baseAutoEQ: baseAutoEQ, parametricEQ: parametricEQ)

        if let base = baseAutoEQ {
            var merged = AutoEQProfile(
                id: base.id,
                name: "\(base.name) + PEQ",
                source: base.source,
                preampDB: base.preampDB,
                filters: base.filters + appliedPEQ,
                measuredBy: base.measuredBy,
                optimizedSampleRate: base.optimizedSampleRate
            )
            merged.levelTrimDB = base.levelTrimDB
            merged.fixedPreampDB = parametricEQ.preampDB
            return merged
        } else {
            // When only preamp is non-zero, add a unity 0 dB filter so AutoEQProcessor runs.
            let standaloneFilters = appliedPEQ.isEmpty
                ? [AutoEQFilter(type: .peaking, frequency: 1000, gainDB: 0, q: 1.0)]
                : appliedPEQ
            var profile = AutoEQProfile(
                id: "device-peq-\(deviceUID)",
                name: "Device Parametric EQ",
                source: .imported,
                preampDB: 0,
                filters: standaloneFilters,
                measuredBy: nil,
                optimizedSampleRate: nil
            )
            profile.fixedPreampDB = parametricEQ.preampDB
            return profile
        }
    }

    static func clampedPreamp(_ value: Float) -> Float {
        guard value.isFinite else { return 0.0 }
        return max(preampRangeDB.lowerBound, min(preampRangeDB.upperBound, value))
    }
}
