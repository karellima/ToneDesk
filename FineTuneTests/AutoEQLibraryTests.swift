// FineTuneTests/AutoEQLibraryTests.swift
import AudioToolbox
import Foundation
import Testing
@testable import FineTune

/// Temporary directory removed on deinit.
final class TempDir {
    let url: URL
    init() {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("FineTuneTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: url) }
    func sub(_ name: String) -> URL {
        let u = url.appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
}

@MainActor
@Suite("AutoEQLibrary — persistent profile library")
struct AutoEQLibraryTests {

    static let userFixtures = ["1_Harman.txt", "2_Harman_Grave_Extra.txt", "3_BK_1974.txt", "4_Harman_mais_ar_16k.txt"]

    func makeLibrary(_ dir: URL) -> (AutoEQLibrary, AutoEQProfileManager) {
        let manager = AutoEQProfileManager(loader: AutoEQProfileLoader(directory: dir))
        return (AutoEQLibrary(manager: manager), manager)
    }

    /// A folder like the user's: 6 profiles plus a README that is not a profile.
    func makeProfileFolder(_ tmp: TempDir) throws -> URL {
        let folder = tmp.sub("Presets")
        for name in Self.userFixtures {
            try FileManager.default.copyItem(at: AutoEQTestSupport.fixtureURL(name), to: folder.appendingPathComponent(name))
        }
        try AutoEQTestSupport.syntheticProfileText(count: 12).write(
            to: folder.appendingPathComponent("5_Twelve.txt"), atomically: true, encoding: .utf8)
        try AutoEQTestSupport.syntheticProfileText(count: 20, preamp: -8).write(
            to: folder.appendingPathComponent("6_Twenty.txt"), atomically: true, encoding: .utf8)
        try "Como usar: importe os arquivos no FineTune.".write(
            to: folder.appendingPathComponent("COMO_USAR.txt"), atomically: true, encoding: .utf8)
        return folder
    }

    @Test("Importing a folder of 6 profiles keeps all of them after relaunch")
    func importFolderPersists() throws {
        let tmp = TempDir()
        let store = tmp.sub("store")
        let folder = try makeProfileFolder(tmp)

        let (library, _) = makeLibrary(store)
        let summary = library.importItems(at: [folder])
        #expect(summary.imported.count == 6)
        #expect(summary.failures.map(\.fileName) == ["COMO_USAR.txt"])
        #expect(library.profiles.map(\.name) == ["1_Harman", "2_Harman_Grave_Extra", "3_BK_1974",
                                                  "4_Harman_mais_ar_16k", "5_Twelve", "6_Twenty"])

        // "Relaunch": brand-new manager + library reading the same directory.
        let (reopened, manager) = makeLibrary(store)
        #expect(reopened.profiles.map(\.name) == library.profiles.map(\.name))
        #expect(manager.profile(for: reopened.profiles[5].id)?.filters.count == 20)
    }

    @Test("Re-importing the same folder does not create duplicates")
    func reimportSkipsDuplicates() throws {
        let tmp = TempDir()
        let folder = try makeProfileFolder(tmp)
        let (library, _) = makeLibrary(tmp.sub("store"))
        _ = library.importItems(at: [folder])
        let again = library.importItems(at: [folder])
        #expect(again.imported.isEmpty)
        #expect(again.duplicates.count == 6)
        #expect(library.profiles.count == 6)
    }

    @Test("Rename, duplicate, reorder and delete persist")
    func editsPersist() throws {
        let tmp = TempDir()
        let store = tmp.sub("store")
        let folder = try makeProfileFolder(tmp)
        let (library, _) = makeLibrary(store)
        _ = library.importItems(at: [folder])
        let ids = library.profiles.map(\.id)

        #expect(library.rename(id: ids[0], to: "  Harman sala  "))
        #expect(!library.rename(id: ids[0], to: "   "))
        let copy = try #require(library.duplicate(id: ids[0]))
        #expect(copy.name == "Harman sala copy")
        #expect(library.order[1] == copy.id)
        library.move(fromOffsets: IndexSet(integer: 0), toOffset: library.order.count)
        library.delete(id: ids[2])

        let (reopened, _) = makeLibrary(store)
        let names = reopened.profiles.map(\.name)
        #expect(names.first == "Harman sala copy")
        #expect(names.last == "Harman sala")
        #expect(!names.contains("3_BK_1974"))
        #expect(names.count == 6)
    }

    @Test("Next/previous wraps around the library order")
    func cycling() throws {
        let tmp = TempDir()
        let (library, _) = makeLibrary(tmp.sub("store"))
        _ = library.importItems(at: [try makeProfileFolder(tmp)])
        let ids = library.order
        #expect(library.neighbor(of: nil, offset: 1)?.id == ids.first)
        #expect(library.neighbor(of: nil, offset: -1)?.id == ids.last)
        #expect(library.neighbor(of: ids[0], offset: 1)?.id == ids[1])
        #expect(library.neighbor(of: ids.last, offset: 1)?.id == ids[0])
        #expect(library.neighbor(of: ids[0], offset: -1)?.id == ids.last)
    }

    @Test("Profiles imported by older versions (no library.json) are picked up")
    func legacyFilesWithoutIndex() throws {
        let tmp = TempDir()
        let store = tmp.sub("store")
        let loader = AutoEQProfileLoader(directory: store)
        try loader.saveProfile(id: "legacy-1", text: try AutoEQTestSupport.fixtureText("1_Harman.txt"), name: "Old import")
        let (library, _) = makeLibrary(store)
        #expect(library.profiles.map(\.name) == ["Old import"])
        // Launch alone never writes the index.
        #expect(!FileManager.default.fileExists(atPath: store.appendingPathComponent("library.json").path))
    }

    @Test("Backup .zip round-trips names, order, filters, favorites and IDs")
    func backupRoundTrip() async throws {
        let tmp = TempDir()
        let (library, _) = makeLibrary(tmp.sub("store"))
        _ = library.importItems(at: [try makeProfileFolder(tmp)])
        library.rename(id: library.order[0], to: "Sala principal")
        let favorite = library.order[2]
        let zip = tmp.url.appendingPathComponent("backup.zip")
        try await library.exportBackup(to: zip, favoriteIDs: [favorite])
        #expect(FileManager.default.fileExists(atPath: zip.path))

        let (restored, manager) = makeLibrary(tmp.sub("other-mac"))
        let result = try await restored.importBackup(from: zip)
        #expect(result.summary.imported.count == 6)
        #expect(result.favoriteIDs == [favorite])
        #expect(restored.order == library.order)
        #expect(restored.profiles.map(\.name) == library.profiles.map(\.name))
        #expect(manager.profile(for: library.order[5])?.filters.count == 20)

        // Restoring again is a no-op.
        let again = try await restored.importBackup(from: zip)
        #expect(again.summary.imported.isEmpty)
        #expect(restored.profiles.count == 6)
    }

    @Test("Backup restore blocks prefix-sibling path traversal and sanitizes unsafe manifest IDs")
    func backupSecurityGuards() async throws {
        let tmp = TempDir()
        let backup = tmp.sub("backup")
        let sibling = tmp.sub("backup-secret")
        let secretFile = sibling.appendingPathComponent("secret.txt")
        try AutoEQTestSupport.fixtureText("1_Harman.txt").write(to: secretFile, atomically: true, encoding: .utf8)

        let profilesDir = backup.appendingPathComponent("profiles")
        try FileManager.default.createDirectory(at: profilesDir, withIntermediateDirectories: true)
        try AutoEQTestSupport.fixtureText("2_Harman_Grave_Extra.txt").write(
            to: profilesDir.appendingPathComponent("ok.txt"), atomically: true, encoding: .utf8)

        let manifest = """
        {
          "formatVersion": 1,
          "app": "FineTune",
          "exportedAt": "2026-01-01T00:00:00Z",
          "profiles": [
            {"id": "escaped", "name": "Escaped", "file": "../backup-secret/secret.txt", "favorite": false},
            {"id": "../../evil", "name": "Safe Content", "file": "profiles/ok.txt", "favorite": false}
          ]
        }
        """
        try manifest.write(to: backup.appendingPathComponent("library.json"), atomically: true, encoding: .utf8)

        let store = tmp.sub("store")
        let (library, _) = makeLibrary(store)
        let result = try await library.importBackup(from: backup)
        // Sibling traversal was blocked; valid profile imported with a safe generated UUID.
        #expect(result.summary.imported.count == 1)
        let imported = try #require(result.summary.imported.first)
        #expect(imported.name == "Safe Content")
        #expect(AutoEQProfileLoader.isSafeProfileID(imported.id))
        #expect(!imported.id.contains(".."))
        #expect(!FileManager.default.fileExists(atPath: tmp.url.appendingPathComponent("evil.txt").path))
    }

    @Test("Unreadable profile file on disk does not abort loading other imported profiles")
    func corruptFileDoesNotBreakLibraryLoad() throws {
        let tmp = TempDir()
        let store = tmp.sub("store")
        let loader = AutoEQProfileLoader(directory: store)
        try loader.saveProfile(id: "good-1", text: try AutoEQTestSupport.fixtureText("1_Harman.txt"), name: "Good")
        // Create a directory named `bad.txt` so reading it as Data throws.
        try FileManager.default.createDirectory(at: store.appendingPathComponent("bad.txt"), withIntermediateDirectories: true)

        let (library, _) = makeLibrary(store)
        #expect(library.profiles.map(\.name) == ["Good"])
    }
}

@MainActor
@Suite("AutoEQ assignment — fallback by device name")
struct AutoEQDeviceNameFallbackTests {

    @Test("Device key normalizes case and whitespace; empty name has no key")
    func keyNormalization() {
        #expect(AutoEQDeviceKey.make(name: " TTGK  USB Audio ", manufacturer: "TTGK") == "ttgk|ttgk usb audio")
        #expect(AutoEQDeviceKey.make(name: "TTGK USB Audio", manufacturer: nil) == "|ttgk usb audio")
        #expect(AutoEQDeviceKey.make(name: "  ", manufacturer: "x") == nil)
    }

    @Test("Same dongle on another USB port (new UID) keeps its profile")
    func newUIDResolvesByName() {
        let tmp = TempDir()
        let settings = SettingsManager(directory: tmp.url)
        let key = AutoEQDeviceKey.make(name: "TTGK USB Audio", manufacturer: "TTGK")
        let selection = AutoEQSelection(profileID: "harman", isEnabled: true)
        settings.setAutoEQSelection(for: "AppleUSBAudioEngine:TTGK:port1", deviceKey: key, to: selection)

        // Read-only lookup (UI) does not write.
        #expect(settings.resolveAutoEQSelection(for: "AppleUSBAudioEngine:TTGK:port2", deviceKey: key, persist: false) == selection)
        #expect(settings.getAutoEQSelection(for: "AppleUSBAudioEngine:TTGK:port2") == nil)

        // Playback lookup re-binds the new UID.
        #expect(settings.resolveAutoEQSelection(for: "AppleUSBAudioEngine:TTGK:port2", deviceKey: key) == selection)
        #expect(settings.getAutoEQSelection(for: "AppleUSBAudioEngine:TTGK:port2") == selection)

        // Survives a restart.
        settings.flushSync()
        let reloaded = SettingsManager(directory: tmp.url)
        #expect(reloaded.resolveAutoEQSelection(for: "AppleUSBAudioEngine:TTGK:port3", deviceKey: key) == selection)
    }

    @Test("Legacy UID-only assignments are mirrored into the name map when the device is seen")
    func legacyUIDBackfillsName() {
        let tmp = TempDir()
        let settings = SettingsManager(directory: tmp.url)
        let key = AutoEQDeviceKey.make(name: "TTGK USB Audio", manufacturer: "TTGK")
        let selection = AutoEQSelection(profileID: "bk", isEnabled: false)
        settings.setAutoEQSelection(for: "uid-old", to: selection)  // pre-v13 API: UID only

        #expect(settings.resolveAutoEQSelection(for: "uid-old", deviceKey: key) == selection)
        #expect(settings.resolveAutoEQSelection(for: "uid-new", deviceKey: key) == selection)
    }

    @Test("A different device with no assignment gets nothing")
    func unrelatedDevice() {
        let settings = SettingsManager(directory: TempDir().url)
        settings.setAutoEQSelection(for: "uid-a", deviceKey: "x|dongle", to: AutoEQSelection(profileID: "p", isEnabled: true))
        #expect(settings.resolveAutoEQSelection(for: "uid-b", deviceKey: "y|headphones") == nil)
    }

    @Test("Deleting a profile clears its UID and name assignments, favorite and A/B slot")
    func deleteClearsAssignments() {
        let settings = SettingsManager(directory: TempDir().url)
        settings.setAutoEQSelection(for: "uid-a", deviceKey: "x|dongle", to: AutoEQSelection(profileID: "p", isEnabled: true))
        settings.favoriteAutoEQProfile(id: "p")
        settings.autoEQAB = AutoEQABSettings(profileA: "p", profileB: "q")
        settings.removeAutoEQSelections(profileID: "p")
        #expect(settings.resolveAutoEQSelection(for: "uid-z", deviceKey: "x|dongle") == nil)
        #expect(settings.getAutoEQSelection(for: "uid-a") == nil)
        #expect(!settings.isAutoEQFavorite(id: "p"))
        #expect(settings.autoEQAB.profileA == nil)
        #expect(settings.autoEQAB.profileB == "q")
    }
}

@MainActor
@Suite("Settings migration v12 → v13")
struct SettingsMigrationV13Tests {

    static let v12JSON = """
    {
      "version": 12,
      "appVolumes": {"com.spotify.client": 0.8},
      "deviceAutoEQ": {
        "AppleUSBAudioEngine:TTGK:1": {"profileID": "harman-id", "isEnabled": true},
        "BuiltInHeadphones": {"profileID": "hd600", "isEnabled": false}
      },
      "favoriteAutoEQProfiles": ["harman-id"],
      "autoEQPreampEnabled": false
    }
    """

    @Test("Old file is backed up, version stamped 13, nothing lost")
    func migratesWithBackup() throws {
        let tmp = TempDir()
        let url = tmp.url.appendingPathComponent("settings.json")
        try Self.v12JSON.write(to: url, atomically: true, encoding: .utf8)

        let settings = SettingsManager(directory: tmp.url)
        #expect(settings.settingsVersion == 13)
        #expect(settings.getAutoEQSelection(for: "AppleUSBAudioEngine:TTGK:1") == AutoEQSelection(profileID: "harman-id", isEnabled: true))
        #expect(settings.getAutoEQSelection(for: "BuiltInHeadphones") == AutoEQSelection(profileID: "hd600", isEnabled: false))
        #expect(settings.isAutoEQFavorite(id: "harman-id"))
        #expect(settings.autoEQPreampEnabled == false)
        #expect(settings.getVolume(for: "com.spotify.client") == 0.8)
        #expect(settings.autoEQAB == AutoEQABSettings())

        let backup = SettingsMigration.backupURL(for: url, version: 12)
        #expect(try String(contentsOf: backup, encoding: .utf8) == Self.v12JSON)

        let onDisk = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        #expect(onDisk?["version"] as? Int == 13)
        #expect((onDisk?["deviceAutoEQ"] as? [String: Any])?.count == 2)
    }

    @Test("Existing backup is never overwritten; current-version files are not backed up")
    func backupIsWriteOnce() throws {
        let tmp = TempDir()
        let url = tmp.url.appendingPathComponent("settings.json")
        let backup = SettingsMigration.backupURL(for: url, version: 12)
        try "original".write(to: backup, atomically: true, encoding: .utf8)
        try Self.v12JSON.write(to: url, atomically: true, encoding: .utf8)
        _ = SettingsManager(directory: tmp.url)
        #expect(try String(contentsOf: backup, encoding: .utf8) == "original")

        // Second launch at v13: no v13 backup created.
        _ = SettingsManager(directory: tmp.url)
        #expect(!FileManager.default.fileExists(atPath: SettingsMigration.backupURL(for: url, version: 13).path))
    }

    @Test("v13 fields round-trip")
    func v13RoundTrip() throws {
        var s = SettingsManager.Settings()
        s.deviceAutoEQByName["ttgk|ttgk usb audio"] = AutoEQSelection(profileID: "p", isEnabled: true)
        s.autoEQAB = AutoEQABSettings(profileA: "p", profileB: "q", active: .b, levelMatch: false)
        let decoded = try JSONDecoder().decode(SettingsManager.Settings.self, from: JSONEncoder().encode(s))
        #expect(decoded.deviceAutoEQByName == s.deviceAutoEQByName)
        #expect(decoded.autoEQAB == s.autoEQAB)
    }
}

@MainActor
@Suite("A/B level matching")
struct AutoEQLevelMatchTests {

    func profile(_ text: String, id: String) throws -> AutoEQProfile {
        try #require(AutoEQParser.parse(text: text, name: id, source: .imported, id: id))
    }

    @Test("Identical curves need no trim")
    func identical() throws {
        let a = try profile("Filter 1: ON PK Fc 1000 Hz Gain 3 dB Q 1", id: "a")
        let b = try profile("Filter 1: ON PK Fc 1000 Hz Gain 3 dB Q 1", id: "b")
        let (ta, tb) = AutoEQLoudness.levelMatchTrims(a: a, b: b, includePreamp: true)
        #expect(abs(ta) < 1e-4 && abs(tb) < 1e-4)
    }

    @Test("A broadband +6 dB difference is matched by attenuating the louder profile by ~6 dB")
    func broadbandOffset() throws {
        let quiet = try profile("Preamp: -6 dB\nFilter 1: ON PK Fc 1000 Hz Gain 0.1 dB Q 1", id: "q")
        let loud = try profile("Preamp: 0 dB\nFilter 1: ON PK Fc 1000 Hz Gain 0.1 dB Q 1", id: "l")
        let (tq, tl) = AutoEQLoudness.levelMatchTrims(a: quiet, b: loud, includePreamp: true)
        #expect(tq == 0)
        #expect(abs(tl + 6) < 0.01)
        // Without the preamp the curves are equal.
        let (nq, nl) = AutoEQLoudness.levelMatchTrims(a: quiet, b: loud, includePreamp: false)
        #expect(abs(nq) < 1e-4 && abs(nl) < 1e-4)
    }

    @Test("K-weighting: a sub-bass boost counts less than a presence boost")
    func kWeighting() throws {
        let sub = try profile("Filter 1: ON PK Fc 40 Hz Gain 6 dB Q 1", id: "s")
        let presence = try profile("Filter 1: ON PK Fc 3000 Hz Gain 6 dB Q 1", id: "p")
        #expect(AutoEQLoudness.estimatedGainDB(of: presence, includePreamp: true)
                > AutoEQLoudness.estimatedGainDB(of: sub, includePreamp: true))
    }

    @Test("User profiles: Harman vs Harman Grave Extra produces a finite, non-positive trim pair")
    func userProfiles() throws {
        let a = try profile(try AutoEQTestSupport.fixtureText("1_Harman.txt"), id: "a")
        let b = try profile(try AutoEQTestSupport.fixtureText("2_Harman_Grave_Extra.txt"), id: "b")
        let (ta, tb) = AutoEQLoudness.levelMatchTrims(a: a, b: b, includePreamp: true)
        #expect(ta <= 0 && tb <= 0 && ta.isFinite && tb.isFinite)
        #expect(min(ta, tb) == 0 || max(ta, tb) == 0)
    }

    @Test("Processor applies the level trim even with the preamp bypassed")
    func trimAppliedWithoutPreamp() throws {
        var p = try profile("Preamp: -6 dB\nFilter 1: ON PK Fc 100 Hz Gain 0.1 dB Q 1", id: "t")
        p.levelTrimDB = -3
        #expect(p.validated().levelTrimDB == -3)
        p.levelTrimDB = 5  // never boosts
        #expect(p.validated().levelTrimDB == 0)
    }

    @Test("validated() drops non-finite filter parameters and zeroes NaN preamp instead of clamping to +30 dB")
    func validatedRejectsNonFinite() {
        let bad = AutoEQProfile(
            id: "bad",
            name: "Bad",
            source: .imported,
            preampDB: .nan,
            filters: [
                AutoEQFilter(type: .peaking, frequency: .infinity, gainDB: 3, q: 1),
                AutoEQFilter(type: .peaking, frequency: 1000, gainDB: 3, q: .infinity),
                AutoEQFilter(type: .peaking, frequency: 1000, gainDB: 2, q: 1.4)
            ],
            optimizedSampleRate: nil
        )
        let validated = bad.validated()
        #expect(validated.preampDB == 0)
        #expect(validated.filters.count == 1)
        #expect(validated.filters[0].frequency == 1000 && validated.filters[0].q == 1.4)
    }

    @Test("A/B toggle follows actual active profile, ignores disabled correction, and prevents A == B")
    func abToggleAndStateSemantics() throws {
        let tmp = TempDir()
        let settings = SettingsManager(directory: tmp.sub("settings"))
        let loader = AutoEQProfileLoader(directory: tmp.sub("autoeq"))
        try loader.saveProfile(id: "prof-a", text: try AutoEQTestSupport.fixtureText("1_Harman.txt"), name: "A")
        try loader.saveProfile(id: "prof-b", text: try AutoEQTestSupport.fixtureText("2_Harman_Grave_Extra.txt"), name: "B")
        let profileManager = AutoEQProfileManager(loader: loader)

        let deviceMonitor = MockAudioDeviceMonitor()
        let device = AudioDevice(id: AudioDeviceID(42), uid: "uid-dac", name: "USB DAC", icon: nil, supportsAutoEQ: true)
        deviceMonitor.addOutputDevice(device)
        let volumeMonitor = MockDeviceVolumeProviding(deviceMonitor: deviceMonitor)
        volumeMonitor.defaultDeviceUID = device.uid

        let engine = AudioEngine(
            permission: AudioRecordingPermission(),
            settingsManager: settings,
            autoEQProfileManager: profileManager,
            deviceProvider: deviceMonitor,
            processMonitor: StubProcessMonitor(),
            deviceVolumeMonitor: volumeMonitor,
            startMonitorsAutomatically: false
        )

        // Setting the same profile to both slots clears the opposite slot and stays unconfigured.
        engine.setAutoEQABProfile("prof-a", slot: .a)
        engine.setAutoEQABProfile("prof-a", slot: .b)
        #expect(!engine.autoEQAB.isConfigured)
        #expect(engine.autoEQAB.profileA == nil)
        #expect(engine.autoEQAB.profileB == "prof-a")

        // Configure distinct A and B.
        engine.setAutoEQABProfile("prof-a", slot: .a)
        engine.setAutoEQABProfile("prof-b", slot: .b)
        #expect(engine.autoEQAB.isConfigured)

        // Start A/B -> activates A.
        #expect(engine.toggleAutoEQAB() == .a)
        #expect(engine.activeAutoEQProfile?.id == "prof-a")
        #expect(engine.activeAutoEQABSlot == .a)

        // User manually switches to B (ab.active is still .a internally): next toggle must go straight to A!
        engine.selectAutoEQProfileForActiveDevice("prof-b")
        #expect(engine.activeAutoEQABSlot == .b)
        #expect(engine.toggleAutoEQAB() == .a)
        #expect(engine.activeAutoEQProfile?.id == "prof-a")

        // Disabling correction clears activeAutoEQABSlot, and toggling A/B re-enables slot A.
        engine.setAutoEQEnabled(for: device.uid, enabled: false)
        #expect(engine.activeAutoEQABSlot == nil)
        #expect(engine.toggleAutoEQAB() == .a)
        #expect(engine.isActiveAutoEQEnabled)
        #expect(engine.activeAutoEQProfile?.id == "prof-a")
    }
}
