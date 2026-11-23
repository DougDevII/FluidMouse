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
        appMenu.addItem(root)

        // "Ir Para" (UI-01): atalhos reais de menu ⌘1–4 que mudam a seleção
        // da sidebar — rotas de teclado descobríveis, com rótulo e imagem
        // expostos na barra de menus enquanto o app está ativo.
        let goToMenu = NSMenu(title: "Ir Para")
        for (index, section) in ContentView.Section.allCases.enumerated() {
            let item = NSMenuItem(title: section.title,
                                  action: #selector(selectSection(_:)),
                                  keyEquivalent: String(index + 1))
            item.tag = index
            item.keyEquivalentModifierMask = .command
            item.target = self
            goToMenu.addItem(item)
        }
        let goToItem = NSMenuItem()
        goToItem.title = "Ir Para"
        goToItem.submenu = goToMenu
        appMenu.addItem(goToItem)

        NSApp.mainMenu = appMenu

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        buildStatusMenu()
        statusItem.menu = statusMenu
        controller.statusChanged = { [weak self] in self?.updateMenu() }
        if CommandLine.arguments.contains("--migrate-login") { controller.migrateLoginRegistration() }
        controller.start()
        updateMenu()
        if !controller.loginEnabled || !controller.trusted { showSettings() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings(); return true
    }

    func applicationWillTerminate(_ notification: Notification) { controller.stop() }

    @objc func showSettings() {
        if window == nil {
            let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 880, height: 640),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered, defer: false)
            panel.title = "FluidMouse"
            panel.titlebarAppearsTransparent = true
            panel.titleVisibility = .hidden
            panel.isMovableByWindowBackground = true
            panel.minSize = NSSize(width: 760, height: 560)
            panel.isReleasedWhenClosed = false
            panel.contentView = NSHostingView(rootView: ContentView(controller: controller))
            panel.center(); window = panel
        }
        window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: Menu da barra de status

    /// O menu é criado uma vez e apenas os textos/ícones são atualizados.
    /// Trocar o objeto `NSMenu` enquanto o usuário interage com ele faz o
    /// AppKit descartar o clique.
    private let statusMenu = NSMenu()
    private let appHeaderItem = NSMenuItem()
    private let appStateItem = NSMenuItem()
    private let mouseHeaderItem = NSMenuItem()
    private let batteryItem = NSMenuItem()
    private let linkItem = NSMenuItem()
    private let dpiItem = NSMenuItem()
    private let pollingItem = NSMenuItem()
    private let sleepingItem = NSMenuItem()
    private let toggleItem = NSMenuItem()
    private let refreshItem = NSMenuItem()
    private let settingsItem = NSMenuItem()
    private let permissionItem = NSMenuItem()
    private let quitItem = NSMenuItem()

    private func buildStatusMenu() {
        statusMenu.autoenablesItems = true

        appHeaderItem.attributedTitle = Self.attributed("FluidMouse", weight: .semibold, color: .secondaryLabelColor)
        appHeaderItem.image = NSImage(systemSymbolName: "computermouse.fill", accessibilityDescription: nil)
        appHeaderItem.image?.isTemplate = true
        appHeaderItem.isEnabled = false
        statusMenu.addItem(appHeaderItem)

        appStateItem.isEnabled = false
        statusMenu.addItem(appStateItem)
        statusMenu.addItem(.separator())

        mouseHeaderItem.attributedTitle = Self.attributed("Mouse", weight: .semibold, color: .secondaryLabelColor)
        mouseHeaderItem.image = NSImage(systemSymbolName: "computermouse", accessibilityDescription: nil)
        mouseHeaderItem.image?.isTemplate = true
        mouseHeaderItem.isEnabled = false
        statusMenu.addItem(mouseHeaderItem)

        for item in [batteryItem, linkItem, dpiItem, pollingItem, sleepingItem] {
            item.isEnabled = false
            statusMenu.addItem(item)
        }
        statusMenu.addItem(.separator())

        toggleItem.action = #selector(toggleEnabled); toggleItem.target = self
        statusMenu.addItem(toggleItem)

        refreshItem.title = "Atualizar leitura do mouse"
        refreshItem.action = #selector(refreshMouse); refreshItem.target = self
        statusMenu.addItem(refreshItem)

        settingsItem.title = "Ajustes…"
        settingsItem.action = #selector(showSettings); settingsItem.target = self
        settingsItem.keyEquivalent = ","
        statusMenu.addItem(settingsItem)

        permissionItem.title = "Conceder Acessibilidade…"
        permissionItem.action = #selector(grantPermission); permissionItem.target = self
        statusMenu.addItem(permissionItem)

        statusMenu.addItem(.separator())

        quitItem.title = "Sair do FluidMouse"
        quitItem.action = #selector(quit); quitItem.target = self
        quitItem.keyEquivalent = "q"
        statusMenu.addItem(quitItem)
    }

    private func updateMenu() {
        statusItem.button?.image = Self.statusSymbol(for: controller)
        statusItem.button?.toolTip = Self.tooltip(for: controller)

        let captureState = ScrollCaptureState.from(enabled: controller.enabled, trusted: controller.trusted,
                                                   smoothyRunning: controller.smoothyRunning,
                                                   running: controller.running)
        appStateItem.attributedTitle = Self.attributed(captureState.title, weight: .regular, color: .labelColor)
        appStateItem.image = NSImage(systemSymbolName: captureState.symbol, accessibilityDescription: nil)
        appStateItem.image?.isTemplate = true
        toggleItem.title = controller.enabled ? "Pausar suavização" : "Ativar suavização"
        toggleItem.image = NSImage(systemSymbolName: controller.enabled ? "pause.fill" : "playpause.fill",
                                   accessibilityDescription: nil)
        toggleItem.image?.isTemplate = true
        permissionItem.isHidden = controller.trusted

        let rapoo = controller.rapooStatus
        mouseHeaderItem.isHidden = rapoo == nil
        batteryItem.isHidden = rapoo?.percent == nil
        linkItem.isHidden = rapoo == nil
        dpiItem.isHidden = rapoo?.dpi == nil
        pollingItem.isHidden = rapoo == nil
        sleepingItem.isHidden = (rapoo?.readable ?? false)
        refreshItem.isHidden = rapoo == nil

        if let rapoo {
            if let percent = rapoo.percent {
                let charging = rapoo.charging == true ? " · carregando" : ""
                batteryItem.attributedTitle = Self.attributed("Bateria \(percent)%\(charging)",
                                                             weight: .regular, color: .labelColor)
                batteryItem.image = NSImage(systemSymbolName: Self.batterySymbol(percent: percent,
                                                                                   charging: rapoo.charging == true),
                                             accessibilityDescription: nil)
                batteryItem.image?.isTemplate = true
            }
            let link = rapoo.linkDescription ?? "Link desconhecido"
            linkItem.attributedTitle = Self.attributed(link, weight: .regular, color: .labelColor)
            linkItem.image = NSImage(systemSymbolName: "antenna.radiowaves.left.and.right", accessibilityDescription: nil)
            linkItem.image?.isTemplate = true

            if let table = rapoo.dpi, let stage = rapoo.activeStage, stage < table.stages.count {
                let scale = max(rapoo.dpiScale, 1)
                dpiItem.attributedTitle = Self.attributed("DPI \(table.stages[stage] * scale) · estágio \(stage + 1)",
                                                          weight: .regular, color: .labelColor)
                dpiItem.image = NSImage(systemSymbolName: "target", accessibilityDescription: nil)
                dpiItem.image?.isTemplate = true
            }
            let hz = RapooPollingReadout.activeHz(link: rapoo.link,
                                                  receiverHz: rapoo.receiverHz, wiredHz: rapoo.wiredHz)
            pollingItem.attributedTitle = Self.attributed(hz.map { "Polling \($0) Hz" } ?? "Polling não lido",
                                                          weight: .regular, color: .labelColor)
            pollingItem.image = NSImage(systemSymbolName: "speedometer", accessibilityDescription: nil)
            pollingItem.image?.isTemplate = true
            sleepingItem.attributedTitle = Self.attributed("Dormindo — mova o mouse",
                                                           weight: .regular, color: .secondaryLabelColor)
            sleepingItem.image = NSImage(systemSymbolName: "moon.zzz", accessibilityDescription: nil)
            sleepingItem.image?.isTemplate = true
        }
    }

    /// Ícone do menu com o nível de bateria dentro da silhueta do mouse.
    private static func statusSymbol(for controller: AppController) -> NSImage? {
        guard let rapoo = controller.rapooStatus, let percent = rapoo.percent else {
            return NSImage(systemSymbolName: controller.running ? "computermouse.fill" : "computermouse",
                           accessibilityDescription: "FluidMouse")
        }
        let level = CGFloat(max(0, min(percent, 100))) / 100
        let image = NSImage(size: NSSize(width: 18, height: 20), flipped: false) { _ in
            let body = NSBezierPath(roundedRect: NSRect(x: 3.5, y: 1.5, width: 11, height: 17),
                                    xRadius: 5.5, yRadius: 5.5)
            NSColor.black.setStroke()
            body.lineWidth = 1.4
            body.stroke()

            NSGraphicsContext.saveGraphicsState()
            body.addClip()
            NSColor.black.setFill()
            NSRect(x: 3.5, y: 1.5, width: 11, height: 17 * level).fill()
            NSGraphicsContext.restoreGraphicsState()

            let wheel = NSBezierPath(roundedRect: NSRect(x: 8, y: 12, width: 2, height: 4),
                                     xRadius: 1, yRadius: 1)
            NSColor.black.setFill()
            wheel.fill()
            NSGraphicsContext.saveGraphicsState()
            wheel.addClip()
            NSGraphicsContext.current?.cgContext.clear(NSRect(x: 3.5, y: 1.5, width: 11, height: 17 * level))
            NSGraphicsContext.restoreGraphicsState()
            return true
        }
        image.accessibilityDescription = "FluidMouse — bateria do mouse \(percent)%"
        image.isTemplate = true
        return image
    }

    private static func batterySymbol(percent: Int, charging: Bool) -> String {
        if charging { return "battery.100.bolt" }
        switch percent {
        case ..<10: return "battery.0"
        case ..<25: return "battery.25"
        case ..<50: return "battery.50"
        case ..<75: return "battery.75"
        default: return "battery.100"
        }
    }

    private static func tooltip(for controller: AppController) -> String {
        var parts = [controller.status]
        if let rapoo = controller.rapooStatus, let percent = rapoo.percent {
            parts.append("Mouse \(percent)%")
        }
        return parts.joined(separator: " · ")
    }

    private static func attributed(_ title: String, weight: NSFont.Weight,
                                   color: NSColor) -> NSAttributedString {
        NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: weight),
            .foregroundColor: color,
        ])
    }

    /// Comando ⌘1–4 do menu "Ir Para": publica a seção escolhida; a
    /// ContentView assina o comando e muda a seleção real da sidebar.
    @objc private func selectSection(_ sender: NSMenuItem) {
        NotificationCenter.default.post(name: ContentView.selectSectionCommand, object: sender.tag)
    }

    @objc private func toggleEnabled() { controller.enabled.toggle() }
    @objc private func grantPermission() { controller.grantPermission() }
    @objc private func refreshMouse() { controller.refreshRapoo() }
    @objc private func quit() { NSApp.terminate(nil) }
}
