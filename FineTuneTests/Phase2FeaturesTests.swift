// FineTuneTests/Phase2FeaturesTests.swift
import AppKit
import AudioToolbox
import Foundation
import Testing
@testable import FineTune

@Suite("Phase 2 — Global Parametric EQ, Frequency Response Graph & Menu Bar Meter")
@MainActor
struct Phase2FeaturesTests {

    // MARK: - DeviceParametricEQ Model & Export

    @Test("DeviceParametricEQ exports valid Equalizer APO text that round-trips through AutoEQParser")
    func exportRoundTrip() throws {
        var eq = DeviceParametricEQ(
            isEnabled: true,
            preampDB: -3.5,
            bands: [
                ParametricEQBand(type: .lowShelf, frequency: 80, gainDB: 4.0, q: 0.71),
                ParametricEQBand(type: .peaking, frequency: 1200, gainDB: -2.5, q: 2.0),
                ParametricEQBand(isEnabled: false, type: .highShelf, frequency: 10000, gainDB: 3.0, q: 0.71)
            ]
        )
        let text = eq.exportParametricEQText()
        let report = AutoEQParser.parseReport(text: text, name: "Exported", source: .imported)
        let parsed = try #require(report.profile)
        #expect(report.error == nil)
        #expect(report.warnings.isEmpty)
        #expect(abs(parsed.preampDB - (-3.5)) < 0.05)
        // Band 3 is OFF so parser keeps 2 enabled filters.
        #expect(parsed.filters.count == 2)
        #expect(parsed.filters[0].type == .lowShelf)
        #expect(parsed.filters[1].type == .peaking)

        eq.resetFlat()
        #expect(!eq.isEffectivelyActive)
    }

    @Test("combinedProfile merges AutoEQ + DeviceParametricEQ and respects 64-filter ceiling")
    func combinedProfileMergeAndCeiling() throws {
        let baseFilters = (0..<60).map { i in
            AutoEQFilter(type: .peaking, frequency: 50 + Double(i) * 100, gainDB: 1.0, q: 2.0)
        }
        var base = AutoEQProfile(
            id: "base", name: "HD 600", source: .imported,
            preampDB: -4.0, filters: baseFilters, optimizedSampleRate: nil
        )
        base.levelTrimDB = -1.5

        let peqBands = (0..<6).map { i in
            ParametricEQBand(type: .peaking, frequency: 100 + Double(i) * 500, gainDB: 2.0, q: 1.0)
        }
        let peq = DeviceParametricEQ(isEnabled: true, preampDB: -2.0, bands: peqBands)

        let combined = try #require(DeviceParametricEQ.combinedProfile(
            deviceUID: "uid-1", baseAutoEQ: base, parametricEQ: peq
        ))
        #expect(combined.filters.count == AutoEQProfile.maxFilters)
        // Base AutoEQ preamp stays in `preampDB`; PEQ preamp lives in `fixedPreampDB`
        // so bypassing AutoEQ preamp never disables the user's PEQ preamp.
        #expect(combined.preampDB == -4.0)
        #expect(combined.fixedPreampDB == -2.0)
        #expect(combined.levelTrimDB == -1.5)

        // Graph evaluation reports the exact same 2 dropped PEQ bands.
        let curves = FrequencyResponseCurve.evaluateDeviceCurves(baseAutoEQ: base, parametricEQ: peq)
        #expect(curves.droppedBandCount == 2)

        // Works standalone without AutoEQ (e.g. speakers / HDMI monitor)
        let standalone = try #require(DeviceParametricEQ.combinedProfile(
            deviceUID: "uid-spk", baseAutoEQ: nil, parametricEQ: peq
        ))
        #expect(standalone.filters.count == 6)
        #expect(standalone.preampDB == 0.0)
        #expect(standalone.fixedPreampDB == -2.0)
    }

    @Test("AutoEQProcessor keeps Device PEQ fixedPreampDB active even when AutoEQ preamp is bypassed")
    func peqPreampSurvivesAutoEQPreampBypass() throws {
        let peq = DeviceParametricEQ(
            isEnabled: true,
            preampDB: -6.0,
            bands: [ParametricEQBand(type: .peaking, frequency: 1000, gainDB: 0.1, q: 1.0)]
        )
        let combined = try #require(DeviceParametricEQ.combinedProfile(
            deviceUID: "uid-spk", baseAutoEQ: nil, parametricEQ: peq
        ))

        let processor = AutoEQProcessor(sampleRate: 48_000)
        processor.setPreampEnabled(false)  // AutoEQ preamp OFF
        processor.updateProfile(combined)

        // Process 1 kHz sine and verify ~-6 dB attenuation still applied
        let frames = 24_000
        var buf = [Float](repeating: 0, count: frames * 2)
        for i in 0..<frames {
            let s: Float = 0.5 * Float(sin(2 * Double.pi * 1000.0 * Double(i) / 48_000.0))
            buf[i * 2] = s
            buf[i * 2 + 1] = s
        }
        buf.withUnsafeMutableBufferPointer { ptr in
            processor.process(input: UnsafePointer(ptr.baseAddress!), output: ptr.baseAddress!, frameCount: frames)
        }
        let steady = buf[(frames)...]
        let rms = sqrt(steady.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(steady.count))
        let gainDB = 20 * log10(rms / (0.5 / 2.0.squareRoot()))
        #expect(abs(gainDB - (-5.9)) < 0.25, "expected ~-5.9 dB, got \(gainDB)")
    }

    @Test("Custom 0 dB band layout is preserved on save and single corrupt band does not wipe PEQ")
    func customZeroGainBandsAndLossyBandDecode() throws {
        var custom = DeviceParametricEQ.default
        custom.bands[0].frequency = 65
        custom.addBand()
        #expect(!custom.isDefaultFlat)

        let json = """
        {
          "isEnabled": true,
          "preampDB": -1.5,
          "bands": [
            {"type": "lowShelf", "frequency": 75, "gainDB": 3.0, "q": 0.71},
            {"type": "corrupt-type", "frequency": "bad"},
            {"type": "highShelf", "frequency": 9000, "gainDB": -2.0, "q": 0.71}
          ]
        }
        """
        let decoded = try JSONDecoder().decode(DeviceParametricEQ.self, from: Data(json.utf8))
        #expect(decoded.isEnabled == true)
        #expect(decoded.preampDB == -1.5)
        #expect(decoded.bands.count == 2)
        #expect(decoded.bands[0].frequency == 75)
        #expect(decoded.bands[1].frequency == 9000)
    }

    @Test("Menu bar scroll-wheel delta drops trackpad inertia, scales trackpad gently, and caps spikes")
    func menuBarScrollSafety() {
        // Momentum tail after flick must produce zero change.
        let tail = MenuBarIconCoordinator.scrollVolumeDelta(
            deltaY: 40, hasPreciseDeltas: true, isDirectionInverted: false,
            isMomentumTail: true, discreteStep: 1.0 / 16.0
        )
        #expect(tail == 0.0)

        // Small trackpad pixel delta moves gently (~0.5%), never jumping by full hotkey step.
        let gentle = MenuBarIconCoordinator.scrollVolumeDelta(
            deltaY: 2.0, hasPreciseDeltas: true, isDirectionInverted: false,
            isMomentumTail: false, discreteStep: 1.0 / 16.0
        )
        #expect(gentle > 0 && gentle < 0.01)

        // Huge single-event spike is capped at ±6%.
        let spike = MenuBarIconCoordinator.scrollVolumeDelta(
            deltaY: 500.0, hasPreciseDeltas: true, isDirectionInverted: false,
            isMomentumTail: false, discreteStep: 1.0 / 16.0
        )
        #expect(abs(spike - 0.06) < 1e-6)
    }

    @Test("Menu bar quick controls hit-test status item globally and match Option-click or middle-click only")
    func menuBarQuickControlHitTestAndMuteMatching() {
        let frame = NSRect(x: 900, y: 1416, width: 72, height: 24)
        // Background app active: eventWindowMatchesButton is false, global mouse inside frame matches.
        #expect(MenuBarIconCoordinator.isPointerOverStatusItem(
            mouseLocation: NSPoint(x: 930, y: 1428),
            buttonWindowFrame: frame,
            eventWindowMatchesButton: false
        ))
        // Mouse outside frame and non-matching window does not match.
        #expect(!MenuBarIconCoordinator.isPointerOverStatusItem(
            mouseLocation: NSPoint(x: 400, y: 800),
            buttonWindowFrame: frame,
            eventWindowMatchesButton: false
        ))
        // Direct status item window match always matches.
        #expect(MenuBarIconCoordinator.isPointerOverStatusItem(
            mouseLocation: .zero,
            buttonWindowFrame: frame,
            eventWindowMatchesButton: true
        ))

        // Option+left-click toggles mute; plain left-click and Cmd+Option+left-click do not.
        #expect(MenuBarIconCoordinator.shouldToggleMute(eventType: .leftMouseDown, buttonNumber: 0, modifierFlags: [.option]))
        #expect(!MenuBarIconCoordinator.shouldToggleMute(eventType: .leftMouseDown, buttonNumber: 0, modifierFlags: []))
        #expect(!MenuBarIconCoordinator.shouldToggleMute(eventType: .leftMouseDown, buttonNumber: 0, modifierFlags: [.option, .command]))

        // Middle-click (button 2) toggles mute; side buttons (3/4) do not.
        #expect(MenuBarIconCoordinator.shouldToggleMute(eventType: .otherMouseDown, buttonNumber: 2, modifierFlags: []))
        #expect(!MenuBarIconCoordinator.shouldToggleMute(eventType: .otherMouseDown, buttonNumber: 3, modifierFlags: []))
    }

    @Test("Quick Config applies PEQ to taps even for a device that only has PEQ (no volume entry)")
    func quickConfigAppliesPEQOnlyDevice() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("FineTunePhase2-HDMI-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let settings = SettingsManager(directory: dir)
        let deviceMonitor = MockAudioDeviceMonitor()
        let hdmi = AudioDevice(id: AudioDeviceID(88), uid: "uid-hdmi", name: "HDMI Monitor", icon: nil, supportsAutoEQ: false)
        deviceMonitor.addOutputDevice(hdmi)
        let volumeMonitor = MockDeviceVolumeProviding(deviceMonitor: deviceMonitor)
        volumeMonitor.defaultDeviceID = hdmi.id
        volumeMonitor.defaultDeviceUID = hdmi.uid

        let app = AudioApp(id: 501, processObjectIDs: [], name: "Music", icon: NSImage(), bundleID: "com.apple.Music")
        let processMonitor = StubProcessMonitor()
        processMonitor.activeApps = [app]
        let permission = AudioRecordingPermission()
        permission.status = .authorized

        var createdTap: RecordingProcessTapController?
        let engine = AudioEngine(
            permission: permission,
            settingsManager: settings,
            autoEQProfileManager: AutoEQProfileManager(loader: AutoEQProfileLoader(directory: dir.appendingPathComponent("eq"))),
            deviceProvider: deviceMonitor,
            processMonitor: processMonitor,
            deviceVolumeMonitor: volumeMonitor,
            tapFactory: { app, uids, _ in
                let tap = RecordingProcessTapController(app: app, deviceUIDs: uids)
                createdTap = tap
                return tap
            },
            startMonitorsAutomatically: false
        )
        engine.setDevice(for: app, deviceUID: hdmi.uid)

        // Save a scene that has ONLY deviceParametricEQ for HDMI (no deviceVolumes entry!)
        let peq = DeviceParametricEQ(
            isEnabled: true, preampDB: -2.0,
            bands: [ParametricEQBand(type: .lowShelf, frequency: 80, gainDB: 3.0, q: 0.71)]
        )
        let scene = AudioScene(name: "HDMI PEQ", deviceParametricEQ: [hdmi.uid: peq])
        settings.saveAudioScene(scene)

        engine.applyQuickConfig(id: scene.id)

        let tap = try #require(createdTap)
        let appliedPEQ = tap.events.contains { event in
            if case .updateAutoEQProfile(let profileID) = event {
                return profileID == "device-peq-\(hdmi.uid)"
            }
            return false
        }
        #expect(appliedPEQ)
    }

    // MARK: - Frequency Response Curve Math

    @Test("Log-frequency X axis mapping is an exact bijection across 20 Hz – 20 kHz")
    func logAxisBijection() {
        for freq in [20.0, 50.0, 100.0, 440.0, 1000.0, 4000.0, 12000.0, 20000.0] {
            let x = FrequencyResponseCurve.normalizedX(forFrequency: freq)
            let back = FrequencyResponseCurve.frequency(forNormalizedX: x)
            #expect(abs(back - freq) / freq < 1e-6)
        }
    }

    @Test("Evaluated frequency response matches analytical peaking gain at Fc and sums AutoEQ + PEQ")
    func responseEvaluationAndSumming() throws {
        let base = AutoEQProfile(
            id: "b", name: "Base", source: .imported, preampDB: 0,
            filters: [AutoEQFilter(type: .peaking, frequency: 1000, gainDB: 4.0, q: 1.5)],
            optimizedSampleRate: nil
        )
        let peq = DeviceParametricEQ(
            isEnabled: true, preampDB: 0,
            bands: [ParametricEQBand(type: .peaking, frequency: 1000, gainDB: -1.5, q: 1.5)]
        )
        let curves = FrequencyResponseCurve.evaluateDeviceCurves(
            baseAutoEQ: base, parametricEQ: peq, pointCount: 201
        )
        let baseCurve = try #require(curves.base)
        // Find point closest to 1 kHz
        let near1k = try #require(curves.combined.min(by: { abs($0.frequency - 1000) < abs($1.frequency - 1000) }))
        let base1k = try #require(baseCurve.min(by: { abs($0.frequency - 1000) < abs($1.frequency - 1000) }))
        #expect(abs(base1k.magnitudeDB - 4.0) < 0.1)
        #expect(abs(near1k.magnitudeDB - 2.5) < 0.1)
    }

    // MARK: - Menu Bar Live Level Meter Image

    @Test("nsImageWithMeter uses fixed canvas size and switches template mode when active")
    func menuBarMeterImage() throws {
        let icon = MenuBarIconImage.systemSymbol("speaker.wave.2.fill")
        let silent = try #require(icon.nsImageWithMeter(level: 0.0, muted: false))
        #expect(silent.size == MenuBarIconImage.meterCanvasSize)
        #expect(silent.isTemplate == true)

        let muted = try #require(icon.nsImageWithMeter(level: 0.9, muted: true))
        #expect(muted.size == MenuBarIconImage.meterCanvasSize)
        #expect(muted.isTemplate == true)

        let playing = try #require(icon.nsImageWithMeter(level: 0.6, muted: false))
        #expect(playing.size == MenuBarIconImage.meterCanvasSize)
        #expect(playing.isTemplate == false)
    }

    // MARK: - Settings Persistence

    @Test("DeviceParametricEQ and menu bar meter settings persist cleanly")
    func persistenceRoundTrip() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("FineTunePhase2-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }

        let settings = SettingsManager(directory: dir)
        #expect(settings.appSettings.menuBarQuickControlsEnabled == false)
        settings.appSettings.showMenuBarMeter = true
        settings.appSettings.showMenuBarVolumeLabel = true
        settings.appSettings.menuBarQuickControlsEnabled = true
        let peq = DeviceParametricEQ(
            isEnabled: true,
            preampDB: -2.0,
            bands: [ParametricEQBand(type: .lowShelf, frequency: 90, gainDB: 3.5, q: 0.71)]
        )
        settings.setDeviceParametricEQ(for: "uid-speakers", to: peq)
        settings.flushSync()

        let reloaded = SettingsManager(directory: dir)
        #expect(reloaded.appSettings.showMenuBarMeter == true)
        #expect(reloaded.appSettings.showMenuBarVolumeLabel == true)
        #expect(reloaded.appSettings.menuBarQuickControlsEnabled == true)
        #expect(reloaded.getDeviceParametricEQ(for: "uid-speakers") == peq)
    }

    @Test("BalanceSliderRow formats centered, left, and right labels and compact badges")
    func balanceSliderRowFormatting() {
        #expect(BalanceSliderRow.label(for: 0.0) == "Center")
        #expect(BalanceSliderRow.label(for: -0.35) == "L 35%")
        #expect(BalanceSliderRow.label(for: 0.2) == "R 20%")
        #expect(BalanceSliderRow.compactBadge(for: 0.0) == nil)
        #expect(BalanceSliderRow.compactBadge(for: -0.35) == "L35")
        #expect(BalanceSliderRow.compactBadge(for: 0.2) == "R20")
    }
}
