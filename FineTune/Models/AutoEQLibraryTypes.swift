// FineTune/Models/AutoEQLibraryTypes.swift
import Foundation

/// Port-independent identity of an output device, used as a fallback key for AutoEQ
/// assignments. Some USB devices get a different CoreAudio UID per USB port, but their
/// name and manufacturer stay the same.
nonisolated enum AutoEQDeviceKey {
    /// "manufacturer|name", case- and whitespace-normalized. Empty name → nil.
    static func make(name: String, manufacturer: String?) -> String? {
        let n = normalize(name)
        guard !n.isEmpty else { return nil }
        return "\(normalize(manufacturer ?? ""))|\(n)"
    }

    private static func normalize(_ s: String) -> String {
        s.split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .lowercased()
    }
}

/// A/B comparison state (stored in settings).
nonisolated struct AutoEQABSettings: Codable, Equatable {
    enum Slot: String, Codable { case a, b }

    var profileA: String?
    var profileB: String?
    var active: Slot = .a
    /// Level-match the two profiles (attenuate the louder one).
    var levelMatch: Bool = true

    /// Profile ID of the active slot.
    var activeProfileID: String? { active == .a ? profileA : profileB }

    var isConfigured: Bool {
        guard let profileA, let profileB else { return false }
        return profileA != profileB
    }

    init(profileA: String? = nil, profileB: String? = nil, active: Slot = .a, levelMatch: Bool = true) {
        self.profileA = profileA
        self.profileB = profileB
        self.active = active
        self.levelMatch = levelMatch
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        profileA = try c.decodeIfPresent(String.self, forKey: .profileA)
        profileB = try c.decodeIfPresent(String.self, forKey: .profileB)
        active = (try? c.decodeIfPresent(Slot.self, forKey: .active)) ?? .a
        levelMatch = try c.decodeIfPresent(Bool.self, forKey: .levelMatch) ?? true
    }
}
