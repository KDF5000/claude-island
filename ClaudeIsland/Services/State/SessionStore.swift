//
//  SessionStore.swift
//  ClaudeIsland
//
//  Central state manager for all Claude sessions.
//  Single source of truth - all state mutations flow through process().
//

import Combine
import Foundation
import Mixpanel
import os.log

/// Central state manager for all Claude sessions
/// Uses Swift actor for thread-safe state mutations
actor SessionStore {
    static let shared = SessionStore()

    /// Logger for session store (nonisolated static for cross-context access)
    nonisolated static let logger = Logger(subsystem: "com.codingisland", category: "Session")

    // MARK: - State

    /// All sessions keyed by sessionId
    private var sessions: [String: SessionState] = [:]

    /// Pending file syncs (debounced)
    private var pendingSyncs: [String: Task<Void, Never>] = [:]

    /// Sync debounce interval (100ms)
    private let syncDebounceNs: UInt64 = 100_000_000

    /// Periodic status check task
    private var statusCheckTask: Task<Void, Never>?

    /// Status check interval (3 seconds)
    private let statusCheckIntervalSeconds: UInt64 = 3

    // MARK: - Published State (for UI)

    /// Publisher for session state changes (nonisolated for Combine subscription from any context)
    private nonisolated(unsafe) let sessionsSubject = CurrentValueSubject<[SessionState], Never>([])

    /// Public publisher for UI subscription
    nonisolated var sessionsPublisher: AnyPublisher<[SessionState], Never> {
        sessionsSubject.eraseToAnyPublisher()
    }

    // MARK: - Initialization

    private init() {}

    // MARK: - Event Processing

    /// Process any session event - the ONLY way to mutate state
    func process(_ event: SessionEvent) async {
        Self.logger.debug("Processing: \(String(describing: event), privacy: .public)")

        switch event {
        case .hookReceived(let hookEvent):
            await processHookEvent(hookEvent)

        case .permissionApproved(let sessionId, let toolUseId):
            await processPermissionApproved(sessionId: sessionId, toolUseId: toolUseId)

        case .permissionDenied(let sessionId, let toolUseId, let reason):
            await processPermissionDenied(sessionId: sessionId, toolUseId: toolUseId, reason: reason)

        case .permissionSocketFailed(let sessionId, let toolUseId):
            await processSocketFailure(sessionId: sessionId, toolUseId: toolUseId)

        case .fileUpdated(let payload):
            await processFileUpdate(payload)

        case .interruptDetected(let sessionId):
            await processInterrupt(sessionId: sessionId)

        case .clearDetected(let sessionId):
            await processClearDetected(sessionId: sessionId)

        case .sessionEnded(let sessionId):
            await processSessionEnd(sessionId: sessionId)

        case .loadHistory(let sessionId, let cwd):
            await loadHistoryFromFile(sessionId: sessionId, cwd: cwd)

        case .historyLoaded(let sessionId, let messages, let completedTools, let toolResults, let structuredResults, let conversationInfo):
            await processHistoryLoaded(
                sessionId: sessionId,
                messages: messages,
                completedTools: completedTools,
                toolResults: toolResults,
                structuredResults: structuredResults,
                conversationInfo: conversationInfo
            )

        case .toolCompleted(let sessionId, let toolUseId, let result):
            await processToolCompleted(sessionId: sessionId, toolUseId: toolUseId, result: result)

        // MARK: - Subagent Events

        case .subagentStarted(let sessionId, let taskToolId):
            processSubagentStarted(sessionId: sessionId, taskToolId: taskToolId)

        case .subagentToolExecuted(let sessionId, let tool):
            processSubagentToolExecuted(sessionId: sessionId, tool: tool)

        case .subagentToolCompleted(let sessionId, let toolId, let status):
            processSubagentToolCompleted(sessionId: sessionId, toolId: toolId, status: status)

        case .subagentStopped(let sessionId, let taskToolId):
            processSubagentStopped(sessionId: sessionId, taskToolId: taskToolId)

        case .agentFileUpdated:
            // No longer used - subagent tools are populated from JSONL completion
            break
        }

        publishState()
    }

    // MARK: - Hook Event Processing

    private func processHookEvent(_ event: HookEvent) async {
        let sessionId = event.sessionId
        let isNewSession = sessions[sessionId] == nil

        // If this is a new session from a known PID or TTY, it's likely a resume or restart
        // Remove old sessions associated with the same PID/TTY to avoid duplicates
        if isNewSession {
            var staleSessions: [String: SessionState] = [:]
            
            // 1. Try to deduplicate by PID
            if let newPid = event.pid {
                let matching = sessions.filter { $0.value.pid == newPid && $0.key != sessionId }
                for (k, v) in matching { staleSessions[k] = v }
            }
            
            // 2. Try to deduplicate by TTY (only if it's a valid TTY)
            if let newTty = event.tty?.replacingOccurrences(of: "/dev/", with: ""),
               !newTty.isEmpty, newTty != "no tty", newTty != "??" {
                let matching = sessions.filter { $0.value.tty == newTty && $0.key != sessionId }
                for (k, v) in matching { staleSessions[k] = v }
            }
            
            for (staleId, staleSession) in staleSessions {
                Self.logger.debug("Removing stale session \(staleId.prefix(8), privacy: .public) as process (PID: \(staleSession.pid ?? 0), TTY: \(staleSession.tty ?? "none")) started a new session")
                sessions.removeValue(forKey: staleId)
                cancelPendingSync(sessionId: staleId)
            }
        }

        var session = sessions[sessionId] ?? createSession(from: event)

        // Track new session in Mixpanel
        if isNewSession {
            Mixpanel.mainInstance().track(event: "Session Started")
        }

        session.pid = event.pid
        session.providerId = event.providerId
        if let pid = event.pid {
            let tree = ProcessTreeBuilder.shared.buildTree()
            session.isInTmux = ProcessTreeBuilder.shared.isInTmux(pid: pid, tree: tree)
        }
        if let tty = event.tty {
            session.tty = tty.replacingOccurrences(of: "/dev/", with: "")
        }
        
        // Update cwd and projectName if provided in the event and valid
        if event.cwd != "/" && event.cwd != "" {
            var actualCwd = event.cwd
            var projectName = URL(fileURLWithPath: event.cwd).lastPathComponent
            
            // Try to read title or cwd from Coco's session.json
            let sessionJsonPath = NSHomeDirectory() + "/Library/Caches/coco/sessions/\(event.sessionId)/session.json"
            if let data = try? Data(contentsOf: URL(fileURLWithPath: sessionJsonPath)),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let metadata = json["metadata"] as? [String: Any] {
                if let title = metadata["title"] as? String, !title.isEmpty {
                    projectName = title
                } else if let sessionCwd = metadata["cwd"] as? String, !sessionCwd.isEmpty {
                    actualCwd = sessionCwd
                    projectName = URL(fileURLWithPath: sessionCwd).lastPathComponent
                }
            }
            
            session.cwd = actualCwd
            session.projectName = projectName
        }
        
        session.lastActivity = Date()

        // If this is a remote event with new JSONL lines, cache them locally so
        // ConversationParser can read them as if the session were local.
        if let lines = event.remoteJsonlLines, !lines.isEmpty {
            Self.logger.info("[Remote] Hook event \(event.event, privacy: .public) has \(lines.count) JSONL lines for session \(sessionId.prefix(8), privacy: .public)")
            appendRemoteJsonlLines(lines, sessionId: sessionId, cwd: event.cwd)
        } else {
            Self.logger.info("[Remote] Hook event \(event.event, privacy: .public) for session \(sessionId.prefix(8), privacy: .public) has NO remote JSONL lines (remoteJsonlLines=\(event.remoteJsonlLines == nil ? "nil" : "empty", privacy: .public))")
            if let debug = event.remotePathDebug, !debug.isEmpty {
                Self.logger.info("[Remote] Path debug: \(debug.joined(separator: " | "), privacy: .public)")
            }
        }

        if event.status == "ended" {
            sessions.removeValue(forKey: sessionId)
            cancelPendingSync(sessionId: sessionId)
            return
        }

        let newPhase = event.determinePhase()

        if session.phase.canTransition(to: newPhase) {
            session.phase = newPhase
        } else {
            Self.logger.debug("Invalid transition: \(String(describing: session.phase), privacy: .public) -> \(String(describing: newPhase), privacy: .public), ignoring")
        }

        let normalizedEvent = event.event.lowercased().replacingOccurrences(of: "_", with: "")

        processToolTracking(event: event, session: &session)
        processSubagentTracking(event: event, session: &session)

        if normalizedEvent == "permissionrequest", let toolUseId = event.toolUseId {
            Self.logger.debug("Setting tool \(toolUseId, privacy: .public) status to waitingForApproval")
            updateToolStatus(in: &session, toolId: toolUseId, status: .waitingForApproval)
        }

        if normalizedEvent == "stop" {
            session.subagentState = SubagentState()
        }

        sessions[sessionId] = session
        publishState()

        if event.shouldSyncFile || (event.remoteJsonlLines?.isEmpty == false) || normalizedEvent == "agentend" || normalizedEvent == "agent_end" {
            scheduleFileSync(sessionId: sessionId, cwd: event.cwd)
        }

    }

    private func createSession(from event: HookEvent) -> SessionState {
        // Find actual project name from file cache if cwd is missing/default
        var actualCwd = event.cwd
        var projectName = URL(fileURLWithPath: event.cwd).lastPathComponent
        
        // Try to read title or cwd from Coco's session.json
        let sessionJsonPath = NSHomeDirectory() + "/Library/Caches/coco/sessions/\(event.sessionId)/session.json"
        if let data = try? Data(contentsOf: URL(fileURLWithPath: sessionJsonPath)),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let metadata = json["metadata"] as? [String: Any] {
            if let title = metadata["title"] as? String, !title.isEmpty {
                projectName = title
            } else if let sessionCwd = metadata["cwd"] as? String, !sessionCwd.isEmpty {
                actualCwd = sessionCwd
                projectName = URL(fileURLWithPath: sessionCwd).lastPathComponent
            }
        } else if event.cwd == "/" || event.cwd == "" {
            // Fallback for Claude Code if cwd is missing
            projectName = "Unknown"
        }
        
        return SessionState(
            sessionId: event.sessionId,
            cwd: actualCwd,
            projectName: projectName,
            providerId: event.providerId,
            pid: event.pid,
            tty: event.tty?.replacingOccurrences(of: "/dev/", with: ""),
            isInTmux: false,  // Will be updated
            phase: .idle
        )
    }

    private func processToolTracking(event: HookEvent, session: inout SessionState) {
        // Normalize event name to support both Claude Code (PreToolUse) and Coco (pre_tool_use)
        let normalizedEvent = event.event.lowercased().replacingOccurrences(of: "_", with: "")
        
        switch normalizedEvent {
        case "pretooluse", "permissionrequest":
            if let toolUseId = event.toolUseId, let toolName = event.tool {
                session.toolTracker.startTool(id: toolUseId, name: toolName)

                // Skip creating top-level placeholder for subagent tools
                // They'll appear under their parent Task instead
                let isSubagentTool = session.subagentState.hasActiveSubagent && !ToolCallItem.isSubagentContainerName(toolName)
                if isSubagentTool {
                                        return
                }

                let toolExists = session.chatItems.contains { $0.id == toolUseId }
                                if !toolExists {
                    var input: [String: String] = [:]
                    if let hookInput = event.toolInput {
                        for (key, value) in hookInput {
                            if let str = value.value as? String {
                                input[key] = str
                            } else if let num = value.value as? Int {
                                input[key] = String(num)
                            } else if let bool = value.value as? Bool {
                                input[key] = bool ? "true" : "false"
                            }
                        }
                    }

                    let initialStatus: ToolStatus = normalizedEvent == "permissionrequest" ? .waitingForApproval : .running

                    let placeholderItem = ChatHistoryItem(
                        id: toolUseId,
                        type: .toolCall(ToolCallItem(
                            name: toolName,
                            input: input,
                            status: initialStatus,
                            result: nil,
                            structuredResult: nil,
                            subagentTools: []
                        )),
                        timestamp: Date()
                    )
                    session.chatItems.append(placeholderItem)
                    Self.logger.debug("Created placeholder tool entry for \(toolUseId, privacy: .public)")
                }
            }

        case "posttooluse":
            if let toolUseId = event.toolUseId {
                session.toolTracker.completeTool(id: toolUseId, success: true)
                // Update chatItem status - tool completed (possibly approved via terminal)
                // Only update if still waiting for approval or running
                for i in 0..<session.chatItems.count {
                    if session.chatItems[i].id == toolUseId,
                       case .toolCall(var tool) = session.chatItems[i].type,
                       tool.status == .waitingForApproval || tool.status == .running {
                        tool.status = .success
                        session.chatItems[i] = ChatHistoryItem(
                            id: toolUseId,
                            type: .toolCall(tool),
                            timestamp: session.chatItems[i].timestamp
                        )
                        break
                    }
                }
            }

        default:
            break
        }
    }

    private func processSubagentTracking(event: HookEvent, session: inout SessionState) {
        // Normalize event name to support both Claude Code and Coco formats
        let normalizedEvent = event.event.lowercased().replacingOccurrences(of: "_", with: "")

        switch normalizedEvent {
        case "pretooluse":
            if ToolCallItem.isSubagentContainerName(event.tool), let toolUseId = event.toolUseId {
                let description = event.toolInput?["description"]?.value as? String
                session.subagentState.startTask(taskToolId: toolUseId, description: description)
                Self.logger.debug("Started Task/Agent subagent tracking: \(toolUseId.prefix(12), privacy: .public)")
            } else if let toolName = event.tool,
                      let toolUseId = event.toolUseId,
                      session.subagentState.hasActiveSubagent {
                // A subagent's inner tool is starting. Add it to the parent Task/Agent's
                // subagent list and sync to chatItems so the UI updates live (rather
                // than only after the parent Agent completes).
                var input: [String: String] = [:]
                if let hookInput = event.toolInput {
                    for (key, value) in hookInput {
                        if let str = value.value as? String {
                            input[key] = str
                        } else if let num = value.value as? Int {
                            input[key] = String(num)
                        } else if let bool = value.value as? Bool {
                            input[key] = bool ? "true" : "false"
                        }
                    }
                }
                let subagentTool = SubagentToolCall(
                    id: toolUseId,
                    name: toolName,
                    input: input,
                    status: .running,
                    timestamp: Date()
                )
                session.subagentState.addSubagentTool(subagentTool)
                syncSubagentToolsToChatItems(session: &session)
            }

        case "posttooluse":
            if ToolCallItem.isSubagentContainerName(event.tool), let toolUseId = event.toolUseId {
                // Agent tool returned — the subagent has finished. Stop
                // tracking so subsequent tools in the parent turn don't get
                // attached to this dead task.
                session.subagentState.stopTask(taskToolId: toolUseId)
                Self.logger.debug("Stopped subagent tracking for \(toolUseId.prefix(12), privacy: .public)")
            } else if let toolUseId = event.toolUseId,
                      session.subagentState.hasActiveSubagent {
                // A subagent's inner tool completed. Update its status in the
                // parent's subagent list and sync.
                session.subagentState.updateSubagentToolStatus(toolId: toolUseId, status: .success)
                syncSubagentToolsToChatItems(session: &session)
            }

        case "subagentstop":
            // SubagentStop fires when a subagent completes - stop tracking
            // Subagent tools are populated from agent file in processFileUpdated
            Self.logger.debug("SubagentStop received")

        default:
            break
        }
    }

    /// Push the current subagent tool lists from subagentState into the
    /// corresponding ChatHistoryItem.subagentTools so the UI renders them live.
    private func syncSubagentToolsToChatItems(session: inout SessionState) {
        for (taskToolId, context) in session.subagentState.activeTasks {
            guard !context.subagentTools.isEmpty else { continue }
            for i in 0..<session.chatItems.count {
                if session.chatItems[i].id == taskToolId,
                   case .toolCall(var tool) = session.chatItems[i].type {
                    tool.subagentTools = context.subagentTools
                    session.chatItems[i] = ChatHistoryItem(
                        id: taskToolId,
                        type: .toolCall(tool),
                        timestamp: session.chatItems[i].timestamp
                    )
                    break
                }
            }
        }
    }

    // MARK: - Subagent Event Handlers

    /// Handle subagent started event
    private func processSubagentStarted(sessionId: String, taskToolId: String) {
        guard var session = sessions[sessionId] else { return }
        session.subagentState.startTask(taskToolId: taskToolId)
        sessions[sessionId] = session
    }

    /// Handle subagent tool executed event
    private func processSubagentToolExecuted(sessionId: String, tool: SubagentToolCall) {
        guard var session = sessions[sessionId] else { return }
        session.subagentState.addSubagentTool(tool)
        sessions[sessionId] = session
    }

    /// Handle subagent tool completed event
    private func processSubagentToolCompleted(sessionId: String, toolId: String, status: ToolStatus) {
        guard var session = sessions[sessionId] else { return }
        session.subagentState.updateSubagentToolStatus(toolId: toolId, status: status)
        sessions[sessionId] = session
    }

    /// Handle subagent stopped event
    private func processSubagentStopped(sessionId: String, taskToolId: String) {
        guard var session = sessions[sessionId] else { return }
        session.subagentState.stopTask(taskToolId: taskToolId)
        sessions[sessionId] = session
        // Subagent tools will be populated from agent file in processFileUpdated
    }

    /// Parse ISO8601 timestamp string
    private func parseTimestamp(_ timestampStr: String?) -> Date? {
        guard let str = timestampStr else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: str)
    }

    // MARK: - Permission Processing

    private func processPermissionApproved(sessionId: String, toolUseId: String) async {
        guard var session = sessions[sessionId] else { return }

        // Update tool status in chat history first
        updateToolStatus(in: &session, toolId: toolUseId, status: .running)

        // Check if there are other tools still waiting for approval
        if let nextPending = findNextPendingTool(in: session, excluding: toolUseId) {
            // Another tool is waiting - stay in waitingForApproval with that tool's context
            let newPhase = SessionPhase.waitingForApproval(PermissionContext(
                toolUseId: nextPending.id,
                toolName: nextPending.name,
                toolInput: nil,  // We don't have the input stored in chatItems
                receivedAt: nextPending.timestamp
            ))
            if session.phase.canTransition(to: newPhase) {
                session.phase = newPhase
                Self.logger.debug("Switched to next pending tool: \(nextPending.id.prefix(12), privacy: .public)")
            }
        } else {
            // No more pending tools - transition to processing
            if case .waitingForApproval(let ctx) = session.phase, ctx.toolUseId == toolUseId {
                if session.phase.canTransition(to: .processing) {
                    session.phase = .processing
                }
            } else if case .waitingForApproval = session.phase {
                // The approved tool wasn't the one in phase context, but no others pending
                // This can happen if tools were approved out of order
                if session.phase.canTransition(to: .processing) {
                    session.phase = .processing
                }
            }
        }

        sessions[sessionId] = session
    }

    // MARK: - Tool Completion Processing

    /// Process a tool completion event (from JSONL detection)
    /// This is the authoritative handler for tool completions - ensures consistent state updates
    private func processToolCompleted(sessionId: String, toolUseId: String, result: ToolCompletionResult) async {
        guard var session = sessions[sessionId] else { return }

        // Check if this tool is already completed (avoid duplicate processing)
        if let existingItem = session.chatItems.first(where: { $0.id == toolUseId }),
           case .toolCall(let tool) = existingItem.type,
           tool.status == .success || tool.status == .error || tool.status == .interrupted {
            // Already completed, skip
            return
        }

        // Update the tool status
        for i in 0..<session.chatItems.count {
            if session.chatItems[i].id == toolUseId,
               case .toolCall(var tool) = session.chatItems[i].type {
                tool.status = result.status
                tool.result = result.result
                tool.structuredResult = result.structuredResult
                session.chatItems[i] = ChatHistoryItem(
                    id: toolUseId,
                    type: .toolCall(tool),
                    timestamp: session.chatItems[i].timestamp
                )
                Self.logger.debug("Tool \(toolUseId.prefix(12), privacy: .public) completed with status: \(String(describing: result.status), privacy: .public)")
                break
            }
        }

        // Update session phase if needed
        // If the completed tool was the one in the phase context, switch to next pending or processing
        if case .waitingForApproval(let ctx) = session.phase, ctx.toolUseId == toolUseId {
            if let nextPending = findNextPendingTool(in: session, excluding: toolUseId) {
                let newPhase = SessionPhase.waitingForApproval(PermissionContext(
                    toolUseId: nextPending.id,
                    toolName: nextPending.name,
                    toolInput: nil,
                    receivedAt: nextPending.timestamp
                ))
                session.phase = newPhase
                Self.logger.debug("Switched to next pending tool after completion: \(nextPending.id.prefix(12), privacy: .public)")
            } else {
                if session.phase.canTransition(to: .processing) {
                    session.phase = .processing
                }
            }
        }

        sessions[sessionId] = session
    }

    /// Find the next tool waiting for approval (excluding a specific tool ID)
    private func findNextPendingTool(in session: SessionState, excluding toolId: String) -> (id: String, name: String, timestamp: Date)? {
        for item in session.chatItems {
            if item.id == toolId { continue }
            if case .toolCall(let tool) = item.type, tool.status == .waitingForApproval {
                return (id: item.id, name: tool.name, timestamp: item.timestamp)
            }
        }
        return nil
    }

    private func processPermissionDenied(sessionId: String, toolUseId: String, reason: String?) async {
        guard var session = sessions[sessionId] else { return }

        // Update tool status in chat history first
        updateToolStatus(in: &session, toolId: toolUseId, status: .error)

        // Check if there are other tools still waiting for approval
        if let nextPending = findNextPendingTool(in: session, excluding: toolUseId) {
            // Another tool is waiting - stay in waitingForApproval with that tool's context
            let newPhase = SessionPhase.waitingForApproval(PermissionContext(
                toolUseId: nextPending.id,
                toolName: nextPending.name,
                toolInput: nil,
                receivedAt: nextPending.timestamp
            ))
            if session.phase.canTransition(to: newPhase) {
                session.phase = newPhase
                Self.logger.debug("Switched to next pending tool after denial: \(nextPending.id.prefix(12), privacy: .public)")
            }
        } else {
            // No more pending tools - transition to processing (Claude will handle denial)
            if case .waitingForApproval(let ctx) = session.phase, ctx.toolUseId == toolUseId {
                if session.phase.canTransition(to: .processing) {
                    session.phase = .processing
                }
            } else if case .waitingForApproval = session.phase {
                // The denied tool wasn't the one in phase context, but no others pending
                if session.phase.canTransition(to: .processing) {
                    session.phase = .processing
                }
            }
        }

        sessions[sessionId] = session
    }

    private func processSocketFailure(sessionId: String, toolUseId: String) async {
        guard var session = sessions[sessionId] else { return }

        // Mark the failed tool's status as error
        updateToolStatus(in: &session, toolId: toolUseId, status: .error)

        // Check if there are other tools still waiting for approval
        if let nextPending = findNextPendingTool(in: session, excluding: toolUseId) {
            // Another tool is waiting - switch to that tool's context
            let newPhase = SessionPhase.waitingForApproval(PermissionContext(
                toolUseId: nextPending.id,
                toolName: nextPending.name,
                toolInput: nil,
                receivedAt: nextPending.timestamp
            ))
            if session.phase.canTransition(to: newPhase) {
                session.phase = newPhase
                Self.logger.debug("Switched to next pending tool after socket failure: \(nextPending.id.prefix(12), privacy: .public)")
            }
        } else {
            // No more pending tools - clear permission state
            if case .waitingForApproval(let ctx) = session.phase, ctx.toolUseId == toolUseId {
                session.phase = .idle
            } else if case .waitingForApproval = session.phase {
                // The failed tool wasn't in phase context, but no others pending
                session.phase = .idle
            }
        }

        sessions[sessionId] = session
    }

    // MARK: - File Update Processing

    private func processFileUpdate(_ payload: FileUpdatePayload) async {
        guard var session = sessions[payload.sessionId] else { return }

        // Update conversationInfo from JSONL (summary, lastMessage, etc.)
        let conversationInfo = await ConversationParser.shared.parse(
            sessionId: payload.sessionId,
            cwd: session.cwd
        )
        session.conversationInfo = conversationInfo

        // Handle /clear reconciliation - remove items that no longer exist in parser state
        if session.needsClearReconciliation {
            // Build set of valid IDs from the payload messages
            var validIds = Set<String>()
            for message in payload.messages {
                for (blockIndex, block) in message.content.enumerated() {
                    switch block {
                    case .toolUse(let tool):
                        validIds.insert(tool.id)
                    case .text, .thinking, .image, .interrupted:
                        let itemId = "\(message.id)-\(block.typePrefix)-\(blockIndex)"
                        validIds.insert(itemId)
                    }
                }
            }

            // Filter chatItems to only keep valid items OR items that are very recent
            // (within last 2 seconds - these are hook-created placeholders for post-clear tools)
            let cutoffTime = Date().addingTimeInterval(-2)
            let previousCount = session.chatItems.count
            session.chatItems = session.chatItems.filter { item in
                validIds.contains(item.id) || item.timestamp > cutoffTime
            }

            // Also reset tool tracker
            session.toolTracker = ToolTracker()
            session.subagentState = SubagentState()

            session.needsClearReconciliation = false
            Self.logger.debug("Clear reconciliation: kept \(session.chatItems.count) of \(previousCount) items")
        }

        // Coco dual-approval fallback can create a permission placeholder tool_use_id
        // (e.g. "<session_id>:<tool_name>") that later gets replaced by a real tool_use_id
        // from JSONL. If we don't reconcile them, the UI can remain stuck showing a
        // stale waiting-for-approval tool even after the user approved in the terminal.
        func migratePermissionPlaceholderIfNeeded(
            toolId: String,
            toolName: String,
            toolInput: [String: String],
            timestamp: Date
        ) -> Bool {
            // If we already have an item for this toolId, nothing to migrate.
            guard !session.chatItems.contains(where: { $0.id == toolId }) else { return false }

            let preferredPlaceholderId = "\(payload.sessionId):\(toolName)"
            let placeholderIdx = session.chatItems.firstIndex { item in
                guard case .toolCall(let existingTool) = item.type else { return false }
                guard existingTool.status == .waitingForApproval else { return false }

                if item.id == preferredPlaceholderId {
                    return true
                }

                // Fallback: any waiting placeholder from this session with same tool name.
                return item.id.hasPrefix("\(payload.sessionId):") && existingTool.name == toolName
            }

            guard let idx = placeholderIdx,
                  case .toolCall(let existingTool) = session.chatItems[idx].type else {
                return false
            }

            let oldId = session.chatItems[idx].id

            // Move toolTracker state so dedup/tool timing stays consistent.
            if let progress = session.toolTracker.inProgress.removeValue(forKey: oldId) {
                session.toolTracker.inProgress[toolId] = ToolInProgress(
                    id: toolId,
                    name: progress.name,
                    startTime: progress.startTime,
                    phase: progress.phase
                )
            }
            session.toolTracker.seenIds.remove(oldId)
            session.toolTracker.seenIds.insert(toolId)

            // If the session phase is pointing at the placeholder, update the context to
            // the real tool id so UI actions target the right thing.
            if case .waitingForApproval(let ctx) = session.phase, ctx.toolUseId == oldId {
                session.phase = .waitingForApproval(PermissionContext(
                    toolUseId: toolId,
                    toolName: ctx.toolName,
                    toolInput: ctx.toolInput,
                    receivedAt: ctx.receivedAt
                ))
            }

            let newStatus: ToolStatus = (existingTool.status == .waitingForApproval) ? .running : existingTool.status
            session.chatItems[idx] = ChatHistoryItem(
                id: toolId,
                type: .toolCall(ToolCallItem(
                    name: toolName,
                    input: toolInput,
                    status: newStatus,
                    result: existingTool.result,
                    structuredResult: existingTool.structuredResult,
                    subagentTools: existingTool.subagentTools
                )),
                timestamp: timestamp
            )

            Self.logger.debug("Migrated permission placeholder \(oldId, privacy: .public) -> \(toolId, privacy: .public)")
            return true
        }

        if payload.isIncremental {
            let existingIds = Set(session.chatItems.map { $0.id })

            for message in payload.messages {
                for (blockIndex, block) in message.content.enumerated() {
                    if case .toolUse(let tool) = block {
                        if migratePermissionPlaceholderIfNeeded(
                            toolId: tool.id,
                            toolName: tool.name,
                            toolInput: tool.input,
                            timestamp: message.timestamp
                        ) {
                            continue
                        }

                        if let idx = session.chatItems.firstIndex(where: { $0.id == tool.id }) {
                            if case .toolCall(let existingTool) = session.chatItems[idx].type {
                                let newStatus: ToolStatus = (existingTool.status == .waitingForApproval) ? .running : existingTool.status
                                session.chatItems[idx] = ChatHistoryItem(
                                    id: tool.id,
                                    type: .toolCall(ToolCallItem(
                                        name: tool.name,
                                        input: tool.input,
                                        status: newStatus,
                                        result: existingTool.result,
                                        structuredResult: existingTool.structuredResult,
                                        subagentTools: existingTool.subagentTools
                                    )),
                                    timestamp: message.timestamp
                                )
                            }
                            continue
                        }
                    }

                    let item = createChatItem(
                        from: block,
                        message: message,
                        blockIndex: blockIndex,
                        existingIds: existingIds,
                        completedTools: payload.completedToolIds,
                        toolResults: payload.toolResults,
                        structuredResults: payload.structuredResults,
                        toolTracker: &session.toolTracker
                    )

                    if let item = item {
                        session.chatItems.append(item)
                    }
                }
            }
        } else {
            let existingIds = Set(session.chatItems.map { $0.id })

            for message in payload.messages {
                for (blockIndex, block) in message.content.enumerated() {
                    if case .toolUse(let tool) = block {
                        if migratePermissionPlaceholderIfNeeded(
                            toolId: tool.id,
                            toolName: tool.name,
                            toolInput: tool.input,
                            timestamp: message.timestamp
                        ) {
                            continue
                        }

                        if let idx = session.chatItems.firstIndex(where: { $0.id == tool.id }) {
                            if case .toolCall(let existingTool) = session.chatItems[idx].type {
                                let newStatus: ToolStatus = (existingTool.status == .waitingForApproval) ? .running : existingTool.status
                                session.chatItems[idx] = ChatHistoryItem(
                                    id: tool.id,
                                    type: .toolCall(ToolCallItem(
                                        name: tool.name,
                                        input: tool.input,
                                        status: newStatus,
                                        result: existingTool.result,
                                        structuredResult: existingTool.structuredResult,
                                        subagentTools: existingTool.subagentTools
                                    )),
                                    timestamp: message.timestamp
                                )
                            }
                            continue
                        }
                    }

                    let item = createChatItem(
                        from: block,
                        message: message,
                        blockIndex: blockIndex,
                        existingIds: existingIds,
                        completedTools: payload.completedToolIds,
                        toolResults: payload.toolResults,
                        structuredResults: payload.structuredResults,
                        toolTracker: &session.toolTracker
                    )

                    if let item = item {
                        session.chatItems.append(item)
                    }
                }
            }

            session.chatItems.sort { $0.timestamp < $1.timestamp }
        }

        session.toolTracker.lastSyncTime = Date()

        await populateSubagentToolsFromAgentFiles(
            sessionId: payload.sessionId,
            session: &session,
            cwd: payload.cwd,
            structuredResults: payload.structuredResults
        )

        // If the user handled the permission prompt in the terminal (dual-approval fallback),
        // the hook socket is already gone, but the UI can remain stuck in waitingForApproval.
        // As soon as we observe new transcript activity, move out of approval UI.
        if case .waitingForApproval = session.phase,
           !HookSocketServer.shared.hasPendingPermission(sessionId: payload.sessionId),
           (!payload.messages.isEmpty || !payload.completedToolIds.isEmpty) {
            if session.phase.canTransition(to: .processing) {
                session.phase = .processing
            }
        }

        sessions[payload.sessionId] = session

        await emitToolCompletionEvents(
            sessionId: payload.sessionId,
            session: session,
            completedToolIds: payload.completedToolIds,
            toolResults: payload.toolResults,
            structuredResults: payload.structuredResults
        )
    }

    /// Populate subagent tools for Task/Agent tools using their agent JSONL files
    private func populateSubagentToolsFromAgentFiles(
        sessionId: String,
        session: inout SessionState,
        cwd: String,
        structuredResults: [String: ToolResultData]
    ) async {
        for i in 0..<session.chatItems.count {
            guard case .toolCall(var tool) = session.chatItems[i].type,
                  tool.isSubagentContainer,
                  let structuredResult = structuredResults[session.chatItems[i].id],
                  case .task(let taskResult) = structuredResult,
                  !taskResult.agentId.isEmpty else { continue }

            let taskToolId = session.chatItems[i].id

            // Store agentId → description mapping for AgentOutputTool display
            if let description = session.subagentState.activeTasks[taskToolId]?.description {
                session.subagentState.agentDescriptions[taskResult.agentId] = description
            } else if let description = tool.input["description"] {
                session.subagentState.agentDescriptions[taskResult.agentId] = description
            }

            let subagentToolInfos = await ConversationParser.shared.parseSubagentTools(
                sessionId: sessionId,
                agentId: taskResult.agentId,
                cwd: cwd
            )

            guard !subagentToolInfos.isEmpty else { continue }

            tool.subagentTools = subagentToolInfos.map { info in
                SubagentToolCall(
                    id: info.id,
                    name: info.name,
                    input: info.input,
                    status: info.isCompleted ? .success : .running,
                    timestamp: parseTimestamp(info.timestamp) ?? Date()
                )
            }

            session.chatItems[i] = ChatHistoryItem(
                id: taskToolId,
                type: .toolCall(tool),
                timestamp: session.chatItems[i].timestamp
            )

            Self.logger.debug("Populated \(subagentToolInfos.count) subagent tools for Task \(taskToolId.prefix(12), privacy: .public) from agent \(taskResult.agentId.prefix(8), privacy: .public)")
        }
    }

    /// Emit toolCompleted events for tools that have results in JSONL but aren't marked complete yet
    private func emitToolCompletionEvents(
        sessionId: String,
        session: SessionState,
        completedToolIds: Set<String>,
        toolResults: [String: ConversationParser.ToolResult],
        structuredResults: [String: ToolResultData]
    ) async {
        for item in session.chatItems {
            guard case .toolCall(let tool) = item.type else { continue }

            // Only emit for tools that are running or waiting but have results in JSONL
            guard tool.status == .running || tool.status == .waitingForApproval else { continue }
            guard completedToolIds.contains(item.id) else { continue }

            let result = ToolCompletionResult.from(
                parserResult: toolResults[item.id],
                structuredResult: structuredResults[item.id]
            )

            // Process the completion event (this will update state and phase consistently)
            await process(.toolCompleted(sessionId: sessionId, toolUseId: item.id, result: result))
        }
    }

    /// Create chat item (checks existingIds to avoid duplicates)
    private func createChatItem(
        from block: MessageBlock,
        message: ChatMessage,
        blockIndex: Int,
        existingIds: Set<String>,
        completedTools: Set<String>,
        toolResults: [String: ConversationParser.ToolResult],
        structuredResults: [String: ToolResultData],
        toolTracker: inout ToolTracker
    ) -> ChatHistoryItem? {
        switch block {
        case .text(let text):
            let itemId = "\(message.id)-text-\(blockIndex)"
            guard !existingIds.contains(itemId) else { return nil }

            // Skip empty text blocks — assistant turns with only tool calls
            // produce empty text blocks that would render as orphan dots/gaps.
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }

            if message.role == .user {
                return ChatHistoryItem(id: itemId, type: .user(text), timestamp: message.timestamp)
            } else {
                return ChatHistoryItem(id: itemId, type: .assistant(text), timestamp: message.timestamp)
            }

        case .toolUse(let tool):
            guard toolTracker.markSeen(tool.id) else { return nil }

            let isCompleted = completedTools.contains(tool.id)
            let status: ToolStatus = isCompleted ? .success : .running

            // Extract result text for completed tools
            var resultText: String? = nil
            if isCompleted, let parserResult = toolResults[tool.id] {
                if let stdout = parserResult.stdout, !stdout.isEmpty {
                    resultText = stdout
                } else if let stderr = parserResult.stderr, !stderr.isEmpty {
                    resultText = stderr
                } else if let content = parserResult.content, !content.isEmpty {
                    resultText = content
                }
            }

            return ChatHistoryItem(
                id: tool.id,
                type: .toolCall(ToolCallItem(
                    name: tool.name,
                    input: tool.input,
                    status: status,
                    result: resultText,
                    structuredResult: structuredResults[tool.id],
                    subagentTools: []
                )),
                timestamp: message.timestamp
            )

        case .thinking(let text):
            let itemId = "\(message.id)-thinking-\(blockIndex)"
            guard !existingIds.contains(itemId) else { return nil }

            // Skip empty thinking blocks — streaming can briefly produce empty
            // ones that would render as orphan grey dots.
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }

            return ChatHistoryItem(id: itemId, type: .thinking(text), timestamp: message.timestamp)

        case .image(let imageBlock):
            let itemId = "\(message.id)-image-\(blockIndex)"
            guard !existingIds.contains(itemId) else { return nil }
            return ChatHistoryItem(id: itemId, type: .image(imageBlock), timestamp: message.timestamp)

        case .interrupted:
            let itemId = "\(message.id)-interrupted-\(blockIndex)"
            guard !existingIds.contains(itemId) else { return nil }
            return ChatHistoryItem(id: itemId, type: .interrupted, timestamp: message.timestamp)
        }
    }

    private func updateToolStatus(in session: inout SessionState, toolId: String, status: ToolStatus) {
        var found = false
        for i in 0..<session.chatItems.count {
            if session.chatItems[i].id == toolId,
               case .toolCall(var tool) = session.chatItems[i].type {
                tool.status = status
                session.chatItems[i] = ChatHistoryItem(
                    id: toolId,
                    type: .toolCall(tool),
                    timestamp: session.chatItems[i].timestamp
                )
                found = true
                break
            }
        }
        if !found {
            let count = session.chatItems.count
            Self.logger.warning("Tool \(toolId, privacy: .public) not found in chatItems (count: \(count))")
        }
    }

    // MARK: - Interrupt Processing

    private func processInterrupt(sessionId: String) async {
        guard var session = sessions[sessionId] else { return }

        // Clear subagent state
        session.subagentState = SubagentState()

        // Mark running tools as interrupted
        for i in 0..<session.chatItems.count {
            if case .toolCall(var tool) = session.chatItems[i].type,
               tool.status == .running {
                tool.status = .interrupted
                session.chatItems[i] = ChatHistoryItem(
                    id: session.chatItems[i].id,
                    type: .toolCall(tool),
                    timestamp: session.chatItems[i].timestamp
                )
            }
        }

        // Transition to idle
        if session.phase.canTransition(to: .idle) {
            session.phase = .idle
        }

        sessions[sessionId] = session
    }

    // MARK: - Clear Processing

    private func processClearDetected(sessionId: String) async {
        guard var session = sessions[sessionId] else { return }

        Self.logger.info("Processing /clear for session \(sessionId.prefix(8), privacy: .public)")

        // Mark that a clear happened - the next fileUpdated will reconcile
        // by removing items that no longer exist in the parser's state
        session.needsClearReconciliation = true
        sessions[sessionId] = session

        Self.logger.info("/clear processed for session \(sessionId.prefix(8), privacy: .public) - marked for reconciliation")
    }

    // MARK: - Session End Processing

    private func processSessionEnd(sessionId: String) async {
        sessions.removeValue(forKey: sessionId)
        cancelPendingSync(sessionId: sessionId)
    }

    // MARK: - History Loading

    private func loadHistoryFromFile(sessionId: String, cwd: String) async {
        Self.logger.info("[History] loadHistoryFromFile: session \(sessionId.prefix(8), privacy: .public) cwd=\(cwd, privacy: .public)")
        // Parse file asynchronously
        let messages = await ConversationParser.shared.parseFullConversation(
            sessionId: sessionId,
            cwd: cwd
        )
        Self.logger.info("[History] parseFullConversation returned \(messages.count) messages for session \(sessionId.prefix(8), privacy: .public)")
        let completedTools = await ConversationParser.shared.completedToolIds(for: sessionId)
        let toolResults = await ConversationParser.shared.toolResults(for: sessionId)
        let structuredResults = await ConversationParser.shared.structuredResults(for: sessionId)

        // Also parse conversationInfo (summary, lastMessage, etc.)
        let conversationInfo = await ConversationParser.shared.parse(
            sessionId: sessionId,
            cwd: cwd
        )

        // Process loaded history
        await process(.historyLoaded(
            sessionId: sessionId,
            messages: messages,
            completedTools: completedTools,
            toolResults: toolResults,
            structuredResults: structuredResults,
            conversationInfo: conversationInfo
        ))
    }

    private func processHistoryLoaded(
        sessionId: String,
        messages: [ChatMessage],
        completedTools: Set<String>,
        toolResults: [String: ConversationParser.ToolResult],
        structuredResults: [String: ToolResultData],
        conversationInfo: ConversationInfo
    ) async {
        guard var session = sessions[sessionId] else {
            Self.logger.warning("[History] processHistoryLoaded: session \(sessionId.prefix(8), privacy: .public) NOT in sessions dict, dropping \(messages.count) messages")
            return
        }

        Self.logger.info("[History] processHistoryLoaded: session \(sessionId.prefix(8), privacy: .public) messages=\(messages.count) existingChatItems=\(session.chatItems.count)")

        // Update conversationInfo (summary, lastMessage, etc.)
        session.conversationInfo = conversationInfo

        // Convert messages to chat items
        let existingIds = Set(session.chatItems.map { $0.id })

        for message in messages {
            for (blockIndex, block) in message.content.enumerated() {
                let item = createChatItem(
                    from: block,
                    message: message,
                    blockIndex: blockIndex,
                    existingIds: existingIds,
                    completedTools: completedTools,
                    toolResults: toolResults,
                    structuredResults: structuredResults,
                    toolTracker: &session.toolTracker
                )

                if let item = item {
                    session.chatItems.append(item)
                }
            }
        }

        // Sort by timestamp
        session.chatItems.sort { $0.timestamp < $1.timestamp }

        Self.logger.info("[History] processHistoryLoaded: done, chatItems now \(session.chatItems.count) for session \(sessionId.prefix(8), privacy: .public)")
        sessions[sessionId] = session
    }

    // MARK: - File Sync Scheduling

    private func scheduleFileSync(sessionId: String, cwd: String) {
        // Cancel existing sync
        cancelPendingSync(sessionId: sessionId)

        // Schedule new debounced sync
        pendingSyncs[sessionId] = Task { [weak self, syncDebounceNs] in
            try? await Task.sleep(nanoseconds: syncDebounceNs)
            guard !Task.isCancelled else { return }

            // Parse incrementally - only get NEW messages since last call
            let result = await ConversationParser.shared.parseIncremental(
                sessionId: sessionId,
                cwd: cwd
            )

            Self.logger.info("[Sync] parseIncremental for \(sessionId.prefix(8), privacy: .public): newMessages=\(result.newMessages.count) clearDetected=\(result.clearDetected)")

            if result.clearDetected {
                await self?.process(.clearDetected(sessionId: sessionId))
            }

            var hasNewCompletions = false
            if let session = await self?.session(for: sessionId) {
                for item in session.chatItems {
                    if case .toolCall(let tool) = item.type,
                       (tool.status == .running || tool.status == .waitingForApproval),
                       result.completedToolIds.contains(item.id) {
                        hasNewCompletions = true
                        break
                    }
                }
            }

            guard !result.newMessages.isEmpty || result.clearDetected || hasNewCompletions else {
                Self.logger.info("[Sync] No new messages or completions for \(sessionId.prefix(8), privacy: .public), skipping fileUpdated")
                return
            }

            let payload = FileUpdatePayload(
                sessionId: sessionId,
                cwd: cwd,
                messages: result.newMessages,
                isIncremental: !result.clearDetected,
                completedToolIds: result.completedToolIds,
                toolResults: result.toolResults,
                structuredResults: result.structuredResults
            )

            await self?.process(.fileUpdated(payload))
        }
    }

    private func cancelPendingSync(sessionId: String) {
        pendingSyncs[sessionId]?.cancel()
        pendingSyncs.removeValue(forKey: sessionId)
    }

    // MARK: - Periodic Status Check

    /// Start periodic status checking for all sessions
    func startPeriodicStatusCheck() {
        guard statusCheckTask == nil else { return }

        let intervalSeconds = statusCheckIntervalSeconds
        statusCheckTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: intervalSeconds * 1_000_000_000)
                guard !Task.isCancelled else { break }
                await self?.recheckAllSessions()
            }
        }
        Self.logger.info("Started periodic status check (every \(intervalSeconds)s)")
    }

    /// Stop periodic status checking
    func stopPeriodicStatusCheck() {
        statusCheckTask?.cancel()
        statusCheckTask = nil
        Self.logger.info("Stopped periodic status check")
    }

    /// Recheck status of all active sessions
    private func recheckAllSessions() {
        var removedSession = false
        var mutatedSession = false

        for (sessionId, existing) in Array(sessions) {
            var session = existing

            if session.phase == .ended {
                sessions.removeValue(forKey: sessionId)
                cancelPendingSync(sessionId: sessionId)
                removedSession = true
                continue
            }

            if let pid = session.pid {
                let isRunning = isProcessRunning(pid: pid)
                if !isRunning {
                    Self.logger.info("Process \(pid) no longer running, ending session \(sessionId.prefix(8))")
                    sessions.removeValue(forKey: sessionId)
                    cancelPendingSync(sessionId: sessionId)
                    removedSession = true
                    continue
                }
            }

            // Heal stale permission state.
            // This can happen when a PermissionRequest arrives without a resolvable tool_use_id
            // (cache miss) — the socket is closed in HookSocketServer, but the UI could remain
            // stuck in .waitingForApproval forever.
            //
            // IMPORTANT: In dual-approval mode, the hook *intentionally* closes its socket after
            // a short timeout (so the CLI can show its own UI). In that case, we still want to
            // keep the Island UI visible as long as we have a corresponding tool placeholder that
            // is waiting for approval (users can approve via terminal keystroke fallback).
            if session.phase.isWaitingForApproval && !HookSocketServer.shared.hasPendingPermission(sessionId: sessionId) {
                let hasRunningTool = session.chatItems.contains { item in
                    guard case .toolCall(let tool) = item.type else { return false }
                    return tool.status == .running
                }
                let hasWaitingTool = session.chatItems.contains { item in
                    guard case .toolCall(let tool) = item.type else { return false }
                    return tool.status == .waitingForApproval
                }

                // If we still have a waiting tool in the chat history, keep the session in
                // waitingForApproval even if the socket is gone (dual-approval fallback).
                if hasWaitingTool {
                    // No-op
                } else {
                    let targetPhase: SessionPhase = hasRunningTool ? .processing : .idle
                    if session.phase.canTransition(to: targetPhase) {
                        session.phase = targetPhase
                        sessions[sessionId] = session
                        mutatedSession = true
                    }
                }
            }

            let needsSync: Bool
            switch session.phase {
            case .processing, .waitingForApproval:
                needsSync = true
            default:
                needsSync = false
            }
            if needsSync {
                scheduleFileSync(sessionId: sessionId, cwd: session.cwd)
            }
        }

        if removedSession || mutatedSession {
            publishState()
        }
    }

    /// Check if a process is still running
    private nonisolated func isProcessRunning(pid: Int) -> Bool {
        return kill(Int32(pid), 0) == 0
    }

    // MARK: - State Publishing

    private func publishState() {
        let sortedSessions = Array(sessions.values).sorted { $0.projectName < $1.projectName }
        sessionsSubject.send(sortedSessions)
    }

    // MARK: - Queries

    /// Get a specific session
    func session(for sessionId: String) -> SessionState? {
        sessions[sessionId]
    }

    /// Check if there's an active permission for a session
    func hasActivePermission(sessionId: String) -> Bool {
        guard let session = sessions[sessionId] else { return false }
        if case .waitingForApproval = session.phase {
            return true
        }
        return false
    }

    /// Get all current sessions
    func allSessions() -> [SessionState] {
        Array(sessions.values)
    }

    // MARK: - Remote JSONL Caching

    /// Appends raw JSONL lines from a remote hook event to a local cache file,
    /// then triggers an incremental file sync so the UI gets updated messages.
    ///
    /// The cache path mirrors ConversationParser's sessionFilePath logic:
    ///   <remoteCacheDir>/<escaped-cwd>/<sessionId>.jsonl
    /// so ConversationParser can find it without any changes.
    private func appendRemoteJsonlLines(_ lines: [String], sessionId: String, cwd: String) {
        let projectDir = cwd
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ".", with: "-")
        let dir = IslandPaths.remoteCacheDir.appendingPathComponent(projectDir)
        let filePath = dir.appendingPathComponent("\(sessionId).jsonl")

        Self.logger.info("[Remote] Appending \(lines.count) JSONL lines for session \(sessionId.prefix(8), privacy: .public) cwd=\(cwd, privacy: .public)")
        Self.logger.info("[Remote] Cache file path: \(filePath.path, privacy: .public)")

        let fm = FileManager.default
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let appended = lines.map { $0 + "\n" }.joined()
            guard let data = appended.data(using: .utf8) else { return }
            if fm.fileExists(atPath: filePath.path) {
                let handle = try FileHandle(forWritingTo: filePath)
                handle.seekToEndOfFile()
                handle.write(data)
                handle.closeFile()
            } else {
                try data.write(to: filePath, options: .atomic)
            }
            Self.logger.info("[Remote] Successfully wrote \(data.count) bytes to cache file")
        } catch {
            Self.logger.error("Failed to cache remote JSONL: \(error.localizedDescription, privacy: .public)")
            return
        }

        scheduleFileSync(sessionId: sessionId, cwd: cwd)
    }
}
