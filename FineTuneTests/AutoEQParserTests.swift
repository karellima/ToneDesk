// FineTuneTests/AutoEQParserTests.swift
import Foundation
import Testing
@testable import FineTune

@Suite("AutoEQParser — ParametricEQ.txt import")
struct AutoEQParserTests {

    // MARK: - User fixtures (REW exports)

    @Test("User REW fixtures parse completely with Preamp kept",
          arguments: ["1_Harman.txt", "2_Harman_Grave_Extra.txt", "3_BK_1974.txt", "4_Harman_mais_ar_16k.txt"])
    func userFixturesParse(name: String) throws {
        let report = AutoEQParser.parseReport(text: try AutoEQTestSupport.fixtureText(name), name: name, source: .imported)
        let profile = try #require(report.profile)
        #expect(report.error == nil)
        #expect(report.warnings.isEmpty)
        #expect(profile.filters.count == 10)
        #expect(profile.preampDB < 0)
    }

    @Test("Harman fixture: filter values are read exactly")
    func harmanValues() throws {
        let profile = try #require(AutoEQParser.parse(
            text: try AutoEQTestSupport.fixtureText("1_Harman.txt"), name: "H", source: .imported))
        #expect(profile.preampDB == -6.5)
        #expect(profile.filters.first == AutoEQFilter(type: .lowShelf, frequency: 110, gainDB: 6.0, q: 0.71))
        #expect(profile.filters[1] == AutoEQFilter(type: .peaking, frequency: 55, gainDB: -4.5, q: 6.0))
        #expect(profile.filters.last == AutoEQFilter(type: .highShelf, frequency: 10000, gainDB: -1.5, q: 0.71))
    }

    // MARK: - Filter counts

    @Test("Profiles up to the ceiling import without truncation", arguments: [12, 20, 32, 64])
    func manyFilters(count: Int) throws {
        let report = AutoEQParser.parseReport(
            text: AutoEQTestSupport.syntheticProfileText(count: count), name: "n", source: .imported)
        #expect(try #require(report.profile).filters.count == count)
    }

    @Test("Above the ceiling: clear error, never silently truncated")
    func tooManyFilters() {
        let count = AutoEQProfile.maxFilters + 1
        let report = AutoEQParser.parseReport(
            text: AutoEQTestSupport.syntheticProfileText(count: count), name: "n", source: .imported)
        #expect(report.profile == nil)
        #expect(report.error == .tooManyFilters(count: count, max: AutoEQProfile.maxFilters))
        #expect(report.error?.localizedDescription.contains("\(AutoEQProfile.maxFilters)") == true)
    }

    @Test("Ceiling is 64")
    func ceiling() { #expect(AutoEQProfile.maxFilters == 64) }

    // MARK: - Types

    @Test("PK/PEQ, LS/LSC, HS/HSC are all accepted")
    func filterTypes() throws {
        let text = """
        Filter 1: ON PK Fc 100 Hz Gain -1 dB Q 1
        Filter 2: ON PEQ Fc 200 Hz Gain -1 dB Q 1
        Filter 3: ON LS Fc 80 Hz Gain 2 dB Q 0.7
        Filter 4: ON LSC Fc 90 Hz Gain 2 dB Q 0.7
        Filter 5: ON HS Fc 8000 Hz Gain 2 dB Q 0.7
        Filter 6: ON HSC Fc 9000 Hz Gain 2 dB Q 0.7
        """
        let profile = try #require(AutoEQParser.parse(text: text, name: "t", source: .imported))
        #expect(profile.filters.map(\.type) == [.peaking, .peaking, .lowShelf, .lowShelf, .highShelf, .highShelf])
    }

    @Test("Shelf without Q uses Q = 1/√2 (slope 1)")
    func shelfDefaultQ() throws {
        let profile = try #require(AutoEQParser.parse(
            text: "Filter 1: ON LSC Fc 100 Hz Gain 3 dB", name: "t", source: .imported))
        #expect(abs(profile.filters[0].q - 0.70710678) < 1e-6)
    }

    // MARK: - Warnings (skip, don't fail)

    @Test("Unknown lines and unsupported filters are skipped with warnings")
    func unknownLinesWarn() throws {
        let text = """
        # comment
        Device: Speakers
        Preamp: -4 dB
        Filter 1: ON PK Fc 100 Hz Gain -2 dB Q 1.4
        Filter 2: ON LP Fc 20000 Hz
        Filter 3: ON LS 12dB Fc 100 Hz Gain 3 dB
        Filter 4: OFF PK Fc 300 Hz Gain -2 dB Q 1
        Filter 5: ON HSC Fc 10000 Hz Gain -1.5 dB Q 0.71
        """
        let report = AutoEQParser.parseReport(text: text, name: "t", source: .imported)
        let profile = try #require(report.profile)
        #expect(profile.filters.count == 2)
        #expect(profile.preampDB == -4)
        #expect(report.warnings.count == 3)  // Device:, LP, LS 12dB (OFF is silent)
        #expect(report.warnings.contains { $0.contains("Line 2") })
        #expect(report.warnings.contains { $0.contains("LP") })
    }

    @Test("Comma decimals and BOM are tolerated")
    func localeTolerance() throws {
        let text = "\u{FEFF}Preamp: -6,5 dB\nFilter 1: ON PK Fc 55 Hz Gain -4,5 dB Q 6,00"
        let profile = try #require(AutoEQParser.parse(text: text, name: "t", source: .imported))
        #expect(profile.preampDB == -6.5)
        #expect(profile.filters[0].gainDB == -4.5)
    }

    // MARK: - Range validation

    @Test("±24 dB gains are accepted")
    func largeGainsAccepted() throws {
        let text = "Filter 1: ON PK Fc 50 Hz Gain 24 dB Q 1\nFilter 2: ON PK Fc 60 Hz Gain -24 dB Q 1"
        #expect(try #require(AutoEQParser.parse(text: text, name: "t", source: .imported)).filters.count == 2)
    }

    @Test("Absurd values are rejected with a line-specific message",
          arguments: [
            "Filter 1: ON PK Fc 100 Hz Gain 45 dB Q 1",
            "Filter 1: ON PK Fc 0 Hz Gain 3 dB Q 1",
            "Filter 1: ON PK Fc 90000 Hz Gain 3 dB Q 1",
            "Filter 1: ON PK Fc 100 Hz Gain 3 dB Q 0",
            "Filter 1: ON PK Fc 100 Hz Gain 3 dB Q 500",
          ])
    func absurdValues(line: String) {
        let report = AutoEQParser.parseReport(text: "Preamp: -3 dB\n" + line, name: "t", source: .imported)
        #expect(report.profile == nil)
        guard case .valueOutOfRange(let lineNumber, _, _) = report.error else {
            Issue.record("expected valueOutOfRange, got \(String(describing: report.error))")
            return
        }
        #expect(lineNumber == 2)
        #expect(report.error?.localizedDescription.hasPrefix("Line 2:") == true)
    }

    @Test("Absurd preamp is rejected")
    func absurdPreamp() {
        let report = AutoEQParser.parseReport(
            text: "Preamp: -80 dB\nFilter 1: ON PK Fc 100 Hz Gain 3 dB Q 1", name: "t", source: .imported)
        #expect(report.error == .preampOutOfRange(lineNumber: 1, value: -80))
    }

    @Test("File without filters is rejected")
    func noFilters() {
        let report = AutoEQParser.parseReport(text: "Preamp: -3 dB\nhello", name: "t", source: .imported)
        #expect(report.error == .noFilters)
    }

    @Test("Legacy parse() wrapper still returns nil on failure")
    func legacyWrapper() {
        #expect(AutoEQParser.parse(text: "nothing", name: "t", source: .imported) == nil)
    }

    // MARK: - Codable compatibility

    @Test("Legacy JSON without optimizedSampleRate: imported → nil, fetched → 48 kHz")
    func legacyDecoding() throws {
        func decode(_ source: String) throws -> AutoEQProfile {
            let json = """
            {"id":"x","name":"x","source":"\(source)","preampDB":-1,"filters":[{"type":"peaking","frequency":100,"gainDB":-1,"q":1}]}
            """
            return try JSONDecoder().decode(AutoEQProfile.self, from: Data(json.utf8))
        }
        #expect(try decode("imported").optimizedSampleRate == nil)
        #expect(try decode("fetched").optimizedSampleRate == 48000)
    }
}
