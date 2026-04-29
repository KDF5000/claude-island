//
//  CodeBuddyProvider.swift
//  ClaudeIsland
//
//  Provider implementation for Tencent CodeBuddy.
//  Installs a hook script into ~/.codebuddy/settings.json and forwards events
//  to Coding Island via the shared HookSocketServer socket.
//

import Combine
import Foundation
import AppKit
import os.log

private let logger = Logger(subsystem: "com.codingisland", category: "CodeBuddyProvider")

// MARK: - CodeBuddy Provider Factory

struct CodeBuddyProviderFactory: AgentProviderFactory {
    static var providerInfo: ProviderInfo {
        ProviderInfo(
            id: "codebuddy",
            displayName: "CodeBuddy",
            icon: "terminal",
            capabilities: [.realTimeEvents, .permissionControl, .chatHistory, .transcriptAccess],
            configPath: CodeBuddyHookInstaller.userSettingsFile.path
        )
    }

    static func create() -> AgentProvider {
        CodeBuddyProvider()
    }
}

// MARK: - CodeBuddy Provider

final class CodeBuddyProvider: AgentProvider {
    let providerId = "codebuddy"
    let displayName = "CodeBuddy"
    var icon: NSImage? { NSImage(systemSymbolName: "terminal", accessibilityDescription: nil) }

    var capabilities: ProviderCapabilities {
        [.realTimeEvents, .permissionControl, .chatHistory, .transcriptAccess]
    }

    var isAvailable: Bool {
        get async {
            CodeBuddyHookInstaller.hasAnyCodeBuddyFootprint()
        }
    }

    var isHookInstalled: Bool {
        CodeBuddyHookInstaller.isInstalled()
    }

    var sessionsPublisher: AnyPublisher<[SessionState], Never> {
        SessionStore.shared.sessionsPublisher
            .map { sessions in
                sessions.filter { $0.providerId == "codebuddy" }
            }
            .eraseToAnyPublisher()
    }

    func start() async {
        logger.info("Starting CodeBuddy provider")
        // Shared HookSocketServer already receives events from all providers.
    }

    func stop() async {
        logger.info("Stopping CodeBuddy provider")
    }

    func installHooks() async {
        CodeBuddyHookInstaller.install()
        logger.info("Installed CodeBuddy hooks")
    }

    func uninstallHooks() async {
        CodeBuddyHookInstaller.uninstall()
        logger.info("Uninstalled CodeBuddy hooks")
    }

    func approvePermission(sessionId: String, toolUseId: String) async {
        HookSocketServer.shared.respondToPermission(toolUseId: toolUseId, decision: "allow")
        await SessionStore.shared.process(.permissionApproved(sessionId: sessionId, toolUseId: toolUseId))
    }

    func denyPermission(sessionId: String, toolUseId: String, reason: String?) async {
        HookSocketServer.shared.respondToPermission(toolUseId: toolUseId, decision: "deny", reason: reason)
        await SessionStore.shared.process(.permissionDenied(sessionId: sessionId, toolUseId: toolUseId, reason: reason))
    }

    func loadHistory(sessionId: String, cwd: String) async {
        await SessionStore.shared.process(.loadHistory(sessionId: sessionId, cwd: cwd))
    }
}

// MARK: - Hook Installer

private enum CodeBuddyHookInstaller {
    private static let marker = "coding-island-codebuddy-hook.py"

    static var userSettingsFile: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codebuddy/settings.json")
    }

    static func projectSettingsFile(for cwd: String) -> URL {
        URL(fileURLWithPath: cwd).appendingPathComponent(".codebuddy/settings.json")
    }

    static func install() {
        IslandPaths.ensureDirectoriesExist()
        try? FileManager.default.createDirectory(
            at: userSettingsFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let hookScript = IslandPaths.codebuddyHookScriptPath
        if let bundled = Bundle.main.url(forResource: "coding-island-codebuddy-hook", withExtension: "py") {
            try? FileManager.default.removeItem(at: hookScript)
            try? FileManager.default.copyItem(at: bundled, to: hookScript)
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hookScript.path)
            logger.info("Installed CodeBuddy hook script")
        } else {
            logger.warning("Could not find bundled coding-island-codebuddy-hook.py")
        }

        updateSettings(at: userSettingsFile)
    }

    static func uninstall() {
        try? FileManager.default.removeItem(at: IslandPaths.codebuddyHookScriptPath)
        removeCodingIslandHooks(from: userSettingsFile)
    }

    static func isInstalled() -> Bool {
        guard FileManager.default.fileExists(atPath: IslandPaths.codebuddyHookScriptPath.path) else {
            return false
        }
        return settingsContainMarker(userSettingsFile, marker: marker)
    }

    static func hasAnyCodeBuddyFootprint() -> Bool {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let candidates: [String] = [
            home.appendingPathComponent(".codebuddy").path,
            home.appendingPathComponent("Library/Application Support/CodeBuddy").path,
            "/usr/local/bin/codebuddy",
            "/opt/homebrew/bin/codebuddy",
            home.appendingPathComponent(".local/bin/codebuddy").path,
            "/Applications/CodeBuddy.app",
        ]
        return candidates.contains { fm.fileExists(atPath: $0) }
    }

    private static func updateSettings(at settingsURL: URL) {
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
        let command = "\(python) \(IslandPaths.codebuddyHookScriptShellPath)"
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
        hooks = cleanedHooksMap(hooks)

        let events: [(String, [[String: Any]])] = [
            ("SessionStart", nonToolConfig),
            ("SessionEnd", nonToolConfig),
            ("UserPromptSubmit", nonToolConfig),
            ("PreToolUse", toolScopedConfig),
            ("PostToolUse", toolScopedConfig),
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

    private static func removeCodingIslandHooks(from settingsURL: URL) {
        guard let data = try? Data(contentsOf: settingsURL),
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var hooks = json["hooks"] as? [String: Any] else {
            return
        }

        hooks = cleanedHooksMap(hooks)

        if hooks.isEmpty {
            json.removeValue(forKey: "hooks")
        } else {
            json["hooks"] = hooks
        }

        if let out = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
            try? out.write(to: settingsURL)
        }
    }

    private static func cleanedHooksMap(_ hooks: [String: Any]) -> [String: Any] {
        var cleanedHooks: [String: Any] = [:]

        for (event, value) in hooks {
            if let groups = value as? [[String: Any]] {
                let cleaned = groups.compactMap { removingCodingIslandHooks(from: $0) }
                if !cleaned.isEmpty {
                    cleanedHooks[event] = cleaned
                }
            } else {
                cleanedHooks[event] = value
            }
        }

        return cleanedHooks
    }

    private static func settingsContainMarker(_ settingsURL: URL, marker: String) -> Bool {
        guard let data = try? Data(contentsOf: settingsURL),
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
                    if cmd.contains(marker) {
                        return true
                    }
                }
            }
        }

        return false
    }

    private static func detectPython() -> String {
        let candidates = [
            "/usr/bin/python3",
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3",
        ]

        for path in candidates where FileManager.default.fileExists(atPath: path) {
            return path
        }

        return "python3"
    }

    private static func removingCodingIslandHooks(from group: [String: Any]) -> [String: Any]? {
        guard var hooks = group["hooks"] as? [[String: Any]] else {
            return group
        }

        hooks.removeAll { hook in
            let cmd = hook["command"] as? String ?? ""
            return cmd.contains(marker)
        }

        guard !hooks.isEmpty else { return nil }
        var updated = group
        updated["hooks"] = hooks
        return updated
    }
}
