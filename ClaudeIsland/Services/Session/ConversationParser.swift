//
//  ConversationParser.swift
//  ClaudeIsland
//
//  Parses Claude JSONL conversation files to extract summary and last message
//  Optimized for incremental parsing - only reads new lines since last sync
//

import Foundation
import os.log

/// Token usage information from a session
struct UsageInfo: Equatable {
    var inputTokens: Int = 0
    var outputTokens: Int = 0
    var cacheReadTokens: Int = 0
    var cacheCreationTokens: Int = 0

    var totalTokens: Int {
        inputTokens + outputTokens
    }

    /// Formatted string for display (e.g., "12.5K tokens")
    var formattedTotal: String {
        let total = totalTokens
        if total >= 1_000_000 {
            return String(format: "%.1fM", Double(total) / 1_000_000)
        } else if total >= 1_000 {
            return String(format: "%.1fK", Double(total) / 1_000)
        }
        return "\(total)"
    }
}

struct ConversationInfo: Equatable {
    let summary: String?
    let lastMessage: String?
    let lastMessageRole: String?  // "user", "assistant", or "tool"
    let lastToolName: String?  // Tool name if lastMessageRole is "tool"
    let firstUserMessage: String?  // Fallback title when no summary
    let lastUserMessageDate: Date?  // Timestamp of last user message (for stable sorting)
    var usage: UsageInfo = UsageInfo()  // Token usage stats
}

actor ConversationParser {
    static let shared = ConversationParser()

    /// Bump this when parsing behavior changes in a way that should invalidate cached results.
    /// (e.g. adding support for new transcript formats like Codex token_count events)
    private static let cacheVersion: Int = 3

    /// Logger for conversation parser (nonisolated static for cross-context access)
    nonisolated static let logger = Logger(subsystem: "com.codingisland", category: "Parser")

    /// Shared ISO8601 date formatter (expensive to create, reused across all message parsing)
    private let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// Cache of parsed conversation info, keyed by session file path
    private var cache: [String: CachedInfo] = [:]

    private var incrementalState: [String: IncrementalParseState] = [:]

    private struct CachedInfo {
        let version: Int
        let modificationDate: Date
        let fileSize: UInt64
        let info: ConversationInfo
    }

    // MARK: - Codex Session Path Cache

    /// Codex session files are not stored as `<sessionId>.jsonl` so we cache resolved paths.
    nonisolated(unsafe) private static var codexSessionPathCache: [String: String] = [:]
    nonisolated private static let codexSessionPathLock = NSLock()

    /// External providers can supply a direct transcript path in hook payloads.
    nonisolated(unsafe) private static var externalSessionPathCache: [String: String] = [:]
    nonisolated private static let externalSessionPathLock = NSLock()

    nonisolated private static func cachedCodexSessionPath(for sessionId: String) -> String? {
        codexSessionPathLock.lock()
        defer { codexSessionPathLock.unlock() }
        return codexSessionPathCache[sessionId]
    }

    nonisolated private static func setCachedCodexSessionPath(_ path: String, for sessionId: String) {
        codexSessionPathLock.lock()
        codexSessionPathCache[sessionId] = path
        codexSessionPathLock.unlock()
    }

    nonisolated static func rememberExternalSessionPath(_ path: String, for sessionId: String) {
        externalSessionPathLock.lock()
        externalSessionPathCache[sessionId] = path
        externalSessionPathLock.unlock()
    }

    nonisolated private static func cachedExternalSessionPath(for sessionId: String) -> String? {
        externalSessionPathLock.lock()
        defer { externalSessionPathLock.unlock() }
        return externalSessionPathCache[sessionId]
    }

    /// State for incremental JSONL parsing
    private struct IncrementalParseState {
        var lastFileOffset: UInt64 = 0
        var lastSnapshotMarker: String?
        var messages: [ChatMessage] = []
        var seenToolIds: Set<String> = []
        var seenAssistantMessageIds: Set<String> = [] // Track assistant message IDs to deduplicate
        var toolIdToName: [String: String] = [:]  // Map tool_use_id to tool name
        var completedToolIds: Set<String> = []  // Tools that have received results
        var toolResults: [String: ToolResult] = [:]  // Tool results keyed by tool_use_id
        var structuredResults: [String: ToolResultData] = [:]  // Structured results keyed by tool_use_id
        var lastClearOffset: UInt64 = 0  // Offset of last /clear command (0 = none or at start)
        var clearPending: Bool = false  // True if a /clear was just detected
    }

    /// Parsed tool result data
    struct ToolResult {
        let content: String?
        let stdout: String?
        let stderr: String?
        let isError: Bool
        let isInterrupted: Bool

        init(content: String?, stdout: String?, stderr: String?, isError: Bool) {
            self.content = content
            self.stdout = stdout
            self.stderr = stderr
            self.isError = isError
            // Detect if this was an interrupt or rejection (various formats)
            self.isInterrupted = isError && (
                content?.contains("Interrupted by user") == true ||
                content?.contains("interrupted by user") == true ||
                content?.contains("user doesn't want to proceed") == true
            )
        }
    }

    private struct CodeBuddyTranscript {
        let info: ConversationInfo
        let messages: [ChatMessage]
        let completedToolIds: Set<String>
        let toolResults: [String: ToolResult]
        let structuredResults: [String: ToolResultData]
        let toolIdToName: [String: String]
    }

    /// Parse a JSONL file to extract conversation info
    /// Uses caching based on file modification time
    func parse(sessionId: String, cwd: String) -> ConversationInfo {
        let sessionFile = Self.sessionFilePath(sessionId: sessionId, cwd: cwd)

        return parseFile(atPath: sessionFile)
    }

    /// Parse a JSONL file directly from its absolute path.
    /// Reuses the same cache as `parse(sessionId:cwd:)` so repeated full-history scans
    /// do not re-read unchanged files.
    func parseFile(atPath sessionFile: String) -> ConversationInfo {

        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: sessionFile),
              let attrs = try? fileManager.attributesOfItem(atPath: sessionFile),
              let modDate = attrs[.modificationDate] as? Date else {
            return ConversationInfo(summary: nil, lastMessage: nil, lastMessageRole: nil, lastToolName: nil, firstUserMessage: nil, lastUserMessageDate: nil)
        }

        let fileSize = (attrs[.size] as? NSNumber)?.uint64Value ?? 0

        if let cached = cache[sessionFile],
           cached.version == Self.cacheVersion,
           cached.modificationDate == modDate,
           cached.fileSize == fileSize {
            return cached.info
        }

        guard let data = fileManager.contents(atPath: sessionFile) else {
            return ConversationInfo(summary: nil, lastMessage: nil, lastMessageRole: nil, lastToolName: nil, firstUserMessage: nil, lastUserMessageDate: nil)
        }

        let info: ConversationInfo
        if let codeBuddy = parseCodeBuddyTranscript(data: data, filePath: sessionFile) {
            info = codeBuddy.info
        } else if let content = String(data: data, encoding: .utf8) {
            info = parseContent(content)
        } else {
            return ConversationInfo(summary: nil, lastMessage: nil, lastMessageRole: nil, lastToolName: nil, firstUserMessage: nil, lastUserMessageDate: nil)
        }

        cache[sessionFile] = CachedInfo(version: Self.cacheVersion, modificationDate: modDate, fileSize: fileSize, info: info)

        return info
    }

    /// Parse JSONL content
    private func parseContent(_ content: String) -> ConversationInfo {
        let lines = content.components(separatedBy: "\n").filter { !$0.isEmpty }

        var summary: String?
        var lastMessage: String?
        var lastMessageRole: String?
        var lastToolName: String?
        var firstUserMessage: String?
        var lastUserMessageDate: Date?
        var usage = UsageInfo()

        // Codex format reports cumulative token usage via event_msg/token_count.
        // We take the maximum cumulative totals observed in the file.
        var sawCodexTokenCount = false
        var codexMaxInput = 0
        var codexMaxOutput = 0
        var codexMaxCached = 0

        let formatter = isoFormatter

        // First pass: collect usage from all assistant messages
        for line in lines {
            guard let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                continue
            }

            // Codex CLI format: {"type":"event_msg","payload":{"type":"token_count","info":{...}}}
            if let recordType = json["type"] as? String,
               recordType == "event_msg",
               let payload = json["payload"] as? [String: Any],
               (payload["type"] as? String) == "token_count",
               let info = payload["info"] as? [String: Any],
               let total = info["total_token_usage"] as? [String: Any] {
                sawCodexTokenCount = true
                if let v = total["input_tokens"] as? Int { codexMaxInput = max(codexMaxInput, v) }
                if let v = total["output_tokens"] as? Int { codexMaxOutput = max(codexMaxOutput, v) }
                if let v = total["cached_input_tokens"] as? Int { codexMaxCached = max(codexMaxCached, v) }
                continue
            }

            if json["message"] == nil,
               let responseMeta = json["response_meta"] as? [String: Any],
               let usageDict = responseMeta["usage"] as? [String: Any] {
                usage.inputTokens += usageDict["prompt_tokens"] as? Int ?? 0
                usage.outputTokens += usageDict["completion_tokens"] as? Int ?? 0
                continue
            }

            if json["type"] as? String == "assistant" || json["message"] != nil {
                let message: [String: Any]?
                if let type = json["type"] as? String, type == "assistant" {
                    message = json["message"] as? [String: Any]
                } else if let outerMsg = json["message"] as? [String: Any], let innerMsg = outerMsg["message"] as? [String: Any], innerMsg["role"] as? String == "assistant" {
                    message = innerMsg
                } else {
                    continue
                }

                // Claude Code format: message.usage.{input_tokens, output_tokens, ...}
                if let usageDict = message?["usage"] as? [String: Any] {
                    usage.inputTokens += usageDict["input_tokens"] as? Int ?? 0
                    usage.outputTokens += usageDict["output_tokens"] as? Int ?? 0
                    usage.cacheReadTokens += usageDict["cache_read_input_tokens"] as? Int ?? 0
                    usage.cacheCreationTokens += usageDict["cache_creation_input_tokens"] as? Int ?? 0
                    continue
                }

                // Coco / Trae CLI format: message.response_meta.usage.{prompt_tokens, completion_tokens, ...}
                if let responseMeta = message?["response_meta"] as? [String: Any],
                   let usageDict = responseMeta["usage"] as? [String: Any] {
                    usage.inputTokens += usageDict["prompt_tokens"] as? Int ?? 0
                    usage.outputTokens += usageDict["completion_tokens"] as? Int ?? 0
                    continue
                }

            }
        }

        if sawCodexTokenCount {
            usage.inputTokens = codexMaxInput
            usage.outputTokens = codexMaxOutput
            usage.cacheReadTokens = codexMaxCached
        }

        for line in lines {
            guard let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                continue
            }

            // Extract message payload handling both Claude Code and Coco formats
            var msgContent: String?
            let type = json["type"] as? String
            let isMeta = json["isMeta"] as? Bool ?? false
            
            if type == "user" && !isMeta {
                if let message = json["message"] as? [String: Any] {
                    msgContent = message["content"] as? String
                }
            } else if let userPromptSubmit = json["user_prompt_submit"] as? [String: Any],
                      let prompt = userPromptSubmit["prompt"] as? String {
                msgContent = prompt
            } else if let agentStart = json["agent_start"] as? [String: Any],
                      let input = agentStart["input"] as? [[String: Any]],
                      let firstUser = input.first(where: { ($0["role"] as? String) == "user" && ($0["extra"] as? [String: Any])?["is_original_user_input"] as? Bool != false && ($0["extra"] as? [String: Any])?["is_additional_context_input"] as? Bool != true }) {
                msgContent = firstUser["content"] as? String
            } else if let messageOuter = json["message"] as? [String: Any],
                      let innerMsg = messageOuter["message"] as? [String: Any],
                      innerMsg["role"] as? String == "user",
                      (innerMsg["extra"] as? [String: Any])?["is_original_user_input"] as? Bool != false,
                      (innerMsg["extra"] as? [String: Any])?["is_additional_context_input"] as? Bool != true {
                msgContent = innerMsg["content"] as? String
            }

            if let content = msgContent {
                if !content.hasPrefix("<command-name>") && !content.hasPrefix("<local-command") && !content.hasPrefix("Caveat:") && !content.hasPrefix("<system-reminder>") {
                    firstUserMessage = Self.truncateMessage(content, maxLength: 50)
                    break
                }
            }
        }

        var foundLastUserMessage = false
        for line in lines.reversed() {
            guard let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                continue
            }

            var type = json["type"] as? String
            let isMeta = json["isMeta"] as? Bool ?? false
            
            // Extract message for Claude Code and Coco format
            var contentStr: String?
            var contentArray: [[String: Any]]?
            
            if type == "user" || type == "assistant" {
                if !isMeta, let message = json["message"] as? [String: Any],
                   (message["extra"] as? [String: Any])?["is_original_user_input"] as? Bool != false,
                   (message["extra"] as? [String: Any])?["is_additional_context_input"] as? Bool != true {
                    contentStr = message["content"] as? String
                    contentArray = message["content"] as? [[String: Any]]
                }
            } else if let userPromptSubmit = json["user_prompt_submit"] as? [String: Any],
                      let prompt = userPromptSubmit["prompt"] as? String {
                type = "user"
                contentStr = prompt
            } else if let agentStart = json["agent_start"] as? [String: Any],
                      let input = agentStart["input"] as? [[String: Any]],
                      let firstUser = input.first(where: { ($0["role"] as? String) == "user" && ($0["extra"] as? [String: Any])?["is_original_user_input"] as? Bool != false && ($0["extra"] as? [String: Any])?["is_additional_context_input"] as? Bool != true }) {
                type = "user"
                contentStr = firstUser["content"] as? String
            } else if let messageOuter = json["message"] as? [String: Any],
                      let innerMsg = messageOuter["message"] as? [String: Any],
                      (innerMsg["extra"] as? [String: Any])?["is_original_user_input"] as? Bool != false,
                      (innerMsg["extra"] as? [String: Any])?["is_additional_context_input"] as? Bool != true {
                type = innerMsg["role"] as? String
                contentStr = innerMsg["content"] as? String
            } else if let toolCallOuter = json["tool_call"] as? [String: Any],
                      let toolInfo = toolCallOuter["tool_info"] as? [String: Any] {
                // Coco tool use
                let toolName = toolInfo["name"] as? String ?? "Tool"
                if lastMessage == nil {
                    var toolInputStr = ""
                    if let input = toolCallOuter["input"] as? [String: Any],
                       let structuredInput = input["structured_input"] as? [String: Any] {
                        toolInputStr = Self.formatToolInput(structuredInput, toolName: toolName)
                    }
                    lastMessage = toolInputStr.isEmpty ? toolName : toolInputStr
                    lastMessageRole = "tool"
                    lastToolName = toolName
                }
            }

            if lastMessage == nil {
                if type == "user" || type == "assistant" {
                    if let msgContent = contentStr {
                        if !msgContent.hasPrefix("<command-name>") && !msgContent.hasPrefix("<local-command") && !msgContent.hasPrefix("Caveat:") && !msgContent.hasPrefix("<system-reminder>") {
                            lastMessage = msgContent
                            lastMessageRole = type
                        }
                    } else if let array = contentArray {
                        for block in array.reversed() {
                            let blockType = block["type"] as? String
                            if blockType == "tool_use" {
                                let toolName = block["name"] as? String ?? "Tool"
                                let toolInput = Self.formatToolInput(block["input"] as? [String: Any], toolName: toolName)
                                lastMessage = toolInput
                                lastMessageRole = "tool"
                                lastToolName = toolName
                                break
                            } else if blockType == "text", let text = block["text"] as? String {
                                if !text.hasPrefix("[Request interrupted by user") && !text.hasPrefix("<system-reminder>") {
                                    lastMessage = text
                                    lastMessageRole = type
                                    break
                                }
                            }
                        }
                    }
                }
            }

            if !foundLastUserMessage && type == "user" {
                if let msgContent = contentStr {
                    if !msgContent.hasPrefix("<command-name>") && !msgContent.hasPrefix("<local-command") && !msgContent.hasPrefix("Caveat:") && !msgContent.hasPrefix("<system-reminder>") {
                        let timestampStr = (json["timestamp"] as? String) ?? (json["created_at"] as? String)
                        if let tsStr = timestampStr {
                            lastUserMessageDate = formatter.date(from: tsStr)
                        }
                        foundLastUserMessage = true
                    }
                }
            }

            if summary == nil {
                if type == "summary", let summaryText = json["summary"] as? String {
                    summary = summaryText
                } else if let stateUpdate = json["state_update"] as? [String: Any],
                          let updates = stateUpdate["updates"] as? [String: Any],
                          let title = updates["title"] as? String, !title.isEmpty {
                    summary = title
                }
            }

            if summary != nil && lastMessage != nil && foundLastUserMessage {
                break
            }
        }

        return ConversationInfo(
            summary: summary,
            lastMessage: Self.truncateMessage(lastMessage, maxLength: 80),
            lastMessageRole: lastMessageRole,
            lastToolName: lastToolName,
            firstUserMessage: firstUserMessage,
            lastUserMessageDate: lastUserMessageDate,
            usage: usage
        )
    }

    /// Format tool input for display in instance list
    private static func formatToolInput(_ input: [String: Any]?, toolName: String) -> String {
        guard let input = input else { return "" }

        switch toolName {
        case "Read", "Write", "Edit":
            if let filePath = input["file_path"] as? String {
                return (filePath as NSString).lastPathComponent
            }
        case "Bash":
            if let command = input["command"] as? String {
                return command
            }
        case "Grep":
            if let pattern = input["pattern"] as? String {
                return pattern
            }
        case "Glob":
            if let pattern = input["pattern"] as? String {
                return pattern
            }
        case "Task", "Agent":
            // "Task" is the legacy name; Claude Code now uses "Agent"
            if let description = input["description"] as? String {
                return description
            }
        case "WebFetch":
            if let url = input["url"] as? String {
                return url
            }
        case "WebSearch":
            if let query = input["query"] as? String {
                return query
            }
        default:
            for (_, value) in input {
                if let str = value as? String, !str.isEmpty {
                    return str
                }
            }
        }
        return ""
    }

    /// Truncate message for display
    private static func truncateMessage(_ message: String?, maxLength: Int = 80) -> String? {
        guard let msg = message else { return nil }
        let cleaned = msg.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        if cleaned.count > maxLength {
            return String(cleaned.prefix(maxLength - 3)) + "..."
        }
        return cleaned
    }

    // MARK: - Full Conversation Parsing

    /// Parse full conversation history for chat view (returns ALL messages - use sparingly)
    func parseFullConversation(sessionId: String, cwd: String) -> [ChatMessage] {
        let sessionFile = Self.sessionFilePath(sessionId: sessionId, cwd: cwd)

        guard FileManager.default.fileExists(atPath: sessionFile) else {
            Self.logger.warning("[Parser] parseFullConversation: file NOT found: \(sessionFile, privacy: .public)")
            return []
        }

        if let transcript = parseCodeBuddyTranscript(atPath: sessionFile) {
            var state = incrementalState[sessionId] ?? IncrementalParseState()
            let marker = snapshotMarker(for: sessionFile)
            state.lastSnapshotMarker = marker
            state.lastFileOffset = Self.currentFileSize(atPath: sessionFile)
            state.messages = transcript.messages
            state.completedToolIds = transcript.completedToolIds
            state.toolResults = transcript.toolResults
            state.structuredResults = transcript.structuredResults
            state.toolIdToName = transcript.toolIdToName
            state.seenToolIds = Set(transcript.toolIdToName.keys)
            state.seenAssistantMessageIds = Set(transcript.messages.filter { $0.role == .assistant }.map { "msg-\($0.id)" })
            incrementalState[sessionId] = state
            return transcript.messages
        }

        var state = incrementalState[sessionId] ?? IncrementalParseState()
        _ = parseNewLines(filePath: sessionFile, state: &state)
        incrementalState[sessionId] = state

        return state.messages
    }

    /// Result of incremental parsing
    struct IncrementalParseResult {
        let newMessages: [ChatMessage]
        let allMessages: [ChatMessage]
        let completedToolIds: Set<String>
        let toolResults: [String: ToolResult]
        let structuredResults: [String: ToolResultData]
        let clearDetected: Bool
        let sawAgentEnd: Bool
        /// Whether the file had new bytes since last parse (even if no messages were parsed)
        let didReadNewBytes: Bool
    }

    /// Parse only NEW messages since last call (efficient incremental updates)
    func parseIncremental(sessionId: String, cwd: String) -> IncrementalParseResult {
        let sessionFile = Self.sessionFilePath(sessionId: sessionId, cwd: cwd)

        guard FileManager.default.fileExists(atPath: sessionFile) else {
            Self.logger.warning("[Parser] parseIncremental: file NOT found: \(sessionFile, privacy: .public)")
            return IncrementalParseResult(
                newMessages: [],
                allMessages: [],
                completedToolIds: [],
                toolResults: [:],
                structuredResults: [:],
                clearDetected: false,
                sawAgentEnd: false,
                didReadNewBytes: false
            )
        }

        if let transcript = parseCodeBuddyTranscript(atPath: sessionFile) {
            var state = incrementalState[sessionId] ?? IncrementalParseState()
            let marker = snapshotMarker(for: sessionFile)

            if state.lastSnapshotMarker == marker {
                return IncrementalParseResult(
                    newMessages: [],
                    allMessages: state.messages,
                    completedToolIds: state.completedToolIds,
                    toolResults: state.toolResults,
                    structuredResults: state.structuredResults,
                    clearDetected: false,
                    sawAgentEnd: false,
                    didReadNewBytes: false
                )
            }

            let existingIds = Set(state.messages.map(\.id))
            let newMessages: [ChatMessage]
            if transcript.messages.count < state.messages.count {
                newMessages = transcript.messages
            } else {
                newMessages = transcript.messages.filter { !existingIds.contains($0.id) }
            }

            state.lastSnapshotMarker = marker
            state.lastFileOffset = Self.currentFileSize(atPath: sessionFile)
            state.clearPending = false
            state.messages = transcript.messages
            state.completedToolIds = transcript.completedToolIds
            state.toolResults = transcript.toolResults
            state.structuredResults = transcript.structuredResults
            state.toolIdToName = transcript.toolIdToName
            state.seenToolIds = Set(transcript.toolIdToName.keys)
            state.seenAssistantMessageIds = Set(transcript.messages.filter { $0.role == .assistant }.map { "msg-\($0.id)" })
            incrementalState[sessionId] = state

            return IncrementalParseResult(
                newMessages: newMessages,
                allMessages: transcript.messages,
                completedToolIds: transcript.completedToolIds,
                toolResults: transcript.toolResults,
                structuredResults: transcript.structuredResults,
                clearDetected: false,
                sawAgentEnd: false,
                didReadNewBytes: true
            )
        }

        var state = incrementalState[sessionId] ?? IncrementalParseState()
        let parseResult = parseNewLines(filePath: sessionFile, state: &state)
        let clearDetected = state.clearPending
        if clearDetected {
            state.clearPending = false
        }
        incrementalState[sessionId] = state

        return IncrementalParseResult(
            newMessages: parseResult.messages,
            allMessages: state.messages,
            completedToolIds: state.completedToolIds,
            toolResults: state.toolResults,
            structuredResults: state.structuredResults,
            clearDetected: clearDetected,
            sawAgentEnd: parseResult.sawAgentEnd,
            didReadNewBytes: parseResult.didReadNewBytes
        )
    }

    private static func extractText(from message: ChatMessage) -> String {
        var text = ""
        for block in message.content {
            if case let .text(t) = block {
                text += t
            }
        }
        return text
    }

    /// Parse only new lines since last read (incremental)
    private func parseNewLines(filePath: String, state: inout IncrementalParseState) -> (messages: [ChatMessage], sawAgentEnd: Bool, didReadNewBytes: Bool) {
        guard let fileHandle = FileHandle(forReadingAtPath: filePath) else {
            Self.logger.warning("[Parser] Cannot open file: \(filePath, privacy: .public)")
            return ([], false, false)
        }
        defer { try? fileHandle.close() }

        let fileSize: UInt64
        do {
            fileSize = try fileHandle.seekToEnd()
        } catch {
            return ([], false, false)
        }

        let offsetCopy = state.lastFileOffset
        Self.logger.info("[Parser] File=\(filePath, privacy: .public) size=\(fileSize) offset=\(offsetCopy)")

        if fileSize < state.lastFileOffset {
            Self.logger.info("[Parser] File shrank, resetting state")
            state = IncrementalParseState()
        }

        if fileSize == state.lastFileOffset {
            Self.logger.info("[Parser] No new bytes, returning empty")
            return ([], false, false)
        }

        do {
            try fileHandle.seek(toOffset: state.lastFileOffset)
        } catch {
            return (state.messages, false, false)
        }

        guard let newData = try? fileHandle.readToEnd(),
              let newContent = String(data: newData, encoding: .utf8) else {
            return (state.messages, false, false)
        }

        state.clearPending = false
        let isIncrementalRead = state.lastFileOffset > 0
        let lines = newContent.components(separatedBy: "\n")
        var newMessages: [ChatMessage] = []
        var sawAgentEnd = false

        for line in lines where !line.isEmpty {
            if line.contains("<command-name>/clear</command-name>") {
                state.messages = []
                state.seenToolIds = []
                state.seenAssistantMessageIds = []
                state.toolIdToName = [:]
                state.completedToolIds = []
                state.toolResults = [:]
                state.structuredResults = [:]

                if isIncrementalRead {
                    state.clearPending = true
                    state.lastClearOffset = state.lastFileOffset
                    Self.logger.debug("/clear detected (new), will notify UI")
                }
                continue
            }

            if line.contains("\"tool_result\"") || line.contains("\"tool_call_output\"") {
                if let lineData = line.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] {
                   
                   // Claude Code format
                   if let messageDict = json["message"] as? [String: Any],
                      let contentArray = messageDict["content"] as? [[String: Any]] {
                        let toolUseResult = json["toolUseResult"] as? [String: Any]
                        let topLevelToolName = json["toolName"] as? String
                        let stdout = toolUseResult?["stdout"] as? String
                        let stderr = toolUseResult?["stderr"] as? String

                        for block in contentArray {
                            if block["type"] as? String == "tool_result",
                               let toolUseId = block["tool_use_id"] as? String {
                                state.completedToolIds.insert(toolUseId)

                                let content = block["content"] as? String
                                let isError = block["is_error"] as? Bool ?? false
                                state.toolResults[toolUseId] = ToolResult(
                                    content: content,
                                    stdout: stdout,
                                    stderr: stderr,
                                    isError: isError
                                )

                                let toolName = topLevelToolName ?? state.toolIdToName[toolUseId]

                                if let toolUseResult = toolUseResult,
                                   let name = toolName {
                                    let structured = Self.parseStructuredResult(
                                        toolName: name,
                                        toolUseResult: toolUseResult,
                                        isError: isError
                                    )
                                    state.structuredResults[toolUseId] = structured
                                }
                            }
                        }
                    }
                    // Coco format
                    else if let toolCallOutput = json["tool_call_output"] as? [String: Any],
                            let toolUseId = toolCallOutput["tool_call_id"] as? String {
                        state.completedToolIds.insert(toolUseId)
                        
                        var content: String?
                        var stdout: String?
                        var stderr: String?
                        var isError = false
                        
                        if let output = toolCallOutput["output"] as? [String: Any] {
                            isError = output["is_error"] as? Bool ?? false
                            
                            // Check for content array
                            if let contentArray = output["content"] as? [[String: Any]] {
                                content = contentArray.compactMap { $0["text"] as? String }.joined(separator: "\n")
                            } else {
                                // Some tools might format output differently
                                content = output["stdout"] as? String ?? output["text"] as? String
                            }
                            
                            stdout = output["stdout"] as? String
                            stderr = output["stderr"] as? String
                        }
                        
                        state.toolResults[toolUseId] = ToolResult(
                            content: content,
                            stdout: stdout,
                            stderr: stderr,
                            isError: isError
                        )
                        
                        if let toolInfo = toolCallOutput["tool_info"] as? [String: Any],
                           let toolName = toolInfo["name"] as? String,
                           let output = toolCallOutput["output"] as? [String: Any] {
                            let structured = Self.parseStructuredResult(
                                toolName: toolName,
                                toolUseResult: output,
                                isError: isError
                            )
                            state.structuredResults[toolUseId] = structured
                        }
                    }
                }
            } else if line.contains("\"tool_call\"") || line.contains("\"tool_call_output\"") {
                if let lineData = line.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                   let message = parseMessageLine(json, seenToolIds: &state.seenToolIds, seenAssistantMessageIds: &state.seenAssistantMessageIds, toolIdToName: &state.toolIdToName) {
                    
                    if let last = state.messages.last, last.role == message.role {
                        let lastText = Self.extractText(from: last)
                        let currentText = Self.extractText(from: message)
                        if !currentText.isEmpty && lastText == currentText {
                            continue
                        }
                    }
                    
                    newMessages.append(message)
                    state.messages.append(message)
                }
            } else if line.contains("\"type\":\"user\"") || line.contains("\"type\":\"assistant\"") || line.contains("\"agent_start\"") || line.contains("\"message\"") || line.contains("\"agent_end\"") {
                if let lineData = line.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] {
                    // Coco/Trae 的 events.jsonl 在不同版本里对 agent_end 的编码方式不一致：
                    // - {"agent_end": {...}}
                    // - {"type":"agent_end", ...}
                    // - {"event":"agent_end", ...}
                    if json["agent_end"] != nil {
                        sawAgentEnd = true
                    } else if let t = json["type"] as? String, t.lowercased() == "agent_end" {
                        sawAgentEnd = true
                    } else if let e = json["event"] as? String, e.lowercased() == "agent_end" {
                        sawAgentEnd = true
                    } else if let name = json["name"] as? String, name.lowercased() == "agent_end" {
                        sawAgentEnd = true
                    }

                    if let message = parseMessageLine(json, seenToolIds: &state.seenToolIds, seenAssistantMessageIds: &state.seenAssistantMessageIds, toolIdToName: &state.toolIdToName) {
                        
                        if let last = state.messages.last, last.role == message.role {
                            let lastText = Self.extractText(from: last)
                            let currentText = Self.extractText(from: message)
                            if !currentText.isEmpty && lastText == currentText {
                                continue
                            }
                        }
                        
                        Self.logger.info("[Parser] Parsed message id=\(message.id.prefix(8), privacy: .public) role=\(String(describing: message.role), privacy: .public) blocks=\(message.content.count)")
                        newMessages.append(message)
                        state.messages.append(message)
                    } else {
                        let keys = Array((json.keys.prefix(5)))
                        Self.logger.info("[Parser] parseMessageLine returned nil for line with keys: \(keys, privacy: .public)")
                    }
                } else {
                    Self.logger.warning("[Parser] JSON parse failed for candidate line prefix: \(String(line.prefix(80)), privacy: .public)")
                }
            }
        }

        let totalMessages = state.messages.count
        Self.logger.info("[Parser] Done: newMessages=\(newMessages.count) totalMessages=\(totalMessages)")
        state.lastFileOffset = fileSize
        return (newMessages, sawAgentEnd, true)
    }

    /// Get set of completed tool IDs for a session
    func completedToolIds(for sessionId: String) -> Set<String> {
        return incrementalState[sessionId]?.completedToolIds ?? []
    }

    /// Get tool results for a session
    func toolResults(for sessionId: String) -> [String: ToolResult] {
        return incrementalState[sessionId]?.toolResults ?? [:]
    }

    /// Get structured tool results for a session
    func structuredResults(for sessionId: String) -> [String: ToolResultData] {
        return incrementalState[sessionId]?.structuredResults ?? [:]
    }

    /// Reset incremental state for a session (call when reloading)
    func resetState(for sessionId: String) {
        incrementalState.removeValue(forKey: sessionId)
    }

    private static func currentFileSize(atPath path: String) -> UInt64 {
        ((try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.uint64Value) ?? 0
    }

    private func snapshotMarker(for filePath: String) -> String? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: filePath),
              let modDate = attrs[.modificationDate] as? Date else {
            return nil
        }
        let fileSize = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
        return "\(modDate.timeIntervalSince1970)-\(fileSize)"
    }

    /// Check if a /clear command was detected during the last parse
    /// Returns true once and consumes the pending flag
    func checkAndConsumeClearDetected(for sessionId: String) -> Bool {
        guard var state = incrementalState[sessionId], state.clearPending else {
            return false
        }
        state.clearPending = false
        incrementalState[sessionId] = state
        return true
    }

    /// Path to the JSONL file
    private static func sessionFilePath(sessionId: String, cwd: String) -> String {
        let projectDir = cwd.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ".", with: "-")

        // 1. Remote session cache (Coding Island's own cache for remote sessions)
        let islandCachePath = IslandPaths.remoteCacheDir.path + "/" + projectDir + "/" + sessionId + ".jsonl"
        if FileManager.default.fileExists(atPath: islandCachePath) {
            logger.info("[Parser] sessionFilePath: using island cache for \(sessionId.prefix(8), privacy: .public)")
            return islandCachePath
        }

        // 2. Local Claude Code sessions
        let claudePath = ClaudePaths.projectsDir.path + "/" + projectDir + "/" + sessionId + ".jsonl"
        if FileManager.default.fileExists(atPath: claudePath) {
            logger.info("[Parser] sessionFilePath: using claude path for \(sessionId.prefix(8), privacy: .public): \(claudePath, privacy: .public)")
            return claudePath
        }

        // 3. Local Coco (Trae CLI) sessions
        let cocoPath = NSHomeDirectory() + "/Library/Caches/coco/sessions/\(sessionId)/events.jsonl"
        if FileManager.default.fileExists(atPath: cocoPath) {
            logger.info("[Parser] sessionFilePath: using coco path for \(sessionId.prefix(8), privacy: .public)")
            return cocoPath
        }

        // 4. Transcript paths provided directly by external providers (e.g. CodeBuddy)
        if let cached = cachedExternalSessionPath(for: sessionId), FileManager.default.fileExists(atPath: cached) {
            logger.info("[Parser] sessionFilePath: using external transcript path for \(sessionId.prefix(8), privacy: .public)")
            return cached
        }

        // 5. Local Codex sessions
        if let cached = cachedCodexSessionPath(for: sessionId), FileManager.default.fileExists(atPath: cached) {
            logger.info("[Parser] sessionFilePath: using cached codex path for \(sessionId.prefix(8), privacy: .public)")
            return cached
        }

        let codexRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions")
        if let enumerator = FileManager.default.enumerator(
            at: codexRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) {
            for case let fileURL as URL in enumerator {
                guard fileURL.pathExtension == "jsonl" else { continue }
                let name = fileURL.lastPathComponent
                // Codex session files are typically named like: rollout-<timestamp>-<sessionId>.jsonl
                guard name.contains(sessionId) else { continue }
                let resolved = fileURL.path
                setCachedCodexSessionPath(resolved, for: sessionId)
                logger.info("[Parser] sessionFilePath: using codex path for \(sessionId.prefix(8), privacy: .public)")
                return resolved
            }
        }

        // Return claudePath as default if none exists
        logger.info("[Parser] sessionFilePath: returning default claude path for \(sessionId.prefix(8), privacy: .public): \(claudePath, privacy: .public)")
        return claudePath
    }

    private func parseCodeBuddyTranscript(atPath filePath: String) -> CodeBuddyTranscript? {
        guard let data = FileManager.default.contents(atPath: filePath) else { return nil }
        return parseCodeBuddyTranscript(data: data, filePath: filePath)
    }

    private func parseCodeBuddyTranscript(data: Data, filePath: String) -> CodeBuddyTranscript? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["messages"] is [[String: Any]] else {
            return nil
        }

        let baseDir = URL(fileURLWithPath: filePath).deletingLastPathComponent()
        let requests = json["requests"] as? [[String: Any]] ?? []
        let entries = json["messages"] as? [[String: Any]] ?? []

        var messageToRequestId: [String: String] = [:]
        var requestStartDates: [String: Date] = [:]
        var sessionUsage = UsageInfo()

        for request in requests {
            guard let requestId = request["id"] as? String else { continue }

            if let startedAt = request["startedAt"] as? Double {
                requestStartDates[requestId] = Date(timeIntervalSince1970: startedAt / 1000.0)
            } else if let startedAt = request["startedAt"] as? Int {
                requestStartDates[requestId] = Date(timeIntervalSince1970: Double(startedAt) / 1000.0)
            }

            if let usage = request["usage"] as? [String: Any] {
                sessionUsage.inputTokens += Self.intValue(from: usage["inputTokens"])
                sessionUsage.outputTokens += Self.intValue(from: usage["outputTokens"])
            }

            for messageId in request["messages"] as? [String] ?? [] {
                messageToRequestId[messageId] = requestId
            }
        }

        var parsedMessages: [ChatMessage] = []
        var completedToolIds: Set<String> = []
        var toolResults: [String: ToolResult] = [:]
        var structuredResults: [String: ToolResultData] = [:]
        var toolIdToName: [String: String] = [:]
        var firstUserMessage: String?
        var lastUserMessageDate: Date?
        var fallbackUsage = UsageInfo()

        for (index, entry) in entries.enumerated() {
            guard let resolved = resolveCodeBuddyMessage(entry: entry, baseDir: baseDir, messageToRequestId: messageToRequestId) else {
                continue
            }

            let requestId = resolved.requestId ?? messageToRequestId[resolved.id]
            let baseDate = resolved.createdAt
                ?? requestId.flatMap { requestStartDates[$0] }
                ?? Date(timeIntervalSince1970: TimeInterval(index))
            let timestamp = baseDate.addingTimeInterval(Double(index) * 0.001)

            var blocks: [MessageBlock] = []
            var visibleTextParts: [String] = []

            let contentBlocks = resolved.contentBlocks ?? []
            for contentBlock in contentBlocks {
                guard let type = contentBlock["type"] as? String else { continue }
                switch type {
                case "text":
                    let rawText = contentBlock["text"] as? String ?? contentBlock["content"] as? String ?? ""
                    let displayText: String
                    if resolved.role == "user" {
                        displayText = extractCodeBuddyUserText(rawText: rawText, extra: resolved.extra) ?? rawText
                    } else {
                        displayText = rawText
                    }
                    let trimmed = displayText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        blocks.append(.text(trimmed))
                        visibleTextParts.append(trimmed)
                    }
                case "image":
                    if let image = parseCodeBuddyImageBlock(contentBlock) {
                        blocks.append(.image(image))
                    }
                default:
                    break
                }
            }

            for toolCall in resolved.toolCalls {
                guard let toolId = stringValue(from: toolCall["id"]),
                      let toolName = stringValue(from: toolCall["name"]) else {
                    continue
                }
                let arguments = toolCall["arguments"] ?? toolCall["input"]
                let input = Self.stringifyDictionary(arguments)
                toolIdToName[toolId] = toolName
                blocks.append(.toolUse(ToolUseBlock(id: toolId, name: toolName, input: input)))
            }

            for toolResult in resolved.toolResults {
                let toolId = stringValue(from: toolResult["tool_call_id"]) ?? stringValue(from: toolResult["toolCallId"])
                guard let toolId else { continue }
                completedToolIds.insert(toolId)

                let outputPayload = (toolResult["output"] as? [String: Any]) ?? toolResult
                let content = normalizeCodeBuddyText(outputPayload["content"] ?? toolResult["content"])
                let stdout = stringValue(from: outputPayload["stdout"])
                let stderr = stringValue(from: outputPayload["stderr"])
                let isError = Self.boolValue(from: outputPayload["is_error"] ?? outputPayload["isError"])

                toolResults[toolId] = ToolResult(
                    content: content,
                    stdout: stdout,
                    stderr: stderr,
                    isError: isError
                )

                if let toolName = toolIdToName[toolId] {
                    structuredResults[toolId] = Self.parseStructuredResult(
                        toolName: toolName,
                        toolUseResult: outputPayload,
                        isError: isError
                    )
                }
            }

            if blocks.isEmpty { continue }

            let role: ChatRole = resolved.role == "user" ? .user : .assistant
            let message = ChatMessage(id: resolved.id, role: role, timestamp: timestamp, content: blocks)
            parsedMessages.append(message)

            if resolved.role == "user" {
                let text = visibleTextParts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                if firstUserMessage == nil, !text.isEmpty {
                    firstUserMessage = Self.truncateMessage(text, maxLength: 50)
                }
                lastUserMessageDate = timestamp
            }

            fallbackUsage.inputTokens += resolved.inputTokens
            fallbackUsage.outputTokens += resolved.outputTokens
        }

        if sessionUsage.totalTokens == 0 {
            sessionUsage = fallbackUsage
        }

        let info = buildConversationInfo(from: parsedMessages, firstUserMessage: firstUserMessage, lastUserMessageDate: lastUserMessageDate, usage: sessionUsage)

        return CodeBuddyTranscript(
            info: info,
            messages: parsedMessages,
            completedToolIds: completedToolIds,
            toolResults: toolResults,
            structuredResults: structuredResults,
            toolIdToName: toolIdToName
        )
    }

    private struct ResolvedCodeBuddyMessage {
        let id: String
        let role: String
        let contentBlocks: [[String: Any]]?
        let toolCalls: [[String: Any]]
        let toolResults: [[String: Any]]
        let extra: [String: Any]?
        let requestId: String?
        let createdAt: Date?
        let inputTokens: Int
        let outputTokens: Int
    }

    private func resolveCodeBuddyMessage(
        entry: [String: Any],
        baseDir: URL,
        messageToRequestId: [String: String]
    ) -> ResolvedCodeBuddyMessage? {
        guard let id = stringValue(from: entry["id"]) else { return nil }

        var merged = entry
        if merged["message"] == nil && merged["content"] == nil {
            let messageURL = baseDir.appendingPathComponent("messages/\(id).json")
            if let data = try? Data(contentsOf: messageURL),
               let fileJSON = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                for (key, value) in fileJSON where merged[key] == nil {
                    merged[key] = value
                }
            }
        }

        let innerMessage = parseCodeBuddyInnerMessage(merged["message"])
        let role = stringValue(from: merged["role"]) ?? stringValue(from: innerMessage?["role"]) ?? "assistant"
        let contentBlocks = (merged["content"] as? [[String: Any]]) ?? (innerMessage?["content"] as? [[String: Any]])
        let toolCalls = (merged["tool_calls"] as? [[String: Any]])
            ?? (merged["toolCalls"] as? [[String: Any]])
            ?? (innerMessage?["tool_calls"] as? [[String: Any]])
            ?? []
        let toolResults = (merged["tool_results"] as? [[String: Any]])
            ?? (merged["toolResults"] as? [[String: Any]])
            ?? (innerMessage?["tool_results"] as? [[String: Any]])
            ?? []
        let extra = parseJSONObject(from: merged["extra"])
        let requestId = stringValue(from: merged["request_id"]) ?? stringValue(from: extra?["requestId"]) ?? messageToRequestId[id]
        let createdAt = parseDate(from: merged["created_at"]) ?? parseDate(from: merged["timestamp"])
        let inputTokens = Self.intValue(from: merged["input_tokens"] ?? merged["inputTokens"])
        let outputTokens = Self.intValue(from: merged["output_tokens"] ?? merged["outputTokens"])

        return ResolvedCodeBuddyMessage(
            id: id,
            role: role,
            contentBlocks: contentBlocks,
            toolCalls: toolCalls,
            toolResults: toolResults,
            extra: extra,
            requestId: requestId,
            createdAt: createdAt,
            inputTokens: inputTokens,
            outputTokens: outputTokens
        )
    }

    private func buildConversationInfo(
        from messages: [ChatMessage],
        firstUserMessage: String?,
        lastUserMessageDate: Date?,
        usage: UsageInfo
    ) -> ConversationInfo {
        var lastMessage: String?
        var lastMessageRole: String?
        var lastToolName: String?

        outer: for message in messages.reversed() {
            for block in message.content.reversed() {
                switch block {
                case .text(let text):
                    let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !cleaned.isEmpty {
                        lastMessage = cleaned
                        lastMessageRole = message.role.rawValue
                        break outer
                    }
                case .toolUse(let tool):
                    lastMessage = tool.preview.isEmpty ? tool.name : tool.preview
                    lastMessageRole = "tool"
                    lastToolName = tool.name
                    break outer
                default:
                    continue
                }
            }
        }

        return ConversationInfo(
            summary: nil,
            lastMessage: Self.truncateMessage(lastMessage, maxLength: 80),
            lastMessageRole: lastMessageRole,
            lastToolName: lastToolName,
            firstUserMessage: firstUserMessage,
            lastUserMessageDate: lastUserMessageDate,
            usage: usage
        )
    }

    private func parseCodeBuddyInnerMessage(_ raw: Any?) -> [String: Any]? {
        if let dict = raw as? [String: Any] {
            return dict
        }
        if let string = raw as? String,
           let data = string.data(using: .utf8),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return dict
        }
        return nil
    }

    private func parseJSONObject(from raw: Any?) -> [String: Any]? {
        if let dict = raw as? [String: Any] {
            return dict
        }
        if let string = raw as? String,
           let data = string.data(using: .utf8),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return dict
        }
        return nil
    }

    private func extractCodeBuddyUserText(rawText: String, extra: [String: Any]?) -> String? {
        if let sourceBlocks = extra?["sourceContentBlocks"] as? [[String: Any]] {
            let text = sourceBlocks.compactMap { $0["text"] as? String }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { return text }
        }

        if let inputPhrase = extra?["inputPhrase"] as? [[String: Any]] {
            let text = inputPhrase.compactMap { $0["expandContent"] as? String ?? $0["content"] as? String }
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { return text }
        }

        if let extracted = extractTaggedSection(named: "user_query", from: rawText) {
            return extracted
        }

        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func extractTaggedSection(named tag: String, from text: String) -> String? {
        let pattern = "<\(tag)>\\s*([\\s\\S]*?)\\s*</\(tag)>"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: nsRange),
              let range = Range(match.range(at: 1), in: text) else {
            return nil
        }
        let value = text[range].trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private func parseCodeBuddyImageBlock(_ block: [String: Any]) -> ImageBlock? {
        if let source = block["source"] as? [String: Any],
           let mediaType = source["media_type"] as? String,
           let data = source["data"] as? String {
            return ImageBlock(mediaType: mediaType, base64Data: data)
        }

        let dataURL = stringValue(from: block["data_url"] ?? block["url"] ?? block["image_url"])
        guard let dataURL else { return nil }
        return imageBlock(fromDataURL: dataURL)
    }

    private func imageBlock(fromDataURL dataURL: String) -> ImageBlock? {
        guard dataURL.hasPrefix("data:"),
              let commaIndex = dataURL.firstIndex(of: ",") else { return nil }
        let header = String(dataURL[dataURL.startIndex..<commaIndex])
        let payload = String(dataURL[dataURL.index(after: commaIndex)...])
        let mediaType = header
            .replacingOccurrences(of: "data:", with: "")
            .replacingOccurrences(of: ";base64", with: "")
        guard !mediaType.isEmpty, !payload.isEmpty else { return nil }
        return ImageBlock(mediaType: mediaType, base64Data: payload)
    }

    private static func intValue(from raw: Any?) -> Int {
        if let int = raw as? Int { return int }
        if let double = raw as? Double { return Int(double) }
        if let string = raw as? String, let int = Int(string) { return int }
        return 0
    }

    private static func boolValue(from raw: Any?) -> Bool {
        if let bool = raw as? Bool { return bool }
        if let int = raw as? Int { return int != 0 }
        if let string = raw as? String {
            return ["true", "1", "yes"].contains(string.lowercased())
        }
        return false
    }

    private func parseDate(from raw: Any?) -> Date? {
        if let string = raw as? String {
            return isoFormatter.date(from: string)
        }
        if let milliseconds = raw as? Double {
            return Date(timeIntervalSince1970: milliseconds / 1000.0)
        }
        if let milliseconds = raw as? Int {
            return Date(timeIntervalSince1970: Double(milliseconds) / 1000.0)
        }
        return nil
    }

    private func normalizeCodeBuddyText(_ raw: Any?) -> String? {
        if let string = raw as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let blocks = raw as? [[String: Any]] {
            let text = blocks.compactMap { block -> String? in
                if let text = block["text"] as? String { return text }
                if let content = block["content"] as? String { return content }
                return nil
            }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }
        return nil
    }

    private static func stringifyDictionary(_ raw: Any?) -> [String: String] {
        guard let dict = raw as? [String: Any] else {
            if let jsonString = raw as? String,
               let data = jsonString.data(using: .utf8),
               let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return stringifyDictionary(decoded)
            }
            return [:]
        }

        var result: [String: String] = [:]
        for (key, value) in dict {
            if let string = value as? String {
                result[key] = string
            } else if let int = value as? Int {
                result[key] = String(int)
            } else if let double = value as? Double {
                result[key] = String(double)
            } else if let bool = value as? Bool {
                result[key] = bool ? "true" : "false"
            } else if JSONSerialization.isValidJSONObject(value),
                      let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
                      let string = String(data: data, encoding: .utf8) {
                result[key] = string
            } else {
                result[key] = String(describing: value)
            }
        }
        return result
    }

    private func stringValue(from raw: Any?) -> String? {
        if let string = raw as? String { return string }
        if let int = raw as? Int { return String(int) }
        if let double = raw as? Double { return String(double) }
        return nil
    }

    /// Build subagent JSONL file path.
    ///
    /// Current Claude Code nests subagent files under the parent session:
    ///   projects/<project>/<sessionId>/subagents/agent-<agentId>.jsonl
    ///
    /// Older Claude Code versions stored them flat:
    ///   projects/<project>/agent-<agentId>.jsonl
    ///
    /// Prefer the nested path; fall back to the flat path if only it exists
    /// (cross-version compatibility). If neither exists yet (file still being
    /// created) we return the nested path as the modern default.
    nonisolated static func subagentFilePath(sessionId: String, agentId: String, projectDir: String) -> String {
        let base = ClaudePaths.projectsDir.path + "/" + projectDir
        let nested = base + "/" + sessionId + "/subagents/agent-" + agentId + ".jsonl"
        let flat = base + "/agent-" + agentId + ".jsonl"

        let fm = FileManager.default
        if fm.fileExists(atPath: nested) { return nested }
        if fm.fileExists(atPath: flat) { return flat }
        return nested
    }

    private func parseMessageLine(_ json: [String: Any], seenToolIds: inout Set<String>, seenAssistantMessageIds: inout Set<String>, toolIdToName: inout [String: String]) -> ChatMessage? {
        
        var roleStr: String?
        var content: String?
        let parsedMsgId = (json["id"] as? String) ?? UUID().uuidString
        
        if let messageOuter = json["message"] as? [String: Any],
           let innerMsg = messageOuter["message"] as? [String: Any] {
            // Claude Code format
            if (innerMsg["extra"] as? [String: Any])?["is_additional_context_input"] as? Bool != true {
                roleStr = innerMsg["role"] as? String
                content = innerMsg["content"] as? String
            }
        } else if let type = json["type"] as? String, (type == "user" || type == "assistant"),
                  let msg = json["message"] as? [String: Any] {
            // Coco format message
            if (msg["extra"] as? [String: Any])?["is_additional_context_input"] as? Bool != true {
                roleStr = msg["role"] as? String
                content = msg["content"] as? String
            }
        } else if let userPromptSubmit = json["user_prompt_submit"] as? [String: Any],
                  let prompt = userPromptSubmit["prompt"] as? String {
            // Coco format user prompt
            roleStr = "user"
            content = prompt
        } else if let agentStart = json["agent_start"] as? [String: Any],
                  let input = agentStart["input"] as? [[String: Any]],
                  let firstUser = input.first(where: { 
                      ($0["role"] as? String) == "user" && 
                      ($0["extra"] as? [String: Any])?["is_original_user_input"] as? Bool != false && 
                      ($0["extra"] as? [String: Any])?["is_additional_context_input"] as? Bool != true 
                  }) {
            // Coco format agent start
            roleStr = "user"
            content = firstUser["content"] as? String
        }
        
        if let roleStr = roleStr,
           let content = content,
           !content.hasPrefix("<system-reminder>") {
            
            // Prevent exact duplicates of user messages from inner messages
            if roleStr == "user" && seenToolIds.contains("msg-\(parsedMsgId)") {
                return nil
            }
            if roleStr == "user" {
                seenToolIds.insert("msg-\(parsedMsgId)")
            }
            
            // Prevent duplicates of assistant messages 
            // Often Coco sends multiple messages with the same ID or identical content
            if roleStr == "assistant" {
                let dedupId = "msg-\(parsedMsgId)"
                if seenAssistantMessageIds.contains(dedupId) {
                    return nil
                }
                seenAssistantMessageIds.insert(dedupId)
            }
            
            let timestampStr = (json["created_at"] as? String) ?? (json["timestamp"] as? String)
            let timestamp = timestampStr.flatMap { isoFormatter.date(from: $0) } ?? Date()
            let role: ChatRole = roleStr == "user" ? .user : .assistant
            
            return ChatMessage(
                id: parsedMsgId,
                role: role,
                timestamp: timestamp,
                content: [.text(content)]
            )
        }
        
        // Also support Coco agent_end for final summary or error
        if let agentEnd = json["agent_end"] as? [String: Any] {
            let msgId = (json["id"] as? String) ?? UUID().uuidString
            let timestampStr = json["created_at"] as? String
            let timestamp = timestampStr.flatMap { isoFormatter.date(from: $0) } ?? Date()
            
            if let output = agentEnd["output"] as? [String: Any],
               let roleStr = output["role"] as? String,
               let content = output["content"] as? String {
                
                // Prevent duplicates of assistant messages 
                if roleStr == "assistant" {
                    let dedupId = "msg-\(msgId)"
                    if seenAssistantMessageIds.contains(dedupId) {
                        return nil
                    }
                    seenAssistantMessageIds.insert(dedupId)
                }
                
                let role: ChatRole = roleStr == "user" ? .user : .assistant
                
                return ChatMessage(
                    id: msgId,
                    role: role,
                    timestamp: timestamp,
                    content: [.text(content)]
                )
            } else if let errorMessage = agentEnd["error_message"] as? String {
                // Handle error message case in agent_end
                let dedupId = "msg-\(msgId)"
                if seenAssistantMessageIds.contains(dedupId) {
                    return nil
                }
                seenAssistantMessageIds.insert(dedupId)
                
                return ChatMessage(
                    id: msgId,
                    role: .assistant,
                    timestamp: timestamp,
                    content: [.text("⚠️ \(errorMessage)")]
                )
            }
        }
        
        guard let type = json["type"] as? String,
              json["uuid"] != nil else {
            // Coco format fallback
            if let toolCallOuter = json["tool_call"] as? [String: Any],
               let toolCallId = toolCallOuter["tool_call_id"] as? String,
               let toolInfo = toolCallOuter["tool_info"] as? [String: Any],
               let toolName = toolInfo["name"] as? String {
                
                var inputDict: [String: String] = [:]
                if let input = toolCallOuter["input"] as? [String: Any],
                   let structuredInput = input["structured_input"] as? [String: Any] {
                    for (key, value) in structuredInput {
                        if let strValue = value as? String {
                            inputDict[key] = strValue
                        } else if let intValue = value as? Int {
                            inputDict[key] = String(intValue)
                        } else if let boolValue = value as? Bool {
                            inputDict[key] = boolValue ? "true" : "false"
                        } else {
                            inputDict[key] = String(describing: value)
                        }
                    }
                }
                
                seenToolIds.insert(toolCallId)
                toolIdToName[toolCallId] = toolName
                
                let timestampStr = json["created_at"] as? String
                let timestamp = timestampStr.flatMap { isoFormatter.date(from: $0) } ?? Date()
                
                let toolBlock = ToolUseBlock(
                    id: toolCallId,
                    name: toolName,
                    input: inputDict
                )
                
                return ChatMessage(
                    id: (json["id"] as? String) ?? UUID().uuidString,
                    role: .assistant,
                    timestamp: timestamp,
                    content: [.toolUse(toolBlock)]
                )
            }
            
            // Also check tool_call_output for tools since newer formats might only have this
            if let toolCallOuter = json["tool_call_output"] as? [String: Any],
               let toolCallId = toolCallOuter["tool_call_id"] as? String,
               let toolInfo = toolCallOuter["tool_info"] as? [String: Any],
               let toolName = toolInfo["name"] as? String {
                
                // Only create the tool call if we haven't seen it yet
                if !seenToolIds.contains(toolCallId) {
                    var inputDict: [String: String] = [:]
                    if let input = toolCallOuter["input"] as? [String: Any],
                       let structuredInput = input["structured_input"] as? [String: Any] {
                        for (key, value) in structuredInput {
                            if let strValue = value as? String {
                                inputDict[key] = strValue
                            } else if let intValue = value as? Int {
                                inputDict[key] = String(intValue)
                            } else if let boolValue = value as? Bool {
                                inputDict[key] = boolValue ? "true" : "false"
                            } else {
                                inputDict[key] = String(describing: value)
                            }
                        }
                    }
                    
                    seenToolIds.insert(toolCallId)
                    toolIdToName[toolCallId] = toolName
                    
                    let timestampStr = json["created_at"] as? String
                    let timestamp = timestampStr.flatMap { isoFormatter.date(from: $0) } ?? Date()
                    
                    let toolBlock = ToolUseBlock(
                        id: toolCallId,
                        name: toolName,
                        input: inputDict
                    )
                    
                    return ChatMessage(
                        id: (json["id"] as? String) ?? UUID().uuidString,
                        role: .assistant,
                        timestamp: timestamp,
                        content: [.toolUse(toolBlock)]
                    )
                }
            }
            return nil
        }

        guard type == "user" || type == "assistant" else {
            return nil
        }

        if json["isMeta"] as? Bool == true {
            return nil
        }

        guard let messageDict = json["message"] as? [String: Any] else {
            return nil
        }
        
        let msgId = (json["uuid"] as? String) ?? (json["id"] as? String) ?? UUID().uuidString
        
        if type == "assistant" {
            let dedupId = "msg-\(msgId)"
            if seenAssistantMessageIds.contains(dedupId) {
                return nil
            }
            seenAssistantMessageIds.insert(dedupId)
        }

        let timestamp: Date
        if let timestampStr = json["timestamp"] as? String {
            timestamp = isoFormatter.date(from: timestampStr) ?? Date()
        } else {
            timestamp = Date()
        }

        var blocks: [MessageBlock] = []

        if let content = messageDict["content"] as? String {
            if content.hasPrefix("<command-name>") || content.hasPrefix("<local-command") || content.hasPrefix("Caveat:") {
                return nil
            }
            if content.hasPrefix("[Request interrupted by user") {
                blocks.append(.interrupted)
            } else {
                blocks.append(.text(content))
            }
        } else if let contentArray = messageDict["content"] as? [[String: Any]] {
            for block in contentArray {
                if let blockType = block["type"] as? String {
                    switch blockType {
                    case "text":
                        if let text = block["text"] as? String {
                            if text.hasPrefix("[Request interrupted by user") {
                                blocks.append(.interrupted)
                            } else {
                                blocks.append(.text(text))
                            }
                        }
                    case "tool_use":
                        if let toolId = block["id"] as? String {
                            if seenToolIds.contains(toolId) {
                                continue
                            }
                            seenToolIds.insert(toolId)
                            if let toolName = block["name"] as? String {
                                toolIdToName[toolId] = toolName
                            }
                        }
                        if let toolBlock = parseToolUse(block) {
                            blocks.append(.toolUse(toolBlock))
                        }
                    case "thinking":
                        if let thinking = block["thinking"] as? String {
                            blocks.append(.thinking(thinking))
                        }
                    case "image":
                        // Claude Code stores inline images as base64 with media_type.
                        if let source = block["source"] as? [String: Any],
                           let mediaType = source["media_type"] as? String,
                           let data = source["data"] as? String {
                            blocks.append(.image(ImageBlock(mediaType: mediaType, base64Data: data)))
                        }
                    default:
                        break
                    }
                }
            }
        }

        guard !blocks.isEmpty else { return nil }

        let role: ChatRole = type == "user" ? .user : .assistant

        return ChatMessage(
            id: msgId,
            role: role,
            timestamp: timestamp,
            content: blocks
        )
    }

    private func parseToolUse(_ block: [String: Any]) -> ToolUseBlock? {
        guard let id = block["id"] as? String,
              let name = block["name"] as? String else {
            return nil
        }

        var input: [String: String] = [:]
        if let inputDict = block["input"] as? [String: Any] {
            for (key, value) in inputDict {
                if let strValue = value as? String {
                    input[key] = strValue
                } else if let intValue = value as? Int {
                    input[key] = String(intValue)
                } else if let boolValue = value as? Bool {
                    input[key] = boolValue ? "true" : "false"
                }
            }
        }

        return ToolUseBlock(id: id, name: name, input: input)
    }

    // MARK: - Structured Result Parsing

    /// Parse tool result JSON into structured ToolResultData
    private static func parseStructuredResult(
        toolName: String,
        toolUseResult: [String: Any],
        isError: Bool
    ) -> ToolResultData {
        if toolName.hasPrefix("mcp__") {
            let parts = String(toolName.dropFirst(5)).components(separatedBy: "__")
            let serverName = parts.first.flatMap { $0.isEmpty ? nil : $0 } ?? "unknown"
            let mcpToolName = parts.dropFirst().joined(separator: "__")
            return .mcp(MCPResult(
                serverName: serverName,
                toolName: mcpToolName.isEmpty ? toolName : mcpToolName,
                rawResult: toolUseResult
            ))
        }

        switch toolName {
        case "Read":
            return parseReadResult(toolUseResult)
        case "Edit":
            return parseEditResult(toolUseResult)
        case "Write":
            return parseWriteResult(toolUseResult)
        case "Bash":
            return parseBashResult(toolUseResult)
        case "Grep":
            return parseGrepResult(toolUseResult)
        case "Glob":
            return parseGlobResult(toolUseResult)
        case "TodoWrite":
            return parseTodoWriteResult(toolUseResult)
        case "Task", "Agent":
            return parseTaskResult(toolUseResult)
        case "WebFetch":
            return parseWebFetchResult(toolUseResult)
        case "WebSearch":
            return parseWebSearchResult(toolUseResult)
        case "AskUserQuestion":
            return parseAskUserQuestionResult(toolUseResult)
        case "BashOutput":
            return parseBashOutputResult(toolUseResult)
        case "KillShell":
            return parseKillShellResult(toolUseResult)
        case "ExitPlanMode":
            return parseExitPlanModeResult(toolUseResult)
        default:
            let content = toolUseResult["content"] as? String ??
                          toolUseResult["stdout"] as? String ??
                          toolUseResult["result"] as? String
            return .generic(GenericResult(rawContent: content, rawData: toolUseResult))
        }
    }

    // MARK: - Individual Tool Result Parsers

    private static func parseReadResult(_ data: [String: Any]) -> ToolResultData {
        if let fileData = data["file"] as? [String: Any] {
            return .read(ReadResult(
                filePath: fileData["filePath"] as? String ?? "",
                content: fileData["content"] as? String ?? "",
                numLines: fileData["numLines"] as? Int ?? 0,
                startLine: fileData["startLine"] as? Int ?? 1,
                totalLines: fileData["totalLines"] as? Int ?? 0
            ))
        }
        return .read(ReadResult(
            filePath: data["filePath"] as? String ?? "",
            content: data["content"] as? String ?? "",
            numLines: data["numLines"] as? Int ?? 0,
            startLine: data["startLine"] as? Int ?? 1,
            totalLines: data["totalLines"] as? Int ?? 0
        ))
    }

    private static func parseEditResult(_ data: [String: Any]) -> ToolResultData {
        var patches: [PatchHunk]? = nil
        if let patchArray = data["structuredPatch"] as? [[String: Any]] {
            patches = patchArray.compactMap { patch -> PatchHunk? in
                guard let oldStart = patch["oldStart"] as? Int,
                      let oldLines = patch["oldLines"] as? Int,
                      let newStart = patch["newStart"] as? Int,
                      let newLines = patch["newLines"] as? Int,
                      let lines = patch["lines"] as? [String] else {
                    return nil
                }
                return PatchHunk(
                    oldStart: oldStart,
                    oldLines: oldLines,
                    newStart: newStart,
                    newLines: newLines,
                    lines: lines
                )
            }
        }

        return .edit(EditResult(
            filePath: data["filePath"] as? String ?? "",
            oldString: data["oldString"] as? String ?? "",
            newString: data["newString"] as? String ?? "",
            replaceAll: data["replaceAll"] as? Bool ?? false,
            userModified: data["userModified"] as? Bool ?? false,
            structuredPatch: patches
        ))
    }

    private static func parseWriteResult(_ data: [String: Any]) -> ToolResultData {
        let typeStr = data["type"] as? String ?? "create"
        let writeType: WriteResult.WriteType = typeStr == "overwrite" ? .overwrite : .create

        var patches: [PatchHunk]? = nil
        if let patchArray = data["structuredPatch"] as? [[String: Any]] {
            patches = patchArray.compactMap { patch -> PatchHunk? in
                guard let oldStart = patch["oldStart"] as? Int,
                      let oldLines = patch["oldLines"] as? Int,
                      let newStart = patch["newStart"] as? Int,
                      let newLines = patch["newLines"] as? Int,
                      let lines = patch["lines"] as? [String] else {
                    return nil
                }
                return PatchHunk(
                    oldStart: oldStart,
                    oldLines: oldLines,
                    newStart: newStart,
                    newLines: newLines,
                    lines: lines
                )
            }
        }

        return .write(WriteResult(
            type: writeType,
            filePath: data["filePath"] as? String ?? "",
            content: data["content"] as? String ?? "",
            structuredPatch: patches
        ))
    }

    private static func parseBashResult(_ data: [String: Any]) -> ToolResultData {
        return .bash(BashResult(
            stdout: data["stdout"] as? String ?? "",
            stderr: data["stderr"] as? String ?? "",
            interrupted: data["interrupted"] as? Bool ?? false,
            isImage: data["isImage"] as? Bool ?? false,
            returnCodeInterpretation: data["returnCodeInterpretation"] as? String,
            backgroundTaskId: data["backgroundTaskId"] as? String
        ))
    }

    private static func parseGrepResult(_ data: [String: Any]) -> ToolResultData {
        let modeStr = data["mode"] as? String ?? "files_with_matches"
        let mode: GrepResult.Mode
        switch modeStr {
        case "content": mode = .content
        case "count": mode = .count
        default: mode = .filesWithMatches
        }

        return .grep(GrepResult(
            mode: mode,
            filenames: data["filenames"] as? [String] ?? [],
            numFiles: data["numFiles"] as? Int ?? 0,
            content: data["content"] as? String,
            numLines: data["numLines"] as? Int,
            appliedLimit: data["appliedLimit"] as? Int
        ))
    }

    private static func parseGlobResult(_ data: [String: Any]) -> ToolResultData {
        return .glob(GlobResult(
            filenames: data["filenames"] as? [String] ?? [],
            durationMs: data["durationMs"] as? Int ?? 0,
            numFiles: data["numFiles"] as? Int ?? 0,
            truncated: data["truncated"] as? Bool ?? false
        ))
    }

    private static func parseTodoWriteResult(_ data: [String: Any]) -> ToolResultData {
        func parseTodos(_ array: [[String: Any]]?) -> [TodoItem] {
            guard let array = array else { return [] }
            return array.compactMap { item -> TodoItem? in
                guard let content = item["content"] as? String,
                      let status = item["status"] as? String else {
                    return nil
                }
                return TodoItem(
                    content: content,
                    status: status,
                    activeForm: item["activeForm"] as? String
                )
            }
        }

        return .todoWrite(TodoWriteResult(
            oldTodos: parseTodos(data["oldTodos"] as? [[String: Any]]),
            newTodos: parseTodos(data["newTodos"] as? [[String: Any]])
        ))
    }

    private static func parseTaskResult(_ data: [String: Any]) -> ToolResultData {
        return .task(TaskResult(
            agentId: data["agentId"] as? String ?? "",
            status: data["status"] as? String ?? "unknown",
            content: data["content"] as? String ?? "",
            prompt: data["prompt"] as? String,
            totalDurationMs: data["totalDurationMs"] as? Int,
            totalTokens: data["totalTokens"] as? Int,
            totalToolUseCount: data["totalToolUseCount"] as? Int
        ))
    }

    private static func parseWebFetchResult(_ data: [String: Any]) -> ToolResultData {
        return .webFetch(WebFetchResult(
            url: data["url"] as? String ?? "",
            code: data["code"] as? Int ?? 0,
            codeText: data["codeText"] as? String ?? "",
            bytes: data["bytes"] as? Int ?? 0,
            durationMs: data["durationMs"] as? Int ?? 0,
            result: data["result"] as? String ?? ""
        ))
    }

    private static func parseWebSearchResult(_ data: [String: Any]) -> ToolResultData {
        var results: [SearchResultItem] = []
        if let resultsArray = data["results"] as? [[String: Any]] {
            results = resultsArray.compactMap { item -> SearchResultItem? in
                guard let title = item["title"] as? String,
                      let url = item["url"] as? String else {
                    return nil
                }
                return SearchResultItem(
                    title: title,
                    url: url,
                    snippet: item["snippet"] as? String ?? ""
                )
            }
        }

        return .webSearch(WebSearchResult(
            query: data["query"] as? String ?? "",
            durationSeconds: data["durationSeconds"] as? Double ?? 0,
            results: results
        ))
    }

    private static func parseAskUserQuestionResult(_ data: [String: Any]) -> ToolResultData {
        var questions: [QuestionItem] = []
        if let questionsArray = data["questions"] as? [[String: Any]] {
            questions = questionsArray.compactMap { q -> QuestionItem? in
                guard let question = q["question"] as? String else { return nil }
                var options: [QuestionOption] = []
                if let optionsArray = q["options"] as? [[String: Any]] {
                    options = optionsArray.compactMap { opt -> QuestionOption? in
                        guard let label = opt["label"] as? String else { return nil }
                        return QuestionOption(
                            label: label,
                            description: opt["description"] as? String
                        )
                    }
                }
                return QuestionItem(
                    question: question,
                    header: q["header"] as? String,
                    options: options
                )
            }
        }

        var answers: [String: String] = [:]
        if let answersDict = data["answers"] as? [String: String] {
            answers = answersDict
        }

        return .askUserQuestion(AskUserQuestionResult(
            questions: questions,
            answers: answers
        ))
    }

    private static func parseBashOutputResult(_ data: [String: Any]) -> ToolResultData {
        return .bashOutput(BashOutputResult(
            shellId: data["shellId"] as? String ?? "",
            status: data["status"] as? String ?? "",
            stdout: data["stdout"] as? String ?? "",
            stderr: data["stderr"] as? String ?? "",
            stdoutLines: data["stdoutLines"] as? Int ?? 0,
            stderrLines: data["stderrLines"] as? Int ?? 0,
            exitCode: data["exitCode"] as? Int,
            command: data["command"] as? String,
            timestamp: data["timestamp"] as? String
        ))
    }

    private static func parseKillShellResult(_ data: [String: Any]) -> ToolResultData {
        return .killShell(KillShellResult(
            shellId: data["shell_id"] as? String ?? data["shellId"] as? String ?? "",
            message: data["message"] as? String ?? ""
        ))
    }

    private static func parseExitPlanModeResult(_ data: [String: Any]) -> ToolResultData {
        return .exitPlanMode(ExitPlanModeResult(
            filePath: data["filePath"] as? String,
            plan: data["plan"] as? String,
            isAgent: data["isAgent"] as? Bool ?? false
        ))
    }

    // MARK: - Subagent Tools Parsing

    /// Parse subagent tools from an agent JSONL file
    func parseSubagentTools(sessionId: String, agentId: String, cwd: String) -> [SubagentToolInfo] {
        guard !agentId.isEmpty else { return [] }

        let projectDir = cwd.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ".", with: "-")
        let agentFile = Self.subagentFilePath(sessionId: sessionId, agentId: agentId, projectDir: projectDir)

        guard FileManager.default.fileExists(atPath: agentFile),
              let content = try? String(contentsOfFile: agentFile, encoding: .utf8) else {
            return []
        }

        var tools: [SubagentToolInfo] = []
        var seenToolIds: Set<String> = []
        var completedToolIds: Set<String> = []

        for line in content.components(separatedBy: "\n") where !line.isEmpty {
            if line.contains("\"tool_result\""),
               let lineData = line.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
               let messageDict = json["message"] as? [String: Any],
               let contentArray = messageDict["content"] as? [[String: Any]] {
                for block in contentArray {
                    if block["type"] as? String == "tool_result",
                       let toolUseId = block["tool_use_id"] as? String {
                        completedToolIds.insert(toolUseId)
                    }
                }
            }
        }

        for line in content.components(separatedBy: "\n") where !line.isEmpty {
            guard line.contains("\"tool_use\""),
                  let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let messageDict = json["message"] as? [String: Any],
                  let contentArray = messageDict["content"] as? [[String: Any]] else {
                continue
            }

            for block in contentArray {
                guard block["type"] as? String == "tool_use",
                      let toolId = block["id"] as? String,
                      let toolName = block["name"] as? String,
                      !seenToolIds.contains(toolId) else {
                    continue
                }

                seenToolIds.insert(toolId)

                var input: [String: String] = [:]
                if let inputDict = block["input"] as? [String: Any] {
                    for (key, value) in inputDict {
                        if let strValue = value as? String {
                            input[key] = strValue
                        } else if let intValue = value as? Int {
                            input[key] = String(intValue)
                        } else if let boolValue = value as? Bool {
                            input[key] = boolValue ? "true" : "false"
                        }
                    }
                }

                let isCompleted = completedToolIds.contains(toolId)
                let timestamp = json["timestamp"] as? String

                tools.append(SubagentToolInfo(
                    id: toolId,
                    name: toolName,
                    input: input,
                    isCompleted: isCompleted,
                    timestamp: timestamp
                ))
            }
        }

        return tools
    }
}

/// Info about a subagent tool call parsed from JSONL
struct SubagentToolInfo: Sendable {
    let id: String
    let name: String
    let input: [String: String]
    let isCompleted: Bool
    let timestamp: String?
}

// MARK: - Static Subagent Tools Parsing

extension ConversationParser {
    /// Parse subagent tools from an agent JSONL file (static, synchronous version)
    nonisolated static func parseSubagentToolsSync(sessionId: String, agentId: String, cwd: String) -> [SubagentToolInfo] {
        guard !agentId.isEmpty else { return [] }

        let projectDir = cwd.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ".", with: "-")
        let agentFile = subagentFilePath(sessionId: sessionId, agentId: agentId, projectDir: projectDir)

        guard FileManager.default.fileExists(atPath: agentFile),
              let content = try? String(contentsOfFile: agentFile, encoding: .utf8) else {
            return []
        }

        var tools: [SubagentToolInfo] = []
        var seenToolIds: Set<String> = []
        var completedToolIds: Set<String> = []

        for line in content.components(separatedBy: "\n") where !line.isEmpty {
            if line.contains("\"tool_result\""),
               let lineData = line.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
               let messageDict = json["message"] as? [String: Any],
               let contentArray = messageDict["content"] as? [[String: Any]] {
                for block in contentArray {
                    if block["type"] as? String == "tool_result",
                       let toolUseId = block["tool_use_id"] as? String {
                        completedToolIds.insert(toolUseId)
                    }
                }
            }
        }

        for line in content.components(separatedBy: "\n") where !line.isEmpty {
            guard line.contains("\"tool_use\""),
                  let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let messageDict = json["message"] as? [String: Any],
                  let contentArray = messageDict["content"] as? [[String: Any]] else {
                continue
            }

            for block in contentArray {
                guard block["type"] as? String == "tool_use",
                      let toolId = block["id"] as? String,
                      let toolName = block["name"] as? String,
                      !seenToolIds.contains(toolId) else {
                    continue
                }

                seenToolIds.insert(toolId)

                var input: [String: String] = [:]
                if let inputDict = block["input"] as? [String: Any] {
                    for (key, value) in inputDict {
                        if let strValue = value as? String {
                            input[key] = strValue
                        } else if let intValue = value as? Int {
                            input[key] = String(intValue)
                        } else if let boolValue = value as? Bool {
                            input[key] = boolValue ? "true" : "false"
                        }
                    }
                }

                let isCompleted = completedToolIds.contains(toolId)
                let timestamp = json["timestamp"] as? String

                tools.append(SubagentToolInfo(
                    id: toolId,
                    name: toolName,
                    input: input,
                    isCompleted: isCompleted,
                    timestamp: timestamp
                ))
            }
        }

        return tools
    }
}
