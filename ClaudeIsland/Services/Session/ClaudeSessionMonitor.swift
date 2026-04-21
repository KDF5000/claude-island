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

            // Check if the hook socket is still alive (fast path)
            let hasSocket = HookSocketServer.shared.hasPendingPermission(sessionId: sessionId)

            if hasSocket {
                // Fast path: hook is still waiting, respond via socket
                HookSocketServer.shared.respondToPermission(
                    toolUseId: permission.toolUseId,
                    decision: "allow"
                )
            } else {
                // Fallback: hook already timed out, CLI is showing its own UI.
                // Send approval keystrokes to the terminal.
                await sendApprovalToTerminal(session: session, approve: true)
            }

            await SessionStore.shared.process(
                .permissionApproved(sessionId: sessionId, toolUseId: permission.toolUseId)
            )
        }
    }

    func denyPermission(sessionId: String, reason: String?) {
        Task {
            guard let session = await SessionStore.shared.session(for: sessionId),
                  let permission = session.activePermission else {
                return
            }

            let hasSocket = HookSocketServer.shared.hasPendingPermission(sessionId: sessionId)

            if hasSocket {
                HookSocketServer.shared.respondToPermission(
                    toolUseId: permission.toolUseId,
                    decision: "deny",
                    reason: reason
                )
            } else {
                await sendApprovalToTerminal(session: session, approve: false)
            }

            await SessionStore.shared.process(
                .permissionDenied(sessionId: sessionId, toolUseId: permission.toolUseId, reason: reason)
            )
        }
    }

    // MARK: - Terminal Keystroke Injection

    /// Send approval/denial keystrokes to the terminal when the hook socket is no longer available.
    private func sendApprovalToTerminal(session: SessionState, approve: Bool) async {
        if session.isInTmux, let tty = session.tty {
            // tmux session: use ToolApprovalHandler (tmux send-keys)
            if let target = await findTmuxTarget(tty: tty) {
                if approve {
                    _ = await ToolApprovalHandler.shared.approveOnce(target: target)
                } else {
                    _ = await ToolApprovalHandler.shared.reject(target: target)
                }
            }
        } else if let pid = session.pid {
            // Non-tmux session: focus terminal + AppleScript keystrokes
            _ = await YabaiController.shared.focusWindow(forClaudePid: pid)
            try? await Task.sleep(for: .milliseconds(100))
            let key = approve ? "1" : "n"
            await sendKeystrokesViaAppleScript(keys: [key, "Return"])
        }
    }

    /// Send keystrokes via AppleScript (System Events)
    private func sendKeystrokesViaAppleScript(keys: [String]) async {
        let keystrokeLines = keys.map { key in
            if key == "Return" {
                return "key code 36"
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
