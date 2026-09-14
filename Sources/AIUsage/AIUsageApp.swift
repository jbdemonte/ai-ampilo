import SwiftUI
import AppKit
import Darwin
import Observation
import AIUsageCore

@main struct AIUsageApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    var body: some Scene {
        MenuBarExtra(isInserted: Binding(get: { !delegate.store.settings.perAccountMenu || delegate.store.enabledAccounts.isEmpty }, set: { _ in })) {
            PopoverView(store: delegate.store).id(delegate.store.settings.language)
        } label: { MenuBarLabel(store: delegate.store) }
        .menuBarExtraStyle(.window)
        Settings {
            SettingsView(store: delegate.store).id(delegate.store.settings.language)
                .background(SettingsWindowActivation())
        }
    }
}
@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = UsageStore()
    private var statusItems: [UUID: NSStatusItem] = [:]
    private var popovers: [UUID: NSPopover] = [:]
    private var terminating = false
    private var terminationReady = false
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        Task {
            await store.start(); observe(); syncStatusItems()
            if CommandLine.arguments.contains("--render-context") {
                do { try await DemoScreenshots.capture(store: store) }
                catch {
                    fputs("Could not capture the demo desktop. Check screen recording permission and available menu bar space.\n", stderr)
                    await store.stop(); Darwin.exit(EXIT_FAILURE)
                }
                await store.stop(); Darwin.exit(EXIT_SUCCESS)
            }
            if CommandLine.arguments.contains("--render-demo") {
                await renderDemo(); await store.stop()
                // The command-line renderer must exit even when AppKit vetoes termination.
                Darwin.exit(EXIT_SUCCESS)
            }
        }
    }
    private func observe() {
        withObservationTracking {
            _ = store.settings; _ = store.accounts; _ = store.states; _ = store.now
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.syncStatusItems(); self?.observe() }
        }
    }
    private func syncStatusItems() {
        let visible = store.settings.perAccountMenu ? store.enabledAccounts : []
        for id in Array(statusItems.keys) where !visible.contains(where: { $0.id == id }) {
            if let item = statusItems.removeValue(forKey: id) { NSStatusBar.system.removeStatusItem(item) }
            popovers.removeValue(forKey: id)?.close()
        }
        for account in visible {
            let item = statusItems[account.id] ?? NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.button?.image = NSImage(systemSymbolName: account.provider.symbol, accessibilityDescription: account.provider.title)
            item.button?.image?.isTemplate = true; item.button?.imagePosition = .imageLeading
            let usage = store.states[account.id]?.usage
            let title = NSMutableAttributedString(string: " " + account.label, attributes: [.foregroundColor: NSColor.labelColor])
            if store.settings.showPercent {
                if let value = usage?.remainingPercent(at: store.now) {
                    let blocked = usage?.windows.contains { $0.severity == .blocked } == true
                    let color: NSColor = blocked || value <= 5 ? .systemRed : value <= 20 ? .systemOrange : .labelColor
                    title.append(NSAttributedString(string: " " + (usage?.remainingPercentText(at: store.now) ?? "—"), attributes: [.foregroundColor: color]))
                } else { title.append(NSAttributedString(string: " —")) }
            }
            item.button?.attributedTitle = title
            let resetNote = usage?.hasUnconfirmedReset(at: store.now) == true ? " — " + L("Réinitialisation non confirmée") : ""
            item.button?.toolTip = account.displayName + " — " + L("Quota restant") + resetNote
            item.button?.setAccessibilityValue((usage?.remainingPercentText(at: store.now) ?? "—") + resetNote)
            item.button?.target = self; item.button?.action = #selector(toggleAccount(_:))
            item.button?.identifier = NSUserInterfaceItemIdentifier(account.id.uuidString)
            statusItems[account.id] = item
        }
    }
    @objc private func toggleAccount(_ sender: NSStatusBarButton) {
        guard let raw = sender.identifier?.rawValue, let id = UUID(uuidString: raw) else { return }
        let popover = popovers[id] ?? NSPopover(); popovers[id] = popover
        if popover.isShown { popover.close(); return }
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: PopoverView(store: store, only: id))
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if terminationReady { return .terminateNow }
        guard !terminating else { return .terminateCancel }; terminating = true
        // Returning .terminateLater from a MainActor task enters AppKit's nested event loop
        // while that task still owns the executor, starving our async cleanup.
        Task {
            await store.stop(); terminationReady = true
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
        return .terminateCancel
    }
    private func renderDemo() async {
        let directory = store.paths.root.appendingPathComponent("screenshots")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let language = store.settings.language
        store.settings.language = AppLanguage.english.rawValue
        await render(MenuBarLabel(store: store), name: "menubar", size: NSSize(width: 520, height: 30), directory: directory, fitContent: true)
        await render(PopoverView(store: store).environment(\.colorScheme, .light), name: "popover-light", size: NSSize(width: 320, height: 620), directory: directory, fitContent: true)
        await render(PopoverView(store: store).environment(\.colorScheme, .dark), name: "popover-dark", size: NSSize(width: 320, height: 620), directory: directory, fitContent: true)
        await render(SettingsView(store: store), name: "settings", size: NSSize(width: 650, height: 570), directory: directory)
        await render(AccountsTab(store: store).padding(16), name: "settings-accounts", size: NSSize(width: 650, height: 280), directory: directory)
        await render(AdvancedTab(store: store).padding(16), name: "settings-advanced", size: NSSize(width: 650, height: 530), directory: directory)
        for language in AppLanguage.allCases where language != .english {
            store.settings.language = language.rawValue
            await render(PopoverView(store: store), name: "popover-" + language.rawValue, size: NSSize(width: 320, height: 620), directory: directory, fitContent: true)
        }
        store.settings.language = "de"
        await render(SettingsView(store: store), name: "settings-de", size: NSSize(width: 650, height: 570), directory: directory)
        store.settings.language = language
        await render(AccountEditor(store: store, account: Account(provider: .cursor)), name: "cursor-permission", size: NSSize(width: 578, height: 400), directory: directory, fitContent: true)
    }
    private func render<V: View>(_ view: V, name: String, size: NSSize, directory: URL, fitContent: Bool = false) async {
        let window = NSWindow(contentRect: NSRect(origin: .init(x: 50, y: 50), size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let dark = name.contains("dark")
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let host = NSHostingView(rootView: view.background(dark ? Color(nsColor: .darkGray) : .white))
        window.contentView = host; window.setContentSize(size); window.orderFrontRegardless()
        if fitContent { window.setContentSize(host.fittingSize) }
        try? await Task.sleep(for: .milliseconds(600))
        host.layoutSubtreeIfNeeded()
        if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            if let data = bitmap.representation(using: .png, properties: [:]) { try? data.write(to: directory.appendingPathComponent(name + ".png")) }
        }
        window.close()
    }
}
