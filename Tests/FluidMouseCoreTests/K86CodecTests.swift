import XCTest
@testable import FluidMouseCore

/// Golden tests do codec FEA do K86. Os bytes esperados foram calculados A MÃO a partir
/// das fórmulas do JS citadas nos comentários de `K86Codec.swift` — nunca pelo builder.
/// Todas as fixtures são sintéticas: nada aqui vem de captura física de hardware.
final class K86CodecEncodeTests: XCTestCase {

    private func assertFrame(
        _ message: [UInt8], checksum: K86ChecksumType = .bit7,
        equals expected: [UInt8], file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let encoded = try K86Codec.encode(message: message, checksum: checksum)
        XCTAssertEqual(encoded.count, 64, file: file, line: line)
        XCTAssertEqual(encoded, expected, file: file, line: line)
    }

    /// `getRev` = [128]: pad para 8 → [80,00,00,00,00,00,00,00]; soma(bytes 0..6) = 128;
    /// checksum = 255-128 = 127 = 0x7F no índice 7. (iA.sendFeature, index.b078bf5f.js ≈861651)
    func testGetRevGolden() throws {
        try assertFrame(
            [0x80],
            equals: [0x80, 0, 0, 0, 0, 0, 0, 0x7F] + [UInt8](repeating: 0, count: 56))
    }

    /// `getProfile` = [133] (0x85): soma = 133 → checksum = 122 = 0x7A.
    func testGetProfileGolden() throws {
        try assertFrame(
            [0x85],
            equals: [0x85, 0, 0, 0, 0, 0, 0, 0x7A] + [UInt8](repeating: 0, count: 56))
    }

    /// `setDeBounce(10)` = [17,0,10] (0x11,0x00,0x0A): soma(bytes 0..6) = 17+10 = 27 (0x1B)
    /// → checksum = 228 = 0xE4 no índice 7.
    func testSetDebounceGolden() throws {
        try assertFrame(
            [0x11, 0x00, 0x0A],
            equals: [0x11, 0x00, 0x0A, 0, 0, 0, 0, 0xE4] + [UInt8](repeating: 0, count: 56))
    }

    /// `getDeBounce` = [145] (0x91): soma = 145 → checksum = 110 = 0x6E.
    func testGetDebounceGolden() throws {
        try assertFrame(
            [0x91],
            equals: [0x91, 0, 0, 0, 0, 0, 0, 0x6E] + [UInt8](repeating: 0, count: 56))
    }

    /// `setCurrentProfile(1)` = [5,1] (0x05,0x01): soma = 6 → checksum = 249 = 0xF9.
    func testSetProfileGolden() throws {
        try assertFrame(
            [0x05, 0x01],
            equals: [0x05, 0x01, 0, 0, 0, 0, 0, 0xF9] + [UInt8](repeating: 0, count: 56))
    }

    /// `setAutoOsen(true)` = [23,1] (0x17,0x01): soma = 24 (0x18) → checksum = 231 = 0xE7.
    func testSetAutoOsenTrueGolden() throws {
        try assertFrame(
            [0x17, 0x01],
            equals: [0x17, 0x01, 0, 0, 0, 0, 0, 0xE7] + [UInt8](repeating: 0, count: 56))
    }

    /// `setAutoOsen(false)` = [23,0]: soma = 23 → checksum = 232 = 0xE8.
    func testSetAutoOsenFalseGolden() throws {
        try assertFrame(
            [0x17, 0x00],
            equals: [0x17, 0x00, 0, 0, 0, 0, 0, 0xE8] + [UInt8](repeating: 0, count: 56))
    }

    /// `getAutoOsen` = [151] (0x97): soma = 151 → checksum = 104 = 0x68.
    func testGetAutoOsenGolden() throws {
        try assertFrame(
            [0x97],
            equals: [0x97, 0, 0, 0, 0, 0, 0, 0x68] + [UInt8](repeating: 0, count: 56))
    }

    /// `getKbPowerSaveMode` = [134,0] (0x86,0x00): soma = 134 → checksum = 121 = 0x79.
    func testGetKbPowerSaveGolden() throws {
        try assertFrame(
            [0x86, 0x00],
            equals: [0x86, 0x00, 0, 0, 0, 0, 0, 0x79] + [UInt8](repeating: 0, count: 56))
    }

    /// `_getKeyMatrix(camada 1, seq 3)` = [137,1,3]: soma = 137+1+3 = 141 (0x8D)
    /// → checksum = 114 = 0x72. (Leitura: 8 iterações com seq 0...7)
    func testGetKeyMatrixGolden() throws {
        try assertFrame(
            [0x89, 0x01, 0x03],
            equals: [0x89, 0x01, 0x03, 0, 0, 0, 0, 0x72] + [UInt8](repeating: 0, count: 56))
    }

    /// Bit8 com mensagem de 1 byte: pad para 8 → [80,00...]; soma(bytes 0..7) = 128
    /// → checksum = 127 = 0x7F no ÍNDICE 8 (array cresce no JS).
    func testBit8ChecksumGrowsArray() throws {
        try assertFrame(
            [0x80], checksum: .bit8,
            equals: [0x80, 0, 0, 0, 0, 0, 0, 0, 0x7F] + [UInt8](repeating: 0, count: 55))
    }

    /// Bit8 com mensagem de 9 bytes: soma(bytes 0..7) = 128+1+...+7 = 156 (0x9C)
    /// → checksum = 99 = 0x63 sobrescreve o byte 8 (que era 8).
    func testBit8ChecksumOverwritesIndex8() throws {
        try assertFrame(
            [0x80, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08], checksum: .bit8,
            equals: [0x80, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x63]
                + [UInt8](repeating: 0, count: 55))
    }

    /// `None`: nenhuma escrita de checksum — byte 7 permanece como veio (zero).
    func testNoneChecksumLeavesTail() throws {
        try assertFrame(
            [0x11, 0x00, 0x0A], checksum: .none,
            equals: [0x11, 0x00, 0x0A, 0, 0, 0, 0, 0] + [UInt8](repeating: 0, count: 56))
    }

    /// Checksum Bit7 em mensagem de 8 bytes usa bytes 0..6 (a[7] é o alvo).
    func testBit7IgnoresByte7ofEightByteMessage() throws {
        // mensagem [128, 255, 0,0,0,0,0, 123]: soma 0..6 = 128+255 = 383 → &255 = 127
        // checksum = 255-127 = 128 = 0x80; o byte7 pré-existente (123) é SOBRESCRITO.
        try assertFrame(
            [0x80, 0xFF, 0, 0, 0, 0, 0, 0x7B],
            equals: [0x80, 0xFF, 0, 0, 0, 0, 0, 0x80] + [UInt8](repeating: 0, count: 56))
    }

    func testEmptyMessageFails() {
        XCTAssertThrowsError(try K86Codec.encode(message: [], checksum: .bit7))
    }

    func testTooLongMessageFails() {
        let long = [UInt8](repeating: 1, count: 65)
        XCTAssertEqual((try? K86Codec.encode(message: long, checksum: .bit7)),
                       nil as [UInt8]? )
        XCTAssertThrowsError(try K86Codec.encode(message: long, checksum: .bit7)) { error in
            XCTAssertEqual(error as? K86CodecError, .messageTooLong(length: 65, max: 64))
        }
    }

    func testBuildersConstrainSequence() throws {
        XCTAssertThrowsError(try K86Messages.getKeyMatrix(layer: 0, sequence: 8)) { error in
            XCTAssertEqual(error as? K86CodecError, .sequenceOutOfBounds(sequence: 8, max: 7))
        }
        XCTAssertThrowsError(try K86Messages.getKeyMatrix(layer: 0, sequence: -1)) { error in
            XCTAssertEqual(error as? K86CodecError, .sequenceOutOfBounds(sequence: -1, max: 7))
        }
    }

    func testBuildMessageRejectsOversize() {
        XCTAssertThrowsError(
            try K86Codec.buildMessage(command: 0x80, payload: [UInt8](repeating: 0, count: 64))
        ) { error in
            XCTAssertEqual(error as? K86CodecError, .messageTooLong(length: 65, max: 64))
        }
    }
}

/// Parsers golden — respostas sintéticas, índices citados por método no JS.
final class K86CodecParseTests: XCTestCase {

    /// `getUSBVersion`: `t[2]<<8|t[1]` → resposta [128, 0x12, 0x34] = 0x3412 (13330).
    func testParseRevGolden() throws {
        let version = try K86Responses.parseRev([0x80, 0x12, 0x34])
        XCTAssertEqual(version, 0x3412)
        XCTAssertEqual(version, 13_330)
    }

    /// Valores zero não são confirmação: [0, 0, 0] parseia 0 mas não é "sucesso".
    func testParseRevZeroIsZero() throws {
        XCTAssertEqual(try K86Responses.parseRev([0x00, 0x00, 0x00]), 0)
    }

    func testParseTooShort() {
        XCTAssertThrowsError(try K86Responses.parseRev([0x80, 0x12]))
        XCTAssertThrowsError(try K86Responses.parseProfile([0x85]))
        XCTAssertThrowsError(try K86Responses.parseDebounce([0x91, 0x00]))
        XCTAssertThrowsError(try K86Responses.parseAutoOsen([0x97]))
        XCTAssertThrowsError(try K86Responses.parseKbPowerSave([0x86, 0, 0, 0]))
    }

    /// `getCurrentProfile` lê byte 1.
    func testParseProfileGolden() throws {
        XCTAssertEqual(try K86Responses.parseProfile([0x85, 0x02]), 2)
        XCTAssertEqual(try K86Responses.parseProfile([0x85, 0x00]), 0)
    }

    /// `getDeBounce` lê byte 2: [145, x, valor].
    func testParseDebounceGolden() throws {
        XCTAssertEqual(try K86Responses.parseDebounce([0x91, 0x00, 0x0A]), 10)
    }

    /// `getAutoOsen` exige eco 151: [151, 1] = true; [151, 0] = false;
    /// outro comando no byte 0 → `staleEcho` (não convertido em false).
    func testParseAutoOsenGoldenAndEcho() throws {
        XCTAssertTrue(try K86Responses.parseAutoOsen([0x97, 0x01]))
        XCTAssertFalse(try K86Responses.parseAutoOsen([0x97, 0x00]))
        XCTAssertThrowsError(try K86Responses.parseAutoOsen([0x91, 0x01])) { error in
            XCTAssertEqual(error as? K86CodecError, .staleEcho(expected: 0x97, got: 0x91))
        }
    }

    /// `getKbPowerSaveMode`: bit 4 (`!!t[4]`).
    func testParseKbPowerSaveGolden() throws {
        XCTAssertTrue(try K86Responses.parseKbPowerSave([0x86, 0, 0, 0, 0x01]))
        XCTAssertFalse(try K86Responses.parseKbPowerSave([0x86, 0, 0, 0, 0x00]))
    }
}

/// Montagem opaca da matriz — 8 fatias de 64 B = 512 B, sem decoder de teclas.
final class K86CodecKeymapTests: XCTestCase {

    func testAssembleFull() throws {
        var slices: [[UInt8]] = []
        for i in 0..<8 {
            slices.append([UInt8](repeating: UInt8(truncatingIfNeeded: i), count: 64))
        }
        let keymap = try K86Responses.assembleKeymap(slices: slices)
        XCTAssertEqual(keymap.raw.count, 512)
        XCTAssertEqual(keymap.slices[7].count, 64)
        XCTAssertEqual(keymap.slices[0].first, 0)
        XCTAssertEqual(keymap.slices[7].first, 7)
        XCTAssertEqual(keymap[3].count, 64)
    }

    /// Estrita: fatia vazia é REJEITADA (não convertida em zeros indistinguíveis
    /// de dados válidos — correção do líder na revisão da K86-01).
    func testAssembleStrictRejectsEmptySlice() {
        XCTAssertThrowsError(
            try K86Responses.assembleKeymap(
                slices: [[UInt8]](repeating: [], count: 8))) { error in
            XCTAssertEqual(error as? K86CodecError, .keymapSliceLength(length: 0, expected: 64))
        }
    }

    /// Diagnóstico: fatia vazia vira zeros RASTREADOS — missingReadIndices guarda a
    /// posição e isComplete = false; comparação segura contra dados incompletos.
    func testAssembleDiagnosticsTracksMissing() throws {
        var slices: [[UInt8]] = []
        for i in 0..<8 {
            slices.append(i == 2 || i == 5
                ? []
                : [UInt8](repeating: UInt8(truncatingIfNeeded: i), count: 64))
        }
        let keymap = try K86Responses.assembleKeymapDiagnostics(slices: slices)
        XCTAssertEqual(keymap.raw.count, 512)
        XCTAssertEqual(keymap.slices[2], [UInt8](repeating: 0, count: 64))
        XCTAssertEqual(keymap.missingReadIndices, [2, 5])
        XCTAssertFalse(keymap.isComplete)
        let complete = try K86Responses.assembleKeymapDiagnostics(
            slices: [[UInt8]](repeating: [UInt8](repeating: 1, count: 64), count: 8))
        XCTAssertTrue(complete.isComplete)
        XCTAssertTrue(complete.missingReadIndices.isEmpty)
    }

    /// Diagnóstico: fatia NÃO vazia com tamanho errado continua rejeitada.
    func testAssembleDiagnosticsRejectsWrongLength() {
        var slices: [[UInt8]] = [[UInt8]](repeating: [UInt8](repeating: 0, count: 64), count: 7)
        slices.append([UInt8](repeating: 0, count: 63))
        XCTAssertThrowsError(try K86Responses.assembleKeymapDiagnostics(slices: slices)) { error in
            XCTAssertEqual(error as? K86CodecError, .keymapSliceLength(length: 63, expected: 64))
        }
    }

    /// Fatia ausente → zeros, exatamente como o JS (`[...i, ...new Array(64).fill(0)]`) —
    /// agora SEMPRE rastreado na variante de diagnóstico (zeros não passam por válidos).
    func testAssembleWithEmptySliceFillsZeros() throws {
        var slices: [[UInt8]] = []
        for _ in 0..<8 { slices.append([]) }
        let keymap = try K86Responses.assembleKeymapDiagnostics(slices: slices)
        XCTAssertEqual(keymap.raw, [UInt8](repeating: 0, count: 512))
        XCTAssertFalse(keymap.isComplete)
    }

    func testAssembleWrongShapeFails() {
        XCTAssertThrowsError(try K86Responses.assembleKeymap(slices: []))
        XCTAssertThrowsError(try K86Responses.assembleKeymap(
            slices: [[UInt8](repeating: 0, count: 63)] + [[UInt8]](repeating: [UInt8](repeating: 0, count: 64), count: 7)))
        var slices: [[UInt8]] = []
        for _ in 0..<9 { slices.append([UInt8](repeating: 0, count: 64)) }
        XCTAssertThrowsError(try K86Responses.assembleKeymap(slices: slices))
    }

    /// Init direto NÃO burla a forma 8×64 (correção do líder na revisão da K86-01).
    func testKeymapDataInitEnforcesShape() {
        XCTAssertThrowsError(try K86KeymapData(slices: [[UInt8]](repeating: [], count: 8)))
        XCTAssertThrowsError(try K86KeymapData(slices: [[UInt8]](repeating: [UInt8](repeating: 0, count: 63), count: 8)))
        XCTAssertThrowsError(try K86KeymapData(slices: [[UInt8]](repeating: [UInt8](repeating: 0, count: 64), count: 9)))
    }
}
