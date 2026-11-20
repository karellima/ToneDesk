// FineTune/Audio/AutoEQ/AutoEQParser.swift
import Foundation
import os

/// Why a ParametricEQ.txt file could not be imported.
nonisolated enum AutoEQParseError: Error, Equatable, LocalizedError {
    /// No enabled, valid filter lines were found.
    case noFilters
    /// The profile has more filters than the processor supports.
    case tooManyFilters(count: Int, max: Int)
    /// A filter line has a value outside the accepted range.
    case valueOutOfRange(lineNumber: Int, line: String, reason: String)
    /// The Preamp value is outside the accepted range.
    case preampOutOfRange(lineNumber: Int, value: Float)
    /// The file could not be read or saved.
    case fileError(String)

    var errorDescription: String? {
        switch self {
        case .noFilters:
            return "No enabled filters found. Expected lines like \"Filter 1: ON PK Fc 100 Hz Gain -2.0 dB Q 1.41\"."
        case let .tooManyFilters(count, max):
            return "This profile has \(count) filters; FineTune supports up to \(max). Nothing was truncated — reduce the filter count and import again."
        case let .valueOutOfRange(lineNumber, line, reason):
            return "Line \(lineNumber): \(reason) — \"\(line)\""
        case let .preampOutOfRange(lineNumber, value):
            let r = AutoEQProfile.preampRangeDB
            return "Line \(lineNumber): Preamp \(value) dB is outside \(Int(r.lowerBound))…\(Int(r.upperBound)) dB."
        case let .fileError(message):
            return "Could not read or save the file: \(message)"
        }
    }
}

/// Detailed outcome of parsing a ParametricEQ.txt file.
nonisolated struct AutoEQParseReport {
    /// Parsed profile, or `nil` when `error` is set.
    let profile: AutoEQProfile?
    /// Non-fatal issues (unknown or unsupported lines that were skipped).
    let warnings: [String]
    /// Fatal issue that prevented import.
    let error: AutoEQParseError?
}

/// Parses EqualizerAPO ParametricEQ.txt files into AutoEQ profiles.
nonisolated enum AutoEQParser {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "FineTune", category: "AutoEQParser")

    /// Default Q for shelves written without a Q (shelf slope S = 1 ⇒ Q = 1/√2).
    static let defaultShelfQ: Double = 0.7071067811865476

    // MARK: - ParametricEQ.txt Parsing

    /// Parse an EqualizerAPO ParametricEQ.txt string into an AutoEQProfile.
    /// Returns nil when the file cannot be imported (see `parseReport` for the reason).
    /// - Parameters:
    ///   - id: Explicit ID to use. If nil, generates one (slug for fetched, UUID for imported).
    static func parse(text: String, name: String, source: AutoEQSource, id: String? = nil) -> AutoEQProfile? {
        parseReport(text: text, name: name, source: source, id: id).profile
    }

    /// Parse with full diagnostics: unknown lines become warnings, out-of-range values and
    /// profiles above `AutoEQProfile.maxFilters` become errors. Never truncates.
    static func parseReport(text: String, name: String, source: AutoEQSource, id: String? = nil) -> AutoEQParseReport {
        var preampDB: Float = 0
        var filters: [AutoEQFilter] = []
        var warnings: [String] = []

        func fail(_ error: AutoEQParseError) -> AutoEQParseReport {
            logger.warning("Parse failed for \(name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return AutoEQParseReport(profile: nil, warnings: warnings, error: error)
        }

        let lines = text.components(separatedBy: .newlines)
        for (index, line) in lines.enumerated() {
            let lineNumber = index + 1
            // Strip BOM and whitespace
            let trimmed = line.trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: "\u{FEFF}")))
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            let lowered = trimmed.lowercased()

            if lowered.hasPrefix("preamp:") {
                guard let value = parsePreamp(trimmed) else {
                    warnings.append("Line \(lineNumber): unreadable Preamp ignored — \"\(trimmed)\"")
                    continue
                }
                guard AutoEQProfile.preampRangeDB.contains(value) else {
                    return fail(.preampOutOfRange(lineNumber: lineNumber, value: value))
                }
                preampDB = value
            } else if lowered.hasPrefix("filter") {
                switch parseFilterLine(trimmed) {
                case .filter(let filter):
                    filters.append(filter)
                case .disabled:
                    continue
                case .skipped(let reason):
                    warnings.append("Line \(lineNumber): \(reason) — ignored: \"\(trimmed)\"")
                case .outOfRange(let reason):
                    return fail(.valueOutOfRange(lineNumber: lineNumber, line: trimmed, reason: reason))
                }
            } else {
                warnings.append("Line \(lineNumber): unknown line ignored — \"\(trimmed)\"")
            }
        }

        guard !filters.isEmpty else { return fail(.noFilters) }
        guard filters.count <= AutoEQProfile.maxFilters else {
            return fail(.tooManyFilters(count: filters.count, max: AutoEQProfile.maxFilters))
        }

        let resolvedID: String
        if let id {
            resolvedID = id
        } else {
            switch source {
            case .bundled, .fetched:
                resolvedID = slugify(name)
            case .imported:
                resolvedID = UUID().uuidString
            }
        }

        let profile = AutoEQProfile(
            id: resolvedID,
            name: name,
            source: source,
            preampDB: preampDB,
            filters: filters,
            // Imported files (REW / Equalizer APO) are applied exactly as written at any
            // device rate. AutoEQ database profiles keep the 48 kHz pre-warp behavior.
            optimizedSampleRate: source == .imported ? nil : 48000
        )
        return AutoEQParseReport(profile: profile, warnings: warnings, error: nil)
    }

    // MARK: - Private Helpers

    private enum FilterLineResult {
        case filter(AutoEQFilter)
        case disabled
        case skipped(String)
        case outOfRange(String)
    }

    /// Parse "Preamp: -6.2 dB" — handles irregular whitespace.
    private static func parsePreamp(_ line: String) -> Float? {
        let parts = line.components(separatedBy: ":").dropFirst()
        guard let valuePart = parts.first else { return nil }
        let tokens = valuePart.split(whereSeparator: { $0.isWhitespace })
        guard let first = tokens.first, let value = parseNumber(String(first)), value.isFinite else { return nil }
        return Float(value)
    }

    /// Parse a filter line like:
    /// "Filter 1: ON PK Fc 100 Hz Gain -2.3 dB Q 1.41"
    /// "Filter 2: ON LSC Fc 105 Hz Gain 7.0 dB Q 0.71"
    private static func parseFilterLine(_ line: String) -> FilterLineResult {
        let tokens = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let upper = tokens.map { $0.uppercased() }

        if upper.contains("OFF") && !upper.contains("ON") { return .disabled }
        guard let onIndex = upper.firstIndex(of: "ON") else {
            return .skipped("missing ON/OFF")
        }
        guard onIndex + 1 < tokens.count else { return .skipped("missing filter type") }

        let typeToken = upper[onIndex + 1]
        guard let type = parseFilterType(typeToken) else {
            return .skipped("unsupported filter type \(tokens[onIndex + 1])")
        }
        // "LS 6dB" / "LSC 12 dB" slope variants use different math — not supported.
        if onIndex + 2 < tokens.count, upper[onIndex + 2] != "FC" {
            return .skipped("unsupported \(tokens[onIndex + 1]) variant")
        }

        guard let frequency = extractValue(after: "FC", in: upper, tokens: tokens) else {
            return .skipped("missing Fc")
        }
        guard let gainDB = extractValue(after: "GAIN", in: upper, tokens: tokens) else {
            return .skipped("missing Gain")
        }
        let q: Double
        if let qValue = extractValue(after: "Q", in: upper, tokens: tokens) {
            q = qValue
        } else if type != .peaking {
            q = defaultShelfQ
        } else {
            return .skipped("missing Q")
        }

        let fc = frequency
        guard AutoEQProfile.frequencyRangeHz.contains(fc) else {
            let r = AutoEQProfile.frequencyRangeHz
            return .outOfRange("Fc \(frequency) Hz is outside \(Int(r.lowerBound))…\(Int(r.upperBound)) Hz")
        }
        let gain = Float(gainDB)
        guard AutoEQProfile.gainRangeDB.contains(gain) else {
            let r = AutoEQProfile.gainRangeDB
            return .outOfRange("Gain \(gainDB) dB is outside \(Int(r.lowerBound))…\(Int(r.upperBound)) dB")
        }
        guard AutoEQProfile.qRange.contains(q) else {
            let r = AutoEQProfile.qRange
            return .outOfRange("Q \(q) is outside \(r.lowerBound)…\(Int(r.upperBound))")
        }

        return .filter(AutoEQFilter(type: type, frequency: fc, gainDB: gain, q: q))
    }

    private static func parseFilterType(_ token: String) -> AutoEQFilter.FilterType? {
        switch token {
        case "PK", "PEQ": return .peaking
        case "LS", "LSC": return .lowShelf
        case "HS", "HSC": return .highShelf
        default: return nil
        }
    }

    /// Extract the numeric value following a keyword (e.g., "Fc" → 100).
    private static func extractValue(after keyword: String, in upper: [String], tokens: [String]) -> Double? {
        guard let index = upper.firstIndex(of: keyword), index + 1 < tokens.count else { return nil }
        guard let value = parseNumber(tokens[index + 1]), value.isFinite else { return nil }
        return value
    }

    /// Accepts "1.5" and "1,5" (some locales export comma decimals).
    private static func parseNumber(_ token: String) -> Double? {
        Double(token) ?? Double(token.replacingOccurrences(of: ",", with: "."))
    }

    /// Convert a profile name to a URL-safe slug.
    private static func slugify(_ name: String) -> String {
        name.lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" }
    }
}
