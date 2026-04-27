//
//  TokenStatisticsManager.swift
//  ClaudeIsland
//

import Foundation
import Combine

struct AgentTokenStats: Codable, Equatable, Sendable {
    var totalTokens: Int
}

struct GlobalTokenStats: Codable, Equatable, Sendable {
    var totalTokens: Int = 0
    var byAgent: [String: AgentTokenStats] = [:]
}

@MainActor
final class TokenStatisticsManager: ObservableObject {
    static let shared = TokenStatisticsManager()

    private struct HistoricalSessionCandidate: Sendable {
        let sessionId: String
        let filePath: String
        let agentId: String
        let priority: Int
    }

    private struct HistoricalSnapshot: Sendable {
        let globalStats: GlobalTokenStats
        let lastSeenSessionTokens: [String: Int]
    }
    
    @Published var globalStats = GlobalTokenStats()
    @Published private(set) var isRebuildingHistory = false
    
    private let defaultsKey = "GlobalTokenStats"
    private let lastSeenDefaultsKey = "GlobalTokenStatsLastSeenSessionTokens"
    private let historyImportCompletedDefaultsKey = "GlobalTokenStatsHistoricalImportCompleted"

    /// Whether `lastSeenSessionTokens` was loaded from UserDefaults.
    /// Used for one-time migration: older versions persisted `globalStats` but not `lastSeenSessionTokens`.
    private var hasPersistedLastSeenSessionTokens: Bool = false

    /// When true, the first time we see a sessionId we will add its current totalTokens into global stats.
    /// This lets the app bootstrap stats from already-existing sessions.
    /// When false, we only baseline lastSeen without adding (prevents double counting for migrated installs).
    private var shouldAccumulateFirstSeenSessions: Bool = true
    private var hasCompletedHistoricalImport: Bool = false

    private var lastSeenSessionTokens: [String: Int] = [:]
    private var pendingSessionSnapshotsDuringRebuild: [String: (totalTokens: Int, agentId: String)] = [:]
    private var cancellables = Set<AnyCancellable>()
    private var historicalRebuildTask: Task<Void, Never>?
    
    private init() {
        loadStats()
        loadLastSeenSessionTokens()
        loadHistoryImportCompletion()

        // If we already have non-zero global stats but we don't have persisted lastSeen data,
        // this is likely an older install. In that case, avoid re-counting historical sessions.
        shouldAccumulateFirstSeenSessions = hasPersistedLastSeenSessionTokens || globalStats.totalTokens == 0
        
        SessionStore.shared.sessionsPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] sessions in
                self?.handleSessionsUpdate(sessions)
            }
            .store(in: &cancellables)

        scheduleInitialHistoryImportIfNeeded()
    }
    
    private func loadStats() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let stats = try? JSONDecoder().decode(GlobalTokenStats.self, from: data) {
            self.globalStats = stats
        }
    }
    
    private func saveStats() {
        if let data = try? JSONEncoder().encode(globalStats) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }

    private func loadLastSeenSessionTokens() {
        if UserDefaults.standard.object(forKey: lastSeenDefaultsKey) != nil {
            hasPersistedLastSeenSessionTokens = true
        }

        if let data = UserDefaults.standard.data(forKey: lastSeenDefaultsKey),
           let values = try? JSONDecoder().decode([String: Int].self, from: data) {
            self.lastSeenSessionTokens = values
        }
    }

    private func saveLastSeenSessionTokens() {
        if let data = try? JSONEncoder().encode(lastSeenSessionTokens) {
            UserDefaults.standard.set(data, forKey: lastSeenDefaultsKey)
        }
    }

    private func loadHistoryImportCompletion() {
        hasCompletedHistoricalImport = UserDefaults.standard.bool(forKey: historyImportCompletedDefaultsKey)
    }

    private func saveHistoryImportCompletion() {
        UserDefaults.standard.set(hasCompletedHistoricalImport, forKey: historyImportCompletedDefaultsKey)
    }

    private var shouldImportHistoricalSessionsOnLaunch: Bool {
        !hasCompletedHistoricalImport && !hasPersistedLastSeenSessionTokens && lastSeenSessionTokens.isEmpty && globalStats.totalTokens == 0
    }

    private func scheduleInitialHistoryImportIfNeeded() {
        guard shouldImportHistoricalSessionsOnLaunch else { return }
        isRebuildingHistory = true

        historicalRebuildTask = Task { [weak self] in
            guard let self else { return }
            await self.performHistoryRebuild()
        }
    }

    func rebuildHistoryFromDisk() async {
        if let existingTask = historicalRebuildTask {
            await existingTask.value
            return
        }

        let task = Task { [weak self] in
            guard let self else { return }
            await self.performHistoryRebuild()
        }

        historicalRebuildTask = task
        await task.value
    }

    private func performHistoryRebuild() async {
        isRebuildingHistory = true
        pendingSessionSnapshotsDuringRebuild.removeAll()
        defer {
            isRebuildingHistory = false
            historicalRebuildTask = nil
        }

        let snapshot = await Task.detached(priority: .utility) {
            await Self.buildHistoricalSnapshot()
        }.value
        apply(snapshot: snapshot)

        let currentSessions = await SessionStore.shared.allSessions()
        bufferSessionsForReplay(currentSessions)
        replayBufferedSessionSnapshots()
    }

    private func apply(snapshot: HistoricalSnapshot) {
        globalStats = snapshot.globalStats
        lastSeenSessionTokens = snapshot.lastSeenSessionTokens
        hasCompletedHistoricalImport = true
        saveStats()
        saveLastSeenSessionTokens()
        saveHistoryImportCompletion()
        shouldAccumulateFirstSeenSessions = true
    }

    nonisolated private static func buildHistoricalSnapshot() async -> HistoricalSnapshot {
        let candidates = discoverHistoricalSessionCandidates()

        var globalStats = GlobalTokenStats()
        var lastSeenSessionTokens: [String: Int] = [:]

        for candidate in candidates.values.sorted(by: { $0.filePath < $1.filePath }) {
            let info = await ConversationParser.shared.parseFile(atPath: candidate.filePath)
            let totalTokens = info.usage.totalTokens

            lastSeenSessionTokens[candidate.sessionId] = totalTokens

            guard totalTokens > 0 else { continue }

            globalStats.totalTokens += totalTokens
            var agentStats = globalStats.byAgent[candidate.agentId] ?? AgentTokenStats(totalTokens: 0)
            agentStats.totalTokens += totalTokens
            globalStats.byAgent[candidate.agentId] = agentStats
        }

        return HistoricalSnapshot(
            globalStats: globalStats,
            lastSeenSessionTokens: lastSeenSessionTokens
        )
    }

    nonisolated private static func discoverHistoricalSessionCandidates() -> [String: HistoricalSessionCandidate] {
        let fileManager = FileManager.default
        var candidates: [String: HistoricalSessionCandidate] = [:]

        func register(sessionId: String, filePath: String, agentId: String, priority: Int) {
            guard !sessionId.isEmpty else { return }

            let candidate = HistoricalSessionCandidate(
                sessionId: sessionId,
                filePath: filePath,
                agentId: agentId,
                priority: priority
            )

            if let existing = candidates[sessionId], existing.priority >= priority {
                return
            }

            candidates[sessionId] = candidate
        }

        if let enumerator = fileManager.enumerator(
            at: IslandPaths.remoteCacheDir,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) {
            for case let fileURL as URL in enumerator {
                guard fileURL.pathExtension == "jsonl" else { continue }
                register(
                    sessionId: fileURL.deletingPathExtension().lastPathComponent,
                    filePath: fileURL.path,
                    agentId: inferAgentId(for: fileURL.path, fallback: "Claude Code"),
                    priority: 3
                )
            }
        }

        if let enumerator = fileManager.enumerator(
            at: ClaudePaths.projectsDir,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) {
            for case let fileURL as URL in enumerator {
                guard fileURL.pathExtension == "jsonl" else { continue }
                guard !fileURL.lastPathComponent.hasPrefix("agent-") else { continue }
                guard !fileURL.path.contains("/subagents/") else { continue }

                register(
                    sessionId: fileURL.deletingPathExtension().lastPathComponent,
                    filePath: fileURL.path,
                    agentId: "Claude Code",
                    priority: 2
                )
            }
        }

        let cocoSessionsDir = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/coco/sessions")

        if let sessionDirectories = try? fileManager.contentsOfDirectory(
            at: cocoSessionsDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            for directory in sessionDirectories {
                let eventsFile = directory.appendingPathComponent("events.jsonl")
                guard fileManager.fileExists(atPath: eventsFile.path) else { continue }

                register(
                    sessionId: directory.lastPathComponent,
                    filePath: eventsFile.path,
                    agentId: "Coco",
                    priority: 1
                )
            }
        }

        // Codex sessions (~/.codex/sessions/**/rollout-*.jsonl)
        let codexSessionsDir = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions")

        if let enumerator = fileManager.enumerator(
            at: codexSessionsDir,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) {
            for case let fileURL as URL in enumerator {
                guard fileURL.pathExtension == "jsonl" else { continue }
                guard let sessionId = inferCodexSessionId(for: fileURL.path) else { continue }
                register(
                    sessionId: sessionId,
                    filePath: fileURL.path,
                    agentId: "Codex",
                    priority: 1
                )
            }
        }

        return candidates
    }

    nonisolated private static func inferCodexSessionId(for filePath: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: filePath) else { return nil }
        defer { try? handle.close() }

        // Codex session_meta line can be very large (base instructions), so do not assume
        // it fits in a small prefix read. Read until the first newline (or a safe cap).
        let maxBytes = 1_048_576 // 1MB cap for the first line
        let chunkSize = 32_768
        var buffer = Data()

        while buffer.count < maxBytes {
            let chunkOpt: Data?
            do {
                chunkOpt = try handle.read(upToCount: chunkSize)
            } catch {
                chunkOpt = nil
            }

            guard let chunk = chunkOpt, !chunk.isEmpty else {
                break
            }

            buffer.append(chunk)
            if buffer.contains(UInt8(0x0A)) { // '\n'
                break
            }
        }

        let lineData: Data
        if let newlineIdx = buffer.firstIndex(of: UInt8(0x0A)) {
            lineData = buffer.prefix(upTo: newlineIdx)
        } else {
            lineData = buffer
        }

        if let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
           (json["type"] as? String) == "session_meta",
           let payload = json["payload"] as? [String: Any],
           let id = payload["id"] as? String,
           !id.isEmpty {
            return id
        }

        // Fallback: attempt to extract the id with a lightweight string search.
        guard let prefix = String(data: lineData, encoding: .utf8) else { return nil }
        guard prefix.contains("\"type\":\"session_meta\"") else { return nil }
        let needle = "\"id\":\""
        guard let startRange = prefix.range(of: needle) else { return nil }
        let after = prefix[startRange.upperBound...]
        guard let endQuote = after.firstIndex(of: "\"") else { return nil }
        let id = String(after[..<endQuote])
        return id.isEmpty ? nil : id
    }

    nonisolated private static func inferAgentId(for filePath: String, fallback: String) -> String {
        guard let fileHandle = FileHandle(forReadingAtPath: filePath) else {
            return fallback
        }

        defer {
            try? fileHandle.close()
        }

        let prefixData = try? fileHandle.read(upToCount: 8_192)
        guard let prefixData, let prefix = String(data: prefixData, encoding: .utf8) else {
            return fallback
        }

        if prefix.contains("\"response_meta\"") || prefix.contains("\"user_prompt_submit\"") || prefix.contains("\"agent_start\"") {
            return "Coco"
        }

        return fallback
    }

    private func handleSessionsUpdate(_ sessions: [SessionState]) {
        if isRebuildingHistory {
            bufferSessionsForReplay(sessions)
            return
        }

        for session in sessions {
            update(with: session)
        }
    }

    private func bufferSessionsForReplay(_ sessions: [SessionState]) {
        for session in sessions {
            let agentId = self.agentId(for: session)
            let existing = pendingSessionSnapshotsDuringRebuild[session.sessionId]?.totalTokens ?? 0
            let latest = max(existing, session.usage.totalTokens)
            pendingSessionSnapshotsDuringRebuild[session.sessionId] = (latest, agentId)
        }
    }

    private func replayBufferedSessionSnapshots() {
        let buffered = pendingSessionSnapshotsDuringRebuild
        pendingSessionSnapshotsDuringRebuild.removeAll()

        for sessionId in buffered.keys.sorted() {
            guard let snapshot = buffered[sessionId] else { continue }
            applyObservedTotal(
                sessionId: sessionId,
                currentTotal: snapshot.totalTokens,
                agentId: snapshot.agentId,
                allowInitialAccumulation: true
            )
        }
    }

    private func agentId(for session: SessionState) -> String {
        switch session.providerId {
        case "claude-code":
            return "Claude Code"
        case "codex", "codex-remote":
            return "Codex"
        case "coco", "coco-remote":
            return "Coco"
        default:
            return session.providerDisplayName
        }
    }

    @discardableResult
    private func applyObservedTotal(sessionId: String, currentTotal: Int, agentId: String, allowInitialAccumulation: Bool) -> Bool {
        if let lastSeen = lastSeenSessionTokens[sessionId] {
            let deltaTokens = currentTotal - lastSeen
            guard deltaTokens > 0 else { return false }

            globalStats.totalTokens += deltaTokens
            var agentStats = globalStats.byAgent[agentId] ?? AgentTokenStats(totalTokens: 0)
            agentStats.totalTokens += deltaTokens
            globalStats.byAgent[agentId] = agentStats

            lastSeenSessionTokens[sessionId] = currentTotal
            saveStats()
            saveLastSeenSessionTokens()
            return true
        }

        if allowInitialAccumulation, currentTotal > 0 {
            globalStats.totalTokens += currentTotal
            var agentStats = globalStats.byAgent[agentId] ?? AgentTokenStats(totalTokens: 0)
            agentStats.totalTokens += currentTotal
            globalStats.byAgent[agentId] = agentStats
            saveStats()
        }

        lastSeenSessionTokens[sessionId] = currentTotal
        saveLastSeenSessionTokens()
        return currentTotal > 0
    }
    
    // Process session update
    private func update(with session: SessionState) {
        let currentTotal = session.usage.totalTokens
        let agentId = self.agentId(for: session)
        _ = applyObservedTotal(
            sessionId: session.sessionId,
            currentTotal: currentTotal,
            agentId: agentId,
            allowInitialAccumulation: shouldAccumulateFirstSeenSessions
        )
    }
    
    func formatTokens(_ total: Int) -> String {
        if total >= 1_000_000 {
            return String(format: "%.1fM", Double(total) / 1_000_000)
        } else if total >= 1_000 {
            return String(format: "%.1fK", Double(total) / 1_000)
        }
        return "\(total)"
    }
}
