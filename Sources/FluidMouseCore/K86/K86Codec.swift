/// Protocolo FEA do teclado Attack Shark K86 — família teclado (`chunks-renderer/438d24dc.js`).
///
/// Evidência por construto/parte (fonte read-only, hashes em `.mece/k86/SOURCE_SHA256.txt`):
/// - Feature report de 64 bytes, report ID 0 fora do payload: WebHID `sendFeatureReport(0, …)`
///   com `FEATURE_REPORT_SIZE = 64` (relatório RE §3.1/§8); no macOS/IOKit a coleção de
///   configuração (usagePage 0xFFFF, usage 0x0002) expõe `MaxFeatureReportSize = 64`
///   (IORegistry do líder, 2026-11-04), consistente com payload 64 B sem prefixo.
/// - Checksum: `index.b078bf5f.js`, classe `iA.sendFeature` (offset ≈861651):
///   `a[7] = 255 - (soma(a[0..<7]) & 255)` (Bit7), `a[8] = 255 - (soma(a[0..<8]) & 255)` (Bit8);
///   padding mínimo para 8 bytes ANTES do checksum. O byte do checksum é sempre 7 (Bit7) ou 8
///   (Bit8), mesmo em mensagens longas — comportamento observado, sem tratamento especial.
/// - Versão de firmware USB (`getUSBVersion`, 438d24dc.js offset ≈2762, cmd `GET_REV` = 128):
///   resposta com eco `resp[0] == 128`, valor = `resp[2] << 8 | resp[1]`
///   (`return t[2]<<8|t[1]`). Isso é a resposta do próprio teclado — o `0xF1` do relatório
///   RE pertence ao caminho do driver (getIotVersion) e NÃO é usado aqui.
/// - Perfil (`getCurrentProfile`, offset ≈3050, cmd 133): resposta byte 1.
/// - Debounce (`getDeBounce`, offset ≈3406, cmd 145): resposta byte 2; SET (offset ≈3051,
///   cmd 17): `[17, 0, valor]`.
/// - Auto-OS (`setAutoOsen`/`getAutoOsen`, offset ≈20863/21026, cmd 23/151):
///   SET `[23, bool?1:0]`; GET exige eco (`t[0] !== 151` → falha) e retorna `t[1] === 1`.
/// - Opções do teclado (`getKbPowerSaveMode`, offset ≈7146, cmd 134): GET `[134, 0]`,
///   bit 4 = economia de energia (`!!t[4]`).
/// - Leitura de matriz de teclas (`_getKeyMatrix`, offset ≈5410, cmd 137): relatório
///   `[137, camada, seq]` com seq 0...7, 8 leituras de 64 B concatenadas (fixtures opacas,
///   total 512 B; caso a leitura falhe, a fatia vira zeros — comportamento original).
/// - ESCRITA de matriz (`_setKeyConfig`, offset ≈20952, cmd 9): pacote `[9, camada, 0xF8, 0x01,
///   seq] + 56 B`, 9 pacotes (504 B) — SEM encoder nesta célula; semântica dos bytes da
///   matriz não demonstrada (representação opaca de leitura somente).
///
/// Fixtures: todos os valores golden dos testes são *sintéticos*, calculados à mão a partir
/// das fórmulas acima, nunca pela execução do próprio builder (independência de teste).
package enum K86Codec {

    /// Mensagens aceitas: 1...64 bytes (incluindo comando). Não há limites de payload por
    /// comando aqui — quem valida faixas de valor é o builder específico.
    package static let maxMessageLength = 64
    /// Relatório feature completo (bytes), sem o prefixo do report ID.
    package static let fixedReportLength = 64

    /// Constrói a mensagem `[comando, payload...]`.
    package static func buildMessage(command: UInt8, payload: [UInt8]) throws -> [UInt8] {
        guard payload.count <= maxMessageLength - 1 else {
            throw K86CodecError.messageTooLong(length: payload.count + 1, max: maxMessageLength)
        }
        return [command] + payload
    }

    /// Espelha `iA.sendFeature`: pad para ≥ 8, checksum Bit7 no índice 7 / Bit8 no índice 8,
    /// depois pad para 64 com zeros. `Bit7`/`Bit8` sobrescrevem o byte-alvo (índice fixo).
    ///
    /// **Tamanho fixo 64** (correção do líder na revisão da K86-01): não existe parâmetro
    /// de comprimento — o frame FEA do K86 é sempre um feature report de 64 bytes sem
    /// prefixo de report ID no payload (o prefixo é assunto do transporte, K86-02). Se
    /// algum dia um encoder genérico for necessário, será um tipo separado construído
    /// deliberadamente — este aqui não vira “tamanhos variáveis”.
    package static func encode(message input: [UInt8], checksum: K86ChecksumType) throws -> [UInt8] {
        guard !input.isEmpty else { throw K86CodecError.emptyMessage }
        guard input.count <= fixedReportLength else {
            throw K86CodecError.messageTooLong(length: input.count, max: fixedReportLength)
        }
        var report = [UInt8](repeating: 0, count: max(input.count, 8))
        for (i, byte) in input.enumerated() { report[i] = byte }
        switch checksum {
        case .bit7:
            let sum = report[0..<7].reduce(0) { $0 &+ Int($1) }
            report[7] = UInt8(truncatingIfNeeded: 255 &- (sum & 255))
        case .bit8:
            let sum = report[0..<8].reduce(0) { $0 &+ Int($1) }
            if report.count < 9 { report.append(0) }
            report[8] = UInt8(truncatingIfNeeded: 255 &- (sum & 255))
            // O JS cresce o array quando a mensagem tem menos de 9 bytes: o índice 8 só
            // passa a existir depois do checksum. Pós-pad de 64 bytes, o resultado é igual.
        case .none:
            break
        }
        guard report.count <= fixedReportLength else {
            throw K86CodecError.messageTooLong(length: report.count, max: fixedReportLength)
        }
        report.append(contentsOf: [UInt8](repeating: 0, count: fixedReportLength - report.count))
        return report
    }
}

/// Tipos de checksum (`CheckSumType` do proto recuperado: Bit7=0, Bit8=1, None=2).
package enum K86ChecksumType: UInt8, Sendable, CaseIterable {
    case bit7 = 0
    case bit8 = 1
    case none = 2
}

package enum K86CodecError: Error, Equatable, Sendable {
    case emptyMessage
    case messageTooLong(length: Int, max: Int)
    case sequenceOutOfBounds(sequence: Int, max: Int)
    case staleEcho(expected: UInt8, got: UInt8)
    case responseTooShort(minimum: Int, got: Int)
    case keymapSliceCount(count: Int, expected: Int)
    case keymapSliceLength(length: Int, expected: Int)
}

/// Comandos da família teclado com payload/semântica demonstrados. Qualquer comando cuja
/// semântica completa ainda não esteja demonstrada (macros, tela, OTA, bootloader, reset,
/// famílias mouse/Hall) NÃO faz parte deste enum.
package enum K86Command: UInt8, CaseIterable, Sendable {
    /// `GET_REV` (438d24dc.js offset ≈2762): versão USB/protocolo.
    case getRev = 0x80
    /// `SET_PROFILE` (offset ≈2792): `[5, índice]`.
    case setProfile = 0x05
    /// `SET_DEBOUNCE` (offset ≈3051): `[17, 0, valor]`.
    case setDebounce = 0x11
    /// `GET_KBOPTION` para bit de economia de energia (offset ≈7146): `[134, 0]`.
    case getKbOption = 0x86
    /// `GET_PROFILE` (offset ≈3050): resposta byte 1.
    case getProfile = 0x85
    /// `SET_CMD_AUTOOSEN` (offset ≈21057): `[23, 0|1]`.
    case setAutoOsen = 0x17
    /// `GET_CMD_AUTOOSEN` (offset ≈21026): eco exigido, byte 1 == 1.
    case getAutoOsen = 0x97
    /// `GET_KEYMATRIX` (offset ≈5410): `[137, camada, seq]`, 8 leituras.
    case getKeyMatrix = 0x89
    /// `GET_DEBOUNCE` (offset ≈3406): resposta byte 2.
    case getDebounce = 0x91
}

package enum K86Messages {

    /// `getUSBVersion`: mensagem `[128]`.
    package static func getRev() throws -> [UInt8] {
        try K86Codec.buildMessage(command: K86Command.getRev.rawValue, payload: [])
    }

    /// `getCurrentProfile`: mensagem `[133]`.
    package static func getProfile() throws -> [UInt8] {
        try K86Codec.buildMessage(command: K86Command.getProfile.rawValue, payload: [])
    }

    /// `setDeBounce`: mensagem `[17, 0, valor]` (offset 0 demonstrado; faixa de valor
    /// não demonstrada no JS — inicia em 1..10 nos registros/config, default K86 = 10;
    /// aqui aceita 0...255 e o controller decide).
    package static func setDebounce(value: UInt8) throws -> [UInt8] {
        try K86Codec.buildMessage(command: K86Command.setDebounce.rawValue, payload: [0, value])
    }

    /// `getDeBounce`: mensagem `[145]`.
    package static func getDebounce() throws -> [UInt8] {
        try K86Codec.buildMessage(command: K86Command.getDebounce.rawValue, payload: [])
    }

    /// `setCurrentProfile`: mensagem `[5, índice]`. O total de perfis não é demonstrado —
    /// não há constante "4" aqui.
    package static func setProfile(index: UInt8) throws -> [UInt8] {
        try K86Codec.buildMessage(command: K86Command.setProfile.rawValue, payload: [index])
    }

    /// `setAutoOsen`: mensagem `[23, 0|1]`.
    package static func setAutoOsen(enabled: Bool) throws -> [UInt8] {
        try K86Codec.buildMessage(command: K86Command.setAutoOsen.rawValue, payload: [enabled ? 1 : 0])
    }

    /// `getAutoOsen`: mensagem `[151]`.
    package static func getAutoOsen() throws -> [UInt8] {
        try K86Codec.buildMessage(command: K86Command.getAutoOsen.rawValue, payload: [])
    }

    /// `getKbPowerSaveMode`: mensagem `[134, 0]`.
    package static func getKbPowerSaveMode() throws -> [UInt8] {
        try K86Codec.buildMessage(command: K86Command.getKbOption.rawValue, payload: [0])
    }

    /// `_getKeyMatrix`: mensagem `[137, camada, seq]`, seq 0...7 (8 iterações no JS).
    package static func getKeyMatrix(layer: UInt8, sequence: Int) throws -> [UInt8] {
        guard (0...7).contains(sequence) else {
            throw K86CodecError.sequenceOutOfBounds(sequence: sequence, max: 7)
        }
        return try K86Codec.buildMessage(
            command: K86Command.getKeyMatrix.rawValue,
            payload: [layer, UInt8(truncatingIfNeeded: sequence)])
    }
}

package enum K86Responses {

    /// `getUSBVersion`: `t[2]<<8|t[1]` (offset ≈2762). **Este parser NÃO valida eco** — o
    /// JS também não valida (`return t[2]<<8|t[1]` sem checagem de `t[0]`), então valores
    /// de zero ou respostas antigas/outras parseiam como se fossem versão. Isto NÃO é
    /// guarda de sucesso: a CORRELAÇÃO requisição↔resposta (eco `response[0]==128`,
    /// token/geração e nunca reaproveitar leitura anterior) é PRÉ-REQUISITO da camada
    /// de transporte (K86-02), que não pode expor resultado como confirmado sem pareamento real.
    package static func parseRev(_ response: [UInt8]) throws -> UInt16 {
        guard response.count >= 3 else {
            throw K86CodecError.responseTooShort(minimum: 3, got: response.count)
        }
        let high = Int(response[2]), low = Int(response[1])
        return UInt16(truncatingIfNeeded: (high << 8) | low)
    }

    /// `getCurrentProfile`: byte 1 (offset ≈3089). **Sem eco validado aqui** — o JS não
    /// checa `t[0]`; correlação é responsabilidade da camada de transporte (K86-02).
    package static func parseProfile(_ response: [UInt8]) throws -> UInt8 {
        guard response.count >= 2 else {
            throw K86CodecError.responseTooShort(minimum: 2, got: response.count)
        }
        return response[1]
    }

    /// `getDeBounce`: byte 2 (offset ≈3406). **Sem eco validado aqui** (o JS não checa);
    /// correlação é da camada de transporte (K86-02).
    package static func parseDebounce(_ response: [UInt8]) throws -> UInt8 {
        guard response.count >= 3 else {
            throw K86CodecError.responseTooShort(minimum: 3, got: response.count)
        }
        return response[2]
    }

    /// `getAutoOsen`: exige eco (`t[0] !== 151` → sem resposta) e `t[1] === 1`.
    package static func parseAutoOsen(_ response: [UInt8]) throws -> Bool {
        guard response.count >= 2 else {
            throw K86CodecError.responseTooShort(minimum: 2, got: response.count)
        }
        guard response[0] == K86Command.getAutoOsen.rawValue else {
            throw K86CodecError.staleEcho(expected: K86Command.getAutoOsen.rawValue, got: response[0])
        }
        return response[1] == 1
    }

    /// `getKbPowerSaveMode`: `!!t[4]`.
    package static func parseKbPowerSave(_ response: [UInt8]) throws -> Bool {
        guard response.count >= 5 else {
            throw K86CodecError.responseTooShort(minimum: 5, got: response.count)
        }
        return response[4] != 0
    }

    /// `_getKeyMatrix` (offset ≈5410), versão **estrita**: exige as 8 fatias completas de
    /// 64 B. Reproduzir o comportamento original (fatia ausente → zeros) só é permitido na
    /// variante de diagnóstico `assembleKeymapDiagnostics` — nunca aqui: zeros indistinguíveis
    /// de dados válidos não podem ser levados a estado confirmado nem a gravação derivada.
    package static func assembleKeymap(slices: [[UInt8]]) throws -> K86KeymapData {
        guard slices.count == 8 else {
            throw K86CodecError.keymapSliceCount(count: slices.count, expected: 8)
        }
        for slice in slices where slice.count != 64 {
            throw K86CodecError.keymapSliceLength(length: slice.count, expected: 64)
        }
        return try K86KeymapData(slices: slices)
    }

    /// Variante de **diagnóstico** da leitura: fatia vazia = leitura que falhou naquele seq.
    /// Vira zeros **rastreados** (`missingReadIndices`/`isComplete=false`) — o consumo de um
    /// dado incompleto é vedado para estado confirmado ou gravação derivada; serve apenas
    /// para diagnóstico/visualização. Fatias não vazias com tamanho errado continuam rejeitadas.
    package static func assembleKeymapDiagnostics(slices: [[UInt8]]) throws -> K86KeymapData {
        guard slices.count == 8 else {
            throw K86CodecError.keymapSliceCount(count: slices.count, expected: 8)
        }
        var missing: [Int] = []
        var filled: [[UInt8]] = []
        for (index, slice) in slices.enumerated() {
            if slice.isEmpty {
                missing.append(index)
                filled.append([UInt8](repeating: 0, count: 64))
            } else {
                guard slice.count == 64 else {
                    throw K86CodecError.keymapSliceLength(length: slice.count, expected: 64)
                }
                filled.append(slice)
            }
        }
        return try K86KeymapData(slices: filled, missingReadIndices: missing)
    }
}

/// Leitura de matriz opaca: 8 fatias de 64 B, total bruto 512 B exatamente como o original
/// concatena (`[...i,...a]` por iteração). Nenhum byte aqui é interpretado como tecla.
/// O init lança em qualquer forma ≠ 8×64 — não existe caminho que burla a forma.
package struct K86KeymapData: Sendable, Equatable {
    package let slices: [[UInt8]]
    /// Fatias que falharam na leitura e foram preenchidas com zeros (só a variante de
    /// diagnóstico as gera; sempre vazio no resultado estrito).
    package let missingReadIndices: [Int]

    /// Fatias completas e legíveis → `isComplete == true`. Dados incompletos são vedados
    /// a estado confirmado/gravação derivada (regra de célula).
    package var isComplete: Bool { missingReadIndices.isEmpty }

    package init(slices: [[UInt8]], missingReadIndices: [Int] = []) throws {
        guard slices.count == 8 else {
            throw K86CodecError.keymapSliceCount(count: slices.count, expected: 8)
        }
        for slice in slices where slice.count != 64 {
            throw K86CodecError.keymapSliceLength(length: slice.count, expected: 64)
        }
        self.slices = slices
        self.missingReadIndices = missingReadIndices
    }

    package var raw: [UInt8] { slices.flatMap { $0 } }

    package subscript(slice: Int) -> [UInt8] { slices[slice] }
}
