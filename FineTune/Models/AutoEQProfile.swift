// FineTune/Models/AutoEQProfile.swift

/// A single biquad filter in an AutoEQ correction profile.
nonisolated struct AutoEQFilter: Codable, Equatable {
    enum FilterType: String, Codable {
        case peaking, lowShelf, highShelf
    }
    let type: FilterType
    let frequency: Double    // Hz
    let gainDB: Float        // dB
    let q: Double            // Quality factor
}

/// A headphone/speaker correction profile from AutoEQ.
nonisolated struct AutoEQProfile: Codable, Equatable, Identifiable {
    let id: String           // Slug for fetched, UUID for imported
    let name: String         // "Sennheiser HD 600"
    let source: AutoEQSource
    let preampDB: Float      // Negative preamp to prevent clipping
    let filters: [AutoEQFilter]
    /// Measurement source (e.g. "oratory1990", "crinacle"). Nil for imported profiles.
    let measuredBy: String?
    /// Sample rate the filter parameters were optimized for (Hz).
    /// `nil` means "use the parameters as written at any device rate" (Equalizer APO / REW
    /// behavior, no frequency pre-warping). Imported profiles use `nil`.
    var optimizedSampleRate: Double?
    /// Runtime-only extra gain (dB) applied with the preamp, e.g. A/B level matching.
    /// Not persisted (absent from `CodingKeys`). Applied even when the preamp is bypassed.
    var levelTrimDB: Float = 0

    /// Maximum number of biquad sections a profile may contain.
    ///
    /// Technical ceiling: `AutoEQProcessor` pre-allocates delay buffers for this many
    /// sections so profile swaps never allocate on the audio thread. Profiles that
    /// exceed it are rejected by the parser with a clear error (never truncated).
    static let maxFilters = 64

    /// Accepted per-filter gain range (dB). Values outside are rejected as absurd.
    static let gainRangeDB: ClosedRange<Float> = -30...30
    /// Accepted preamp range (dB).
    static let preampRangeDB: ClosedRange<Float> = -30...30
    /// Accepted filter frequency range (Hz).
    static let frequencyRangeHz: ClosedRange<Double> = 1...30_000
    /// Accepted Q range.
    static let qRange: ClosedRange<Double> = 0.01...100

    enum CodingKeys: String, CodingKey {
        case id, name, source, preampDB, filters, measuredBy, optimizedSampleRate
    }

    init(
        id: String, name: String, source: AutoEQSource,
        preampDB: Float, filters: [AutoEQFilter],
        measuredBy: String? = nil,
        optimizedSampleRate: Double? = 48000
    ) {
        self.id = id
        self.name = name
        self.source = source
        self.preampDB = preampDB
        self.filters = filters
        self.measuredBy = measuredBy
        self.optimizedSampleRate = optimizedSampleRate
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        source = try container.decode(AutoEQSource.self, forKey: .source)
        preampDB = try container.decode(Float.self, forKey: .preampDB)
        filters = try container.decode([AutoEQFilter].self, forKey: .filters)
        measuredBy = try container.decodeIfPresent(String.self, forKey: .measuredBy)
        if container.contains(.optimizedSampleRate) {
            optimizedSampleRate = try container.decodeIfPresent(Double.self, forKey: .optimizedSampleRate)
        } else {
            // Legacy encodings omitted the key: imported profiles follow APO semantics,
            // everything else keeps the historical 48 kHz assumption.
            optimizedSampleRate = source == .imported ? nil : 48000
        }
    }
}

extension AutoEQProfile {
    /// Validates filters using the same rules as the text parser.
    ///
    /// Defensive only: the parser already rejects out-of-range values with a message.
    /// Profiles beyond `maxFilters` cannot be produced by the parser; if one is ever
    /// constructed directly, the processor refuses it (it never truncates).
    func validated() -> AutoEQProfile {
        let validFilters = filters.filter { f in
            f.frequency > 0 && f.q > 0 && f.gainDB.isFinite && abs(f.gainDB) <= Self.gainRangeDB.upperBound
        }
        let clampedPreamp = max(Self.preampRangeDB.lowerBound, min(Self.preampRangeDB.upperBound, preampDB))
        var result = AutoEQProfile(
            id: id, name: name, source: source,
            preampDB: clampedPreamp,
            filters: validFilters,
            measuredBy: measuredBy,
            optimizedSampleRate: optimizedSampleRate
        )
        result.levelTrimDB = levelTrimDB.isFinite ? max(-30, min(0, levelTrimDB)) : 0
        return result
    }
}

/// Where a profile came from.
nonisolated enum AutoEQSource: String, Codable {
    case bundled, imported, fetched
}

/// Lightweight catalog entry for the AutoEQ search index (no filter data).
/// Populated from the AutoEQ GitHub INDEX.md.
nonisolated struct AutoEQCatalogEntry: Codable, Identifiable, Equatable {
    let id: String           // Slugified name
    let name: String         // "AKG K240 Studio"
    let measuredBy: String   // "oratory1990"
    let relativePath: String // "oratory1990/over-ear/AKG K240 Studio"
}

/// Per-device AutoEQ selection (stored in settings).
nonisolated struct AutoEQSelection: Codable, Equatable {
    let profileID: String
    var isEnabled: Bool
}
