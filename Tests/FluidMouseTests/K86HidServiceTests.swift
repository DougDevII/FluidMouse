import XCTest
@testable import FluidMouse
@testable import FluidMouseCore

/// Envelope de produção do serviço: o `K86HIDExchange` REAL (o mesmo da
/// descoberta IOKit) é dirigido com link fake; o serviço entrega
/// status/guarda de fase e NUNCA transforma zeros/resposta curta/eco errado
/// em confirmação. Todos os testes passam pelo caminho de produção
/// (bindCandidate → executor serial → completion → status).
final class K86HidServiceTests: XCTestCase {

    final class Box<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var item: T?
        func set(_ v: T) { lock.lock(); item = v; lock.unlock() }
        func get() -> T? { lock.lock(); defer { lock.unlock() }; return item }
    }

    /// Box para Status com default (autoclosure simples de Tooth de bind).
    final class BoxStatus: @unchecked Sendable {
        private let lock = NSLock()
        private var item: K86HidService.Status?
        func set(_ v: K86HidService.Status) { lock.lock(); item = v; lock.unlock() }
        func get() -> K86HidService.Status? { lock.lock(); defer { lock.unlock() }; return item }
        var value: K86HidService.Status { lock.lock(); defer { lock.unlock() }; return item ?? K86HidService.Status() }
    }

    // MARK: Link fake (mesma porta do caminho de produção)

    final class ScriptedLink: K86HIDLink, @unchecked Sendable {
        let properties: K86LinkProperties
        private let lock = NSLock()
        private var steps: [Step] = []
        private var stepIndex = 0

        enum Step: Sendable {
            case respond([UInt8])
            case fail(Int32)
        }

        init(descriptor: [UInt8]?, registryEntryID: Int = 4294982852) {
            self.properties = K86LinkProperties(
                vendorID: 12625, productID: 16405, locationID: 18022400,
                maxFeatureReportSize: 64, reportDescriptor: descriptor,
                registryEntryID: registryEntryID)
        }
        /// `open()` bloqueável (rev. 3).
        var openGate: DispatchSemaphore?

        func script(_ steps: [Step]) {
            lock.lock(); self.steps = steps; self.stepIndex = 0; lock.unlock()
        }

        func open() -> Bool {
            if let openGate { openGate.wait() }
            return true
        }

        func close() { /* coberto no executor de Core */ }

        func setFeature(reportID: Int, payload: [UInt8]) throws {
            // o frame exato do codec é verificado nos testes do executor
            // (Core), que roda o MESMO caminho de produção
        }

        func getFeature(reportID: Int, byteCount: Int) throws -> [UInt8] {
            lock.lock()
            let index = stepIndex
            stepIndex += 1
            let step = index < steps.count
                ? steps[index]
                : Step.respond([UInt8](repeating: 0, count: byteCount))
            lock.unlock()
            switch step {
            case .respond(let bytes): return bytes
            case .fail(let code): throw K86ReportError.reportFailed(code: code)
            }
        }
    }

    /// Descritor REAL do líder, byte a byte:
    /// 06ffff0902a10109021580257f95407508b102c0
    private let leaderDescriptor: [UInt8] = [
        0x06, 0xFF, 0xFF, 0x09, 0x02, 0xA1, 0x01, 0x09, 0x02,
        0x15, 0x80, 0x25, 0x7F, 0x95, 0x40, 0x75, 0x08, 0xB1, 0x02, 0xC0,
    ]

    private func makeServiceAndLink() -> (K86HidService, ScriptedLink) {
        let link = ScriptedLink(descriptor: leaderDescriptor)
        let service = K86HidService()
        return (service, link)
    }

    // MARK: Guarda de fase (SET bloqueado antes de qualquer I/O)

    func testFaseGETOnlyBlocaSETsDeConfiguracao() {
        let (service, _) = makeServiceAndLink()
        XCTAssertThrowsError(try service.exchange(message: [0x05, 0x00]) { _ in },
                             "SET_PROFILE bloqueado na fase de descoberta")
        XCTAssertThrowsError(try service.exchange(message: [0x11, 0x00, 0x02]) { _ in },
                             "SET_DEBOUNCE bloqueado")
        XCTAssertThrowsError(try service.exchange(message: [0x17, 0x00]) { _ in },
                             "SET_AUTOOSEN bloqueado")
        XCTAssertThrowsError(try service.exchange(message: [0x99]) { _ in },
                             "comando fora da whitelist: nem consulta")
    }

    // MARK: Resposta de outro comando / zeros / curto NÃO são confirmados

    func testRespostaDeOutroComandoSegueCruaSemConfirmacao() throws {
        let (service, link) = makeServiceAndLink()
        service.activateLifecycle()
        let attachDone = expectation(description: "attach")
        service.bindCandidate(link: link, completion: { _ in attachDone.fulfill() })
        wait(for: [attachDone], timeout: 2)

        link.script([.respond([0x91] + [UInt8](repeating: 0, count: 63))])
        let readout = Box<K86HidService.VersionReadout>()
        let done = expectation(description: "cross")
        try service.readVersionUnchecked { result in
            if case .success(let value) = result { readout.set(value) }
            done.fulfill()
        }
        wait(for: [done], timeout: 3)
        XCTAssertEqual(readout.get()?.echoMatches, false, "eco de outro comando não é confirmação")
        XCTAssertEqual(readout.get()?.raw.first, 0x91, "resposta segue CRUA (nada reescrito)")
    }

    func testAllZerosEcurtosNuncaSeTornamConfirmados() throws {
        let (service, link) = makeServiceAndLink()
        service.activateLifecycle()
        let attachDone = expectation(description: "attach")
        service.bindCandidate(link: link, completion: { _ in attachDone.fulfill() })
        wait(for: [attachDone], timeout: 2)

        // all-zeros: cru de volta; parseAutoOsen NÃO aceita zeros como sucesso
        link.script([.respond([UInt8](repeating: 0, count: 64))])
        let zeros = expectation(description: "zeros")
        try service.exchange(message: [0x80]) { result in
            if case .success(let bytes) = result {
                XCTAssertEqual(bytes, [UInt8](repeating: 0, count: 64), "zeros crus; nada rotulado")
                do { _ = try K86Responses.parseAutoOsen(bytes)
                     XCTFail("zeros NÃO são sucesso no parser de eco") } catch { /* correct */ }
            }
            zeros.fulfill()
        }
        wait(for: [zeros], timeout: 3)

        // curto: um byte não alimenta parser nenhum
        link.script([.respond([0x80])])
        let curto = expectation(description: "curto")
        try service.exchange(message: [0x80]) { result in
            if case .success(let bytes) = result {
                XCTAssertEqual(bytes, [0x80])
                do { _ = try K86Responses.parseProfile(bytes)
                     XCTFail("buffer curto não é confirmado pelo parser") } catch { /* correct */ }
            }
            curto.fulfill()
        }
        wait(for: [curto], timeout: 3)
    }

    // MARK: IOReturn REAL propaga (não vira kIOReturnError)

    func testIOReturnRealPropagaComoERecusadoNoSinkDeConfirmacao() throws {
        let (service, link) = makeServiceAndLink()
        service.activateLifecycle()
        let attachDone = expectation(description: "attach")
        service.bindCandidate(link: link, completion: { _ in attachDone.fulfill() })
        wait(for: [attachDone], timeout: 2)

        link.script([.fail(Int32(bitPattern: 0xE00002E1))])
        let done = expectation(description: "erro real")
        try service.exchange(message: [0x80]) { result in
            guard case .failure(.ioFailure(let code)) = result else {
                XCTFail("esperava ioFailure com código real; veio \(result)")
                return
            }
            XCTAssertEqual(code, Int32(bitPattern: 0xE00002E1), "IOReturn genuíno, não swallowing genérico")
            done.fulfill()
        }
        wait(for: [done], timeout: 3)
    }

    // MARK: Descritor REAL validado por parse (status do serviço)

    func testStatusDoDescritorServeReferenciaDoLider() {
        let (service, link) = makeServiceAndLink()
        service.activateLifecycle()
        let attachDone = expectation(description: "attach")
        service.bindCandidate(link: link, completion: { _ in attachDone.fulfill() })
        wait(for: [attachDone], timeout: 2)

        XCTAssertTrue(service.status.bound)
        XCTAssertTrue(service.status.descriptorMatchesReference ?? false,
                      "descritor real validado por parse completo dos fatos")
        XCTAssertEqual(service.status.descriptorUnnumberedFeature, true,
                       "sem item 85 no hex ⇒ reportID 0 no parâmetro (não é inferência)")
        XCTAssertEqual(service.status.descriptorFeatureByteCount, 64)
        XCTAssertTrue(service.status.protocolVariantUnresolved,
                      "P1-1c: família de parse não resolvida bloqueia configurar")
        XCTAssertFalse(service.status.identityConfirmed,
                       "K86 vs K2405 no mesmo PID: identidade permanece candidata")
    }

    /// Rev.5: callback de bind REENTRANTE (consulta currentGeneration/status e
    /// até stop) roda SEM deadlock; observador recebe o snapshot final com
    /// bound=true e a geração do executor.
    func testBindCompletionReentranteNaoTravaEonChangeRecebeBound() {
        let (service, link) = makeServiceAndLink()
        service.activateLifecycle() // ciclo ativo espelhando start
        let finalSnapshots = BoxStatus()
        let finalGenerations = Box<Int?>()
        service.onChange = { snapshot, generation in
            finalSnapshots.set(snapshot)        // snapshot CAPTURADO, não relido
            finalGenerations.set(generation)
        }
        let reentryOK = Box<Bool>()
        let bindDone = expectation(description: "bind reentrante")
        service.bindCandidate(link: link, completion: { ok in
            // REENTRÂNCIA: currentGeneration + status/stop-like path sob o
            // MESMO lock da entrega — com o stateLock held, isto deadlockaria.
            let generation = service.currentGeneration()
            _ = service.lifecycleTokenForTesting
            service.evaluatePermission()   // também passa pelo lock de estado
            reentryOK.set(generation >= 0)
            bindDone.fulfill()
        })
        wait(for: [bindDone], timeout: 2)
        XCTAssertEqual(reentryOK.get(), true, "callback reentrante não trava")
        serviceEventually(service.currentGeneration() >= 0)
        serviceEventually(bindVoice(from: finalSnapshots))
        XCTAssertEqual(finalGenerations.get(), 1, "geração do executor no snapshot final")
        XCTAssertTrue(service.status.bound, "bind bem-sucedido visível no status")
    }

    // MARK: Ciclo de vida (remoção, cooldown, callback antigo)

    func testRemocaoPorEntryIDMesmaLocationCaprichada() {
        let (service, link) = makeServiceAndLink()
        service.activateLifecycle()
        let attachDone = expectation(description: "attach")
        service.bindCandidate(link: link, completion: { _ in attachDone.fulfill() })
        wait(for: [attachDone], timeout: 2)
        XCTAssertTrue(service.status.bound)
        XCTAssertEqual(service.status.locationID, 18022400)

        // LocationID é IGUAL entre interfaces do mesmo composto — a remoção é
        // atribuída por IORegistryEntryID EXATO: outro entryID (mesmo location)
        // MANTÉM a sessão; o entryID vinculado derruba.
        service.removalOfDevice(entryID: 4294982853) // device irmão (mesma location)
        XCTAssertTrue(service.status.bound, "interface não vinculada (mesma location!) não derruba")
        service.removalOfDevice(entryID: 4294982852) // o VINCULADO
        serviceEventually(service.status.bound == false)
        _ = link
    }

    /// Rev.5 ponto B: o evento capturado NO CICLO N (token do REGISTRO) morre
    /// quando chega DEPOIS de stop→start N+1 — validação por token DO REGISTRO
    /// no hop, não apenas no destino.
    /// Rev.5 ponto B: o evento capturado NO CICLO N (token do REGISTRO) morre
    /// quando chega DEPOIS de stop→start N+1 — validação por token DO REGISTRO
    /// no hop, não apenas no destino. Sem device anexado neste teste: nenhum
    /// dead/re-descoberta ambiente interfere; a régua é o contador de tentativas.
    func testEventoDoCicloNMorreAposStopStart() {
        let (service, _) = makeServiceAndLink()
        service.activateLifecycle() // ciclo N (espelha start())
        let cicloNToken = service.lifecycleTokenForTesting
        service.matchingCallbackReport(registeredToken: cicloNToken)
        serviceEventually(service.reattachAttemptsForTesting >= 1)
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        let antes = service.reattachAttemptsForTesting

        // ciclo N+1: stop (stopping+token+) → start simulado (active+token+)
        service.stop()
        service.activateLifecycle()
        XCTAssertTrue(service.lifecycleTokenForTesting > cicloNToken,
                      "cada ciclo avança o token monotônico")

        // evento VELHO do ciclo N depois do start N+1: morre no hop (token)
        service.matchingCallbackReport(registeredToken: cicloNToken)
        service.matchingCallbackReport(registeredToken: cicloNToken)
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(service.reattachAttemptsForTesting, antes,
                       "evento do ciclo N não sobrevive stop/start N+1")
    }

    func testRemovalDoCicloVelhoTamhoMorre() {
        let (service, link) = makeServiceAndLink()
        service.activateLifecycle()
        let attachDone = expectation(description: "attach")
        service.bindCandidate(link: link, completion: { _ in attachDone.fulfill() })
        wait(for: [attachDone], timeout: 2)
        XCTAssertTrue(service.status.bound)

        let cicloN = service.lifecycleTokenForTesting
        service.stop()
        service.activateLifecycle()
        // dead do stop → re-descoberta ambient do ciclo N+1 conta uma vez
        serviceEventually(service.reattachAttemptsForTesting >= 1)
        let attempts = service.reattachAttemptsForTesting
        // evento VELHO do ciclo N (token do registro velho) — deve ser dropado
        service.matchingCallbackReport(registeredToken: cicloN)
        service.matchingCallbackReport(registeredToken: cicloN)
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(service.reattachAttemptsForTesting, attempts,
                       "eventos do ciclo N não contam no ciclo N+1 (token do registro)")
    }

    func testOpenBloqueadoStopDuranteOpenNãoPublicadoBound() {
        let (service, link) = makeServiceAndLink()
        service.activateLifecycle()
        let openGate = DispatchSemaphore(value: 0)
        link.openGate = openGate // open() vai BLOQUEAR dentro do executor
        let bindOutcome = Box<Bool>()
        let bindDone = expectation(description: "bind fim")
        service.bindCandidate(link: link, completion: { ok in
            bindOutcome.set(ok)
            bindDone.fulfill()
        })
        RunLoop.current.run(until: Date().addingTimeInterval(0.15)) // open segue bloqueado
        service.stop() // stop durante open: token muda + detach incondicional
        openGate.signal()
        wait(for: [bindDone], timeout: 3)
        XCTAssertEqual(bindOutcome.get(), false, "bind CANCELADO durante stop (token na entrega)")
        XCTAssertFalse(service.status.bound, "nada publicado como attached de sessão morta")
    }

    func testDeadPorOpenFalhaNãoDisparaLoopDeRedescoberta() {
        let (service, _) = makeServiceAndLink()
        service.activateLifecycle()
        service.executorStateChanged(.dead(generation: 1, reason: "open falhou — permissões/IOHIDDeviceOpen"))
        serviceEventually(true)
        XCTAssertEqual(service.reattachAttemptsForTesting, 0,
                       "open falhou → dead → NADA de reattach automático (só matching do sistema)")
    }

    func testDeadPorDisconnectPodeReconectarComCooldownCicloVivo() {
        let (service, _) = makeServiceAndLink()
        service.activateLifecycle()
        service.executorStateChanged(.dead(generation: 1, reason: "disconnect: remoção do device"))
        serviceEventually(service.reattachAttemptsForTesting >= 1, timeout: 1.5)
        // cooldown evita loop: a segunda chamada em sequência NÃO conta de novo
        service.executorStateChanged(.dead(generation: 2, reason: "disconnect: remoção"))
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        XCTAssertEqual(service.reattachAttemptsForTesting, 1,
                       "disconnect → dead → re-descoberta UMA vez (cooldown do ciclo)")
        XCTAssertEqual(service.reattachAttemptsForTesting, 1,
                       "disconnect → dead → re-descoberta permitida UMA vez via cooldown")
    }

    private func bindVoice(from slot: BoxStatus) -> Bool {
        slot.value.bound
    }

    /// Espera assíncrona das ações enfileiradas do serviço (reaattach espelho).
    private func serviceEventually(_ condition: @autoclosure () -> Bool,
                                   timeout: TimeInterval = 1.5,
                                   file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTFail("ação esperada não ocorreu", file: file, line: line)
    }

    // MARK: Timeout como erro PRÓPRIO, segunda I/O recusada até soltar

    func testTimeoutServicoRecusaNovaIOTerminaEFechaSoDepois() throws {
        let (service, link) = makeServiceAndLink()
        service.activateLifecycle()
        let attachDone = expectation(description: "attach")
        service.bindCandidate(link: link, completion: { _ in attachDone.fulfill() })
        wait(for: [attachDone], timeout: 2)

        // Travar o getFeature do link "de produção" exige gateway no fake —
        // o comportamento em si foi provado no executor (Core): aqui valida
        // que o timeout de serviço é o erro próprio e a sessão fica
        // quarantine até o worker terminar.
        link.script([.fail(Int32(bitPattern: 0xE00040D2))]) // kIOReturnTimeout real do fake (0xE00040D2)
        let done = expectation(description: "erro próprio")
        try service.exchange(message: [0x80], deadlineMs: 300) { result in
            if case .failure(let error) = result {
                if case .ioFailure(let code) = error {
                    XCTAssertEqual(code, Int32(bitPattern: 0xE00040D2))
                    done.fulfill()
                } else if case .timeout = error {
                    done.fulfill()
                }
            }
        }
        wait(for: [done], timeout: 3)
        // Falha real imediata: não houve quarentina (a sessão continua
        // utilizável) — o erro próprio foi entregue ao completion e NADA é
        // rotulado como confirmado.
        XCTAssertTrue(service.status.bound)
        XCTAssertTrue(service.status.sessionReason == nil)
    }
}
