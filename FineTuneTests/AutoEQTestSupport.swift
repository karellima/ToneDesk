// FineTuneTests/AutoEQTestSupport.swift
import Foundation
@testable import FineTune

/// Shared helpers for AutoEQ tests.
enum AutoEQTestSupport {

    /// Magnitude response (dB) of a vDSP-format cascade `[b0,b1,b2,a1,a2] * N` at `frequency`.
    static func magnitudeDB(coefficients c: [Double], frequency: Double, sampleRate: Double) -> Double {
        precondition(c.count % 5 == 0)
        let w = 2.0 * Double.pi * frequency / sampleRate
        // z^-1 = e^{-jw}
        let c1 = cos(w), s1 = -sin(w)
        let c2 = cos(2 * w), s2 = -sin(2 * w)
        var totalDB = 0.0
        for i in stride(from: 0, to: c.count, by: 5) {
            let (b0, b1, b2, a1, a2) = (c[i], c[i + 1], c[i + 2], c[i + 3], c[i + 4])
            let numRe = b0 + b1 * c1 + b2 * c2
            let numIm = b1 * s1 + b2 * s2
            let denRe = 1.0 + a1 * c1 + a2 * c2
            let denIm = a1 * s1 + a2 * s2
            let num = numRe * numRe + numIm * numIm
            let den = denRe * denRe + denIm * denIm
            totalDB += 10.0 * log10(num / den)
        }
        return totalDB
    }

    /// Builds an APO ParametricEQ.txt text with `count` peaking filters spread log-uniformly.
    static func syntheticProfileText(count: Int, preamp: Float = -6.0, gain: Float = -2.0) -> String {
        var lines = ["Preamp: \(preamp) dB"]
        for i in 0..<count {
            let t = Double(i) / Double(max(count - 1, 1))
            let fc = 30.0 * pow(16000.0 / 30.0, t)
            let g = i.isMultiple(of: 2) ? gain : -gain
            lines.append(String(format: "Filter %d: ON PK Fc %.1f Hz Gain %.1f dB Q 4.00", i + 1, fc, g))
        }
        return lines.joined(separator: "\n")
    }

    static func fixtureURL(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/AutoEQ")
            .appendingPathComponent(name)
    }

    static func fixtureText(_ name: String) throws -> String {
        try String(contentsOf: fixtureURL(name), encoding: .utf8)
    }
}
