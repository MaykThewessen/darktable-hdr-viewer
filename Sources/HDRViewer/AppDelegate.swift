import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var window: NSWindow?
    private var viewController: HDRViewController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenu()
        setupWindow()
        NSApp.activate(ignoringOtherApps: true)
    }

    // Keep the app (and the IPC server) alive when the preview window is closed.
    // The window is created with isReleasedWhenClosed = false, so closing it just
    // orders it out; the next frame from darktable re-shows it (see
    // HDRViewController.handleFrame). Quit explicitly via the menu (Cmd-Q).
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    // Clicking the Dock icon (or `open`-ing the app again) while no window is
    // visible must bring the preview back. Without this the window is
    // unrecoverable once closed. Returning true lets AppKit do its default
    // un-hide/activate too.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            showPreviewWindow(nil)
        }
        return true
    }

    // MARK: - Window control

    /// Re-show (creating if necessary) the preview window and bring it forward.
    /// Safe to call repeatedly; used by the Window menu item, Dock reopen, and as
    /// a recovery path. Never crashes if the window was released.
    @objc func showPreviewWindow(_ sender: Any?) {
        if window == nil {
            setupWindow()
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Private

    private func setupWindow() {
        let contentRect = NSRect(x: 0, y: 0, width: 800, height: 600)
        let styleMask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]

        let window = NSWindow(
            contentRect: contentRect,
            styleMask: styleMask,
            backing: .buffered,
            defer: false
        )
        window.title = "darktable HDR Preview"
        window.center()
        window.isReleasedWhenClosed = false

        // Remember position/size between launches so the daily-driver opens where
        // the user left it (handy when it lives on a specific HDR display).
        window.setFrameAutosaveName("DTHDRPreviewWindow")

        // Allow the window to display HDR content on HDR-capable displays.
        // EDR is opt-in per CAMetalLayer (see HDRMetalView); nothing extra is
        // required at the window level.
        if #available(macOS 12.0, *) {
            // No-op: documented here so the EDR contract is visible in one place.
        }

        let vc = HDRViewController()
        window.contentViewController = vc
        window.makeKeyAndOrderFront(nil)

        self.window = window
        self.viewController = vc
    }

    private func setupMenu() {
        let mainMenu = NSMenu()
        let appName = ProcessInfo.processInfo.processName

        // MARK: App menu
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu

        appMenu.addItem(
            withTitle: "About \(appName)",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        appMenu.addItem(.separator())

        let hideItem = appMenu.addItem(
            withTitle: "Hide \(appName)",
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h"
        )
        hideItem.keyEquivalentModifierMask = [.command]

        let hideOthersItem = appMenu.addItem(
            withTitle: "Hide Others",
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h"
        )
        hideOthersItem.keyEquivalentModifierMask = [.command, .option]

        appMenu.addItem(
            withTitle: "Show All",
            action: #selector(NSApplication.unhideAllApplications(_:)),
            keyEquivalent: ""
        )
        appMenu.addItem(.separator())

        appMenu.addItem(
            withTitle: "Quit \(appName)",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )

        // MARK: Window menu
        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenuItem.submenu = windowMenu

        windowMenu.addItem(
            withTitle: "Minimize",
            action: #selector(NSWindow.performMiniaturize(_:)),
            keyEquivalent: "m"
        )
        windowMenu.addItem(
            withTitle: "Zoom",
            action: #selector(NSWindow.performZoom(_:)),
            keyEquivalent: ""
        )
        windowMenu.addItem(.separator())

        // Recovery path: re-open the preview window if it was closed. Targeting
        // the delegate (self) keeps this working even when no window exists, when
        // a first-responder chain selector would be disabled.
        let reopenItem = windowMenu.addItem(
            withTitle: "darktable HDR Preview",
            action: #selector(AppDelegate.showPreviewWindow(_:)),
            keyEquivalent: "0"
        )
        reopenItem.keyEquivalentModifierMask = [.command]
        reopenItem.target = self

        NSApp.mainMenu = mainMenu
        // Let AppKit manage the standard Window menu contents (window list,
        // "Bring All to Front") in addition to our custom items.
        NSApp.windowsMenu = windowMenu
    }
}
