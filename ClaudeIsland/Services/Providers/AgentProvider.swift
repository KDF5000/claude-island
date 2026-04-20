//
//  AgentProvider.swift
//  ClaudeIsland
//
//  Provider protocol for supporting multiple AI coding agents
//  Enables extensibility to Coco, Cursor, Aider, etc.
//

import Combine
import Foundation
import AppKit

// MARK: - Provider Capabilities

/// Capabilities that a provider may support
struct ProviderCapabilities: OptionSet, Sendable {
    let rawValue: Int

    static let realTimeEvents = ProviderCapabilities(rawValue: 1 << 0)
    static let permissionControl = ProviderCapabilities(rawValue: 1 << 1)
    static let chatHistory = ProviderCapabilities(rawValue: 1 << 2)
    static let subagentTracking = ProviderCapabilities(rawValue: 1 << 3)
    static let transcriptAccess = ProviderCapabilities(rawValue: 1 << 4)  // Access to conversation transcript
}

// MARK: - Provider Info

/// Static information about a provider
struct ProviderInfo: Sendable {
    let id: String
    let displayName: String
    let icon: String  // SF Symbol name or asset name
    let capabilities: ProviderCapabilities
    let configPath: String  // Default config file path
}

// MARK: - Agent Provider Protocol

/// Protocol that all AI coding agent providers must implement
protocol AgentProvider: AnyObject {
    // MARK: - Identity

    /// Unique identifier for this provider
    var providerId: String { get }

    /// Human-readable display name
    var displayName: String { get }

    /// Icon for UI display
    var icon: NSImage? { get }

    /// Provider capabilities
    var capabilities: ProviderCapabilities { get }

    // MARK: - State

    /// Whether the provider is currently available (CLI installed, etc.)
    var isAvailable: Bool { get async }

    /// Whether hooks are installed for this provider
    var isHookInstalled: Bool { get }

    // MARK: - Events

    /// Publisher for session state changes
    var sessionsPublisher: AnyPublisher<[SessionState], Never> { get }

    // MARK: - Lifecycle

    /// Start monitoring this provider
    func start() async

    /// Stop monitoring this provider
    func stop() async

    /// Install hooks for this provider
    func installHooks() async

    /// Uninstall hooks for this provider
    func uninstallHooks() async

    // MARK: - Permission Control

    /// Approve a pending permission request
    func approvePermission(sessionId: String, toolUseId: String) async

    /// Deny a pending permission request
    func denyPermission(sessionId: String, toolUseId: String, reason: String?) async

    // MARK: - History

    /// Load chat history for a session
    func loadHistory(sessionId: String, cwd: String) async
}

// MARK: - Default Implementations

extension AgentProvider {
    var capabilities: ProviderCapabilities {
        [.realTimeEvents, .permissionControl, .chatHistory]
    }

    var isHookInstalled: Bool { false }

    func installHooks() async {}
    func uninstallHooks() async {}
    func loadHistory(sessionId: String, cwd: String) async {}
}

// MARK: - Provider Factory

/// Protocol for creating provider instances
protocol AgentProviderFactory {
    static var providerInfo: ProviderInfo { get }
    static func create() -> AgentProvider
}
