// FineTune/Models/DeviceAudioProcessing.swift
import Foundation

/// Per-output-device stereo processing, safety limit, and Bluetooth mode settings.
nonisolated struct DeviceAudioProcessingSettings: Codable, Equatable, Sendable {
    /// Stereo balance from -1.0 (full left) through 0.0 (center) to +1.0 (full right).
    var balance: Float = 0.0
    /// Sums left and right channels to mono (`(L + R) * 0.5`) before applying balance.
    var isMono: Bool = false
    /// Swaps left and right channels before mono/balance processing.
    var swapChannels: Bool = false
    /// Optional maximum volume cap in slider fraction (`0.10...1.00`). `nil` = unlimited.
    var maxVolumeLimit: Float? = nil
    /// For Bluetooth devices: prevents macOS from switching input to the headset mic (SCO/HFP),
    /// keeping the headset in high-quality A2DP music output mode.
    var bluetoothOutputOnly: Bool = false

    static let `default` = DeviceAudioProcessingSettings()
    static let maxVolumeLimitRange: ClosedRange<Float> = 0.10...1.00

    init(
        balance: Float = 0.0,
        isMono: Bool = false,
        swapChannels: Bool = false,
        maxVolumeLimit: Float? = nil,
        bluetoothOutputOnly: Bool = false
    ) {
        self.balance = Self.clampedBalance(balance)
        self.isMono = isMono
        self.swapChannels = swapChannels
        self.maxVolumeLimit = maxVolumeLimit.map(Self.clampedMaxVolumeLimit)
        self.bluetoothOutputOnly = bluetoothOutputOnly
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let rawBalance = try c.decodeIfPresent(Float.self, forKey: .balance) ?? 0.0
        balance = Self.clampedBalance(rawBalance)
        isMono = try c.decodeIfPresent(Bool.self, forKey: .isMono) ?? false
        swapChannels = try c.decodeIfPresent(Bool.self, forKey: .swapChannels) ?? false
        if let rawLimit = try c.decodeIfPresent(Float.self, forKey: .maxVolumeLimit) {
            maxVolumeLimit = Self.clampedMaxVolumeLimit(rawLimit)
        } else {
            maxVolumeLimit = nil
        }
        bluetoothOutputOnly = try c.decodeIfPresent(Bool.self, forKey: .bluetoothOutputOnly) ?? false
    }

    /// True when every setting is at its neutral default (no entry needs to be persisted).
    var isDefault: Bool {
        abs(balance) < 0.005
            && !isMono
            && !swapChannels
            && maxVolumeLimit == nil
            && !bluetoothOutputOnly
    }

    /// Compact pills shown on `DeviceRow` only when non-default controls are active.
    var activeBadges: [String] {
        var badges: [String] = []
        if isMono { badges.append("MONO") }
        if swapChannels { badges.append("L⇄R") }
        let pct = Int(round(abs(balance) * 100))
        if pct >= 1 {
            badges.append(balance < 0 ? "L\(pct)" : "R\(pct)")
        }
        if let limit = maxVolumeLimit, limit < 0.995 {
            badges.append("≤\(Int(round(limit * 100)))%")
        }
        if bluetoothOutputOnly {
            badges.append("A2DP")
        }
        return badges
    }

    static func clampedBalance(_ value: Float) -> Float {
        guard value.isFinite else { return 0 }
        let clamped = max(-1.0, min(1.0, value))
        // Snap tiny values near center to exact 0.0 so UI and DSP stay clean.
        return abs(clamped) < 0.01 ? 0.0 : clamped
    }

    static func clampedMaxVolumeLimit(_ value: Float) -> Float {
        guard value.isFinite else { return 1.0 }
        return max(maxVolumeLimitRange.lowerBound, min(maxVolumeLimitRange.upperBound, value))
    }

    /// Linear per-channel attenuation matching macOS balance law (never boosts above 1.0):
    /// - `balance <= 0`: left = 1.0, right = 1.0 + balance
    /// - `balance > 0`:  left = 1.0 - balance, right = 1.0
    static func channelGains(balance: Float) -> (left: Float, right: Float) {
        let b = clampedBalance(balance)
        if b < 0 {
            return (1.0, max(0.0, 1.0 + b))
        } else if b > 0 {
            return (max(0.0, 1.0 - b), 1.0)
        }
        return (1.0, 1.0)
    }
}
