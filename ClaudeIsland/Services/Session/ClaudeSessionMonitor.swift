//
//  ClaudeSessionMonitor.swift
//  ClaudeIsland
//
//  MainActor wrapper around SessionStore for UI binding.
//  Publishes SessionState arrays for SwiftUI observation.
//

import AppKit
import Combine
import Foundation

@MainActor
class ClaudeSessionMonitor: ObservableObject {
    @Published var instances: [SessionState] = []
    @Published var pendingInstances: [SessionState] = []

    private var cancellables = Set<AnyCancellable>()

    // MARK: - Singleton
    static let shared = ClaudeSessionMonitor()

    init() {
        SessionStore.shared.sessionsPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] sessions in
                self?.updateFromSessions(sessions)
            }
            .store(in: &cancellables)

        InterruptWatcherManager.shared.delegate = self
    }

    // MARK: - Monitoring Lifecycle

    func startMonitoring() {
        // Start periodic status rechecking
        Task {
            await SessionStore.shared.startPeriodicStatusCheck()
        }

        HookSocketServer.shared.start(
            onEvent: { event in
                Task {
                    await SessionStore.shared.process(.hookReceived(event))
                }

                if event.sessionPhase == .processing {
                    Task { @MainActor in
                        InterruptWatcherManager.shared.startWatching(
                            sessionId: event.sessionId,
                            cwd: event.cwd
                        )
                    }
                }

                if event.status == "ended" {
                    Task { @MainActor in
                        InterruptWatcherManager.shared.stopWatching(sessionId: event.sessionId)
                    }
                }

                let normalizedEvent = event.event.lowercased().replacingOccurrences(of: "_", with: "")

                if normalizedEvent == "stop" {
                    HookSocketServer.shared.cancelPendingPermissions(sessionId: event.sessionId)
                }

                if normalizedEvent == "posttooluse", let toolUseId = event.toolUseId {
                    HookSocketServer.shared.cancelPendingPermission(toolUseId: toolUseId)
                }
            },
            onPermissionFailure: { sessionId, toolUseId in
                Task {
                    await SessionStore.shared.process(
                        .permissionSocketFailed(sessionId: sessionId, toolUseId: toolUseId)
                    )
                }
            }
        )
    }

    func stopMonitoring() {
        HookSocketServer.shared.stop()
        Task {
            await SessionStore.shared.stopPeriodicStatusCheck()
        }
    }

    // MARK: - Permission Handling

    func approvePermission(sessionId: String) {
        Task {
            guard let session = await SessionStore.shared.session(for: sessionId),
                  let permission = session.activePermission else {
                return
            }

            // Try to respond via hook socket first (fast path). If the tool_use_id doesn't match,
            // fall back to the most recent pending permission for the session.
            var resolvedToolUseId = permission.toolUseId

            if HookSocketServer.shared.hasPendingPermission(sessionId: sessionId) {
                let wrote = HookSocketServer.shared.respondToPermission(toolUseId: permission.toolUseId, decision: "allow")
                if !wrote {
                    if let pending = HookSocketServer.shared.getPendingPermission(sessionId: sessionId),
                       let actualId = pending.toolId {
                        resolvedToolUseId = actualId
                        _ = HookSocketServer.shared.respondToPermission(toolUseId: actualId, decision: "allow")
                    } else if !HookSocketServer.shared.hasPendingPermission(sessionId: sessionId) {
                        // Socket path failed (write error / socket closed). Fall back to terminal keystrokes.
                        await sendApprovalToTerminal(session: session, approve: true)
                    }
                }
            } else {
                // Fallback: hook already timed out, CLI is showing its own UI.
                // Send approval keystrokes to the terminal.
                await sendApprovalToTerminal(session: session, approve: true)
            }

            await SessionStore.shared.process(.permissionApproved(sessionId: sessionId, toolUseId: resolvedToolUseId))
        }
    }

    func denyPermission(sessionId: String, reason: String?) {
        Task {
            guard let session = await SessionStore.shared.session(for: sessionId),
                  let permission = session.activePermission else {
                return
            }

            var resolvedToolUseId = permission.toolUseId

            if HookSocketServer.shared.hasPendingPermission(sessionId: sessionId) {
                let wrote = HookSocketServer.shared.respondToPermission(toolUseId: permission.toolUseId, decision: "deny", reason: reason)
                if !wrote {
                    if let pending = HookSocketServer.shared.getPendingPermission(sessionId: sessionId),
                       let actualId = pending.toolId {
                        resolvedToolUseId = actualId
                        _ = HookSocketServer.shared.respondToPermission(toolUseId: actualId, decision: "deny", reason: reason)
                    } else if !HookSocketServer.shared.hasPendingPermission(sessionId: sessionId) {
                        await sendApprovalToTerminal(session: session, approve: false)
                    }
                }
            } else {
                await sendApprovalToTerminal(session: session, approve: false)
            }

            await SessionStore.shared.process(.permissionDenied(sessionId: sessionId, toolUseId: resolvedToolUseId, reason: reason))
        }
    }

    // MARK: - Terminal Keystroke Injection

    /// Send approval/denial keystrokes to the terminal when the hook socket is no longer available.
    private func sendApprovalToTerminal(session: SessionState, approve: Bool) async {
        let isCocoLike = (session.providerId == "coco" || session.providerId == "coco-remote")

        if session.isInTmux, let tty = session.tty {
            // tmux session: use ToolApprovalHandler (tmux send-keys)
            if let target = await findTmuxTarget(tty: tty) {
                if isCocoLike {
                    // Trae/Coco uses an interactive selector: default is highlighted; Enter confirms; Esc cancels.
                    if approve {
                        _ = await ToolApprovalHandler.shared.pressEnter(target: target)
                    } else {
                        _ = await ToolApprovalHandler.shared.pressEscape(target: target)
                    }
                } else {
                    // Claude Code legacy prompt (numeric)
                    if approve {
                        _ = await ToolApprovalHandler.shared.approveOnce(target: target)
                    } else {
                        _ = await ToolApprovalHandler.shared.reject(target: target)
                    }
                }
            }
        } else if let pid = session.pid {
            // Non-tmux session: we cannot inject input by writing to /dev/tty (that only prints).
            // Instead, activate the owning terminal app and send real keystrokes via AppleScript.
            let terminalBundleId = await focusTerminalApp(forSessionPid: pid)
            try? await Task.sleep(for: .milliseconds(120))

            // iTerm2: prefer its AppleScript API so we don't depend on Accessibility keystroke injection.
            // This also helps when System Events keystrokes are blocked.
            if approve, terminalBundleId == "com.googlecode.iterm2" {
                if await sendReturnToITerm2Session(tty: session.tty) {
                    return
                }
            }

            if isCocoLike {
                // Trae/Coco selector: Enter confirms current selection (default is Yes), Esc cancels.
                if approve {
                    await sendKeystrokesViaAppleScript(keys: ["Return"])
                } else {
                    await sendKeystrokesViaAppleScript(keys: ["Escape"])
                }
            } else {
                let key = approve ? "1" : "n"
                await sendKeystrokesViaAppleScript(keys: [key, "Return"])
            }
        } else {
            // Last resort: AppleScript keystrokes to the current focused app.
            // (May fail if focus is not on the terminal.)
            if isCocoLike {
                if approve {
                    await sendKeystrokesViaAppleScript(keys: ["Return"])
                } else {
                    await sendKeystrokesViaAppleScript(keys: ["Escape"])
                }
            } else {
                let key = approve ? "1" : "n"
                await sendKeystrokesViaAppleScript(keys: [key, "Return"])
            }
        }
    }

    /// Best-effort focus of the terminal app that owns the CLI session.
    /// Returns the terminal app bundle identifier when available.
    private func focusTerminalApp(forSessionPid pid: Int) async -> String? {
        let tree = ProcessTreeBuilder.shared.buildTree()
        guard let terminalPid = ProcessTreeBuilder.shared.findTerminalPid(forProcess: pid, tree: tree),
              let app = NSRunningApplication(processIdentifier: pid_t(terminalPid)) else {
            return nil
        }

        let bundleId = app.bundleIdentifier
        if let bundleId, let mainApp = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first {
            _ = mainApp.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        } else {
            _ = app.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        }
        return bundleId
    }

    /// iTerm2-only: locate the session by tty (if possible) and send a Return (write text "").
    /// Falls back to current session if tty lookup fails.
    private func sendReturnToITerm2Session(tty: String?) async -> Bool {
        let normalizedTty = tty?.replacingOccurrences(of: "/dev/", with: "")

        let script: String
        if let normalizedTty, !normalizedTty.isEmpty {
            script = """
            tell application \"iTerm2\"
                repeat with w in windows
                    repeat with t in tabs of w
                        repeat with s in sessions of t
                            try
                                if (tty of s) is \"\(normalizedTty)\" then
                                    select t
                                    select w
                                    tell s to write text \"\"
                                    return \"ok\"
                                end if
                            end try
                        end repeat
                    end repeat
                end repeat

                -- Fallback: current session
                tell current session of current window to write text \"\"
                return \"ok\"
            end tell
            """
        } else {
            script = """
            tell application \"iTerm2\"
                tell current session of current window to write text \"\"
                return \"ok\"
            end tell
            """
        }

        let result = await ProcessExecutor.shared.runWithResult("/usr/bin/osascript", arguments: ["-e", script])
        switch result {
        case .success(let res):
            return res.isSuccess
        case .failure:
            return false
        }
    }

    /// Send keystrokes via AppleScript (System Events)
    private func sendKeystrokesViaAppleScript(keys: [String]) async {
        let keystrokeLines = keys.map { key in
            if key == "Return" {
                return "key code 36"
            } else if key == "Escape" {
                return "key code 53"
            } else {
                return "keystroke \"\(key)\""
            }
        }.joined(separator: "\n    delay 0.05\n    ")

        let script = """
        tell application "System Events"
            \(keystrokeLines)
        end tell
        """

        _ = try? await ProcessExecutor.shared.run(
            "/usr/bin/osascript", arguments: ["-e", script]
        )
    }

    /// Find the tmux target for a given TTY
    private func findTmuxTarget(tty: String) async -> TmuxTarget? {
        guard let tmuxPath = await TmuxPathFinder.shared.getTmuxPath() else {
            return nil
        }

        do {
            let output = try await ProcessExecutor.shared.run(
                tmuxPath,
                arguments: ["list-panes", "-a", "-F", "#{session_name}:#{window_index}.#{pane_index} #{pane_tty}"]
            )

            let lines = output.components(separatedBy: "\n")
            for line in lines {
                let parts = line.components(separatedBy: " ")
                guard parts.count >= 2 else { continue }

                let target = parts[0]
                let paneTty = parts[1].replacingOccurrences(of: "/dev/", with: "")

                if paneTty == tty {
                    return TmuxTarget(from: target)
                }
            }
        } catch {
            return nil
        }

        return nil
    }

    /// Archive (remove) a session from the instances list
    func archiveSession(sessionId: String) {
        Task {
            await SessionStore.shared.process(.sessionEnded(sessionId: sessionId))
        }
    }

    // MARK: - State Update

    private func updateFromSessions(_ sessions: [SessionState]) {
        instances = sessions
        pendingInstances = sessions.filter { $0.needsAttention }
    }

    // MARK: - History Loading (for UI)

    /// Request history load for a session
    func loadHistory(sessionId: String, cwd: String) {
        Task {
            await SessionStore.shared.process(.loadHistory(sessionId: sessionId, cwd: cwd))
        }
    }
}

// MARK: - Interrupt Watcher Delegate

extension ClaudeSessionMonitor: JSONLInterruptWatcherDelegate {
    nonisolated func didDetectInterrupt(sessionId: String) {
        Task {
            await SessionStore.shared.process(.interruptDetected(sessionId: sessionId))
        }

        Task { @MainActor in
            InterruptWatcherManager.shared.stopWatching(sessionId: sessionId)
        }
    }
}
