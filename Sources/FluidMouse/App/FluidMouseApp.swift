import AppKit
import SwiftUI

@main
struct FluidMouseApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let controller = AppController()
    private var statusItem: NSStatusItem!
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let identifier = Bundle.main.bundleIdentifier ?? "br.com.douglas.fluido"
        if NSRunningApplication.runningApplications(withBundleIdentifier: identifier).count > 1 {
            NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
                .first { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }?.activate()
            NSApp.terminate(nil); return
        }
        let appMenu = NSMenu()
        let root = NSMenuItem(); root.submenu = NSMenu()
        root.submenu?.addItem(withTitle: "Sobre o FluidMouse", action: #selector(showSettings), keyEquivalent: ",").target = self
        root.submenu?.addItem(.separator())
        root.submenu?.addItem(withTitle: "Sair do FluidMouse", action: #selector(quit), keyEquivalent: "q").target = self
        appMenu.addItem(root); NSApp.mainMenu = appMenu
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        controller.statusChanged = { [weak self] in self?.updateMenu() }
        if CommandLine.arguments.contains("--migrate-login") { controller.migrateLoginRegistration() }
        controller.start()
        if !controller.loginEnabled || !controller.trusted { showSettings() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings(); return true
    }

    func applicationWillTerminate(_ notification: Notification) { controller.stop() }

    @objc func showSettings() {
        if window == nil {
            let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 580, height: 885),
                styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            panel.title = "FluidMouse — rolagem suave"
            panel.isReleasedWhenClosed = false
            panel.contentView = NSHostingView(rootView: ContentView(controller: controller))
            panel.center(); window = panel
        }
        window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }

    private func updateMenu() {
        statusItem.button?.image = NSImage(systemSymbolName: controller.running ? "computermouse.fill" : "computermouse",
                                          accessibilityDescription: "FluidMouse")
        statusItem.button?.toolTip = "FluidMouse — \(controller.status)"
        let menu = NSMenu()
        let heading = NSMenuItem(title: "FluidMouse", action: nil, keyEquivalent: ""); heading.isEnabled = false
        menu.addItem(heading)
        let state = NSMenuItem(title: controller.status, action: nil, keyEquivalent: ""); state.isEnabled = false
        menu.addItem(state); menu.addItem(.separator())
        let toggle = NSMenuItem(title: controller.enabled ? "Pausar suavização" : "Ativar suavização",
            action: #selector(toggleEnabled), keyEquivalent: "")
        toggle.target = self; menu.addItem(toggle)
        let settings = NSMenuItem(title: "Ajustes e teste…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self; menu.addItem(settings)
        if !controller.trusted {
            let permission = NSMenuItem(title: "Conceder Acessibilidade…", action: #selector(grantPermission), keyEquivalent: "")
            permission.target = self; menu.addItem(permission)
        }
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Sair do FluidMouse", action: #selector(quit), keyEquivalent: "q")
        quit.target = self; menu.addItem(quit)
        statusItem.menu = menu
    }

    @objc private func toggleEnabled() { controller.enabled.toggle() }
    @objc private func grantPermission() { controller.grantPermission() }
    @objc private func quit() { NSApp.terminate(nil) }
}
