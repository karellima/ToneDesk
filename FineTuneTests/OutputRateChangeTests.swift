// FineTuneTests/OutputRateChangeTests.swift
import Foundation
import Testing
@testable import FineTune

/// Rate-change handling for non-Bluetooth outputs (USB DACs re-rated while playing,
/// upstream issues #395 and #463).
@Suite("Output rate-change detection (USB DACs)")
struct OutputRateChangeTests {

    @Test("Typical DAC rate switches are detected",
          arguments: [(44_100.0, 96_000.0), (96_000.0, 44_100.0), (48_000.0, 192_000.0), (88_200.0, 48_000.0)])
    func dacSwitchesFire(rates: (Double, Double)) {
        #expect(AudioDeviceMonitor.isMeaningfulRateChange(oldRate: rates.0, newRate: rates.1))
    }

    @Test("Throttle allows normal track-by-track switching")
    func throttleAllowsNormalUse() {
        var throttle = AudioDeviceMonitor.RateChangeThrottle()
        let start = Date()
        // A rate change per track, every ~3 minutes, never throttled.
        for i in 0..<20 {
            do { let allowed = throttle.allow("usb-dac", now: start.addingTimeInterval(Double(i) * 180)); #expect(allowed) }
        }
    }

    @Test("Throttle stops a device flapping between rates, per device, and recovers")
    func throttleStopsFlapping() {
        var throttle = AudioDeviceMonitor.RateChangeThrottle(limit: 6, window: 10)
        let start = Date()
        for i in 0..<6 {
            do { let allowed = throttle.allow("flappy", now: start.addingTimeInterval(Double(i) * 0.5)); #expect(allowed) }
        }
        do { let allowed = throttle.allow("flappy", now: start.addingTimeInterval(3.5)); #expect(!allowed) }
        // Other devices are unaffected.
        do { let allowed = throttle.allow("usb-dac", now: start.addingTimeInterval(3.5)); #expect(allowed) }
        // After the window passes the device is handled again.
        do { let allowed = throttle.allow("flappy", now: start.addingTimeInterval(14)); #expect(allowed) }
    }

    @Test("Throttle reports remaining wait time for deferred recovery")
    func throttleNextAllowedDelay() {
        var throttle = AudioDeviceMonitor.RateChangeThrottle(limit: 2, window: 10)
        let start = Date()
        let first = throttle.allow("dac", now: start)
        let second = throttle.allow("dac", now: start.addingTimeInterval(1))
        let third = throttle.allow("dac", now: start.addingTimeInterval(3))
        #expect(first)
        #expect(second)
        #expect(!third)
        let delay = throttle.nextAllowedDelay(for: "dac", now: start.addingTimeInterval(3))
        #expect(abs(delay - 7.0) < 0.01)
    }
}
