import Foundation

final class InMemoryFirstLaunchStateStore: FirstLaunchHookAutoInstallStateStore {
    var hasCompletedInitialHookAutoInstall: Bool

    init(hasCompletedInitialHookAutoInstall: Bool = false) {
        self.hasCompletedInitialHookAutoInstall = hasCompletedInitialHookAutoInstall
    }
}

actor StubAutoInstallProvider: FirstLaunchHookAutoInstallProvider {
    let providerId: String
    private let available: Bool
    private(set) var installCallCount: Int = 0

    init(providerId: String, available: Bool) {
        self.providerId = providerId
        self.available = available
    }

    var isAvailableForAutoInstall: Bool {
        get async { available }
    }

    func installHooks() async {
        installCallCount += 1
    }

    func observedInstallCallCount() async -> Int {
        installCallCount
    }
}

@main
struct FirstLaunchHookAutoInstallTests {
    static func main() async {
        await testInstallsOnlyAvailableProvidersOnFirstLaunch()
        await testSkipsAllProvidersAfterFirstLaunchCompletes()
        print("PASS")
    }

    private static func testInstallsOnlyAvailableProvidersOnFirstLaunch() async {
        let stateStore = InMemoryFirstLaunchStateStore()
        let claude = StubAutoInstallProvider(providerId: "claude-code", available: true)
        let qoder = StubAutoInstallProvider(providerId: "qoder", available: false)

        let result = await FirstLaunchHookAutoInstaller.runIfNeeded(
            stateStore: stateStore,
            providers: [claude, qoder]
        )

        expect(result.didRun, "expected installer to run on first launch")
        expect(result.installedProviderIds == ["claude-code"], "expected only available providers to be installed")
        expect(stateStore.hasCompletedInitialHookAutoInstall, "expected first-launch flag to be persisted")
        let claudeInstallCount = await claude.observedInstallCallCount()
        let qoderInstallCount = await qoder.observedInstallCallCount()
        expect(claudeInstallCount == 1, "expected available provider to install exactly once")
        expect(qoderInstallCount == 0, "expected unavailable provider to be skipped")
    }

    private static func testSkipsAllProvidersAfterFirstLaunchCompletes() async {
        let stateStore = InMemoryFirstLaunchStateStore(hasCompletedInitialHookAutoInstall: true)
        let claude = StubAutoInstallProvider(providerId: "claude-code", available: true)

        let result = await FirstLaunchHookAutoInstaller.runIfNeeded(
            stateStore: stateStore,
            providers: [claude]
        )

        let claudeInstallCount = await claude.observedInstallCallCount()

        expect(!result.didRun, "expected installer to skip once first-launch auto install already ran")
        expect(result.installedProviderIds.isEmpty, "expected no providers to be installed on later launches")
        expect(claudeInstallCount == 0, "expected provider not to be reinstalled after first launch")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fputs("FAIL: \(message)\n", stderr)
            exit(1)
        }
    }
}
