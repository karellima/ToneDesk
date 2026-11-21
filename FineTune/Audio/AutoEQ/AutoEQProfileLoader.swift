// FineTune/Audio/AutoEQ/AutoEQProfileLoader.swift
import Foundation
import os

/// Handles file I/O for AutoEQ profiles: managing imported profile files on disk.
nonisolated final class AutoEQProfileLoader {
    private let logger = Logger(subsystem: "com.finetuneapp.FineTune", category: "AutoEQProfileLoader")

    /// Directory holding imported profiles (`<id>.txt` + `<id>.name`) and `library.json`.
    let importDirectory: URL

    static var defaultImportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("ToneDesk")
            .appendingPathComponent("AutoEQ")
    }

    /// - Parameter directory: Override for tests. Defaults to Application Support/FineTune/AutoEQ.
    init(directory: URL? = nil) {
        self.importDirectory = directory ?? Self.defaultImportDirectory
    }

    /// Rejects profile IDs that could escape `importDirectory` when used as filenames.
    static func isSafeProfileID(_ id: String) -> Bool {
        guard !id.isEmpty, !id.hasPrefix("."), !id.contains("..") else { return false }
        return !id.contains("/") && !id.contains("\\") && !id.contains(":") && !id.contains("\0")
    }

    // MARK: - Imported Profiles

    /// Loads imported profiles synchronously from the import directory.
    func loadImportedProfiles() -> [AutoEQProfile] {
        let dir = importDirectory
        guard FileManager.default.fileExists(atPath: dir.path) else { return [] }

        var profiles: [AutoEQProfile] = []
        do {
            let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "txt" }
            for file in files {
                let text: String
                do {
                    text = try Self.readText(at: file)
                } catch {
                    logger.warning("Skipping unreadable profile \(file.lastPathComponent): \(error.localizedDescription)")
                    continue
                }
                let stableID = file.deletingPathExtension().lastPathComponent

                let nameFile = dir.appendingPathComponent("\(stableID).name")
                let displayName = (try? String(contentsOf: nameFile, encoding: .utf8))?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? stableID

                if let profile = AutoEQParser.parse(text: text, name: displayName, source: .imported, id: stableID) {
                    profiles.append(profile)
                }
            }
            logger.info("Loaded \(profiles.count) imported AutoEQ profiles")
        } catch {
            logger.error("Failed to load imported profiles: \(error.localizedDescription)")
        }
        return profiles
    }

    // MARK: - Import / Delete on Disk

    /// Import a ParametricEQ.txt file. Copies to import directory and returns parsed profile.
    func importProfile(from url: URL, name: String) -> AutoEQProfile? {
        importProfileReport(from: url, name: name).profile
    }

    /// Import a ParametricEQ.txt file with full diagnostics (warnings for skipped lines,
    /// a descriptive error when the file is rejected). The file is only copied into the
    /// library when parsing succeeds.
    func importProfileReport(from url: URL, name: String, id: String? = nil) -> AutoEQParseReport {
        let text: String
        do {
            text = try Self.readText(at: url)
        } catch {
            logger.error("Failed to read profile: \(error.localizedDescription)")
            return AutoEQParseReport(profile: nil, warnings: [], error: .fileError(error.localizedDescription))
        }

        let safeID = id.flatMap { Self.isSafeProfileID($0) ? $0 : nil }
        let report = AutoEQParser.parseReport(text: text, name: name, source: .imported, id: safeID)
        guard let profile = report.profile else {
            logger.warning("Failed to parse imported file: \(name)")
            return report
        }

        do {
            let dir = importDirectory
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let dest = dir.appendingPathComponent("\(profile.id).txt")
            try text.write(to: dest, atomically: true, encoding: .utf8)
            let nameFile = dir.appendingPathComponent("\(profile.id).name")
            try name.write(to: nameFile, atomically: true, encoding: .utf8)

            logger.info("Imported AutoEQ profile: \(name) (\(profile.filters.count) filters, \(report.warnings.count) warnings)")
            return report
        } catch {
            logger.error("Failed to import profile: \(error.localizedDescription)")
            return AutoEQParseReport(profile: nil, warnings: report.warnings, error: .fileError(error.localizedDescription))
        }
    }

    /// Reads a text file, tolerating UTF-16 (some Windows tools) and Latin-1 encodings.
    static func readText(at url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        for encoding in [String.Encoding.utf8, .utf16, .isoLatin1] {
            if let text = String(data: data, encoding: encoding) { return text }
        }
        throw CocoaError(.fileReadInapplicableStringEncoding)
    }

    // MARK: - Library File Access

    /// Raw ParametricEQ.txt text of an imported profile.
    func readProfileText(id: String) -> String? {
        try? Self.readText(at: importDirectory.appendingPathComponent("\(id).txt"))
    }

    /// Writes (or overwrites) an imported profile's text and display name.
    func saveProfile(id: String, text: String, name: String) throws {
        try FileManager.default.createDirectory(at: importDirectory, withIntermediateDirectories: true)
        try text.write(to: importDirectory.appendingPathComponent("\(id).txt"), atomically: true, encoding: .utf8)
        try writeName(id: id, name: name)
    }

    /// Updates only the display name of an imported profile.
    func writeName(id: String, name: String) throws {
        try FileManager.default.createDirectory(at: importDirectory, withIntermediateDirectories: true)
        try name.write(to: importDirectory.appendingPathComponent("\(id).name"), atomically: true, encoding: .utf8)
    }

    /// Delete an imported profile's files from disk.
    func deleteProfileFiles(id: String) {
        let dir = importDirectory
        let file = dir.appendingPathComponent("\(id).txt")
        let nameFile = dir.appendingPathComponent("\(id).name")
        try? FileManager.default.removeItem(at: file)
        try? FileManager.default.removeItem(at: nameFile)
    }
}
