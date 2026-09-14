import AppKit
import SwiftUI
import AIUsageCore

/// Photograph native macOS surfaces with sample accounts and the current wallpaper.
@MainActor enum DemoScreenshots {
    static func capture(store: UsageStore) async throws {
        guard let screen = NSScreen.main,
              let wallpaperURL = NSWorkspace.shared.desktopImageURL(for: screen),
              let wallpaper = NSImage(contentsOf: wallpaperURL) else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        let directory = store.paths.file("screenshots")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store.settings.language = AppLanguage.english.rawValue
        let previousApp = NSWorkspace.shared.frontmostApplication
        NSApp.activate(ignoringOtherApps: true)
        defer { previousApp?.activate(options: []) }

        // Cover other apps and desktop filenames without changing the user's wallpaper or windows.
        let backdrop = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        backdrop.isReleasedWhenClosed = false
        backdrop.level = .floating
        backdrop.ignoresMouseEvents = true
        let imageView = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        imageView.wantsLayer = true
        imageView.layer?.contents = wallpaper.cgImage(forProposedRect: nil, context: nil, hints: nil)
        imageView.layer?.contentsGravity = .resizeAspectFill
        imageView.layer?.masksToBounds = true
        backdrop.contentView = imageView
        backdrop.orderFrontRegardless()
        defer { backdrop.close() }

        // Reserve the complete crop in the real menu bar so neighboring accounts/apps never enter it.
        let item = NSStatusBar.system.statusItem(withLength: 390)
        defer { NSStatusBar.system.removeStatusItem(item) }
        guard let button = item.button else { throw CocoaError(.coderInvalidValue) }
        button.title = store.enabledAccounts.compactMap { store.states[$0.id]?.usage?.remainingPercentText(at: store.now) }.joined(separator: "  |  ")
        button.font = .monospacedDigitSystemFont(ofSize: 14, weight: .medium)
        try await Task.sleep(for: .milliseconds(600))
        guard let barWindow = button.window else { throw CocoaError(.coderInvalidValue) }
        let anchor = barWindow.convertToScreen(button.convert(button.bounds, to: nil))

        for (name, appearance) in [("desktop-light", NSAppearance.Name.aqua), ("desktop-dark", .darkAqua)] {
            let popover = NSPopover()
            popover.behavior = .applicationDefined
            popover.animates = false
            popover.appearance = NSAppearance(named: appearance)
            let controller = NSHostingController(rootView: PopoverView(store: store))
            popover.contentViewController = controller
            popover.contentSize = controller.view.fittingSize
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            defer { popover.close() }
            try await Task.sleep(for: .milliseconds(700))
            guard let panel = controller.view.window else { throw CocoaError(.coderInvalidValue) }
            panel.makeFirstResponder(nil)
            try await Task.sleep(for: .milliseconds(150))
            let bounds = NSRect(x: anchor.minX, y: panel.frame.minY - 24, width: anchor.width,
                                height: screen.frame.maxY - panel.frame.minY + 24)
            guard bounds.minX >= screen.frame.minX, bounds.maxX <= screen.frame.maxX,
                  bounds.minY >= screen.frame.minY,
                  panel.frame.minX >= bounds.minX, panel.frame.maxX <= bounds.maxX else {
                throw CocoaError(.coderInvalidValue)
            }
            try await photograph(bounds, screen: screen, output: directory.appendingPathComponent(name + ".png"))
            popover.close()
        }

        let settings = NSWindow(contentRect: NSRect(x: screen.frame.midX - 325, y: screen.frame.midY - 185, width: 650, height: 370),
                                styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        settings.isReleasedWhenClosed = false
        settings.title = "AI Ampilo — Accounts"
        settings.appearance = NSAppearance(named: .aqua)
        settings.level = .floating
        settings.contentViewController = NSHostingController(rootView: AccountsTab(store: store).padding(16))
        settings.setContentSize(NSSize(width: 650, height: 300))
        settings.center()
        settings.makeKeyAndOrderFront(nil)
        defer { settings.close() }
        try await Task.sleep(for: .milliseconds(700))
        try await photograph(settings.frame.insetBy(dx: -28, dy: -28), screen: screen,
                             output: directory.appendingPathComponent("desktop-accounts.png"))
    }

    private static func photograph(_ rect: NSRect, screen: NSScreen, output: URL) async throws {
        let top = (NSScreen.screens.first?.frame.maxY ?? screen.frame.maxY) - rect.maxY
        let region = "\(Int(rect.minX)),\(Int(top)),\(Int(rect.width)),\(Int(rect.height))"
        let result = try await ProcessRunner().run("/usr/sbin/screencapture", arguments: ["-x", "-R", region, output.path], timeout: 10)
        guard result.exitCode == 0 else { throw CocoaError(.fileWriteUnknown) }
    }
}
