import AppKit
import SwiftUI

@MainActor
final class MenuBarController: NSObject, NSWindowDelegate {
    private let model: AppModel
    private let statusItem: NSStatusItem
    private let panel: DeckPanel
    private let hostingController: NSHostingController<AnyView>
    private let settingsController: SettingsWindowController
    private var statusTrackingArea: NSTrackingArea?
    private var statusToolTipTag: NSView.ToolTipTag?
    private var statusDisplays: [MenuBarProviderDisplay] = []
    private var hoveredStatusProvider: ProviderID?
    private var outsideClickMonitor: Any?
    private var keyEventMonitor: Any?

    init(model: AppModel) {
        self.model = model
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.settingsController = SettingsWindowController(model: model)

        let initialSize = model.resolvedPanelSize()
        self.panel = DeckPanel(
            contentRect: NSRect(origin: .zero, size: initialSize),
            styleMask: [.borderless, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        self.hostingController = NSHostingController(rootView: AnyView(EmptyView()))
        super.init()

        configureStatusItem()
        configurePanel()
        updateStatusItem(model.state)
        model.stateDidChange = { [weak self] state in
            self?.updateStatusItem(state)
        }
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }
        button.image = nil
        button.title = ""
        button.toolTip = nil
        button.target = self
        button.action = #selector(statusItemClicked(_:))
        button.sendAction(on: [.leftMouseDown, .rightMouseDown])
        refreshStatusTracking()
    }

    @objc private func statusItemClicked(_ sender: Any?) {
        switch StatusItemActionResolver.action(for: NSApp.currentEvent?.type) {
        case .togglePanel:
            panel.isVisible ? closePanel() : openPanel()
        case .showContextMenu:
            closePanel()
            showContextMenu()
        case .ignore:
            break
        }
    }

    private func configurePanel() {
        hostingController.sizingOptions = []
        panel.delegate = self
        panel.contentViewController = hostingController
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.minSize = NSSize(width: DeckDesign.popoverMinimumWidth, height: DeckDesign.popoverMinimumHeight)
        panel.maxSize = NSSize(width: DeckDesign.popoverMaximumWidth, height: DeckDesign.popoverMaximumHeight)
    }

    private func openPanel() {
        hostingController.rootView = AnyView(
            MenuBarRootView(sessionID: UUID())
                .environment(model)
        )
        panel.setContentSize(model.resolvedPanelSize())
        NSApp.activate(ignoringOtherApps: true)
        positionPanel()
        panel.makeKeyAndOrderFront(nil)
        model.popoverOpened()
        installOutsideClickMonitor()
    }

    private func closePanel() {
        if panel.isVisible {
            model.savePanelSize(panel.frame.size)
        }
        panel.orderOut(nil)
        removeOutsideClickMonitor()
    }

    private func positionPanel() {
        guard let button = statusItem.button,
              let window = button.window,
              let screen = window.screen ?? NSScreen.main
        else { return }

        let buttonInWindow = button.convert(button.bounds, to: nil)
        let buttonOnScreen = window.convertToScreen(buttonInWindow)
        let visible = screen.visibleFrame
        var origin = NSPoint(
            x: buttonOnScreen.midX - panel.frame.width / 2,
            y: buttonOnScreen.minY - panel.frame.height - 8
        )
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - panel.frame.width - 8)
        origin.y = max(origin.y, visible.minY + 8)
        panel.setFrameOrigin(origin)
    }

    private func showContextMenu() {
        guard let button = statusItem.button else { return }
        let menu = NSMenu()
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        settings.toolTip = "Open Agents Deck settings"
        menu.addItem(settings)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Agents Deck", action: #selector(quitApplication), keyEquivalent: "q")
        quit.target = self
        quit.toolTip = "Quit Agents Deck and stop provider processes"
        menu.addItem(quit)

        statusItem.menu = menu
        button.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func openSettings() {
        settingsController.show()
    }

    @objc private func quitApplication() {
        NSApplication.shared.terminate(nil)
    }

    private func updateStatusItem(_ state: AppViewState) {
        guard let button = statusItem.button else { return }
        let selectedWindows = Dictionary(uniqueKeysWithValues: ProviderID.allCases.map {
            ($0, model.selectedUsageWindow(for: $0))
        }.compactMap { provider, kind in kind.map { (provider, $0) } })
        let displays = MenuBarPresentation.displays(
            for: state,
            selection: model.menuBarProviderSelection,
            selectedWindowKinds: selectedWindows
        )
        statusDisplays = displays
        hoveredStatusProvider = displays.contains { $0.provider == hoveredStatusProvider }
            ? hoveredStatusProvider
            : nil
        statusItem.length = MenuBarStatusLayout.contentWidth(segmentCount: displays.count)
        renderStatusButton()
        refreshStatusTracking()
        let accessibilityParts = displays.map { display in
            if let percent = display.percent {
                "\(display.provider.displayName) \(percent) percent"
            } else {
                "\(display.provider.displayName) unavailable"
            }
        }
        button.setAccessibilityLabel("Agents Deck, " + accessibilityParts.joined(separator: ", "))
    }

    private func renderStatusButton() {
        guard let button = statusItem.button else { return }
        let result = NSMutableAttributedString()
        for (index, display) in statusDisplays.enumerated() {
            if index > 0 {
                result.append(NSAttributedString(string: "   "))
            }

            let hovered = hoveredStatusProvider == display.provider
            let attachment = NSTextAttachment()
            attachment.image = statusImage(for: display.provider)
            attachment.bounds = NSRect(x: 0, y: hovered ? -1 : -2, width: 15, height: 15)
            result.append(NSAttributedString(attachment: attachment))

            let percentage = display.percent.map { " \($0)%" } ?? " --"
            result.append(NSAttributedString(
                string: percentage,
                attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
                    .foregroundColor: NSColor.labelColor,
                    .baselineOffset: hovered ? 1 : 0
                ]
            ))
        }
        button.attributedTitle = result
    }

    private func statusImage(for provider: ProviderID) -> NSImage? {
        let assetName = provider == .claude ? "ClaudeProviderMark" : "CodexProviderMark"
        guard let source = NSImage(named: NSImage.Name(assetName))
        else {
            return NSImage(systemSymbolName: "gauge.with.dots.needle.0percent", accessibilityDescription: nil)
        }

        let size = NSSize(width: 15, height: 15)
        let image = NSImage(size: size, flipped: false) { rect in
            source.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
            NSColor.white.setFill()
            rect.fill(using: .sourceAtop)
            return true
        }
        image.isTemplate = false
        return image
    }

    private func refreshStatusTracking() {
        guard let button = statusItem.button else { return }
        if let statusTrackingArea { button.removeTrackingArea(statusTrackingArea) }
        let area = NSTrackingArea(
            rect: button.bounds,
            options: [.activeAlways, .inVisibleRect, .mouseMoved, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        button.addTrackingArea(area)
        statusTrackingArea = area

        if let statusToolTipTag { button.removeToolTip(statusToolTipTag) }
        statusToolTipTag = button.addToolTip(button.bounds, owner: self, userData: nil)
    }

    @objc(mouseEntered:)
    private func statusMouseEntered(_ event: NSEvent) {
        updateHoveredStatusProvider(with: event)
    }

    @objc(mouseMoved:)
    private func statusMouseMoved(_ event: NSEvent) {
        updateHoveredStatusProvider(with: event)
    }

    private func updateHoveredStatusProvider(with event: NSEvent) {
        guard let button = statusItem.button else { return }
        let provider = MenuBarStatusLayout.provider(
            at: button.convert(event.locationInWindow, from: nil),
            in: statusDisplays
        )
        guard hoveredStatusProvider != provider else { return }
        hoveredStatusProvider = provider
        renderStatusButton()
    }

    @objc(mouseExited:)
    private func statusMouseExited(_ event: NSEvent) {
        _ = event
        guard hoveredStatusProvider != nil else { return }
        hoveredStatusProvider = nil
        renderStatusButton()
    }

    @objc func view(
        _ view: NSView,
        stringForToolTip tag: NSView.ToolTipTag,
        point: NSPoint,
        userData data: UnsafeMutableRawPointer?
    ) -> String {
        guard let provider = MenuBarStatusLayout.provider(at: point, in: statusDisplays),
              let display = statusDisplays.first(where: { $0.provider == provider })
        else { return "Open Agents Deck" }
        let value = display.percent.map { "\($0)%" } ?? "unavailable"
        return "\(provider.displayName): \(value). Click to open Agents Deck."
    }

    private func installOutsideClickMonitor() {
        removeOutsideClickMonitor()
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.closePanel() }
        }
        keyEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }
            Task { @MainActor in self?.closePanel() }
            return nil
        }
    }

    private func removeOutsideClickMonitor() {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        if let keyEventMonitor { NSEvent.removeMonitor(keyEventMonitor) }
        outsideClickMonitor = nil
        keyEventMonitor = nil
    }

    func windowDidResize(_ notification: Notification) {
        guard panel.isVisible else { return }
        model.savePanelSize(panel.frame.size)
    }

    func windowDidResignKey(_ notification: Notification) {
        closePanel()
    }

}

enum PanelSizePolicy {
    static let currentLayoutVersion = 2

    static func resolvedSize(
        storedWidth: Double,
        storedHeight: Double,
        storedLayoutVersion: Int
    ) -> NSSize {
        guard storedLayoutVersion == currentLayoutVersion else {
            return NSSize(width: DeckDesign.popoverIdealWidth, height: DeckDesign.popoverIdealHeight)
        }
        return NSSize(
            width: min(max(storedWidth > 0 ? storedWidth : DeckDesign.popoverIdealWidth, DeckDesign.popoverMinimumWidth), DeckDesign.popoverMaximumWidth),
            height: min(max(storedHeight > 0 ? storedHeight : DeckDesign.popoverIdealHeight, DeckDesign.popoverMinimumHeight), DeckDesign.popoverMaximumHeight)
        )
    }
}

private final class DeckPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class SettingsWindowController: NSWindowController {
    init(model: AppModel) {
        let hosting = NSHostingController(rootView: SettingsView().environment(model))
        let window = NSWindow(contentViewController: hosting)
        window.title = "Agents Deck Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.setContentSize(NSSize(width: 520, height: 520))
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func show() {
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

enum StatusItemAction: Equatable {
    case togglePanel
    case showContextMenu
    case ignore
}

enum StatusItemActionResolver {
    static func action(for eventType: NSEvent.EventType?) -> StatusItemAction {
        switch eventType {
        case .leftMouseDown, .leftMouseUp: .togglePanel
        case .rightMouseDown, .rightMouseUp: .showContextMenu
        default: .ignore
        }
    }
}

struct MenuBarDisplay: Equatable {
    let provider: ProviderID?
    let percent: Int?
}

struct MenuBarProviderDisplay: Identifiable, Equatable, Sendable {
    var id: ProviderID { provider }
    let provider: ProviderID
    let percent: Int?
}

enum MenuBarPresentation {
    static func displays(
        for state: AppViewState,
        selection: MenuBarProviderSelection,
        selectedWindowKinds: [ProviderID: UsageWindowKind],
        now: Date = Date()
    ) -> [MenuBarProviderDisplay] {
        selection.providers.map { provider in
            providerDisplay(
                provider,
                state: state,
                selectedWindowKind: selectedWindowKinds[provider],
                now: now
            )
        }
    }

    static func display(
        for state: AppViewState,
        selectedProviderID: ProviderID?,
        selectedWindowKind: UsageWindowKind? = nil,
        now: Date = Date()
    ) -> MenuBarDisplay {
        if let selectedProviderID {
            guard let selected = state.providers[selectedProviderID],
                  let snapshot = selected.snapshot,
                  UsageAlgorithms.isFresh(snapshot, now: now)
            else {
                return MenuBarDisplay(provider: selectedProviderID, percent: nil)
            }
            let window = selectedWindowKind.flatMap { snapshot[$0] }
                ?? snapshot.preferredGaugeWindow
            guard let window else {
                return MenuBarDisplay(provider: selectedProviderID, percent: nil)
            }
            return MenuBarDisplay(
                provider: selectedProviderID,
                percent: Int(window.usedPercent.rounded())
            )
        }

        guard let automatic = UsageAlgorithms.criticalProvider(
            in: Array(state.providers.values),
            keeping: state.criticalProviderID,
            now: now
        ), let percent = automatic.snapshot?.shortWindow?.usedPercent
        else {
            return MenuBarDisplay(provider: nil, percent: nil)
        }
        return MenuBarDisplay(provider: automatic.provider, percent: Int(percent.rounded()))
    }

    private static func providerDisplay(
        _ provider: ProviderID,
        state: AppViewState,
        selectedWindowKind: UsageWindowKind?,
        now: Date
    ) -> MenuBarProviderDisplay {
        guard let providerState = state.providers[provider],
              let snapshot = providerState.snapshot,
              UsageAlgorithms.isFresh(snapshot, now: now),
              let window = selectedWindowKind.flatMap({ snapshot[$0] }) ?? snapshot.preferredGaugeWindow
        else {
            return MenuBarProviderDisplay(provider: provider, percent: nil)
        }
        return MenuBarProviderDisplay(provider: provider, percent: Int(window.usedPercent.rounded()))
    }
}

private enum MenuBarStatusLayout {
    static let segmentWidth: CGFloat = 56
    static let spacing: CGFloat = 4
    static let height: CGFloat = 22

    static func contentWidth(segmentCount: Int) -> CGFloat {
        let count = max(1, segmentCount)
        return CGFloat(count) * segmentWidth + CGFloat(max(0, count - 1)) * spacing
    }

    static func provider(at point: NSPoint, in segments: [MenuBarProviderDisplay]) -> ProviderID? {
        guard point.y >= 0, point.y <= height else { return nil }
        for (index, segment) in segments.enumerated() {
            let minX = CGFloat(index) * (segmentWidth + spacing)
            if point.x >= minX, point.x <= minX + segmentWidth { return segment.provider }
        }
        return nil
    }
}
