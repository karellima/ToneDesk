// FineTuneTests/AutoEQProcessorTests.swift
// Signal-level tests for AutoEQProcessor: N-filter profiles, preamp, and glitch-free switching.
import Foundation
import Testing
@testable import FineTune

@MainActor
@Suite("AutoEQProcessor — signal")
struct AutoEQProcessorTests {

    static let rate = 48000.0
    static let block = 512

    /// Runs a stereo sine through the processor in blocks; returns the interleaved output.
    func render(_ p: AutoEQProcessor, frequency: Double, amplitude: Float = 0.25,
                frames: Int, startPhase: Int = 0,
                onBlock: ((Int) -> Void)? = nil) -> [Float] {
        var out = [Float](repeating: 0, count: frames * 2)
        var buf = [Float](repeating: 0, count: Self.block * 2)
        var offset = 0
        var blockIndex = 0
        while offset < frames {
            onBlock?(blockIndex)
            let n = min(Self.block, frames - offset)
            for i in 0..<n {
                let s = amplitude * Float(sin(2 * Double.pi * frequency * Double(startPhase + offset + i) / Self.rate))
                buf[i * 2] = s
                buf[i * 2 + 1] = s
            }
            buf.withUnsafeMutableBufferPointer { b in
                p.process(input: UnsafePointer(b.baseAddress!), output: b.baseAddress!, frameCount: n)
            }
            for i in 0..<(n * 2) { out[offset * 2 + i] = buf[i] }
            offset += n
            blockIndex += 1
        }
        return out
    }

    func rmsDB(_ x: ArraySlice<Float>) -> Double {
        let sum = x.reduce(0.0) { $0 + Double($1) * Double($1) }
        return 10 * log10(sum / Double(x.count))
    }

    func profile(count: Int, preamp: Float = -6) throws -> AutoEQProfile {
        try #require(AutoEQParser.parse(
            text: AutoEQTestSupport.syntheticProfileText(count: count, preamp: preamp),
            name: "n\(count)", source: .imported))
    }

    @Test("All N filters + preamp are applied to the signal", arguments: [12, 20, 32, 64])
    func appliesAllFilters(count: Int) throws {
        let prof = try profile(count: count)
        let p = AutoEQProcessor(sampleRate: Self.rate)
        p.updateProfile(prof)
        #expect(p.activeFilterCount == count)

        let probe = try #require(prof.filters.last).frequency
        let frames = Int(Self.rate)  // 1 s
        let y = render(p, frequency: probe, frames: frames)
        let measured = rmsDB(y[frames...]) - 20 * log10(0.25 / 2.0.squareRoot())

        let c = BiquadMath.coefficientsForAutoEQFilters(prof.filters, sampleRate: Self.rate, profileOptimizedRate: nil)
        let predicted = AutoEQTestSupport.magnitudeDB(coefficients: c, frequency: probe, sampleRate: Self.rate) + Double(prof.preampDB)
        #expect(abs(measured - predicted) < 0.1, "measured \(measured) dB vs predicted \(predicted) dB")
    }

    @Test("Preamp bypass removes only the preamp")
    func preampBypass() throws {
        let prof = try profile(count: 12, preamp: -9)
        let on = AutoEQProcessor(sampleRate: Self.rate)
        on.updateProfile(prof)
        let off = AutoEQProcessor(sampleRate: Self.rate)
        off.setPreampEnabled(false)
        off.updateProfile(prof)
        let frames = Int(Self.rate / 2)
        let a = rmsDB(render(on, frequency: 1000, frames: frames)[frames...])
        let b = rmsDB(render(off, frequency: 1000, frames: frames)[frames...])
        #expect(abs((b - a) - 9) < 0.05)
    }

    /// Largest sample-to-sample jump; a click shows up as a spike far above the sine's own slope.
    func maxStep(_ y: [Float], channel: Int = 0) -> Float {
        var m: Float = 0
        var i = channel + 2
        while i < y.count { m = max(m, abs(y[i] - y[i - 2])); i += 2 }
        return m
    }

    @Test("Switching profiles mid-stream is click-free (12 → 64 → 20 filters → off)")
    func switchingIsSmooth() throws {
        let a = try profile(count: 12, preamp: -3)
        let b = try profile(count: 64, preamp: -12)
        let c = try #require(AutoEQParser.parse(
            text: try AutoEQTestSupport.fixtureText("2_Harman_Grave_Extra.txt"), name: "h", source: .imported))
        let p = AutoEQProcessor(sampleRate: Self.rate)
        p.updateProfile(a)

        let freq = 220.0
        let amp: Float = 0.25
        let y = render(p, frequency: freq, amplitude: amp, frames: Int(Self.rate) * 2) { block in
            switch block {
            case 40: p.updateProfile(b)
            case 80: p.updateProfile(c)
            case 120: p.updateProfile(nil)
            default: break
            }
        }
        // A sine's max step is 2π f / fs · A_out. Allow generous headroom for EQ gain,
        // but a hard switch between cascades with different state produces far larger steps.
        let sineSlope = Float(2 * Double.pi * freq / Self.rate) * amp
        #expect(maxStep(y) < sineSlope * 4, "max step \(maxStep(y)) vs sine slope \(sineSlope)")
        #expect(!y.contains { $0.isNaN })
        // After disabling and the fade-out the processor reports idle.
        #expect(p.isEnabled == false)
    }

    @Test("Sample-rate change applies new coefficients (hard cut) without NaN")
    func sampleRateChange() throws {
        let p = AutoEQProcessor(sampleRate: Self.rate)
        p.updateProfile(try profile(count: 20))
        _ = render(p, frequency: 1000, frames: 4096)
        p.updateSampleRate(96000)
        #expect(p.sampleRate == 96000)
        let y = render(p, frequency: 1000, frames: 4096)
        #expect(!y.contains { $0.isNaN })
        #expect(p.activeFilterCount == 20)
    }

    @Test("Large callback sizes (> scratch) are processed in chunks during a fade")
    func largeBuffers() throws {
        let p = AutoEQProcessor(sampleRate: Self.rate)
        p.updateProfile(try profile(count: 32))
        var buf = [Float](repeating: 0.1, count: 8192 * 2)
        buf.withUnsafeMutableBufferPointer { b in
            p.process(input: UnsafePointer(b.baseAddress!), output: b.baseAddress!, frameCount: 8192)
        }
        #expect(!buf.contains { $0.isNaN })
    }
}
