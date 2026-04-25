//
//  WindowFocuser.swift
//  ClaudeIsland
//
//  Focuses windows using yabai
//

import Cocoa
import Foundation

/// Focuses windows using yabai
actor WindowFocuser {
    static let shared = WindowFocuser()

    private init() {}

    /// Focus a window by ID
    func focusWindow(id: Int) async -> Bool {
        guard let yabaiPath = await WindowFinder.shared.getYabaiPath() else { return false }

        do {
            _ = try await ProcessExecutor.shared.run(yabaiPath, arguments: [
                "-m", "window", "--focus", String(id)
            ])
            return true
        } catch {
            return false
        }
    }

    /// Focus the tmux window for a terminal
    func focusTmuxWindow(terminalPid: Int, windows: [YabaiWindow]) async -> Bool {
        // First, activate the terminal app to bring it to front (handles minimized/hidden windows)
        await activateTerminalApp(forPid: terminalPid)

        // Try to find actual tmux window
        if let tmuxWindow = WindowFinder.shared.findTmuxWindow(forTerminalPid: terminalPid, windows: windows) {
            return await focusWindow(id: tmuxWindow.id)
        }

        // Fall back to any non-Claude window
        if let window = WindowFinder.shared.findNonClaudeWindow(forTerminalPid: terminalPid, windows: windows) {
            return await focusWindow(id: window.id)
        }

        return false
    }

    /// Activate the terminal app by PID (brings to front, un-minimizes if needed)
    private func activateTerminalApp(forPid pid: Int) async {
        // Get the process info to find the terminal app name
        let tree = ProcessTreeBuilder.shared.buildTree()
        var appPid = pid

        // Walk up the process tree to find the actual terminal app process
        while appPid > 1 {
            if let info = tree[appPid] {
                let command = info.command
                // Check if this is a terminal app (by checking common terminal names)
                if isTerminalAppBundle(command: command) {
                    break
                }
                appPid = info.ppid
            } else {
                break
            }
        }

        await MainActor.run {
            // Try to find and activate the running application
            if let app = NSRunningApplication(processIdentifier: pid_t(appPid)) {
                app.activate(options: [.activateIgnoringOtherApps, .activateAllWindows])
            } else {
                // Fallback: find terminal app by name from all running apps
                let apps = NSWorkspace.shared.runningApplications
                for app in apps {
                    let name = app.localizedName ?? ""
                    if isTerminalAppBundleName(name) {
                        app.activate(options: [.activateIgnoringOtherApps, .activateAllWindows])
                        break
                    }
                }
            }
        }
    }

    /// Check if command path is a terminal app
    private nonisolated func isTerminalAppBundle(command: String) -> Bool {
        let terminalApps = [
            "Terminal.app",
            "iTerm.app",
            "iTerm2.app",
            "Alacritty.app",
            "kitty.app",
            "WezTerm.app",
            "Hyper.app"
        ]
        return terminalApps.contains { command.contains($0) }
    }

    /// Check if app name is a terminal
    private nonisolated func isTerminalAppBundleName(_ name: String) -> Bool {
        let terminalNames = ["Terminal", "iTerm", "iTerm2", "Alacritty", "kitty", "WezTerm", "Hyper"]
        return terminalNames.contains { name.contains($0) }
    }
}
