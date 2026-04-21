//
//  HookSocketServer.swift
//  ClaudeIsland
//
//  Unix domain socket server for real-time hook events
//  Supports request/response for permission decisions
//

import Foundation
import os.log

/// Logger for hook socket server
private let logger = Logger(subsystem: "com.codingisland", category: "Hooks")

/// Event received from Claude Code or Coco hooks
struct HookEvent: Codable, Sendable {
    let providerId: String  // "claude-code" or "coco"
    let sessionId: String
    let cwd: String
    let event: String
    let status: String
    let pid: Int?
    let tty: String?
    let tool: String?
    let toolInput: [String: AnyCodable]?
    let toolUseId: String?
    let notificationType: String?
    let message: String?

    // Coco-specific fields
    let transcriptPath: String?
    let agentId: String?
    let agentType: String?

    /// Raw JSONL lines from the remote transcript, attached by the remote hook script.
    /// Only present for remote (TCP) events when new lines have been written since the last event.
    let remoteJsonlLines: [String]?

    /// Path resolution debug info from the remote hook script (for diagnosing missing JSONL).
    let remotePathDebug: [String]?

    /// Whether the hook uses dual-approval mode (short timeout, CLI shows its own UI)
    let dualApprovalMode: Bool?

    enum CodingKeys: String, CodingKey {
        case providerId = "provider_id"
        case sessionId = "session_id"
        case cwd, event, status, pid, tty, tool
        case toolInput = "tool_input"
        case toolUseId = "tool_use_id"
        case notificationType = "notification_type"
        case message
        case transcriptPath = "transcript_path"
        case agentId = "agent_id"
        case agentType = "agent_type"
        case remoteJsonlLines = "remote_jsonl_lines"
        case remotePathDebug = "remote_path_debug"
        case dualApprovalMode = "dual_approval_mode"
    }

    /// Create a copy with updated toolUseId
    init(
        providerId: String = "claude-code",
        sessionId: String,
        cwd: String,
        event: String,
        status: String,
        pid: Int?,
        tty: String?,
        tool: String?,
        toolInput: [String: AnyCodable]?,
        toolUseId: String?,
        notificationType: String?,
        message: String?,
        transcriptPath: String? = nil,
        agentId: String? = nil,
        agentType: String? = nil,
        remoteJsonlLines: [String]? = nil,
        remotePathDebug: [String]? = nil,
        dualApprovalMode: Bool? = nil
    ) {
        self.providerId = providerId
        self.sessionId = sessionId
        self.cwd = cwd
        self.event = event
        self.status = status
        self.pid = pid
        self.tty = tty
        self.tool = tool
        self.toolInput = toolInput
        self.toolUseId = toolUseId
        self.notificationType = notificationType
        self.message = message
        self.transcriptPath = transcriptPath
        self.agentId = agentId
        self.agentType = agentType
        self.remoteJsonlLines = remoteJsonlLines
        self.remotePathDebug = remotePathDebug
        self.dualApprovalMode = dualApprovalMode
    }

    var sessionPhase: SessionPhase {
        // Support both Claude Code (PreCompact) and Coco (pre_compact) event names
        let normalizedEvent = event.lowercased().replacingOccurrences(of: "_", with: "")
        if normalizedEvent == "precompact" {
            return .compacting
        }

        switch status {
        case "waiting_for_approval":
            // Note: Full PermissionContext is constructed by SessionStore, not here
            // This is just for quick phase checks
            return .waitingForApproval(PermissionContext(
                toolUseId: toolUseId ?? "",
                toolName: tool ?? "unknown",
                toolInput: toolInput,
                receivedAt: Date()
            ))
        case "waiting_for_input":
            return .waitingForInput
        case "running_tool", "processing", "starting":
            return .processing
        case "compacting":
            return .compacting
        default:
            return .idle
        }
    }

    /// Whether this event expects a response (permission request)
    /// Supports both Claude Code (PermissionRequest) and Coco (permission_request) formats
    nonisolated var expectsResponse: Bool {
        let normalizedEvent = event.lowercased().replacingOccurrences(of: "_", with: "")
        return normalizedEvent == "permissionrequest" && status == "waiting_for_approval"
    }
}

/// Response to send back to the hook
struct HookResponse: Codable {
    let decision: String // "allow", "deny", or "ask"
    let reason: String?
}

/// Pending permission request waiting for user decision
struct PendingPermission: Sendable {
    let providerId: String
    let sessionId: String
    let toolUseId: String
    let clientSocket: Int32
    let event: HookEvent
    let receivedAt: Date
    let dualApprovalMode: Bool
}

/// Callback for hook events
typealias HookEventHandler = @Sendable (HookEvent) -> Void

/// Callback for permission response failures (socket died)
typealias PermissionFailureHandler = @Sendable (_ sessionId: String, _ toolUseId: String) -> Void

/// Unix domain socket server that receives events from Claude Code hooks
/// Uses GCD DispatchSource for non-blocking I/O
/// Supports both Unix socket and TCP (for SSH tunnel support)
class HookSocketServer {
    static let shared = HookSocketServer()
    static let socketPath = IslandPaths.socketPath
    static let tcpPort: UInt16 = 19999  // TCP port for SSH tunnel support

    private var serverSocket: Int32 = -1
    private var tcpServerSocket: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var tcpAcceptSource: DispatchSourceRead?
    private var eventHandler: HookEventHandler?
    private var permissionFailureHandler: PermissionFailureHandler?
    private let queue = DispatchQueue(label: "com.codingisland.socket", qos: .userInitiated)

    /// Pending permission requests indexed by toolUseId
    private var pendingPermissions: [String: PendingPermission] = [:]
    private let permissionsLock = NSLock()

    /// Dispatch sources to detect when hooks close their sockets (after dual-approval timeout)
    private var socketMonitors: [String: DispatchSourceRead] = [:]

    /// Cache tool_use_id from PreToolUse to correlate with PermissionRequest
    /// Key: "sessionId:toolName:serializedInput" -> Queue of tool_use_ids (FIFO)
    /// PermissionRequest events don't include tool_use_id, so we cache from PreToolUse
    private var toolUseIdCache: [String: [String]] = [:]
    private let cacheLock = NSLock()

    private init() {}

    /// Start the socket server (Unix socket + TCP)
    func start(onEvent: @escaping HookEventHandler, onPermissionFailure: PermissionFailureHandler? = nil) {
        queue.async { [weak self] in
            self?.startServer(onEvent: onEvent, onPermissionFailure: onPermissionFailure)
        }
    }

    private func startServer(onEvent: @escaping HookEventHandler, onPermissionFailure: PermissionFailureHandler?) {
        guard serverSocket < 0 else { return }


        eventHandler = onEvent
        permissionFailureHandler = onPermissionFailure

        // Ensure the directory exists before binding
        IslandPaths.ensureDirectoriesExist()

        unlink(Self.socketPath)

        serverSocket = socket(AF_UNIX, SOCK_STREAM, 0)
        guard serverSocket >= 0 else {
            logger.error("Failed to create socket: \(errno)")
            return
        }

        let flags = fcntl(serverSocket, F_GETFL)
        _ = fcntl(serverSocket, F_SETFL, flags | O_NONBLOCK)

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        Self.socketPath.withCString { ptr in
            withUnsafeMutablePointer(to: &addr.sun_path) { pathPtr in
                let pathBufferPtr = UnsafeMutableRawPointer(pathPtr)
                    .assumingMemoryBound(to: CChar.self)
                strcpy(pathBufferPtr, ptr)
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                bind(serverSocket, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        guard bindResult == 0 else {
            logger.error("Failed to bind socket: \(errno)")
            close(serverSocket)
            serverSocket = -1
            return
        }

        chmod(Self.socketPath, 0o600)

        guard listen(serverSocket, 10) == 0 else {
            logger.error("Failed to listen: \(errno)")
            close(serverSocket)
            serverSocket = -1
            return
        }

        logger.info("Listening on \(Self.socketPath, privacy: .public)")

        acceptSource = DispatchSource.makeReadSource(fileDescriptor: serverSocket, queue: queue)
        acceptSource?.setEventHandler { [weak self] in
            self?.acceptConnection()
        }
        acceptSource?.setCancelHandler { [weak self] in
            if let fd = self?.serverSocket, fd >= 0 {
                close(fd)
                self?.serverSocket = -1
            }
        }
        acceptSource?.resume()

        // Also start TCP server for SSH tunnel support
        startTCPServer()
    }

    /// Start TCP socket server for SSH tunnel connections
    private func startTCPServer() {
        guard tcpServerSocket < 0 else { return }

        tcpServerSocket = socket(AF_INET, SOCK_STREAM, 0)
        guard tcpServerSocket >= 0 else {
            logger.error("Failed to create TCP socket: \(errno)")
            return
        }

        let flags = fcntl(tcpServerSocket, F_GETFL)
        _ = fcntl(tcpServerSocket, F_SETFL, flags | O_NONBLOCK)

        var opt: Int32 = 1
        setsockopt(tcpServerSocket, SOL_SOCKET, SO_REUSEADDR, &opt, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = Self.tcpPort.bigEndian
        addr.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.bind(tcpServerSocket, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        guard bindResult == 0 else {
            logger.error("Failed to bind TCP socket: \(errno)")
            close(tcpServerSocket)
            tcpServerSocket = -1
            return
        }

        guard listen(tcpServerSocket, 10) == 0 else {
            logger.error("Failed to listen on TCP: \(errno)")
            close(tcpServerSocket)
            tcpServerSocket = -1
            return
        }

        logger.info("TCP server listening on port \(Self.tcpPort, privacy: .public) (for SSH tunnels)")

        tcpAcceptSource = DispatchSource.makeReadSource(fileDescriptor: tcpServerSocket, queue: queue)
        tcpAcceptSource?.setEventHandler { [weak self] in
            self?.acceptTCPConnection()
        }
        tcpAcceptSource?.setCancelHandler { [weak self] in
            if let fd = self?.tcpServerSocket, fd >= 0 {
                close(fd)
                self?.tcpServerSocket = -1
            }
        }
        tcpAcceptSource?.resume()
    }

    /// Accept a TCP connection (from SSH tunnel)
    private func acceptTCPConnection() {
        var addr = sockaddr_in()
        var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        let clientSocket = withUnsafeMutablePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.accept(tcpServerSocket, sockaddrPtr, &addrLen)
            }
        }

        guard clientSocket >= 0 else { return }

        var nosigpipe: Int32 = 1
        setsockopt(clientSocket, SOL_SOCKET, SO_NOSIGPIPE, &nosigpipe, socklen_t(MemoryLayout<Int32>.size))

        logger.debug("Accepted TCP connection (SSH tunnel)")
        handleClient(clientSocket, isRemote: true)
    }

    /// Stop the socket server
    func stop() {
        acceptSource?.cancel()
        acceptSource = nil
        unlink(Self.socketPath)

        tcpAcceptSource?.cancel()
        tcpAcceptSource = nil

        for (_, monitor) in socketMonitors {
            monitor.cancel()
        }
        socketMonitors.removeAll()

        permissionsLock.lock()
        for (_, pending) in pendingPermissions {
            close(pending.clientSocket)
        }
        pendingPermissions.removeAll()
        permissionsLock.unlock()
    }

    /// Respond to a pending permission request by toolUseId
    /// Returns true if the socket response was sent successfully, false if socket was already closed
    @discardableResult
    func respondToPermission(toolUseId: String, decision: String, reason: String? = nil) -> Bool {
        permissionsLock.lock()
        guard let pending = pendingPermissions.removeValue(forKey: toolUseId) else {
            permissionsLock.unlock()
            logger.debug("No pending permission for toolUseId: \(toolUseId.prefix(12), privacy: .public)")
            return false
        }
        permissionsLock.unlock()

        // Cancel the socket monitor if one exists
        socketMonitors[toolUseId]?.cancel()
        socketMonitors.removeValue(forKey: toolUseId)

        let response = HookResponse(decision: decision, reason: reason)
        guard let data = try? JSONEncoder().encode(response) else {
            close(pending.clientSocket)
            return false
        }

        let age = Date().timeIntervalSince(pending.receivedAt)
        logger.info("Sending response: \(decision, privacy: .public) for \(pending.sessionId.prefix(8), privacy: .public) tool:\(toolUseId.prefix(12), privacy: .public) (age: \(String(format: "%.1f", age), privacy: .public)s)")

        var writeOk = false
        data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else {
                logger.error("Failed to get data buffer address")
                return
            }
            let result = write(pending.clientSocket, baseAddress, data.count)
            if result < 0 {
                logger.error("Write failed with errno: \(errno)")
            } else {
                logger.debug("Write succeeded: \(result) bytes")
                writeOk = true
            }
        }

        close(pending.clientSocket)
        return writeOk
    }

    /// Respond to permission by sessionId (finds the most recent pending for that session)
    func respondToPermissionBySession(sessionId: String, decision: String, reason: String? = nil) {
        queue.async { [weak self] in
            self?.sendPermissionResponseBySession(sessionId: sessionId, decision: decision, reason: reason)
        }
    }

    /// Cancel all pending permissions for a session (when Claude stops waiting)
    func cancelPendingPermissions(sessionId: String) {
        queue.async { [weak self] in
            self?.cleanupPendingPermissions(sessionId: sessionId)
        }
    }

    /// Check if there's a pending permission request for a session
    func hasPendingPermission(sessionId: String) -> Bool {
        permissionsLock.lock()
        defer { permissionsLock.unlock() }
        return pendingPermissions.values.contains { $0.sessionId == sessionId }
    }

    /// Get the pending permission details for a session (if any)
    func getPendingPermission(sessionId: String) -> (toolName: String?, toolId: String?, toolInput: [String: AnyCodable]?)? {
        permissionsLock.lock()
        defer { permissionsLock.unlock() }
        guard let pending = pendingPermissions.values.first(where: { $0.sessionId == sessionId }) else {
            return nil
        }
        return (pending.event.tool, pending.toolUseId, pending.event.toolInput)
    }

    /// Cancel a specific pending permission by toolUseId (when tool completes via terminal approval)
    func cancelPendingPermission(toolUseId: String) {
        queue.async { [weak self] in
            self?.cleanupSpecificPermission(toolUseId: toolUseId)
        }
    }

    private func cleanupSpecificPermission(toolUseId: String) {
        permissionsLock.lock()
        guard let pending = pendingPermissions.removeValue(forKey: toolUseId) else {
            permissionsLock.unlock()
            return
        }
        permissionsLock.unlock()

        logger.debug("Tool completed externally, closing socket for \(pending.sessionId.prefix(8), privacy: .public) tool:\(toolUseId.prefix(12), privacy: .public)")
        close(pending.clientSocket)
    }

    /// Clean up a pending permission whose socket was closed by the hook (dual-approval timeout)
    private func cleanupDeadPermission(toolUseId: String) {
        socketMonitors.removeValue(forKey: toolUseId)

        permissionsLock.lock()
        guard let pending = pendingPermissions.removeValue(forKey: toolUseId) else {
            permissionsLock.unlock()
            return
        }
        permissionsLock.unlock()

        logger.debug("Hook socket closed (dual-approval timeout), cleaning up \(pending.sessionId.prefix(8), privacy: .public) tool:\(toolUseId.prefix(12), privacy: .public)")
        close(pending.clientSocket)
    }

    private func cleanupPendingPermissions(sessionId: String) {
        permissionsLock.lock()
        let matching = pendingPermissions.filter { $0.value.sessionId == sessionId }
        for (toolUseId, pending) in matching {
            logger.debug("Cleaning up stale permission for \(sessionId.prefix(8), privacy: .public) tool:\(toolUseId.prefix(12), privacy: .public)")
            close(pending.clientSocket)
            pendingPermissions.removeValue(forKey: toolUseId)
        }
        permissionsLock.unlock()
    }

    // MARK: - Tool Use ID Cache

    /// Encoder with sorted keys for deterministic cache keys
    private static let sortedEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return encoder
    }()

    /// Generate cache key from event properties
    private func cacheKey(sessionId: String, toolName: String?, toolInput: [String: AnyCodable]?) -> String {
        let inputStr: String
        if let input = toolInput,
           let data = try? Self.sortedEncoder.encode(input),
           let str = String(data: data, encoding: .utf8) {
            inputStr = str
        } else {
            inputStr = "{}"
        }
        return "\(sessionId):\(toolName ?? "unknown"):\(inputStr)"
    }

    /// Cache tool_use_id from PreToolUse event (FIFO queue per key)
    private func cacheToolUseId(event: HookEvent) {
        guard let toolUseId = event.toolUseId else { return }

        let key = cacheKey(sessionId: event.sessionId, toolName: event.tool, toolInput: event.toolInput)

        cacheLock.lock()
        if toolUseIdCache[key] == nil {
            toolUseIdCache[key] = []
        }
        toolUseIdCache[key]?.append(toolUseId)
        cacheLock.unlock()

        logger.debug("Cached tool_use_id for \(event.sessionId.prefix(8), privacy: .public) tool:\(event.tool ?? "?", privacy: .public) id:\(toolUseId.prefix(12), privacy: .public)")
    }

    /// Pop and return cached tool_use_id for PermissionRequest (FIFO)
    private func popCachedToolUseId(event: HookEvent) -> String? {
        let key = cacheKey(sessionId: event.sessionId, toolName: event.tool, toolInput: event.toolInput)

        cacheLock.lock()
        defer { cacheLock.unlock() }

        guard var queue = toolUseIdCache[key], !queue.isEmpty else {
            return nil
        }

        let toolUseId = queue.removeFirst()

        if queue.isEmpty {
            toolUseIdCache.removeValue(forKey: key)
        } else {
            toolUseIdCache[key] = queue
        }

        logger.debug("Retrieved cached tool_use_id for \(event.sessionId.prefix(8), privacy: .public) tool:\(event.tool ?? "?", privacy: .public) id:\(toolUseId.prefix(12), privacy: .public)")
        return toolUseId
    }

    /// Clean up cache entries for a session (on session end)
    private func cleanupCache(sessionId: String) {
        cacheLock.lock()
        let keysToRemove = toolUseIdCache.keys.filter { $0.hasPrefix("\(sessionId):") }
        for key in keysToRemove {
            toolUseIdCache.removeValue(forKey: key)
        }
        cacheLock.unlock()

        if !keysToRemove.isEmpty {
            logger.debug("Cleaned up \(keysToRemove.count) cache entries for session \(sessionId.prefix(8), privacy: .public)")
        }
    }

    // MARK: - Private

    private func acceptConnection() {
        let clientSocket = accept(serverSocket, nil, nil)
        guard clientSocket >= 0 else { return }

        var nosigpipe: Int32 = 1
        setsockopt(clientSocket, SOL_SOCKET, SO_NOSIGPIPE, &nosigpipe, socklen_t(MemoryLayout<Int32>.size))

        handleClient(clientSocket, isRemote: false)
    }

    /// Read and process a single hook event.
    ///
    /// Note: TCP connections are used for SSH tunnels, so their `pid`/`tty` refer to the
    /// remote machine. We intentionally drop `pid` for these events so SessionStore's
    /// local process-liveness checks don't immediately evict the session.
    private func handleClient(_ clientSocket: Int32, isRemote: Bool) {
        let flags = fcntl(clientSocket, F_GETFL)
        _ = fcntl(clientSocket, F_SETFL, flags | O_NONBLOCK)

        var allData = Data()
        var buffer = [UInt8](repeating: 0, count: 131072)
        var pollFd = pollfd(fd: clientSocket, events: Int16(POLLIN), revents: 0)

        let startTime = Date()
        while Date().timeIntervalSince(startTime) < 5.0 {
            let pollResult = poll(&pollFd, 1, 50)

            if pollResult > 0 && (pollFd.revents & Int16(POLLIN)) != 0 {
                let bytesRead = read(clientSocket, &buffer, buffer.count)

                if bytesRead > 0 {
                    allData.append(contentsOf: buffer[0..<bytesRead])
                } else if bytesRead == 0 {
                    // EOF — sender closed connection, all data received
                    break
                } else if errno != EAGAIN && errno != EWOULDBLOCK {
                    break
                }
            } else if pollResult < 0 {
                break
            }
            // pollResult == 0 means poll timed out with no data yet — keep waiting
        }

        guard !allData.isEmpty else {
            close(clientSocket)
            return
        }

        let data = allData

        guard let decoded = try? JSONDecoder().decode(HookEvent.self, from: data) else {
            logger.warning("Failed to parse event: \(String(data: data, encoding: .utf8) ?? "?", privacy: .public)")
            close(clientSocket)
            return
        }

        // Normalize remote events so they behave correctly on the local host.
        let event: HookEvent = {
            guard isRemote else { return decoded }
            return HookEvent(
                providerId: decoded.providerId,
                sessionId: decoded.sessionId,
                cwd: decoded.cwd,
                event: decoded.event,
                status: decoded.status,
                pid: nil, // Remote PID is meaningless on this host
                tty: decoded.tty,
                tool: decoded.tool,
                toolInput: decoded.toolInput,
                toolUseId: decoded.toolUseId,
                notificationType: decoded.notificationType,
                message: decoded.message,
                transcriptPath: decoded.transcriptPath,
                agentId: decoded.agentId,
                agentType: decoded.agentType,
                remoteJsonlLines: decoded.remoteJsonlLines,
                remotePathDebug: decoded.remotePathDebug,
                dualApprovalMode: decoded.dualApprovalMode
            )
        }()


        let normalizedEvent = event.event.lowercased().replacingOccurrences(of: "_", with: "")

        logger.debug("Received: \(event.event, privacy: .public) for \(event.sessionId.prefix(8), privacy: .public)")

        if normalizedEvent == "pretooluse" {
            cacheToolUseId(event: event)
        }

        if normalizedEvent == "sessionend" {
            cleanupCache(sessionId: event.sessionId)
        }

        if event.expectsResponse {
            let toolUseId: String
            if let eventToolUseId = event.toolUseId {
                toolUseId = eventToolUseId
            } else if let cachedToolUseId = popCachedToolUseId(event: event) {
                toolUseId = cachedToolUseId
            } else {
                logger.warning("Permission request missing tool_use_id for \(event.sessionId.prefix(8), privacy: .public) - no cache hit")
                close(clientSocket)
                eventHandler?(event)
                return
            }

            logger.debug("Permission request - keeping socket open for \(event.sessionId.prefix(8), privacy: .public) tool:\(toolUseId.prefix(12), privacy: .public)")

            let updatedEvent = HookEvent(
                providerId: event.providerId,
                sessionId: event.sessionId,
                cwd: event.cwd,
                event: event.event,
                status: event.status,
                pid: event.pid,
                tty: event.tty,
                tool: event.tool,
                toolInput: event.toolInput,
                toolUseId: toolUseId,  // Use resolved toolUseId
                notificationType: event.notificationType,
                message: event.message,
                transcriptPath: event.transcriptPath,
                agentId: event.agentId,
                agentType: event.agentType,
                remoteJsonlLines: event.remoteJsonlLines,
                remotePathDebug: event.remotePathDebug,
                dualApprovalMode: event.dualApprovalMode
            )

            let isDualApproval = event.dualApprovalMode ?? false

            let pending = PendingPermission(
                providerId: event.providerId,
                sessionId: event.sessionId,
                toolUseId: toolUseId,
                clientSocket: clientSocket,
                event: updatedEvent,
                receivedAt: Date(),
                dualApprovalMode: isDualApproval
            )
            permissionsLock.lock()
            pendingPermissions[toolUseId] = pending
            permissionsLock.unlock()

            // In dual-approval mode, the hook will close its socket after 3 seconds.
            // Monitor for EOF so we can clean up the dead pending permission.
            if isDualApproval {
                let monitor = DispatchSource.makeReadSource(fileDescriptor: clientSocket, queue: queue)
                monitor.setEventHandler { [weak self] in
                    self?.cleanupDeadPermission(toolUseId: toolUseId)
                    monitor.cancel()
                }
                monitor.resume()
                socketMonitors[toolUseId] = monitor
            }

            eventHandler?(updatedEvent)
            return
        } else {
            close(clientSocket)
        }

        eventHandler?(event)
    }

    private func sendPermissionResponseBySession(sessionId: String, decision: String, reason: String?) {
        permissionsLock.lock()
        let matchingPending = pendingPermissions.values
            .filter { $0.sessionId == sessionId }
            .sorted { $0.receivedAt > $1.receivedAt }
            .first

        guard let pending = matchingPending else {
            permissionsLock.unlock()
            logger.debug("No pending permission for session: \(sessionId.prefix(8), privacy: .public)")
            return
        }

        pendingPermissions.removeValue(forKey: pending.toolUseId)
        permissionsLock.unlock()

        let response = HookResponse(decision: decision, reason: reason)
        guard let data = try? JSONEncoder().encode(response) else {
            close(pending.clientSocket)
            permissionFailureHandler?(sessionId, pending.toolUseId)
            return
        }

        let age = Date().timeIntervalSince(pending.receivedAt)
        logger.info("Sending response: \(decision, privacy: .public) for \(sessionId.prefix(8), privacy: .public) tool:\(pending.toolUseId.prefix(12), privacy: .public) (age: \(String(format: "%.1f", age), privacy: .public)s)")

        var writeSuccess = false
        data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else {
                logger.error("Failed to get data buffer address")
                return
            }
            let result = write(pending.clientSocket, baseAddress, data.count)
            if result < 0 {
                logger.error("Write failed with errno: \(errno)")
            } else {
                logger.debug("Write succeeded: \(result) bytes")
                writeSuccess = true
            }
        }

        close(pending.clientSocket)

        if !writeSuccess {
            permissionFailureHandler?(sessionId, pending.toolUseId)
        }
    }
}

// MARK: - AnyCodable for tool_input

/// Type-erasing codable wrapper for heterogeneous values
/// Used to decode JSON objects with mixed value types
struct AnyCodable: Codable, @unchecked Sendable {
    /// The underlying value (nonisolated(unsafe) because Any is not Sendable)
    nonisolated(unsafe) let value: Any

    /// Initialize with any value
    init(_ value: Any) {
        self.value = value
    }

    /// Decode from JSON
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            value = NSNull()
        } else if let bool = try? container.decode(Bool.self) {
            value = bool
        } else if let int = try? container.decode(Int.self) {
            value = int
        } else if let double = try? container.decode(Double.self) {
            value = double
        } else if let string = try? container.decode(String.self) {
            value = string
        } else if let array = try? container.decode([AnyCodable].self) {
            value = array.map { $0.value }
        } else if let dict = try? container.decode([String: AnyCodable].self) {
            value = dict.mapValues { $0.value }
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Cannot decode value")
        }
    }

    /// Encode to JSON
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()

        switch value {
        case is NSNull:
            try container.encodeNil()
        case let bool as Bool:
            try container.encode(bool)
        case let int as Int:
            try container.encode(int)
        case let double as Double:
            try container.encode(double)
        case let string as String:
            try container.encode(string)
        case let array as [Any]:
            try container.encode(array.map { AnyCodable($0) })
        case let dict as [String: Any]:
            try container.encode(dict.mapValues { AnyCodable($0) })
        default:
            throw EncodingError.invalidValue(value, EncodingError.Context(codingPath: [], debugDescription: "Cannot encode value"))
        }
    }
}
