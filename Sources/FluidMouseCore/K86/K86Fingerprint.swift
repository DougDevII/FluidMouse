import Foundation

/// Fingerprint e fatos do descritor do teclado K86 — **pura** (sem IOKit) para
/// poder ser testada com bytes sintéticos.
///
/// Fonte da fingerprint: IORegistry real do líder (2026-11-04, leitura-only) —
/// "Gaming Keyboard" VID 0x3151 PID 0x4015; três dispositivos (teclado
/// 0x01:0x06, consumer 0x0C:0x01 e coleção de configuração 0xFFFF:0x0002
/// MaxFeature 64). Mesmo PID casa K86 (registro id:1168) e K2405 (id:3041):
/// nada aqui confirma identidade, só candidatura.
///
/// **Descritor REAL** capturado pelo líder no Mac (hex):
/// `06ffff0902a10109021580257f95407508b102c0` — decodificado:
/// `06 FF FF` usage page vendor 0xFFFF · `09 02` usage 0x0002 · `A1 01`
/// Collection(Application) · `09 02` usage · `15 80` LogicalMinimum(-128) ·
/// `25 7F` LogicalMaximum(127) · `95 40` ReportCount 64 · `75 08` ReportSize 8
/// · `B1 02` Feature(Data,Var,Abs) · `C0` End Collection. **Não há item `85 xx`
/// (Report ID) nem `91`/forcing 65-byte**: feature report **unnumbered**,
/// reportID 0 no parâmetro da API — não é inferência de MaxFeature=64, é o
/// descritor.
package enum K86Fingerprint {

    package static let vendorID = 12625 // 0x3151
    /// 0x4015 = registro id:1168 ("K86"); 0x5002 = id:2730 ("yc3123"). Dongles
    /// genéricos 0x5040/0x504B/0x503F ficam FORA.
    package static let candidatePIDs: Set<Int> = [16405, 20482]
    package static let configUsagePage = 65535 // 0xFFFF (coleção de configuração)
    package static let configUsage = 0x0002
    /// RAW value de `kIOHIDElementTypeCollection` (header SDK IOHIDDeviceTypes.h
    /// ≈linhas 119–128: Input_Misc=1, Input_Button=2, Input_Axis=3, Input_ScanCodes=4,
    /// Input_NULL=5, Output=129, **Feature=257**, **Collection=513**). O adaptador
    /// de produção compara `IOHIDElementGetType(element).rawValue` REAL; os testes
    /// sintéticos usam 513 — nunca o 3 (que é Input_Axis e mascarava a seleção).
    package static let collectionElementRawValue = 513 // kIOHIDElementTypeCollection

    /// Fatos do descritor REAL capturado pelo líder no Mac do usuário (hex
    /// `06ffff0902a10109021580257f95407508b102c0`): unnumbered e 64 bytes.
    package static let referenceDescriptorFacts = DescriptorFacts(
        usagePage: 65535,
        usage: 0x0002,
        featureReportCount: 64,
        featureReportSize: 8,
        featureByteCount: 64,
        usesReportIDItem: false)

    package struct ElementSample: Equatable, Sendable {
        package let usagePage: Int
        package let usage: Int
        package let type: Int
        package init(usagePage: Int, usage: Int, type: Int) {
            self.usagePage = usagePage
            self.usage = usage
            self.type = type
        }
    }

    /// Vínculo por ELEMENTS: só a coleção de configuração qualifica.
    package static func hasConfigCollection(elements: [ElementSample]) -> Bool {
        elements.contains { element in
            element.type == collectionElementRawValue
                && element.usagePage == configUsagePage
                && element.usage == configUsage
        }
    }

    /// Fatos extraídos do descritor (referência: o hex real do líder).
    package struct DescriptorFacts: Equatable, Sendable {
        package let usagePage: Int
        package let usage: Int
        package let featureReportCount: Int
        package let featureReportSize: Int
        /// bytes do feature report = count × size ÷ 8
        package let featureByteCount: Int
        /// Item `85 xx` presente dentro da coleção ⇒ report numerado.
        package let usesReportIDItem: Bool
        /// unnumbered = sem item `85` ⇒ API recebe reportID 0 e payload SEM prefixo.
        package var unnumberedFeature: Bool { !usesReportIDItem }
    }

    /// Parse CORRETO de item HID (comprimentos e escopos reais), sem substring:
    /// - tamanho do item = bits 0..1 do item (0/1/2/4 bytes de dados); long item 0xFE;
    /// - tipo = bits 2..3 (0 Main, 1 Global, 2 Local), tag = bits 4..7;
    /// - estado global (usage page 0x05/0x06, Report ID 0x85, Report Count 0x95,
    ///   Report Size 0x75, Push 0xA4/Pop 0xB4 com pilha); uso local 0x09 pendente
    ///   liga a próxima Collection/Feature no escopo atual;
    /// - Collection (0xA1) abre escopo, Feature (0xB1) registra no escopo atual,
    ///   End Collection (0xC0) fecha escopo de verdade (0xC0 sem A1 ⇒ nil).
    ///
    /// **Estrito para a coleção de configuração**: o stream INTEIRO deve fazer
    /// parse (descritor truncado/lixo final ⇒ nil); EXATAMENTE uma collection
    /// top-level, de usagePage 0xFFFF e usage 0x0002 (descritor com prefixo e
    /// outra collection ⇒ nil); SEM item de Report ID em NENHUM lugar (Report ID
    /// herdado/global ⇒ nil); SEM Push/Pop; SEM collection aninhada dentro do
    /// alvo (nested ⇒ nil); EXATAMENTE um Feature no alvo. Nenhum falso positivo.
    package static func descriptorFacts(_ descriptor: [UInt8]) -> DescriptorFacts? {
        let raw = descriptor
        var index = 0
        var usagePage: UInt64 = 0
        var reportCount = 0
        var reportSize = 0
        var globalsPushStack: [(page: UInt64, count: Int, size: Int)] = []
        var reportIDSeen = false
        var pushPopSeen = false
        var longItemSeen = false
        var pendingLocalUsage: UInt64 = 0
        var topLevelCollections = 0
        var featureOutsideCollection = false
        var itemsAfterFinalCollection = false
        var matchedTarget: (page: Int, usage: Int, nested: Int,
                            features: [(count: Int, size: Int)])?
        var matchedCount = 0

        struct Scope {
            var page = 0
            var usage = 0
            var nested = 0
            var features: [(count: Int, size: Int, page: Int)] = []
        }
        var stack: [Scope] = []

        func readPayload(_ byteCount: Int) -> UInt64? {
            guard byteCount == 0 else {
                guard index + 1 + byteCount <= raw.count else { return nil }
                var value: UInt64 = 0
                for offset in 0..<byteCount {
                    value |= UInt64(raw[index + 1 + offset]) << (8 * offset)
                }
                return value
            }
            return 0
        }

        while index < raw.count {
            let itemByte = raw[index]
            if itemByte == 0xFE { // long item: [0xFE, size, tag, dados…]
                guard index + 2 <= raw.count else { return nil }
                let dataSize = Int(raw[index + 1])
                guard index + 2 + dataSize <= raw.count else { return nil }
                if !stack.isEmpty { longItemSeen = true }
                index += 2 + dataSize
                continue
            }
            let dataSize = Int(itemByte & 0x03)
            let itemType = Int((itemByte >> 2) & 0x03)
            let tag = Int(itemByte >> 4)
            guard index + 1 + dataSize <= raw.count else { return nil } // truncado
            guard let payload = readPayload(dataSize) else { return nil }

            if itemsAfterFinalCollection {
                // Qualquer item depois da única collection top-level fechada
                // quebra a estrutura de referência.
                itemsAfterFinalCollection = true
                return nil
            }

            switch itemType {
            case 1: // Global
                switch tag {
                case 0: usagePage = payload // Usage Page (0x05 1-byte / 0x06 2-byte)
                case 8: reportIDSeen = true // Report ID herdado/qualquer escopo ⇒ não-referência
                case 9: reportCount = Int(truncatingIfNeeded: payload)
                case 7: reportSize = Int(truncatingIfNeeded: payload)
                case 10: // Push
                    pushPopSeen = true
                    globalsPushStack.append((usagePage, reportCount, reportSize))
                case 11: // Pop
                    pushPopSeen = true
                    guard let top = globalsPushStack.popLast() else { return nil }
                    usagePage = top.page
                    reportCount = top.count
                    reportSize = top.size
                default: break
                }
            case 2: // Local
                if tag == 0 { pendingLocalUsage = payload } // Usage (01/02/04)
            case 0: // Main
                switch tag {
                case 10: // Collection (0xA1)
                    stack.append(Scope(page: Int(truncatingIfNeeded: usagePage),
                                       usage: Int(truncatingIfNeeded: pendingLocalUsage)))
                    pendingLocalUsage = 0
                case 11: // Feature (0xB1)
                    if stack.isEmpty {
                        featureOutsideCollection = true
                    } else {
                        stack[stack.count - 1].features
                            .append((count: reportCount,
                                     size: reportSize,
                                     page: Int(truncatingIfNeeded: usagePage)))
                    }
                case 12: // End Collection (0xC0)
                    guard let done = stack.popLast() else { return nil }
                    if stack.isEmpty {
                        topLevelCollections += 1
                        if done.page == Self.configUsagePage,
                           done.usage == Self.configUsage {
                            let exactFeature = done.features.count == 1
                            let flat = done.features.first
                            let consistent = flat.map { $0.page == done.page } ?? false
                            if exactFeature && done.nested == 0 && consistent {
                                matchedTarget = (page: done.page, usage: done.usage,
                                                 nested: done.nested,
                                                 features: [(flat!.count, flat!.size)])
                                matchedCount += 1
                            } else {
                                matchedCount += 1 // estrutura divergente ⇒ але não-referência
                            }
                        }
                        itemsAfterFinalCollection = topLevelCollections <= 1
                        // Nota: se houver MAIS de uma collection top-level, o flag
                        // `topLevelCollections > 1` rejeita no check final abaixo.
                    } else {
                        // Collection aninhada: conta no pai — nested dentro do alvo ⇒ rejeita.
                        stack[stack.count - 1].nested += 1
                    }
                default: break
                }
            default: break
            }
            index += 1 + dataSize
        }

        guard stack.isEmpty else { return nil } // EOF sem fechar collection
        guard reportIDSeen == false, pushPopSeen == false, longItemSeen == false,
              featureOutsideCollection == false, topLevelCollections == 1,
              matchedCount == 1,
              let target = matchedTarget else { return nil }
        let feature = (count: target.features[0].count, size: target.features[0].size)
        guard feature.count > 0, feature.size > 0, (feature.count * feature.size) % 8 == 0 else { return nil }
        return DescriptorFacts(
            usagePage: target.page,
            usage: target.usage,
            featureReportCount: feature.count,
            featureReportSize: feature.size,
            featureByteCount: feature.count * feature.size / 8,
            usesReportIDItem: false)
    }
}

/// **Porta do GET_REV físico** (exigência do líder): a consulta física só pode
/// ser enviada com autorização do líder APÓS revisão estática — nunca por nome
/// de candidato.
///
/// Evidência por offset (chunks no mount + COMPLEMENTO do usuário de
/// 2026-11-04, `fluidmouse-complemento/chunks/`, hashes OK):
/// - `a5d33148.js` (`findYC3121Device`): factory escolhe por **nome de
///   catálogo** (`r[_.name]`, offset ≈8312 no arquivo), 48 variantes — o
///   VID/PID identifica só a família de leitura, o modelo é decisão de
///   catálogo/empareamento (desambiguação K86 vs K2405 também por catálogo
///   `company` + `id`, `index` ≈481700–482000).
/// - 0x4015 (K86): `a5d33148` → `b74085e4.js` `Yc3121_sg8967_3m_soc extends
///   CommonKbYc500 (438d24dc)` com override APENAS de matrizes ⇒ wire format
///   do 0x4015 = coluna 438d24dc (comando 128 @2742, parse `t[2]<<8|t[1]`
///   @2762) — o que o codec atual já casa por offset.
/// - 0x5002: `95287242.js` `Yc3123_sg_sg8967_3m_1k extends 63fce7a0.C extends
///   5e635fe2.et` (boot/OTA overrides só), MAS o factory que instancia o
///   95287242 NÃO está nos materiais (`a5d33148` não tem `yc3123`) ⇒ cadeia
///   5002 INCOMPLETA; seu wire (cmd 143 @2207, parse `e[8]<<8|e[7]` @3211)
///   permanece candidato não confirmado.
///
/// Conclusão computada do gate: requisição 0x80 e formato esperado NÃO são
/// idênticos entre as DUAS famílias candidatas (128≠143; [2]:[1]≠[8]:[7]) ⇒
/// o envio físico permanece PENDENTE até revisão do líder (o wire do 0x4015
/// está staticamente apontado, mas autorização de hardware é do líder).
package enum K86GetRevProbeGate {

    /// O que é igual: 1 byte de mensagem + checksum Bit7 nas duas famílias.
    package static let commonRequestBits = true
    /// 128 (438d24dc @2742) ≠ 143 (5e635fe2 @2207).
    package static let sameCommandNumber = false
    /// `t[2]<<8|t[1]` (@2762) ≠ `e[8]<<8|e[7]` (@3211).
    package static let sameResponseLayout = false

    /// Gate: envio físico autorizado apenas com `true`.
    package static var requestAndExpectedFormatIdentical: Bool {
        commonRequestBits && sameCommandNumber && sameResponseLayout
    }
}
