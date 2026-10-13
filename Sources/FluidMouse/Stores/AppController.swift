import AppKit
import ApplicationServices
import ServiceManagement
import Combine
import OSLog

final class AppController: ObservableObject {
    private let logger = Logger(subsystem: "br.com.douglas.fluido", category: "lifecycle")
    private let service = ScrollService()
    private let defaults = UserDefaults.standard
    private var refreshTimer: Timer?
    private var observers: [NSObjectProtocol] = []
    @Published var enabled: Bool { didSet { defaults.set(enabled, forKey: "enabled"); reconcile() } }
    @Published var speed: Double { didSet { defaults.set(speed, forKey: "speed"); updateConfiguration() } }
    @Published var smoothness: Double { didSet { defaults.set(smoothness, forKey: "smoothness"); updateConfiguration() } }
    @Published var reverse: Bool { didSet { defaults.set(reverse, forKey: "reverse"); updateConfiguration() } }
    @Published private(set) var trusted = false
    @Published private(set) var running = false
    @Published private(set) var smoothyRunning = false
    @Published private(set) var status = "Verificando…"
    @Published private(set) var wheelCount = 0
    @Published private(set) var trackpadCount = 0
    @Published private(set) var frameCount = 0
    @Published private(set) var loginEnabled = false
    @Published private(set) var loginNeedsApproval = false
    @Published var errorMessage: String?
    var statusChanged: (() -> Void)?
    private var sleeping = false

    init() {
        enabled = defaults.object(forKey: "enabled") as? Bool ?? true
        let savedSpeed = defaults.object(forKey: "speed") as? Double ?? 2
        speed = savedSpeed.isFinite ? min(4, max(0.5, savedSpeed)) : 2
        let savedSmoothness = defaults.object(forKey: "smoothness") as? Double ?? 0.5
        smoothness = savedSmoothness.isFinite ? min(1, max(0, savedSmoothness)) : 0.5
        reverse = defaults.bool(forKey: "reverse")
    }

    func start() {
        updateConfiguration(); reconcile()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.reconcile() }
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main) { [weak self] _ in self?.service.cancel() })
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification,
            object: nil, queue: .main) { [weak self] _ in self?.sleeping = true; self?.reconcile() })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification,
            object: nil, queue: .main) { [weak self] _ in self?.sleeping = false; self?.reconcile() })
        logger.info("FluidMouse launched")
    }

    func stop() {
        refreshTimer?.invalidate(); service.stop()
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }; observers.removeAll()
    }

    func reconcile() {
        trusted = AXIsProcessTrusted()
        smoothyRunning = NSWorkspace.shared.runningApplications.contains {
            $0.bundleURL?.lastPathComponent == "Smoothy.app" || $0.localizedName == "Smoothy"
        }
        if enabled && trusted && !smoothyRunning && !sleeping {
            running = service.start()
            status = running ? "Rolagem suave ativa" : "Não foi possível capturar a rolagem"
        } else {
            if service.isRunning { service.stop() }
            running = false
            if !enabled { status = "Suavização pausada" }
            else if smoothyRunning { status = "Feche o Smoothy para ativar" }
            else if !trusted { status = "Aguardando Acessibilidade" }
            else { status = "Mac em repouso" }
        }
        wheelCount = service.wheels; trackpadCount = service.passedContinuous; frameCount = service.frames
        loginEnabled = SMAppService.mainApp.status == .enabled
        loginNeedsApproval = SMAppService.mainApp.status == .requiresApproval
        statusChanged?()
    }

    private func updateConfiguration() {
        service.cancel()
        service.speed = speed; service.smoothness = smoothness; service.reverse = reverse
    }

    func grantPermission() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    func setLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch { errorMessage = "Não foi possível alterar o início automático: \(error.localizedDescription)" }
        reconcile()
    }

    func openLoginSettings() { SMAppService.openSystemSettingsLoginItems() }
    /// Used once when installing under the new name, if login was previously enabled.
    func migrateLoginRegistration() {
        do { try SMAppService.mainApp.unregister() }
        catch { logger.info("Previous login registration unavailable; registering the current app") }
        setLogin(true)
    }
    func reset() { speed = 2; smoothness = 0.5; reverse = false }
}
