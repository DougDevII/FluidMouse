import Foundation
import IOKit
import IOKit.hid
import ApplicationServices
import FluidMouseCore
import OSLog

private let rapooLog = Logger(subsystem: "br.com.douglas.fluido", category: "rapoo")

/// Speaks the Rapoo VT9 Pro register protocol over the `0xFF00:0x000E`
/// collection through IOKit. Every reply is fetched with `GET_REPORT(Input)`
/// (`IOHIDDeviceGetReport`, input kind) — the mouse does not push answers as
/// interrupt-IN reports.
///
/// Channel properties that shape this code (all measured in the vendor
/// driver 1.6.29 study, `rapoo-vt9-pro-testing.md`):
/// - about 40% of frames are silently dropped, so exchanges retry;
/// - an OK only counts after a busy — an OK seen without a busy is the
///   previous command's stale answer sitting in the input buffer;
/// - an idle mouse stops answering `0xBA` while feature `0x2A` keeps working;
/// - writes are whole-block read-modify-write, and feature `0x2B` disconnects
///   the mouse — never touched here.
///
/// All exchanges run serially on one background queue; callers get callbacks
/// on their own dispatch.
final class RapooHidService {
    struct Status: Equatable {
        var percent: Int?
        var charging: Bool?
        /// Link reported by the last heartbeat. nil = nunca reportado; `.unknown`
        /// = código não reconhecido. Nunca presumir cabo a partir de nil.
        var link: RapooProtocol.Link?
        /// Texto do link para exibição: "Receptor 2.4 GHz" / "Cabo USB"; nil quando desconhecido.
        var linkDescription: String?
        var receiverHz: Int?
        var wiredHz: Int?
        var dpi: RapooProtocol.DpiTable?
        /// DPI stored ÷ this value in the register block (1 = raw, 50 = unit0).
        var dpiScale = 1
        var activeStage: Int?
        var liftoffCode: Int?
        var motionSync: Bool?
        var timing: RapooProtocol.Timing?
        var sensorAngle: Int?
        var productID: Int?
        var readable = false                  // register walk succeeded
        /// Last collected register blocks, for the diagnostics panel.
        var rawBlocks: [Int: [UInt8]] = [:]
        /// True when macOS (TCC) refused `IOHIDDeviceOpen`: the user must
        /// grant the app Input Monitoring before the channel works.
        var permissionPending = false
    }

    enum RapooError: Error, LocalizedError, Equatable {
        case deviceMissing
        case channelUnresponsive(String)
        case writeRejected(String)

        var errorDescription: String? {
            switch self {
            case .deviceMissing:
                return "Conecte o VT9 Pro (receptor ou cabo) e tente novamente."
            case .channelUnresponsive(let realm):
                return "O mouse não respondeu (\(realm)). Mexa nele para acordar o canal."
            case .writeRejected(let what):
                return "O mouse recusou a alteração de \(what)."
            }
        }
    }

    // MARK: Types

    typealias OperationCompletion = @Sendable (RapooError?) -> Void

    /// Completion of a hardware write. Besides the outcome it carries the
    /// connection generation **captured immutably on the serial queue** —
    /// never re-read at delivery time — so callers can reject callbacks from
    /// a connection session that no longer exists.
    typealias WriteCompletion = @Sendable (RapooError?, Int) -> Void

    // MARK: State

    private var manager: IOHIDManager?
    private var device: IOHIDDevice?
    private let queue = DispatchQueue(label: "br.com.douglas.fluido.rapoo", qos: .userInitiated)

    private(set) var status = Status()
    /// Called with a **coherent snapshot** (`status`, `generation`) captured on
    /// the notifying thread — callers must not re-read mutable state.
    var onChange: ((Status, Int) -> Void)?
    /// Connection generation: bumps on every teardown/reset so completions in
    /// flight from a dead link can be recognized and ignored by callers.
    /// Mutated only on the serial IO queue; read from other threads through
    /// `currentGeneration()` (lock-guarded).
    private(set) var generation = 0
    private let generationLock = NSLock()

    private var lastSweepAttempt: Date = .distantPast
    private var sweepWasSilent = false
    private let notificationLock = NSLock()

    // MARK: Timing (measured vendor driver behaviour)

    private static let attempts = 4
    private static let retrySeconds: TimeInterval = 0.05
    /// Tempo que o mouse leva para processar um frame (medido: ~5 ms no
    /// receptor, ~30 ms no cabo).
    private static let settleSeconds: TimeInterval = 0.035
    private static let acceptSeconds: TimeInterval = 0.12
    private static let pollMicroseconds = 2_000
    private static let blockRounds = 4
    private static let blockGapSeconds: TimeInterval = 0.12
    private static let batteryRounds = 4
    private static let batteryPollMicroseconds = 4_000
    private static let batteryPollCount = 60
    private static let silentSweepRetry: TimeInterval = 30

    /// Scratch buffer shared by the input report callback. IOKit keeps no copy
    /// of it after the device closes; the allocation happens once and lives
    /// for the process' lifetime so a callback in flight can never dereference
    /// freed memory.
    private static let callbackBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 32)

    // MARK: Lifecycle

    func start() {
        evaluatePermission()
        guard manager == nil else { return }
        let newManager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(0))
        IOHIDManagerSetDeviceMatching(newManager,
            ["VendorID": NSNumber(value: RapooProtocol.vendorID)] as CFDictionary)
        IOHIDManagerOpen(newManager, IOOptionBits(0))
        IOHIDManagerScheduleWithRunLoop(newManager, CFRunLoopGetMain(),
                                        "kCFRunLoopDefaultMode" as CFString)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(newManager, { context, _, _, _ in
            guard let context else { return }
            DispatchQueue.main.async {
                Unmanaged<RapooHidService>.fromOpaque(context).takeUnretainedValue()
                    .reattachAsync()
            }
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(newManager, { context, _, _, _ in
            guard let context else { return }
            DispatchQueue.main.async {
                Unmanaged<RapooHidService>.fromOpaque(context).takeUnretainedValue()
                    .deviceGoneAsync()
            }
        }, context)
        manager = newManager
        reattachAsync()
    }

    /// Input Monitoring (kTCCServiceListenEvent) governs `IOHIDDeviceOpen`.
    /// The open call itself returns success even when TCC denies — the deny
    /// shows up later as silent no-ops — so the permission is preflighted
    /// here, and `CGRequestListenEventAccess` raises the native prompt.
    func evaluatePermission() {
        let granted = CGPreflightListenEventAccess()
        rapooLog.info("preflight ListenEvent: \(granted, privacy: .public)")
        if !granted {
            _ = CGRequestListenEventAccess()
        }
        if status.permissionPending == granted {
            status.permissionPending = !granted
            notifyChange()
        }
    }

    func stop() {
        guard let hidManager = manager else { return }
        IOHIDManagerClose(hidManager, IOOptionBits(0))
        self.manager = nil
        queue.async {
            self.teardownDevice()
            self.resetStatus()
        }
    }

    private func reattachAsync() {
        queue.async { self.reattach() }
    }

    private func deviceGoneAsync() {
        queue.async {
            self.teardownDevice()
            self.resetStatus()
        }
    }

    /// Find the Rapoo device carrying the configuration collection and bind to
    /// it — but bind to the link that ANSWERS: cable and receiver both expose
    /// the collection, and only the active link answers (the gen1 captures
    /// measured the cable taking the channel over). Product ids move between
    /// batches, so this matches on the collection itself, never on the pid.
    private func reattach() {
        guard let manager, device == nil else { return }
        guard let services = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else {
            notifyChange()
            return
        }
        let candidates = services.filter(hasConfigCollection)
        // Depois de uma troca de link, o device certo é o outro: tenta
        // primeiro o que não é o que já estava vinculado.
        let ordered = candidates.sorted { lhs, rhs in
            let lhsSame = (IOHIDDeviceGetProperty(lhs, "ProductID" as CFString) as? NSNumber)?.intValue == lastBoundPID
            let rhsSame = (IOHIDDeviceGetProperty(rhs, "ProductID" as CFString) as? NSNumber)?.intValue == lastBoundPID
            if lhsSame != rhsSame { return !lhsSame }
            return false
        }
        for candidate in ordered {
            if bind(candidate) { return }
        }
        rapooLog.info("nenhum Rapoo com a coleção FF00:000E entre \(services.count) devices")
        resetStatus()
        notifyChange()
    }

    /// Open the device that carries the configuration collection. Silence is
    /// NOT a reason to drop it: the VT9 Pro stops answering `0xBA` **and**
    /// stops sending the `0xBB` heartbeat while it is idle, so a quiet device
    /// is normal. The link is dropped only when the device disappears or when
    /// the heartbeat announces another link.
    private func bind(_ candidate: IOHIDDevice) -> Bool {
        guard open(candidate) else {
            status.permissionPending = true
            notifyChange()
            return true // permission issue, not a silent link: stop here
        }
        rapooLog.info("vínculo com \(self.status.productID.map { String(format: "pid=0x%04X", $0) } ?? "")")
        // Tenta os registros; se o mouse estiver dormindo, eles voltam
        // sozinhos quando ele se mexer (o vigia de 5 s cuida disso).
        if let block = readBlock(.activeStage),
           RapooProtocol.decodeActiveStage(block) != nil {
            status.readable = true
            queue.async { self.walkRegisters() }
        } else {
            status.readable = false
        }
        queue.async { self.refreshBattery() }
        notifyChange()
        return true
    }

    private func hasConfigCollection(_ device: IOHIDDevice) -> Bool {
        // Prefer elements when macOS hands them over.
        if let elements = IOHIDDeviceCopyMatchingElements(device, nil, 0)
                as? [[String: Any]] {
            for element in elements {
                let page = (element["UsagePage" as String] as? NSNumber)?.intValue ?? 0
                let usage = (element["Usage" as String] as? NSNumber)?.intValue ?? 0
                let type = (element["Type" as String] as? NSNumber)?.intValue ?? -1
                let reportID = (element["ReportID" as String] as? NSNumber)?.intValue ?? 0
                if type == 3, page == RapooProtocol.configUsagePage,
                   usage == RapooProtocol.configUsage,
                   reportID == RapooProtocol.configReportID {
                    return true
                }
            }
        }
        // Fallback: scan the report descriptor for the vendor collection
        // (06 00 FF 09 0E …) with the 0xBA report id (85 BA). macOS sometimes
        // refuses CopyMatchingElements (TCC/gate) but still hands the property.
        guard let descriptor = IOHIDDeviceGetProperty(device,
                "ReportDescriptor" as CFString) as? Data,
              descriptor.count > 6 else { return false }
        let bytes: [UInt8] = Array(descriptor)
        for index in 0..<(bytes.count - 7) {
            if bytes[index] == 0x06, bytes[index + 1] == 0x00, bytes[index + 2] == 0xFF,
               bytes[index + 3] == 0x09, bytes[index + 4] == 0x0E,
               bytes[index + 5] == 0xA1, bytes[index + 6] == 0x01 {
                // coleção presente; 0xBA vem como 85 BA logo adiante
                for probe in (index + 7)..<(min(index + 12, bytes.count - 1)) {
                    if bytes[probe] == 0x85 && bytes[probe + 1] == UInt8(RapooProtocol.configReportID) {
                        return true
                    }
                }
            }
        }
        return false
    }

    private func open(_ device: IOHIDDevice) -> Bool {
        guard IOHIDDeviceOpen(device, IOOptionBits(0)) == kIOReturnSuccess else {
            status.permissionPending = true
            notifyChange()
            rapooLog.error("IOHIDDeviceOpen recusado — antecipe a pendência de Monitoramento de Entrada na UI")
            return false
        }
        status.permissionPending = false
        self.device = device
        let productID = (IOHIDDeviceGetProperty(device, "ProductID" as CFString)
                         as? NSNumber)?.intValue
        status.productID = productID
        lastBoundPID = productID
        IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetMain(),
                                       "kCFRunLoopDefaultMode" as CFString)
        IOHIDDeviceRegisterInputReportCallback(device, Self.callbackBuffer, 32,
            { context, _, _, _, _, report, length in
                guard let context, length > 0 else { return }
                let bytes = [UInt8](UnsafeBufferPointer(start: report, count: length))
                DispatchQueue.main.async {
                    Unmanaged<RapooHidService>.fromOpaque(context)
                        .takeUnretainedValue()
                        .receivedNotification(bytes)
                }
            }, Unmanaged.passUnretained(self).toOpaque())
        return true
    }

    private func probeDump() {
        guard let device else { return }
        func readOnce() -> (IOReturn, Int, [UInt8]) {
            var poll = [UInt8](repeating: 0, count: 32)
            var pollLength: CFIndex = poll.count
            let pollResult = poll.withUnsafeMutableBufferPointer { pointer in
                IOHIDDeviceGetReport(device, kIOHIDReportTypeInput, 0xBA,
                                     pointer.baseAddress!, &pollLength)
            }
            var raw = Array(poll[0..<max(0, min(pollLength, 32))])
            if raw.count == 32 && raw.first == UInt8(RapooProtocol.configReportID) { raw.removeFirst() }
            return (pollResult, pollLength, raw)
        }
        func trySet(_ kind: IOHIDReportType, label: String) {
            var frame = [UInt8](repeating: 0, count: 32)
            frame[0] = UInt8(RapooProtocol.configReportID)
            frame[1] = 0xA5; frame[2] = 0xA4; frame[3] = 0x04
            frame[4] = 0x98; frame[5] = 0x08
            let sendResult = frame.withUnsafeBufferPointer { pointer in
                IOHIDDeviceSetReport(device, kind, 0xBA, pointer.baseAddress!, 32)
            }
            for _ in 0..<40 {
                let (_, _, raw) = readOnce()
                // mudou de "bateria antiga" para bloco de registro?
                if raw.count >= 8 && (raw[1] == 0 || raw.count > 8) && raw[4...].contains(0x01) && raw.prefix(3) != [0x01, 0x02, 0x64] {
                    rapooLog.info("probeDump [\(label, privacy: .public)]: set=0x\(String(UInt32(bitPattern: sendResult), radix: 16), privacy: .public) mudou! bytes=\(RapooHidService.hex(Array(raw.prefix(8))), privacy: .public)")
                    return
                }
                usleep(4000)
            }
            rapooLog.info("probeDump [\(label, privacy: .public)]: set=0x\(String(UInt32(bitPattern: sendResult), radix: 16), privacy: .public) buffer não mudou")
        }
        trySet(kIOHIDReportTypeOutput, label: "output")
        trySet(kIOHIDReportTypeFeature, label: "feature")
    }

    private func teardownDevice() {
        guard let device else { return }
        IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetMain(),
                                         "kCFRunLoopDefaultMode" as CFString)
        IOHIDDeviceClose(device, IOOptionBits(0))
        self.device = nil
    }

    /// Thread-safe read for callers outside the IO queue (setters capture
    /// the acceptance generation, callbacks need the snapshot). The IO queue
    /// mutates the generation under the same lock.
    func currentGeneration() -> Int {
        generationLock.lock()
        defer { generationLock.unlock() }
        return generation
    }

    /// Bumping happens only on the IO queue; locked so out-of-queue readers
    /// observe whole transitions.
    private func bumpGeneration() {
        generationLock.lock()
        generation += 1
        generationLock.unlock()
    }

    private func resetStatus() {
        status = Status()
        latestNotification = nil
        sweepWasSilent = false
        bumpGeneration()
        notifyChange()
    }

    static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
    }

    /// Notifies listeners with a coherent snapshot taken right here, on the
    /// notifying thread — later mutation of `status`/`generation` cannot
    /// corrupt what observers receive.
    private func notifyChange() {
        onChange?(self.status, currentGeneration())
    }

    private func receivedNotification(_ bytes: [UInt8]) {
        rapooLog.info("notification 0xBB raw: \(RapooHidService.hex(bytes), privacy: .public)")
        guard let notification = RapooProtocol.decodeNotification(bytes) else { return }
        notificationLock.lock()
        latestNotification = notification
        lastNotificationAt = Date()
        notificationLock.unlock()
        let description = RapooHidService.describe(notification.link)
        // O heartbeat diz qual link está no uso (0x41 cabo, 0x42 receptor).
        // Quando ele muda, o device certo é outro: re-vincula.
        notificationLock.lock()
        let linkChanged = lastLink != notification.link && lastLink != nil
        lastLink = notification.link
        notificationLock.unlock()
        if linkChanged {
            rapooLog.info("link mudou no heartbeat — re-vinculando")
            queue.async {
                self.teardownDevice()
                self.reattach()
            }
        }
        if status.percent != notification.percent
            || status.charging != notification.charging
            || status.link != notification.link
            || status.linkDescription != description {
            status.percent = notification.percent
            status.charging = notification.charging
            status.link = notification.link
            status.linkDescription = description
            notifyChange()
        }
    }

    private var latestNotification: RapooProtocol.Notification?
    private var lastNotificationAt: Date?
    private var lastLink: RapooProtocol.Link?
    private var lastBoundPID: Int?

    static func describe(_ link: RapooProtocol.Link) -> String? {
        switch link {
        case .receiver: return "Receptor 2.4 GHz"
        case .cable: return "Cabo USB"
        case .unknown: return nil
        }
    }

    private func complete(_ error: RapooError?, _ completion: OperationCompletion?) {
        guard let completion else { return }
        DispatchQueue.main.async { completion(error) }
    }

    /// Delivery of a write outcome. Called on the serial queue: the caller
    /// captured the generation there, and this hop only carries the immutable
    /// values to the main queue — no mutable service read at delivery time.
    private func completeWrite(_ error: RapooError?, generation: Int, _ completion: WriteCompletion?) {
        RapooOperationDelivery.deliver(error, generation: generation, to: completion)
    }

    /// Shared envelope for every hardware write.
    ///
    /// - The write is **accepted** with the connection generation read via
    ///   `currentGeneration()` on the caller's thread.
    /// - On the serial queue, if the connection already moved on (or there is
    ///   no device), the command is rejected **before** anything is written
    ///   to the new device: completed as `.deviceMissing`, bound to the
    ///   accepted generation.
    /// - On success (same generation, device present), the body runs and the
    ///   outcome is delivered once on the main queue with the same
    ///   immutable generation.
    private func runBoundWrite(from acceptanceGeneration: Int,
                               _ completion: WriteCompletion?,
                               _ body: @escaping () -> RapooError?) {
        queue.async {
            guard self.currentGeneration() == acceptanceGeneration, self.device != nil else {
                self.completeWrite(.deviceMissing, generation: acceptanceGeneration, completion)
                return
            }
            let error = body()
            self.completeWrite(error, generation: acceptanceGeneration, completion)
        }
    }

    // MARK: Reads

    /// Heavy refresh: one walk of the register map. A click on "Atualizar"
    /// always forces the walk past the silent-retry window.
    func refreshStatus(_ completion: (@Sendable (RapooError?) -> Void)? = nil) {
        queue.async {
            if self.device == nil { self.reattach() }
            guard self.device != nil else {
                self.complete(.deviceMissing, completion)
                return
            }
            self.lastSweepAttempt = .distantPast
            self.sweepWasSilent = false
            self.walkRegisters()
            self.refreshBattery()
            self.notifyChange()
            self.complete(nil, completion)
        }
    }

    private var failedProbeRounds = 0

    /// Lightweight refresh: watchdog + the values that change live. A bound
    /// link goes through one light register read; two consecutive failures
    /// drop the link (cable took the channel over, dongle asleep) so the
    /// attach can re-probe and pick whatever answers now.
    func refreshLiveValues(_ completion: (@Sendable (RapooError?) -> Void)? = nil) {
        queue.async {
            self.evaluatePermission()
            guard self.device != nil else {
                self.reattach()
                self.complete(nil, completion)
                return
            }
            if let block = self.readBlock(.activeStage) {
                self.failedProbeRounds = 0
                if let stage = RapooProtocol.decodeActiveStage(block),
                   self.status.activeStage != stage {
                    self.status.activeStage = stage
                    self.notifyChange()
                }
                if !self.status.readable {
                    self.status.readable = true
                    self.queue.async { self.walkRegisters() }
                    self.notifyChange()
                }
            } else {
                // O mouse dormiu: o canal de registros só responde com ele em
                // movimento. O vínculo é mantido — a leitura volta sozinha
                // quando o usuário mexer no mouse.
                self.failedProbeRounds += 1
                if self.failedProbeRounds >= 2 {
                    self.failedProbeRounds = 0
                    if self.status.readable {
                        self.status.readable = false
                        self.notifyChange()
                    }
                }
            }
            self.refreshBattery()
            self.notifyChange()
            self.complete(nil, completion)
        }
    }

    private func walkRegisters() {
        guard device != nil else { return }
        if sweepWasSilent,
           Date().timeIntervalSince(lastSweepAttempt) < Self.silentSweepRetry {
            return
        }
        lastSweepAttempt = Date()
        sweepWasSilent = false
        var collected: [RapooProtocol.Address: [UInt8]] = [:]
        let order: [RapooProtocol.Address] =
            [.performance, .sensor, .dpiX, .activeStage, .timing, .sensorAngle]
        for address in order {
            if let block = readBlock(address) {
                collected[address] = block
            } else if collected.isEmpty {
                // A mouse that answered nothing is asleep or out of range.
                sweepWasSilent = true
            }
        }
        guard !collected.isEmpty else {
            status.readable = false
            status.rawBlocks = [:]
            rapooLog.info("sweep rapoo: nada respondido — liberando o vínculo para re-probe")
            resetStatus()
            teardownDevice()
            queue.async { self.reattach() }
            return
        }
        status.rawBlocks = Dictionary(uniqueKeysWithValues: collected.map { ($0.key.rawValue, $0.value) })
        status.readable = true
        approachLog: do {
            if let block = collected[.performance] {
                rapooLog.info("0x880: \(RapooHidService.hex(Array(block.prefix(4))), privacy: .public)")
            }
            if let block = collected[.timing], block.count >= 4 {
                rapooLog.info("0x8C0: \(RapooHidService.hex(block), privacy: .public)")
            }
        }
        if let block = collected[.performance],
           let performance = RapooProtocol.decodePerformance(block) {
            // gen1 stores the receiver rate at byte 0; the newer firmware in
            // the field puts it at byte 1 (ex.: `01 82 01 ff` = 4000 Hz).
            let slots = self.pollingSlots(block)
            self.pollingLayout = slots
            status.receiverHz = RapooProtocol.pollingHz(forCode: block[slots.first])
            status.wiredHz = RapooProtocol.pollingHz(forCode: block[slots.second])
        }
        if let sensor = collected[.sensor].flatMap(RapooProtocol.decodeSensor) {
            status.liftoffCode = sensor.liftOffCode
            status.motionSync = sensor.motionSync
        }
        if let table = collected[.dpiX].flatMap(RapooProtocol.decodeDpiTable) {
            status.dpi = table
            status.dpiScale = RapooProtocol.inferDpiScale(stages: table.stages)
        }
        if let stage = collected[.activeStage].flatMap(RapooProtocol.decodeActiveStage) {
            status.activeStage = stage
        }
        if let timing = collected[.timing].flatMap(RapooProtocol.decodeTiming) {
            status.timing = timing
        }
        if let angle = collected[.sensorAngle] {
            status.sensorAngle = Int(angle[0])
        }
    }

    /// The `0xAA` query does not follow busy -> OK: the value is already in
    /// the device's input buffer, so each send is followed by a short scan
    /// that recognizes the answer by its marker byte, not by the handshake.
    private func refreshBattery() {
        guard device != nil else { return }
        // A notificação de bateria (0xBB) é mais recente que a query; a query
        // só é tentada quando o canal de registros está adormecido.
        let frame = RapooProtocol.frame(.battery, address: 0, data: [])
        if let battery = performIO(timeout: Self.ioTimeout, { [weak self] in
            self?.doBatteryQuery(frame: frame)
        }) {
            if self.status.percent != battery.percent ||
               self.status.charging != battery.charging {
                self.status.percent = battery.percent
                self.status.charging = battery.charging
                self.notifyChange()
            }
            return
        }
        // Fallback: o feature 0x2A responde mesmo com o mouse parado.
        if let percent = readFeatureBattery() {
            if status.percent != percent {
                status.percent = percent
                status.charging = status.charging ?? false
                notifyChange()
            }
        }
    }

    /// A query 0xAA na thread de I/O: escrever para um mouse adormecido
    /// trava no kernel, e aqui isso não congela o resto do serviço.
    private func doBatteryQuery(frame: [UInt8]) -> RapooProtocol.Battery? {
        for _ in 0..<Self.batteryRounds {
            guard send(frame) else { return nil }
            for _ in 0..<Self.batteryPollCount {
                if let raw = inputReport(), let battery = RapooProtocol.decodeBattery(raw) {
                    return battery
                }
                usleep(UInt32(Self.batteryPollMicroseconds))
            }
        }
        return nil
    }

    private func readFeatureBattery() -> Int? {
        guard let device else { return nil }
        var report = [UInt8](repeating: 0, count: 10)
        var length: CFIndex = report.count
        let result = report.withUnsafeMutableBufferPointer { pointer in
            IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature,
                                 CFIndex(RapooProtocol.statusReportID),
                                 pointer.baseAddress!, &length)
        }
        guard result == kIOReturnSuccess else { return nil }
        let bytes = Array(report[0..<min(length, 10)])
        rapooLog.info("feature 0x2A: \(RapooHidService.hex(bytes), privacy: .public)")
        return RapooProtocol.decodeFeatureStatus(bytes)
    }

    /// One register read, resending across rounds until the device answers.
    /// Reads are idempotent, so a resend costs nothing but time — a single
    /// silence proves nothing on a channel that drops two frames in five.
    private func readBlock(_ address: RapooProtocol.Address) -> [UInt8]? {
        for round in 0..<Self.blockRounds {
            if round > 0 { Thread.sleep(forTimeInterval: Self.blockGapSeconds) }
            let frame = RapooProtocol.frameRead(address: address.rawValue,
                                                length: address.blockLength)
            if let answer = exchange(frame: frame, expectedLength: address.blockLength) {
                return answer.block
            }
        }
        return nil
    }

    // MARK: Writes

    /// Send one frame and read the answer.
    ///
    /// The mouse keeps a **single answer slot**: the control read always
    /// returns whatever the device produced last, and reading the same
    /// register twice yields identical bytes (so "is it fresh?" cannot be
    /// answered by comparing content). The reliable recipe, measured on the
    /// wired link, is: send, wait for the device to process the frame
    /// (~30 ms), ask the same thing again and read — the second answer is
    /// guaranteed to belong to the register that was asked for.
    private func exchange(frame: [UInt8], expectedLength: Int) -> RapooProtocol.Answer? {
        for attempt in 0..<Self.attempts {
            if attempt > 0 { Thread.sleep(forTimeInterval: Self.retrySeconds) }
            if abandonedWrites >= Self.abandonLimit {
                rapooLog.info("muitas escritas travadas — recua 5 s antes de tentar de novo")
                Thread.sleep(forTimeInterval: 5)
                abandonedWrites = 0
            }
            // A escrita para um mouse adormecido bloqueia no kernel; a
            // thread de I/O com timeout evita que isso congele o serviço.
            if let answer = performIO(timeout: Self.ioTimeoutLong, { [weak self] in
                self?.doExchange(frame: frame, expectedLength: expectedLength)
            }) {
                return answer
            }
        }
        return nil
    }

    /// A troca completa, na thread de I/O.
    private func doExchange(frame: [UInt8], expectedLength: Int) -> RapooProtocol.Answer? {
        // 1ª passada: o mouse processa o frame e o slot passa a conter a
        // resposta pedida (descartada de propósito).
        guard send(frame) else { return nil }
        Thread.sleep(forTimeInterval: Self.settleSeconds)
        _ = inputReport()
        // 2ª passada: mesma pergunta — agora a resposta é do registrador.
        guard send(frame) else { return nil }
        Thread.sleep(forTimeInterval: Self.settleSeconds)
        guard let raw = inputReport() else { return nil }
        guard let answer = try? RapooProtocol.decodeAnswer(raw, expectedLength: expectedLength) else {
            return nil
        }
        return answer.isBattery ? nil : answer
    }

    // MARK: Blocking I/O

    private static let ioTimeout: TimeInterval = 0.45
    private static let ioTimeoutLong: TimeInterval = 1.2
    private static let abandonLimit = 4
    private var abandonedWrites = 0
    private let ioLock = NSLock()

    /// Runs `block` off the caller's thread and gives up after `timeout`. A
    /// stuck call (the mouse asleep) is abandoned: the worker finishes
    /// whenever the device wakes up.
    ///
    /// Note: the work must run on a **DispatchQueue**, not on a bare
    /// `Thread` — IOKit's control transfers block forever on a thread with no
    /// run loop (measured).
    private func performIO<T>(timeout: TimeInterval, _ block: @escaping () -> T?) -> T? {
        let box = IOBox<T>()
        DispatchQueue.global(qos: .userInitiated).async {
            box.value = block()
            box.semaphore.signal()
        }
        if box.semaphore.wait(timeout: .now() + timeout) == .success {
            return box.value
        }
        abandonedWrites += 1
        rapooLog.info("escrita travada (mouse dormindo?) — abandono após \(String(format: "%.0f", timeout * 1000)) ms")
        return nil
    }

    /// Result box shared between the caller and the worker thread.
    private final class IOBox<T>: @unchecked Sendable {
        let semaphore = DispatchSemaphore(value: 0)
        var value: T?
    }

    /// Whole-block read-modify-write: read the register, patch it, write it
    /// back, then read again to confirm the new bytes.
    private func writeBlock(_ address: RapooProtocol.Address,
                            what: String,
                            mutate: (inout [UInt8]) -> Void,
                            verify: ([UInt8]) -> Bool) -> RapooError? {
        guard device != nil else { return .deviceMissing }
        guard var block = readBlock(address) else {
            return .channelUnresponsive("leitura pré-escrita \(hex(address.rawValue))")
        }
        mutate(&block)
        guard confirmWrite(address: address, block: block, what: what) else {
            return .channelUnresponsive("escrita \(hex(address.rawValue))")
        }
        for _ in 0..<Self.attempts {
            if let fresh = readBlock(address) {
                return verify(fresh) ? nil : .writeRejected(what)
            }
        }
        return .channelUnresponsive("confirmação \(hex(address.rawValue))")
    }

    private func confirmWrite(address: RapooProtocol.Address, block: [UInt8],
                              what: String) -> Bool {
        let frame = RapooProtocol.frameWrite(address: address.rawValue, block: block)
        for attempt in 0..<Self.attempts {
            if attempt > 0 { Thread.sleep(forTimeInterval: Self.retrySeconds) }
            guard send(frame) else { continue }
            Thread.sleep(forTimeInterval: Self.settleSeconds)
            // O ACK de escrita é um `01` de 1 byte — distinto do bloco, que
            // tem 4 + N bytes. Se o slot ainda tiver a resposta de uma
            // leitura anterior, a escrita é repetida.
            guard let raw = inputReport() else { continue }
            if RapooProtocol.decodeWriteAck(raw) { return true }
            if raw.count >= 4 { continue } // ainda não é o ACK: tenta de novo
        }
        return false
    }

    private enum AnswerStatus {
        case ok          // byte 0 == 0x01
        case busy        // byte 0 != 0x01
        case garbage
    }

    /// Status-only look at a raw buffer (respostas variam de tamanho no macOS:
    /// um OK de read de 4 bytes tem 8 no total).
    private func decodeStatus(of raw: [UInt8]) -> AnswerStatus {
        guard raw.count >= 4 else { return .garbage }
        return raw[0] == 0x01 ? .ok : .busy
    }

    /// Polling slot layout: gen1 keeps the receiver code at byte 0 and cable
    /// at byte 2; the newer firmware in the field places the active-link code
    /// at byte 1 (measured `01 82 01 ff` = 4000 Hz on the linked side).
    private var pollingLayout = (first: 0, second: 2)

    private func pollingSlots(_ block: [UInt8]) -> (first: Int, second: Int) {
        guard block.count >= 4 else { return (0, 2) }
        if RapooProtocol.pollingHz(forCode: block[1]) != nil {
            return (1, 2)
        }
        return (0, 2)
    }

    // MARK: Writes surface

    func setPollingRate(_ hz: Int, onReceiver: Bool,
                        _ completion: WriteCompletion? = nil) {
        runBoundWrite(from: currentGeneration(), completion) {
            guard let code = RapooProtocol.pollingCode(forHz: hz) else {
                return .writeRejected("polling rate \(hz) Hz")
            }
            let error = self.writeBlock(.performance, what: "polling rate \(hz) Hz") { block in
                if onReceiver { block[self.pollingLayout.first] = code }
                else { block[self.pollingLayout.second] = code }
            } verify: { fresh in
                if onReceiver { fresh[self.pollingLayout.first] == code }
                else { fresh[self.pollingLayout.second] == code }
            }
            self.patchStatus(enabled: error == nil) {
                if onReceiver { self.status.receiverHz = hz } else { self.status.wiredHz = hz }
            }
            return error
        }
    }

    /// `stages` come in DPI units; they are stored in the register divided by
    /// the variant's scale. The caller passes the scale it discovered.
    ///
    /// Error contract: the **first** (X) error is authoritative. Y is
    /// attempted only when the X block landed — a failed X never starts a
    /// second write, and no later success can ever mask it. The older firmware
    /// stores the Y table at 0x8C8 byte-identical to X; the newer one doesn't
    // (the block reads all-FF), so Y is only touched when `scale <= 1`.
    func setDpiTable(_ stages: [Int], enabledStages: Int, scale: Int,
                     _ completion: WriteCompletion? = nil) {
        runBoundWrite(from: currentGeneration(), completion) {
            // The table block holds exactly seven stages; anything else is refused.
            guard stages.count == 7 else { return .writeRejected("DPI") }
            let registerUnits = stages.map { $0 / max(scale, 1) }
            let table = RapooProtocol.DpiTable(stages: registerUnits, enabledStages: enabledStages)
            let error = RapooWritePlan.dpiWriteOutcome(scale: scale, writeX: {
                self.writeBlock(.dpiX, what: "DPI X") { block in
                    block = RapooProtocol.encodeDpiTable(table)
                } verify: { fresh in
                    RapooProtocol.decodeDpiTable(fresh) == table
                }
            }, writeY: {
                // The older firmware stores the Y table at 0x8C8 byte-identical
                // to X; the newer one doesn't (the block reads all-FF), so the
                // coordinator only calls this when scale <= 1.
                self.writeBlock(.dpiY, what: "DPI Y") { block in
                    block = RapooProtocol.encodeDpiTable(table)
                } verify: { fresh in
                    RapooProtocol.decodeDpiTable(fresh) == table
                }
            })
            self.patchStatus(enabled: error == nil) {
                self.status.dpi = table
                self.status.dpiScale = scale
            }
            return error
        }
    }

    func setActiveStage(_ stage: Int, _ completion: WriteCompletion? = nil) {
        runBoundWrite(from: currentGeneration(), completion) {
            let error = self.writeBlock(.activeStage, what: "estágio DPI") { block in
                block[0] = UInt8(stage)
            } verify: { fresh in RapooProtocol.decodeActiveStage(fresh) == stage }
            self.patchStatus(enabled: error == nil) { self.status.activeStage = stage }
            return error
        }
    }

    func setLiftOff(_ code: Int, _ completion: WriteCompletion? = nil) {
        runBoundWrite(from: currentGeneration(), completion) {
            let error = self.writeBlock(.sensor, what: "lift-off") { block in
                block[0] = UInt8(code)
            } verify: { fresh in fresh[0] == UInt8(code) }
            self.patchStatus(enabled: error == nil) { self.status.liftoffCode = code }
            return error
        }
    }

    func setMotionSync(_ enabled: Bool, _ completion: WriteCompletion? = nil) {
        runBoundWrite(from: currentGeneration(), completion) {
            let error = self.writeBlock(.sensor, what: "motion sync") { block in
                block[1] = enabled ? 0x01 : 0x00
            } verify: { fresh in (fresh[1] != 0) == enabled }
            self.patchStatus(enabled: error == nil) { self.status.motionSync = enabled }
            return error
        }
    }

    /// `nil` keeps the byte already stored on the mouse for that side (including
    /// 0xFF, "no value"), so editing one side never rewrites the other.
    func setDebounce(pressIndex: Int?, releaseIndex: Int?,
                     _ completion: WriteCompletion? = nil) {
        runBoundWrite(from: currentGeneration(), completion) {
            guard RapooDebounceWrite.isValid(pressIndex: pressIndex, releaseIndex: releaseIndex) else {
                return .writeRejected("debounce")
            }
            let error = self.writeBlock(.timing, what: "debounce") { block in
                block = RapooDebounceWrite.merged(block, pressIndex: pressIndex, releaseIndex: releaseIndex)
            } verify: { fresh in
                RapooDebounceWrite.matches(fresh, pressIndex: pressIndex, releaseIndex: releaseIndex)
            }
            self.patchStatus(enabled: error == nil) {
                self.withTiming { timing in
                    RapooProtocol.Timing(
                        pressDebounceIndex: pressIndex ?? timing.pressDebounceIndex,
                        releaseDebounceIndex: releaseIndex ?? timing.releaseDebounceIndex,
                        sleepMinutes: timing.sleepMinutes,
                        angleSnapping: timing.angleSnapping, rippleControl: timing.rippleControl)
                }
            }
            return error
        }
    }

    func setSleep(_ minutes: Int, _ completion: WriteCompletion? = nil) {
        runBoundWrite(from: currentGeneration(), completion) {
            let error = self.writeBlock(.timing, what: "tempo de sleep \(minutes) min") { block in
                block[2] = UInt8(minutes)
            } verify: { fresh in fresh[2] == UInt8(minutes) }
            self.patchStatus(enabled: error == nil) {
                self.withTiming { timing in
                    RapooProtocol.Timing(
                        pressDebounceIndex: timing.pressDebounceIndex,
                        releaseDebounceIndex: timing.releaseDebounceIndex,
                        sleepMinutes: minutes,
                        angleSnapping: timing.angleSnapping, rippleControl: timing.rippleControl)
                }
            }
            return error
        }
    }

    func setAngleSnapping(_ enabled: Bool, _ completion: WriteCompletion? = nil) {
        runBoundWrite(from: currentGeneration(), completion) {
            let error = self.writeBlock(.timing, what: "angle snap") { block in
                block[3] = enabled ? block[3] & ~0x01 : block[3] | 0x01
            } verify: { fresh in (fresh[3] & 0x01 == 0) == enabled }
            self.patchStatus(enabled: error == nil) {
                self.withTiming { timing in
                    RapooProtocol.Timing(
                        pressDebounceIndex: timing.pressDebounceIndex,
                        releaseDebounceIndex: timing.releaseDebounceIndex,
                        sleepMinutes: timing.sleepMinutes,
                        angleSnapping: enabled, rippleControl: timing.rippleControl)
                }
            }
            return error
        }
    }

    func setRippleControl(_ enabled: Bool, _ completion: WriteCompletion? = nil) {
        runBoundWrite(from: currentGeneration(), completion) {
            let error = self.writeBlock(.timing, what: "ripple control") { block in
                block[3] = enabled ? block[3] & ~0x02 : block[3] | 0x02
            } verify: { fresh in (fresh[3] & 0x02 == 0) == enabled }
            self.patchStatus(enabled: error == nil) {
                self.withTiming { timing in
                    RapooProtocol.Timing(
                        pressDebounceIndex: timing.pressDebounceIndex,
                        releaseDebounceIndex: timing.releaseDebounceIndex,
                        sleepMinutes: timing.sleepMinutes,
                        angleSnapping: timing.angleSnapping, rippleControl: enabled)
                }
            }
            return error
        }
    }

    private func patchStatus(enabled: Bool, _ patch: () -> Void) {
        guard enabled else { return }
        patch()
        notifyChange()
    }

    private func withTiming(_ patch: (RapooProtocol.Timing) -> RapooProtocol.Timing) {
        guard let timing = status.timing else { return }
        status.timing = patch(timing)
    }

    // MARK: Raw transport

    private func send(_ frame: [UInt8]) -> Bool {
        guard let device, frame.count == RapooProtocol.frameLength else { return false }
        // macOS IOKit: the output buffer must carry the report id at index 0.
        var report = [UInt8](repeating: 0, count: frame.count + 1)
        report[0] = UInt8(RapooProtocol.configReportID)
        for (index, byte) in frame.enumerated() { report[index + 1] = byte }
        return report.withUnsafeBufferPointer { buffer in
            IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput,
                                 CFIndex(RapooProtocol.configReportID),
                                 buffer.baseAddress!, CFIndex(report.count)) == kIOReturnSuccess
        }
    }

    /// `GET_REPORT(Input)` on `0xBA`. Nothing buffered is a "not yet", not an
    /// error — callers poll again.
    private func inputReport() -> [UInt8]? {
        guard let device else { return nil }
        var report = [UInt8](repeating: 0, count: 32)
        var length: CFIndex = report.count
        let result = report.withUnsafeMutableBufferPointer { pointer in
            IOHIDDeviceGetReport(device, kIOHIDReportTypeInput,
                                 CFIndex(RapooProtocol.configReportID),
                                 pointer.baseAddress!, &length)
        }
        guard result == kIOReturnSuccess, length > 0, length <= 32 else {
            if lastGetReportError != result {
                lastGetReportError = result
                rapooLog.error("GetReport(0xBA): erro 0x\(String(UInt32(bitPattern: result), radix: 16), privacy: .public) len=\(length)")
            }
            return nil
        }
        var bytes = Array(report[0..<length])
        // Some transports prepend the report id; accept both shapes.
        if bytes.count == 32 && bytes[0] == RapooProtocol.configReportID {
            bytes.removeFirst()
        }
        return bytes
    }

    private var lastGetReportError: IOReturn = kIOReturnSuccess

    private func hex(_ address: Int) -> String { "0x" + String(address, radix: 16) }
}

/// Debounce write rules, pure so they can be tested without a device. The
/// timing block keeps press in byte 0 and release in byte 1; a side that is
/// not being edited keeps its stored byte exactly (0xFF included).
enum RapooDebounceWrite {
    static func isValid(pressIndex: Int?, releaseIndex: Int?) -> Bool {
        guard pressIndex != nil || releaseIndex != nil else { return false }
        return [pressIndex, releaseIndex].allSatisfy { index in
            guard let index else { return true }
            return RapooProtocol.debounceTimesMs.indices.contains(index)
        }
    }

    /// Returns the block with the requested sides replaced. Blocks shorter than
    /// two bytes are returned untouched; `matches` then rejects the write.
    static func merged(_ block: [UInt8], pressIndex: Int?, releaseIndex: Int?) -> [UInt8] {
        guard block.count >= 2 else { return block }
        var next = block
        if let pressIndex { next[0] = UInt8(pressIndex) }
        if let releaseIndex { next[1] = UInt8(releaseIndex) }
        return next
    }

    static func matches(_ block: [UInt8], pressIndex: Int?, releaseIndex: Int?) -> Bool {
        guard block.count >= 2 else { return false }
        if let pressIndex, block[0] != UInt8(pressIndex) { return false }
        if let releaseIndex, block[1] != UInt8(releaseIndex) { return false }
        return true
    }
}

/// Taxa de polling do link ativo. Cada link tem a sua (0x880 guarda receptor e
/// cabo separados). Sem link reportado, não há taxa do link ativo: nil.
enum RapooPollingReadout {
    static func activeHz(link: RapooProtocol.Link?, receiverHz: Int?, wiredHz: Int?) -> Int? {
        switch link {
        case .receiver?: return receiverHz
        case .cable?: return wiredHz
        case .unknown?, nil: return nil
        }
    }
}
