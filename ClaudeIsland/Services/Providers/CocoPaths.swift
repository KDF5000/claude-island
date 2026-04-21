//
//  CocoPaths.swift
//  ClaudeIsland
//
//  Path resolution for Coco (Trae CLI) configuration files
//

import Foundation

enum CocoPaths {

    /// Coco/Trae config directory
    static var cocoDir: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser

        // Try common locations (new Trae CLI path first)
        let candidates = [
            home.appendingPathComponent(".trae"),           // New Trae CLI path
            home.appendingPathComponent(".config/coco"),    // Old Coco path
            home.appendingPathComponent(".coco"),           // Old alternative
        ]

        for candidate in candidates {
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }

        // Default to new Trae CLI path
        return home.appendingPathComponent(".trae")
    }

    /// Coco config file (YAML format)
    static var configFile: URL {
        // Check for existing config files
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent(".trae/traecli.yaml"),      // New Trae CLI
            home.appendingPathComponent(".config/coco/config.yaml"), // Old Coco
            home.appendingPathComponent(".coco/coco.yaml"),          // Old alternative
        ]

        for candidate in candidates {
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }

        // Default to new Trae CLI path
        return home.appendingPathComponent(".trae/traecli.yaml")
    }

    /// Alternative config file location
    static var altConfigFile: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".coco.yaml")
    }

    /// Hooks directory (shared via IslandPaths)
    static var hooksDir: URL {
        IslandPaths.hooksDir
    }

    /// Hook script path
    static var hookScriptPath: URL {
        IslandPaths.cocoHookScriptPath
    }

    /// Shell-safe path for hook commands
    static var hookScriptShellPath: String {
        IslandPaths.cocoHookScriptShellPath
    }

    /// Coco transcript directory (if available)
    static var transcriptsDir: URL {
        cocoDir.appendingPathComponent("transcripts")
    }

    /// Check if Coco CLI is installed
    static var isCocoInstalled: Bool {
        let candidates = [
            "/usr/local/bin/coco",
            "/opt/homebrew/bin/coco",
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".local/bin/coco").path,
        ]
        return candidates.contains { FileManager.default.fileExists(atPath: $0) }
    }
}
