import Foundation

protocol FirstLaunchHookAutoInstallStateStore: AnyObject {
    var hasCompletedInitialHookAutoInstall: Bool { get set }
}

protocol FirstLaunchHookAutoInstallProvider: AnyObject {
    var providerId: String { get }
    var isAvailableForAutoInstall: Bool { get async }
    func installHooks() async
}

struct FirstLaunchHookAutoInstallResult {
    let didRun: Bool
    let installedProviderIds: [String]
}

final class UserDefaultsFirstLaunchHookAutoInstallStateStore: FirstLaunchHookAutoInstallStateStore {
    private let defaults: UserDefaults
    private let key: String

    init(
        defaults: UserDefaults = .standard,
        key: String = "FirstLaunchHookAutoInstallCompleted"
    ) {
        self.defaults = defaults
        self.key = key
    }

    var hasCompletedInitialHookAutoInstall: Bool {
        get { defaults.bool(forKey: key) }
        set { defaults.set(newValue, forKey: key) }
    }
}

enum FirstLaunchHookAutoInstaller {
    static func runIfNeeded(
        stateStore: FirstLaunchHookAutoInstallStateStore = UserDefaultsFirstLaunchHookAutoInstallStateStore(),
        providers: [FirstLaunchHookAutoInstallProvider]
    ) async -> FirstLaunchHookAutoInstallResult {
        guard !stateStore.hasCompletedInitialHookAutoInstall else {
            return FirstLaunchHookAutoInstallResult(didRun: false, installedProviderIds: [])
        }

        var installedProviderIds: [String] = []

        for provider in providers {
            let available = await provider.isAvailableForAutoInstall
            guard available else { continue }

            await provider.installHooks()
            installedProviderIds.append(provider.providerId)
        }

        stateStore.hasCompletedInitialHookAutoInstall = true
        return FirstLaunchHookAutoInstallResult(
            didRun: true,
            installedProviderIds: installedProviderIds
        )
    }
}
