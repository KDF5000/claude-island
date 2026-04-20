//
//  CocoProvider.swift
//  ClaudeIsland
//
//  Provider implementation for Coco (Trae CLI)
//  Uses the same socket infrastructure as Claude Code
//

import Combine
import Foundation
import AppKit
import os.log

private let logger = Logger(subsystem: "com.claudeisland", category: "CocoProvider")

// MARK: - Coco Provider Factory

struct CocoProviderFactory: AgentProviderFactory {
    static var providerInfo: ProviderInfo {
        ProviderInfo(
            id: "coco",
            displayName: "Coco",
            icon: "coco-icon",
            capabilities: [.realTimeEvents, .permissionControl, .chatHistory, .transcriptAccess],
            configPath: CocoPaths.configFile.path
        )
    }

    static func create() -> AgentProvider {
        CocoProvider()
    }
}

// MARK: - Coco Provider

class CocoProvider: AgentProvider {
    let providerId = "coco"
    let displayName = "Coco"
    var icon: NSImage? { NSImage(named: "coco-icon") }

    var capabilities: ProviderCapabilities {
        [.realTimeEvents, .permissionControl, .chatHistory, .transcriptAccess]
    }

    var isAvailable: Bool {
        get async {
            CocoPaths.isCocoInstalled
        }
    }

    var isHookInstalled: Bool {
        CocoHookInstaller.isInstalled()
    }

    // Session publisher - uses SessionStore with provider filtering
    var sessionsPublisher: AnyPublisher<[SessionState], Never> {
        SessionStore.shared.sessionsPublisher
            .map { sessions in
                sessions.filter { $0.providerId == "coco" }
            }
            .eraseToAnyPublisher()
    }

    func start() async {
        logger.info("Starting Coco provider")

        // Install hooks if needed
        if !isHookInstalled {
            await installHooks()
        }

        // The shared HookSocketServer already handles events from all providers
        // We just need to ensure our hooks are installed
    }

    func stop() async {
        logger.info("Stopping Coco provider")
        // Keep hooks installed for next session
    }

    func installHooks() async {
        CocoHookInstaller.install()
        logger.info("Installed Coco hooks")
    }

    func uninstallHooks() async {
        CocoHookInstaller.uninstall()
        logger.info("Uninstalled Coco hooks")
    }

    func approvePermission(sessionId: String, toolUseId: String) async {
        logger.debug("Approving permission for Coco session: \(sessionId.prefix(8), privacy: .public)")

        HookSocketServer.shared.respondToPermission(
            toolUseId: toolUseId,
            decision: "allow"
        )

        await SessionStore.shared.process(
            .permissionApproved(sessionId: sessionId, toolUseId: toolUseId)
        )
    }

    func denyPermission(sessionId: String, toolUseId: String, reason: String?) async {
        logger.debug("Denying permission for Coco session: \(sessionId.prefix(8), privacy: .public)")

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
        // Coco provides transcript_path in events, we can parse that file
        // For now, use the standard history loading
        await SessionStore.shared.process(.loadHistory(sessionId: sessionId, cwd: cwd))
    }
}
