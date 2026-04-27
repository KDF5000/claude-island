//
//  CodexPaths.swift
//  ClaudeIsland
//
//  Paths for OpenAI Codex CLI configuration.
//  Codex supports user-level (~/.codex) and project-level (.codex) configs.
//  For hook installation we manage the user-level config by default.
//

import Foundation

enum CodexPaths {
    /// User config directory: ~/.codex/
    static var codexDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex")
    }

    /// User config file: ~/.codex/config.toml
    static var configFile: URL {
        codexDir.appendingPathComponent("config.toml")
    }

    /// User hooks file: ~/.codex/hooks.json
    static var hooksFile: URL {
        codexDir.appendingPathComponent("hooks.json")
    }
}

