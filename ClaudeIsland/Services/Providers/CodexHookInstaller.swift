//
//  CodexHookInstaller.swift
//  ClaudeIsland
//
//  Installs hooks for OpenAI Codex CLI.
//  - Copies Coding Island's Codex hook script into ~/.coding-island/hooks/
//  - Enables codex_hooks in ~/.codex/config.toml
//  - Upserts hooks into ~/.codex/hooks.json
//

import Foundation
import os.log

private let logger = Logger(subsystem: "com.codingisland", category: "CodexHooks")

struct CodexHookInstaller {

    // MARK: - Installation

    static func install() {
        // 1) Ensure directories exist
        IslandPaths.ensureDirectoriesExist()
        try? FileManager.default.createDirectory(
            at: CodexPaths.codexDir,
            withIntermediateDirectories: true
        )

        // 2) Copy Python hook script into ~/.coding-island/hooks/
        let hookScript = IslandPaths.codexHookScriptPath
        if let bundled = Bundle.main.url(forResource: "coding-island-codex-hook", withExtension: "py") {
            try? FileManager.default.removeItem(at: hookScript)
            try? FileManager.default.copyItem(at: bundled, to: hookScript)
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hookScript.path)
            logger.info("Installed Codex hook script")
        } else {
            logger.warning("Could not find bundled coding-island-codex-hook.py")
        }

        // 3) Enable hooks feature
        updateConfigToml()

        // 4) Upsert hooks.json
        updateHooksJSON()
    }

    static func uninstall() {
        // Remove hook script
        try? FileManager.default.removeItem(at: IslandPaths.codexHookScriptPath)

        // Remove our entries from hooks.json
        removeHooksFromHooksJSON()

        logger.info("Uninstalled Codex hooks")
    }

    static func isInstalled() -> Bool {
        guard FileManager.default.fileExists(atPath: IslandPaths.codexHookScriptPath.path) else {
            return false
        }
        let hooksContent = (try? String(contentsOf: CodexPaths.hooksFile, encoding: .utf8)) ?? ""
        return hooksContent.contains("coding-island-codex-hook.py")
    }

    // MARK: - config.toml

    private static func updateConfigToml() {
        let path = CodexPaths.configFile
        let existing = (try? String(contentsOf: path, encoding: .utf8)) ?? ""
        let updated = upsertCodexHooksFeature(in: existing)
        do {
            try updated.write(to: path, atomically: true, encoding: .utf8)
            logger.info("Updated Codex config at \(path.path, privacy: .public)")
        } catch {
            logger.error("Failed to write Codex config: \(error, privacy: .public)")
        }
    }

    private static func upsertCodexHooksFeature(in content: String) -> String {
        var lines = content.components(separatedBy: "\n")

        func isSectionHeader(_ s: String) -> Bool {
            let t = s.trimmingCharacters(in: .whitespaces)
            return t.hasPrefix("[") && t.hasSuffix("]")
        }

        // Find [features]
        if let idx = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "[features]" }) {
            // Find section end
            var end = lines.count
            if idx + 1 < lines.count {
                for i in (idx + 1)..<lines.count {
                    if isSectionHeader(lines[i]) {
                        end = i
                        break
                    }
                }
            }

            // Upsert codex_hooks
            var found = false
            for i in (idx + 1)..<end {
                let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("codex_hooks") {
                    lines[i] = "codex_hooks = true"
                    found = true
                    break
                }
            }
            if !found {
                lines.insert("codex_hooks = true", at: end)
            }
            return lines.joined(separator: "\n")
        }

        // No [features] section, append one.
        var result = content
        if !result.isEmpty && !result.hasSuffix("\n") {
            result += "\n"
        }
        let separator = result.isEmpty ? "" : "\n"
        return result + separator + "[features]\n" + "codex_hooks = true\n"
    }

    // MARK: - hooks.json

    private static func updateHooksJSON() {
        let hooksPath = CodexPaths.hooksFile

        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: hooksPath),
           let json = try? JSONSerialization.jsonObject(with: data),
           let obj = json as? [String: Any] {
            root = obj
        }

        var hooks = (root["hooks"] as? [String: Any]) ?? [:]

        let python = detectPython()
        let command = "\(python) \(IslandPaths.codexHookScriptShellPath)"
        let marker = "coding-island-codex-hook.py"

        // Tool-scoped events use matcher on tool_name. Non-tool events ignore matcher.
        let toolEvents: [String] = ["PreToolUse", "PermissionRequest", "PostToolUse"]
        let nonToolEvents: [String] = ["SessionStart", "UserPromptSubmit", "Stop"]

        for eventName in toolEvents {
            hooks[eventName] = upsertEventHooks(
                existing: hooks[eventName],
                matcher: ".*",
                command: command,
                marker: marker,
                statusMessage: "Coding Island"
            )
        }

        for eventName in nonToolEvents {
            hooks[eventName] = upsertEventHooks(
                existing: hooks[eventName],
                matcher: ".*",
                command: command,
                marker: marker,
                statusMessage: "Coding Island"
            )
        }

        root["hooks"] = hooks

        do {
            let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: hooksPath, options: [.atomic])
            logger.info("Updated Codex hooks at \(hooksPath.path, privacy: .public)")
        } catch {
            logger.error("Failed to write Codex hooks.json: \(error, privacy: .public)")
        }
    }

    private static func removeHooksFromHooksJSON() {
        let hooksPath = CodexPaths.hooksFile
        guard let data = try? Data(contentsOf: hooksPath),
              let json = try? JSONSerialization.jsonObject(with: data),
              var root = json as? [String: Any] else {
            return
        }

        guard var hooks = root["hooks"] as? [String: Any] else { return }

        for (eventName, value) in hooks {
            guard let arr = value as? [[String: Any]] else { continue }
            let kept = arr.compactMap { group -> [String: Any]? in
                guard let groupHooks = group["hooks"] as? [[String: Any]] else { return group }
                let filtered = groupHooks.filter { hook in
                    let cmd = hook["command"] as? String
                    return !(cmd?.contains("coding-island-codex-hook.py") ?? false)
                }
                if filtered.isEmpty { return nil }
                var updated = group
                updated["hooks"] = filtered
                return updated
            }
            hooks[eventName] = kept
        }

        root["hooks"] = hooks
        do {
            let newData = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
            try newData.write(to: hooksPath, options: [.atomic])
        } catch {
            logger.error("Failed to remove Codex hooks.json entries: \(error, privacy: .public)")
        }
    }

    private static func upsertEventHooks(
        existing: Any?,
        matcher: String,
        command: String,
        marker: String,
        statusMessage: String
    ) -> [[String: Any]] {
        var groups: [[String: Any]] = (existing as? [[String: Any]]) ?? []

        // Prefer updating an existing group that already contains our marker.
        if let idx = groups.firstIndex(where: { group in
            guard let hooks = group["hooks"] as? [[String: Any]] else { return false }
            return hooks.contains(where: { ($0["command"] as? String)?.contains(marker) == true })
        }) {
            var group = groups[idx]
            var hooks = (group["hooks"] as? [[String: Any]]) ?? []
            hooks.removeAll(where: { ($0["command"] as? String)?.contains(marker) == true })
            hooks.append([
                "type": "command",
                "command": command,
                "timeout": 300,
                "statusMessage": statusMessage,
            ])
            group["matcher"] = matcher
            group["hooks"] = hooks
            groups[idx] = group
            return groups
        }

        // Otherwise append a new group.
        groups.append([
            "matcher": matcher,
            "hooks": [[
                "type": "command",
                "command": command,
                "timeout": 300,
                "statusMessage": statusMessage,
            ]],
        ])
        return groups
    }

    // MARK: - Helpers

    private static func detectPython() -> String {
        let candidates = [
            "/usr/bin/python3",
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3",
        ]
        for p in candidates {
            if FileManager.default.fileExists(atPath: p) {
                return p
            }
        }
        return "python3"
    }
}

