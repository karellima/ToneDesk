// FineTune/Audio/AutoEQ/AutoEQLoudness.swift
import Foundation
import os

/// Approximate loudness change a profile applies, used to level-match A/B comparisons.
///
/// Model: pink noise (equal energy per octave, i.e. uniform on a log-frequency axis)
/// passed through the profile and K-weighted as in ITU-R BS.1770 (the weighting behind
/// LUFS). The result is the K-weighted power gain in dB — an "approximate LUFS delta".
/// It is a static estimate of the EQ curve, not a measurement of the music playing.
nonisolated enum AutoEQLoudness {

    /// Number of log-spaced analysis points between 20 Hz and 20 kHz.
    static let pointCount = 480

    private struct TrimCacheKey: Equatable {
        let a: AutoEQProfile
        let b: AutoEQProfile
        let includePreamp: Bool
    }

    private struct TrimCacheEntry {
        let key: TrimCacheKey
        let value: (Float, Float)
    }

    private static let trimCache = OSAllocatedUnfairLock<TrimCacheEntry?>(initialState: nil)

    /// Estimated loudness change (dB) of `profile`, including its preamp when requested.
    static func estimatedGainDB(of profile: AutoEQProfile, includePreamp: Bool, sampleRate: Double = 48000) -> Double {
        let validated = profile.validated()
        let coefficients = BiquadMath.coefficientsForAutoEQFilters(
            validated.filters, sampleRate: sampleRate,
            profileOptimizedRate: validated.optimizedSampleRate)
        var weighted = 0.0
        var total = 0.0
        let lo = log(20.0), hi = log(20000.0)
        for i in 0..<pointCount {
            let f = exp(lo + (hi - lo) * (Double(i) + 0.5) / Double(pointCount))
            guard f < sampleRate / 2 else { continue }
            let k = kWeightingPower(frequency: f)
            weighted += k * powerGain(coefficients, frequency: f, sampleRate: sampleRate)
            total += k
        }
        guard total > 0, weighted > 0 else { return 0 }
        let curveDB = 10 * log10(weighted / total)
        return curveDB + (includePreamp ? Double(validated.preampDB) : 0)
    }

    /// Level-matching trims for an A/B pair: the louder profile is attenuated so both
    /// sound equally loud; the quieter one is never boosted. Returns (trimA, trimB) in dB (≤ 0).
    static func levelMatchTrims(a: AutoEQProfile, b: AutoEQProfile, includePreamp: Bool) -> (Float, Float) {
        let key = TrimCacheKey(a: a, b: b, includePreamp: includePreamp)
        if let cached = trimCache.withLock({ $0?.key == key ? $0?.value : nil }) {
            return cached
        }
        let la = estimatedGainDB(of: a, includePreamp: includePreamp)
        let lb = estimatedGainDB(of: b, includePreamp: includePreamp)
        let quietest = min(la, lb)
        let trims = (Float(quietest - la), Float(quietest - lb))
        trimCache.withLock { $0 = TrimCacheEntry(key: key, value: trims) }
        return trims
    }

    // MARK: - Helpers

    /// |H(f)|² of a vDSP-format cascade.
    static func powerGain(_ c: [Double], frequency: Double, sampleRate: Double) -> Double {
        let w = 2 * Double.pi * frequency / sampleRate
        let c1 = cos(w), s1 = -sin(w), c2 = cos(2 * w), s2 = -sin(2 * w)
        var gain = 1.0
        var i = 0
        while i + 4 < c.count {
            let numRe = c[i] + c[i + 1] * c1 + c[i + 2] * c2
            let numIm = c[i + 1] * s1 + c[i + 2] * s2
            let denRe = 1 + c[i + 3] * c1 + c[i + 4] * c2
            let denIm = c[i + 3] * s1 + c[i + 4] * s2
            gain *= (numRe * numRe + numIm * numIm) / (denRe * denRe + denIm * denIm)
            i += 5
        }
        return gain
    }

    /// BS.1770 K-weighting power response (pre-filter shelf + RLB high-pass), 48 kHz coefficients.
    static func kWeightingPower(frequency: Double) -> Double {
        let stage1: [Double] = [1.53512485958697, -2.69169618940638, 1.19839281085285,
                                -1.69065929318241, 0.73248077421585]
        let stage2: [Double] = [1.0, -2.0, 1.0, -1.99004745483398, 0.99007225036621]
        return powerGain(stage1 + stage2, frequency: frequency, sampleRate: 48000)
    }
}
