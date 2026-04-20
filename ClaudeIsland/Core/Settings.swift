//
//  Settings.swift
//  ClaudeIsland
//
//  App settings manager using UserDefaults
//

import Foundation

/// Available notification sounds
enum NotificationSound: String, CaseIterable {
    case none = "None"
    case pop = "Pop"
    case ping = "Ping"
    case tink = "Tink"
    case glass = "Glass"
    case blow = "Blow"
    case bottle = "Bottle"
    case frog = "Frog"
    case funk = "Funk"
    case hero = "Hero"
    case morse = "Morse"
    case purr = "Purr"
    case sosumi = "Sosumi"
    case submarine = "Submarine"
    case basso = "Basso"

    /// The system sound name to use with NSSound, or nil for no sound
    var soundName: String? {
        self == .none ? nil : rawValue
    }
}

enum AppSettings {
    private static let defaults = UserDefaults.standard

    // MARK: - Keys

    private enum Keys {
        static let notificationSound = "notificationSound"
        static let claudeDirectoryName = "claudeDirectoryName"

        static let remoteSSHEnabled = "remoteSSHEnabled"
        static let remoteSSHHost = "remoteSSHHost"
        static let remoteSSHUser = "remoteSSHUser"
        static let remoteSSHPort = "remoteSSHPort"
    }

    // MARK: - Notification Sound

    /// The sound to play when Claude finishes and is ready for input
    static var notificationSound: NotificationSound {
        get {
            guard let rawValue = defaults.string(forKey: Keys.notificationSound),
                  let sound = NotificationSound(rawValue: rawValue) else {
                return .pop // Default to Pop
            }
            return sound
        }
        set {
            defaults.set(newValue.rawValue, forKey: Keys.notificationSound)
        }
    }

    // MARK: - Claude Directory

    /// The name of the Claude config directory under the user's home folder.
    /// Defaults to ".claude" (standard Claude Code installation).
    /// Change to ".claude-internal" (or similar) for enterprise/custom distributions.
    static var claudeDirectoryName: String {
        get {
            let value = defaults.string(forKey: Keys.claudeDirectoryName) ?? ""
            return value.isEmpty ? ".claude" : value
        }
        set {
            defaults.set(newValue.trimmingCharacters(in: .whitespaces), forKey: Keys.claudeDirectoryName)
        }
    }

    // MARK: - Remote SSH

    /// Whether Claude Island should maintain an SSH reverse tunnel to a remote host.
    static var remoteSSHEnabled: Bool {
        get { defaults.bool(forKey: Keys.remoteSSHEnabled) }
        set { defaults.set(newValue, forKey: Keys.remoteSSHEnabled) }
    }

    /// Remote host (e.g. "example.com" or "10.0.0.12"). Empty means not configured.
    static var remoteSSHHost: String {
        get { (defaults.string(forKey: Keys.remoteSSHHost) ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        set { defaults.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Keys.remoteSSHHost) }
    }

    /// Remote SSH user (optional). Empty means use default SSH user.
    static var remoteSSHUser: String {
        get { (defaults.string(forKey: Keys.remoteSSHUser) ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        set { defaults.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Keys.remoteSSHUser) }
    }

    /// Remote SSH port (default 22).
    static var remoteSSHPort: Int {
        get {
            let value = defaults.integer(forKey: Keys.remoteSSHPort)
            return value == 0 ? 22 : value
        }
        set {
            let clamped = max(1, min(65535, newValue))
            defaults.set(clamped, forKey: Keys.remoteSSHPort)
        }
    }
}
