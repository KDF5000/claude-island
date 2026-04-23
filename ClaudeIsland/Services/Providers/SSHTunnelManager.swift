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

private let logger = Logger(subsystem: "com.codingisland", category: "SSHTunnel")

// MARK: - Local debug log (file)
// Console.app 有时不会显示 info/debug 级别日志；为了可观测性，把 Remote Hook 的关键步骤
// 额外落到本机日志文件，便于用户直接查看。
private let remoteHookLogLock = NSLock()

private func appendRemoteHookLog(_ line: String) {
    remoteHookLogLock.lock()
    defer { remoteHookLogLock.unlock() }

    let fm = FileManager.default
    let home = fm.homeDirectoryForCurrentUser
    let dir = home.appendingPathComponent("Library/Logs/CodingIsland", isDirectory: true)
    let fileURL = dir.appendingPathComponent("remote-hook.log", isDirectory: false)

    do {
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: fileURL.path) {
            fm.createFile(atPath: fileURL.path, contents: nil)
        }

        let df = ISO8601DateFormatter()
        df.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let stamp = df.string(from: Date())
        let out = "[\(stamp)] \(line)\n"
        guard let data = out.data(using: .utf8) else { return }

        let handle = try FileHandle(forWritingTo: fileURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        try handle.close()
    } catch {
        // Worst case: swallow logging failures.
    }
}

private func remoteHookLogPathString() -> String {
    FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/CodingIsland/remote-hook.log")
        .path
}

/// Represents an active SSH tunnel
struct SSHTunnel: Identifiable, Equatable {
    let id: UUID
    let host: String
    let user: String?
    let sshPort: Int
    let remotePort: Int
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

    /// Default port for Coding Island TCP socket
    static let defaultPort = 19999

    /// Socket path for Unix domain socket
    static let socketPath = IslandPaths.socketPath

    // MARK: - Private

    private var tunnelProcesses: [UUID: Process] = [:]

    private let detectionQueue = DispatchQueue(label: "com.codingisland.SSHTunnelDetection")
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
        remotePort: Int = SSHTunnelManager.defaultPort,
        localPort: Int = SSHTunnelManager.defaultPort
    ) -> Bool {
        if activeTunnels.contains(where: {
            $0.host == host &&
            $0.user == user &&
            $0.sshPort == sshPort &&
            $0.remotePort == remotePort &&
            $0.localPort == localPort &&
            ($0.process?.isRunning != false)
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
                remotePort: Self.defaultPort,
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
        remotePort: Int = SSHTunnelManager.defaultPort,
        localPort: Int = SSHTunnelManager.defaultPort,
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

        // Remote port forwarding: remote:<remotePort> -> local:<localPort>
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
                remotePort: remotePort,
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
    func removeTunnels(
        host: String,
        user: String?,
        sshPort: Int,
        remotePort: Int = SSHTunnelManager.defaultPort,
        localPort: Int = SSHTunnelManager.defaultPort
    ) async {
        // Best-effort: also terminate a matching tunnel process even if it was created
        // manually or by a previous app run (we won't have a `Process` handle).
        terminateStaleLocalSSHTunnels(
            host: host,
            user: user,
            sshPort: sshPort,
            remotePort: remotePort,
            localPort: localPort
        )

        let ids = activeTunnels
            .filter {
                $0.host == host &&
                $0.user == user &&
                $0.sshPort == sshPort &&
                $0.remotePort == remotePort &&
                $0.localPort == localPort
            }
            .map { $0.id }

        for id in ids {
            await removeTunnel(id)
        }
    }

    // MARK: - Remote hook bootstrap

    /// Typical Trae/Coco config paths on remote machines (checked in order).
    private static let remoteCocoConfigCandidates: [String] = [
        "$HOME/.trae/traecli.yaml",
        "$HOME/.config/coco/coco.yaml",
        "$HOME/.config/coco/config.yaml",
        "$HOME/.coco/coco.yaml",
        "$HOME/.coco.yaml",
    ]

    /// Some SSH setups can provide a wrong `$HOME` in non-interactive sessions.
    /// Fix it by reading the real home directory from the passwd database.
    ///
    /// This shell snippet runs on the remote machine inside `bash -lc`.
    private static func remoteHomeBootstrapShell() -> String {
        // Prefer reading the home from the passwd database.
        // Fall back to shell `~` expansion when python isn't available.
        // We also `export HOME` so subsequent `$HOME/...` expansions are correct.
        // IMPORTANT: terminate statements with `;` instead of relying on newlines.
        // Some remote shells/SSH setups can collapse newlines in the transmitted command,
        // which would turn `export HOME` into `export HOME mkdir -p ...` and fail.
        return #"""
HOME="$(python3 -c 'import os,pwd;print(pwd.getpwuid(os.getuid()).pw_dir)' 2>/dev/null || python -c 'import os,pwd;print(pwd.getpwuid(os.getuid()).pw_dir)' 2>/dev/null || eval echo ~)";
export HOME;
"""#
    }

    /// Returns a shell snippet that prints the chosen config path (absolute),
    /// defaulting to `$HOME/.trae/traecli.yaml` when none exist.
    private static func remoteResolveConfigPathShell() -> String {
        // NOTE: keep this POSIX-sh compatible (bash -lc is used remotely).
        return Self.remoteHomeBootstrapShell() + #"""
CFG=""
for p in "$HOME/.trae/traecli.yaml" "$HOME/.config/coco/coco.yaml" "$HOME/.config/coco/config.yaml" "$HOME/.coco/coco.yaml" "$HOME/.coco.yaml"; do
  if [ -f "$p" ]; then CFG="$p"; break; fi
done
if [ -z "$CFG" ]; then CFG="$HOME/.trae/traecli.yaml"; fi
printf "%s" "$CFG"
"""#
    }

    /// Returns a shell snippet that prints all existing config paths (one per line).
    /// If none exist, prints nothing.
    private static func remoteListExistingConfigPathsShell() -> String {
        return Self.remoteHomeBootstrapShell() + #"""
for p in "$HOME/.trae/traecli.yaml" "$HOME/.config/coco/coco.yaml" "$HOME/.config/coco/config.yaml" "$HOME/.coco/coco.yaml" "$HOME/.coco.yaml"; do
  if [ -f "$p" ]; then printf "%s\n" "$p"; fi
done
"""#
    }

    /// Best-effort read of remote `$HOME` for building absolute paths in config.
    private func readRemoteHomeDirectory(host: String, user: String?, sshPort: Int) async -> Result<String, Error> {
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
            if let user { return "\(user)@\(host)" }
            return host
        }()

        // Print corrected $HOME without trailing newline.
        let cmd = Self.remoteHomeBootstrapShell() + "printf %s \"$HOME\""
        let cmdArg = Self.shellSingleQuote(cmd)
        args.append(contentsOf: [hostString, "bash", "-lc", cmdArg])
        process.arguments = args

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            let status = try await runProcessAsync(process)
            let outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            let outText = String(data: outData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            if status == 0, !outText.isEmpty {
                return .success(outText)
            }

            let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let errText = String(data: errData, encoding: .utf8) ?? ""
            let error = NSError(
                domain: "SSHTunnelManager",
                code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: errText.isEmpty ? "ssh exited with status \(status)" : errText]
            )
            return .failure(error)
        } catch {
            return .failure(error)
        }
    }

    private func resolveRemoteCocoConfigPath(host: String, user: String?, sshPort: Int) async -> Result<String, Error> {
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
            if let user { return "\(user)@\(host)" }
            return host
        }()

        let cmd = Self.remoteResolveConfigPathShell()
        let cmdArg = Self.shellSingleQuote(cmd)
        args.append(contentsOf: [hostString, "bash", "-lc", cmdArg])
        process.arguments = args

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            let status = try await runProcessAsync(process)
            let outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            let outText = String(data: outData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            if status == 0, !outText.isEmpty {
                return .success(outText)
            }

            let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let errText = String(data: errData, encoding: .utf8) ?? ""
            let error = NSError(
                domain: "SSHTunnelManager",
                code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: errText.isEmpty ? "ssh exited with status \(status)" : errText]
            )
            return .failure(error)
        } catch {
            return .failure(error)
        }
    }

    private func listRemoteExistingCocoConfigPaths(host: String, user: String?, sshPort: Int) async -> Result<[String], Error> {
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
            if let user { return "\(user)@\(host)" }
            return host
        }()

        let cmd = Self.remoteListExistingConfigPathsShell()
        let cmdArg = Self.shellSingleQuote(cmd)
        args.append(contentsOf: [hostString, "bash", "-lc", cmdArg])
        process.arguments = args

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            let status = try await runProcessAsync(process)
            let outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            let outText = String(data: outData, encoding: .utf8) ?? ""
            if status == 0 {
                let paths = outText
                    .split(separator: "\n")
                    .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                return .success(paths)
            }

            let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let errText = String(data: errData, encoding: .utf8) ?? ""
            let error = NSError(
                domain: "SSHTunnelManager",
                code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: errText.isEmpty ? "ssh exited with status \(status)" : errText]
            )
            return .failure(error)
        } catch {
            return .failure(error)
        }
    }

    private func readRemoteFile(host: String, user: String?, sshPort: Int, path: String) async -> Result<String, Error> {
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
            if let user { return "\(user)@\(host)" }
            return host
        }()

        let escapedPath = path.replacingOccurrences(of: "\"", with: "\\\"")
        let cmd = "if [ -f \"\(escapedPath)\" ]; then cat \"\(escapedPath)\"; fi"
        let cmdArg = Self.shellSingleQuote(cmd)
        args.append(contentsOf: [hostString, "bash", "-lc", cmdArg])
        process.arguments = args

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            let status = try await runProcessAsync(process)
            let outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            let outText = String(data: outData, encoding: .utf8) ?? ""

            if status == 0 {
                return .success(outText)
            }

            let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let errText = String(data: errData, encoding: .utf8) ?? ""
            let error = NSError(
                domain: "SSHTunnelManager",
                code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: errText.isEmpty ? "ssh exited with status \(status)" : errText]
            )
            return .failure(error)
        } catch {
            return .failure(error)
        }
    }

    private func writeRemoteFile(host: String, user: String?, sshPort: Int, path: String, content: String) async -> Result<Void, Error> {
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
            if let user { return "\(user)@\(host)" }
            return host
        }()

        let escapedPath = path.replacingOccurrences(of: "\"", with: "\\\"")
        // `dirname` is available on Linux/macOS; use it to create parent dir.
        let cmd = "mkdir -p \"$(dirname \"\(escapedPath)\")\" && cat > \"\(escapedPath)\""
        let cmdArg = Self.shellSingleQuote(cmd)
        args.append(contentsOf: [hostString, "bash", "-lc", cmdArg])
        process.arguments = args

        let stdinPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardError = stderrPipe

        do {
            try process.run()
            if let data = content.data(using: .utf8) {
                stdinPipe.fileHandleForWriting.write(data)
            }
            try? stdinPipe.fileHandleForWriting.close()

            process.waitUntilExit()
            if process.terminationStatus == 0 {
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

    private static func buildRemoteTraeHookBlock(command: String) -> String {
        // Keep indentation consistent with Trae/Coco YAML (2 spaces under hooks:).
        return """
  # Coding Island hook (remote)
  - type: command
    command: \(command)
    # Allow enough time for Island-driven permission decisions.
    # The hook script will stop waiting early if the CLI proceeds.
    timeout: 310s
    matchers:
      - event: user_prompt_submit
      - event: pre_tool_use
      - event: post_tool_use
      - event: post_tool_use_failure
      - event: permission_request
      - event: notification
      - event: stop
      - event: subagent_start
      - event: subagent_stop
      - event: session_start
      - event: session_end
      - event: pre_compact
      - event: post_compact
"""
    }

    /// Inserts/updates our Coding Island hook inside a Trae/Coco YAML config.
    /// Preserves other hooks by removing only entries that reference our scripts.
    private static func upsertCodingIslandHook(in content: String, hookBlock: String) -> String {
        let markers = [
            "coding-island-remote-hook.py",
            "coding-island-coco-hook.py",
            "coco-island-state.py",
        ]

        var lines = content.components(separatedBy: "\n")
        if let hooksIndex = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "hooks:" }) {
            var endIndex = lines.count
            for i in (hooksIndex + 1)..<lines.count {
                let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty,
                   !lines[i].hasPrefix(" "),
                   !lines[i].hasPrefix("\t"),
                   !trimmed.hasPrefix("#") {
                    endIndex = i
                    break
                }
            }

            let beforeHooks = Array(lines[0...hooksIndex])
            let hooksBody = hooksIndex + 1 < endIndex ? Array(lines[(hooksIndex + 1)..<endIndex]) : []
            let afterHooks = endIndex < lines.count ? Array(lines[endIndex...]) : []

            // Remove our existing hook blocks but keep other hooks.
            var kept: [String] = []
            var idx = 0
            while idx < hooksBody.count {
                let line = hooksBody[idx]
                if line.hasPrefix("  - ") {
                    var j = idx + 1
                    while j < hooksBody.count {
                        if hooksBody[j].hasPrefix("  - ") { break }
                        j += 1
                    }
                    let blockLines = Array(hooksBody[idx..<j])
                    let blockText = blockLines.joined(separator: "\n")
                    if markers.contains(where: { blockText.contains($0) }) {
                        // drop
                    } else {
                        kept.append(contentsOf: blockLines)
                    }
                    idx = j
                } else {
                    kept.append(line)
                    idx += 1
                }
            }

            // Ensure we end hooks section with a newline before appending our block.
            if !kept.isEmpty, kept.last != "" {
                kept.append("")
            }
            kept.append(contentsOf: hookBlock.components(separatedBy: "\n"))

            var newLines = beforeHooks
            newLines.append(contentsOf: kept)
            newLines.append(contentsOf: afterHooks)
            return newLines.joined(separator: "\n")
        }

        // No hooks: section; append a new one.
        if content.isEmpty {
            return "hooks:\n" + hookBlock
        }
        var out = content
        if !out.hasSuffix("\n") {
            out += "\n"
        }
        // Separate from previous content.
        out += "\n" + "hooks:\n" + hookBlock
        return out
    }

    /// Ensures the remote Trae/Coco config contains the Coding Island remote hook.
    private func ensureRemoteTraeHookConfigured(
        host: String,
        user: String?,
        sshPort: Int,
        remoteHomeDirectory: String,
        remoteHookAbsolutePath: String
    ) async -> Result<Void, Error> {
        let hostString: String = {
            if let user { return "\(user)@\(host)" }
            return host
        }()

        // Prefer updating ALL existing config files to avoid ambiguity about which one
        // the remote CLI actually reads.
        let listResult = await listRemoteExistingCocoConfigPaths(host: host, user: user, sshPort: sshPort)
        let paths: [String]
        switch listResult {
        case .failure(let err):
            logger.error("RemoteHook: list existing config paths failed host=\(hostString, privacy: .public): \(err.localizedDescription, privacy: .public)")
            appendRemoteHookLog("RemoteHook: list configs FAILED host=\(hostString) error=\(err.localizedDescription)")
            return .failure(err)
        case .success(let found):
            paths = found
        }

        if paths.isEmpty {
            logger.info("RemoteHook: no existing config files found host=\(hostString, privacy: .public)")
            appendRemoteHookLog("RemoteHook: no existing config files host=\(hostString)")
        } else {
            logger.info("RemoteHook: existing config files host=\(hostString, privacy: .public) paths=\(paths.joined(separator: ","), privacy: .public)")
            appendRemoteHookLog("RemoteHook: existing config files host=\(hostString) paths=\(paths.joined(separator: ","))")
        }

        let command = "python3 " + Self.shellSingleQuote(remoteHookAbsolutePath)
        let hookBlock = Self.buildRemoteTraeHookBlock(command: command)

        // Always write to the canonical config locations users check, even if the CLI
        // ends up reading a different file on a given distro.
        var targetSet = Set(paths)
        targetSet.insert(remoteHomeDirectory + "/.trae/traecli.yaml")
        targetSet.insert(remoteHomeDirectory + "/.config/coco/coco.yaml")
        let targetPaths = Array(targetSet)

        logger.info(
            "RemoteHook: will update configs host=\(hostString, privacy: .public) targets=\(targetPaths.sorted().joined(separator: ","), privacy: .public)"
        )
        appendRemoteHookLog("RemoteHook: will update configs host=\(hostString) targets=\(targetPaths.sorted().joined(separator: ","))")

        // Apply to each target config.
        for configPath in targetPaths {
            logger.info("RemoteHook: updating config host=\(hostString, privacy: .public) path=\(configPath, privacy: .public)")
            appendRemoteHookLog("RemoteHook: updating config host=\(hostString) path=\(configPath)")
            let readResult = await readRemoteFile(host: host, user: user, sshPort: sshPort, path: configPath)
            let existing: String
            switch readResult {
            case .success(let text):
                existing = text
            case .failure(let err):
                logger.error("RemoteHook: read config failed host=\(hostString, privacy: .public) path=\(configPath, privacy: .public): \(err.localizedDescription, privacy: .public)")
                appendRemoteHookLog("RemoteHook: read config FAILED host=\(hostString) path=\(configPath) error=\(err.localizedDescription)")
                return .failure(err)
            }

            logger.info("RemoteHook: read config OK host=\(hostString, privacy: .public) path=\(configPath, privacy: .public) bytes=\(existing.utf8.count, privacy: .public)")
            appendRemoteHookLog("RemoteHook: read config OK host=\(hostString) path=\(configPath) bytes=\(existing.utf8.count)")
            let updated = Self.upsertCodingIslandHook(in: existing, hookBlock: hookBlock)
            let writeResult = await writeRemoteFile(host: host, user: user, sshPort: sshPort, path: configPath, content: updated)
            switch writeResult {
            case .success:
                logger.info("RemoteHook: wrote config OK host=\(hostString, privacy: .public) path=\(configPath, privacy: .public)")
                appendRemoteHookLog("RemoteHook: wrote config OK host=\(hostString) path=\(configPath)")
                // Read-after-write verification. Users reported “success” but the file
                // didn't actually contain hooks when inspected manually.
                let verifyRead = await readRemoteFile(host: host, user: user, sshPort: sshPort, path: configPath)
                switch verifyRead {
                case .failure(let err):
                    logger.error("RemoteHook: verify read failed host=\(hostString, privacy: .public) path=\(configPath, privacy: .public): \(err.localizedDescription, privacy: .public)")
                    appendRemoteHookLog("RemoteHook: verify read FAILED host=\(hostString) path=\(configPath) error=\(err.localizedDescription)")
                    return .failure(err)
                case .success(let afterWriteText):
                    if !afterWriteText.contains("hooks:") || !afterWriteText.contains("coding-island-remote-hook.py") {
                        let preview = String(afterWriteText.prefix(500))
                        let message = "Remote hook 配置写入校验失败：写入后回读未包含 hooks/remote-hook 标记。\n" +
                                      "path=\(configPath)\n" +
                                      "expectedHook=\(remoteHookAbsolutePath)\n" +
                                      "preview=\n\(preview)"
                        logger.error("RemoteHook: verify FAILED host=\(hostString, privacy: .public) path=\(configPath, privacy: .public)")
                        appendRemoteHookLog("RemoteHook: verify FAILED host=\(hostString) path=\(configPath) preview=\(preview)")
                        let error = NSError(
                            domain: "SSHTunnelManager",
                            code: 2001,
                            userInfo: [NSLocalizedDescriptionKey: message]
                        )
                        return .failure(error)
                    }

                    logger.info("RemoteHook: verify OK host=\(hostString, privacy: .public) path=\(configPath, privacy: .public) bytes=\(afterWriteText.utf8.count, privacy: .public)")
                    appendRemoteHookLog("RemoteHook: verify OK host=\(hostString) path=\(configPath) bytes=\(afterWriteText.utf8.count)")
                }
            case .failure(let err):
                logger.error("RemoteHook: write config FAILED host=\(hostString, privacy: .public) path=\(configPath, privacy: .public): \(err.localizedDescription, privacy: .public)")
                appendRemoteHookLog("RemoteHook: write config FAILED host=\(hostString) path=\(configPath) error=\(err.localizedDescription)")
                return .failure(err)
            }
        }

        return .success(())
    }

    /// Checks whether the remote hook script exists on the remote host and whether
    /// Trae/Coco config references it (otherwise no events will fire).
    func isRemoteHookInstalled(
        host: String,
        user: String? = nil,
        sshPort: Int = 22,
        remotePath: String = "~/.coding-island/hooks/coding-island-remote-hook.py"
    ) async -> Result<Bool, Error> {
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

        let expandedPath: String = {
            if remotePath.hasPrefix("~/") {
                return "$HOME/" + remotePath.dropFirst(2)
            }
            return remotePath
        }()

        let escapedPath = expandedPath.replacingOccurrences(of: "\"", with: "\\\"")
        // Consider the remote hook "installed" only when:
        // 1) the script exists (it is executed via `python3 <path>`, so exec bit isn't required)
        // 2) Trae/Coco config references the script (otherwise no events will fire)
        // NOTE: this must be a *non-raw* Swift string literal so `\(escapedPath)` interpolates.
        // Using a `#"""` raw string would require `\#(escapedPath)`.
        let cmd = Self.remoteHomeBootstrapShell() + """
echo "SCRIPT_PATH=\(escapedPath)"
if [ -f "\(escapedPath)" ]; then
  echo "SCRIPT_EXISTS=1"
else
  echo "SCRIPT_EXISTS=0"
  exit 10
fi

found_path=""
for p in "$HOME/.trae/traecli.yaml" "$HOME/.config/coco/coco.yaml" "$HOME/.config/coco/config.yaml" "$HOME/.coco/coco.yaml" "$HOME/.coco.yaml"; do
  if [ -f "$p" ]; then
    if grep -q "coding-island-remote-hook.py" "$p" 2>/dev/null; then
      found_path="$p"
      break
    fi
  fi
done
echo "FOUND_CONFIG=$found_path"
if [ -n "$found_path" ]; then
  exit 0
fi
exit 11
"""
        let cmdArg = Self.shellSingleQuote(cmd)
        args.append(contentsOf: [hostString, "bash", "-lc", cmdArg])
        process.arguments = args

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            let terminationStatus = try await runProcessAsync(process)

            // Diagnostic: record stdout/stderr to the local file log so users can see
            // why the UI shows "Not Installed".
            let outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            let outText = String(data: outData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let errText = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !outText.isEmpty {
                appendRemoteHookLog("RemoteHook: status-check stdout host=\(hostString) code=\(terminationStatus)\n\(outText)")
            } else {
                appendRemoteHookLog("RemoteHook: status-check stdout host=\(hostString) code=\(terminationStatus) <empty>")
            }
            if !errText.isEmpty {
                appendRemoteHookLog("RemoteHook: status-check stderr host=\(hostString) code=\(terminationStatus)\n\(errText)")
            }

            switch terminationStatus {
            case 0:
                return .success(true)
            case 10, 11:
                return .success(false)
            default:
                let error = NSError(
                    domain: "SSHTunnelManager",
                    code: Int(terminationStatus),
                    userInfo: [
                        NSLocalizedDescriptionKey: errText.isEmpty
                            ? "ssh exited with status \(terminationStatus)"
                            : errText
                    ]
                )
                return .failure(error)
            }
        } catch {
            return .failure(error)
        }
    }

    /// Reads the `TCP_PORT` constant from the remote hook script.
    ///
    /// Returns:
    /// - `.success(Int?)`: parsed port if present, else nil (file exists but port line missing)
    /// - `.failure(Error)`: ssh failed or remote command errored
    func readRemoteHookTCPPort(
        host: String,
        user: String? = nil,
        sshPort: Int = 22,
        remotePath: String = "~/.coding-island/hooks/coding-island-remote-hook.py"
    ) async -> Result<Int?, Error> {
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

        let expandedPath: String = {
            if remotePath.hasPrefix("~/") {
                return "$HOME/" + remotePath.dropFirst(2)
            }
            return remotePath
        }()

        // Use python3 to avoid depending on sed/grep variants.
        // Print the port as a single line, or empty if not found.
        let escapedPath = expandedPath.replacingOccurrences(of: "\"", with: "\\\"")
        let cmd = Self.remoteHomeBootstrapShell() + "python3 -c 'import re,sys; p=sys.argv[1];\n" +
                  "\ntry: txt=open(p, \"r\", encoding=\"utf-8\", errors=\"ignore\").read()\n" +
                  "except Exception: sys.exit(10)\n" +
                  "m=re.search(r\"(?m)^TCP_PORT\\\\s*=\\\\s*(\\\\d+)\\\\s*$\", txt)\n" +
                  "print(m.group(1) if m else \"\")' \"\(escapedPath)\""
        let cmdArg = Self.shellSingleQuote(cmd)
        args.append(contentsOf: [hostString, "bash", "-lc", cmdArg])
        process.arguments = args

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            let status = try await runProcessAsync(process)
            let outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            let outText = (String(data: outData, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

            if status == 0 {
                if outText.isEmpty {
                    return .success(nil)
                }
                return .success(Int(outText))
            }

            let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let errText = String(data: errData, encoding: .utf8) ?? ""
            let error = NSError(
                domain: "SSHTunnelManager",
                code: Int(status),
                userInfo: [
                    NSLocalizedDescriptionKey: errText.isEmpty
                        ? "ssh exited with status \(status)"
                        : errText
                ]
            )
            return .failure(error)
        } catch {
            return .failure(error)
        }
    }

    private func runProcessAsync(_ process: Process) async throws -> Int32 {
        try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { finishedProcess in
                continuation.resume(returning: finishedProcess.terminationStatus)
            }

            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: error)
            }
        }
    }

    /// Uploads the remote hook script to the remote host over SSH.
    /// Writes to `~/.coding-island/hooks/coding-island-remote-hook.py` by default.
    func installRemoteHook(
        host: String,
        user: String? = nil,
        sshPort: Int = 22,
        remotePath: String = "~/.coding-island/hooks/coding-island-remote-hook.py",
        tcpPort: Int = SSHTunnelManager.defaultPort,
        localPort: Int = SSHTunnelManager.defaultPort
    ) async -> Result<Void, Error> {
        let baseScript = loadBundledRemoteHookScript() ?? Self.fallbackRemoteHookScript
        let script = Self.patchRemoteHookScript(baseScript, tcpPort: tcpPort, localPort: localPort)

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

        let startMsg = "RemoteHook: install start host=\(hostString) sshPort=\(sshPort) tcpPort=\(tcpPort) localPort=\(localPort) remotePath=\(remotePath) log=\(remoteHookLogPathString())"
        appendRemoteHookLog(startMsg)
        logger.notice("\(startMsg, privacy: .public)")

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
        let cmd = Self.remoteHomeBootstrapShell() + "mkdir -p \"$HOME/.coding-island/hooks\" && cat > \"\(escapedPath)\" && chmod 755 \"\(escapedPath)\""
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
                appendRemoteHookLog("RemoteHook: script written OK host=\(hostString) remotePath=\(remotePath)")

                // Also ensure the remote Trae/Coco config actually calls this hook.
                // Without this, the script exists but never runs, so the app sees no events.
                let homeResult = await readRemoteHomeDirectory(host: host, user: user, sshPort: sshPort)
                switch homeResult {
                case .failure(let err):
                    logger.error("RemoteHook: read remote HOME failed host=\(hostString, privacy: .public): \(err.localizedDescription, privacy: .public)")
                    appendRemoteHookLog("RemoteHook: read HOME FAILED host=\(hostString) error=\(err.localizedDescription)")
                    return .failure(err)
                case .success(let homeDir):
                    logger.info("RemoteHook: resolved remote HOME host=\(hostString, privacy: .public) HOME=\(homeDir, privacy: .public)")
                    appendRemoteHookLog("RemoteHook: resolved HOME host=\(hostString) HOME=\(homeDir)")
                    // Build absolute path (avoid relying on ~/$HOME expansion in the CLI runner).
                    let hookAbsPath: String = {
                        if remotePath.hasPrefix("~/") {
                            return homeDir + "/" + String(remotePath.dropFirst(2))
                        }
                        if remotePath.hasPrefix("$HOME/") {
                            return homeDir + "/" + String(remotePath.dropFirst(6))
                        }
                        return remotePath
                    }()

                    let cfgResult = await ensureRemoteTraeHookConfigured(
                        host: host,
                        user: user,
                        sshPort: sshPort,
                        remoteHomeDirectory: homeDir,
                        remoteHookAbsolutePath: hookAbsPath
                    )
                    switch cfgResult {
                    case .success:
                        logger.info("RemoteHook: config updated OK host=\(hostString, privacy: .public)")
                        appendRemoteHookLog("RemoteHook: config updated OK host=\(hostString)")
                        return .success(())
                    case .failure(let err):
                        logger.error("RemoteHook: config update FAILED host=\(hostString, privacy: .public): \(err.localizedDescription, privacy: .public)")
                        appendRemoteHookLog("RemoteHook: config update FAILED host=\(hostString) error=\(err.localizedDescription)")
                        return .failure(err)
                    }
                }
            }

            let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let errText = String(data: errData, encoding: .utf8) ?? ""
            if !errText.isEmpty {
                logger.error("RemoteHook: ssh failed host=\(hostString, privacy: .public) status=\(process.terminationStatus, privacy: .public) stderr=\(errText, privacy: .public)")
                appendRemoteHookLog("RemoteHook: ssh failed host=\(hostString) status=\(process.terminationStatus) stderr=\(errText)")
            } else {
                logger.error("RemoteHook: ssh failed host=\(hostString, privacy: .public) status=\(process.terminationStatus, privacy: .public)")
                appendRemoteHookLog("RemoteHook: ssh failed host=\(hostString) status=\(process.terminationStatus)")
            }
            let error = NSError(
                domain: "SSHTunnelManager",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: errText.isEmpty ? "ssh exited with status \(process.terminationStatus)" : errText]
            )
            return .failure(error)
        } catch {
            logger.error("RemoteHook: ssh launch failed host=\(hostString, privacy: .public): \(error.localizedDescription, privacy: .public)")
            appendRemoteHookLog("RemoteHook: ssh launch failed host=\(hostString) error=\(error.localizedDescription)")
            return .failure(error)
        }
    }

    private static func patchRemoteHookScript(_ script: String, tcpPort: Int, localPort: Int) -> String {
        // Keep the script self-contained (no env var dependency). We patch only the TCP port
        // constant; unix socket path stays the same.
        var out = script

        // Replace any `TCP_PORT = <number>` assignment.
        if let re = try? NSRegularExpression(pattern: "(?m)^TCP_PORT\\s*=\\s*\\d+\\s*$") {
            let range = NSRange(out.startIndex..<out.endIndex, in: out)
            out = re.stringByReplacingMatches(in: out, range: range, withTemplate: "TCP_PORT = \(tcpPort)")
        }

        // Best-effort update of the nearby comment if present.
        if let re = try? NSRegularExpression(pattern: "(?m)^# TCP fallback \\(forwarded via SSH -R .*\\)\\s*$") {
            let range = NSRange(out.startIndex..<out.endIndex, in: out)
            out = re.stringByReplacingMatches(
                in: out,
                range: range,
                withTemplate: "# TCP fallback (forwarded via SSH -R \(tcpPort):127.0.0.1:\(localPort))"
            )
        }
        return out
    }

    private func loadBundledRemoteHookScript() -> String? {
        // If the .py is added to Copy Bundle Resources, this will work in release builds.
        guard let url = Bundle.main.url(forResource: "coding-island-remote-hook", withExtension: "py") else {
            return nil
        }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    private static func shellSingleQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Fallback script content, used when the file is not bundled.
    private static let fallbackRemoteHookScript: String = #"""
#!/usr/bin/env python3
# Coding Island Remote Hook
# - For use on remote servers accessed via SSH
# - Connects to local Coding Island via SSH tunnel (Unix socket or TCP)
# - Install: Copy to remote server and configure in coco/claude settings

import json
import os
import socket
import sys
import subprocess

# Unix socket path (forwarded via SSH -R)
SOCKET_PATH = os.path.expanduser("~/.coding-island/coding-island.sock")

# TCP fallback (forwarded via SSH -R 19999:127.0.0.1:19999)
TCP_HOST = "127.0.0.1"
TCP_PORT = 19999

TIMEOUT_SECONDS = 300  # 5 minutes for permission decisions
PROVIDER_ID = "coco-remote"  # Will be overridden by actual provider

# Per-session JSONL byte offsets (tracks how much we've already sent)
_jsonl_offsets = {}


def read_new_jsonl_lines(jsonl_path, session_id):
    """Read new lines from a JSONL file since the last read offset.
    Returns list of raw line strings (not parsed)."""
    if not jsonl_path or not os.path.isfile(jsonl_path):
        return []
    offset = _jsonl_offsets.get(session_id, 0)
    try:
        with open(jsonl_path, "rb") as f:
            f.seek(0, 2)  # end
            file_size = f.tell()
            if file_size <= offset:
                return []
            f.seek(offset)
            new_bytes = f.read()
            _jsonl_offsets[session_id] = file_size
        lines = []
        for raw in new_bytes.decode("utf-8", errors="replace").splitlines():
            raw = raw.strip()
            if raw:
                lines.append(raw)
        return lines
    except OSError:
        return []


def get_tty():
    """Get the TTY of the process"""
    ppid = os.getppid()
    
    try:
        result = subprocess.run(
            ["ps", "-p", str(ppid), "-o", "tty="],
            capture_output=True,
            text=True,
            timeout=2
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
    """Send event to app via SSH tunnel, return response if any"""
    
    # Try Unix socket first (if forwarded via SSH -R)
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

    # Fall back to TCP (if forwarded via SSH -R port:port)
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
        print(f"CodingIsland remote hook error: {e}", file=sys.stderr)
        return None


def main():
    try:
        data = json.load(sys.stdin)
    except json.JSONDecodeError:
        sys.exit(1)

    # Detect provider from hook event name format
    event = data.get("hook_event_name", "")
    
    # Extract common fields
    session_id = data.get("session_id", "unknown")
    cwd = data.get("cwd") or os.getcwd()
    tool_name = data.get("tool_name", "")
    tool_input = data.get("tool_input", {})
    
    # Determine provider
    # Claude Code provides transcript_path in hook events.
    # Coco does not, so if it's empty, we assume it's Coco.
    transcript_path = data.get("transcript_path", "")
    if transcript_path:
        provider_id = "claude-code"
    else:
        provider_id = "coco"

    # Get process info
    pid = os.getppid()
    tty = get_tty()

    # Get JSONL transcript path.
    # Claude Code provides transcript_path in hook events.
    # Coco does not, so we derive the path from the well-known cache location.
    # Note: traces.jsonl contains OpenTelemetry spans (not messages); events.jsonl
    # has the actual conversation in agent_start/message/tool_call format.
    _path_debug = []
    if not transcript_path and provider_id == "coco":
        import platform
        home = os.path.expanduser("~")
        _path_debug.append(f"home={home} platform={platform.system()}")
        if platform.system() == "Darwin":
            coco_cache_base = os.path.join(home, "Library", "Caches", "coco", "sessions", session_id)
        else:
            # Linux / other: try XDG_CACHE_HOME first, then ~/.cache
            xdg_cache = os.environ.get("XDG_CACHE_HOME", os.path.join(home, ".cache"))
            coco_cache_base = os.path.join(xdg_cache, "coco", "sessions", session_id)
        # events.jsonl has conversation messages; traces.jsonl is OpenTelemetry spans only
        coco_events = os.path.join(coco_cache_base, "events.jsonl")
        _path_debug.append(f"coco_events={coco_events} exists={os.path.isfile(coco_events)}")
        if os.path.isfile(coco_events):
            transcript_path = coco_events
        else:
            # Also try ~/.config/coco and other common locations
            for alt_base in [
                os.path.join(home, ".config", "coco", "sessions", session_id),
                os.path.join(home, ".local", "share", "coco", "sessions", session_id),
            ]:
                alt_events = os.path.join(alt_base, "events.jsonl")
                _path_debug.append(f"alt={alt_events} exists={os.path.isfile(alt_events)}")
                if os.path.isfile(alt_events):
                    transcript_path = alt_events
                    break

    # Build state object
    state = {
        "provider_id": provider_id,
        "session_id": session_id,
        "cwd": cwd,
        "event": event,
        "pid": pid,
        "tty": tty,
        "tool": tool_name,
        "tool_input": tool_input,
        "transcript_path": transcript_path,
        "remote_path_debug": _path_debug,
    }

    # === Event-to-status mapping ===
    
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
        tool_response = data.get("tool_response", "")
        state["tool_result"] = tool_response[:500] if tool_response else None
        state["tool_use_id"] = data.get("tool_use_id") or f"{session_id}:{tool_name}"
        
    elif normalized_event == "posttoolusefailure":
        error = data.get("error", "Unknown error")
        state["status"] = "processing"
        state["error"] = error
        state["tool_use_id"] = data.get("tool_use_id") or f"{session_id}:{tool_name}"
        
    elif normalized_event == "notification":
        notification_type = data.get("notification_type", "")
        title = data.get("title", "")
        message = data.get("message", "")
        
        if notification_type == "permission_prompt":
            sys.exit(0)
        elif notification_type == "idle_prompt":
            state["status"] = "waiting_for_input"
        elif notification_type == "elicitation_dialog":
            state["status"] = "waiting_for_input"
        else:
            state["status"] = "notification"
            
        state["notification_type"] = notification_type
        state["message"] = f"{title}: {message}" if title else message
        
    elif normalized_event == "stop":
        state["status"] = "waiting_for_input"
        
    elif normalized_event == "subagentstart":
        agent_id = data.get("agent_id", "")
        agent_type = data.get("agent_type", "")
        state["status"] = "processing"
        state["agent_id"] = agent_id
        state["agent_type"] = agent_type
        
    elif normalized_event == "subagentstop":
        state["status"] = "processing"
        
    elif normalized_event == "sessionstart":
        source = data.get("source", "startup")
        state["status"] = "waiting_for_input"
        state["source"] = source
        
    elif normalized_event == "sessionend":
        reason = data.get("reason", "other")
        state["status"] = "ended"
        state["end_reason"] = reason
        
    elif normalized_event == "precompact":
        state["status"] = "compacting"
        
    elif normalized_event == "postcompact":
        compact_summary = data.get("compact_summary", "")
        state["status"] = "processing"
        state["compact_summary"] = compact_summary
        
    elif normalized_event == "permissionrequest":
        # === Critical: Permission request handling ===
        state["status"] = "waiting_for_approval"
        state["tool_use_id"] = data.get("tool_use_id") or f"{session_id}:{tool_name}"
        
        # Send to app and wait for decision
        response = send_event(state)
        
        if response:
            decision = response.get("decision", "ask")
            reason = response.get("reason", "")
            
            if decision == "allow":
                output = {
                    "hookSpecificOutput": {
                        "hookEventName": event,
                        "decision": {"behavior": "allow"}
                    }
                }
                print(json.dumps(output))
                sys.exit(0)
                
            elif decision == "deny":
                output = {
                    "hookSpecificOutput": {
                        "hookEventName": event,
                        "decision": {
                            "behavior": "deny",
                            "message": reason or "Denied by user via CodingIsland"
                        }
                    }
                }
                print(json.dumps(output))
                sys.exit(0)
        
        # No response or explicit "ask" - tell the CLI to show its native UI
        output = {
            "hookSpecificOutput": {
                "hookEventName": event,
                "decision": {"behavior": "ask"}
            }
        }
        print(json.dumps(output))
        sys.exit(0)
        
    else:
        state["status"] = "unknown"

    # Send to socket (fire and forget for non-permission events)
    # Attach any new JSONL lines so the Mac app can build message history
    new_lines = read_new_jsonl_lines(transcript_path, session_id)
    if new_lines:
        state["remote_jsonl_lines"] = new_lines
    send_event(state)


if __name__ == "__main__":
    main()
"""#

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
        # This forwards the remote socket to your local Coding Island app

        ssh -R /tmp/coding-island.sock:\(Self.socketPath) \(hostString) -N

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
        Coding Island Remote Hook
        - For use on remote servers accessed via SSH
        - Connects to local Coding Island via SSH tunnel
        \"\"\"

        import json
        import os
        import socket
        import sys

        # Try Unix socket first (SSH -R forwarding)
        SOCKET_PATH = os.path.expanduser("~/.coding-island/coding-island.sock")
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
