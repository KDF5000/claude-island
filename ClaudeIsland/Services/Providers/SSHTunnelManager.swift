//
//  SSHTunnelManager.swift
//  ClaudeIsland
//
//  Manages SSH tunnels for remote Claude/Coco session monitoring
//  Enables detection of sessions running on remote servers via SSH
//

import Combine
import Foundation
import os.log

private let logger = Logger(subsystem: "com.claudeisland", category: "SSHTunnel")

/// Represents an active SSH tunnel
struct SSHTunnel: Identifiable, Equatable {
    let id: UUID
    let host: String
    let user: String?
    let sshPort: Int
    let localPort: Int
    let process: Process?
    let createdAt: Date

    var displayName: String {
        if let user = user {
            return "\(user)@\(host)"
        }
        return host
    }

    static func == (lhs: SSHTunnel, rhs: SSHTunnel) -> Bool {
        lhs.id == rhs.id
    }
}

/// Identifies an ssh `-R remotePort:127.0.0.1:localPort` forwarding process.
struct SSHTCPTunnelKey: Hashable {
    let host: String
    let user: String?
    let sshPort: Int
    let remotePort: Int
    let localPort: Int
}

/// Manages SSH tunnels for remote session monitoring
class SSHTunnelManager: ObservableObject {
    static let shared = SSHTunnelManager()

    // MARK: - Published State

    @Published private(set) var activeTunnels: [SSHTunnel] = []
    @Published var isTunnelSupported: Bool = false
    @Published private(set) var lastErrorMessage: String? = nil

    /// SSH tunnels that were detected by scanning local processes.
    ///
    /// This covers:
    /// - Tunnels created before the app started (we have no `Process` handle).
    /// - Tunnels created manually in Terminal.
    @Published private(set) var detectedTCPTunnels: Set<SSHTCPTunnelKey> = []


    // MARK: - Constants

    /// Default port for Claude Island TCP socket
    static let defaultPort = 19999

    /// Socket path for Unix domain socket
    static let socketPath = "/tmp/claude-island.sock"

    // MARK: - Private

    private var tunnelProcesses: [UUID: Process] = [:]

    private let detectionQueue = DispatchQueue(label: "com.claudeisland.SSHTunnelDetection")
    private var detectionTimer: DispatchSourceTimer?

    /// When we intentionally terminate a tunnel (user disconnect, replacement, etc),
    /// we should not surface its exit as an error.
    private var suppressExitErrorForTunnelIds: Set<UUID> = []
    private let suppressExitErrorLock = NSLock()

    private func suppressNextExitError(for id: UUID) {
        suppressExitErrorLock.lock()
        suppressExitErrorForTunnelIds.insert(id)
        suppressExitErrorLock.unlock()
    }

    private func consumeShouldSuppressExitError(for id: UUID) -> Bool {
        suppressExitErrorLock.lock()
        let should = suppressExitErrorForTunnelIds.contains(id)
        if should { suppressExitErrorForTunnelIds.remove(id) }
        suppressExitErrorLock.unlock()
        return should
    }

    /// Best-effort cleanup of stale ssh tunnel processes from previous app runs.
    ///
    /// When the app restarts, we lose the `Process` handles for any already-running
    /// `ssh -N -R ...` processes. If those are still alive, the next connect attempt
    /// will fail with: "remote port forwarding failed for listen port <port>".
    private func terminateStaleLocalSSHTunnels(
        host: String,
        user: String?,
        sshPort: Int,
        remotePort: Int,
        localPort: Int
    ) {
        let hostString: String = {
            if let user {
                return "\(user)@\(host)"
            }
            return host
        }()

        // Build substrings we expect in our ssh command line.
        let forwardSpec = "-R \(remotePort):127.0.0.1:\(localPort)"
        let portSpec = sshPort == 22 ? nil : "-p \(sshPort)"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        // Use `-ww` to avoid command truncation, otherwise we may miss the `-R ...` spec.
        process.arguments = ["-axww", "-o", "pid=", "-o", "command="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            // Read output BEFORE waiting to avoid deadlock if ps output exceeds pipe buffer.
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return }
            guard let text = String(data: data, encoding: .utf8) else { return }

            let pids: [Int] = text
                .split(separator: "\n")
                .compactMap { line in
                    // Very lightweight parse: "<pid> <command...>"
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    guard let spaceIdx = trimmed.firstIndex(of: " ") else { return nil }
                    let pidStr = trimmed[..<spaceIdx]
                    let cmd = trimmed[spaceIdx...]

                    guard let pid = Int(pidStr) else { return nil }

                    // Match only our port-forwarding tunnel for this host.
                    if !cmd.contains("ssh") { return nil }
                    if !cmd.contains(hostString) { return nil }
                    if !cmd.contains(forwardSpec) { return nil }
                    if let portSpec, !cmd.contains(portSpec) { return nil }
                    if !cmd.contains("-N") { return nil }
                    return pid
                }

            guard !pids.isEmpty else { return }

            logger.info("Terminating stale ssh tunnels: \(pids.map(String.init).joined(separator: ","), privacy: .public)")

            // SIGTERM, then SIGKILL if needed.
            for pid in pids {
                _ = kill(Int32(pid), SIGTERM)
            }
            usleep(200_000)
            for pid in pids {
                _ = kill(Int32(pid), SIGKILL)
            }
        } catch {
            // Best-effort; ignore.
            return
        }
    }

    // MARK: - Initialization

    private init() {
        checkSSHAvailability()
        startTCPTunnelDetectionTimer()
    }


    deinit {
        detectionTimer?.cancel()
        detectionTimer = nil
    }

    /// True if we consider the given tunnel active.
    ///
    /// Uses both in-memory tunnels (created by the app) and best-effort process scanning
    /// (for manual / previous-run tunnels).
    func isTCPTunnelActive(
        host: String,
        user: String?,
        sshPort: Int,
        remotePort: Int = 19999,
        localPort: Int = 19999
    ) -> Bool {
        if activeTunnels.contains(where: {
            $0.host == host && $0.user == user && $0.sshPort == sshPort && $0.localPort == localPort && ($0.process?.isRunning != false)
        }) {
            return true
        }

        let key = SSHTCPTunnelKey(
            host: host,
            user: user,
            sshPort: sshPort,
            remotePort: remotePort,
            localPort: localPort
        )
        return detectedTCPTunnels.contains(key)
    }

    // MARK: - Availability Check

    private func checkSSHAvailability() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = ["ssh"]

        do {
            try process.run()
            process.waitUntilExit()
            isTunnelSupported = process.terminationStatus == 0
        } catch {
            isTunnelSupported = false
        }

        logger.info("SSH tunnel support: \(self.isTunnelSupported, privacy: .public)")
    }

    // MARK: - TCP Tunnel Detection

    private func startTCPTunnelDetectionTimer() {
        detectionTimer?.cancel()
        detectionTimer = nil

        guard isTunnelSupported else { return }

        let timer = DispatchSource.makeTimerSource(queue: detectionQueue)
        // Low-frequency scan; enough for UI correctness without noticeable overhead.
        timer.schedule(deadline: .now(), repeating: .seconds(2), leeway: .seconds(1))
        timer.setEventHandler { [weak self] in
            self?.refreshDetectedTCPTunnels()
        }
        timer.resume()
        detectionTimer = timer
    }

    private func refreshDetectedTCPTunnels() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        // Use `-ww` to avoid command truncation, otherwise we may miss the destination host.
        process.arguments = ["-axww", "-o", "command="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            // Read output BEFORE waiting to avoid deadlock if ps output exceeds pipe buffer.
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return }
            guard let text = String(data: data, encoding: .utf8) else { return }

            var keys = Set<SSHTCPTunnelKey>()
            for rawLine in text.split(separator: "\n") {
                let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let key = parseTCPTunnelKey(from: line) else { continue }
                keys.insert(key)
            }

            Task { @MainActor in
                if keys != self.detectedTCPTunnels {
                    self.detectedTCPTunnels = keys
                }
            }
        } catch {
            // Best-effort; ignore.
            return
        }
    }

    private func parseTCPTunnelKey(from command: String) -> SSHTCPTunnelKey? {
        // Quick filters to avoid parsing unrelated processes.
        guard command.contains("ssh") else { return nil }
        guard command.contains("-R") else { return nil }
        // Our tunnels are long-lived; requiring -N avoids matching random one-off ssh commands.
        guard command.contains("-N") else { return nil }

        // Destination host is typically the last token.
        let tokens = command.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard let destination = tokens.last, !destination.hasPrefix("-") else { return nil }

        let user: String?
        let host: String
        if let at = destination.firstIndex(of: "@") {
            let u = String(destination[..<at])
            let h = String(destination[destination.index(after: at)...])
            guard !h.isEmpty else { return nil }
            user = u.isEmpty ? nil : u
            host = h
        } else {
            host = destination
            user = nil
        }

        // Parse `-p <port>` if present; default 22.
        var sshPort = 22
        if let pIndex = tokens.firstIndex(of: "-p"), pIndex + 1 < tokens.count {
            sshPort = Int(tokens[pIndex + 1]) ?? 22
        }

        // Parse `-R <remotePort>:127.0.0.1:<localPort>`.
        // Support both `-R 19999:...` and `-R19999:...`.
        let pattern = "-R\\s*([0-9]+):127\\.0\\.0\\.1:([0-9]+)"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(command.startIndex..<command.endIndex, in: command)
        guard let match = regex.firstMatch(in: command, range: range), match.numberOfRanges == 3,
              let remoteRange = Range(match.range(at: 1), in: command),
              let localRange = Range(match.range(at: 2), in: command)
        else {
            return nil
        }

        let remotePort = Int(command[remoteRange]) ?? 0
        let localPort = Int(command[localRange]) ?? 0
        guard remotePort > 0, localPort > 0 else { return nil }

        return SSHTCPTunnelKey(host: host, user: user, sshPort: sshPort, remotePort: remotePort, localPort: localPort)
    }

    // MARK: - Tunnel Management

    /// Create an SSH tunnel to a remote host
    /// - Parameters:
    ///   - host: Remote host address
    ///   - user: SSH username (optional)
    ///   - port: SSH port (default 22)
    /// - Returns: The created tunnel, or nil if failed
    @discardableResult
    func createTunnel(host: String, user: String? = nil, port: Int = 22) async -> SSHTunnel? {
        logger.info("Creating SSH tunnel to \(host, privacy: .public)")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")

        var args = [
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=5",
            "-o", "ExitOnForwardFailure=yes",
            "-o", "ServerAliveInterval=30",
            "-o", "ServerAliveCountMax=3",
        ]

        // Remote port forwarding: forward remote socket to local
        // This makes the remote server's connections to the socket reach our local server
        args.append(contentsOf: [
            "-R", "\(Self.socketPath):\(Self.socketPath)",
        ])

        // Build host string
        let hostString: String
        if let user = user {
            hostString = "\(user)@\(host)"
        } else {
            hostString = host
        }

        if port != 22 {
            args.append(contentsOf: ["-p", String(port)])
        }

        // Keep the connection alive without relying on stdin.
        // In a GUI app, stdin is often closed; using `cat` can exit immediately,
        // tearing down the tunnel. `-N` keeps ssh running with just forwarding.
        args.append(contentsOf: ["-N", "-T", hostString])

        process.arguments = args

        // Capture stderr so we can surface auth/forwarding errors in UI.
        let stderrPipe = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderrPipe

        do {
            try process.run()

            // If ssh exits immediately, treat as failure and surface stderr.
            try? await Task.sleep(nanoseconds: 300_000_000)
            if !process.isRunning {
                process.waitUntilExit()
                let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                let errText = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                await MainActor.run {
                    self.lastErrorMessage = errText.isEmpty ? "ssh exited with status \(process.terminationStatus)" : errText
                }
                logger.error("SSH tunnel exited early: \(self.lastErrorMessage ?? "unknown", privacy: .public)")
                return nil
            }

            await MainActor.run { self.lastErrorMessage = nil }

            let tunnel = SSHTunnel(
                id: UUID(),
                host: host,
                user: user,
                sshPort: port,
                localPort: Self.defaultPort,
                process: process,
                createdAt: Date()
            )

            tunnelProcesses[tunnel.id] = process
            await MainActor.run {
                activeTunnels.append(tunnel)
            }

            logger.info("SSH tunnel created successfully: \(tunnel.id, privacy: .public)")

            // Monitor process termination
            Task.detached { [weak self] in
                process.waitUntilExit()

                guard let self else { return }
                if !self.consumeShouldSuppressExitError(for: tunnel.id) {
                    let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                    let errText = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    if process.terminationStatus != 0 {
                        await MainActor.run {
                            self.lastErrorMessage = errText.isEmpty
                                ? "SSH 隧道已断开（exit \(process.terminationStatus)）"
                                : errText
                        }
                    }
                }

                await self.removeTunnel(tunnel.id)
            }

            return tunnel
        } catch {
            logger.error("Failed to create SSH tunnel: \(error, privacy: .public)")
            await MainActor.run { self.lastErrorMessage = error.localizedDescription }
            return nil
        }
    }

    /// Create tunnel using TCP port forwarding (alternative approach)
    func createTCPTunnel(
        host: String,
        user: String? = nil,
        sshPort: Int = 22,
        remotePort: Int = 19999,
        localPort: Int = 19999,
        didRetryAfterPortForwardFailure: Bool = false
    ) async -> SSHTunnel? {
        logger.info("Creating TCP SSH tunnel to \(host, privacy: .public):\(remotePort) -> localhost:\(localPort)")

        // Clean up any stale `ssh -N -R` process from previous app runs.
        terminateStaleLocalSSHTunnels(host: host, user: user, sshPort: sshPort, remotePort: remotePort, localPort: localPort)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")

        var args = [
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=5",
            "-o", "ExitOnForwardFailure=yes",
            "-o", "ServerAliveInterval=30",
            "-o", "ServerAliveCountMax=3",
        ]

        // Remote port forwarding: remote:19999 -> local:19999
        args.append(contentsOf: [
            "-R", "\(remotePort):127.0.0.1:\(localPort)",
        ])

        let hostString: String
        if let user = user {
            hostString = "\(user)@\(host)"
        } else {
            hostString = host
        }

        if sshPort != 22 {
            args.append(contentsOf: ["-p", String(sshPort)])
        }

        // Keep the connection alive without relying on stdin (see comment above).
        args.append(contentsOf: ["-N", "-T", hostString])

        process.arguments = args

        let stderrPipe = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderrPipe

        do {
            try process.run()

            // If ssh exits immediately, treat as failure and surface stderr.
            try? await Task.sleep(nanoseconds: 300_000_000)
            if !process.isRunning {
                process.waitUntilExit()
                let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                let errText = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                // If port-forward allocation failed, retry once after best-effort cleanup.
                if !didRetryAfterPortForwardFailure,
                   errText.contains("remote port forwarding failed for listen port") {
                    terminateStaleLocalSSHTunnels(host: host, user: user, sshPort: sshPort, remotePort: remotePort, localPort: localPort)

                    let retry = await createTCPTunnel(
                        host: host,
                        user: user,
                        sshPort: sshPort,
                        remotePort: remotePort,
                        localPort: localPort,
                        didRetryAfterPortForwardFailure: true
                    )
                    if retry != nil {
                        return retry
                    }
                }

                let friendly: String
                if errText.contains("remote port forwarding failed for listen port") {
                    friendly = errText + "\n\n可能原因：远端端口 \(remotePort) 已被占用（已有旧 tunnel 未退出），或远端 sshd 禁用了远程端口转发（AllowTcpForwarding）。"
                } else {
                    friendly = errText
                }
                await MainActor.run {
                    self.lastErrorMessage = friendly.isEmpty ? "ssh exited with status \(process.terminationStatus)" : friendly
                }
                logger.error("TCP SSH tunnel exited early: \(self.lastErrorMessage ?? "unknown", privacy: .public)")
                return nil
            }

            await MainActor.run { self.lastErrorMessage = nil }

            let tunnel = SSHTunnel(
                id: UUID(),
                host: host,
                user: user,
                sshPort: sshPort,
                localPort: localPort,
                process: process,
                createdAt: Date()
            )

            tunnelProcesses[tunnel.id] = process
            await MainActor.run {
                activeTunnels.append(tunnel)
            }

            logger.info("TCP SSH tunnel created: \(tunnel.id, privacy: .public)")

            Task.detached { [weak self] in
                process.waitUntilExit()

                guard let self else { return }
                if !self.consumeShouldSuppressExitError(for: tunnel.id) {
                    let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                    let errText = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    if process.terminationStatus != 0 {
                        await MainActor.run {
                            self.lastErrorMessage = errText.isEmpty
                                ? "SSH 隧道已断开（exit \(process.terminationStatus)）"
                                : errText
                        }
                    }
                }

                await self.removeTunnel(tunnel.id)
            }

            return tunnel
        } catch {
            logger.error("Failed to create TCP SSH tunnel: \(error, privacy: .public)")
            await MainActor.run { self.lastErrorMessage = error.localizedDescription }
            return nil
        }
    }

    /// Remove a tunnel by ID
    func removeTunnel(_ id: UUID) async {
        guard let process = tunnelProcesses[id] else { return }

        // This is an intentional stop; don't surface it as an error.
        suppressNextExitError(for: id)

        if process.isRunning {
            process.terminate()
        }

        tunnelProcesses.removeValue(forKey: id)
        await MainActor.run {
            activeTunnels.removeAll { $0.id == id }
        }

        logger.info("SSH tunnel removed: \(id, privacy: .public)")
    }

    /// Remove tunnels matching host/user/sshPort.
    func removeTunnels(host: String, user: String?, sshPort: Int) async {
        // Best-effort: also terminate a matching tunnel process even if it was created
        // manually or by a previous app run (we won't have a `Process` handle).
        terminateStaleLocalSSHTunnels(
            host: host,
            user: user,
            sshPort: sshPort,
            remotePort: 19999,
            localPort: 19999
        )

        let ids = activeTunnels
            .filter { $0.host == host && $0.user == user && $0.sshPort == sshPort }
            .map { $0.id }

        for id in ids {
            await removeTunnel(id)
        }
    }

    // MARK: - Remote hook bootstrap

    /// Uploads the remote hook script to the remote host over SSH.
    /// Writes to `~/.claude/hooks/claude-island-remote-hook.py` by default.
    func installRemoteHook(
        host: String,
        user: String? = nil,
        sshPort: Int = 22,
        remotePath: String = "~/.claude/hooks/claude-island-remote-hook.py"
    ) async -> Result<Void, Error> {
        let script = loadBundledRemoteHookScript() ?? Self.fallbackRemoteHookScript

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")

        var args: [String] = [
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "ServerAliveInterval=30",
            "-o", "ServerAliveCountMax=3",
        ]

        if sshPort != 22 {
            args.append(contentsOf: ["-p", String(sshPort)])
        }

        let hostString: String = {
            if let user {
                return "\(user)@\(host)"
            }
            return host
        }()

        // NOTE: ssh transmits a single command string (not argv). If we pass
        // `bash -lc <cmd>` as multiple arguments, remote shell parsing can break
        // the `-c` command string (e.g. `bash -lc mkdir -p ...` -> command is only
        // `mkdir`, causing `mkdir: missing operand`).
        // Fix: wrap the command string in single quotes so the remote shell keeps
        // it as one argument to `bash -lc`.
        let expandedPath: String = {
            if remotePath.hasPrefix("~/") {
                return "$HOME/" + remotePath.dropFirst(2)
            }
            return remotePath
        }()

        let escapedPath = expandedPath.replacingOccurrences(of: "\"", with: "\\\"")
        let cmd = "mkdir -p \"$HOME/.claude/hooks\" && cat > \"\(escapedPath)\" && chmod 755 \"\(escapedPath)\""
        let cmdArg = Self.shellSingleQuote(cmd)
        args.append(contentsOf: [hostString, "bash", "-lc", cmdArg])

        process.arguments = args

        let stdinPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardError = stderrPipe

        do {
            try process.run()

            if let data = script.data(using: .utf8) {
                stdinPipe.fileHandleForWriting.write(data)
            }
            try? stdinPipe.fileHandleForWriting.close()

            process.waitUntilExit()
            if process.terminationStatus == 0 {
                logger.info("Installed remote hook to \(hostString, privacy: .public):\(remotePath, privacy: .public)")
                return .success(())
            }

            let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let errText = String(data: errData, encoding: .utf8) ?? ""
            let error = NSError(
                domain: "SSHTunnelManager",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: errText.isEmpty ? "ssh exited with status \(process.terminationStatus)" : errText]
            )
            return .failure(error)
        } catch {
            return .failure(error)
        }
    }

    private func loadBundledRemoteHookScript() -> String? {
        // If the .py is added to Copy Bundle Resources, this will work in release builds.
        guard let url = Bundle.main.url(forResource: "claude-island-remote-hook", withExtension: "py") else {
            return nil
        }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    private static func shellSingleQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Fallback script content, used when the file is not bundled.
    private static let fallbackRemoteHookScript: String = """
#!/usr/bin/env python3
# Claude Island Remote Hook
# - For use on remote servers accessed via SSH
# - Connects to local Claude Island via SSH tunnel (Unix socket or TCP)

import json
import os
import socket
import sys
import subprocess

SOCKET_PATH = "/tmp/claude-island.sock"
TCP_HOST = "127.0.0.1"
TCP_PORT = 19999

TIMEOUT_SECONDS = 300


def get_tty():
    ppid = os.getppid()

    try:
        result = subprocess.run(
            ["ps", "-p", str(ppid), "-o", "tty="],
            capture_output=True,
            text=True,
            timeout=2,
        )
        tty = result.stdout.strip()
        if tty and tty not in ("??", "-"):
            if not tty.startswith("/dev/"):
                tty = "/dev/" + tty
            return tty
    except Exception:
        pass

    try:
        return os.ttyname(sys.stdin.fileno())
    except (OSError, AttributeError):
        pass

    return None


def send_event(state):
    # Try Unix socket first
    try:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(TIMEOUT_SECONDS)
        sock.connect(SOCKET_PATH)
        sock.sendall(json.dumps(state).encode())
        if state.get("status") == "waiting_for_approval":
            response = sock.recv(4096)
            sock.close()
            if response:
                return json.loads(response.decode())
        else:
            sock.close()
        return None
    except (socket.error, OSError, FileNotFoundError):
        pass

    # TCP fallback
    try:
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.settimeout(TIMEOUT_SECONDS)
        sock.connect((TCP_HOST, TCP_PORT))
        sock.sendall(json.dumps(state).encode())
        if state.get("status") == "waiting_for_approval":
            response = sock.recv(4096)
            sock.close()
            if response:
                return json.loads(response.decode())
        else:
            sock.close()
        return None
    except (socket.error, OSError, json.JSONDecodeError) as e:
        print(f"ClaudeIsland remote hook error: {e}", file=sys.stderr)
        return None


def main():
    try:
        data = json.load(sys.stdin)
    except json.JSONDecodeError:
        sys.exit(1)

    event = data.get("hook_event_name", "")
    session_id = data.get("session_id", "unknown")
    cwd = data.get("cwd") or os.getcwd()
    tool_name = data.get("tool_name", "")
    tool_input = data.get("tool_input", {})

    if event and event[0].isupper():
        provider_id = "claude-code"
    else:
        provider_id = "coco"

    pid = os.getppid()
    tty = get_tty()

    state = {
        "provider_id": provider_id,
        "session_id": session_id,
        "cwd": cwd,
        "event": event,
        "pid": pid,
        "tty": tty,
        "tool": tool_name,
        "tool_input": tool_input,
    }

    normalized_event = event.lower().replace("_", "")

    if normalized_event == "userpromptsubmit":
        prompt = data.get("prompt", "")
        state["status"] = "processing"
        state["message"] = prompt[:200] if prompt else None

    elif normalized_event == "pretooluse":
        state["status"] = "running_tool"
        state["tool_use_id"] = data.get("tool_use_id") or f"{session_id}:{tool_name}"

    elif normalized_event == "posttooluse":
        state["status"] = "processing"
        state["tool_use_id"] = data.get("tool_use_id") or f"{session_id}:{tool_name}"

    elif normalized_event == "posttoolusefailure":
        state["status"] = "processing"
        state["tool_use_id"] = data.get("tool_use_id") or f"{session_id}:{tool_name}"

    elif normalized_event == "notification":
        notification_type = data.get("notification_type", "")
        title = data.get("title", "")
        message = data.get("message", "")
        if notification_type in ("idle_prompt", "elicitation_dialog"):
            state["status"] = "waiting_for_input"
        else:
            state["status"] = "notification"
        state["notification_type"] = notification_type
        state["message"] = f"{title}: {message}" if title else message

    elif normalized_event == "stop":
        state["status"] = "waiting_for_input"

    elif normalized_event == "subagentstart":
        state["status"] = "processing"
        state["agent_id"] = data.get("agent_id", "")
        state["agent_type"] = data.get("agent_type", "")

    elif normalized_event == "subagentstop":
        state["status"] = "processing"

    elif normalized_event == "sessionstart":
        state["status"] = "waiting_for_input"
        state["source"] = data.get("source", "startup")

    elif normalized_event == "sessionend":
        state["status"] = "ended"
        state["end_reason"] = data.get("reason", "other")

    elif normalized_event == "precompact":
        state["status"] = "compacting"

    elif normalized_event == "postcompact":
        state["status"] = "processing"

    elif normalized_event == "permissionrequest":
        state["status"] = "waiting_for_approval"
        state["tool_use_id"] = data.get("tool_use_id") or f"{session_id}:{tool_name}"

        response = send_event(state)
        if response:
            decision = response.get("decision", "ask")
            reason = response.get("reason", "")
            if decision == "allow":
                print(json.dumps({"hookSpecificOutput": {"decision": {"behavior": "allow"}}}))
                sys.exit(0)
            if decision == "deny":
                print(json.dumps({"hookSpecificOutput": {"decision": {"behavior": "deny", "message": reason or "Denied by user via ClaudeIsland"}}}))
                sys.exit(0)
        sys.exit(0)

    else:
        state["status"] = "unknown"

    send_event(state)


if __name__ == "__main__":
    main()
"""

    /// Remove all tunnels
    func removeAllTunnels() async {
        for tunnel in activeTunnels {
            await removeTunnel(tunnel.id)
        }
    }

    // MARK: - Helper Methods

    /// Get SSH command for user to run on remote server
    /// This command sets up the tunnel from the remote side
    func getRemoteSetupCommand(for host: String, user: String? = nil) -> String {
        let hostString = user != nil ? "\(user!)@\(host)" : host
        return """
        # Run this command on your LOCAL machine to set up SSH tunnel
        # This forwards the remote socket to your local Claude Island app

        ssh -R /tmp/claude-island.sock:/tmp/claude-island.sock \(hostString) -N

        # Or for TCP mode (if Unix socket forwarding doesn't work):
        # ssh -R 19999:127.0.0.1:19999 \(hostString) -N
        """
    }

    /// Check if a tunnel exists for a host
    func hasTunnel(for host: String) -> Bool {
        activeTunnels.contains { $0.host == host }
    }
}

// MARK: - Remote Hook Script

extension SSHTunnelManager {

    /// Get the hook script content for remote servers
    /// This script should be installed on remote servers
    static var remoteHookScript: String {
        """
        #!/usr/bin/env python3
        \"\"\"
        Claude Island Remote Hook
        - For use on remote servers accessed via SSH
        - Connects to local Claude Island via SSH tunnel
        \"\"\"

        import json
        import os
        import socket
        import sys

        # Try Unix socket first (SSH -R forwarding)
        SOCKET_PATH = "/tmp/claude-island.sock"
        # Fall back to TCP (SSH -R port forwarding)
        TCP_HOST = "127.0.0.1"
        TCP_PORT = 19999
        TIMEOUT_SECONDS = 300

        def send_event(state):
            # Try Unix socket first
            try:
                sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                sock.settimeout(TIMEOUT_SECONDS)
                sock.connect(SOCKET_PATH)
                sock.sendall(json.dumps(state).encode())

                if state.get("status") == "waiting_for_approval":
                    response = sock.recv(4096)
                    sock.close()
                    if response:
                        return json.loads(response.decode())
                else:
                    sock.close()
                return None
            except (socket.error, OSError):
                pass

            # Fall back to TCP
            try:
                sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
                sock.settimeout(TIMEOUT_SECONDS)
                sock.connect((TCP_HOST, TCP_PORT))
                sock.sendall(json.dumps(state).encode())

                if state.get("status") == "waiting_for_approval":
                    response = sock.recv(4096)
                    sock.close()
                    if response:
                        return json.loads(response.decode())
                else:
                    sock.close()
                return None
            except (socket.error, OSError, json.JSONDecodeError):
                return None

        # ... rest of the hook script is the same as coco-island-state.py
        """
    }
}
