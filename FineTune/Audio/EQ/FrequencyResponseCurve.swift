// FineTune/Audio/EQ/FrequencyResponseCurve.swift
import Foundation

/// A single evaluated point along a 20 Hz – 20 kHz log-frequency response curve.
nonisolated struct FrequencyResponsePoint: Equatable, Sendable {
    let frequency: Double
    let magnitudeDB: Double
    /// Position along [0, 1] on the log10 frequency axis (20 Hz → 0, 20 kHz → 1).
    let normalizedX: Double
}

/// Pure DSP frequency-response evaluator for real-time EQ graphs and profile previews.
nonisolated enum FrequencyResponseCurve {
    static let minFrequency: Double = 20.0
    static let maxFrequency: Double = 20_000.0
    private static let logMin: Double = log10(minFrequency)
    private static let logMax: Double = log10(maxFrequency)

    /// Standard audio grid lines (Hz) for the X axis.
    static let gridFrequencies: [Double] = [20, 50, 100, 200, 500, 1000, 2000, 5000, 10000, 20000]

    /// Maps a frequency (Hz) to [0, 1] on the logarithmic X axis.
    static func normalizedX(forFrequency frequency: Double) -> Double {
        let clamped = max(minFrequency, min(maxFrequency, frequency))
        return (log10(clamped) - logMin) / (logMax - logMin)
    }

    /// Inverse mapping from [0, 1] on the logarithmic X axis back to Hz.
    static func frequency(forNormalizedX x: Double) -> Double {
        let clamped = max(0.0, min(1.0, x))
        return pow(10.0, logMin + clamped * (logMax - logMin))
    }

    /// Evaluates the combined magnitude response (dB) of a filter cascade across 20 Hz – 20 kHz.
    static func evaluate(
        filters: [AutoEQFilter],
        preampDB: Float = 0,
        includePreamp: Bool = false,
        optimizedSampleRate: Double? = nil,
        sampleRate: Double = 48_000,
        pointCount: Int = 160
    ) -> [FrequencyResponsePoint] {
        let count = max(2, pointCount)
        let preampOffset = includePreamp ? Double(preampDB) : 0.0
        let coeffs = filters.isEmpty
            ? []
            : BiquadMath.coefficientsForAutoEQFilters(
                filters,
                sampleRate: sampleRate,
                profileOptimizedRate: optimizedSampleRate
            )

        var points: [FrequencyResponsePoint] = []
        points.reserveCapacity(count)

        for i in 0..<count {
            let x = Double(i) / Double(count - 1)
            let f = frequency(forNormalizedX: x)
            let magDB: Double
            if coeffs.isEmpty {
                magDB = preampOffset
            } else {
                let p = AutoEQLoudness.powerGain(coeffs, frequency: f, sampleRate: sampleRate)
                let db = p > 1e-12 ? 10.0 * log10(p) : -120.0
                magDB = db + preampOffset
            }
            points.append(FrequencyResponsePoint(frequency: f, magnitudeDB: magDB, normalizedX: x))
        }
        return points
    }

    /// Evaluates an `AutoEQProfile` directly (optionally including its preamp offset).
    static func evaluate(
        profile: AutoEQProfile,
        includePreamp: Bool = false,
        sampleRate: Double = 48_000,
        pointCount: Int = 160
    ) -> [FrequencyResponsePoint] {
        let validated = profile.validated()
        return evaluate(
            filters: validated.filters,
            preampDB: validated.preampDB,
            includePreamp: includePreamp,
            optimizedSampleRate: validated.optimizedSampleRate,
            sampleRate: sampleRate,
            pointCount: pointCount
        )
    }

    /// Evaluates both the optional base AutoEQ curve and the combined AutoEQ + Device Parametric EQ curve,
    /// using the exact same 64-filter ceiling as `DeviceParametricEQ.combinedProfile` so the graph
    /// always matches what is actually rendered in audio.
    static func evaluateDeviceCurves(
        baseAutoEQ: AutoEQProfile?,
        parametricEQ: DeviceParametricEQ,
        includePreamp: Bool = false,
        sampleRate: Double = 48_000,
        pointCount: Int = 160
    ) -> (combined: [FrequencyResponsePoint], base: [FrequencyResponsePoint]?, droppedBandCount: Int) {
        let effectiveRate = sampleRate > 0 ? sampleRate : 48_000
        let (peqFilters, droppedCount) = DeviceParametricEQ.effectiveFilters(
            baseAutoEQ: baseAutoEQ,
            parametricEQ: parametricEQ
        )
        let peqPreamp: Float = parametricEQ.isEnabled ? parametricEQ.preampDB : 0

        let basePoints = baseAutoEQ.map {
            evaluate(profile: $0, includePreamp: includePreamp, sampleRate: effectiveRate, pointCount: pointCount)
        }

        guard baseAutoEQ != nil else {
            let peqPoints = evaluate(
                filters: peqFilters,
                preampDB: peqPreamp,
                includePreamp: includePreamp,
                optimizedSampleRate: nil,
                sampleRate: effectiveRate,
                pointCount: pointCount
            )
            return (combined: peqPoints, base: nil, droppedBandCount: droppedCount)
        }

        if peqFilters.isEmpty && (!includePreamp || abs(peqPreamp) < 0.05) {
            let base = basePoints ?? []
            return (combined: base, base: nil, droppedBandCount: droppedCount)
        }

        // Sum dB responses of baseAutoEQ and applied PEQ filters (exact because cascades multiply in linear magnitude).
        let peqPoints = evaluate(
            filters: peqFilters,
            preampDB: peqPreamp,
            includePreamp: includePreamp,
            optimizedSampleRate: nil,
            sampleRate: effectiveRate,
            pointCount: pointCount
        )
        let base = basePoints ?? []
        let combined = zip(base, peqPoints).map { b, p in
            FrequencyResponsePoint(
                frequency: b.frequency,
                magnitudeDB: b.magnitudeDB + p.magnitudeDB,
                normalizedX: b.normalizedX
            )
        }
        return (combined: combined, base: base, droppedBandCount: droppedCount)
    }
}
