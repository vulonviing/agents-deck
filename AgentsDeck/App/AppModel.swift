import AppKit
import Foundation
import Observation
import ServiceManagement

@MainActor
@Observable
final class AppModel {
    private let coordinator: UsageCoordinator
    private let uiProfileStore: DeckUIProfileStore
    private var stateTask: Task<Void, Never>?
    private(set) var hasStarted = false
    private var uiProfile: DeckUIProfile

    var state = AppViewState()
    var stateDidChange: (@MainActor (AppViewState) -> Void)?
    private(set) var menuBarProviderSelection: MenuBarProviderSelection
    private(set) var refreshCadence: RefreshCadence
    private(set) var isMenuBarItemVisible: Bool
    var presentedError: String?
    var notificationsGranted = false
    var launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
    var menuBarVisibilityDidChange: (@MainActor (Bool) -> Void)?

    init(
        coordinator: UsageCoordinator = UsageCoordinator(),
        uiProfileStore: DeckUIProfileStore = DeckUIProfileStore()
    ) {
        self.coordinator = coordinator
        self.uiProfileStore = uiProfileStore
        let profile = uiProfileStore.load()
        self.uiProfile = profile
        self.menuBarProviderSelection = profile.menuBarProviderSelection
        self.refreshCadence = profile.refreshCadence
        self.isMenuBarItemVisible = profile.menuBarItemVisible
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        stateTask = Task { [weak self, coordinator] in
            for await state in coordinator.states {
                guard let self else { return }
                self.state = state
                self.stateDidChange?(state)
            }
        }
        Task { await coordinator.start(refreshCadence: refreshCadence) }
    }

    func popoverOpened() {
        Task { await coordinator.popoverOpened() }
    }

    func providerDetailOpened(_ provider: ProviderID) {
        Task { await coordinator.providerDetailOpened(provider) }
    }

    func refreshNow() {
        Task { await coordinator.manualRefresh() }
    }

    func setMenuBarProviderSelection(_ selection: MenuBarProviderSelection) {
        guard menuBarProviderSelection != selection else { return }
        menuBarProviderSelection = selection
        uiProfile.menuBarProviderSelection = selection
        persistUIProfile()
        stateDidChange?(state)
    }

    func setRefreshCadence(_ cadence: RefreshCadence) {
        guard refreshCadence != cadence else { return }
        refreshCadence = cadence
        uiProfile.refreshCadence = cadence
        persistUIProfile()
        Task { await coordinator.setRefreshCadence(cadence) }
    }

    func setMenuBarItemVisible(_ visible: Bool) {
        guard isMenuBarItemVisible != visible else { return }
        isMenuBarItemVisible = visible
        uiProfile.menuBarItemVisible = visible
        persistUIProfile()
        menuBarVisibilityDidChange?(visible)
    }

    func synchronizeMenuBarItemVisibility(_ visible: Bool) {
        guard isMenuBarItemVisible != visible else { return }
        isMenuBarItemVisible = visible
        uiProfile.menuBarItemVisible = visible
        persistUIProfile()
    }

    func selectedUsageWindow(for provider: ProviderID) -> UsageWindowKind? {
        uiProfile.selectedUsageWindowByProvider[provider]
    }

    func selectUsageWindow(_ kind: UsageWindowKind, for provider: ProviderID) {
        guard uiProfile.selectedUsageWindowByProvider[provider] != kind else { return }
        uiProfile.selectedUsageWindowByProvider[provider] = kind
        persistUIProfile()
        stateDidChange?(state)
    }

    func resolvedPanelSize() -> NSSize {
        let size = PanelSizePolicy.resolvedSize(
            storedWidth: uiProfile.panelWidth ?? 0,
            storedHeight: uiProfile.panelHeight ?? 0,
            storedLayoutVersion: uiProfile.panelLayoutVersion ?? 0
        )
        if uiProfile.panelWidth != size.width
            || uiProfile.panelHeight != size.height
            || uiProfile.panelLayoutVersion != PanelSizePolicy.currentLayoutVersion {
            savePanelSize(size)
        }
        return size
    }

    func savePanelSize(_ size: NSSize) {
        let resolved = PanelSizePolicy.resolvedSize(
            storedWidth: size.width,
            storedHeight: size.height,
            storedLayoutVersion: PanelSizePolicy.currentLayoutVersion
        )
        guard uiProfile.panelWidth != resolved.width
            || uiProfile.panelHeight != resolved.height
            || uiProfile.panelLayoutVersion != PanelSizePolicy.currentLayoutVersion
        else { return }

        uiProfile.panelWidth = resolved.width
        uiProfile.panelHeight = resolved.height
        uiProfile.panelLayoutVersion = PanelSizePolicy.currentLayoutVersion
        persistUIProfile()
    }

    func connect(_ provider: ProviderID) {
        Task {
            switch provider {
            case .claude: await coordinator.connectClaude()
            case .codex: await coordinator.connectCodex()
            }
        }
    }

    func openClaudeLogin() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("claude auth login --claudeai", forType: .string)
        let terminal = URL(filePath: "/System/Applications/Utilities/Terminal.app")
        NSWorkspace.shared.openApplication(at: terminal, configuration: .init()) { _, error in
            if error != nil {
                Task { @MainActor [weak self] in
                    self?.presentedError = "Could not open Terminal. The login command is on your clipboard."
                }
            }
        }
    }

    func installClaudeBridge() {
        Task {
            do { try await coordinator.installClaudeBridge() }
            catch { presentedError = "Claude settings could not be updated safely. Your existing settings were not replaced." }
        }
    }

    func uninstallClaudeBridge() {
        Task {
            do { try await coordinator.uninstallClaudeBridge() }
            catch { presentedError = "Claude integration was not removed because its settings changed after installation." }
        }
    }

    func retryCodex() {
        Task { await coordinator.retryCodex() }
    }

    func requestNotifications() {
        Task { notificationsGranted = await coordinator.requestNotificationAuthorization() }
    }

    func chooseExecutable(for provider: ProviderID) {
        let panel = NSOpenPanel()
        panel.title = "Choose the \(provider.displayName) executable"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            presentedError = "The selected file is not executable."
            return
        }
        UserDefaults.standard.set(url.path, forKey: "executable.\(provider.rawValue)")
        Task { await coordinator.restart(provider) }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
        } catch {
            launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
            presentedError = "Launch at Login could not be changed."
        }
    }

    func revealLogs() {
        do {
            try FileManager.default.createDirectory(at: coordinator.logsDirectory, withIntermediateDirectories: true)
            NSWorkspace.shared.open(coordinator.logsDirectory)
        } catch {
            presentedError = "The logs folder could not be opened."
        }
    }

    func clearLogs() {
        Task {
            do { try await coordinator.clearLogs() }
            catch { presentedError = "Diagnostic logs could not be cleared." }
        }
    }

    func clearHistory() {
        Task {
            do { try await coordinator.clearHistory() }
            catch { presentedError = "Usage history could not be cleared." }
        }
    }

    func shutdown() async {
        stateTask?.cancel()
        await coordinator.stop()
    }

    private func persistUIProfile() {
        uiProfileStore.save(uiProfile)
    }
}
