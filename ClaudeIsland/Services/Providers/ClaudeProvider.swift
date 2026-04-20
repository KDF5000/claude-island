//
//  ClaudeProvider.swift
//  ClaudeIsland
//
//  Provider implementation for Claude Code CLI
//  Wraps the existing HookSocketServer and SessionStore
//

import Combine
import Foundation
import AppKit

// MARK: - Claude Provider Factory

struct ClaudeProviderFactory: AgentProviderFactory {
    static var providerInfo: ProviderInfo {
        ProviderInfo(
            id: "claude-code",
            displayName: "Claude Code",
            icon: "claude-icon",
            capabilities: [.realTimeEvents, .permissionControl, .chatHistory, .subagentTracking],
            configPath: ClaudePaths.settingsFile.path
        )
    }

    static func create() -> AgentProvider {
        ClaudeProvider()
    }
}

// MARK: - Claude Provider

class ClaudeProvider: AgentProvider {
    let providerId = "claude-code"
    let displayName = "Claude Code"
    var icon: NSImage? { NSImage(named: "claude-icon") }

    var capabilities: ProviderCapabilities {
        [.realTimeEvents, .permissionControl, .chatHistory, .subagentTracking]
    }

    var isAvailable: Bool {
        get async {
            // Check if Claude Code CLI is installed
            let candidates = [
                "/usr/local/bin/claude",
                "/opt/homebrew/bin/claude",
                NSHomeDirectory() + "/.claude/local/claude",
                NSHomeDirectory() + "/.local/bin/claude",
            ]
            return candidates.contains { FileManager.default.fileExists(atPath: $0) }
        }
    }

    var isHookInstalled: Bool {
        HookInstaller.isInstalled()
    }

    // Session publisher from SessionStore
    var sessionsPublisher: AnyPublisher<[SessionState], Never> {
        SessionStore.shared.sessionsPublisher
    }

    func start() async {
        // Install hooks if needed
        if !isHookInstalled {
            await installHooks()
        }

        // Start monitoring (handled by ClaudeSessionMonitor)
    }

    func stop() async {
        // Stop monitoring (handled by ClaudeSessionMonitor)
    }

    func installHooks() async {
        HookInstaller.installIfNeeded()
    }

    func uninstallHooks() async {
        HookInstaller.uninstall()
    }

    func approvePermission(sessionId: String, toolUseId: String) async {
        HookSocketServer.shared.respondToPermission(
            toolUseId: toolUseId,
            decision: "allow"
        )

        await SessionStore.shared.process(
            .permissionApproved(sessionId: sessionId, toolUseId: toolUseId)
        )
    }

    func denyPermission(sessionId: String, toolUseId: String, reason: String?) async {
        HookSocketServer.shared.respondToPermission(
            toolUseId: toolUseId,
            decision: "deny",
            reason: reason
        )

        await SessionStore.shared.process(
            .permissionDenied(sessionId: sessionId, toolUseId: toolUseId, reason: reason)
        )
    }

    func loadHistory(sessionId: String, cwd: String) async {
        await SessionStore.shared.process(.loadHistory(sessionId: sessionId, cwd: cwd))
    }
}
