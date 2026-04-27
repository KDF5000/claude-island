//
//  CodexProvider.swift
//  ClaudeIsland
//
//  Provider implementation for OpenAI Codex CLI.
//  Uses the shared HookSocketServer + SessionStore infrastructure.
//

import Combine
import Foundation
import AppKit
import os.log

private let logger = Logger(subsystem: "com.codingisland", category: "CodexProvider")

// MARK: - Codex Provider Factory

struct CodexProviderFactory: AgentProviderFactory {
    static var providerInfo: ProviderInfo {
        ProviderInfo(
            id: "codex",
            displayName: "Codex",
            icon: "terminal",
            capabilities: [.realTimeEvents, .permissionControl, .chatHistory, .transcriptAccess],
            configPath: CodexPaths.configFile.path
        )
    }

    static func create() -> AgentProvider {
        CodexProvider()
    }
}

// MARK: - Codex Provider

final class CodexProvider: AgentProvider {
    let providerId = "codex"
    let displayName = "Codex"
    var icon: NSImage? { NSImage(systemSymbolName: "terminal", accessibilityDescription: nil) }

    var capabilities: ProviderCapabilities {
        [.realTimeEvents, .permissionControl, .chatHistory, .transcriptAccess]
    }

    var isAvailable: Bool {
        get async {
            let candidates = [
                "/usr/local/bin/codex",
                "/opt/homebrew/bin/codex",
                NSHomeDirectory() + "/.local/bin/codex",
            ]
            return candidates.contains { FileManager.default.fileExists(atPath: $0) }
        }
    }

    var isHookInstalled: Bool {
        CodexHookInstaller.isInstalled()
    }

    var sessionsPublisher: AnyPublisher<[SessionState], Never> {
        SessionStore.shared.sessionsPublisher
            .map { sessions in
                sessions.filter { $0.providerId == "codex" || $0.providerId == "codex-remote" }
            }
            .eraseToAnyPublisher()
    }

    func start() async {
        logger.info("Starting Codex provider")
        // Shared HookSocketServer already receives events from all providers.
    }

    func stop() async {
        logger.info("Stopping Codex provider")
    }

    func installHooks() async {
        CodexHookInstaller.install()
        logger.info("Installed Codex hooks")
    }

    func uninstallHooks() async {
        CodexHookInstaller.uninstall()
        logger.info("Uninstalled Codex hooks")
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

