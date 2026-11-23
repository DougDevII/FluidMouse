import XCTest
@testable import FluidMouseCore

/// Seleção de dispositivo: 1:6 (teclado) e 0x0C:1 (consumer) são REJEITADOS;
/// 0xFFFF:0x0002 com o descritor REAL do líder (hex capturado no IORegistry
/// deste Mac, 2026-11-04) é ACEITO com gating por parse completo, nunca
/// substring sozinha. O descritor prova feature unnumbered (sem item `85 xx`)
/// e 64 bytes — não é inferência de MaxFeature=64.
final class K86FingerprintTests: XCTestCase {

    /// Hex REAL do líder: 06 FF FF 09 02 A1 01 09 02 15 80 25 7F 95 40 75 08 B1 02 C0
    private let leaderDescriptor: [UInt8] = [
        0x06, 0xFF, 0xFF, 0x09, 0x02, 0xA1, 0x01, 0x09, 0x02,
        0x15, 0x80, 0x25, 0x7F, 0x95, 0x40, 0x75, 0x08, 0xB1, 0x02, 0xC0,
    ]

    func testElementosTeclado1_6SaoRecusados() {
        XCTAssertFalse(K86Fingerprint.hasConfigCollection(elements: [
            .init(usagePage: 0x01, usage: 0x06, type: 513),
        ]))
    }

    func testElementosConsumer0C_1SaoRecusados() {
        XCTAssertFalse(K86Fingerprint.hasConfigCollection(elements: [
            .init(usagePage: 0x0C, usage: 0x01, type: 513), // consumer
        ]))
    }

    func testColecaoFFFF_2ComElementosTipoColecaoEAceito() {
        XCTAssertTrue(K86Fingerprint.hasConfigCollection(elements: [
            .init(usagePage: 0x01, usage: 0x06, type: 513),
            .init(usagePage: 0xFFFF, usage: 0x0002, type: 513), // coleção de configuração
        ]))
    }

    func testParseCompletoDoDescritorRealCasaComAReferencia() {
        let facts = K86Fingerprint.descriptorFacts(leaderDescriptor)
        XCTAssertEqual(facts, K86Fingerprint.referenceDescriptorFacts)
        XCTAssertEqual(facts?.usagePage, 0xFFFF)
        XCTAssertEqual(facts?.usage, 0x0002)
        XCTAssertEqual(facts?.featureReportCount, 64)
        XCTAssertEqual(facts?.featureReportSize, 8)
        XCTAssertEqual(facts?.featureByteCount, 64)
        XCTAssertEqual(facts?.usesReportIDItem, false)
        XCTAssertEqual(facts?.unnumberedFeature, true, "sem item 85 ⇒ reportID 0 no parâmetro")
    }

    func testDescritorComItemReportID85NaoEUnnumberedEERejeitado() {
        var perturbed = [UInt8]()
        perturbed += [0x06, 0xFF, 0xFF]
        perturbed += [0x09, 0x02, 0xA1, 0x01]
        perturbed += [0x85, 0x01] // Report ID item presente (msmescopo do feature) ⇒ numerado
        perturbed += [0x09, 0x02, 0x15, 0x80, 0x25, 0x7F, 0x95, 0x40, 0x75, 0x08, 0xB1, 0x02, 0xC0]
        // Estrito: Report ID em qualquer escopo ⇒ sem fatos (nunca candidato).
        XCTAssertNil(K86Fingerprint.descriptorFacts(perturbed))
    }

    func testDescritorComContagemTamanhoDiferentesRejeitado() {
        var shortCount = leaderDescriptor
        shortCount[14] = 0x20 // 95 40 → 95 20 (count 32; índice do byte de dados)
        var facts = K86Fingerprint.descriptorFacts(shortCount)
        XCTAssertEqual(facts?.featureReportCount, 32)
        XCTAssertNotEqual(facts, K86Fingerprint.referenceDescriptorFacts)

        var biggerSize = leaderDescriptor
        biggerSize[biggerSize.count - 4] = 0x80 // 75 08 → 75 80 (size 128)
        facts = K86Fingerprint.descriptorFacts(biggerSize)
        XCTAssertEqual(facts?.featureReportSize, 128)
        XCTAssertNotEqual(facts, K86Fingerprint.referenceDescriptorFacts)
    }

    func testDescritorSemColecaoFechadaRetornaNil() {
        XCTAssertNil(K86Fingerprint.descriptorFacts([]))
        XCTAssertNil(K86Fingerprint.descriptorFacts([0x06, 0xFF]))
        XCTAssertNil(K86Fingerprint.descriptorFacts([0x09, 0x02, 0xA1, 0x01, 0xB1, 0x02]))
    }

    // MARK: Estreatividade da discovery de descritor (zero falso positivo)

    func testDescritorComColecaoPrefixadaAntesDoAlvoENaoReferencia() {
        // Uma collection válida de teclado (1:6) ANTES da coleção alvo ⇒
        // mais de uma top-level ⇒ recusa (nunca substring sozinha).
        var comPrefixo = [UInt8]()
        comPrefixo += [0x05, 0x01, 0x09, 0x06, 0xA1, 0x01, 0x95, 0x01, 0x75, 0x08,
                       0x81, 0x02, 0xC0] // teclado fecheado
        comPrefixo += leaderDescriptor
        XCTAssertNil(K86Fingerprint.descriptorFacts(comPrefixo),
                     "prefixo com outra collection ⇒ NÃO é candidato")
    }

    func testDescritorComReportIDGlobalNãoEunnumbered() {
        var numerado = [UInt8]()
        numerado += [0x85, 0x01] // Report ID global ANTES da collection
        numerado += leaderDescriptor
        XCTAssertNil(K86Fingerprint.descriptorFacts(numerado),
                     "Report ID em qualquer escopo ⇒ unnumbered provado não-existe")
    }

    func testDescritorComNestedCollectionNãoEReferência() {
        // Coleção alvo contendo UMA collection aninhada ⇒ nil (a referência não tem).
        var nested = [UInt8]()
        nested += [0x06, 0xFF, 0xFF, 0x09, 0x02, 0xA1, 0x01]
        nested += [0x09, 0x0A, 0xA1, 0x02, 0x95, 0x01, 0x75, 0x08, 0x81, 0x02, 0xC0]
        nested += [0x09, 0x02, 0x15, 0x80, 0x25, 0x7F, 0x95, 0x40, 0x75, 0x08, 0xB1, 0x02, 0xC0]
        XCTAssertNil(K86Fingerprint.descriptorFacts(nested),
                     "collection aninhada dentro do alvo ⇒ não é referência")
    }

    func testDescritorTruncadoEFinalComLixoNãoPassam() {
        // EOF sem fechar collection ⇒ truncado
        var truncado = leaderDescriptor
        truncado.removeLast() // sem C0
        XCTAssertNil(K86Fingerprint.descriptorFacts(truncado))
        // dados após C0 final
        var comLixo = leaderDescriptor
        comLixo.append(0x06) // item solto depois
        comLixo.append(0xFF)
        XCTAssertNil(K86Fingerprint.descriptorFacts(comLixo))
    }

    func testPushPopNãoÉReferência() {
        var comPush = [UInt8]()
        comPush += [0xA4] // Push
        comPush += leaderDescriptor
        comPush.append(0xB4) // Pop
        XCTAssertNil(K86Fingerprint.descriptorFacts(comPush),
                     "Push/Pop na estrutura de referência ⇒ recusado")
    }

    // MARK: constante real do tipo de elemento (prova por header)

    func testelementosComTipoRealSDK() {
        // IOHIDDeviceTypes.h (SDK): kIOHIDElementTypeCollection = 513; Feature = 257.
        XCTAssertEqual(K86Fingerprint.collectionElementRawValue, 513)
        // Input_Axis (3) NÃO qualifica como coleção.
        XCTAssertFalse(K86Fingerprint.hasConfigCollection(elements: [
            .init(usagePage: 0xFFFF, usage: 0x0002, type: 3),
        ]))
    }

    // MARK: Gate do GET_REV físico (P1-1c)

    func testGateGETRevFisicoFicaFechadoEnquantoCandidatasDivergem() {
        // 438d24dc K/H: cmd 128 (@2742), parse t[2]<<8|t[1] (@2762).
        // 5e635fe2 C: cmd 143 (@2207), parse e[8]<<8|e[7] (@3211).
        XCTAssertFalse(K86GetRevProbeGate.sameCommandNumber, "128 ≠ 143")
        XCTAssertFalse(K86GetRevProbeGate.sameResponseLayout, "[2]:[1] ≠ [8]:[7]")
        XCTAssertFalse(K86GetRevProbeGate.requestAndExpectedFormatIdentical,
                       "consulta física fica PENDENTE até o RE entregar o a5d33148.js")
    }
}
