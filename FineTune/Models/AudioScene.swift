// FineTune/Models/AudioScene.swift
import Foundation

/// A saved "Quick Config" snapshot of the user's audio setup that can be applied in one click.
nonisolated struct AudioScene: Codable, Equatable, Identifiable, Sendable {
    var id: UUID = UUID()
    var name: String
    var icon: String = "sparkles"

    /// Default output/input devices at snapshot time.
    var defaultOutputUID: String?
    var defaultOutputDeviceKey: String?
    var defaultInputUID: String?

    /// Output device volumes (keyed by device UID) in native backend scale.
    var deviceVolumes: [String: Float] = [:]
    /// Per-device AutoEQ selections (keyed by device UID).
    var deviceAutoEQ: [String: AutoEQSelection] = [:]
    /// Per-device processing (balance, mono, channel swap, max volume limit, BT output-only).
    var deviceProcessing: [String: DeviceAudioProcessingSettings] = [:]
    /// Per-device global parametric EQ.
    var deviceParametricEQ: [String: DeviceParametricEQ] = [:]

    /// Per-app state (keyed by app persistenceIdentifier).
    var appVolumes: [String: Float] = [:]
    var appMutes: [String: Bool] = [:]
    var appBalances: [String: Float] = [:]
    var appDeviceRouting: [String: String] = [:]

    /// Global loudness settings.
    var loudnessCompensationEnabled: Bool = false
    var loudnessEqualizationEnabled: Bool = false

    init(
        id: UUID = UUID(),
        name: String,
        icon: String = "sparkles",
        defaultOutputUID: String? = nil,
        defaultOutputDeviceKey: String? = nil,
        defaultInputUID: String? = nil,
        deviceVolumes: [String: Float] = [:],
        deviceAutoEQ: [String: AutoEQSelection] = [:],
        deviceProcessing: [String: DeviceAudioProcessingSettings] = [:],
        deviceParametricEQ: [String: DeviceParametricEQ] = [:],
        appVolumes: [String: Float] = [:],
        appMutes: [String: Bool] = [:],
        appBalances: [String: Float] = [:],
        appDeviceRouting: [String: String] = [:],
        loudnessCompensationEnabled: Bool = false,
        loudnessEqualizationEnabled: Bool = false
    ) {
        self.id = id
        self.name = name
        self.icon = icon
        self.defaultOutputUID = defaultOutputUID
        self.defaultOutputDeviceKey = defaultOutputDeviceKey
        self.defaultInputUID = defaultInputUID
        self.deviceVolumes = deviceVolumes
        self.deviceAutoEQ = deviceAutoEQ
        self.deviceProcessing = deviceProcessing
        self.deviceParametricEQ = deviceParametricEQ
        self.appVolumes = appVolumes
        self.appMutes = appMutes
        self.appBalances = appBalances
        self.appDeviceRouting = appDeviceRouting
        self.loudnessCompensationEnabled = loudnessCompensationEnabled
        self.loudnessEqualizationEnabled = loudnessEqualizationEnabled
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        icon = try c.decodeIfPresent(String.self, forKey: .icon) ?? "sparkles"
        defaultOutputUID = try c.decodeIfPresent(String.self, forKey: .defaultOutputUID)
        defaultOutputDeviceKey = try c.decodeIfPresent(String.self, forKey: .defaultOutputDeviceKey)
        defaultInputUID = try c.decodeIfPresent(String.self, forKey: .defaultInputUID)
        deviceVolumes = try c.decodeIfPresent([String: Float].self, forKey: .deviceVolumes) ?? [:]
        deviceAutoEQ = try c.decodeIfPresent([String: AutoEQSelection].self, forKey: .deviceAutoEQ) ?? [:]
        deviceProcessing = try c.decodeIfPresent([String: DeviceAudioProcessingSettings].self, forKey: .deviceProcessing) ?? [:]
        deviceParametricEQ = try c.decodeIfPresent([String: DeviceParametricEQ].self, forKey: .deviceParametricEQ) ?? [:]
        appVolumes = try c.decodeIfPresent([String: Float].self, forKey: .appVolumes) ?? [:]
        appMutes = try c.decodeIfPresent([String: Bool].self, forKey: .appMutes) ?? [:]
        appBalances = try c.decodeIfPresent([String: Float].self, forKey: .appBalances) ?? [:]
        appDeviceRouting = try c.decodeIfPresent([String: String].self, forKey: .appDeviceRouting) ?? [:]
        loudnessCompensationEnabled = try c.decodeIfPresent(Bool.self, forKey: .loudnessCompensationEnabled) ?? false
        loudnessEqualizationEnabled = try c.decodeIfPresent(Bool.self, forKey: .loudnessEqualizationEnabled) ?? false
    }

    static let availableIcons: [String] = [
        "sparkles", "headphones", "hifispeaker.2", "desktopcomputer",
        "mic", "moon.stars", "gamecontroller", "film", "music.note"
    ]
}
