import XCTest
@testable import FluidMouseCore

/// Testes de ENVELOPE de produção do transporte K86: executor serial com
/// fakes injetáveis — timeout com fake bloqueado (segunda I/O recusada até
/// soltar a primeira), disconnect/reconnect + callback antigo, `close` não
/// ocorre antes da I/O terminar, conclusão única, erro real não vira zero.
final class K86HIDExchangeTests: XCTestCase {

    /// Holder Sendable para resultados que chegam do executor (threads).
    final class Box<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var item: T?
        func set(_ v: T) { lock.lock(); item = v; lock.unlock() }
        func get() -> T? { lock.lock(); defer { lock.unlock() }; return item }
    }

    final class ListBox<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [T] = []
        func append(_ v: T) { lock.lock(); items.append(v); lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return items.count }
        var first: T? { lock.lock(); defer { lock.unlock() }; return items.first }
    }

    // MARK: Fake link (porta K86HIDLink roteirizada)

    final class FakeK86Link: K86HIDLink, @unchecked Sendable {
        let properties: K86LinkProperties
        private let lock = NSLock()
        private(set) var log: [String] = []
        private(set) var setPayloads: [[UInt8]] = []
        private(set) var getFeaturesCount = 0

        enum Step: Sendable {
            case respond([UInt8])
            case fail(Int32)
            case block(gate: DispatchSemaphore)
        }

        private var steps: [Step] = []
        private var stepIndex = 0
        let responseGate = DispatchSemaphore(value: 0) // testes liberam a leitura travada

        init(descriptor: [UInt8]? = nil, registryEntryID: Int = 4294982852) {
            self.properties = K86LinkProperties(
                vendorID: 12625, productID: 16405, locationID: 18022400,
                maxFeatureReportSize: 64, reportDescriptor: descriptor,
                registryEntryID: registryEntryID)
        }
        /// `open()` bloqueável (rev. 3: testes de detach durante open).
        var openGate: DispatchSemaphore?

        func script(_ steps: [Step]) { lock.lock(); self.steps = steps; self.stepIndex = 0; lock.unlock() }

        func open() -> Bool {
            if let openGate {
                openGate.wait() // simula open() bloqueado dentro do IOKit
            }
            lock.lock(); defer { lock.unlock() }
            log.append("open"); return true
        }
        func close() {
            lock.lock(); defer { lock.unlock() }
            log.append("close")
        }
        func setFeature(reportID: Int, payload: [UInt8]) throws {
            lock.lock(); log.append("set(\(reportID))"); setPayloads.append(payload); lock.unlock()
        }
        func getFeature(reportID: Int, byteCount: Int) throws -> [UInt8] {
            defer {
                lock.lock(); getFeaturesCount += 1; lock.unlock()
            }
            lock.lock()
            let index = stepIndex
            stepIndex += 1
            log.append("get(\(reportID))")
            let step = index < steps.count ? steps[index] : Step.respond([UInt8](repeating: 0, count: byteCount))
            lock.unlock()
            switch step {
            case .respond(let bytes): return bytes
            case .fail(let code): throw K86ReportError.reportFailed(code: code)
            case .block(let gate):
                gate.wait() // bloqueia o worker REAL (nada é cancelado)
                lock.lock()
                let nextIndex = stepIndex
                stepIndex += 1
                log.append("released")
                let next = nextIndex < steps.count ? nextIndex : -1
                lock.unlock()
                if next >= 0, case .respond(let bytes) = steps[next] { return bytes }
                return [UInt8](repeating: 0x55, count: byteCount)
            }
        }
    }

    func makeExecutor() -> K86HIDExchange { K86HIDExchange(label: "test.k86.executor") }

    func eventually(timeout: TimeInterval = 3.0,
                    file: StaticString = #filePath, line: UInt = #line,
                    _ condition: @autoclosure @escaping () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTFail("condição não ocorreu em \(timeout)s", file: file, line: line)
    }

    // MARK: Attach / geração

    func testAttachAbreSessaoEGeracaoSobe() {
        let executor = makeExecutor()
        let link = FakeK86Link()
        let done = expectation(description: "attach")
        executor.attach(link: link, completion: { result in
            guard case .success = result else {
                XCTFail("attach deveria abrir")
                return
            }
            done.fulfill()
        })
        wait(for: [done], timeout: 2)
        XCTAssertTrue(link.log.contains("open"))
        guard case .ready(let gen) = executor.stateSnapshot() else {
            XCTFail("estado ready esperado")
            return
        }
        XCTAssertEqual(gen, 1)
    }

    /// Regressão FUNCIONAL do gate de attach (não vazio): attach submetido
    /// durante I/O bloqueado é RECUSADO na hora e sua intenção NÃO é
    /// reaplicada quando a operação termina.
    func testAttachDuranteIOBloqueadoRecusaENaoReaplicaIntencaoAntiga() {
        let executor = makeExecutor()
        let link1 = FakeK86Link()
        let attach1 = expectation(description: "attach 1")
        executor.attach(link: link1, completion: { _ in attach1.fulfill() })
        wait(for: [attach1], timeout: 2)

        link1.script([.block(gate: link1.responseGate)])
        let accepted = expectation(description: "aceite op")
        executor.exchange(frame: [0x80] + [UInt8](repeating: 0, count: 63),
                          readDelayMs: 10, deadlineMs: 3000,
                          onAccepted: { _ in accepted.fulfill() },
                          completion: { _ in })
        wait(for: [accepted], timeout: 2)

        // Attach durante inFlight: recusado IMEDIATAMENTE, sem tocar device.
        let link2 = FakeK86Link()
        let attachResult = Box<Result<K86LinkProperties, K86HIDExchange.K86IOError>>()
        let attachDone = expectation(description: "attach recusado")
        executor.attach(link: link2, completion: { result in
            attachResult.set(result)
            attachDone.fulfill()
        })
        wait(for: [attachDone], timeout: 2)
        guard case .failure(.rejected(.operationInFlight)) = attachResult.get() else {
            XCTFail("esperava rejected(operationInFlight); veio: \(String(describing: attachResult.get()))")
            return
        }
        XCTAssertFalse(link2.log.contains("open"), "device NUNCA tocado antes da recusa")

        // Solta o worker → op completa normalmente (resposta chega) → sessão
        // volta a ready. A intenção do attach recusado NÃO é reaplicada:
        // nenhum open automático aparece no link2.
        link1.responseGate.signal()
        eventually(executor.stateSnapshot() == .ready(generation: 1))
        eventually(!link2.log.contains("open"))
    }

    /// Corrida determinística (FILA CONTROLADA): attach B ENFILEIRADO e
    /// exchange submetido em A — o exchange vinculado à geração da SUBMISSÃO
    /// nunca envia no device novo. O executor é PAUSADO até as duas submissões
    /// estarem na fila.
    func testExchangeSubmetidoEmANuncaEnviaNoDeviceNovoB() {
        let executor = makeExecutor()
        let linkA = FakeK86Link()
        linkA.script([.respond([UInt8](repeating: 0x42, count: 64))])
        let attachA = expectation(description: "attach A")
        executor.attach(link: linkA, completion: { _ in attachA.fulfill() })
        wait(for: [attachA], timeout: 2)
        XCTAssertEqual(executor.stateSnapshot(), .ready(generation: 1))

        // PAUSA a fila do executor (barreira travada) — submissões FIFO vêm atrás.
        let pauseGate = DispatchSemaphore(value: 0)
        let pauseEntered = expectation(description: "pausa do executor")
        executor.queue.async {
            pauseEntered.fulfill()
            pauseGate.wait()
        }
        wait(for: [pauseEntered], timeout: 2)

        // ORDEM das submissões (thread única, fila travada): attach B, depois exchange.
        let linkB = FakeK86Link()
        let attachBOutcome = Box<Result<K86LinkProperties, K86HIDExchange.K86IOError>>()
        let attachBDone = expectation(description: "attach B executor")
        executor.attach(link: linkB, completion: { result in
            attachBOutcome.set(result)
            attachBDone.fulfill()
        })

        let exchangeOutcome = Box<Result<[UInt8], K86HIDExchange.K86IOError>>()
        let exchangeDone = expectation(description: "exchange recusado")
        let acceptedRef = Box<Bool>()
        executor.exchange(frame: [0x80] + [UInt8](repeating: 0, count: 63),
                          readDelayMs: 10, deadlineMs: 300,
                          onAccepted: { _ in acceptedRef.set(true) },
                          completion: { result in
                              exchangeOutcome.set(result)
                              exchangeDone.fulfill()
                          })
        pauseGate.signal() // libera: attachB executa primeiro (FIFO), depois o gate

        wait(for: [attachBDone, exchangeDone], timeout: 4)
        // attachB swap: fecha A, abre B (gen 2). O exchange de A, vinculado à
        // geração da SUBMISSÃO (gen 1), é recusado SEM tocar B.
        guard case .success = attachBOutcome.get() else {
            XCTFail("attach B executa primeiro (FIFO)")
            return
        }
        XCTAssertTrue(linkB.log.contains("open"))
        XCTAssertFalse(acceptedRef.get() ?? false)
        guard case .failure(.rejected(.dead)) = exchangeOutcome.get() else {
            XCTFail("exchange de A recusado (sessão mudou); veio \(String(describing: exchangeOutcome.get()))")
            return
        }
        XCTAssertEqual(linkA.setPayloads.count, 0, "exchange de A nunca envia no B")
        XCTAssertEqual(linkB.setPayloads.count, 0)
    }

    /// Ready-detach invalida IMEDIATAMENTE: exchange submetido logo após o
    /// detach (antes mesmo do close de limpeza rodar) é recusado na submissão.
    /// Ready-detach invalida IMEDIATAMENTE: exchange submetido logo após o
    /// detach (antes mesmo do close de limpeza rodar) é recusado na submissão.
    func testDetachReadyImediatoRecusaExchangeNovo() {
        let executor = makeExecutor()
        let link = FakeK86Link()
        let attachDone = expectation(description: "attach")
        executor.attach(link: link, completion: { _ in attachDone.fulfill() })
        wait(for: [attachDone], timeout: 2)

        executor.detach(reason: "remoção do sistema")
        guard case .dead = executor.stateSnapshot() else {
            XCTFail("detach ready deve virar DEAD IMEDIATAMENTE (sem agendar)")
            return
        }
        let rejected = Box<Bool>()
        executor.exchange(frame: [0x80] + [UInt8](repeating: 0, count: 63),
                          deadlineMs: 500,
                          onAccepted: { _ in XCTFail("não aceita falar com sessão morta") },
                          completion: { result in
                              if case .failure = result { rejected.set(true) }
                          })
        executor.queue.sync {} // nada da fila é necessário: recusa foi na submissão
        XCTAssertTrue(rejected.get() ?? false, "exchange pós-detach recusado antes de tocar o device")
    }

    // MARK: Timeout — segunda I/O recusada, close só depois do worker real

    func testTimeoutComFakeTravadoRecusaSegundaIOTerminaEFechaSoDepois() {
        let executor = makeExecutor()
        let link = FakeK86Link()
        let attachDone = expectation(description: "attach")
        executor.attach(link: link, completion: { _ in attachDone.fulfill() })
        wait(for: [attachDone], timeout: 2)

        // getFeature do worker VAI TRAVAR no gate — liberação manual depois.
        link.script([.block(gate: link.responseGate)])

        let completions = ListBox<Result<[UInt8], K86HIDExchange.K86IOError>>()
        let timedOut = expectation(description: "timeout entregue 1x")
        let accepted = expectation(description: "aceite")
        executor.exchange(frame: [0x80] + [UInt8](repeating: 0, count: 63),
                          readDelayMs: 10, deadlineMs: 40,
                          onAccepted: { envelope in
                              XCTAssertEqual(envelope.generation, 1)
                              accepted.fulfill()
                          },
                          completion: { result in
                              completions.append(result)
                              timedOut.fulfill()
                          })
        wait(for: [accepted, timedOut], timeout: 3)
        XCTAssertEqual(completions.count, 1, "conclusão única")
        guard case .failure(let error) = completions.first else {
            XCTFail("timeout esperado")
            return
        }
        guard case .timeout(let ms) = error else {
            XCTFail("erro PRÓPRIO de timeout, não kIOReturnError; veio: \(error)")
            return
        }
        XCTAssertEqual(ms, 40)

        // Quarentina: segunda I/O é RECUSADA antes de tocar o device.
        let secondData = expectation(description: "segunda recusada")
        executor.exchange(frame: [0x80] + [UInt8](repeating: 0, count: 63),
                          deadlineMs: 200,
                          onAccepted: { _ in XCTFail("não deveria aceitar I/O") },
                          completion: { result in
                              if case .failure(.rejected(.quarantined)) = result {
                                  secondData.fulfill()
                              }
                          })
        wait(for: [secondData], timeout: 2)
        XCTAssertEqual(link.setPayloads.count, 1, "recusada ANTES de qualquer I/O")

        // O worker real ainda em voo: close NÃO ocorreu.
        XCTAssertFalse(link.log.contains("close"))

        // Solta o worker: ele termina → close → dead → novo attach possível.
        link.responseGate.signal()
        eventually(executor.stateSnapshot() == .dead(generation: 1, reason: "resolvida: timeout 40 ms"))
        XCTAssertTrue(link.log.contains("close"), "close SÓ depois do worker real terminar")
        let callLog = link.log
        if let getIndex = callLog.firstIndex(where: { $0 == "get(0)" }),
           let closeIndex = callLog.firstIndex(where: { $0 == "close" }) {
            XCTAssertLessThan(getIndex, closeIndex, "close jamais antes da I/O em voo")
        } else {
            XCTFail("ordem get→close esperada")
        }

        // Reconnect após dead: nova geração, nada da sessão antiga.
        let link2 = FakeK86Link()
        let attach2 = expectation(description: "attach 2")
        executor.attach(link: link2, completion: { _ in attach2.fulfill() })
        wait(for: [attach2], timeout: 2)
        XCTAssertEqual(link2.log.contains("open"), true)
        guard case .ready(let gen2) = executor.stateSnapshot() else {
            XCTFail("nova sessão ready esperada")
            return
        }
        XCTAssertEqual(gen2, 2, "geração avança no novo vínculo")
    }

    // MARK: Disconnect durante I/O + callback antigo

    func testDisconnectEmVooEntregaUmaVezDescartaTardioEFechaSoDepois() {
        let executor = makeExecutor()
        let link = FakeK86Link()
        let attachDone = expectation(description: "attach")
        executor.attach(link: link, completion: { _ in attachDone.fulfill() })
        wait(for: [attachDone], timeout: 2)

        let lost = expectation(description: "sessionEnded entregue única")
        let acceptedEval = expectation(description: "aceite")
        let completionCount = Box<Int>()
        executor.exchange(frame: [0x80] + [UInt8](repeating: 0, count: 63),
                          readDelayMs: 10, deadlineMs: 5000,
                          onAccepted: { _ in acceptedEval.fulfill() },
                          completion: { result in
                              completionCount.set((completionCount.get() ?? 0) + 1)
                              if case .failure(.sessionEnded("disconnect: remoção do device")) = result {
                                  lost.fulfill()
                              }
                          })
        wait(for: [acceptedEval], timeout: 2)
        executor.detach(reason: "remoção do device")
        wait(for: [lost], timeout: 3)
        XCTAssertEqual(completionCount.get(), 1, "conclusão única, callback tardio não redelivera")

        // Callback antigo (segundo detach) não muda estado da sessão antiga.
        executor.detach(reason: "disconnect duplicado")
        guard case .quarantined(let gen, let token, _) = executor.stateSnapshot(),
              gen == 1, token == 1 else {
            XCTFail("quarentina persiste até o worker real terminar; mesmo detach duplicado não muda a sessão antiga")
            return
        }
        link.responseGate.signal()
        eventually(executor.stateSnapshot() == .dead(generation: 1, reason: "resolvida: disconnect: remoção do device"))
        XCTAssertTrue(link.log.contains("close"), "close somente após worker terminar")
        XCTAssertEqual(completionCount.get(), 1)
    }

    /// Regressão do rev.3 ponto 1 (fila suspensa): attach B enfileirado ANTES
    /// do detach → detach → liberar; A é fechado EXATAMENTE 1× (victim
    /// capturado, incondicional, não `self.link`) e a intenção ANTIGA de B é
    /// recusada pelo epoch (detach avança em idle/dead também).
    func testAttachEnfileiradoAntesDoDetachClose1xIntentoRecusada() {
        let executor = makeExecutor()
        let linkA = FakeK86Link()
        let attachA = expectation(description: "attach A")
        executor.attach(link: linkA, completion: { _ in attachA.fulfill() })
        wait(for: [attachA], timeout: 2)

        // PAUSA a fila do executor.
        let pauseGate = DispatchSemaphore(value: 0)
        let pauseEntered = expectation(description: "pausado")
        executor.queue.async {
            pauseEntered.fulfill()
            pauseGate.wait()
        }
        wait(for: [pauseEntered], timeout: 2)

        // Submissões na fila (nesta ordem): attach B, depois detach.
        let linkB = FakeK86Link()
        let attachBOutcome = Box<Result<K86LinkProperties, K86HIDExchange.K86IOError>>()
        let attachBDone = expectation(description: "attach B gate")
        executor.attach(link: linkB, completion: { result in
            attachBOutcome.set(result)
            attachBDone.fulfill()
        })
        executor.detach(reason: "stop do sistema")

        pauseGate.signal()
        wait(for: [attachBDone], timeout: 3)
        // attachGate: dead com epoch AVANÇADO pelo detach ⇒ intenção antiga RECUSADA.
        guard case .failure(.rejected(.dead)) = attachBOutcome.get() else {
            XCTFail("intenção de attach enfileirada é recusada pelo epoch; veio \(String(describing: attachBOutcome.get()))")
            return
        }
        // A: fechado EXATAMENTE 1× (victim capturado, mesmo com attachB já recusado).
        // (o close roda no item de fila seguinte ao gate: espera ser processado)
        eventually(linkA.log.filter { $0 == "close" }.count == 1)
        XCTAssertFalse(linkB.log.contains("open"), "device B nunca tocado pela intenção antiga")
        eventually(executor.stateSnapshot() == .dead(generation: 1, reason: "disconnect: stop do sistema"))
    }

    /// Rev.3 ponto 2: `ready` não é publicado antes de link.open terminar —
    /// detach DURANTE open ⇒ open que retornar completa FALHA, device fechado
    /// exatamente 1×, sem bound morto.
    func testOpenBloqueadoDetachDuranteOpeningCompletaFalhaUmaVez() {
        let executor = makeExecutor()
        let link = FakeK86Link()
        let openGate = DispatchSemaphore(value: 0)
        link.openGate = openGate

        let attachOutcome = Box<Result<K86LinkProperties, K86HIDExchange.K86IOError>>()
        let attachDone = expectation(description: "attach com open bloqueado")
        executor.attach(link: link, completion: { result in
            attachOutcome.set(result)
            attachDone.fulfill()
        })
        eventually(executor.stateSnapshot() == .opening(generation: 1))
        executor.detach(reason: "stop durante open") // invalida epoch + reserva victim
        openGate.signal()
        wait(for: [attachDone], timeout: 3)
        // open que retornou revalidou epoch ⇒ FALHA (nada publicado como attached).
        guard case .failure = attachOutcome.get() else {
            XCTFail("attach com detach-no-opening devia completar falha; veio \(String(describing: attachOutcome.get()))")
            return
        }
        eventually(executor.stateSnapshot() == .dead(generation: 1, reason: "disconnect durante open: stop durante open"))
        XCTAssertEqual(link.log.filter { $0 == "close" }.count, 1,
                       "device do attach cancelado fechado EXATAMENTE 1× (victim)")
    }

    // MARK: Erro real propaga; curtos/zeros não viram valor favorável

    func testErroRealIOReturnPropagaComoVem() {
        let executor = makeExecutor()
        let link = FakeK86Link()
        let attachDone = expectation(description: "attach")
        executor.attach(link: link, completion: { _ in attachDone.fulfill() })
        wait(for: [attachDone], timeout: 2)

        link.script([.fail(Int32(bitPattern: 0xE00002C7))]) // código REAL do fake, não kIOReturnError
        let done = expectation(description: "erro real")
        executor.exchange(frame: [0x80] + [UInt8](repeating: 0, count: 63),
                          readDelayMs: 10, deadlineMs: 1000,
                          onAccepted: { _ in },
                          completion: { result in
                              guard case .failure(.ioFailure(let code)) = result else {
                                  XCTFail("ioFailure com código real esperado; veio \(result)")
                                  return
                              }
                              XCTAssertEqual(code, Int32(bitPattern: 0xE00002C7), "IOReturn genuíno propagado")
                              done.fulfill()
                          })
        wait(for: [done], timeout: 3)
    }

    func testRespostaCurtaEAllZerosPassamCrusSemSucessoNenhum() {
        let executor = makeExecutor()
        let link = FakeK86Link()
        let attachDone = expectation(description: "attach")
        executor.attach(link: link, completion: { _ in attachDone.fulfill() })
        wait(for: [attachDone], timeout: 2)

        // curto: 1 byte — entrega cru, SEM preenchimento por zero
        link.script([.respond([0x80])])
        let outcome1 = Box<Result<[UInt8], K86HIDExchange.K86IOError>>()
        let done1 = expectation(description: "curto")
        executor.exchange(frame: [0x80] + [UInt8](repeating: 0, count: 63),
                          readDelayMs: 10, deadlineMs: 1000,
                          onAccepted: { _ in },
                          completion: { result in
                              outcome1.set(result)
                              done1.fulfill()
                          })
        wait(for: [done1], timeout: 3)
        XCTAssertEqual(try? outcome1.get()?.get(), [0x80], "bytes crus voltam; nada é preenchido")

        // all-zeros: volta cru — NÃO é confirmação em nenhum caminho daqui
        link.script([.respond([UInt8](repeating: 0, count: 64))])
        let done2 = expectation(description: "zeros")
        let outcome2 = Box<Result<[UInt8], K86HIDExchange.K86IOError>>()
        executor.exchange(frame: [0x80] + [UInt8](repeating: 0, count: 63),
                          readDelayMs: 10, deadlineMs: 1000,
                          onAccepted: { _ in },
                          completion: { result in
                              outcome2.set(result)
                              done2.fulfill()
                          })
        wait(for: [done2], timeout: 3)
        XCTAssertEqual(try? outcome2.get()?.get(), [UInt8](repeating: 0, count: 64))

        // parser do codec NÃO trata zeros/curtos como sucesso:
        XCTAssertThrowsError(try K86Responses.parseProfile([UInt8](repeating: 0, count: 1)))
    }

    // MARK: Frame exato passa sem reencodar (produção)

    func testFramePassaInteiroSemPrefixoEComReportID0NoParametro() {
        let executor = makeExecutor()
        let link = FakeK86Link()
        let attachDone = expectation(description: "attach")
        executor.attach(link: link, completion: { _ in attachDone.fulfill() })
        wait(for: [attachDone], timeout: 2)

        let expected = try! K86Codec.encode(message: try! K86Messages.getRev(), checksum: .bit7)
        XCTAssertEqual(expected.count, 64)
        XCTAssertEqual(expected[0], 0x80)
        XCTAssertEqual(expected[7], 0x7F) // checksum Bit7 certificado no golden de codec
        link.script([.respond([UInt8](repeating: 0x42, count: 64))])
        let done = expectation(description: "round")
        executor.exchange(frame: expected, readDelayMs: 10, deadlineMs: 1000,
                          onAccepted: { _ in },
                          completion: { _ in done.fulfill() })
        wait(for: [done], timeout: 3)
        XCTAssertEqual(link.setPayloads.first, expected, "frame cru, sem prefixo de 65 bytes")
    }
}
