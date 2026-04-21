//
//  NotchMenuView.swift
//  ClaudeIsland
//
//  Minimal menu matching Dynamic Island aesthetic
//

import ApplicationServices
import AppKit
import SwiftUI

// MARK: - NotchMenuView

struct NotchMenuView: View {
    @ObservedObject var viewModel: NotchViewModel

    var body: some View {
        // ScrollView so the menu gracefully scrolls when content exceeds the
        // panel height (e.g. both picker rows expanded on a small panel).
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 4) {
                // Back button
                MenuRow(
                    icon: "chevron.left",
                    label: "Back"
                ) {
                    viewModel.toggleMenu()
                }

                Divider()
                    .background(Color.white.opacity(0.08))
                    .padding(.vertical, 4)

                MenuRow(
                    icon: "gearshape",
                    label: "Settings"
                ) {
                    AppDelegate.shared?.showSettingsWindow()
                    viewModel.toggleMenu()
                }

                Divider()
                    .background(Color.white.opacity(0.08))
                    .padding(.vertical, 4)

                MenuRow(
                    icon: "xmark.circle",
                    label: "Quit",
                    isDestructive: true
                ) {
                    NSApplication.shared.terminate(nil)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

// MARK: - Remote SSH Picker Row

struct RemoteSSHPickerRow: View {
    @ObservedObject var tunnelManager: SSHTunnelManager

    @State private var isHovered: Bool = false
    @State private var isExpanded: Bool = false

    @State private var host: String = AppSettings.remoteSSHHost
    @State private var user: String = AppSettings.remoteSSHUser
    @State private var portText: String = String(AppSettings.remoteSSHPort)
    @State private var tunnelPortText: String = String(AppSettings.remoteSSHTunnelPort)

    @State private var isWorking: Bool = false
    @State private var statusText: String? = nil
    @State private var errorText: String? = nil

    @State private var connectTask: Task<Void, Never>? = nil
    @State private var connectedTunnelId: UUID? = nil

    private struct NormalizedSSHIdentity {
        let host: String
        let user: String?
    }

    /// Normalize user/host input so both of these inputs work:
    /// - Host="example.com", User="alice"
    /// - Host="alice@example.com", User="" (user will be inferred)
    private var normalizedSSHIdentity: NormalizedSSHIdentity {
        let hostTrim = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let userTrim = user.trimmingCharacters(in: .whitespacesAndNewlines)

        if userTrim.isEmpty,
           let at = hostTrim.firstIndex(of: "@"),
           hostTrim.firstIndex(of: " ") == nil {
            let u = String(hostTrim[..<at])
            let h = String(hostTrim[hostTrim.index(after: at)...])
            if !u.isEmpty, !h.isEmpty {
                return NormalizedSSHIdentity(host: h, user: u)
            }
        }

        return NormalizedSSHIdentity(host: hostTrim, user: userTrim.isEmpty ? nil : userTrim)
    }

    private var normalizedHost: String { normalizedSSHIdentity.host }
    private var normalizedUser: String { normalizedSSHIdentity.user ?? "" }

    private var sshPort: Int {
        let parsed = Int(portText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 22
        return max(1, min(65535, parsed))
    }

    private var tunnelPort: Int {
        let parsed = Int(tunnelPortText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? SSHTunnelManager.defaultPort
        return max(1, min(65535, parsed))
    }

    private var isConnected: Bool {
        if let id = connectedTunnelId,
           let tunnel = tunnelManager.activeTunnels.first(where: { $0.id == id }) {
            // `process == nil` means we don't have a handle (e.g. restored externally);
            // treat as connected as long as it's still in the active list.
            if tunnel.process?.isRunning != false {
                return true
            }
        }

        return tunnelManager.isTCPTunnelActive(
            host: normalizedHost,
            user: normalizedSSHIdentity.user,
            sshPort: sshPort,
            remotePort: tunnelPort,
            localPort: SSHTunnelManager.defaultPort
        )
    }

    private var isConnecting: Bool {
        connectTask != nil || isWorking
    }

    private var connectionLabel: String {
        if isConnected { return "Connected" }
        if isConnecting { return "Connecting" }
        return AppSettings.remoteSSHEnabled ? "Disconnected" : "Off"
    }

    private var displayedErrorText: String? {
        if let errorText { return errorText }
        guard AppSettings.remoteSSHEnabled, !isConnected else { return nil }
        return tunnelManager.lastErrorMessage
    }

    var body: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "network")
                        .font(.system(size: 12))
                        .foregroundColor(textColor)
                        .frame(width: 16)

                    Text("Remote SSH")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(textColor)

                    Spacer()

                    HStack(spacing: 6) {
                        Circle()
                            .fill(isConnected ? TerminalColors.green : Color.white.opacity(0.3))
                            .frame(width: 6, height: 6)
                        Text(connectionLabel)
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.4))
                    }

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.4))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(isHovered ? Color.white.opacity(0.08) : Color.clear)
                )
            }
            .buttonStyle(.plain)
            .onHover { isHovered = $0 }

            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        LabeledField(label: "Host", text: $host, placeholder: "example.com")
                        LabeledField(label: "User", text: $user, placeholder: "optional")
                        LabeledField(label: "Port", text: $portText, placeholder: "22", width: 64)
                        LabeledField(label: "Tunnel", text: $tunnelPortText, placeholder: String(SSHTunnelManager.defaultPort), width: 72)
                    }

                    HStack(spacing: 8) {
                        SmallActionButton(
                            title: isConnected ? "Disconnect" : (isConnecting ? "Cancel" : "Connect"),
                            isPrimary: !isConnected,
                            isDisabled: (!isConnected && !isConnecting && normalizedHost.isEmpty) || !tunnelManager.isTunnelSupported
                        ) {
                            if isConnecting && !isConnected {
                                Task { await cancelConnectionAttempt() }
                            } else {
                                connectTask?.cancel()
                                connectTask = Task { @MainActor in
                                    await toggleConnection()
                                    connectTask = nil
                                }
                            }
                        }

                        SmallActionButton(
                            title: "Install Hook",
                            isPrimary: false,
                            isDisabled: isWorking || normalizedHost.isEmpty || !tunnelManager.isTunnelSupported
                        ) {
                            Task { await installRemoteHook() }
                        }

                        SmallActionButton(
                            title: "Copy hook cmd",
                            isPrimary: false,
                            isDisabled: false
                        ) {
                            copyToClipboard("python3 ~/.coding-island/hooks/coding-island-remote-hook.py")
                            statusText = "已复制 hook 命令"
                            errorText = nil
                        }

                        SmallActionButton(
                            title: "Copy ssh cmd",
                            isPrimary: false,
                            isDisabled: normalizedHost.isEmpty
                        ) {
                            copyToClipboard(suggestedSSHCommand())
                            statusText = "已复制 ssh 命令"
                            errorText = nil
                        }
                    }

                    if !tunnelManager.isTunnelSupported {
                        Text("未检测到系统 ssh（需要 /usr/bin/ssh）。")
                            .font(.system(size: 11))
                            .foregroundColor(Color(red: 1.0, green: 0.6, blue: 0.6).opacity(0.9))
                    }

                    if let statusText {
                        Text(statusText)
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.5))
                    }

                    if let displayedErrorText {
                        Text(displayedErrorText)
                            .font(.system(size: 11))
                            .foregroundColor(Color(red: 1.0, green: 0.6, blue: 0.6).opacity(0.9))
                    }

                    Text("提示：Connect 会在本机自动建立 ssh 反向转发（remote 127.0.0.1:\(tunnelPort) → local 127.0.0.1:\(SSHTunnelManager.defaultPort)），远端运行 hook 后即可把事件回传到 Coding Island。")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.35))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.leading, 28)
                .padding(.top, 6)
                .onAppear {
                    host = AppSettings.remoteSSHHost
                    user = AppSettings.remoteSSHUser
                    portText = String(AppSettings.remoteSSHPort)
                    tunnelPortText = String(AppSettings.remoteSSHTunnelPort)
                }
            }
        }
    }

    private var textColor: Color {
        .white.opacity(isHovered ? 1.0 : 0.7)
    }

    private func suggestedSSHCommand() -> String {
        let hostString = normalizedSSHIdentity.user == nil ? normalizedHost : "\(normalizedUser)@\(normalizedHost)"
        if sshPort == 22 {
            return "ssh -N -R \(tunnelPort):127.0.0.1:\(SSHTunnelManager.defaultPort) \(hostString)"
        }
        return "ssh -N -p \(sshPort) -R \(tunnelPort):127.0.0.1:\(SSHTunnelManager.defaultPort) \(hostString)"
    }

    private func persistSettings(enabled: Bool) {
        AppSettings.remoteSSHHost = normalizedHost
        AppSettings.remoteSSHUser = normalizedSSHIdentity.user ?? ""
        AppSettings.remoteSSHPort = sshPort
        AppSettings.remoteSSHTunnelPort = tunnelPort
        AppSettings.remoteSSHEnabled = enabled
    }

    @MainActor
    private func cancelConnectionAttempt() async {
        connectTask?.cancel()
        connectTask = nil
        isWorking = false
        errorText = nil
        statusText = "已取消连接"
        connectedTunnelId = nil

        let userValue = normalizedSSHIdentity.user
        persistSettings(enabled: false)
        await tunnelManager.removeTunnels(host: normalizedHost, user: userValue, sshPort: sshPort, remotePort: tunnelPort, localPort: SSHTunnelManager.defaultPort)
    }

    @MainActor
    private func toggleConnection() async {
        errorText = nil
        statusText = nil

        guard tunnelManager.isTunnelSupported else {
            errorText = "系统未找到 ssh：/usr/bin/ssh"
            return
        }

        let userValue = normalizedSSHIdentity.user
        defer {
            isWorking = false
        }

        if isConnected {
            isWorking = true
            persistSettings(enabled: false)
            await tunnelManager.removeTunnels(host: normalizedHost, user: userValue, sshPort: sshPort, remotePort: tunnelPort, localPort: SSHTunnelManager.defaultPort)
            statusText = "已断开"
            connectedTunnelId = nil
            return
        }

        guard !normalizedHost.isEmpty else {
            errorText = "请先填写 Host"
            return
        }

        isWorking = true
        persistSettings(enabled: true)
        await tunnelManager.removeTunnels(host: normalizedHost, user: userValue, sshPort: sshPort, remotePort: tunnelPort, localPort: SSHTunnelManager.defaultPort)

        let tunnel = await tunnelManager.createTCPTunnel(
            host: normalizedHost,
            user: userValue,
            sshPort: sshPort,
            remotePort: tunnelPort,
            localPort: SSHTunnelManager.defaultPort
        )

        if tunnel == nil {
            persistSettings(enabled: false)
            errorText = tunnelManager.lastErrorMessage ?? "连接失败：ssh tunnel 未能建立（请检查 host/user/port，以及 ssh key/agent）。"
            connectedTunnelId = nil
        } else {
            statusText = "已连接：\(normalizedHost)"
            connectedTunnelId = tunnel?.id
        }
    }

    private func installRemoteHook() async {
        errorText = nil
        statusText = nil

        guard tunnelManager.isTunnelSupported else {
            errorText = "系统未找到 ssh：/usr/bin/ssh"
            return
        }

        guard !normalizedHost.isEmpty else {
            errorText = "请先填写 Host"
            return
        }

        isWorking = true
        let userValue = normalizedSSHIdentity.user
        let result = await tunnelManager.installRemoteHook(
            host: normalizedHost,
            user: userValue,
            sshPort: sshPort,
            tcpPort: tunnelPort,
            localPort: SSHTunnelManager.defaultPort
        )
        isWorking = false

        switch result {
        case .success:
            statusText = "已安装远端 hook：~/.coding-island/hooks/coding-island-remote-hook.py"
        case .failure(let error):
            errorText = "安装失败：\(error.localizedDescription)"
        }
    }

    private func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

private struct LabeledField: View {
    let label: String
    @Binding var text: String
    let placeholder: String
    var width: CGFloat? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.white.opacity(0.45))

            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.white.opacity(0.85))
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .frame(width: width)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.white.opacity(0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
        }
    }
}

private struct SmallActionButton: View {
    let title: String
    let isPrimary: Bool
    let isDisabled: Bool
    let action: () -> Void

    @State private var isHovered: Bool = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(foreground)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(background)
                )
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .onHover { isHovered = $0 }
        .opacity(isDisabled ? 0.5 : 1.0)
    }

    private var foreground: Color {
        if isPrimary {
            return .black
        }
        return .white.opacity(isHovered ? 1.0 : 0.8)
    }

    private var background: Color {
        if isPrimary {
            return isHovered ? Color.white.opacity(0.95) : Color.white
        }
        return isHovered ? Color.white.opacity(0.10) : Color.white.opacity(0.06)
    }
}

// MARK: - Update Row

struct UpdateRow: View {
    @ObservedObject var updateManager: UpdateManager
    @State private var isHovered = false
    @State private var isSpinning = false

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "v\(version) (\(build))"
    }

    var body: some View {
        Button {
            handleTap()
        } label: {
            HStack(spacing: 10) {
                // Icon
                ZStack {
                    if case .installing = updateManager.state {
                        Image(systemName: "gear")
                            .font(.system(size: 12))
                            .foregroundColor(TerminalColors.blue)
                            .rotationEffect(.degrees(isSpinning ? 360 : 0))
                            .animation(.linear(duration: 1).repeatForever(autoreverses: false), value: isSpinning)
                            .onAppear { isSpinning = true }
                    } else {
                        Image(systemName: icon)
                            .font(.system(size: 12))
                            .foregroundColor(iconColor)
                    }
                }
                .frame(width: 16)

                // Label
                Text(label)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(labelColor)

                Spacer()

                // Right side: progress or status
                rightContent
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isHovered && isInteractive ? Color.white.opacity(0.08) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .disabled(!isInteractive)
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.2), value: updateManager.state)
    }

    // MARK: - Right Content

    @ViewBuilder
    private var rightContent: some View {
        switch updateManager.state {
        case .idle:
            Text(appVersion)
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.4))

        case .upToDate:
            HStack(spacing: 6) {
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(TerminalColors.green)
                Text("Up to date")
                    .font(.system(size: 11))
                    .foregroundColor(TerminalColors.green)
            }

        case .checking, .installing:
            ProgressView()
                .scaleEffect(0.5)
                .frame(width: 12, height: 12)

        case .found(let version, _):
            HStack(spacing: 6) {
                Circle()
                    .fill(TerminalColors.green)
                    .frame(width: 6, height: 6)
                Text("v\(version)")
                    .font(.system(size: 11))
                    .foregroundColor(TerminalColors.green)
            }

        case .downloading(let progress):
            HStack(spacing: 8) {
                ProgressView(value: progress)
                    .frame(width: 60)
                    .tint(TerminalColors.blue)
                Text("\(Int(progress * 100))%")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(TerminalColors.blue)
                    .frame(width: 32, alignment: .trailing)
            }

        case .extracting(let progress):
            HStack(spacing: 8) {
                ProgressView(value: progress)
                    .frame(width: 60)
                    .tint(TerminalColors.amber)
                Text("\(Int(progress * 100))%")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(TerminalColors.amber)
                    .frame(width: 32, alignment: .trailing)
            }

        case .readyToInstall(let version):
            HStack(spacing: 6) {
                Circle()
                    .fill(TerminalColors.green)
                    .frame(width: 6, height: 6)
                Text("v\(version)")
                    .font(.system(size: 11))
                    .foregroundColor(TerminalColors.green)
            }

        case .error:
            Text("Retry")
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.5))
        }
    }

    // MARK: - Computed Properties

    private var icon: String {
        switch updateManager.state {
        case .idle:
            return "arrow.down.circle"
        case .checking:
            return "arrow.down.circle"
        case .upToDate:
            return "checkmark.circle.fill"
        case .found:
            return "arrow.down.circle.fill"
        case .downloading:
            return "arrow.down.circle"
        case .extracting:
            return "doc.zipper"
        case .readyToInstall:
            return "checkmark.circle.fill"
        case .installing:
            return "gear"
        case .error:
            return "exclamationmark.circle"
        }
    }

    private var iconColor: Color {
        switch updateManager.state {
        case .idle:
            return .white.opacity(isHovered ? 1.0 : 0.7)
        case .checking:
            return .white.opacity(0.7)
        case .upToDate:
            return TerminalColors.green
        case .found, .readyToInstall:
            return TerminalColors.green
        case .downloading:
            return TerminalColors.blue
        case .extracting:
            return TerminalColors.amber
        case .installing:
            return TerminalColors.blue
        case .error:
            return Color(red: 1.0, green: 0.4, blue: 0.4)
        }
    }

    private var label: String {
        switch updateManager.state {
        case .idle:
            return "Check for Updates"
        case .checking:
            return "Checking..."
        case .upToDate:
            return "Check for Updates"
        case .found:
            return "Download Update"
        case .downloading:
            return "Downloading..."
        case .extracting:
            return "Extracting..."
        case .readyToInstall:
            return "Install & Relaunch"
        case .installing:
            return "Installing..."
        case .error:
            return "Update failed"
        }
    }

    private var labelColor: Color {
        switch updateManager.state {
        case .idle, .upToDate:
            return .white.opacity(isHovered ? 1.0 : 0.7)
        case .checking, .downloading, .extracting, .installing:
            return .white.opacity(0.9)
        case .found, .readyToInstall:
            return TerminalColors.green
        case .error:
            return Color(red: 1.0, green: 0.4, blue: 0.4)
        }
    }

    private var isInteractive: Bool {
        switch updateManager.state {
        case .idle, .upToDate, .found, .readyToInstall, .error:
            return true
        case .checking, .downloading, .extracting, .installing:
            return false
        }
    }

    // MARK: - Actions

    private func handleTap() {
        switch updateManager.state {
        case .idle, .upToDate, .error:
            updateManager.checkForUpdates()
        case .found:
            updateManager.downloadAndInstall()
        case .readyToInstall:
            updateManager.installAndRelaunch()
        default:
            break
        }
    }
}

// MARK: - Accessibility Permission Row

struct AccessibilityRow: View {
    let isEnabled: Bool

    @State private var isHovered = false
    @State private var refreshTrigger = false

    private var currentlyEnabled: Bool {
        // Re-check on each render when refreshTrigger changes
        _ = refreshTrigger
        return AXIsProcessTrusted()
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "hand.raised")
                .font(.system(size: 12))
                .foregroundColor(textColor)
                .frame(width: 16)

            Text("Accessibility")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(textColor)

            Spacer()

            if currentlyEnabled {
                Circle()
                    .fill(TerminalColors.green)
                    .frame(width: 6, height: 6)

                Text("On")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.4))
            } else {
                Button(action: openAccessibilitySettings) {
                    Text("Enable")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.black)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(Color.white)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isHovered ? Color.white.opacity(0.08) : Color.clear)
        )
        .onHover { isHovered = $0 }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshTrigger.toggle()
        }
    }

    private var textColor: Color {
        .white.opacity(isHovered ? 1.0 : 0.7)
    }

    private func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}

struct MenuRow: View {
    let icon: String
    let label: String
    var isDestructive: Bool = false
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundColor(textColor)
                    .frame(width: 16)

                Text(label)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(textColor)

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isHovered ? Color.white.opacity(0.08) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }

    private var textColor: Color {
        if isDestructive {
            return Color(red: 1.0, green: 0.4, blue: 0.4)
        }
        return .white.opacity(isHovered ? 1.0 : 0.7)
    }
}

struct MenuToggleRow: View {
    let icon: String
    let label: String
    let isOn: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundColor(textColor)
                    .frame(width: 16)

                Text(label)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(textColor)

                Spacer()

                Circle()
                    .fill(isOn ? TerminalColors.green : Color.white.opacity(0.3))
                    .frame(width: 6, height: 6)

                Text(isOn ? "On" : "Off")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.4))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isHovered ? Color.white.opacity(0.08) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }

    private var textColor: Color {
        .white.opacity(isHovered ? 1.0 : 0.7)
    }
}
