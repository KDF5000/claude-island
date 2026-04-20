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
        // Our settings UI uses a dark background; force a matching appearance so
        // sidebar text/icons use light foreground colors.
        window.appearance = NSAppearance(named: .darkAqua)
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
    @ObservedObject private var soundSelector = SoundSelector.shared
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
            .scrollContentBackground(.hidden)
            .background(SettingsWindowColors.sidebar)
        } detail: {
            SettingsDetailView(
                selection: model.selection,
                updateManager: updateManager,
                screenSelector: screenSelector,
                soundSelector: soundSelector,
                sshTunnelManager: sshTunnelManager
            )
            .background(SettingsWindowColors.content)
        }
        .frame(minWidth: 760, minHeight: 520)
        .preferredColorScheme(.dark)
    }
}

private struct SettingsSidebarRow: View {
    let section: SettingsSection
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(section.title, systemImage: section.systemImage)
                .foregroundStyle(Color.white.opacity(isSelected ? 0.95 : 0.82))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets(top: 6, leading: 10, bottom: 6, trailing: 10))
        .listRowBackground(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.white.opacity(0.10) : Color.clear)
        )
    }
}

private enum SettingsWindowColors {
    static let sidebar = Color.black.opacity(0.94)
    static let content = Color.black.opacity(0.90)
}

private struct SettingsDetailView: View {
    let selection: SettingsSection?
    @ObservedObject var updateManager: UpdateManager
    @ObservedObject var screenSelector: ScreenSelector
    @ObservedObject var soundSelector: SoundSelector
    @ObservedObject var sshTunnelManager: SSHTunnelManager

    var body: some View {
        Group {
            switch selection {
            case .appearance:
                SettingsPage(title: "Appearance") {
                    ScreenPickerRow(screenSelector: screenSelector)
                }
            case .notifications:
                SettingsPage(title: "Notifications") {
                    SoundPickerRow(soundSelector: soundSelector)
                }
            case .paths:
                SettingsPage(title: "Paths") {
                    ClaudeDirPickerRow()
                }
            case .remote:
                SettingsPage(title: "Remote") {
                    RemoteSSHPickerRow(tunnelManager: sshTunnelManager)
                }
            case .system:
                SystemSettingsPage()
            case .about:
                AboutSettingsPage(updateManager: updateManager)
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
                .foregroundColor(.white.opacity(0.9))
            Text("Choose an item from the sidebar to edit settings.")
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.5))
        }
        .padding(20)
    }
}

private struct SettingsPage<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 12) {
                Text(title)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.white.opacity(0.9))
                    .padding(.bottom, 4)

                content
            }
            .padding(20)
            .frame(maxWidth: 720, alignment: .topLeading)
        }
        .scrollContentBackground(.hidden)
    }
}

private struct SystemSettingsPage: View {
    @State private var hooksInstalled: Bool = false
    @State private var launchAtLogin: Bool = false

    var body: some View {
        SettingsPage(title: "System") {
            MenuToggleRow(
                icon: "power",
                label: "Launch at Login",
                isOn: launchAtLogin
            ) {
                do {
                    if launchAtLogin {
                        try SMAppService.mainApp.unregister()
                        launchAtLogin = false
                    } else {
                        try SMAppService.mainApp.register()
                        launchAtLogin = true
                    }
                } catch {
                    print("Failed to toggle launch at login: \(error)")
                }
            }

            MenuToggleRow(
                icon: "arrow.triangle.2.circlepath",
                label: "Hooks",
                isOn: hooksInstalled
            ) {
                if hooksInstalled {
                    HookInstaller.uninstall()
                    hooksInstalled = false
                } else {
                    HookInstaller.installIfNeeded()
                    hooksInstalled = true
                }
            }

            AccessibilityRow(isEnabled: AXIsProcessTrusted())
        }
        .onAppear {
            hooksInstalled = HookInstaller.isInstalled()
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

private struct AboutSettingsPage: View {
    @ObservedObject var updateManager: UpdateManager

    var body: some View {
        SettingsPage(title: "About") {
            UpdateRow(updateManager: updateManager)

            MenuRow(icon: "star", label: "Star on GitHub") {
                if let url = URL(string: "https://github.com/farouqaldori/claude-island") {
                    NSWorkspace.shared.open(url)
                }
            }

            MenuRow(icon: "xmark.circle", label: "Quit", isDestructive: true) {
                NSApplication.shared.terminate(nil)
            }
        }
    }
}
