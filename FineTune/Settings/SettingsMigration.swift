// FineTune/Settings/SettingsMigration.swift
import Foundation
import os

/// Versioning and backup for `settings.json`.
///
/// Schema changes are additive (new keys decode with defaults), so migrating means:
/// back up the old file once, then stamp the current version. Nothing is dropped.
///
/// - v13: `deviceAutoEQByName` (AutoEQ assignment fallback by device name/manufacturer)
///        and `autoEQAB` (A/B comparison). Existing `deviceAutoEQ` entries are kept and
///        are mirrored into the name map lazily, when each device is next seen.
nonisolated enum SettingsMigration {
    static let currentVersion = 13

    private static let logger = Logger(subsystem: "com.finetuneapp.FineTune", category: "SettingsMigration")

    /// `settings.v<version>.backup.json` next to `settingsURL`.
    static func backupURL(for settingsURL: URL, version: Int) -> URL {
        settingsURL.deletingLastPathComponent()
            .appendingPathComponent("settings.v\(version).backup.json")
    }

    /// Copies the on-disk settings file before it is rewritten with a newer version.
    /// An existing backup for the same version is never overwritten (keeps the oldest copy).
    @discardableResult
    static func backupBeforeMigrating(settingsURL: URL, fromVersion: Int) -> URL? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: settingsURL.path) else { return nil }
        let backup = backupURL(for: settingsURL, version: fromVersion)
        if fm.fileExists(atPath: backup.path) { return backup }
        do {
            try fm.copyItem(at: settingsURL, to: backup)
            logger.info("Backed up settings v\(fromVersion) to \(backup.lastPathComponent)")
            return backup
        } catch {
            logger.error("Settings backup failed: \(error.localizedDescription)")
            return nil
        }
    }
}
