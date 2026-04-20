import AppKit
import Combine
import IOKit
import Mixpanel
import Sparkle
import SwiftUI
import ServiceManagement

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowManager: WindowManager?
    private var screenObserver: ScreenObserver?
    private var updateCheckTimer: Timer?
    private var settingsWindowController: SettingsWindowController?

    static var shared: AppDelegate?
    let updater: SPUUpdater
    private let userDriver: NotchUserDriver

    var windowController: NotchWindowController? {
        windowManager?.windowController
    }

    override init() {
        userDriver = NotchUserDriver()
        updater = SPUUpdater(
            hostBundle: Bundle.main,
            applicationBundle: Bundle.main,
            userDriver: userDriver,
            delegate: nil
        )
        super.init()
        AppDelegate.shared = self

        do {
            try updater.start()
        } catch {
            print("Failed to start Sparkle updater: \(error)")
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if !ensureSingleInstance() {
            NSApplication.shared.terminate(nil)
            return
        }

        Mixpanel.initialize(token: "49814c1436104ed108f3fc4735228496")

        let distinctId = getOrCreateDistinctId()
        Mixpanel.mainInstance().identify(distinctId: distinctId)

        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
        let osVersion = Foundation.ProcessInfo.processInfo.operatingSystemVersionString

        Mixpanel.mainInstance().registerSuperProperties([
            "app_version": version,
            "build_number": build,
            "macos_version": osVersion
        ])

        fetchAndRegisterClaudeVersion()

        Mixpanel.mainInstance().people.set(properties: [
            "app_version": version,
            "build_number": build,
            "macos_version": osVersion
        ])

        Mixpanel.mainInstance().track(event: "App Launched")
        Mixpanel.mainInstance().flush()

        HookInstaller.installIfNeeded()

        // Start all available providers (including Coco/Trae CLI)
        Task {
            await ProviderRegistry.shared.startAll()
        }

        // Auto-connect Remote SSH tunnel if configured.
        Task {
            let host = AppSettings.remoteSSHHost
            guard AppSettings.remoteSSHEnabled,
                  !host.isEmpty,
                  SSHTunnelManager.shared.isTunnelSupported
            else { return }

            let user = AppSettings.remoteSSHUser.isEmpty ? nil : AppSettings.remoteSSHUser
            let port = AppSettings.remoteSSHPort
            let tunnelPort = AppSettings.remoteSSHTunnelPort
            await SSHTunnelManager.shared.removeTunnels(host: host, user: user, sshPort: port, remotePort: tunnelPort, localPort: SSHTunnelManager.defaultPort)
            _ = await SSHTunnelManager.shared.createTCPTunnel(host: host, user: user, sshPort: port, remotePort: tunnelPort, localPort: SSHTunnelManager.defaultPort)
        }

        NSApplication.shared.setActivationPolicy(.accessory)

        windowManager = WindowManager()
        _ = windowManager?.setupNotchWindow()

        screenObserver = ScreenObserver { [weak self] in
            self?.handleScreenChange()
        }

        if updater.canCheckForUpdates {
            updater.checkForUpdates()
        }

        updateCheckTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            guard let updater = self?.updater, updater.canCheckForUpdates else { return }
            updater.checkForUpdates()
        }
    }

    // MARK: - Settings Window

    func showSettingsWindow(section: SettingsSection? = nil) {
        NSApp.activate(ignoringOtherApps: true)

        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController(initialSection: section)
        }

        settingsWindowController?.show(section: section)
    }

    private func handleScreenChange() {
        _ = windowManager?.setupNotchWindow()
    }

    func applicationWillTerminate(_ notification: Notification) {
        Mixpanel.mainInstance().flush()
        updateCheckTimer?.invalidate()
        screenObserver = nil
    }

    private func getOrCreateDistinctId() -> String {
        let key = "mixpanel_distinct_id"

        if let existingId = UserDefaults.standard.string(forKey: key) {
            return existingId
        }

        let platformExpert = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("IOPlatformExpertDevice")
        )
        defer { IOObjectRelease(platformExpert) }

        if let uuid = IORegistryEntryCreateCFProperty(
            platformExpert,
            kIOPlatformUUIDKey as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() as? String {
            UserDefaults.standard.set(uuid, forKey: key)
            return uuid
        }

        let newId = UUID().uuidString
        UserDefaults.standard.set(newId, forKey: key)
        return newId
    }

    private func fetchAndRegisterClaudeVersion() {
        let claudeProjectsDir = ClaudePaths.projectsDir

        guard let projectDirs = try? FileManager.default.contentsOfDirectory(
            at: claudeProjectsDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: .skipsHiddenFiles
        ) else { return }

        var latestFile: URL?
        var latestDate: Date?

        for projectDir in projectDirs {
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: projectDir,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: .skipsHiddenFiles
            ) else { continue }

            for file in files where file.pathExtension == "jsonl" && !file.lastPathComponent.hasPrefix("agent-") {
                if let attrs = try? file.resourceValues(forKeys: [.contentModificationDateKey]),
                   let modDate = attrs.contentModificationDate {
                    if latestDate == nil || modDate > latestDate! {
                        latestDate = modDate
                        latestFile = file
                    }
                }
            }
        }

        guard let jsonlFile = latestFile,
              let handle = FileHandle(forReadingAtPath: jsonlFile.path) else { return }
        defer { try? handle.close() }

        let data = handle.readData(ofLength: 8192)
        guard let content = String(data: data, encoding: .utf8) else { return }

        for line in content.components(separatedBy: .newlines) where !line.isEmpty {
            guard let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let version = json["version"] as? String else { continue }

            Mixpanel.mainInstance().registerSuperProperties(["claude_code_version": version])
            Mixpanel.mainInstance().people.set(properties: ["claude_code_version": version])
            return
        }
    }

    private func ensureSingleInstance() -> Bool {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.farouqaldori.ClaudeIsland"
        let runningApps = NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier == bundleID
        }

        if runningApps.count > 1 {
            if let existingApp = runningApps.first(where: { $0.processIdentifier != getpid() }) {
                existingApp.activate()
            }
            return false
        }

        return true
    }
}

// MARK: - Settings Window Controller

@MainActor
final class SettingsWindowController: NSWindowController {
    private let model: SettingsWindowModel

    init(initialSection: SettingsSection?) {
        self.model = SettingsWindowModel(initialSection: initialSection)

        let root = SettingsWindowRootView(model: model)
        let hosting = NSHostingController(rootView: root)

        let window = NSWindow(contentViewController: hosting)
        window.title = "Settings"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.titleVisibility = .visible
        window.setContentSize(NSSize(width: 860, height: 560))
        window.minSize = NSSize(width: 760, height: 520)
        window.isReleasedWhenClosed = false
        window.center()

        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(section: SettingsSection?) {
        if let section {
            model.selection = section
        }
        window?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - Settings Window Model

@MainActor
final class SettingsWindowModel: ObservableObject {
    @Published var selection: SettingsSection?

    init(initialSection: SettingsSection?) {
        self.selection = initialSection ?? .appearance
    }
}

// MARK: - Settings Sections

enum SettingsSection: String, CaseIterable, Identifiable {
    case appearance
    case notifications
    case paths
    case remote
    case system
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .appearance: return "Appearance"
        case .notifications: return "Notifications"
        case .paths: return "Paths"
        case .remote: return "Remote"
        case .system: return "System"
        case .about: return "About"
        }
    }

    var systemImage: String {
        switch self {
        case .appearance: return "paintbrush"
        case .notifications: return "bell"
        case .paths: return "folder"
        case .remote: return "network"
        case .system: return "gearshape"
        case .about: return "info.circle"
        }
    }
}

// MARK: - Settings Window Views

private struct SettingsWindowRootView: View {
    @ObservedObject var model: SettingsWindowModel

    @ObservedObject private var updateManager = UpdateManager.shared
    @ObservedObject private var screenSelector = ScreenSelector.shared
    @ObservedObject private var sshTunnelManager = SSHTunnelManager.shared

    var body: some View {
        NavigationSplitView {
            List {
                ForEach(SettingsSection.allCases) { section in
                    SettingsSidebarRow(
                        section: section,
                        isSelected: model.selection == section
                    ) {
                        model.selection = section
                    }
                }
            }
            .listStyle(.sidebar)
        } detail: {
            SettingsDetailView(
                selection: model.selection,
                updateManager: updateManager,
                screenSelector: screenSelector,
                sshTunnelManager: sshTunnelManager
            )
        }
        .frame(minWidth: 760, minHeight: 520)
    }
}

private struct SettingsSidebarRow: View {
    let section: SettingsSection
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(section.title, systemImage: section.systemImage)
                .foregroundStyle(isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets(top: 6, leading: 10, bottom: 6, trailing: 10))
        .listRowBackground(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
        )
    }
}

private struct SettingsDetailView: View {
    let selection: SettingsSection?
    @ObservedObject var updateManager: UpdateManager
    @ObservedObject var screenSelector: ScreenSelector
    @ObservedObject var sshTunnelManager: SSHTunnelManager

    var body: some View {
        Group {
            switch selection {
            case .appearance:
                AppearanceSettingsView(screenSelector: screenSelector)
            case .notifications:
                NotificationSettingsView()
            case .paths:
                PathsSettingsView()
            case .remote:
                RemoteSettingsView(tunnelManager: sshTunnelManager)
            case .system:
                SystemSettingsView()
            case .about:
                AboutSettingsView(updateManager: updateManager)
            case .none:
                SettingsEmptyState()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct SettingsEmptyState: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Select a category")
                .font(.system(size: 16, weight: .semibold))
            Text("Choose an item from the sidebar to edit settings.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .padding(20)
    }
}

// MARK: - System Appearance Friendly Settings Pages

private struct SettingsPage<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 16) {
                Text(title)
                    .font(.system(size: 20, weight: .semibold))

                content
            }
            .padding(20)
            .frame(maxWidth: 760, alignment: .topLeading)
        }
    }
}

private struct AppearanceSettingsView: View {
    @ObservedObject var screenSelector: ScreenSelector

    @State private var mode: ScreenSelectionMode = .automatic
    @State private var selectedIdentifier: ScreenIdentifier? = nil

    var body: some View {
        SettingsPage(title: "Appearance") {
            GroupBox("Screen") {
                VStack(alignment: .leading, spacing: 12) {
                    LabeledContent("Mode") {
                        Picker("", selection: $mode) {
                            Text("Automatic").tag(ScreenSelectionMode.automatic)
                            Text("Specific").tag(ScreenSelectionMode.specificScreen)
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(width: 260)
                    }

                    if mode == .specificScreen {
                        LabeledContent("Display") {
                            Picker("", selection: Binding(
                                get: { selectedIdentifier },
                                set: { newValue in
                                    selectedIdentifier = newValue
                                    applyScreenSelection()
                                }
                            )) {
                                ForEach(screenSelector.availableScreens, id: \.self) { screen in
                                    let id = ScreenIdentifier(screen: screen)
                                    Text(screen.localizedName).tag(Optional(id))
                                }
                            }
                            .labelsHidden()
                            .frame(width: 320)
                        }
                    }
                }
                .padding(.top, 4)
            }
        }
        .onAppear {
            screenSelector.refreshScreens()
            mode = screenSelector.selectionMode
            selectedIdentifier = screenSelector.selectedScreen.map { ScreenIdentifier(screen: $0) }
        }
        .onChange(of: mode) { _, _ in
            applyScreenSelection()
        }
    }

    private func applyScreenSelection() {
        switch mode {
        case .automatic:
            screenSelector.selectAutomatic()
            triggerWindowRecreation()
        case .specificScreen:
            screenSelector.refreshScreens()
            if let id = selectedIdentifier,
               let screen = screenSelector.availableScreens.first(where: { id.matches($0) }) {
                screenSelector.selectScreen(screen)
                triggerWindowRecreation()
            }
        }
    }

    private func triggerWindowRecreation() {
        NotificationCenter.default.post(
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }
}

private struct NotificationSettingsView: View {
    @State private var selectedSound: NotificationSound = AppSettings.notificationSound

    var body: some View {
        SettingsPage(title: "Notifications") {
            GroupBox("Notification Sound") {
                VStack(alignment: .leading, spacing: 12) {
                    LabeledContent("Sound") {
                        Picker("", selection: $selectedSound) {
                            ForEach(NotificationSound.allCases, id: \.self) { sound in
                                Text(sound.rawValue).tag(sound)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 220)
                    }

                    Button("Preview") {
                        if let name = selectedSound.soundName {
                            NSSound(named: name)?.play()
                        }
                    }
                    .disabled(selectedSound.soundName == nil)
                }
                .padding(.top, 4)
            }
        }
        .onAppear {
            selectedSound = AppSettings.notificationSound
        }
        .onChange(of: selectedSound) { _, newValue in
            AppSettings.notificationSound = newValue
        }
    }
}

private struct PathsSettingsView: View {
    private enum Mode: String, CaseIterable, Identifiable {
        case auto
        case custom
        var id: String { rawValue }
    }

    @State private var mode: Mode = .auto
    @State private var customPath: String = ""

    var body: some View {
        SettingsPage(title: "Paths") {
            GroupBox("Claude Directory") {
                VStack(alignment: .leading, spacing: 12) {
                    LabeledContent("Mode") {
                        Picker("", selection: $mode) {
                            Text("Auto-detect").tag(Mode.auto)
                            Text("Custom").tag(Mode.custom)
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(width: 260)
                    }

                    if mode == .custom {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Folder")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.secondary)

                            HStack(spacing: 10) {
                                TextField("", text: $customPath)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 420)

                                Button("Choose…") {
                                    chooseFolder()
                                }
                            }
                        }
                    }

                    LabeledContent("Resolved") {
                        Text(shortenedPath(ClaudePaths.claudeDir.path))
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                .padding(.top, 4)
            }
        }
        .onAppear {
            let current = AppSettings.claudeDirectoryName
            if !current.isEmpty && current != ".claude" {
                mode = .custom
                customPath = current
            } else {
                mode = .auto
                customPath = ""
            }
        }
        .onChange(of: mode) { _, newMode in
            if newMode == .auto {
                applyAutoDetect()
            } else if customPath.isEmpty {
                // Give the user a sensible starting point.
                customPath = ClaudePaths.claudeDir.path
            }
        }
        .onChange(of: customPath) { _, newValue in
            guard mode == .custom else { return }
            applyCustomPath(newValue)
        }
    }

    private func applyAutoDetect() {
        AppSettings.claudeDirectoryName = ".claude"
        ClaudePaths.invalidateCache()
        HookInstaller.installIfNeeded()
    }

    private func applyCustomPath(_ path: String) {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        AppSettings.claudeDirectoryName = trimmed
        ClaudePaths.invalidateCache()
        HookInstaller.installIfNeeded()
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose Claude Config Directory"
        panel.message = "Select the folder Claude Code uses (typically ~/.claude or ~/.config/claude)."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.canCreateDirectories = false
        panel.directoryURL = ClaudePaths.claudeDir

        if panel.runModal() == .OK, let url = panel.url {
            mode = .custom
            customPath = url.path
            applyCustomPath(url.path)
        }
    }

    private func shortenedPath(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
}

private struct RemoteSettingsView: View {
    @ObservedObject var tunnelManager: SSHTunnelManager

    @State private var enabled: Bool = AppSettings.remoteSSHEnabled
    @State private var host: String = AppSettings.remoteSSHHost
    @State private var user: String = AppSettings.remoteSSHUser
    @State private var sshPort: Int = AppSettings.remoteSSHPort
    @State private var remotePort: Int = AppSettings.remoteSSHTunnelPort

    @State private var isWorking: Bool = false
    @State private var statusText: String? = nil
    @State private var errorText: String? = nil

    private struct NormalizedIdentity {
        let host: String
        let user: String?
    }

    private var normalized: NormalizedIdentity {
        let hostTrim = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let userTrim = user.trimmingCharacters(in: .whitespacesAndNewlines)

        if userTrim.isEmpty,
           let at = hostTrim.firstIndex(of: "@"),
           hostTrim.firstIndex(of: " ") == nil {
            let u = String(hostTrim[..<at])
            let h = String(hostTrim[hostTrim.index(after: at)...])
            if !u.isEmpty, !h.isEmpty {
                return NormalizedIdentity(host: h, user: u)
            }
        }

        return NormalizedIdentity(host: hostTrim, user: userTrim.isEmpty ? nil : userTrim)
    }

    private var isConnected: Bool {
        guard !normalized.host.isEmpty else { return false }
        return tunnelManager.isTCPTunnelActive(
            host: normalized.host,
            user: normalized.user,
            sshPort: sshPort,
            remotePort: remotePort,
            localPort: SSHTunnelManager.defaultPort
        )
    }

    var body: some View {
        SettingsPage(title: "Remote") {
            GroupBox("Remote SSH") {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 10) {
                    GridRow {
                        Text("Enabled")
                        Toggle("", isOn: $enabled)
                            .labelsHidden()
                    }

                    GridRow {
                        Text("Host")
                        TextField("example.com", text: $host)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 320)
                    }

                    GridRow {
                        Text("User")
                        TextField("(optional)", text: $user)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 220)
                    }

                    GridRow {
                        Text("SSH Port")
                        TextField("", value: $sshPort, formatter: SettingsNumberFormatters.port)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 120)
                    }

                    GridRow {
                        Text("Remote Port")
                        TextField("", value: $remotePort, formatter: SettingsNumberFormatters.port)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 120)
                            .help("Remote listen port for ssh -R <remotePort>:127.0.0.1:<localPort>.")
                    }
                }
                .padding(.top, 4)
            }

            GroupBox("Connection") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(isConnected ? "Connected" : "Disconnected")
                            .foregroundStyle(isConnected ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
                        Spacer()
                        if isWorking {
                            ProgressView().controlSize(.small)
                        }
                    }

                    HStack(spacing: 10) {
                        Button(isConnected ? "Disconnect" : "Connect") {
                            Task { await toggleConnection() }
                        }
                        .disabled(isWorking || (!enabled && !isConnected) || normalized.host.isEmpty)

                        Button("Install Remote Hook") {
                            Task { await installRemoteHook() }
                        }
                        .disabled(isWorking || normalized.host.isEmpty)
                    }

                    if let statusText {
                        Text(statusText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if let error = displayedErrorText {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                }
                .padding(.top, 4)
            }
        }
        .onAppear {
            enabled = AppSettings.remoteSSHEnabled
            host = AppSettings.remoteSSHHost
            user = AppSettings.remoteSSHUser
            sshPort = AppSettings.remoteSSHPort
            remotePort = AppSettings.remoteSSHTunnelPort
        }
        .onChange(of: enabled) { _, newValue in
            AppSettings.remoteSSHEnabled = newValue
            if !newValue {
                Task { await disconnect() }
            }
        }
        .onChange(of: host) { _, newValue in
            AppSettings.remoteSSHHost = newValue
        }
        .onChange(of: user) { _, newValue in
            AppSettings.remoteSSHUser = newValue
        }
        .onChange(of: sshPort) { _, newValue in
            AppSettings.remoteSSHPort = newValue
        }
        .onChange(of: remotePort) { _, newValue in
            AppSettings.remoteSSHTunnelPort = newValue
        }
    }

    private var displayedErrorText: String? {
        if let errorText { return errorText }
        if enabled && !isConnected {
            return tunnelManager.lastErrorMessage
        }
        return nil
    }

    private func toggleConnection() async {
        errorText = nil
        statusText = nil
        if isConnected {
            await disconnect()
        } else {
            await connect()
        }
    }

    private func connect() async {
        let h = normalized.host
        guard !h.isEmpty else { return }

        isWorking = true
        defer { isWorking = false }

        statusText = "Connecting…"
        let u = normalized.user
        await tunnelManager.removeTunnels(host: h, user: u, sshPort: sshPort, remotePort: remotePort, localPort: SSHTunnelManager.defaultPort)
        let tunnel = await tunnelManager.createTCPTunnel(host: h, user: u, sshPort: sshPort, remotePort: remotePort, localPort: SSHTunnelManager.defaultPort)
        if tunnel != nil {
            statusText = "Connected"
        } else {
            statusText = "Failed to connect"
            errorText = tunnelManager.lastErrorMessage
        }
    }

    private func disconnect() async {
        let h = normalized.host
        guard !h.isEmpty else { return }

        isWorking = true
        defer { isWorking = false }

        statusText = "Disconnecting…"
        await tunnelManager.removeTunnels(host: h, user: normalized.user, sshPort: sshPort, remotePort: remotePort, localPort: SSHTunnelManager.defaultPort)
        statusText = "Disconnected"
    }

    private func installRemoteHook() async {
        let h = normalized.host
        guard !h.isEmpty else { return }

        isWorking = true
        defer { isWorking = false }

        statusText = "Installing remote hook…"
        errorText = nil

        let result = await tunnelManager.installRemoteHook(
            host: h,
            user: normalized.user,
            sshPort: sshPort,
            tcpPort: remotePort,
            localPort: SSHTunnelManager.defaultPort
        )

        switch result {
        case .success:
            statusText = "Remote hook installed"
        case .failure(let error):
            statusText = "Failed to install remote hook"
            errorText = error.localizedDescription
        }
    }
}

private enum SettingsNumberFormatters {
    static let port: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .none
        f.allowsFloats = false
        f.minimum = 1
        f.maximum = 65535
        return f
    }()
}

private struct SystemSettingsView: View {
    @State private var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled
    @State private var hooksInstalled: Bool = HookInstaller.isInstalled()

    var body: some View {
        SettingsPage(title: "System") {
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Launch at Login", isOn: $launchAtLogin)
                        .onChange(of: launchAtLogin) { _, newValue in
                            do {
                                if newValue {
                                    try SMAppService.mainApp.register()
                                } else {
                                    try SMAppService.mainApp.unregister()
                                }
                            } catch {
                                // Revert on failure
                                launchAtLogin = SMAppService.mainApp.status == .enabled
                                print("Failed to toggle launch at login: \(error)")
                            }
                        }

                    Toggle("Hooks", isOn: $hooksInstalled)
                        .onChange(of: hooksInstalled) { _, newValue in
                            if newValue {
                                HookInstaller.installIfNeeded()
                            } else {
                                HookInstaller.uninstall()
                            }
                            hooksInstalled = HookInstaller.isInstalled()
                        }
                }
            }

            GroupBox("Accessibility") {
                HStack {
                    Text(AXIsProcessTrusted() ? "Enabled" : "Disabled")
                        .foregroundStyle(AXIsProcessTrusted() ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
                    Spacer()
                    if !AXIsProcessTrusted() {
                        Button("Open System Settings") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    }
                }
                .padding(.top, 4)
            }
        }
    }
}

private struct AboutSettingsView: View {
    @ObservedObject var updateManager: UpdateManager

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "v\(version) (\(build))"
    }

    var body: some View {
        SettingsPage(title: "About") {
            GroupBox {
                LabeledContent("Version", value: appVersion)
            }

            GroupBox("Updates") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(updateStatusText)
                            .foregroundStyle(.secondary)
                        Spacer()
                        if updateManager.state.isActive {
                            ProgressView().controlSize(.small)
                        }
                    }
                    updateActions
                }
                .padding(.top, 4)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    Button("Star on GitHub") {
                        if let url = URL(string: "https://github.com/farouqaldori/claude-island") {
                            NSWorkspace.shared.open(url)
                        }
                    }

                    Button("Quit") {
                        NSApplication.shared.terminate(nil)
                    }
                    .foregroundStyle(.red)
                }
            }
        }
    }

    private var updateStatusText: String {
        switch updateManager.state {
        case .idle:
            return "Idle"
        case .checking:
            return "Checking…"
        case .upToDate:
            return "Up to date"
        case .found(let version, _):
            return "Update found: v\(version)"
        case .downloading(let progress):
            return "Downloading… \(Int(progress * 100))%"
        case .extracting(let progress):
            return "Extracting… \(Int(progress * 100))%"
        case .readyToInstall(let version):
            return "Ready to install: v\(version)"
        case .installing:
            return "Installing…"
        case .error(let message):
            return "Error: \(message)"
        }
    }

    @ViewBuilder
    private var updateActions: some View {
        switch updateManager.state {
        case .idle, .upToDate, .error:
            Button("Check for Updates") { updateManager.checkForUpdates() }
        case .found:
            Button("Download and Install") { updateManager.downloadAndInstall() }
            Button("Not Now") { updateManager.dismissUpdate() }
        case .readyToInstall:
            Button("Install and Relaunch") { updateManager.installAndRelaunch() }
        case .downloading:
            Button("Cancel Download") { updateManager.cancelDownload() }
        default:
            EmptyView()
        }
    }
}
