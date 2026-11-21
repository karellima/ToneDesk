// FineTune/Audio/AutoEQ/AutoEQLibrary.swift
import Foundation
import os

/// Outcome of importing one or more files / folders into the library.
struct AutoEQImportSummary: Equatable {
    struct Failure: Equatable {
        let fileName: String
        let message: String
    }

    var imported: [AutoEQProfile] = []
    /// Files skipped because an identical profile with the same name is already in the library.
    var duplicates: [String] = []
    var failures: [Failure] = []
    /// Non-fatal parser warnings, prefixed with the file name.
    var warnings: [String] = []

    /// Short human-readable result, e.g. "Imported 6 profiles · 1 skipped".
    var message: String {
        var parts: [String] = []
        parts.append("Imported \(imported.count) profile\(imported.count == 1 ? "" : "s")")
        if !duplicates.isEmpty { parts.append("\(duplicates.count) already in library") }
        if !failures.isEmpty { parts.append("\(failures.count) failed") }
        if !warnings.isEmpty { parts.append("\(warnings.count) line(s) ignored") }
        return parts.joined(separator: " · ")
    }
}

/// The user's persistent library of imported ParametricEQ profiles.
///
/// Files live in `Application Support/FineTune/AutoEQ` (`<id>.txt` + `<id>.name`, the
/// format FineTune already used), plus `library.json` for the user-defined order.
/// Favorites stay in `settings.json` (`favoriteAutoEQProfiles`) as before.
@Observable
@MainActor
final class AutoEQLibrary {
    private let manager: AutoEQProfileManager
    private let loader: AutoEQProfileLoader
    private let logger = Logger(subsystem: "com.finetuneapp.FineTune", category: "AutoEQLibrary")

    /// Ordered IDs of library profiles.
    private(set) var order: [String] = []

    /// Library profiles in user order.
    var profiles: [AutoEQProfile] {
        order.compactMap { manager.profile(for: $0) }
    }

    init(manager: AutoEQProfileManager) {
        self.manager = manager
        self.loader = manager.profileLoader
        loadOrder()
        reconcileOrder()
    }

    // MARK: - Order persistence

    private struct Index: Codable {
        var version: Int = 1
        var order: [String]
    }

    private var indexURL: URL { loader.importDirectory.appendingPathComponent("library.json") }

    private func loadOrder() {
        guard let data = try? Data(contentsOf: indexURL),
              let index = try? JSONDecoder().decode(Index.self, from: data) else { return }
        order = index.order
    }

    private func saveOrder() {
        do {
            try FileManager.default.createDirectory(at: loader.importDirectory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(Index(order: order))
            try data.write(to: indexURL, options: .atomic)
        } catch {
            logger.error("Failed to save library order: \(error.localizedDescription)")
        }
    }

    /// Drops IDs whose files are gone and appends imported profiles missing from the
    /// index (e.g. imported by an older version), sorted by name.
    private func reconcileOrder() {
        let imported = manager.importedProfiles
        let ids = Set(imported.map(\.id))
        var newOrder = order.filter { ids.contains($0) }
        let known = Set(newOrder)
        let missing = imported
            .filter { !known.contains($0.id) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        newOrder.append(contentsOf: missing.map(\.id))
        // In memory only: the index is written on the next user edit, so merely
        // launching (or constructing in tests) never touches disk.
        order = newOrder
    }

    func contains(_ id: String) -> Bool { order.contains(id) }

    // MARK: - Import

    /// Imports `.txt` files and/or folders (folders are scanned up to two levels deep).
    func importItems(at urls: [URL]) -> AutoEQImportSummary {
        var summary = AutoEQImportSummary()
        for file in Self.expandToTextFiles(urls) {
            importFile(file, into: &summary)
        }
        if !summary.imported.isEmpty { saveOrder() }
        logger.info("Library import: \(summary.message)")
        return summary
    }

    private func importFile(_ url: URL, name: String? = nil, id: String? = nil,
                            into summary: inout AutoEQImportSummary) {
        let fileName = url.lastPathComponent
        let displayName = name ?? url.deletingPathExtension().lastPathComponent

        if let text = try? AutoEQProfileLoader.readText(at: url), isDuplicate(text: text, name: displayName) {
            summary.duplicates.append(fileName)
            return
        }

        let resolvedID = id.flatMap { candidate -> String? in
            guard AutoEQProfileLoader.isSafeProfileID(candidate),
                  manager.profile(for: candidate) == nil else { return nil }
            return candidate
        }
        let report = loader.importProfileReport(from: url, name: displayName, id: resolvedID)
        summary.warnings.append(contentsOf: report.warnings.map { "\(fileName): \($0)" })
        guard let profile = report.profile else {
            let message = report.error?.localizedDescription ?? "Could not read profile"
            summary.failures.append(.init(fileName: fileName, message: message))
            return
        }
        manager.registerImported(profile)
        order.append(profile.id)
        summary.imported.append(profile)
    }

    private func isDuplicate(text: String, name: String) -> Bool {
        let normalized = Self.normalizedText(text)
        return profiles.contains { profile in
            profile.name == name && loader.readProfileText(id: profile.id).map(Self.normalizedText) == normalized
        }
    }

    private static func normalizedText(_ text: String) -> String {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    /// Expands folders into the `.txt` files they contain (depth ≤ 2, hidden files skipped).
    nonisolated static func expandToTextFiles(_ urls: [URL]) -> [URL] {
        var result: [URL] = []
        let fm = FileManager.default
        for url in urls {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if !isDir.boolValue {
                if url.pathExtension.lowercased() == "txt" { result.append(url) }
                continue
            }
            guard let enumerator = fm.enumerator(
                at: url, includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }
            var files: [URL] = []
            for case let file as URL in enumerator {
                if enumerator.level > 2 { enumerator.skipDescendants(); continue }
                if file.pathExtension.lowercased() == "txt" { files.append(file) }
            }
            files.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            result.append(contentsOf: files)
        }
        return result
    }

    // MARK: - Edit

    /// Renames a profile. Returns false for an empty name or unknown ID.
    @discardableResult
    func rename(id: String, to newName: String) -> Bool {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let profile = manager.profile(for: id), profile.source == .imported else { return false }
        do {
            try loader.writeName(id: id, name: name)
        } catch {
            logger.error("Rename failed: \(error.localizedDescription)")
            return false
        }
        manager.registerImported(AutoEQProfile(
            id: profile.id, name: name, source: profile.source, preampDB: profile.preampDB,
            filters: profile.filters, measuredBy: profile.measuredBy,
            optimizedSampleRate: profile.optimizedSampleRate))
        return true
    }

    /// Duplicates a profile right after the original. Returns the copy.
    @discardableResult
    func duplicate(id: String) -> AutoEQProfile? {
        guard let profile = manager.profile(for: id), profile.source == .imported,
              let text = loader.readProfileText(id: id) else { return nil }
        let newID = UUID().uuidString
        let newName = uniqueName(base: "\(profile.name) copy")
        guard let copy = AutoEQParser.parse(text: text, name: newName, source: .imported, id: newID) else { return nil }
        do {
            try loader.saveProfile(id: newID, text: text, name: newName)
        } catch {
            logger.error("Duplicate failed: \(error.localizedDescription)")
            return nil
        }
        manager.registerImported(copy)
        let index = order.firstIndex(of: id).map { $0 + 1 } ?? order.count
        order.insert(newID, at: index)
        saveOrder()
        return copy
    }

    /// Deletes a profile's files. Device assignments are cleared by the caller (AudioEngine).
    func delete(id: String) {
        manager.deleteImportedProfile(id: id)
        order.removeAll { $0 == id }
        saveOrder()
    }

    /// Reorders using SwiftUI `onMove` semantics.
    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        var items = order
        let moving = source.sorted().map { items[$0] }
        for index in source.sorted(by: >) { items.remove(at: index) }
        let adjusted = destination - source.filter { $0 < destination }.count
        items.insert(contentsOf: moving, at: max(0, min(adjusted, items.count)))
        order = items
        saveOrder()
    }

    private func uniqueName(base: String) -> String {
        let names = Set(profiles.map(\.name))
        guard names.contains(base) else { return base }
        var n = 2
        while names.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }

    // MARK: - Cycling

    /// Next / previous library profile relative to `currentID` (wraps around).
    func neighbor(of currentID: String?, offset: Int) -> AutoEQProfile? {
        let items = profiles
        guard !items.isEmpty else { return nil }
        guard let currentID, let index = items.firstIndex(where: { $0.id == currentID }) else {
            return offset >= 0 ? items.first : items.last
        }
        let count = items.count
        return items[((index + offset) % count + count) % count]
    }

    // MARK: - Backup (export / import)

    private struct Manifest: Codable {
        struct Entry: Codable {
            let id: String
            let name: String
            let file: String
            let favorite: Bool
        }
        var formatVersion: Int = 1
        var app: String = "ToneDesk"
        var exportedAt: Date
        var profiles: [Entry]
    }

    static let backupFolderName = "ToneDesk Profiles"

    /// Writes the whole library (files, names, order, favorites) to a `.zip` at `destination`.
    func exportBackup(to destination: URL, favoriteIDs: Set<String>) async throws {
        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appendingPathComponent("FineTuneExport-\(UUID().uuidString)")
        let root = staging.appendingPathComponent(Self.backupFolderName)
        let profilesDir = root.appendingPathComponent("profiles")
        try fm.createDirectory(at: profilesDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        var entries: [Manifest.Entry] = []
        for profile in profiles {
            guard let text = loader.readProfileText(id: profile.id) else { continue }
            let file = "profiles/\(profile.id).txt"
            try text.write(to: root.appendingPathComponent(file), atomically: true, encoding: .utf8)
            entries.append(.init(id: profile.id, name: profile.name, file: file,
                                 favorite: favoriteIDs.contains(profile.id)))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(Manifest(exportedAt: Date(), profiles: entries))
            .write(to: root.appendingPathComponent("library.json"), options: .atomic)

        if destination.pathExtension.lowercased() == "zip" {
            try? fm.removeItem(at: destination)
            try await Self.runDitto(["-c", "-k", "--sequesterRsrc", "--keepParent", root.path, destination.path])
        } else {
            try? fm.removeItem(at: destination)
            try fm.copyItem(at: root, to: destination)
        }
        logger.info("Exported \(entries.count) profiles to \(destination.lastPathComponent)")
    }

    /// Restores a backup (`.zip` or folder). Profiles already present (same name and
    /// filters) are skipped; original IDs are kept when free so device assignments in a
    /// restored settings file keep working. Returns the summary and the IDs to favorite.
    func importBackup(from source: URL) async throws -> (summary: AutoEQImportSummary, favoriteIDs: Set<String>) {
        let fm = FileManager.default
        var root = source
        var cleanup: URL?
        defer { if let cleanup { try? fm.removeItem(at: cleanup) } }

        if source.pathExtension.lowercased() == "zip" {
            let tmp = fm.temporaryDirectory.appendingPathComponent("FineTuneImport-\(UUID().uuidString)")
            try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
            cleanup = tmp
            try await Self.runDitto(["-x", "-k", source.path, tmp.path])
            root = tmp
        }

        guard let manifestURL = Self.findManifest(in: root) else {
            // Plain folder of .txt files
            return (importItems(at: [root]), [])
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(Manifest.self, from: Data(contentsOf: manifestURL))
        let base = manifestURL.deletingLastPathComponent().standardizedFileURL
        let basePrefix = base.path.hasSuffix("/") ? base.path : base.path + "/"

        var summary = AutoEQImportSummary()
        var favorites: Set<String> = []
        for entry in manifest.profiles {
            let fileURL = base.appendingPathComponent(entry.file).standardizedFileURL
            // Never read outside the backup folder.
            guard fileURL.path.hasPrefix(basePrefix) else { continue }
            let before = summary.imported.count
            importFile(fileURL, name: entry.name, id: entry.id, into: &summary)
            if entry.favorite, summary.imported.count > before, let id = summary.imported.last?.id {
                favorites.insert(id)
            }
        }
        if !summary.imported.isEmpty { saveOrder() }
        return (summary, favorites)
    }

    private static func findManifest(in root: URL) -> URL? {
        let fm = FileManager.default
        let direct = root.appendingPathComponent("library.json")
        if fm.fileExists(atPath: direct.path) { return direct }
        let nested = root.appendingPathComponent(backupFolderName).appendingPathComponent("library.json")
        if fm.fileExists(atPath: nested.path) { return nested }
        let children = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return children.lazy
            .map { $0.appendingPathComponent("library.json") }
            .first { fm.fileExists(atPath: $0.path) }
    }

    enum BackupError: LocalizedError {
        case archiveFailed(Int32)
        var errorDescription: String? {
            switch self {
            case .archiveFailed(let code): return "Could not create or read the archive (ditto exit \(code))."
            }
        }
    }

    /// `/usr/bin/ditto` ships with macOS and handles Finder-compatible zip archives.
    /// Awaits process completion asynchronously so `@MainActor` is never blocked.
    private nonisolated static func runDitto(_ arguments: [String]) async throws {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            process.arguments = arguments
            process.terminationHandler = { proc in
                if proc.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: BackupError.archiveFailed(proc.terminationStatus))
                }
            }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: error)
            }
        }
    }
}
