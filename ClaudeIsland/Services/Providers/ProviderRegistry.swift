//
//  ProviderRegistry.swift
//  ClaudeIsland
//
//  Central registry for all AI coding agent providers
//  Manages provider lifecycle and aggregates sessions from all providers
//

import Combine
import Foundation
import os.log

private let logger = Logger(subsystem: "com.codingisland", category: "Providers")

/// Central registry for all agent providers
@MainActor
class ProviderRegistry: ObservableObject {
    static let shared = ProviderRegistry()

    // MARK: - Published State

    /// All registered provider factories
    @Published private(set) var registeredFactories: [String: AgentProviderFactory.Type] = [:]

    /// Active provider instances
    @Published private(set) var activeProviders: [String: AgentProvider] = [:]

    /// Aggregated sessions from all providers
    @Published private(set) var allSessions: [SessionState] = []

    /// Provider availability status
    @Published private(set) var providerAvailability: [String: Bool] = [:]

    // MARK: - Private

    private var cancellables = Set<AnyCancellable>()
    private var sessionCancellables: [String: Set<AnyCancellable>] = [:]

    // MARK: - Initialization

    private init() {
        // Register built-in providers
        register(ClaudeProviderFactory.self)
        register(CocoProviderFactory.self)
    }

    // MARK: - Registration

    /// Register a provider factory
    func register(_ factory: AgentProviderFactory.Type) {
        let info = factory.providerInfo
        registeredFactories[info.id] = factory
        logger.info("Registered provider: \(info.id, privacy: .public)")
    }

    // MARK: - Lifecycle

    /// Activate a provider by ID
    func activate(providerId: String) async {
        guard let factory = registeredFactories[providerId] else {
            logger.warning("Unknown provider: \(providerId, privacy: .public)")
            return
        }

        // Check if already active
        if activeProviders[providerId] != nil {
            logger.debug("Provider already active: \(providerId, privacy: .public)")
            return
        }

        // Create and start provider
        let provider = factory.create()

        // Check availability
        let available = await provider.isAvailable
        providerAvailability[providerId] = available

        guard available else {
            logger.info("Provider not available: \(providerId, privacy: .public)")
            return
        }

        // Install hooks if not already installed
        if !provider.isHookInstalled {
            await provider.installHooks()
        }

        // Start monitoring
        await provider.start()

        // Subscribe to sessions
        subscribeToProvider(provider)

        activeProviders[providerId] = provider
        logger.info("Activated provider: \(providerId, privacy: .public)")
    }

    /// Deactivate a provider
    func deactivate(providerId: String) async {
        guard let provider = activeProviders[providerId] else { return }

        await provider.stop()
        sessionCancellables[providerId]?.forEach { $0.cancel() }
        sessionCancellables.removeValue(forKey: providerId)
        activeProviders.removeValue(forKey: providerId)

        // Re-aggregate sessions
        await aggregateSessions()

        logger.info("Deactivated provider: \(providerId, privacy: .public)")
    }

    /// Start all available providers
    func startAll() async {
        for providerId in registeredFactories.keys {
            await activate(providerId: providerId)
        }
    }

    /// Stop all providers
    func stopAll() async {
        for providerId in activeProviders.keys {
            await deactivate(providerId: providerId)
        }
    }

    // MARK: - Session Aggregation

    private func subscribeToProvider(_ provider: AgentProvider) {
        let providerId = provider.providerId

        var cancellables = Set<AnyCancellable>()
        provider.sessionsPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    await self?.aggregateSessions()
                }
            }
            .store(in: &cancellables)

        sessionCancellables[providerId] = cancellables
    }

    private func aggregateSessions() async {
        var uniqueSessions: [String: SessionState] = [:]

        for provider in activeProviders.values {
            let providerSessions = await provider.sessionsPublisher.values.first(where: { _ in true }) ?? []
            for session in providerSessions {
                // Ensure we don't duplicate sessions if multiple providers use the same shared store
                uniqueSessions[session.id] = session
            }
        }

        var sessions = Array(uniqueSessions.values)

        // Sort: needs attention first, then by last activity
        sessions.sort { s1, s2 in
            let n1 = s1.phase.needsAttention
            let n2 = s2.phase.needsAttention
            if n1 != n2 { return n1 }
            return s1.lastActivity > s2.lastActivity
        }

        allSessions = sessions
    }

    // MARK: - Permission Control

    /// Approve permission for a session (finds the right provider)
    func approvePermission(sessionId: String, toolUseId: String) async {
        for provider in activeProviders.values {
            await provider.approvePermission(sessionId: sessionId, toolUseId: toolUseId)
        }
    }

    /// Deny permission for a session
    func denyPermission(sessionId: String, toolUseId: String, reason: String?) async {
        for provider in activeProviders.values {
            await provider.denyPermission(sessionId: sessionId, toolUseId: toolUseId, reason: reason)
        }
    }

    // MARK: - Queries

    /// Get provider by ID
    func provider(for providerId: String) -> AgentProvider? {
        activeProviders[providerId]
    }

    /// Check if a provider is active
    func isActive(providerId: String) -> Bool {
        activeProviders[providerId] != nil
    }

    /// Get all available provider IDs
    var availableProviderIds: [String] {
        providerAvailability.filter { $0.value }.keys.sorted()
    }
}
