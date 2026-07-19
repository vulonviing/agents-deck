import AppKit
import SwiftUI

@main
struct AgentsDeckApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("Agents Deck Test Host", id: "test-host") {
            Color.clear.frame(width: 1, height: 1)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)

        Settings {
            SettingsView()
                .environment(appDelegate.model)
                .frame(width: 560, height: 620)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private var menuBarController: MenuBarController?
    private var terminationInProgress = false
    private var shouldShowSettingsOnFirstActivation = true

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard ProcessInfo.processInfo.environment["XCTestBundlePath"] == nil else { return }
        menuBarController = MenuBarController(
            model: model,
            onStatusItemInteraction: { [weak self] in
                self?.shouldShowSettingsOnFirstActivation = false
            }
        )
        model.start()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        guard shouldShowSettingsOnFirstActivation else { return }
        shouldShowSettingsOnFirstActivation = false
        menuBarController?.showSettings()
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        shouldShowSettingsOnFirstActivation = false
        menuBarController?.showSettings()
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminationInProgress else { return .terminateNow }
        terminationInProgress = true
        Task {
            await model.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
