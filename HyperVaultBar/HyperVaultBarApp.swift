import AppKit
import Combine
import SwiftUI

@main
struct HyperVaultBarApp: App {
    @NSApplicationDelegateAdaptor(StatusItemController.self) private var statusItem

    var body: some Scene {
        Settings { EmptyView() }
    }
}

@MainActor
private final class VaultPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
private final class StatusItemController: NSObject, NSApplicationDelegate {
    private let model = BalanceViewModel()
    private let popover = VaultPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                  backing: .buffered, defer: false)
    private var localClickMonitor: Any?
    private var globalClickMonitor: Any?
    private var statusItem: NSStatusItem?
    private var observation: AnyCancellable?
    private var hideBalance: Bool {
        get { UserDefaults.standard.bool(forKey: "hideBalance") }
        set {
            UserDefaults.standard.set(newValue, forKey: "hideBalance")
            updateTitle()
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        item.button?.target = self
        item.button?.action = #selector(statusItemClicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        popover.isOpaque = false
        popover.backgroundColor = .clear
        popover.hasShadow = true
        popover.level = .popUpMenu
        popover.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        popover.hidesOnDeactivate = false
        popover.contentViewController = NSHostingController(rootView:
            VaultPopoverView(model: model,
                             dismiss: { [weak self] in self?.closePopover() },
                             balanceVisibilityChanged: { [weak self] in self?.updateTitle() })
        )
        observation = model.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { self?.updateTitle() }
        }
        updateTitle()
    }

    private func updateTitle() {
        guard let button = statusItem?.button else { return }
        if hideBalance {
            let image = NSImage(systemSymbolName: "eye.slash", accessibilityDescription: "Balance hidden")
            image?.isTemplate = true
            button.image = image
            button.attributedTitle = NSAttributedString(string: image == nil ? "••••" : "")
            button.toolTip = "HyperVaultBar · Balance hidden"
            button.setAccessibilityLabel("HyperVaultBar, balance hidden")
            return
        }
        button.image = nil
        button.toolTip = nil
        let balance = model.balance
        let label: String
        if model.stale {
            label = "—"
        } else if !model.hasPosition {
            label = "No position"
        } else {
            label = balance.map { Money.format($0, decimals: 0) } ?? "—"
        }
        let font = NSFont.menuBarFont(ofSize: 0)
        let title = NSMutableAttributedString(string: label, attributes: [.font: font])
        if !model.stale, model.hasPosition, let change = model.change, let balance,
           let percent = Money.significantPercent(change, base: balance - change, signed: true) {
            title.append(NSAttributedString(string: " " + percent, attributes: [
                .font: font, .foregroundColor: change >= 0 ? NSColor.systemGreen : NSColor.systemRed
            ]))
        }
        button.attributedTitle = title
        button.setAccessibilityLabel(title.string)
    }

    private func popoverFrame(anchoredTo button: NSStatusBarButton) -> NSRect? {
        guard let window = button.window, let screen = window.screen,
              let view = popover.contentView else { return nil }
        view.layoutSubtreeIfNeeded()
        let size = view.fittingSize
        let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
        let visible = screen.visibleFrame
        let edgeInset = min(8, max(0, (visible.width - size.width) / 2))
        let minX = visible.minX + edgeInset
        let maxX = visible.maxX - edgeInset - size.width
        let scale = screen.backingScaleFactor
        let centeredX = ((anchor.midX - size.width / 2) * scale).rounded() / scale
        let x = min(max(centeredX, minX), maxX)
        let top = min(anchor.minY, visible.maxY) - 4
        let y = (top * scale).rounded(.down) / scale - size.height
        return NSRect(origin: NSPoint(x: x, y: y), size: size)
    }

    private func showPopover(anchoredTo button: NSStatusBarButton) {
        guard let frame = popoverFrame(anchoredTo: button) else { return }
        popover.setFrame(frame, display: true)
        popover.makeKeyAndOrderFront(nil)
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self else { return event }
            let point = event.window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
            if event.window !== self.popover, !self.statusButtonContains(point) {
                self.closePopover()
            }
            return event
        }
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            let point = NSEvent.mouseLocation
            DispatchQueue.main.async {
                guard let self, !self.statusButtonContains(point) else { return }
                self.closePopover()
            }
        }
    }

    private func statusButtonContains(_ screenPoint: NSPoint) -> Bool {
        guard let button = statusItem?.button, let window = button.window else { return false }
        return window.convertToScreen(button.convert(button.bounds, to: nil)).contains(screenPoint)
    }

    private func closePopover() {
        popover.orderOut(nil)
        if let localClickMonitor { NSEvent.removeMonitor(localClickMonitor) }
        if let globalClickMonitor { NSEvent.removeMonitor(globalClickMonitor) }
        localClickMonitor = nil
        globalClickMonitor = nil
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp ||
            (event?.type == .leftMouseUp && event?.modifierFlags.contains(.control) == true) {
            closePopover()
            guard let window = sender.window else { return }
            let anchor = window.convertToScreen(sender.convert(sender.bounds, to: nil))
            let menuOrigin = NSPoint(x: anchor.minX, y: anchor.minY - 12)
            makeMenu().popUp(positioning: nil, at: menuOrigin, in: nil)
        } else if popover.isVisible {
            closePopover()
        } else {
            showPopover(anchoredTo: sender)
        }
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(item("Refresh", action: #selector(refreshSelected)))
        menu.addItem(item(hideBalance ? "Show Balance" : "Hide Balance", action: #selector(visibilitySelected)))
        menu.addItem(.separator())
        menu.addItem(item("Settings", action: #selector(settingsSelected)))
        menu.addItem(.separator())
        menu.addItem(item("Quit", action: #selector(quitSelected)))
        return menu
    }

    private func item(_ title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func refreshSelected() { model.refresh() }
    @objc private func visibilitySelected() { hideBalance.toggle() }
    @objc private func settingsSelected() { SettingsWindowController.shared.show(model: model) }
    @objc private func quitSelected() { NSApp.terminate(nil) }
}

private struct VaultPopoverView: View {
    @ObservedObject var model: BalanceViewModel
    @AppStorage("hideBalance") private var hideBalance = false
    let dismiss: () -> Void
    let balanceVisibilityChanged: () -> Void
    @AppStorage("reduceTransparency") private var reduceTransparency = false
    @State private var confirmHistoryReset = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.displayVaultName).font(.headline)
                    Text("Your vault position").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image("HyperFoundationLogo")
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 27, height: 27)
                    .accessibilityLabel("Hyperliquid logo")
            }

            Text(model.balance.map { model.hasPosition ? Money.format($0) : "No position in this vault" } ?? "—")
                .font(.system(size: 30, weight: .semibold, design: .rounded))
                .contentTransition(.numericText())
            if model.hasPosition {
                HStack(spacing: 8) {
                    Text(model.changeKind.label)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Text(model.changeValueDescription)
                        .foregroundStyle(model.change.map { $0 >= 0 ? Color.green : Color.red } ?? Color.secondary)
                        .monospacedDigit()
                }
                .font(.subheadline)
                .help(model.changeKind.explanation)
            }
            Text("Last updated: \(model.updatedAt?.formatted(date: .omitted, time: .standard) ?? "Never")\(model.stale ? " · stale" : "")")
                .font(.caption).foregroundStyle(.secondary)


            Divider()
            HStack(alignment: .top, spacing: 20) {
                metric("Vault balance", value: model.vaultEquity.map { Money.format($0, decimals: 0) } ?? "—")
                metric("APR", value: model.vaultAPR.map { Money.apr($0) } ?? "—")
            }
            if !issues.isEmpty { issuePanel }
            if model.canResetHistory {
                Button("Restart balance history") { confirmHistoryReset = true }
                    .help("Preserves the damaged file. Historical comparisons will need new samples.")
            }

            Divider()
            HStack(spacing: 12) {
                Button("Refresh now", systemImage: "arrow.clockwise") { model.refresh() }
                Button(hideBalance ? "Show balance" : "Hide balance",
                       systemImage: hideBalance ? "eye" : "eye.slash") {
                    hideBalance.toggle()
                    balanceVisibilityChanged()
                }
            }
            .buttonStyle(PopoverActionStyle())
            Button("Open vault on Hyperliquid", systemImage: "arrow.up.right.square") {
                if let url = URL(string: "https://app.hyperliquid.xyz/vaults/\(model.settings.vaultAddress)") {
                    NSWorkspace.shared.open(url)
                }
            }
            .buttonStyle(PopoverActionStyle())
            Divider()
            HStack(spacing: 12) {
                Button("Settings") {
                    dismiss()
                    // Present Settings after the menu-bar window has been dismissed.
                    DispatchQueue.main.async { SettingsWindowController.shared.show(model: model) }
                }
                Button("Quit", systemImage: "power") { NSApplication.shared.terminate(nil) }
            }
            .buttonStyle(PopoverActionStyle())
        }
        .padding(18)
        .frame(width: 360)
        .background {
            if reduceTransparency {
                Color(nsColor: .windowBackgroundColor)
            } else {
                Rectangle().fill(.regularMaterial)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .confirmationDialog("Restart balance history?", isPresented: $confirmHistoryReset) {
            Button("Restart history", role: .destructive) { model.resetCorruptedHistory() }
        } message: {
            Text("The damaged file will be preserved. 24-hour comparisons and seven-day peak tracking will need new history.")
        }
    }

    private func metric(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.headline)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var issues: [PopoverIssue] {
        var result: [PopoverIssue] = []
        if model.vaultDetailsStale {
            result.append(.init(summary: "Vault balance and APR may be outdated."))
        }
        if let error = model.errorMessage {
            result.append(.init(summary: "Personal balance could not be refreshed.", detail: error))
        }
        if let error = model.historyError {
            result.append(.init(summary: "Balance history needs attention.", detail: error))
        }
        if let error = model.flowError {
            result.append(.init(summary: "Cash-flow adjustment and balance alerts are paused.", detail: error))
        }
        if let error = model.notificationError {
            result.append(.init(summary: "Notifications need attention.", detail: error))
        }
        return result
    }

    private var issuePanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(issues.enumerated()), id: \.offset) { _, issue in
                Label(issue.summary, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            let details = issues.compactMap(\.detail)
            if !details.isEmpty {
                DisclosureGroup("Technical details") {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(details.enumerated()), id: \.offset) { _, detail in
                            Text(detail)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.top, 4)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private struct PopoverIssue {
        let summary: String
        var detail: String? = nil
    }
}

private struct PopoverActionStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PopoverActionBody(configuration: configuration)
    }

    private struct PopoverActionBody: View {
        let configuration: ButtonStyleConfiguration
        @AppStorage("reduceTransparency") private var reduceTransparency = false
        @State private var hovered = false
        private let highlight = Color(red: 48 / 255, green: 120 / 255, blue: 99 / 255)

        var body: some View {
            configuration.label
                .font(.subheadline)
                .foregroundStyle(hovered || configuration.isPressed ? .white : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 11)
                .frame(height: 36)
                .background(hovered || configuration.isPressed
                            ? highlight
                            : Color(nsColor: .controlBackgroundColor),
                            in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    if reduceTransparency && !hovered && !configuration.isPressed {
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 1)
                    }
                }
                .onHover { hovered = $0 }
        }
    }
}

@MainActor
private final class SettingsWindowController {
    static let shared = SettingsWindowController()
    private var window: NSWindow?

    func show(model: BalanceViewModel) {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 700),
                                  styleMask: [.titled, .closable, .miniaturizable],
                                  backing: .buffered, defer: false)
            window.title = "HyperVaultBar Settings"
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        guard let window else { return }
        if !window.isVisible && !window.isMiniaturized {
            let settings = SettingsView(model: model,
                                        onSave: { [weak self] in self?.window?.close() },
                                        onCancel: { [weak self] in self?.window?.close() })
            window.contentViewController = NSHostingController(rootView: settings)
        }
        NSApp.activate(ignoringOtherApps: true)
        if window.isMiniaturized { window.deminiaturize(nil) }
        // An agent app can still be inactive while the activation request takes effect.
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)
    }
}

