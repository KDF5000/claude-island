//
//  QoderProvider.swift
//  ClaudeIsland
//
//  Provider implementation for Qoder (IDE / JetBrains plugin hooks)
//  Installs a hook script into ~/.qoder/settings.json and forwards events
//  to Coding Island via the shared HookSocketServer socket.
//

import Combine
import Foundation
import AppKit
import os.log

private let logger = Logger(subsystem: "com.codingisland", category: "QoderProvider")

// MARK: - Qoder Provider Factory

struct QoderProviderFactory: AgentProviderFactory {
    static var providerInfo: ProviderInfo {
        ProviderInfo(
            id: "qoder",
            displayName: "Qoder",
            icon: "q.circle",
            capabilities: [.realTimeEvents, .chatHistory, .transcriptAccess],
            configPath: QoderHookInstaller.userSettingsFile.path
        )
    }

    static func create() -> AgentProvider {
        QoderProvider()
    }
}

// MARK: - Qoder Provider

final class QoderProvider: AgentProvider {
    let providerId = "qoder"
    let displayName = "Qoder"
    var icon: NSImage? { NSImage(systemSymbolName: "q.circle", accessibilityDescription: nil) }

    var capabilities: ProviderCapabilities {
        [.realTimeEvents, .chatHistory, .transcriptAccess]
    }

    var isAvailable: Bool {
        get async {
            let fm = FileManager.default
            let home = fm.homeDirectoryForCurrentUser

            let candidates: [String] = [
                home.appendingPathComponent(".qoder").path,
                home.appendingPathComponent("Library/Application Support/Qoder").path,
                "/Applications/Qoder.app",
            ]
            return candidates.contains { fm.fileExists(atPath: $0) }
        }
    }

    var isHookInstalled: Bool {
        QoderHookInstaller.isInstalled()
    }

    var sessionsPublisher: AnyPublisher<[SessionState], Never> {
        SessionStore.shared.sessionsPublisher
            .map { sessions in
                sessions.filter { $0.providerId == "qoder" }
            }
            .eraseToAnyPublisher()
    }

    func start() async {
        logger.info("Starting Qoder provider")
        // Shared HookSocketServer already receives events from all providers.
    }

    func stop() async {
        logger.info("Stopping Qoder provider")
    }

    func installHooks() async {
        QoderHookInstaller.install()
        logger.info("Installed Qoder hooks")
    }

    func uninstallHooks() async {
        QoderHookInstaller.uninstall()
        logger.info("Uninstalled Qoder hooks")
    }

    // Qoder hook set does not include PermissionRequest in the IDE/JB plugin docs.
    // Keep these as no-ops; the shared UI can still call them safely.
    func approvePermission(sessionId: String, toolUseId: String) async {}
    func denyPermission(sessionId: String, toolUseId: String, reason: String?) async {}

    func loadHistory(sessionId: String, cwd: String) async {
        await SessionStore.shared.process(.loadHistory(sessionId: sessionId, cwd: cwd))
    }
}

// MARK: - Hook Installer

private enum QoderHookInstaller {
    static var userSettingsFile: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".qoder/settings.json")
    }

    static func install() {
        IslandPaths.ensureDirectoriesExist()

        logger.info("[Qoder] installHooks Bundle.main=\(Bundle.main.bundleURL.path, privacy: .public)")

        // 1) Copy Python hook script into ~/.coding-island/hooks/
        let hookScript = IslandPaths.qoderHookScriptPath
        if let bundled = Bundle.main.url(forResource: "coding-island-qoder-hook", withExtension: "py") {
            if let data = try? Data(contentsOf: bundled), let text = String(data: data, encoding: .utf8) {
                let hasVersion = text.contains("HOOK_VERSION")
                logger.info("[Qoder] bundled hook found at \(bundled.path, privacy: .public), size=\(data.count, privacy: .public), hasVersion=\(hasVersion, privacy: .public)")
            } else {
                logger.info("[Qoder] bundled hook found at \(bundled.path, privacy: .public) (could not read content)")
            }
            try? FileManager.default.removeItem(at: hookScript)
            try? FileManager.default.copyItem(at: bundled, to: hookScript)
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hookScript.path)
            if let data = try? Data(contentsOf: hookScript), let text = String(data: data, encoding: .utf8) {
                let hasVersion = text.contains("HOOK_VERSION")
                logger.info("[Qoder] installed hook at \(hookScript.path, privacy: .public), size=\(data.count, privacy: .public), hasVersion=\(hasVersion, privacy: .public)")
            }
            logger.info("Installed Qoder hook script")
        } else {
            logger.warning("Could not find bundled coding-island-qoder-hook.py")
        }

        // 2) Update ~/.qoder/settings.json
        updateSettings(at: userSettingsFile)
    }

    static func uninstall() {
        try? FileManager.default.removeItem(at: IslandPaths.qoderHookScriptPath)

        let settings = userSettingsFile
        guard let data = try? Data(contentsOf: settings),
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var hooks = json["hooks"] as? [String: Any] else {
            return
        }

        for (event, value) in hooks {
            if var groups = value as? [[String: Any]] {
                groups = groups.compactMap { removingCodingIslandQoderHooks(from: $0) }
                if groups.isEmpty {
                    hooks.removeValue(forKey: event)
                } else {
                    hooks[event] = groups
                }
            }
        }

        if hooks.isEmpty {
            json.removeValue(forKey: "hooks")
        } else {
            json["hooks"] = hooks
        }

        if let out = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
            try? out.write(to: settings)
        }
    }

    static func isInstalled() -> Bool {
        guard FileManager.default.fileExists(atPath: IslandPaths.qoderHookScriptPath.path) else {
            return false
        }

        let settings = userSettingsFile
        guard let data = try? Data(contentsOf: settings),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = json["hooks"] as? [String: Any] else {
            return false
        }

        for (_, value) in hooks {
            guard let groups = value as? [[String: Any]] else { continue }
            for group in groups {
                guard let groupHooks = group["hooks"] as? [[String: Any]] else { continue }
                for hook in groupHooks {
                    let cmd = hook["command"] as? String ?? ""
                    if cmd.contains("coding-island-qoder-hook.py") {
                        return true
                    }
                }
            }
        }
        return false
    }

    // MARK: - Settings JSON

    private static func updateSettings(at settingsURL: URL) {
        // Ensure ~/.qoder exists
        try? FileManager.default.createDirectory(
            at: settingsURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var json: [String: Any] = [:]
        if let data = try? Data(contentsOf: settingsURL),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            json = existing
        }

        let python = detectPython()
        let command = "\(python) \(IslandPaths.qoderHookScriptShellPath)"
        let marker = "coding-island-qoder-hook.py"

        let hookEntry: [String: Any] = [
            "type": "command",
            "command": command,
            "timeout": 300,
        ]

        let toolScopedConfig: [[String: Any]] = [[
            "matcher": "*",
            "hooks": [hookEntry],
        ]]

        let nonToolConfig: [[String: Any]] = [[
            "hooks": [hookEntry],
        ]]

        var hooks = json["hooks"] as? [String: Any] ?? [:]

        // Remove any existing Coding Island Qoder hooks from all events first.
        var cleanedHooks: [String: Any] = [:]
        for (event, value) in hooks {
            if let groups = value as? [[String: Any]] {
                let cleaned = groups.compactMap { removingCodingIslandQoderHooks(from: $0, marker: marker) }
                if !cleaned.isEmpty {
                    cleanedHooks[event] = cleaned
                }
            } else {
                cleanedHooks[event] = value
            }
        }
        hooks = cleanedHooks

        // Qoder IDE/JB plugin supports these five events.
        let events: [(String, [[String: Any]])] = [
            ("UserPromptSubmit", nonToolConfig),
            ("PreToolUse", toolScopedConfig),
            ("PostToolUse", toolScopedConfig),
            ("PostToolUseFailure", toolScopedConfig),
            ("Stop", nonToolConfig),
        ]

        for (event, config) in events {
            let existing = hooks[event] as? [[String: Any]] ?? []
            hooks[event] = existing + config
        }

        json["hooks"] = hooks

        if let out = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
            try? out.write(to: settingsURL)
        }
    }

    // MARK: - Helpers

    private static func detectPython() -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = ["python3"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                return "python3"
            }
        } catch {}

        return "python"
    }

    private static func removingCodingIslandQoderHooks(from group: [String: Any], marker: String = "coding-island-qoder-hook.py") -> [String: Any]? {
        guard var hooks = group["hooks"] as? [[String: Any]] else {
            return group
        }

        hooks.removeAll(where: { hook in
            let cmd = hook["command"] as? String ?? ""
            return cmd.contains(marker)
        })

        guard !hooks.isEmpty else { return nil }
        var updated = group
        updated["hooks"] = hooks
        return updated
    }
}
