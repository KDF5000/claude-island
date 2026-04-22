//
//  Settings.swift
//  ClaudeIsland
//
//  App settings manager using UserDefaults
//

import Foundation

struct RemoteMachineSettings: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    var host: String
    var user: String
    var sshPort: Int
    var remotePort: Int
    var isEnabled: Bool

    init(
        id: String = UUID().uuidString,
        name: String = "",
        host: String = "",
        user: String = "",
        sshPort: Int = 22,
        remotePort: Int = 19999,
        isEnabled: Bool = false
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.user = user
        self.sshPort = sshPort
        self.remotePort = remotePort
        self.isEnabled = isEnabled
    }
}

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
        static let remoteMachines = "remoteMachines"

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

    static var remoteMachines: [RemoteMachineSettings] {
        get {
            if let data = defaults.data(forKey: Keys.remoteMachines),
               let decoded = try? JSONDecoder().decode([RemoteMachineSettings].self, from: data) {
                return normalizeRemoteMachines(decoded)
            }

            guard let legacy = legacyRemoteMachine() else {
                return []
            }

            let migrated = normalizeRemoteMachines([legacy])
            persistRemoteMachines(migrated)
            return migrated
        }
        set {
            persistRemoteMachines(normalizeRemoteMachines(newValue))
        }
    }

    /// Whether Coding Island should maintain an SSH reverse tunnel to a remote host.
    static var remoteSSHEnabled: Bool {
        get { remoteMachines.first?.isEnabled ?? defaults.bool(forKey: Keys.remoteSSHEnabled) }
        set {
            updatePrimaryRemote { remote in
                remote.isEnabled = newValue
            }
        }
    }

    /// Remote host (e.g. "example.com" or "10.0.0.12"). Empty means not configured.
    static var remoteSSHHost: String {
        get { remoteMachines.first?.host ?? (defaults.string(forKey: Keys.remoteSSHHost) ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        set {
            updatePrimaryRemote { remote in
                remote.host = newValue
            }
        }
    }

    /// Remote SSH user (optional). Empty means use default SSH user.
    static var remoteSSHUser: String {
        get { remoteMachines.first?.user ?? (defaults.string(forKey: Keys.remoteSSHUser) ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        set {
            updatePrimaryRemote { remote in
                remote.user = newValue
            }
        }
    }

    /// Remote SSH port (default 22).
    static var remoteSSHPort: Int {
        get {
            if let value = remoteMachines.first?.sshPort {
                return value
            }
            let value = defaults.integer(forKey: Keys.remoteSSHPort)
            return value == 0 ? 22 : value
        }
        set {
            updatePrimaryRemote { remote in
                remote.sshPort = newValue
            }
        }
    }

    /// Remote reverse-tunnel port (default 19999).
    ///
    /// This is the port that will be bound on the *remote* host (remote 127.0.0.1:<port>)
    /// and forwarded back to Coding Island running locally.
    static var remoteSSHTunnelPort: Int {
        get {
            if let value = remoteMachines.first?.remotePort {
                return value
            }
            let value = defaults.integer(forKey: Keys.remoteSSHTunnelPort)
            return value == 0 ? 19999 : value
        }
        set {
            updatePrimaryRemote { remote in
                remote.remotePort = newValue
            }
        }
    }

    private static func updatePrimaryRemote(_ update: (inout RemoteMachineSettings) -> Void) {
        var remotes = remoteMachines
        if remotes.isEmpty {
            remotes = [RemoteMachineSettings(name: "Primary Remote")]
        }
        update(&remotes[0])
        remoteMachines = remotes
    }

    private static func persistRemoteMachines(_ remotes: [RemoteMachineSettings]) {
        if let data = try? JSONEncoder().encode(remotes) {
            defaults.set(data, forKey: Keys.remoteMachines)
        }
        syncLegacyRemoteDefaults(with: remotes)
    }

    private static func syncLegacyRemoteDefaults(with remotes: [RemoteMachineSettings]) {
        let primary = remotes.first
        defaults.set(primary?.isEnabled ?? false, forKey: Keys.remoteSSHEnabled)
        defaults.set(primary?.host ?? "", forKey: Keys.remoteSSHHost)
        defaults.set(primary?.user ?? "", forKey: Keys.remoteSSHUser)
        defaults.set(primary?.sshPort ?? 22, forKey: Keys.remoteSSHPort)
        defaults.set(primary?.remotePort ?? 19999, forKey: Keys.remoteSSHTunnelPort)
    }

    private static func legacyRemoteMachine() -> RemoteMachineSettings? {
        let host = (defaults.string(forKey: Keys.remoteSSHHost) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let user = (defaults.string(forKey: Keys.remoteSSHUser) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let sshPortRaw = defaults.integer(forKey: Keys.remoteSSHPort)
        let remotePortRaw = defaults.integer(forKey: Keys.remoteSSHTunnelPort)
        let enabled = defaults.bool(forKey: Keys.remoteSSHEnabled)

        guard !host.isEmpty else { return nil }

        return RemoteMachineSettings(
            name: host,
            host: host,
            user: user,
            sshPort: sshPortRaw == 0 ? 22 : sshPortRaw,
            remotePort: remotePortRaw == 0 ? 19999 : remotePortRaw,
            isEnabled: enabled
        )
    }

    private static func normalizeRemoteMachines(_ remotes: [RemoteMachineSettings]) -> [RemoteMachineSettings] {
        remotes.enumerated().map { index, remote in
            let trimmedHost = remote.host.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedUser = remote.user.trimmingCharacters(in: .whitespacesAndNewlines)
            let fallbackName = trimmedHost.isEmpty ? "Remote \(index + 1)" : trimmedHost

            return RemoteMachineSettings(
                id: remote.id,
                name: remote.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? fallbackName : remote.name.trimmingCharacters(in: .whitespacesAndNewlines),
                host: trimmedHost,
                user: trimmedUser,
                sshPort: max(1, min(65535, remote.sshPort)),
                remotePort: max(1, min(65535, remote.remotePort)),
                isEnabled: remote.isEnabled
            )
        }
    }
}
