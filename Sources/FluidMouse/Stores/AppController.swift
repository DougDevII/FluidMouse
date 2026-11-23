import AppKit
import ApplicationServices
import ServiceManagement
import Combine
import OSLog
import FluidMouseCore

final class AppController: ObservableObject {
    private let logger = Logger(subsystem: "br.com.douglas.fluido", category: "lifecycle")
    private let service: ScrollService
    private let buttonService: ButtonService
    private let devices = DeviceService()
    private let rapoo = RapooHidService()
    private let defaults = UserDefaults.standard
    private var refreshTimer: Timer?
    private var rapooRefreshTimer: Timer?
    private var rapooRefreshInterval: TimeInterval = 5
    private var observers: [NSObjectProtocol] = []
    @Published var enabled: Bool { didSet { defaults.set(enabled, forKey: "enabled"); reconcile() } }
    @Published var speed: Double { didSet { defaults.set(speed, forKey: "speed"); updateConfiguration() } }
    @Published var smoothness: Double { didSet { defaults.set(smoothness, forKey: "smoothness"); updateConfiguration() } }
    @Published var reverse: Bool { didSet { defaults.set(reverse, forKey: "reverse"); updateConfiguration() } }
    /// Button number as reported by `mouseEventButtonNumber` (0 left, 1 right,
    /// 2 middle, extras from 3) mapped to what the button does.
    @Published var buttonMappings: [Int: ButtonAction] {
        didSet {
            if let data = try? JSONEncoder().encode(buttonMappings) {
                defaults.set(data, forKey: "buttonMappings")
            }
            buttonService.mappings = buttonMappings
            buttonService.refreshTap(knownTrusted: trusted)
        }
    }
    @Published private(set) var trusted = false
    @Published private(set) var running = false
    @Published private(set) var smoothyRunning = false
    @Published private(set) var status = "Verificando…"
    @Published private(set) var wheelCount = 0
    @Published private(set) var trackpadCount = 0
    @Published private(set) var frameCount = 0
    @Published private(set) var loginEnabled = false
    @Published private(set) var loginNeedsApproval = false
    @Published private(set) var detectedDevices: [DeviceService.DeviceInfo] = []
    /// Live view of the VT9 Pro configuration channel; nil does not mean
    /// "absent", it means the channel has nothing to show (device missing).
    @Published private(set) var rapooStatus: RapooHidService.Status?
    /// True while the UI asks the user to press the button to be configured.
    @Published private(set) var awaitingButtonPress = false
    /// Button number reported by the press-to-identify flow, already consumed by the UI.
    @Published private(set) var capturedButton: Int?
    @Published var errorMessage: String?
    /// Live state of each named Rapoo hardware write: pending until the
    /// explicit callback arrives, then success/failure; interrupted on
    /// disconnect. Stale callbacks (old token or old connection generation)
    /// are ignored by the tracker.
    @Published private(set) var rapooOperations: [String: RapooOperationTracker.Snapshot] = [:]
    /// Tabela de DPI editada e ainda não confirmada pelo mouse. Fica aqui (e não
    /// na view) para sobreviver à troca de aba e à desconexão.
    @Published var rapooDpiDraft: RapooDpiDraft?
    /// True while a status read from the mouse is in flight.
    @Published private(set) var rapooRefreshing = false
    var statusChanged: (() -> Void)?
    private var sleeping = false
    private let operationsTracker = RapooOperationTracker()

    init() {
        service = ScrollService()
        buttonService = ButtonService(scrollService: service)
        enabled = defaults.object(forKey: "enabled") as? Bool ?? true
        let savedSpeed = defaults.object(forKey: "speed") as? Double ?? 2
        speed = savedSpeed.isFinite ? min(4, max(0.5, savedSpeed)) : 2
        let savedSmoothness = defaults.object(forKey: "smoothness") as? Double ?? 0.5
        smoothness = savedSmoothness.isFinite ? min(1, max(0, savedSmoothness)) : 0.5
        reverse = defaults.bool(forKey: "reverse")
        if let data = defaults.data(forKey: "buttonMappings"),
           let mappings = try? JSONDecoder().decode([Int: ButtonAction].self, from: data) {
            buttonMappings = mappings.filter { $1 != .unchanged }
        } else {
            buttonMappings = [:]
        }
        buttonService.mappings = buttonMappings
        devices.onChange = { [weak self] in self?.reflectDevices() }
        rapoo.onChange = { [weak self] status, generation in
            guard let self else { return }
            // Single main-queue hop carrying the coherent snapshot captured by
            // the service; status/generation are not re-read afterwards.
            DispatchQueue.main.async {
                self.rapooStatus = status
                self.operationsTracker.adoptConnectionGeneration(generation)
                self.rapooOperations = self.operationsTracker.snapshots
            }
        }
        operationsTracker.onChange = { [weak self] in
            guard let self else { return }
            DispatchQueue.main.async { self.rapooOperations = self.operationsTracker.snapshots }
        }
    }

    func start() {
        // Two instances interleave the same HID channel: answers stolen
        // between processes make every probe look silent. De-duplicate by
        // terminating the other copy.
        let duplicates = NSRunningApplication.runningApplications(
            withBundleIdentifier: Bundle.main.bundleIdentifier ?? "br.com.douglas.fluido")
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        if !duplicates.isEmpty {
            logger.info("encerrando \(duplicates.count) instância(s) duplicada(s) do FluidMouse")
            duplicates.forEach { $0.terminate() }
            // Wait a beat so the HID channel of the old instance actually
            // closes before this one opens it.
            usleep(800_000)
        }
        devices.start(); reflectDevices()
        rapoo.start()
        updateConfiguration(); reconcile()
        rapooRefreshTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.tickRapoo()
        }
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
        refreshTimer?.invalidate(); rapooRefreshTimer?.invalidate()
        service.stop(); buttonService.stop(); rapoo.stop(); devices.stop()
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }; observers.removeAll()
    }

    func reconcile() {
        trusted = AXIsProcessTrusted()
        buttonService.refreshTap(knownTrusted: trusted)
        smoothyRunning = NSWorkspace.shared.runningApplications.contains {
            $0.bundleURL?.lastPathComponent == "Smoothy.app" || $0.localizedName == "Smoothy"
        }
        if enabled && trusted && !smoothyRunning && !sleeping {            running = service.start()
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
    /// Removes every button mapping; each button returns to its native behavior.
    func clearButtonMappings() { buttonMappings = [:] }

    private func reflectDevices() { detectedDevices = devices.devices }

    /// Press-to-identify: the UI asks the user to press the physical button.
    func beginButtonCapture() {
        guard !awaitingButtonPress else { return }
        guard trusted else {
            errorMessage = "Conceda Acessibilidade antes de identificar botões."
            return
        }
        capturedButton = nil
        awaitingButtonPress = true
        buttonService.beginCapture { [weak self] button in
            guard let self else { return }
            self.awaitingButtonPress = false
            self.capturedButton = button
            self.buttonService.endCapture()
        }
    }

    func cancelButtonCapture() {
        guard awaitingButtonPress else { return }
        awaitingButtonPress = false
        buttonService.endCapture()
    }

    /// The view consumes the captured button number once, then clears it.
    func clearCapturedButton() { capturedButton = nil }

    // MARK: VT9 Pro (ponte para a RapooHidService)

    private func rapooFailure(_ error: RapooHidService.RapooError?) {
        guard let error else { return }
        errorMessage = error.localizedDescription
    }

    /// Runs one named hardware write with operation tracking. The tracker
    /// rejects stale callbacks (a token invalidated by a newer operation on
    /// the same id, or a callback from a dead connection generation) without
    /// ever pre-applying the requested value or inferring completion from a
    /// status read.
    private func runRapooOperation(_ id: String,
                                   onSettled: ((RapooOperationTracker.Outcome) -> Void)? = nil,
                                   action: @escaping (@escaping RapooHidService.WriteCompletion) -> Void) {
        let token = operationsTracker.begin(id)
        action { [weak self] error, generation in
            guard let self,
                  self.operationsTracker.finish(id, token: token,
                                                atGeneration: generation, failure: error) else { return }
            if let error { self.errorMessage = error.localizedDescription }
            onSettled?(error.map(RapooOperationTracker.Outcome.failure) ?? .success)
        }
    }

    /// Vigia do canal VT9 Pro: o mouse só responde comandos quando está em
    /// movimento, e a janela é curta — por isso, enquanto os registros não
    /// chegam, o app insiste rápido (1,2 s); quando tem tudo, relaxa (5 s).
    private func tickRapoo() {
        rapoo.refreshLiveValues()
        let interval: TimeInterval = (rapooStatus?.readable == true) ? 5 : 1.2
        guard abs(rapooRefreshInterval - interval) > 0.01 else { return }
        rapooRefreshInterval = interval
        rapooRefreshTimer?.invalidate()
        rapooRefreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.tickRapoo()
        }
    }

    func refreshRapoo() {
        guard !rapooRefreshing else { return }
        rapooRefreshing = true
        rapoo.refreshStatus { [weak self] error in
            self?.rapooRefreshing = false
            self?.rapooFailure(error)
        }
    }

    /// Input Monitoring governs IOHIDDeviceOpen; the pane exists without a
    /// programmatic prompt API, so the UI points the user at it.
    func openRapooPermissionSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Applies the polling rate to one of the two stored rates. The mouse
    /// keeps them separate: what the UI labels "cabo" is 0x880[2].
    func setRapooPolling(_ hz: Int, onReceiver: Bool) {
        runRapooOperation(onReceiver ? "rapoo.polling.receiver" : "rapoo.polling.cable") { completion in
            self.rapoo.setPollingRate(hz, onReceiver: onReceiver, completion)
        }
    }

    func setRapooDpi(_ stages: [Int], enabledStages: Int) {
        let scale = rapoo.status.dpiScale
        let submitted = RapooDpiDraft(stages: stages, enabledStages: enabledStages)
        if let problem = submitted.problem(scale: scale) {
            errorMessage = problem
            return
        }
        runRapooOperation("rapoo.dpi", onSettled: { [weak self] outcome in
            guard outcome == .success, let self else { return }
            self.rapooDpiDraft = RapooDpiDraft.afterSuccess(current: self.rapooDpiDraft, submitted: submitted)
        }) { completion in
            self.rapoo.setDpiTable(stages, enabledStages: enabledStages, scale: scale, completion)
        }
    }

    func setRapooActiveStage(_ stage: Int) {
        runRapooOperation("rapoo.stage") { completion in
            self.rapoo.setActiveStage(stage, completion)
        }
    }

    func setRapooLiftOff(_ code: Int) {
        runRapooOperation("rapoo.liftoff") { completion in
            self.rapoo.setLiftOff(code, completion)
        }
    }

    func setRapooMotionSync(_ enabled: Bool) {
        runRapooOperation("rapoo.motionSync") { completion in
            self.rapoo.setMotionSync(enabled, completion)
        }
    }

    /// Edits one or both sides; a `nil` side keeps the byte already on the mouse.
    /// Refused before any write when the indices are invalid or the timing block
    /// has never been read.
    func setRapooDebounce(pressIndex: Int?, releaseIndex: Int?) {
        guard RapooDebounceWrite.isValid(pressIndex: pressIndex, releaseIndex: releaseIndex) else {
            errorMessage = "Escolha um tempo de debounce da lista."
            return
        }
        guard rapoo.status.timing != nil else {
            errorMessage = "Leia o mouse antes de alterar o debounce."
            return
        }
        runRapooOperation("rapoo.debounce") { completion in
            self.rapoo.setDebounce(pressIndex: pressIndex, releaseIndex: releaseIndex, completion)
        }
    }

    func setRapooSleep(_ minutes: Int) {
        runRapooOperation("rapoo.sleep") { completion in
            self.rapoo.setSleep(minutes, completion)
        }
    }

    func setRapooAngleSnap(_ enabled: Bool) {
        runRapooOperation("rapoo.angleSnap") { completion in
            self.rapoo.setAngleSnapping(enabled, completion)
        }
    }

    func setRapooRipple(_ enabled: Bool) {
        runRapooOperation("rapoo.ripple") { completion in
            self.rapoo.setRippleControl(enabled, completion)
        }
    }
}
