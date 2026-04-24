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

        // Ensure shared directory and migrate from old locations
        IslandPaths.ensureDirectoriesExist()
        IslandPaths.cleanupLegacyHooks()
        HookInstaller.cleanupLegacySettingsEntries()

        HookInstaller.installIfNeeded()

        // Start Token Statistics Manager
        _ = TokenStatisticsManager.shared

        // Start session monitoring globally
        ClaudeSessionMonitor.shared.startMonitoring()

        // Start all available providers (including Coco/Trae CLI)
        Task {
            await ProviderRegistry.shared.startAll()
        }

        // Auto-connect Remote SSH tunnel if configured.
        Task {
            guard SSHTunnelManager.shared.isTunnelSupported else { return }

            for remote in AppSettings.remoteMachines where remote.isEnabled {
                let normalized = normalizeRemoteSSHIdentity(host: remote.host, user: remote.user)
                guard !normalized.host.isEmpty else { continue }

                await SSHTunnelManager.shared.removeTunnels(
                    host: normalized.host,
                    user: normalized.user,
                    sshPort: remote.sshPort,
                    remotePort: remote.remotePort,
                    localPort: SSHTunnelManager.defaultPort
                )

                _ = await SSHTunnelManager.shared.createTCPTunnel(
                    host: normalized.host,
                    user: normalized.user,
                    sshPort: remote.sshPort,
                    remotePort: remote.remotePort,
                    localPort: SSHTunnelManager.defaultPort
                )
            }
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
        let bundleID = Bundle.main.bundleIdentifier ?? "com.celestial.CodingIsland"
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
        // Match macOS Settings: no title text, content extends into titlebar,
        // and traffic lights sit over the sidebar area.
        window.title = ""
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.styleMask.insert(.fullSizeContentView)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
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
    case systems
    case hooks
    case tokenUsage
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .appearance: return "Appearance"
        case .notifications: return "Notifications"
        case .systems: return "Systems"
        case .hooks: return "Hooks"
        case .tokenUsage: return "Token Usage"
        case .about: return "About"
        }
    }

    var systemImage: String {
        switch self {
        case .appearance: return "paintbrush"
        case .notifications: return "bell"
        case .systems: return "server.rack"
        case .hooks: return "point.3.connected.trianglepath.dotted"
        case .tokenUsage: return "chart.bar"
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
        ZStack {
            // Content layer background. Keep Liquid Glass/material effects reserved
            // for the navigation layer (sidebar) instead of the entire window.
            Rectangle().fill(SettingsStyle.pageBackground)

            HStack(spacing: 0) {
                SettingsSidebarView(selection: $model.selection)
                    .frame(width: SettingsStyle.sidebarWidth)
                    // Sidebar acts as the navigation layer.
                    .background(.regularMaterial)
                    // Prefer depth cues (shadow) over a hard divider line.
                    .compositingGroup()
                    .shadow(color: Color.black.opacity(0.10), radius: 10, x: 4, y: 0)

                SettingsDetailView(
                    selection: model.selection,
                    updateManager: updateManager,
                    screenSelector: screenSelector,
                    sshTunnelManager: sshTunnelManager
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // Content stays in the content layer and inherits the page background.
                .background(Color.clear)
            }
        }
        .frame(minWidth: 760, minHeight: 520)
    }
}

private struct SettingsSidebarView: View {
    @Binding var selection: SettingsSection?

    private var generalSections: [SettingsSection] {
        [.appearance, .notifications, .systems, .hooks, .tokenUsage]
    }

    private var infoSections: [SettingsSection] {
        [.about]
    }

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 10) {
                // Leave room for the traffic lights when using fullSizeContentView.
                Spacer().frame(height: SettingsStyle.titlebarContentInset)

                SettingsSidebarSectionHeader(title: "General")
                VStack(spacing: 6) {
                    ForEach(generalSections) { section in
                        SettingsSidebarRow(
                            section: section,
                            isSelected: selection == section
                        ) {
                            withAnimation(.easeInOut(duration: 0.16)) {
                                selection = section
                            }
                        }
                    }
                }

                Spacer().frame(height: 10)

                SettingsSidebarSectionHeader(title: "Info")
                VStack(spacing: 6) {
                    ForEach(infoSections) { section in
                        SettingsSidebarRow(
                            section: section,
                            isSelected: selection == section
                        ) {
                            withAnimation(.easeInOut(duration: 0.16)) {
                                selection = section
                            }
                        }
                    }
                }

                Spacer(minLength: 16)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .scrollIndicators(.hidden)
    }
}

private struct SettingsSidebarSectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.top, 4)
    }
}

private struct SettingsSidebarRow: View {
    let section: SettingsSection
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovering = false
    @State private var didPushCursor = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: section.systemImage)
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 18)

                Text(section.title)
                    .font(.system(size: 13, weight: .semibold))

                Spacer(minLength: 0)
            }
            .foregroundStyle(isSelected ? AnyShapeStyle(Color.white) : AnyShapeStyle(.primary))
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? SettingsStyle.sidebarSelection : (isHovering ? SettingsStyle.sidebarHover : Color.clear))
            )
        }
        .buttonStyle(SettingsSidebarRowButtonStyle())
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isHovering = hovering
            }

            // SwiftUI doesn't have a stable cursor modifier; use AppKit for pointer feedback.
            if hovering {
                if !didPushCursor {
                    NSCursor.pointingHand.push()
                    didPushCursor = true
                }
            } else {
                if didPushCursor {
                    NSCursor.pop()
                    didPushCursor = false
                }
            }
        }
        .onDisappear {
            if didPushCursor {
                NSCursor.pop()
                didPushCursor = false
            }
        }
        .accessibilityHint(isSelected ? "Selected" : "Switch to \(section.title)")
    }
}

private struct SettingsSidebarRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .opacity(configuration.isPressed ? 0.90 : 1.0)
            .animation(.spring(response: 0.22, dampingFraction: 0.78), value: configuration.isPressed)
    }
}

private enum SettingsStyle {
    static let sidebarWidth: CGFloat = 210
    // Keep room for traffic lights, but avoid a large empty band.
    static let titlebarContentInset: CGFloat = 8
    // Right content doesn't need to align with sidebar items; keep a small, consistent
    // top inset from the window frame instead.
    static let contentTopInset: CGFloat = 12
    static let contentMaxWidth: CGFloat = 820

    // Mimic the reference: sidebar slightly darker than the content area.
    static let sidebarBackground = Color(nsColor: .controlBackgroundColor)
    // Match window background so the right side doesn't look like a separate slab.
    static let pageBackground = Color(nsColor: .controlBackgroundColor)

    // Selection pill.
    static let sidebarSelection = Color(nsColor: .systemBlue)

    // Hover highlight for non-selected rows.
    static let sidebarHover = Color(nsColor: .selectedContentBackgroundColor).opacity(0.18)

    // Cards.
    static let cardBackground = Color(nsColor: .windowBackgroundColor)
    static let cardBorder = Color(nsColor: .separatorColor).opacity(0.45)
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
            case .systems:
                SystemsSettingsView()
            case .hooks:
                HooksSettingsView(tunnelManager: sshTunnelManager)
            case .tokenUsage:
                TokenUsageSettingsView()
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
            VStack(alignment: .leading, spacing: 14) {
                Text(title)
                    .font(.system(size: 26, weight: .bold))

                content
            }
            // With fullSizeContentView, content can extend under the titlebar.
            // Add top inset so the first title doesn't clash with the window chrome.
            .padding(.horizontal, 18)
            .padding(.bottom, 18)
            .padding(.top, SettingsStyle.contentTopInset)
            .frame(maxWidth: SettingsStyle.contentMaxWidth, alignment: .topLeading)
        }
    }
}

private struct SettingsSectionTitle: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
    }
}

private struct SettingsCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(SettingsStyle.cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(SettingsStyle.cardBorder)
        )
        // Newer macOS settings cards use subtler elevation.
        .shadow(color: Color.black.opacity(0.03), radius: 6, x: 0, y: 2)
        // Cards in System Settings are full-width within the content column.
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SettingsCardDivider: View {
    var body: some View {
        Divider().padding(.leading, 14)
    }
}

private struct SettingsRow<Accessory: View>: View {
    let title: String
    let subtitle: String?
    @ViewBuilder var accessory: Accessory

    init(_ title: String, subtitle: String? = nil, @ViewBuilder accessory: () -> Accessory) {
        self.title = title
        self.subtitle = subtitle
        self.accessory = accessory()
    }

    var body: some View {
        HStack(alignment: subtitle == nil ? .center : .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 0)

            accessory
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

private struct AppearanceSettingsView: View {
    @ObservedObject var screenSelector: ScreenSelector

    @State private var mode: ScreenSelectionMode = .automatic
    @State private var selectedIdentifier: ScreenIdentifier? = nil

    var body: some View {
        SettingsPage(title: "Appearance") {
            SettingsSectionTitle(title: "Screen")
            SettingsCard {
                SettingsRow("Mode") {
                    Picker("", selection: $mode) {
                        Text("Automatic").tag(ScreenSelectionMode.automatic)
                        Text("Specific").tag(ScreenSelectionMode.specificScreen)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 260)
                }

                if mode == .specificScreen {
                    SettingsCardDivider()
                    SettingsRow("Display") {
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
            SettingsSectionTitle(title: "Sound")
            SettingsCard {
                SettingsRow("Sound") {
                    Picker("", selection: $selectedSound) {
                        ForEach(NotificationSound.allCases, id: \.self) { sound in
                            Text(sound.rawValue).tag(sound)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 220)
                }
                SettingsCardDivider()
                SettingsRow("Preview") {
                    Button("Play") {
                        if let name = selectedSound.soundName {
                            NSSound(named: name)?.play()
                        }
                    }
                    .disabled(selectedSound.soundName == nil)
                }
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

private struct NormalizedRemoteSSHIdentity {
    let host: String
    let user: String?
}

private func normalizeRemoteSSHIdentity(host: String, user: String) -> NormalizedRemoteSSHIdentity {
    let hostTrim = host.trimmingCharacters(in: .whitespacesAndNewlines)
    let userTrim = user.trimmingCharacters(in: .whitespacesAndNewlines)

    if userTrim.isEmpty,
       let at = hostTrim.firstIndex(of: "@"),
       hostTrim.firstIndex(of: " ") == nil {
        let parsedUser = String(hostTrim[..<at])
        let parsedHost = String(hostTrim[hostTrim.index(after: at)...])
        if !parsedUser.isEmpty, !parsedHost.isEmpty {
            return NormalizedRemoteSSHIdentity(host: parsedHost, user: parsedUser)
        }
    }

    return NormalizedRemoteSSHIdentity(host: hostTrim, user: userTrim.isEmpty ? nil : userTrim)
}

private func shortenedSettingsPath(_ path: String) -> String {
    let home = NSHomeDirectory()
    if path.hasPrefix(home) {
        return "~" + path.dropFirst(home.count)
    }
    return path
}

private struct SystemsSettingsView: View {
    @State private var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled

    var body: some View {
        SettingsPage(title: "Systems") {
            SettingsSectionTitle(title: "Local Paths")
            SettingsCard {
                SettingsRow("Claude Config") {
                    Text(shortenedSettingsPath(ClaudePaths.claudeDir.path))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                SettingsCardDivider()
                SettingsRow("Claude Projects") {
                    Text(shortenedSettingsPath(ClaudePaths.projectsDir.path))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                SettingsCardDivider()
                SettingsRow("Island Root") {
                    Text(shortenedSettingsPath(IslandPaths.rootDir.path))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                SettingsCardDivider()
                SettingsRow("Socket") {
                    Text(shortenedSettingsPath(IslandPaths.socketPath))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            Spacer().frame(height: 12)

            SettingsSectionTitle(title: "System")
            SettingsCard {
                SettingsRow("Launch at Login") {
                    Toggle("", isOn: $launchAtLogin)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .onChange(of: launchAtLogin) { _, newValue in
                            do {
                                if newValue {
                                    try SMAppService.mainApp.register()
                                } else {
                                    try SMAppService.mainApp.unregister()
                                }
                            } catch {
                                launchAtLogin = SMAppService.mainApp.status == .enabled
                                print("Failed to toggle launch at login: \(error)")
                            }
                        }
                }
            }

            Spacer().frame(height: 12)

            SettingsSectionTitle(title: "Accessibility")
            SettingsCard {
                SettingsRow(AXIsProcessTrusted() ? "Enabled" : "Disabled") {
                    if !AXIsProcessTrusted() {
                        Button("Open System Settings") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    }
                }
            }
        }
        .onAppear {
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

// MARK: - Token Usage

private struct TokenUsageSettingsView: View {
    @ObservedObject private var statsManager = TokenStatisticsManager.shared

    var body: some View {
        SettingsPage(title: "Token Usage") {
            SettingsSectionTitle(title: "Totals")
            SettingsCard {
                SettingsRow("Total tokens", subtitle: "Imported history and live session usage") {
                    Text(statsManager.globalStats.totalTokens.formatted())
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.primary)
                        .contentTransition(.numericText())
                        .animation(.snappy, value: statsManager.globalStats.totalTokens)
                }
            }

            SettingsSectionTitle(title: "History")
            SettingsCard {
                VStack(spacing: 0) {
                    SettingsRow(
                        "Historical import",
                        subtitle: "First launch auto-imports old sessions. Rebuild if the total looks off."
                    ) {
                        Button(statsManager.isRebuildingHistory ? "Scanning…" : "Rebuild") {
                            Task {
                                await statsManager.rebuildHistoryFromDisk()
                            }
                        }
                        .disabled(statsManager.isRebuildingHistory)
                    }

                    if statsManager.isRebuildingHistory {
                        SettingsCardDivider()

                        HStack(spacing: 10) {
                            ProgressView()
                                .controlSize(.small)

                            Text("Scanning all historical session files and rebuilding token totals…")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)

                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                    }
                }
            }

            SettingsSectionTitle(title: "By Agent")
            SettingsCard {
                if statsManager.globalStats.byAgent.isEmpty {
                    SettingsRow("No data", subtitle: "No token usage recorded yet") {
                        EmptyView()
                    }
                } else {
                    let total = max(1, statsManager.globalStats.totalTokens)
                    let sorted = statsManager.globalStats.byAgent.sorted(by: { $0.value.totalTokens > $1.value.totalTokens })

                    ForEach(Array(sorted.enumerated()), id: \.element.key) { index, element in
                        let agent = element.key
                        let tokens = element.value.totalTokens

                        VStack(spacing: 0) {
                            SettingsRow(agent) {
                                Text("\(statsManager.formatTokens(tokens)) tk")
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }

                            GeometryReader { geometry in
                                ZStack(alignment: .leading) {
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(Color(nsColor: .separatorColor).opacity(0.18))
                                        .frame(height: 6)

                                    let width = geometry.size.width * CGFloat(tokens) / CGFloat(total)
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(agentColor(for: agent))
                                        .frame(width: max(0, width), height: 6)
                                }
                            }
                            .frame(height: 6)
                            .padding(.horizontal, 14)
                            .padding(.bottom, 10)

                            if index != sorted.count - 1 {
                                SettingsCardDivider()
                            }
                        }
                    }
                }
            }
        }
    }

    private func agentColor(for agent: String) -> Color {
        if agent == "Claude Code" {
            return Color(red: 0.85, green: 0.47, blue: 0.34)
        }
        if agent == "Coco" {
            return Color(red: 0.35, green: 0.6, blue: 0.95)
        }
        return Color(nsColor: .controlAccentColor)
    }
}

private struct RemoteMachinesSettingsSection: View {
    @Binding var remoteMachines: [RemoteMachineSettings]
    @ObservedObject var tunnelManager: SSHTunnelManager

    var body: some View {
        HStack {
            SettingsSectionTitle(title: "Remote Machines")
            Spacer(minLength: 0)
            Button("Add Machine") {
                addRemoteMachine()
            }
        }
        .padding(.horizontal, 6)

        if remoteMachines.isEmpty {
            SettingsCard {
                SettingsRow("No remote machines", subtitle: "Add a machine to monitor remote tunnel status and install remote hooks.") {
                    Button("Add Machine") {
                        addRemoteMachine()
                    }
                }
            }
        } else {
            SettingsCard {
                ForEach($remoteMachines) { $machine in
                    RemoteMachineSettingsCard(
                        machine: $machine,
                        tunnelManager: tunnelManager,
                        onRemove: {
                            removeRemoteMachine(id: machine.id)
                        }
                    )

                    if machine.id != remoteMachines.last?.id {
                        SettingsCardDivider()
                    }
                }
            }
        }
    }

    private func addRemoteMachine() {
        remoteMachines.append(
            RemoteMachineSettings(name: "Remote \(remoteMachines.count + 1)")
        )
    }

    private func removeRemoteMachine(id: String) {
        guard let index = remoteMachines.firstIndex(where: { $0.id == id }) else { return }
        let machine = remoteMachines[index]
        let normalized = normalizeRemoteSSHIdentity(host: machine.host, user: machine.user)

        if !normalized.host.isEmpty {
            Task {
                await tunnelManager.removeTunnels(
                    host: normalized.host,
                    user: normalized.user,
                    sshPort: machine.sshPort,
                    remotePort: machine.remotePort,
                    localPort: SSHTunnelManager.defaultPort
                )
            }
        }

        remoteMachines.remove(at: index)
    }
}

private struct RemoteMachineSettingsCard: View {
    @Binding var machine: RemoteMachineSettings
    @ObservedObject var tunnelManager: SSHTunnelManager

    let onRemove: () -> Void

    private struct MachineConnectionIdentity: Equatable {
        let host: String
        let user: String?
        let sshPort: Int
        let remotePort: Int
    }

    private enum RemoteHookState: Equatable {
        case unknown
        case checking
        case installed
        case notInstalled
        case unavailable(String)
    }

    @State private var isExpanded: Bool = false
    @State private var isEditing: Bool = false
    @State private var draftMachine: RemoteMachineSettings? = nil
    @State private var isWorking: Bool = false
    @State private var statusText: String? = nil
    @State private var errorText: String? = nil
    @State private var remoteHookState: RemoteHookState = .unknown
    @State private var isSyncingHistory: Bool = false

    private var normalizedIdentity: NormalizedRemoteSSHIdentity {
        normalizeRemoteSSHIdentity(host: machine.host, user: machine.user)
    }

    private var isConnected: Bool {
        guard !normalizedIdentity.host.isEmpty else { return false }
        return tunnelManager.isTCPTunnelActive(
            host: normalizedIdentity.host,
            user: normalizedIdentity.user,
            sshPort: machine.sshPort,
            remotePort: machine.remotePort,
            localPort: SSHTunnelManager.defaultPort
        )
    }

    private var titleText: String {
        let trimmedName = machine.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedName.isEmpty {
            return trimmedName
        }
        if !normalizedIdentity.host.isEmpty {
            return normalizedIdentity.host
        }
        return "Remote Machine"
    }

    private var stateLabel: String {
        if isConnected { return "Connected" }
        if machine.isEnabled { return "Auto-connect enabled" }
        return "Idle"
    }

    private var statusColor: Color {
        if isConnected { return .green }
        if machine.isEnabled { return .orange }
        return .secondary.opacity(0.6)
    }

    private var summaryHostText: String {
        let host = normalizedIdentity.host.trimmingCharacters(in: .whitespacesAndNewlines)
        return host.isEmpty ? "Host not configured" : host
    }

    private var displayUserText: String {
        let user = normalizedIdentity.user?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return user.isEmpty ? "Default SSH user" : user
    }

    private var displayAutoConnectText: String {
        machine.isEnabled ? "Enabled" : "Disabled"
    }

    private var displayedErrorText: String? {
        errorText
    }

    private var remoteHookLabel: String {
        switch remoteHookState {
        case .unknown:
            return normalizedIdentity.host.isEmpty ? "Host not configured" : "Not checked"
        case .checking:
            return "Checking…"
        case .installed:
            return "Installed"
        case .notInstalled:
            return "Not Installed"
        case .unavailable:
            return "Unavailable"
        }
    }

    private var remoteHookColor: Color {
        switch remoteHookState {
        case .installed:
            return .green
        case .checking:
            return .orange
        case .notInstalled, .unknown:
            return .secondary.opacity(0.6)
        case .unavailable:
            return .red
        }
    }

    private var remoteHookSubtitle: String? {
        switch remoteHookState {
        case .unknown:
            return normalizedIdentity.host.isEmpty ? "Configure the host before checking the remote hook." : nil
        case .checking, .installed, .notInstalled:
            return nil
        case .unavailable(let message):
            return message
        }
    }

    private var remoteHookActionTitle: String {
        remoteHookState == .installed ? "Reinstall Remote Hook" : "Install Remote Hook"
    }

    private func draftBinding<Value>(_ keyPath: WritableKeyPath<RemoteMachineSettings, Value>) -> Binding<Value> {
        Binding(
            get: {
                draftMachine?[keyPath: keyPath] ?? machine[keyPath: keyPath]
            },
            set: { newValue in
                if draftMachine == nil {
                    draftMachine = machine
                }
                draftMachine?[keyPath: keyPath] = newValue
            }
        )
    }

    @ViewBuilder
    private func readOnlyValue(_ text: String, monospaced: Bool = false, placeholder: Bool = false) -> some View {
        Text(text)
            .font(.system(size: 12, design: monospaced ? .monospaced : .default))
            .foregroundStyle(placeholder ? .tertiary : .secondary)
            .multilineTextAlignment(.trailing)
            .textSelection(.enabled)
            .frame(maxWidth: 320, alignment: .trailing)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(titleText)
                        .font(.system(size: 14, weight: .semibold))

                    Text(summaryHostText)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 12)

                HStack(spacing: 8) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 8, height: 8)

                    Text(stateLabel)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                if isWorking {
                    ProgressView()
                        .controlSize(.small)
                }

                Button {
                    let willExpand = !isExpanded
                    withAnimation(.easeInOut(duration: 0.18)) {
                        if isExpanded {
                            cancelEditing()
                            remoteHookState = .unknown
                        }
                        isExpanded.toggle()
                    }

                    if willExpand {
                        Task {
                            await refreshRemoteHookStatus(force: true)
                        }
                    }
                } label: {
                    Image(systemName: isExpanded ? "info.circle.fill" : "info.circle")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isExpanded ? "Hide \(titleText) details" : "Show \(titleText) details")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            if isExpanded {
                SettingsCardDivider()
                SettingsRow("Name") {
                    if isEditing {
                        TextField("Remote machine", text: draftBinding(\.name))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 320)
                    } else {
                        readOnlyValue(titleText)
                    }
                }
                SettingsCardDivider()
                SettingsRow("Host") {
                    if isEditing {
                        TextField("example.com", text: draftBinding(\.host))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 320)
                    } else {
                        readOnlyValue(summaryHostText, monospaced: true, placeholder: normalizedIdentity.host.isEmpty)
                    }
                }
                SettingsCardDivider()
                SettingsRow("User", subtitle: "optional") {
                    if isEditing {
                        TextField("", text: draftBinding(\.user))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 320)
                    } else {
                        readOnlyValue(displayUserText, monospaced: true, placeholder: normalizedIdentity.user == nil)
                    }
                }
                SettingsCardDivider()
                SettingsRow("SSH Port") {
                    if isEditing {
                        TextField("", value: draftBinding(\.sshPort), formatter: SettingsNumberFormatters.port)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 140)
                    } else {
                        readOnlyValue("\(machine.sshPort)", monospaced: true)
                    }
                }
                SettingsCardDivider()
                SettingsRow("Remote Port", subtitle: "Remote listen port for ssh -R") {
                    if isEditing {
                        TextField("", value: draftBinding(\.remotePort), formatter: SettingsNumberFormatters.port)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 140)
                    } else {
                        readOnlyValue("\(machine.remotePort)", monospaced: true)
                    }
                }
                SettingsCardDivider()
                SettingsRow("Auto-connect", subtitle: "Reconnect this machine when the app launches.") {
                    if isEditing {
                        Toggle("", isOn: draftBinding(\.isEnabled))
                            .labelsHidden()
                            .toggleStyle(.switch)
                    } else {
                        readOnlyValue(displayAutoConnectText)
                    }
                }
                SettingsCardDivider()
                SettingsRow("Status") {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(statusColor)
                            .frame(width: 8, height: 8)
                        Text(stateLabel)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
                SettingsCardDivider()
                SettingsRow("Remote Hook") {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(remoteHookColor)
                            .frame(width: 8, height: 8)
                        Text(remoteHookLabel)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
                if let remoteHookSubtitle {
                    SettingsCardDivider()
                    SettingsRow("Remote Hook Details", subtitle: remoteHookSubtitle) {
                        EmptyView()
                    }
                }
                SettingsCardDivider()
                SettingsRow("Actions") {
                    HStack(spacing: 10) {
                        if isWorking {
                            ProgressView()
                                .controlSize(.small)
                        }

                        if isEditing {
                            Button("Cancel") {
                                withAnimation(.easeInOut(duration: 0.18)) {
                                    cancelEditing()
                                }
                            }
                            .disabled(isWorking)

                            Button("Save") {
                                Task {
                                    await saveEdits()
                                }
                            }
                            .disabled(isWorking)
                        } else {
                            Button("Edit") {
                                withAnimation(.easeInOut(duration: 0.18)) {
                                    beginEditing()
                                }
                            }
                            .disabled(isWorking)
                        }

                        Button(isConnected ? "Disconnect" : "Connect") {
                            Task {
                                await toggleConnection()
                            }
                        }
                        .disabled(isWorking || normalizedIdentity.host.isEmpty || isEditing)

                        Button(remoteHookActionTitle) {
                            Task {
                                await installRemoteHook()
                            }
                        }
                        .disabled(isWorking || normalizedIdentity.host.isEmpty || isEditing)

                        Button(isSyncingHistory ? "Syncing…" : "Sync History") {
                            Task {
                                await syncRemoteHistory()
                            }
                        }
                        .disabled(isWorking || isSyncingHistory || normalizedIdentity.host.isEmpty || isEditing)

                        Button("Remove") {
                            onRemove()
                        }
                        .foregroundStyle(.red)
                        .disabled(isWorking || isEditing)
                    }
                }

                if let statusText {
                    SettingsCardDivider()
                    SettingsRow("Last Action", subtitle: statusText) {
                        EmptyView()
                    }
                }

                if let error = displayedErrorText {
                    SettingsCardDivider()
                    SettingsRow("Error") {
                        Text(error)
                            .font(.system(size: 11))
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                            .frame(maxWidth: 420, alignment: .leading)
                    }
                }
            }
        }
        .animation(.easeInOut(duration: 0.18), value: isExpanded)
        .onAppear {
            if isExpanded {
                Task {
                    await refreshRemoteHookStatus(force: false)
                }
            }
        }
        .onChange(of: machine.isEnabled) { _, newValue in
            if !newValue && isConnected {
                Task {
                    await disconnect()
                }
            }
        }
        .onChange(of: machine.host) { _, _ in
            remoteHookState = .unknown
        }
        .onChange(of: machine.user) { _, _ in
            remoteHookState = .unknown
        }
        .onChange(of: machine.sshPort) { _, _ in
            remoteHookState = .unknown
        }
    }

    private func beginEditing() {
        draftMachine = machine
        isEditing = true
    }

    private func cancelEditing() {
        draftMachine = nil
        isEditing = false
    }

    private func normalizeMachine(_ value: RemoteMachineSettings) -> RemoteMachineSettings {
        var normalized = value
        let identity = normalizeRemoteSSHIdentity(host: normalized.host, user: normalized.user)
        normalized.host = identity.host
        normalized.user = identity.user ?? ""
        normalized.name = normalized.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized
    }

    private func connectionIdentity(for settings: RemoteMachineSettings) -> MachineConnectionIdentity {
        let identity = normalizeRemoteSSHIdentity(host: settings.host, user: settings.user)
        return MachineConnectionIdentity(
            host: identity.host,
            user: identity.user,
            sshPort: settings.sshPort,
            remotePort: settings.remotePort
        )
    }

    private func isTunnelActive(for settings: RemoteMachineSettings) -> Bool {
        let identity = connectionIdentity(for: settings)
        guard !identity.host.isEmpty else { return false }
        return tunnelManager.isTCPTunnelActive(
            host: identity.host,
            user: identity.user,
            sshPort: identity.sshPort,
            remotePort: identity.remotePort,
            localPort: SSHTunnelManager.defaultPort
        )
    }

    private func saveEdits() async {
        guard let draftMachine else {
            cancelEditing()
            return
        }

        let previousMachine = machine
        let updatedMachine = normalizeMachine(draftMachine)
        let previousIdentity = connectionIdentity(for: previousMachine)
        let updatedIdentity = connectionIdentity(for: updatedMachine)
        let wasConnected = isTunnelActive(for: previousMachine)
        let connectionIdentityChanged = previousIdentity != updatedIdentity

        machine = updatedMachine
        self.draftMachine = nil
        isEditing = false
        errorText = nil
        remoteHookState = .unknown

        guard wasConnected, connectionIdentityChanged, !previousIdentity.host.isEmpty else {
            statusText = "Settings saved"
            if isExpanded {
                await refreshRemoteHookStatus(force: false)
            }
            return
        }

        isWorking = true
        defer { isWorking = false }

        statusText = "Updating connection…"
        await tunnelManager.removeTunnels(
            host: previousIdentity.host,
            user: previousIdentity.user,
            sshPort: previousIdentity.sshPort,
            remotePort: previousIdentity.remotePort,
            localPort: SSHTunnelManager.defaultPort
        )
        statusText = "Connection settings changed. Reconnect to apply the new address."
        if isExpanded {
            await refreshRemoteHookStatus(force: false)
        }
    }

    private func persistNormalizedIdentity() {
        machine = normalizeMachine(machine)
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
        persistNormalizedIdentity()

        guard !normalizedIdentity.host.isEmpty else { return }

        isWorking = true
        defer { isWorking = false }

        statusText = "Connecting…"
        await tunnelManager.removeTunnels(
            host: normalizedIdentity.host,
            user: normalizedIdentity.user,
            sshPort: machine.sshPort,
            remotePort: machine.remotePort,
            localPort: SSHTunnelManager.defaultPort
        )

        let tunnel = await tunnelManager.createTCPTunnel(
            host: normalizedIdentity.host,
            user: normalizedIdentity.user,
            sshPort: machine.sshPort,
            remotePort: machine.remotePort,
            localPort: SSHTunnelManager.defaultPort
        )

        if tunnel != nil {
            statusText = "Connected to \(normalizedIdentity.host)"
        } else {
            statusText = "Failed to connect"
            errorText = tunnelManager.lastErrorMessage
        }
    }

    private func disconnect() async {
        persistNormalizedIdentity()

        guard !normalizedIdentity.host.isEmpty else { return }

        isWorking = true
        defer { isWorking = false }

        statusText = "Disconnecting…"
        await tunnelManager.removeTunnels(
            host: normalizedIdentity.host,
            user: normalizedIdentity.user,
            sshPort: machine.sshPort,
            remotePort: machine.remotePort,
            localPort: SSHTunnelManager.defaultPort
        )
        statusText = "Disconnected"
    }

    private func installRemoteHook() async {
        persistNormalizedIdentity()

        guard !normalizedIdentity.host.isEmpty else { return }

        isWorking = true
        defer { isWorking = false }

        statusText = "Installing remote hook…"
        errorText = nil

        let result = await tunnelManager.installRemoteHook(
            host: normalizedIdentity.host,
            user: normalizedIdentity.user,
            sshPort: machine.sshPort,
            tcpPort: machine.remotePort,
            localPort: SSHTunnelManager.defaultPort
        )

        switch result {
        case .success:
            statusText = "Remote hook installed"
            remoteHookState = .installed
        case .failure(let error):
            statusText = "Failed to install remote hook"
            errorText = error.localizedDescription
            remoteHookState = .unavailable(error.localizedDescription)
        }
    }

    private func refreshRemoteHookStatus(force: Bool) async {
        guard !normalizedIdentity.host.isEmpty else {
            remoteHookState = .unknown
            return
        }

        if !force, case .installed = remoteHookState {
            return
        }

        remoteHookState = .checking
        let result = await tunnelManager.isRemoteHookInstalled(
            host: normalizedIdentity.host,
            user: normalizedIdentity.user,
            sshPort: machine.sshPort
        )

        switch result {
        case .success(let installed):
            remoteHookState = installed ? .installed : .notInstalled
        case .failure(let error):
            remoteHookState = .unavailable(error.localizedDescription)
        }
    }

    private func syncRemoteHistory() async {
        persistNormalizedIdentity()
        guard !normalizedIdentity.host.isEmpty else { return }

        isSyncingHistory = true
        statusText = "Syncing remote history…"
        errorText = nil

        // Run sync on background thread to avoid freezing the UI
        let result = await Task.detached(priority: .utility) {
            await self.tunnelManager.syncRemoteHistory(
                host: self.normalizedIdentity.host,
                user: self.normalizedIdentity.user,
                sshPort: self.machine.sshPort
            )
        }.value

        isSyncingHistory = false

        switch result {
        case .success(let syncResult):
            if syncResult.syncedFiles > 0 {
                statusText = "Synced \(syncResult.syncedFiles) sessions (\(syncResult.skippedFiles) already cached)"
                // Trigger token rebuild to count the newly synced sessions
                await TokenStatisticsManager.shared.rebuildHistoryFromDisk()
            } else if syncResult.scannedFiles == 0 {
                statusText = "No remote sessions found"
            } else {
                statusText = "All \(syncResult.skippedFiles) sessions already cached"
            }
        case .failure(let error):
            statusText = "Sync failed"
            errorText = error.localizedDescription
        }
    }
}

private struct HooksSettingsView: View {
    @ObservedObject private var providerRegistry = ProviderRegistry.shared
    @ObservedObject var tunnelManager: SSHTunnelManager

    @State private var expandedProviderIds: Set<String> = []
    @State private var workingProviderIds: Set<String> = []
    @State private var actionMessages: [String: String] = [:]
    @State private var remoteMachines: [RemoteMachineSettings] = AppSettings.remoteMachines

    private var providers: [ProviderInfo] {
        providerRegistry.registeredFactories.values
            .map { $0.providerInfo }
            .sorted {
                $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
    }

    var body: some View {
        SettingsPage(title: "Hooks") {
            SettingsSectionTitle(title: "Providers")

            SettingsCard {
                ForEach(providers, id: \.id) { info in
                    HStack(alignment: .center, spacing: 12) {
                        Text(info.displayName)
                            .font(.system(size: 14, weight: .semibold))

                        Spacer(minLength: 12)

                        HStack(spacing: 8) {
                            Circle()
                                .fill(hookStatusColor(for: info.id))
                                .frame(width: 8, height: 8)

                            Text(hookStatusLabel(for: info.id))
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }

                        if workingProviderIds.contains(info.id) {
                            ProgressView()
                                .controlSize(.small)
                        }

                        Button {
                            withAnimation(.easeInOut(duration: 0.18)) {
                                toggleProviderDetails(info.id)
                            }
                        } label: {
                            Image(systemName: expandedProviderIds.contains(info.id) ? "info.circle.fill" : "info.circle")
                                .font(.system(size: 17, weight: .medium))
                                .foregroundStyle(.secondary)
                                .frame(width: 28, height: 28)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(expandedProviderIds.contains(info.id) ? "Hide \(info.displayName) details" : "Show \(info.displayName) details")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)

                    if expandedProviderIds.contains(info.id) {
                        SettingsCardDivider()
                        VStack(alignment: .leading, spacing: 12) {
                            Text(availabilitySubtitle(for: info.id))
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)

                            HStack(spacing: 10) {
                                Button(isInstalled(for: info.id) ? "Reinstall" : "Install") {
                                    Task {
                                        await runHookAction(providerId: info.id, install: true)
                                    }
                                }
                                .disabled(workingProviderIds.contains(info.id) || isProviderUnavailable(info.id))

                                Button("Uninstall") {
                                    Task {
                                        await runHookAction(providerId: info.id, install: false)
                                    }
                                }
                                .disabled(workingProviderIds.contains(info.id) || !isInstalled(for: info.id))

                                Spacer(minLength: 0)
                            }

                            if let message = actionMessages[info.id] {
                                Text(message)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }

                            if isProviderUnavailable(info.id) {
                                Text("Can't install hooks while this provider is unavailable. Please make sure the corresponding CLI is installed on this Mac.")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.tertiary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                    }

                    if info.id != providers.last?.id {
                        SettingsCardDivider()
                    }
                }
            }

            Spacer().frame(height: 12)

            RemoteMachinesSettingsSection(
                remoteMachines: $remoteMachines,
                tunnelManager: tunnelManager
            )
        }
        .onAppear {
            remoteMachines = AppSettings.remoteMachines
        }
        .onChange(of: remoteMachines) { _, newValue in
            AppSettings.remoteMachines = newValue
        }
    }

    private func provider(for providerId: String) -> AgentProvider? {
        if let provider = providerRegistry.activeProviders[providerId] {
            return provider
        }
        return providerRegistry.registeredFactories[providerId]?.create()
    }

    private func isInstalled(for providerId: String) -> Bool {
        provider(for: providerId)?.isHookInstalled ?? false
    }

    private func availabilitySubtitle(for providerId: String) -> String {
        if providerRegistry.activeProviders[providerId] != nil {
            return "Provider is active and ready to receive hook events."
        }
        guard let available = providerRegistry.providerAvailability[providerId] else {
            return "Waiting for provider startup detection."
        }
        return available
            ? "CLI detected. You can install or reinstall hooks."
            : "CLI not detected on this machine."
    }

    private func hookStatusLabel(for providerId: String) -> String {
        if isInstalled(for: providerId) {
            return "Installed"
        }
        if providerRegistry.providerAvailability[providerId] == nil {
            return "Checking…"
        }
        if isProviderUnavailable(providerId) {
            return "Unavailable"
        }
        return "Not Installed"
    }

    private func hookStatusColor(for providerId: String) -> Color {
        isInstalled(for: providerId) ? .green : .secondary
    }

    private func isProviderUnavailable(_ providerId: String) -> Bool {
        if providerRegistry.activeProviders[providerId] != nil {
            return false
        }
        return providerRegistry.providerAvailability[providerId] == false
    }

    private func toggleProviderDetails(_ providerId: String) {
        if expandedProviderIds.contains(providerId) {
            expandedProviderIds.remove(providerId)
        } else {
            expandedProviderIds.insert(providerId)
        }
    }

    private func runHookAction(providerId: String, install: Bool) async {
        guard let provider = provider(for: providerId) else {
            actionMessages[providerId] = "Provider is not registered."
            return
        }

        workingProviderIds.insert(providerId)
        defer { workingProviderIds.remove(providerId) }

        if install {
            await provider.installHooks()
            actionMessages[providerId] = provider.isHookInstalled ? "Hooks installed." : "Install finished. Verify provider config if hooks still show as missing."
        } else {
            await provider.uninstallHooks()
            actionMessages[providerId] = provider.isHookInstalled ? "Uninstall finished, but hooks still appear present." : "Hooks removed."
        }
    }
}

private struct PathsSettingsView: View {
    var body: some View {
        SettingsPage(title: "Paths") {
            SettingsSectionTitle(title: "Claude Code")
            SettingsCard {
                SettingsRow("Config Directory") {
                    Text(shortenedPath(ClaudePaths.claudeDir.path))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                SettingsCardDivider()
                SettingsRow("Projects Directory") {
                    Text(shortenedPath(ClaudePaths.projectsDir.path))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            Spacer().frame(height: 12)

            SettingsSectionTitle(title: "Coding Island")
            SettingsCard {
                SettingsRow("Shared Directory") {
                    Text(shortenedPath(IslandPaths.rootDir.path))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                SettingsCardDivider()
                SettingsRow("Hooks") {
                    Text(shortenedPath(IslandPaths.hooksDir.path))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                SettingsCardDivider()
                SettingsRow("Socket") {
                    Text(shortenedPath(IslandPaths.socketPath))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
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
            SettingsSectionTitle(title: "Remote SSH")
            SettingsCard {
                SettingsRow("Enabled") {
                    Toggle("", isOn: $enabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
                SettingsCardDivider()
                SettingsRow("Host") {
                    TextField("example.com", text: $host)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 320)
                }
                SettingsCardDivider()
                SettingsRow("User", subtitle: "optional") {
                    TextField("", text: $user)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 220)
                }
                SettingsCardDivider()
                SettingsRow("SSH Port") {
                    TextField("", value: $sshPort, formatter: SettingsNumberFormatters.port)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 120)
                }
                SettingsCardDivider()
                SettingsRow("Remote Port", subtitle: "Remote listen port for ssh -R") {
                    TextField("", value: $remotePort, formatter: SettingsNumberFormatters.port)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 120)
                        .help("Remote listen port for ssh -R <remotePort>:127.0.0.1:<localPort>.")
                }
            }

            Spacer().frame(height: 12)

            SettingsSectionTitle(title: "Connection")
            SettingsCard {
                SettingsRow(isConnected ? "Connected" : "Disconnected") {
                    HStack(spacing: 10) {
                        if isWorking {
                            ProgressView().controlSize(.small)
                        }
                        Text("")
                    }
                }
                .overlay(alignment: .trailing) {
                    Text(isConnected ? "" : "")
                }

                SettingsCardDivider()
                SettingsRow("Actions") {
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
                }

                if let statusText {
                    SettingsCardDivider()
                    SettingsRow("Status", subtitle: statusText) { EmptyView() }
                }

                if let error = displayedErrorText {
                    SettingsCardDivider()
                    SettingsRow("Error") {
                        Text(error)
                            .font(.system(size: 11))
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                            .frame(maxWidth: 420, alignment: .leading)
                    }
                }
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
            SettingsSectionTitle(title: "System")
            SettingsCard {
                SettingsRow("Launch at Login") {
                    Toggle("", isOn: $launchAtLogin)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .onChange(of: launchAtLogin) { _, newValue in
                            do {
                                if newValue {
                                    try SMAppService.mainApp.register()
                                } else {
                                    try SMAppService.mainApp.unregister()
                                }
                            } catch {
                                launchAtLogin = SMAppService.mainApp.status == .enabled
                                print("Failed to toggle launch at login: \(error)")
                            }
                        }
                }
                SettingsCardDivider()
                SettingsRow("Hooks") {
                    Toggle("", isOn: $hooksInstalled)
                        .labelsHidden()
                        .toggleStyle(.switch)
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

            Spacer().frame(height: 12)

            SettingsSectionTitle(title: "Accessibility")
            SettingsCard {
                SettingsRow(AXIsProcessTrusted() ? "Enabled" : "Disabled") {
                    if !AXIsProcessTrusted() {
                        Button("Open System Settings") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    }
                }
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
            SettingsSectionTitle(title: "App")
            SettingsCard {
                SettingsRow("Version") {
                    Text(appVersion)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer().frame(height: 12)

            SettingsSectionTitle(title: "Updates")
            SettingsCard {
                SettingsRow("Status") {
                    HStack(spacing: 10) {
                        Text(updateStatusText)
                            .foregroundStyle(.secondary)
                        if updateManager.state.isActive {
                            ProgressView().controlSize(.small)
                        }
                    }
                }
                SettingsCardDivider()
                SettingsRow("Actions") { updateActions }
            }

            Spacer().frame(height: 12)

            SettingsSectionTitle(title: "Actions")
            SettingsCard {
                SettingsRow("Star on GitHub") {
                    Button("Open") {
                        if let url = URL(string: "https://github.com/farouqaldori/claude-island") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
                SettingsCardDivider()
                SettingsRow("Quit") {
                    Button("Quit") { NSApplication.shared.terminate(nil) }
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
