//
//  IslandPaths.swift
//  ClaudeIsland
//
//  Single source of truth for Coding Island's own directory structure.
//  All agent-independent files (hooks, socket, cache, logs) live under
//  ~/.coding-island/.  Agent-specific config/data paths remain in
//  ClaudePaths and CocoPaths.
//

import Foundation

enum IslandPaths {

    // MARK: - Root

    /// Root shared directory: ~/.coding-island/
    static var rootDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".coding-island")
    }

    // MARK: - Hooks

    /// Hooks directory: ~/.coding-island/hooks/
    static var hooksDir: URL {
        rootDir.appendingPathComponent("hooks")
    }

    /// Claude Code hook script: ~/.coding-island/hooks/coding-island-claude-hook.py
    static var claudeHookScriptPath: URL {
        hooksDir.appendingPathComponent("coding-island-claude-hook.py")
    }

    /// Shell-safe path for Claude hook commands in settings.json
    static var claudeHookScriptShellPath: String {
        shellQuote(claudeHookScriptPath.path)
    }

    /// Coco/Trae hook script: ~/.coding-island/hooks/coding-island-coco-hook.py
    static var cocoHookScriptPath: URL {
        hooksDir.appendingPathComponent("coding-island-coco-hook.py")
    }

    /// Shell-safe path for Coco hook commands in YAML config
    static var cocoHookScriptShellPath: String {
        shellQuote(cocoHookScriptPath.path)
    }

    /// Remote hook script: ~/.coding-island/hooks/coding-island-remote-hook.py
    static var remoteHookScriptPath: URL {
        hooksDir.appendingPathComponent("coding-island-remote-hook.py")
    }

    // MARK: - Socket

    /// Unix domain socket path for IPC: ~/.coding-island/coding-island.sock
    static var socketPath: String {
        rootDir.appendingPathComponent("coding-island.sock").path
    }

    // MARK: - Cache

    /// Remote session JSONL cache: ~/.coding-island/cache/remote-sessions/
    static var remoteCacheDir: URL {
        rootDir.appendingPathComponent("cache/remote-sessions")
    }

    // MARK: - Logs

    /// Debug logs directory: ~/.coding-island/logs/
    static var logsDir: URL {
        rootDir.appendingPathComponent("logs")
    }

    // MARK: - Directory Management

    /// Ensure the root directory and standard subdirectories exist.
    /// Call on app launch before any socket binding or file writes.
    static func ensureDirectoriesExist() {
        let fm = FileManager.default
        let dirs = [rootDir, hooksDir, remoteCacheDir, logsDir]
        for dir in dirs {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    /// Remove old hooks from agent-specific directories (migration from pre-0.x).
    /// Called once on app launch after upgrade.
    static func cleanupLegacyHooks() {
        let fm = FileManager.default

        // Old Claude hook scripts that lived inside Claude's config dir
        let legacyScripts = [
            ClaudePaths.claudeDir.appendingPathComponent("hooks/claude-island-state.py"),
            ClaudePaths.claudeDir.appendingPathComponent("hooks/coco-island-state.py"),
        ]
        for path in legacyScripts {
            if fm.fileExists(atPath: path.path) {
                try? fm.removeItem(at: path)
            }
        }
    }

    // MARK: - Private

    private static func shellQuote(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
