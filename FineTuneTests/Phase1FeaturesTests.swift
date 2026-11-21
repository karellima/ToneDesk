// FineTuneTests/Phase1FeaturesTests.swift
import AppKit
import AudioToolbox
import Foundation
import Testing
@testable import FineTune

@Suite("Phase 1 — Stereo Processing, Max Volume Limit, BT Output-Only & Quick Configs")
@MainActor
struct Phase1FeaturesTests {

    // MARK: - Stereo Processing DSP (RT-safe)

    @Test("channelGains follows non-boosting macOS balance law")
    func channelGainsLaw() {
        let center = DeviceAudioProcessingSettings.channelGains(balance: 0)
        #expect(center.left == 1.0 && center.right == 1.0)

        let left = DeviceAudioProcessingSettings.channelGains(balance: -0.5)
        #expect(left.left == 1.0 && abs(left.right - 0.5) < 1e-5)

        let right = DeviceAudioProcessingSettings.channelGains(balance: 0.75)
        #expect(abs(right.left - 0.25) < 1e-5 && right.right == 1.0)

        let hardLeft = DeviceAudioProcessingSettings.channelGains(balance: -1.0)
        #expect(hardLeft.left == 1.0 && hardLeft.right == 0.0)
    }

    @Test("applyStereoProcessing swaps L/R, sums mono, then applies L/R balance")
    func stereoProcessingDSPOrder() {
        // Stereo interleaved 2 frames: (L=1.0, R=0.2), (L=-0.4, R=0.8)
        var swapBuf: [Float] = [1.0, 0.2, -0.4, 0.8]
        swapBuf.withUnsafeMutableBufferPointer { ptr in
            ProcessTapController.applyStereoProcessing(
                buffer: ptr.baseAddress!, frameCount: 2, channelCount: 2,
                leftChannel: 0, rightChannel: 1,
                swapChannels: true, isMono: false, leftGain: 1.0, rightGain: 1.0
            )
        }
        #expect(swapBuf == [0.2, 1.0, 0.8, -0.4])

        // Mono + hard-left balance: (1.0 + 0.2)/2 = 0.6 on L, 0.0 on R
        var monoBalBuf: [Float] = [1.0, 0.2, -0.4, 0.8]
        monoBalBuf.withUnsafeMutableBufferPointer { ptr in
            ProcessTapController.applyStereoProcessing(
                buffer: ptr.baseAddress!, frameCount: 2, channelCount: 2,
                leftChannel: 0, rightChannel: 1,
                swapChannels: false, isMono: true, leftGain: 1.0, rightGain: 0.0
            )
        }
        #expect(abs(monoBalBuf[0] - 0.6) < 1e-5 && monoBalBuf[1] == 0.0)
        #expect(abs(monoBalBuf[2] - 0.2) < 1e-5 && monoBalBuf[3] == 0.0)
    }

    @Test("DeviceAudioProcessingSettings active badges reflect only non-default controls")
    func activeBadges() {
        #expect(DeviceAudioProcessingSettings.default.activeBadges.isEmpty)
        let custom = DeviceAudioProcessingSettings(
            balance: -0.35, isMono: true, swapChannels: true,
            maxVolumeLimit: 0.7, bluetoothOutputOnly: true
        )
        #expect(custom.activeBadges == ["MONO", "L⇄R", "L35", "≤70%", "A2DP"])
    }

    // MARK: - Persistence & Clamping

    @Test("Device processing, per-app balance and Quick Configs round-trip through SettingsManager")
    func settingsPersistenceRoundTrip() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("FineTunePhase1-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }

        let settings = SettingsManager(directory: dir)
        let proc = DeviceAudioProcessingSettings(balance: 0.4, isMono: true, swapChannels: false, maxVolumeLimit: 0.65, bluetoothOutputOnly: true)
        settings.setDeviceAudioProcessing(for: "uid-dac", to: proc)
        settings.setAppBalance(for: "com.spotify.client", to: -0.25)

        let scene = AudioScene(name: "Night Mode", icon: "moon.stars", defaultOutputUID: "uid-dac", loudnessCompensationEnabled: true)
        settings.saveAudioScene(scene)
        settings.activeAudioSceneID = scene.id
        settings.flushSync()

        let reloaded = SettingsManager(directory: dir)
        #expect(reloaded.getDeviceAudioProcessing(for: "uid-dac") == proc)
        #expect(abs(reloaded.getAppBalance(for: "com.spotify.client") - (-0.25)) < 1e-5)
        #expect(reloaded.audioScenes.count == 1)
        #expect(reloaded.audioScenes[0].name == "Night Mode")
        #expect(reloaded.activeAudioSceneID == scene.id)
    }

    // MARK: - Max Volume Limit & Quick Configs in AudioEngine

    @Test("Setting a max volume limit clamps current device volume immediately")
    func maxVolumeLimitClampsCurrentVolume() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("FineTunePhase1-Max-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let settings = SettingsManager(directory: dir)
        let deviceMonitor = MockAudioDeviceMonitor()
        let device = AudioDevice(id: AudioDeviceID(77), uid: "uid-iem", name: "IEM DAC", icon: nil, supportsAutoEQ: true)
        deviceMonitor.addOutputDevice(device)
        let volumeMonitor = MockDeviceVolumeProviding(deviceMonitor: deviceMonitor)
        volumeMonitor.volumes[device.id] = 0.90

        let engine = AudioEngine(
            permission: AudioRecordingPermission(),
            settingsManager: settings,
            autoEQProfileManager: AutoEQProfileManager(loader: AutoEQProfileLoader(directory: dir.appendingPathComponent("eq"))),
            deviceProvider: deviceMonitor,
            processMonitor: StubProcessMonitor(),
            deviceVolumeMonitor: volumeMonitor,
            startMonitorsAutomatically: false
        )

        var proc = DeviceAudioProcessingSettings.default
        proc.maxVolumeLimit = 0.50
        engine.setDeviceAudioProcessing(for: device.uid, to: proc)

        // MockDeviceVolumeProviding defaults to hardware tier (identity mapping), so volume clamps to 0.50.
        #expect((volumeMonitor.volumes[device.id] ?? 1.0) <= 0.501)
    }

    @Test("Quick Config captures, restores, and cycles scenes cleanly")
    func quickConfigsCaptureApplyCycle() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("FineTunePhase1-Scene-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let settings = SettingsManager(directory: dir)
        let deviceMonitor = MockAudioDeviceMonitor()
        let dac = AudioDevice(id: AudioDeviceID(10), uid: "uid-dac", name: "USB DAC", icon: nil, supportsAutoEQ: true)
        let speakers = AudioDevice(id: AudioDeviceID(11), uid: "uid-spk", name: "Speakers", icon: nil, supportsAutoEQ: false)
        deviceMonitor.addOutputDevice(dac)
        deviceMonitor.addOutputDevice(speakers)
        let volumeMonitor = MockDeviceVolumeProviding(deviceMonitor: deviceMonitor)
        volumeMonitor.defaultDeviceID = dac.id
        volumeMonitor.defaultDeviceUID = dac.uid
        volumeMonitor.volumes[dac.id] = 0.6

        let engine = AudioEngine(
            permission: AudioRecordingPermission(),
            settingsManager: settings,
            autoEQProfileManager: AutoEQProfileManager(loader: AutoEQProfileLoader(directory: dir.appendingPathComponent("eq"))),
            deviceProvider: deviceMonitor,
            processMonitor: StubProcessMonitor(),
            deviceVolumeMonitor: volumeMonitor,
            startMonitorsAutomatically: false
        )

        engine.setDeviceAudioProcessing(for: dac.uid, to: DeviceAudioProcessingSettings(isMono: true))
        let music = try #require(engine.saveQuickConfig(name: "Music", icon: "headphones"))

        // Change state and save second scene
        engine.setDeviceAudioProcessing(for: dac.uid, to: .default)
        volumeMonitor.volumes[dac.id] = 0.25
        let night = try #require(engine.saveQuickConfig(name: "Night", icon: "moon.stars"))

        // Apply "Music" — mono and volume restore
        engine.applyQuickConfig(id: music.id)
        #expect(engine.activeQuickConfigID == music.id)
        #expect(engine.getDeviceAudioProcessing(for: dac.uid).isMono == true)
        #expect(abs((volumeMonitor.volumes[dac.id] ?? 0) - 0.6) < 0.01)

        // Cycle advances Music -> Night -> Music
        #expect(engine.cycleQuickConfig()?.id == night.id)
        #expect(engine.getDeviceAudioProcessing(for: dac.uid).isMono == false)
        #expect(engine.cycleQuickConfig()?.id == music.id)
    }

    // MARK: - Pinned Popup Window Controller

    @Test("PinnedPopupWindowController suppresses resignKey dismissal while pinned and restores delegate on unpin")
    func pinnedPopupSwallowsResignKey() {
        final class SpyDelegate: NSObject, NSWindowDelegate {
            var resignKeyCalls = 0
            func windowDidResignKey(_ notification: Notification) { resignKeyCalls += 1 }
        }

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.borderless], backing: .buffered, defer: false)
        let spy = SpyDelegate()
        window.delegate = spy

        let controller = PinnedPopupWindowController.shared
        controller.unpin()

        controller.pin(window)
        #expect(controller.isPinned)
        #expect(window.level == .floating)
        #expect(window.isMovableByWindowBackground)

        // Resign key is swallowed while pinned
        controller.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification, object: window))
        #expect(spy.resignKeyCalls == 0)

        // Unpin restores original delegate and behavior
        controller.unpin()
        #expect(!controller.isPinned)
        #expect(window.delegate === spy)
        #expect(!window.isMovableByWindowBackground)
    }

    @Test("PinnedPopupWindowController automatically unpins when FluidMenuBarExtra hides window via orderOut")
    func pinnedPopupUnpinsOnOrderOut() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.borderless], backing: .buffered, defer: false)
        window.orderFront(nil)

        let controller = PinnedPopupWindowController.shared
        controller.unpin()
        var callbackStates: [Bool] = []
        controller.onPinStateChanged = { callbackStates.append($0) }
        defer { controller.onPinStateChanged = nil }

        controller.pin(window)
        #expect(controller.isPinned)

        // Simulate FluidMenuBarExtra dismissing the panel via orderOut(nil)
        window.orderOut(nil)
        #expect(!controller.isPinned)
        #expect(callbackStates == [true, false])
    }

    @Test("Malformed Quick Config or device processing entry does not wipe valid siblings on decode")
    func lossyDecodingPreservesValidEntries() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("FineTunePhase1-Lossy-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let json = """
        {
          "version": 13,
          "audioScenes": [
            {"id": "11111111-1111-1111-1111-111111111111", "name": "Valid Scene"},
            {"broken": true}
          ],
          "deviceAudioProcessing": {
            "uid-good": {"balance": -0.2, "isMono": true},
            "uid-bad": "not-an-object"
          },
          "appBalances": {
            "com.good.app": 0.5,
            "com.bad.app": "invalid"
          }
        }
        """
        try json.write(to: dir.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)

        let settings = SettingsManager(directory: dir)
        #expect(settings.audioScenes.count == 1)
        #expect(settings.audioScenes.first?.name == "Valid Scene")
        #expect(settings.getDeviceAudioProcessing(for: "uid-good").isMono == true)
        #expect(abs(settings.getAppBalance(for: "com.good.app") - 0.5) < 1e-5)
    }

    @Test("applyQuickConfig preserves AutoEQ of unrelated devices not captured in the scene")
    func quickConfigPreservesUnrelatedDevices() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("FineTunePhase1-Preserve-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let settings = SettingsManager(directory: dir)
        let deviceMonitor = MockAudioDeviceMonitor()
        let dacA = AudioDevice(id: AudioDeviceID(10), uid: "uid-a", name: "DAC A", icon: nil, supportsAutoEQ: true)
        deviceMonitor.addOutputDevice(dacA)
        let volumeMonitor = MockDeviceVolumeProviding(deviceMonitor: deviceMonitor)
        volumeMonitor.defaultDeviceID = dacA.id
        volumeMonitor.defaultDeviceUID = dacA.uid
        volumeMonitor.volumes[dacA.id] = 0.7

        let engine = AudioEngine(
            permission: AudioRecordingPermission(),
            settingsManager: settings,
            autoEQProfileManager: AutoEQProfileManager(loader: AutoEQProfileLoader(directory: dir.appendingPathComponent("eq"))),
            deviceProvider: deviceMonitor,
            processMonitor: StubProcessMonitor(),
            deviceVolumeMonitor: volumeMonitor,
            startMonitorsAutomatically: false
        )

        // Save scene while only DAC A is connected
        let scene = try #require(engine.saveQuickConfig(name: "Desk"))

        // Later connect DAC B and assign an AutoEQ profile to it
        let dacB = AudioDevice(id: AudioDeviceID(11), uid: "uid-b", name: "DAC B", icon: nil, supportsAutoEQ: true)
        deviceMonitor.addOutputDevice(dacB)
        engine.setAutoEQProfile(for: dacB.uid, profileID: "harman")
        #expect(engine.getAutoEQSelection(for: dacB.uid)?.profileID == "harman")

        // Applying "Desk" must NOT wipe DAC B's AutoEQ assignment
        engine.applyQuickConfig(id: scene.id)
        #expect(engine.getAutoEQSelection(for: dacB.uid)?.profileID == "harman")
    }
}
