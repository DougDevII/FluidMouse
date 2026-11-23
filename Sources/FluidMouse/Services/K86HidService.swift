import Foundation
import IOKit
import IOKit.hid
import ApplicationServices
import FluidMouseCore
import OSLog

private let k86Log = Logger(subsystem: "br.com.douglas.fluido", category: "k86")

/// Façade do transporte K86: descoberta (fingerprint), permissão, guarda de
/// fase (GET-only) e status — toda a serialização/vida do device vive no
/// `K86HIDExchange` (executor serial do Core, testado com fakes).
///
/// Descoberta (produção): matching por VendorID 12625 no manager; candidato
/// precisa PID ∈ {0x4015 (id:1168 "K86"), 0x5002 (id:2730)} **e** fingerprint
/// da coleção de configuração. Elementos são lidos com **IOHIDElementGet\***
/// (o `IOHIDDeviceCopyMatchingElements` devolve elementos, não dicionários);
/// o descritor REAL é validado por PARSE COMPLETO dos fatos (`K86Fingerprint.
/// descriptorFacts` = coleção 0xFFFF:0x0002, ReportCount 64, ReportSize 8,
/// **sem item de Report ID** ⇒ unnumbered 0) — substring nunca é prova única,
/// e o descritor do líder (`06ffff0902a10109021580257f95407508b102c0`) é a
/// referência.
///
/// NENHUM report é enviado no start/bind — só attach/getPossible/open/timer,
/// tudo por completion do executor. A identidade é sempre candidata; o gate
/// `protocolVariantUnresolved` fica TRUE até o RE P1-1c (chunk `a5d33148.js`
/// ausente do mount) decidir a família — isso bloqueia configurar o teclado,
/// não o transporte. A consulta física GET_REV segue PENDENTE: as classes
/// candidatas divergem no comando (128 vs 143) e no layout de resposta
/// (`t[2]<<8|t[1]` vs `e[8]<<8|e[7]`; offsets K86GetRevProbeGate).
final class K86HidService: @unchecked Sendable {

    // MARK: Tipos

    enum K86ServiceError: Error, Equatable {
        /// Guarda de fase: somente consultas de descoberta nesta célula.
        case configWritesBlockedInDiscoveryPhase(command: UInt8)
        case notAQueryCommand(command: UInt8)
        case frameEncodeFailed
    }

    /// Leitura de versão NÃO VALIDADA: `echoMatches` é eco de comando apenas —
    /// eco não confirma variante/identidade; zeros/curtos/eco errado não
    /// viram "sucesso" em nenhum caminho daqui.
    struct VersionReadout: Equatable {
        let raw: [UInt8]
        let echoMatches: Bool
    }

    struct Status: Equatable {
        var permissionPending = true
        /// Fingerprint presente no sistema (coleção 0xFFFF:0x0002 em candidato).
        var deviceSeen = false
        var bound = false
        var vendorID: Int?
        var productID: Int?
        var locationID: Int?
        var maxFeatureReportSize: Int?
        /// Fato do descritor REAL: feature unnumbered (sem item `85 xx`),
        /// provado por parse — NÃO inferido de MaxFeature=64.
        var descriptorUnnumberedFeature: Bool?
        var descriptorFeatureByteCount: Int?
        /// Descritor concorda com a referência real do líder (0xFFFF:0x0002,
        /// count 64, size 8, unnumbered).
        var descriptorMatchesReference: Bool?
        /// P1-1c: família de parse não resolvida; configurar fica bloqueado.
        var protocolVariantUnresolved = true
        /// Quarentina/desconexão do executor (sessão invalidada).
        var sessionReason: String?
        /// Sempre false nesta fase: mesmo PID casa K86 (id:1168) e K2405 (id:3041).
        var identityConfirmed = false
        var lastError: String?
    }

    private(set) var status = Status()
    var onChange: ((Status, Int) -> Void)?

    // MARK: Dependências

    let executor: K86HIDExchange
    private let serviceQueue = DispatchQueue(label: "br.com.douglas.fluido.k86.service", qos: .userInitiated)
    private let stateLock = NSLock()

    // MARK: Ciclo de vida (invalidação de callbacks)

    enum Lifecycle: Equatable { case idle, active, stopping }
    private var lifecycle: Lifecycle = .idle
    /// Token/epoch monotônico do ciclo: capturado em matching/removal/reattach/
    /// bind e VALIDADO na entrega — callback antigo de stop→start morre.
    private var lifecycleToken = 0
    /// Última re-descoberta automática (cooldown dead→reattach→open-falha→loop).
    private var lastAutomaticReattach: Date = .distantPast
    static let automaticReattachCooldown: TimeInterval = 2.0
    /// IORegistryEntryID do device VÍNCULADO: teclado/consumer/config de um
    /// mesmo composto compartilham LocationID — a remoção só é atribuída com
    /// o entryIDENTITY exato, LocationID não distingue interfaces.
    private var boundEntryID: Int?

    /// Fonte de candidatos injetável: em produção enumera via IOHIDManager e
    /// devolve (device, link); testes injetam listas sintéticas.
    internal var enumerateCandidates: () -> [(device: IOHIDDevice, link: any K86HIDLink)]

    private var manager: IOHIDManager?

    init(exchange: K86HIDExchange = K86HIDExchange(label: "br.com.douglas.fluido.k86.io")) {
        self.executor = exchange
        self.enumerateCandidates = { [] } // substituído no start() com a fonte IOKit
        executor.onStateChanged = { [weak self] newState in
            guard let self else { return }
            self.serviceQueue.async {
                self.executorStateChanged(newState)
            }
        }
    }

    // MARK: Ciclo de vida

    func start() {
        evaluatePermission()
        stateLock.lock()
        guard lifecycle != .active else {
            stateLock.unlock()
            return
        }
        lifecycle = .active
        lifecycleToken += 1 // novo ciclo: callbacks de ciclos velhos morrem
        callbackContext = CallbackContext(service: self, token: lifecycleToken) // token DO REGISTRO
        stateLock.unlock()
        guard manager == nil else { return }
        registerCallbacks()
    }

    /// Contexto dos callbacks C: (service, token imutável DO REGISTRO) —
    /// closures C function pointer NÃO capturam escopo, então o token do ciclo
    /// de registro vem POR CONTEXTO e é validado em cada hop (rev.5 ponto B).
    final class CallbackContext: @unchecked Sendable {
        weak var service: K86HidService?
        let registeredToken: Int
        init(service: K86HidService, token: Int) {
            self.service = service
            self.registeredToken = token
        }
    }
    private var callbackContext: CallbackContext?

    /// Registro dos callbacks com o token imutável_DO_REGISTRO (rev.5 ponto B):
    /// evento de ciclo N sobrevivendo a stop/start N+1 é dropado.
    private func registerCallbacks() {
        guard let contextObject = callbackContext else { return }
        let context = Unmanaged.passUnretained(contextObject).toOpaque()
        let newManager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(newManager,
            ["VendorID": NSNumber(value: K86Fingerprint.vendorID)] as CFDictionary)
        IOHIDManagerOpen(newManager, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerScheduleWithRunLoop(newManager, CFRunLoopGetMain(),
                                        "kCFRunLoopDefaultMode" as CFString)
        IOHIDManagerRegisterDeviceMatchingCallback(newManager, { context, _, _, _ in
            guard let context else { return }
            let holder = Unmanaged<CallbackContext>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async {
                // token DO REGISTRO (imutável, dado o próprio registro) — hop 1.
                holder.service?.matchingCallbackReport(registeredToken: holder.registeredToken)
            }
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(newManager, { context, _, _, device in
            guard let context else { return }
            let holder = Unmanaged<CallbackContext>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async {// hop 1 do removal também carrega o token do registro
                holder.service?.removalCallbackReport(for: device,
                                                      registeredToken: holder.registeredToken)
            }
        }, context)
        manager = newManager
        enumerateCandidates = { [weak self] in self?.productionCandidates() ?? [] }
        reattachAsync()
    }

    func stop() {
        stateLock.lock()
        guard lifecycle != .stopping else {
            stateLock.unlock()
            executor.detach(reason: "stop reentrante") // sempre invalida
            return
        }
        lifecycle = .stopping      // callbacks enfileirados são invalidados aqui
        lifecycleToken += 1        // callbacks antigos de matching/removal morrem
        let helper = manager
        manager = nil
        stateLock.unlock()
        // stop SEMPRE invalida o executor — mesmo sem manager (rev. 3 ponto 3)
        executor.detach(reason: "stop")
        guard let hidManager = helper else { return }
        IOHIDManagerUnscheduleFromRunLoop(hidManager, CFRunLoopGetMain(),
                                         "kCFRunLoopDefaultMode" as CFString)
        IOHIDManagerClose(hidManager, IOOptionBits(kIOHIDOptionsTypeNone))
        notifyChange()
    }

    /// Apenas PREFLIGHT — sem prompt automático (pedido do líder): a solicitação
    /// de input monitoramento será ação EXPLÍCITA contextual na UI (célula future).
    func evaluatePermission() {
        let granted = CGPreflightListenEventAccess()
        k86Log.info("preflight ListenEvent (sem prompt automático): \(granted, privacy: .public)")
        setStatus { status in
            if status.permissionPending == granted {
                status.permissionPending = !granted
            }
        }
    }

    // MARK: Descoberta (produção)

    internal func reattachAsync(claimingToken: Int? = nil) {
        stateLock.lock()
        let token = claimingToken ?? lifecycleToken
        let still = lifecycleToken == token && lifecycle == .active
        stateLock.unlock()
        guard still else { return } // ciclo mudou antes até de enfileirar
        serviceQueue.async { [self] in
            stateLock.lock()
            let delivered = lifecycleToken == token && lifecycle == .active
            stateLock.unlock()
            guard delivered else { return } // ciclo mudou na fila
            reattachNow(token: token)
        }
    }

    /// Remoção: SÓ derruba a sessão quando device removido é o VINCULADO —
    /// qualquer outra interface do mesmo vendor é IGNORADA.
    internal func removalOfDevice(entryID removedEntryID: Int?) {
        stateLock.lock()
        let bound = boundEntryID
        stateLock.unlock()
        guard let removedEntryID, let bound, removedEntryID == bound else {
            k86Log.info("remoção de device NÃO vinculado (entryID \(removedEntryID ?? -1, privacy: .public)) — sessão intocada")
            return
        }
        boundEntryID = nil
        executor.detach(reason: "disconnect")
        notifyChange()
    }

    /// (rev.5 ponto C) helper estático referenciado por instância:
    private func deviceRegistryEntryID(of device: IOHIDDevice) -> Int? {
        Self.registryEntryID(of: device)
    }

    /// Espelho do estado do executor + política de re-descoberta:
    /// - `.dead` vindos de disconnect/timeout RESOLVIDO podem reconnectar
    ///   (com midzinha/cooldown de 2 s);
    /// - `.dead` de `open falhou` NÃO dispara loop (reattach→attach→dead): só
    ///   um callback de matching DO SISTEMA re-tenta.
    internal func executorStateChanged(_ newState: K86HIDExchange.ExecutorState) {
        mirrorExecutorState()
        guard case .dead(_, let reason) = newState else { return }
        // Prevenção de loop: 'open falhou' só volta por matching do sistema.
        guard !reason.hasPrefix("open") else {
            k86Log.info("dead por open-falha — aguardando callback do sistema, sem loop de redescoberta")
            return
        }
        let now = Date()
        stateLock.lock()
        let due = now.timeIntervalSince(lastAutomaticReattach) >= Self.automaticReattachCooldown
        let active = lifecycle == .active
        if due { lastAutomaticReattach = now }
        stateLock.unlock()
        guard due, active else { return }
        reattachAsync() // captura o token do ciclo e valida na entrega (rev. 3)
    }

    /// Contador observável para testes do ciclo de vida (dependência injetada).
    internal var reattachAttemptsForTesting = 0
    private func countReattachAttempt(token: Int) {
        stateLock.lock()
        if lifecycleToken == token { reattachAttemptsForTesting += 1 } // entrega token-válida
        stateLock.unlock()
    }

    /// Callback `matching` com token capturado e validado NA ENTREGA (rev. 3):
    /// callback de ciclo antigo (stop→start) não sobrevive.
    internal func matchingCallbackReport(registeredToken: Int) {
        // Token DO REGISTRO vs ciclo corrente: callback do ciclo velho morre
        // imediatamente (stop→start), não apenas no destino.
        stateLock.lock()
        let current = lifecycleToken
        let active = lifecycle == .active
        stateLock.unlock()
        guard active, registeredToken == current else {
            k86Log.info("matching callback de ciclo \(registeredToken, privacy: .public) descartado (ciclo \(current, privacy: .public))")
            return
        }
        reattachAsync(claimingToken: registeredToken)
    }

    /// Callback `removal` com token na entrega; identidade por IORegistryEntryID
    /// (LocationID NÃO distingue interfaces do mesmo composto — rev. 3 ponto 4).
    internal func removalCallbackReport(for device: IOHIDDevice, registeredToken: Int) {
        stateLock.lock()
        let current = lifecycleToken
        let active = lifecycle == .active
        stateLock.unlock()
        guard active, registeredToken == current else {
            k86Log.info("removal callback de ciclo \(registeredToken, privacy: .public) descartado (ciclo \(current, privacy: .public))")
            return
        }
        let entryID = deviceRegistryEntryID(of: device) // helper de PRODUÇÃO (SDK)
        removalOfDevice(entryID: entryID)
    }

    /// Leitura do token do ciclo para testes (validação fora do serviço).
    internal var lifecycleTokenForTesting: Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return lifecycleToken
    }

    /// Caminho de produção `start()` sem tocar IOHIDManager (fase de testes):
    /// espelha start() INTEIRO (incrementa o token como o líder pediu).
    internal func activateLifecycle() {
        stateLock.lock()
        lifecycle = .active
        lifecycleToken += 1 // espelha start(): novo ciclo, callbacks velhos morrem
        stateLock.unlock()
    }

    private func reattachNow(token: Int) {
        countReattachAttempt(token: token)
        stateLock.lock()
        let alive = lifecycle == .active && lifecycleToken == token
        let helper = manager
        stateLock.unlock()
        // Callback antigo/stop: sem redescoberta com manager fechado.
        guard alive, helper != nil else { return }
        // Nenhum attach enquanto operação em voo/quarentina: o executor recusa
        // ANTES de tocar o device e o callback de estado reagenda via dead.
        guard executor.isAttachableNow else { return }
        let candidates = enumerateCandidates()
        guard let first = candidates.first else {
            k86Log.info("nenhum candidato com a coleção 0xFFFF:0x0002 (enumerados: \(candidates.count))")
            setStatus { status in
                status.deviceSeen = false
            }
            notifyChange()
            return
        }
        IOHIDDeviceScheduleWithRunLoop(first.device, CFRunLoopGetMain(),
                                       "kCFRunLoopDefaultMode" as CFString)
        bindCandidate(link: first.link, completion: { _ in })
    }

    /// Caminho de produção do vínculo de um candidato: executor.attach + espelho
    /// de status. `reattachNow` chama isto; os testes injetam links fake direto.
    internal func bindCandidate(link: any K86HIDLink,
                                completion: @escaping @Sendable (Bool) -> Void) {
        stateLock.lock()
        let bindToken = lifecycleToken
        stateLock.unlock()
        executor.attach(link: link, completion: { [weak self] result in
            guard let self else { return }
            // Publicação com MESMA GUARDA ATÔMICA do token: check + status
            // mutação no MESMO holding do lock (sem janela para stop intercalar).
            self.applyBindOutcome(result, bindToken: bindToken, completion: completion)
        })
    }

    private func applyBindOutcome<E: Error>(_ result: Result<K86LinkProperties, E>,
                                            bindToken: Int,
                                            completion: @escaping @Sendable (Bool) -> Void) {
        // Validação + mutação de status ATÔMICAS (mesma guarda do token); o
        // SNAPSHOT final e a geração são capturados AINDA sob o lock; depois
        // unlock e SÓ ENTÃO notify + completion — callback reentrante pode
        // consultar currentGeneration/status/stop sem dead-travamento
        // (rev.5 correção: nada de completion sob stateLock).
        stateLock.lock()
        var deliveredSnapshot: Status?
        var deliveredGeneration = 0
        var outcome = false
        if lifecycleToken == bindToken, lifecycle == .active {
            switch result {
            case .success(let properties):
                var facts: K86Fingerprint.DescriptorFacts?
                if let descriptor = properties.reportDescriptor {
                    facts = K86Fingerprint.descriptorFacts(descriptor)
                }
                status.permissionPending = false
                status.deviceSeen = true
                status.bound = true
                status.vendorID = properties.vendorID
                status.productID = properties.productID
                status.locationID = properties.locationID
                status.maxFeatureReportSize = properties.maxFeatureReportSize
                status.descriptorUnnumberedFeature = facts?.unnumberedFeature
                status.descriptorFeatureByteCount = facts?.featureByteCount
                status.descriptorMatchesReference = facts.map { $0 == K86Fingerprint.referenceDescriptorFacts }
                status.identityConfirmed = false
                status.protocolVariantUnresolved = true
                status.sessionReason = nil
                status.lastError = nil
                boundEntryID = properties.registryEntryID
            case .failure(let error):
                status.bound = false
                status.lastError = "attach: \(error)"
            }
            deliveredSnapshot = status // captura ATÔMICA do snapshot final
            deliveredGeneration = executor.envelopeSnapshot()?.generation ?? 0
            if case .success = result { outcome = true } else { outcome = false }
        } else {
            // Ciclo mudou durante open (stop/start): bind descartado ANTES de
            // publicar qualquer estado — snapshot NÃO é entregue como sucesso.
            status.lastError = "bind descartado: ciclo mudou durante open (stop/start)"
        }
        stateLock.unlock()
        // FORA do lock: notifier (com snapshot CAPTURADO — nunca reler) e completion.
        if let snap = deliveredSnapshot {
            onChange?(snap, deliveredGeneration) // observador recebe o final
        }
        completion(outcome)
    }

    /// Enumeração com **IOHIDElementGet\*** (o cast para dicionários estava
    /// errado): PID permitido + coleção 0xFFFF:0x0002 nos elementos OU
    /// PrimaryUsagePage/Usage + validação por PARSE do descritor real
    /// (ReportCount 64, ReportSize 8, sem Report ID). Sem descritor que valide
    /// os fatos, o candidato não é aceito — substring nunca prova sozinha.
    private func productionCandidates() -> [(device: IOHIDDevice, link: any K86HIDLink)] {
        guard let manager, let services = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else {
            return []
        }
        var result: [(IOHIDDevice, any K86HIDLink)] = []
        for device in services {
            guard let pid = (IOHIDDeviceGetProperty(device, "ProductID" as CFString) as? NSNumber)?.intValue,
                  K86Fingerprint.candidatePIDs.contains(pid) else { continue }
            guard qualifiesByCollectionAndDescriptor(device) else { continue }
            result.append((device, IOKitHIDLink(device: device)))
        }
        return result
    }

    /// Elementos com IOHIDElementGet*; fallback PrimaryUsagePage/Usage.
    private func collectionSamples(_ device: IOHIDDevice) -> [K86Fingerprint.ElementSample] {
        var samples: [K86Fingerprint.ElementSample] = []
        if let elements = IOHIDDeviceCopyMatchingElements(device, nil, 0) as? [IOHIDElement] {
            for element in elements where IOHIDElementGetType(element) == kIOHIDElementTypeCollection {
                samples.append(K86Fingerprint.ElementSample(
                    usagePage: Int(IOHIDElementGetUsagePage(element)),
                    usage: Int(IOHIDElementGetUsage(element)),
                    type: Int(IOHIDElementGetType(element).rawValue)))
            }
        }
        if samples.isEmpty {
            // Propriedades do device: o uso PRIMÁRIO (top-level collection).
            let page = (IOHIDDeviceGetProperty(device, "PrimaryUsagePage" as CFString) as? NSNumber)?.intValue
            let usage = (IOHIDDeviceGetProperty(device, "PrimaryUsage" as CFString) as? NSNumber)?.intValue
            if let page, let usage {
                samples.append(K86Fingerprint.ElementSample(usagePage: page, usage: usage,
                                                            type: K86Fingerprint.collectionElementRawValue)) // uso primário = coleção
            }
        }
        return samples
    }

    /// Helper de PRODUÇÃO para IORegistryEntryID — NÃO depende da propriedade
    /// `IORegistryEntryID` (que pode faltar): `IOHIDDeviceGetService`
    /// (IOHIDDevice.h ≈73–84, MACH_PORT_NULL se sem service) +
    /// `IORegistryEntryGetRegistryEntryID` (IOKitLib.h ≈1149–1159, uint64
    /// global válido até reboot). Usado no link E no removal (mesma fonte).
    /// Ownership (rev.5 correção): `IOHIDDeviceGetService` é **Get**
    /// (referência EMPRESTADA do IOKit) — NENHUM `IOObjectRelease` aqui,
    /// pois nós não fizemos retain/Create/Copy; release sem getter é
    /// over-release. (IOHIDDevice.h ≈73–84; IOKitLib.h ≈1149–1159.)
    static func registryEntryID(of device: IOHIDDevice) -> Int? {
        let service = IOHIDDeviceGetService(device)
        guard service != MACH_PORT_NULL else { return nil }
        var entryID: UInt64 = 0
        let result = IORegistryEntryGetRegistryEntryID(service, &entryID)
        guard result == kIOReturnSuccess else { return nil }
        return Int(entryID)
    }

    private func qualifiesByCollectionAndDescriptor(_ device: IOHIDDevice) -> Bool {
        guard K86Fingerprint.hasConfigCollection(elements: collectionSamples(device)) else {
            return false
        }
        // Descritor REAL: aprovação por FATOS do parse (não substring), e a
        // referência é o hex que o líder capturou no IORegistry deste Mac.
        guard let descriptor = IOHIDDeviceGetProperty(device, "ReportDescriptor" as CFString) as? Data else {
            // Sem descritor exponível: seleção desabilitada (nunca substring sozinha).
            k86Log.info("candidato sem descritor legível — recusado por política")
            return false
        }
        guard let facts = K86Fingerprint.descriptorFacts(Array(descriptor)) else {
            k86Log.info("descritor não casa com os fatos da coleção de configuração (64 B, unnumbered) — recusado")
            return false
        }
        return facts == K86Fingerprint.referenceDescriptorFacts
    }

    // MARK: Guarda de fase + troca (completion, nunca bloqueante)

    /// A guarda é decisão local (codec/executor): fase GET-only; nenhum SET
    /// passa. O frame é construído PELO codec (checksum) e a troca inteira
    /// roda no executor serial (envelope geração+token no aceite e término).
    func exchange(message: [UInt8], checksum: K86ChecksumType = .bit7,
                  readDelayMs: UInt32 = K86HidService.readDelayMs,
                  deadlineMs: UInt32 = 900,
                  onAccepted: (@Sendable (K86HIDExchange.Envelope) -> Void)? = nil,
                  completion: @escaping @Sendable (Result<[UInt8], K86HIDExchange.K86IOError>) -> Void) throws {
        guard let command = message.first else { throw K86ServiceError.notAQueryCommand(command: 0) }
        if !K86PhasePolicy.isDiscoveryQuery(command) {
            if K86Command(rawValue: command) != nil {
                throw K86ServiceError.configWritesBlockedInDiscoveryPhase(command: command)
            }
            throw K86ServiceError.notAQueryCommand(command: command)
        }
        let frame = try K86Codec.encode(message: message, checksum: checksum)
        executor.exchange(frame: frame,
                          readDelayMs: readDelayMs,
                          deadlineMs: deadlineMs,
                          onAccepted: onAccepted ?? { _ in },
                          completion: { result in
                              completion(result)
                          })
    }

    /// `iA.readMsg` default (`n=10`) — espera send→read.
    static let readDelayMs: UInt32 = 10
    /// `defaultVendorSleepTime = 500` da classe K (`438d24dc.js` ≈185) — pausa
    /// pós-escrita deliberada do nível acima (não automática daqui).
    static let writeSettleMs: UInt32 = 500

    /// Versão como leitura NÃO VALIDADA (bytes crus + eco); eco não confirma
    /// variante (P1-1c) nem identidade; zeros/curtos não viram valor positivo.
    func readVersionUnchecked(deadlineMs: UInt32 = 900,
                              completion: @escaping @Sendable (Result<VersionReadout, K86HIDExchange.K86IOError>) -> Void) throws {
        try exchange(message: [0x80], deadlineMs: deadlineMs, completion: { result in
            switch result {
            case .success(let bytes):
                completion(.success(VersionReadout(raw: bytes, echoMatches: bytes.first == 0x80)))
            case .failure(let error):
                completion(.failure(error))
            }
        })
    }

    // MARK: Espelho de estado

    private func mirrorExecutorState() {
        let snapshot = executor.stateSnapshot()
        setStatus { status in
            switch snapshot {
            case .ready:
                status.sessionReason = nil
            case .quarantined(_, _, let reason):
                status.sessionReason = reason
                status.lastError = reason
            case .dead(_, let reason):
                status.bound = false
                status.sessionReason = "resolvida: sessão encerrada (\(reason))"
            case .idle:
                status.bound = false
            case .opening(let gen):
                // NADA é publicado como attached antes de open terminar (rev. 3):
                // espelho reflete a reserva (bound=false até .ready chegar).
                status.bound = false
                status.sessionReason = "opening (g\(gen)): open em andamento"
            case .inFlight:
                break
            }
        }
        notifyChange()
    }

    // MARK: Estado/notificação

    func currentGeneration() -> Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return executor.envelopeSnapshot()?.generation ?? 0
    }

    private func setStatus(_ change: (inout Status) -> Void) {
        stateLock.lock()
        change(&status)
        stateLock.unlock()
    }

    private func notifyChange() {
        stateLock.lock()
        let snapshot = status
        let generation = executor.envelopeSnapshot()?.generation ?? 0
        stateLock.unlock()
        onChange?(snapshot, generation)
        // testes pendem desta cópia — nada de Thread.sleep aqui
    }
}

/// Implementação de produção da porta `K86HIDLink` sobre IOKit. Framing dos
/// headers oficiais (SDK MacOSX15.2 `IOHIDDevice.h`): report ID no parâmetro
/// (payload sem prefixo — unnumbered, provado pelo descritor real), código
/// IOReturn REAL propagado.
final class IOKitHIDLink: K86HIDLink {

    private let device: IOHIDDevice
    let properties: K86LinkProperties

    init(device: IOHIDDevice) {
        self.device = device
        self.properties = K86LinkProperties(
            vendorID: (IOHIDDeviceGetProperty(device, "VendorID" as CFString) as? NSNumber)?.intValue ?? -1,
            productID: (IOHIDDeviceGetProperty(device, "ProductID" as CFString) as? NSNumber)?.intValue ?? -1,
            locationID: (IOHIDDeviceGetProperty(device, "LocationID" as CFString) as? NSNumber)?.intValue ?? -1,
            maxFeatureReportSize: (IOHIDDeviceGetProperty(device, "MaxFeatureReportSize" as CFString) as? NSNumber)?.intValue,
            reportDescriptor: (IOHIDDeviceGetProperty(device, "ReportDescriptor" as CFString) as? Data).map { Array($0) },
            registryEntryID: K86HidService.registryEntryID(of: device))
    }

    func open() -> Bool {
        // Não-exclusiva, sem Seize (kIOHIDOptionsTypeNone; IOHIDKeys.h §231 vs
        // kIOHIDOptionsTypeSeizeDevice IOHIDDevice.h §93).
        IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess
    }

    func close() {
        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    func setFeature(reportID: Int, payload: [UInt8]) throws {
        // IOHIDDeviceSetReport doc (≈640–655): o payload só carrega ID no 1º
        // byte se o device suporta múltiplos reports — o K86 (descritor real,
        // sem item `85`) é unnumbered ⇒ reportID 0 no parâmetro, 64 bytes puros.
        let result = payload.withUnsafeBufferPointer { pointer in
            IOHIDDeviceSetReport(device, kIOHIDReportTypeFeature, CFIndex(reportID),
                                 pointer.baseAddress!, CFIndex(payload.count))
        }
        guard result == kIOReturnSuccess else {
            throw K86ReportError.reportFailed(code: result)
        }
    }

    func getFeature(reportID: Int, byteCount: Int) throws -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: byteCount)
        var length: CFIndex = CFIndex(byteCount)
        let result = buffer.withUnsafeMutableBufferPointer { pointer in
            IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, CFIndex(reportID),
                                 pointer.baseAddress!, &length)
        }
        guard result == kIOReturnSuccess else {
            throw K86ReportError.reportFailed(code: result)
        }
        let effective = max(0, min(Int(length), byteCount))
        guard effective > 0 else { return [] }
        return Array(buffer[0..<effective])
    }
}
