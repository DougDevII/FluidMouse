import Foundation

/// **Executor serial de I/O do K86** — dono ÚNICO da vida do link e do
/// dispositivo: open/close/send/read acontecem todos NESTA fila serial
/// (exigência do líder: teardown nunca roda noutra thread enquanto uma
/// transação usa o device; `close` não ocorre antes da I/O terminar).
///
/// Máquina de estados da sessão:
/// - `idle` — sem link; attach permitido.
/// - `ready(gen)` — link aberto, sem operação; attach (troca de device) e
///   exchange permitidos.
/// - `inFlight(gen, token)` — transação em execução no executor; NENHUMA nova
///   operação/detach-close é aceita (recusada ANTES de tocar o device).
/// - `quarantined(gen, token, reason)` — timeout/disconnect encerrou a
///   conclusão **1×** e invalidou a sessão; a operação REAL pode ainda estar
///   em voo (nada é cancelado por fingimento): novas operações são REJEITADAS
///   até o worker real terminar, e só então o link é fechado (pelo próprio
///   worker) e o estado vira `dead` — aí sim um novo attach/reconnect é
///   possível.
/// - `dead(gen, reason)` — sessão encerrada com device fechado; reattach permitido.
///
/// **Envelope geração+token**: cada transação captura seu envelope no aceite
/// (dentro do executor, atômico em relação aos outros blocos) e o término é
/// entregue UMA vez, validado contra a sessão do aceite. Completion/callback
/// de sessão antiga não muda estado nem entrega segundo resultado; comando de
/// sessão antiga é rejeitado antes de qualquer I/O.
///
/// **Erros**: código real do link (IOReturn) propaga em
/// `K86IOError.ioFailure(code:)`; timeout é erro próprio
/// (`K86IOError.timeout`). API é assíncrona por completion — nada bloqueia a
/// thread do chamador com sleep/semáforo. `Thread.sleep` não existe aqui: a
/// espera entre send e read é `asyncAfter` na própria fila do executor, e o
/// estado `inFlight` cobre o intervalo inteiro, então a fila não intercala.
///
/// Nenhum report é enviado por attach/detach — só pelas transações decididas
/// pelo nível acima.
package final class K86HIDExchange: @unchecked Sendable {

    package struct Envelope: Equatable, Sendable {
        package let generation: Int
        package let token: Int
    }

    package enum ExecutorState: Equatable, Sendable {
        case idle
        case ready(generation: Int)
        /// open() EM ANDAMENTO no link novo — nada antes disso é publicado
        /// como attached; detach durante open invalida e o open que retorna
        /// revalida o epoch antes de publicar sucesso.
        case opening(generation: Int)
        case inFlight(generation: Int, token: Int)
        case quarantined(generation: Int, token: Int, reason: String)
        case dead(generation: Int, reason: String)
    }

    package enum RejectReason: Equatable, Sendable {
        case noLink
        case opening(generation: Int)
        case operationInFlight(generation: Int, token: Int)
        case quarantined(token: Int, reason: String) // attach/exchange negados: worker real ainda em voo
        case dead(generation: Int, reason: String)
    }

    package enum K86IOError: Error, Equatable {
        /// Recusa ANTES de qualquer I/O (inFlight/quarantined/dead/idle sem link).
        case rejected(reason: RejectReason)
        /// Timeout como erro PRÓPRIO (não `kIOReturnError` genérico).
        case timeout(deadlineMs: UInt32)
        /// Sessão perdida no meio (disconnect declarado) — conclusão única.
        case sessionEnded(reason: String)
        /// Falha real do link com o código IOReturn genuíno.
        case ioFailure(code: Int32)
        /// Comando aceito, mas o device respondeu vazio.
        case emptyResponse
    }

    package let queue: DispatchQueue // executor serial: TODO acesso ao device passa aqui
    /// Fila de prazos SEPARADA do executor: o worker real pode ficar preso
    /// dentro de getFeature/setFeature; o prazo não pode ficar preso com ele.
    private let timerQueue: DispatchQueue
    private let lock = NSLock()

    private var state: ExecutorState = .idle
    private var link: (any K86HIDLink)?
    private var generation = 0
    /// Epoch de INTENÇÃO: cresce a CADA transição de ciclo (attach commit,
    /// detach até em idle/dead, resolução de quarentina) — propostas enfileiradas
    /// (attach/exchange) capturam o epoch na submissão e são RECUSADAS quando
    /// o ciclo mudou. Nada de intenção antiga reaplicada.
    private var intentEpoch = 0
    private var nextToken = 0
    private var pendingByToken: [Int: Pending] = [:]

    /// Fim da quarentina (worker real terminou → `dead`) e outros eventos de
    /// estado — para o nível acima agendar redescoberta/reconnect. Chamado
    /// dentro do executor; o observador só agenda trabalho, nunca toca device.
    package var onStateChanged: (@Sendable (ExecutorState) -> Void)?

    private struct Pending {
        let envelope: Envelope
        let completion: @Sendable (Result<[UInt8], K86IOError>) -> Void
    }

    package init(label: String) {
        queue = DispatchQueue(label: label, qos: .userInitiated)
        timerQueue = DispatchQueue(label: label + ".deadline", qos: .userInitiated)
    }

    package func stateSnapshot() -> ExecutorState {
        lock.lock()
        defer { lock.unlock() }
        return state
    }

    /// Checagem rápida para o chamador evitar submeter attach sabidamente
    /// recusado (a porta real de decisão é o gate DENTRO do attach, atômico).
    package var isAttachableNow: Bool {
        lock.lock()
        defer { lock.unlock() }
        return state.isAttachable
    }

    package func envelopeSnapshot() -> Envelope? {
        lock.lock()
        defer { lock.unlock() }
        switch state {
        case .ready(let g), .inFlight(let g, _):
            return Envelope(generation: g, token: nextToken)
        case .quarantined(let g, let token, _):
            return Envelope(generation: g, token: token)
        default:
            return nil // idle/opening/dead: nenhum envelope válido
        }
    }

    // MARK: Attach (troca/criação de sessão)

    /// Vínculo vinculado à SUBMISSÃO: o snapshot de geração é capturado AGORA
    /// (na thread do chamador) e revalidado no executor — attach enfileirado
    /// durante IÓ bloqueado é recusado na hora e NÃO reaplica intenção antiga
    /// quando a sessão antiga termina / se renova.
    package func attach(link: any K86HIDLink,
                        completion: @escaping @Sendable (Result<K86LinkProperties, K86IOError>) -> Void) {
        lock.lock()
        guard state.isAttachable else {
            let reason = rejectReasonFor(state)
            lock.unlock()
            completion(.failure(.rejected(reason: reason))) // antes de enfileirar
            return
        }
        let submittedGeneration = generation
        let submittedEpoch = intentEpoch
        lock.unlock()
        queue.async { [self] in
            attachGate(link: link, submittedGeneration: submittedGeneration,
                       submittedEpoch: submittedEpoch, completion: completion)
        }
    }

    private func attachGate(link: any K86HIDLink, submittedGeneration: Int, submittedEpoch: Int,
                            completion: @escaping @Sendable (Result<K86LinkProperties, K86IOError>) -> Void) {
        // 1) VALIDAÇÃO + COMMIT DE ESTADO ATÔMICOS (rev.5 ponto A): o gate
        // revalida (attachable, generation, epoch) e TUDO o que muda a sessão
        // (swap de link, generation++, epoch++, estado .opening) acontece sob
        // O MESMO lock — não existe janela entre revalidação e commit. O
        // close do device antigo e o open do novo ficam FORA do lock (fila
        // serial), com a revalidação OBRIGATÓRIA logo depois do open.
        let openedGeneration: Int
        lock.lock()
        guard state.isAttachable,
              generation == submittedGeneration, intentEpoch == submittedEpoch else {
            // ciclo mudou desde a submissão: intenção antiga NÃO reaplicada.
            let reason = rejectReasonFor(state)
            lock.unlock()
            completion(.failure(.rejected(reason: reason)))
            return
        }
        var previous: (any K86HIDLink)?
        if case .ready = state {
            previous = self.link
            self.link = nil
        }
        self.link = link // posse NOVA já sob o lock (sem janela para detach roubar)
        generation += 1
        intentEpoch += 1 // commit do attach
        openedGeneration = generation
        let openEpoch = intentEpoch
        state = .opening(generation: openedGeneration)
        lock.unlock()
        emitStateChange(.opening(generation: openedGeneration))

        // 2) close do antigo / open do novo FORA do lock (	executor serial):
        previous?.close()
        let opened = link.open() // non-exclusive; PODE bloquear

        // 3) Revalidação pós-open + commit do resultado ATÔMICOS: detach/stop
        // durante `opening` avança o epoch e captura o link como victim — o
        // open que retornar NÃO ressuscita a sessão.
        lock.lock()
        guard intentEpoch == openEpoch, state == .opening(generation: openedGeneration) else {
            let reason: K86IOError
            if case .dead(_, let deadReason) = state {
                reason = .sessionEnded(reason: "attach cancelado durante open: \(deadReason)")
            } else {
                reason = .rejected(reason: rejectReasonFor(state))
            }
            lock.unlock()
            completion(.failure(reason))
            // O close do device novo é do VICTIM capturado pelo detach (1×);
            // esta gate NÃO toca self.link (posse virou do detach).
            return
        }
        if opened {
            state = .ready(generation: openedGeneration) // único holding do lock
            lock.unlock()
            emitStateChange(.ready(generation: openedGeneration))
            completion(.success(link.properties))
        } else {
            link.close() // este link é NOSSO (nada capturou; epoch eu dono)
            self.link = nil
            state = .dead(generation: openedGeneration, reason: "open falhou — permissões/IOHIDDeviceOpen")
            lock.unlock()
            emitStateChange(.dead(generation: openedGeneration, reason: "open falhou"))
            completion(.failure(.rejected(reason: .dead(generation: openedGeneration, reason: "open falhou"))))
        }
    }

    // MARK: Detach (disconnect / stop)

    /// Disconnect ou encerramento. Se há operação em voo, NÃO fecha o device:
    /// Disconnect ou encerramento. Invariante central: o epoch de intenção
    /// AVANÇA em TODO branch (até em idle/dead), então propostas enfileiradas
    /// antes são recusadas no gate. Em `ready` o estado vai a `dead`
    /// IMEDIATAMENTE e o close é do VICTIM capturado (idêntico 1×) na fila;
    /// em `opening` o open que retornar revalida o epoch e completa falha;
    /// em `inFlight` marca quarentina, entrega a conclusão UMA vez e o worker
    /// real termina antes de qualquer close.
    package func detach(reason: String) {
        lock.lock()
        switch state {
        case .inFlight(let gen, let token):
            state = .quarantined(generation: gen, token: token, reason: "disconnect: \(reason)")
            intentEpoch += 1
            let pending = pendingByToken.removeValue(forKey: token)
            lock.unlock()
            emitStateChange(.quarantined(generation: gen, token: token, reason: "disconnect: \(reason)"))
            if let pending {
                deliverOnce(pending: pending, outcome: .failure(.sessionEnded(reason: "disconnect: \(reason)")))
            }
        case .ready:
            // Ready: validação IMEDIATA (estado) — close NÃO fica agendado onde
            // um attach enfileirado poderia "usar" o device; transição para dead
            // acontece AGORA, epoch de intenção avança, e o close é do VICTIM
            // capturado, INCONDICIONAL e exatamente 1× na fila do executor
            // (attach válido enfileirado antes do detach é recusado pelo epoch
            // no gate; quem abrir depois é intenção própria e nova).
            guard case .ready(let gen) = state else {
                lock.unlock()
                return
            }
            state = .dead(generation: gen, reason: "disconnect: \(reason)")
            intentEpoch += 1
            let victim = self.link
            self.link = nil
            lock.unlock()
            emitStateChange(.dead(generation: gen, reason: "disconnect: \(reason)"))
            queue.async { [self] in
                self.closeOwnedVictim(victim)
            }
        case .opening(let gen):
            // Open em andamento: invalida o epoch IMEDIATAMENTE (proposta de
            // sessão morre); o open que RETURNISAR vai revalidar o epoch e
            // completar como FALHA. O close do device novo é do victim
            // capturado aqui (1×), executado na fila DEPOIS do open terminar
            // (FIFO) — nenhum doble-close.
            state = .dead(generation: gen, reason: "disconnect durante open: \(reason)")
            intentEpoch += 1
            let victim = self.link
            self.link = nil
            lock.unlock()
            emitStateChange(.dead(generation: gen, reason: "disconnect durante open: \(reason)"))
            queue.async { [self] in
                self.closeOwnedVictim(victim)
            }
        case .idle, .dead, .quarantined:
            // Mesmo sem sessão ativa, detach AVANÇA o epoch de intenção: propostas
            // enfileiradas antes (attach/exchange de ciclo velho) são invalidadas.
            intentEpoch += 1
            lock.unlock()
        }
    }

    /// Fechamento do device VÍNCULO capturado pelo detach — OWNERSHIP por
    /// sessão (rev.5 ponto A): quem captura o victim é o DONO exclusivo do
    /// close (self.link virou nil no capture), então o close é 1× estrutural
    /// NÃO por dedupe de endereço (que pode pular close de objeto novo com
    /// endereço reutilizado). Nenhum outro caminho fecha esse objeto: a gate
    /// de attach só fecha o link QUE ELA própria abriu (no falha com epoch
    /// dela), e a troca de ready fecha o `previous` que capturou.
    private func closeOwnedVictim(_ victim: (any K86HIDLink)?) {
        victim?.close()
    }

    // MARK: Transação (send + espera + read), por completion

    /// Aceite = execução do bloco no executor (envelope capturado em
    /// `onAccepted`); término = delivery único validado contra a sessão do
    /// aceite. Rejeita ANTES de qualquer I/O se a sessão não está `ready`.
    package func exchange(frame: [UInt8],
                          readDelayMs: UInt32 = 10,
                          deadlineMs: UInt32 = 900,
                          onAccepted: @escaping @Sendable (Envelope) -> Void,
                          completion: @escaping @Sendable (Result<[UInt8], K86IOError>) -> Void) {
        // Envelope vinculado à SUBMISSÃO: a geração é capturada AGORA (antes de
        // enfileirar) e revalidada no executor — um exchange enfileirado atrás
        // de um attach NUNCA é enviado no device novo; recusa imediata mesmo
        // com o executor preso num worker real se a sessão não está `ready`.
        lock.lock()
        let submittedGeneration: Int
        if case .ready(let gen) = state {
            submittedGeneration = gen
            lock.unlock()
        } else {
            let reason = rejectReasonFor(state)
            lock.unlock()
            completion(.failure(.rejected(reason: reason)))
            return
        }
        queue.async { [self] in
            exchangeGate(frame: frame, readDelayMs: readDelayMs, deadlineMs: deadlineMs,
                         submittedGeneration: submittedGeneration,
                         onAccepted: onAccepted, completion: completion)
        }
    }

    /// Bloco do executor: aceite (envelope), timer, send e agendamento da
    /// leitura — tudo atômico em relação aos outros blocos da fila.
    private func exchangeGate(frame: [UInt8], readDelayMs: UInt32, deadlineMs: UInt32,
                              submittedGeneration: Int,
                              onAccepted: @escaping @Sendable (Envelope) -> Void,
                              completion: @escaping @Sendable (Result<[UInt8], K86IOError>) -> Void) {
        lock.lock()
        guard case .ready(let actualGen) = state, actualGen == submittedGeneration,
              let current = link else {
            // A sessão mudou desde a submissão (attach/detach/disconnect mais
            // novo na fila): NÃO envia no device novo que não é o do aceite.
            let reason = rejectReasonFor(state)
            lock.unlock()
            completion(.failure(.rejected(reason: reason)))
            return
        }
        nextToken += 1
        let envelope = Envelope(generation: submittedGeneration, token: nextToken)
        state = .inFlight(generation: submittedGeneration, token: envelope.token)
        let pending = Pending(envelope: envelope, completion: completion)
        pendingByToken[envelope.token] = pending
        lock.unlock()

        onAccepted(envelope)
        installTimer(envelope: envelope, deadlineMs: deadlineMs)

        // send — no executor; o device não pode ser fechado por outra thread
        // porque detach/attach recusam enquanto `inFlight`.
        do {
            try current.setFeature(reportID: 0, payload: frame)
        } catch {
            finalize(envelope: envelope, outcome: .failure(mapLinkError(error)))
            return
        }
        // espera assíncrona na própria fila; `inFlight` cobre o intervalo.
        queue.asyncAfter(deadline: .now() + Double(readDelayMs) / 1000.0) { [self] in
            readPhase(envelope: envelope, deadlineMs: deadlineMs)
        }
    }

    private func readPhase(envelope: Envelope, deadlineMs: UInt32) {
        lock.lock()
        guard case .inFlight(_, let token) = state, token == envelope.token,
              let current = link else {
            lock.unlock()
            // Quarentina (timeout/disconnect): este é o ÚLTIMO bloco da
            // operação — agora é seguro fechar o device e virar `dead`.
            resolveQuarantine(envelope: envelope)
            return
        }
        lock.unlock()
        do {
            let bytes = try current.getFeature(reportID: 0, byteCount: K86Codec.fixedReportLength)
            if bytes.isEmpty {
                finalize(envelope: envelope, outcome: .failure(.emptyResponse))
            } else {
                finalize(envelope: envelope, outcome: .success(bytes))
            }
        } catch {
            finalize(envelope: envelope, outcome: .failure(mapLinkError(error)))
        }
    }

    /// Fim da operação de uma sessão já em quarentina: worker real terminou,
    /// então agora o close é permitido — estado vira `dead` e o reconnect é
    /// possível. Nenhum segundo resultado é entregue.
    private func resolveQuarantine(envelope: Envelope) {
        lock.lock()
        guard case .quarantined(let gen, let token, let reason) = state, token == envelope.token else {
            lock.unlock()
            return
        }
        self.link?.close()
        self.link = nil
        state = .dead(generation: gen, reason: "resolvida: \(reason)")
        lock.unlock()
        emitStateChange(.dead(generation: gen, reason: "resolvida: \(reason)"))
    }

    private func mapLinkError(_ error: Error) -> K86IOError {
        if let reportError = error as? K86ReportError, case .reportFailed(let code) = reportError {
            return .ioFailure(code: code)
        }
        return .ioFailure(code: kIOReturnError)
    }

    // MARK: Finalização (conclusão única + resolução de quarentina)

    private func finalize(envelope: Envelope, outcome: Result<[UInt8], K86IOError>) {
        lock.lock()
        let pending = pendingByToken.removeValue(forKey: envelope.token)
        switch state {
        case .inFlight(let gen, let token) where token == envelope.token && gen == envelope.generation:
            state = .ready(generation: gen)
            lock.unlock()
            emitStateChange(.ready(generation: gen))
            if let pending {
                deliverOnce(pending: pending, outcome: outcome)
            }
        case .quarantined(let gen, let token, let reason) where token == envelope.token:
            // A operação REAL terminou agora: é o único momento seguro para
            // fechar o device. Resultado é DESCARTADO (conclusão já entregue).
            self.link?.close()
            self.link = nil
            state = .dead(generation: gen, reason: "resolvida: \(reason)")
            lock.unlock()
            emitStateChange(.dead(generation: gen, reason: "resolvida: \(reason)"))
        default:
            lock.unlock()
        }
    }

    private func timeExpired(envelope: Envelope, deadlineMs: UInt32) {
        lock.lock()
        guard case .inFlight(let gen, let token) = state,
              token == envelope.token, gen == envelope.generation else {
            lock.unlock()
            return // já terminou OU já está em quarentina — conclusão anterior era única
        }
        state = .quarantined(generation: gen, token: token, reason: "timeout \(deadlineMs) ms")
        let pending = pendingByToken.removeValue(forKey: envelope.token)
        lock.unlock()
        emitStateChange(.quarantined(generation: gen, token: token, reason: "timeout \(deadlineMs) ms"))
        if let pending {
            deliverOnce(pending: pending, outcome: .failure(.timeout(deadlineMs: deadlineMs)))
        }
    }

    /// Prazo em fila PRÓPRIA (nunca na fila do executor, que o worker real
    /// pode ter travado dentro do IOKit). `timeExpired` valida o estado — sem
    /// cancelamento por fingimento.
    private func installTimer(envelope: Envelope, deadlineMs: UInt32) {
        timerQueue.asyncAfter(deadline: .now() + Double(deadlineMs) / 1000.0) { [weak self] in
            self?.timeExpired(envelope: envelope, deadlineMs: deadlineMs)
        }
    }

    private func deliverOnce(pending: Pending, outcome: Result<[UInt8], K86IOError>) {
        // Conclusão única é garantida ESTRUTURALMENTE: na quarentina o pending
        // é removido e a entrega acontece uma vez; o worker que termina depois
        // não redelivera porque o pending saiu e o estado não casa mais.
        pending.completion(outcome)
    }

    private func emitStateChange(_ newState: ExecutorState) {
        onStateChanged?(newState)
    }

    private func rejectReasonFor(_ forState: ExecutorState) -> RejectReason {
        switch forState {
        case .idle: return .noLink
        case .opening(let gen): return .opening(generation: gen)
        case .ready(let gen): return .dead(generation: gen, reason: "inconsistente") // não deveria ocorrer
        case .inFlight(let gen, let token): return .operationInFlight(generation: gen, token: token)
        case .quarantined(_, let token, let reason): return .quarantined(token: token, reason: reason)
        case .dead(let gen, let reason): return .dead(generation: gen, reason: reason)
        }
    }
}

extension K86HIDExchange.ExecutorState {
    /// attach permitido quando não há (nem pode haver) I/O em voo.
    package var isAttachable: Bool {
        switch self {
        case .idle, .ready, .dead: return true
        case .opening, .inFlight, .quarantined: return false
        }
    }
}

/// Política de fase do transporte: nesta célula só discovery/consultas —
/// nenhum SET de configuração passa pela porta, e a família de parse segue
/// não resolvida (RE P1-1c): nada daqui habilita escrita nem "confirmação".
package enum K86PhasePolicy {
    /// Comandos de consulta de descoberta (payload do K86Codec, provado por
    /// offset na classe K de `438d24dc.js`).
    package static let discoveryQueryCommands: Set<UInt8> = [
        0x80, // GET_REV
        0x85, // GET_PROFILE
        0x91, // GET_DEBOUNCE
        0x97, // GET_AUTOOSEN
        0x86, // GET_KBOPTION
        0x89, // GET_KEYMATRIX (leitura)
    ]
    package static func isDiscoveryQuery(_ command: UInt8) -> Bool {
        discoveryQueryCommands.contains(command)
    }
}
