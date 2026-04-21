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

        static let remoteSSHEnabled = "remoteSSHEnabled"
        static let remoteSSHHost = "remoteSSHHost"
        static let remoteSSHUser = "remoteSSHUser"
        static let remoteSSHPort = "remoteSSHPort"

        // Reverse tunnel listen port on the remote host (ssh -R <remotePort>:127.0.0.1:<localPort>)
        static let remoteSSHTunnelPort = "remoteSSHTunnelPort"
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

    // MARK: - Remote SSH

    /// Whether Coding Island should maintain an SSH reverse tunnel to a remote host.
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

    /// Remote reverse-tunnel port (default 19999).
    ///
    /// This is the port that will be bound on the *remote* host (remote 127.0.0.1:<port>)
    /// and forwarded back to Coding Island running locally.
    static var remoteSSHTunnelPort: Int {
        get {
            let value = defaults.integer(forKey: Keys.remoteSSHTunnelPort)
            return value == 0 ? 19999 : value
        }
        set {
            let clamped = max(1, min(65535, newValue))
            defaults.set(clamped, forKey: Keys.remoteSSHTunnelPort)
        }
    }
}
