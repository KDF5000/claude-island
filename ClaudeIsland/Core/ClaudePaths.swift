//
//  ClaudePaths.swift
//  ClaudeIsland
//
//  Single source of truth for Claude Code config directory paths.
//  Resolves automatically via CLAUDE_CONFIG_DIR env var or filesystem detection.
//  Agent-independent paths (hooks, socket, cache) live in IslandPaths.
//

import Foundation

enum ClaudePaths {

    /// Cached resolved directory to avoid filesystem checks on every access
    private static var _cachedDir: URL?

    /// Guards reads/writes to _cachedDir — accessed from the main actor
    /// (UI settings), the ConversationParser actor, and background watcher
    /// queues, so cross-thread access needs synchronization.
    private static let cacheLock = NSLock()

    /// Root Claude config directory, resolved once and cached.
    ///
    /// Resolution order:
    /// 1. CLAUDE_CONFIG_DIR environment variable (if set and exists)
    /// 2. ~/.config/claude/ (new default since Claude Code v2.1.30+, if projects/ exists)
    /// 3. ~/.claude/ (legacy fallback)
    static var claudeDir: URL {
        cacheLock.lock()
        if let cached = _cachedDir {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        // Resolve outside the lock — involves filesystem reads
        // that shouldn't block other threads.
        let resolved = resolveClaudeDir()

        cacheLock.lock()
        // Another thread may have populated the cache while we were resolving;
        // prefer theirs for consistency, but either value is correct.
        if let existing = _cachedDir {
            cacheLock.unlock()
            return existing
        }
        _cachedDir = resolved
        cacheLock.unlock()
        return resolved
    }

    static var settingsFile: URL {
        claudeDir.appendingPathComponent("settings.json")
    }

    static var projectsDir: URL {
        claudeDir.appendingPathComponent("projects")
    }

    /// Invalidate the cached directory so the next access re-resolves.
    static func invalidateCache() {
        cacheLock.lock()
        _cachedDir = nil
        cacheLock.unlock()
    }

    private static func resolveClaudeDir() -> URL {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser

        // 1. CLAUDE_CONFIG_DIR env var takes highest priority
        if let envDir = Foundation.ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"] {
            let expanded = (envDir as NSString).expandingTildeInPath
            let url = URL(fileURLWithPath: expanded)
            if fm.fileExists(atPath: url.path) {
                return url
            }
        }

        // 2. New default ~/.config/claude/ (if projects/ exists there)
        let newDefault = home.appendingPathComponent(".config/claude")
        if fm.fileExists(atPath: newDefault.appendingPathComponent("projects").path) {
            return newDefault
        }

        // 3. Legacy fallback
        return home.appendingPathComponent(".claude")
    }
}
