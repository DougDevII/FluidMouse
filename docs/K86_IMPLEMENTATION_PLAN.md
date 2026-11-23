# K86_IMPLEMENTATION_PLAN — integração do Attack Shark K86 no FluidMouse (rev. 3)

Data: 2026-11-04 · rev. 2 pós-feedback do líder; rev. 3 das 7 correções recebidas na atribuição da K86-01 · Evidência: `docs/K86_CAPABILITIES.md` (rev. 3).

## Princípios (hardened)

1. **Nativo Swift/SwiftUI + IOKit** e nada mais: **sem Electron, sem Rust, sem daemon genérico, sem processo externo**, sem `iotdriver://`. As recomendações Electron/Rust do relatório RE ficam no arquivo externo — não entram no fluido do FluidMouse.
2. **Offline por construção**: sem rede, sem cloud ODM, sem weather, sem conta/login, e **nenhum token/appid/appsecret/chave embutida no binário original é copiado** para o app.
3. **Somente o que é evidenciado no caminho K86**: cada função implementada carrega, no report da célula, o par (registro do dispositivo → comando da classe-base de teclado). Features de outras famílias do bundle (mouse, Hall, tela, OTA, bootloader) ficam fora.
4. **Identidade candidata, nunca contrato**: fingerprint = VID 0x3151, PID 0x4015 (confrontado com registro `id:1168` do renderer), coleção de configuração `usagePage 0xFFFF / usage 0x0002` (MaxFeatureReport 64 — IORegistry real do líder), RegistryEntryID 4294982852 na sessão de hoje. Enquanto a resolução K86-vs-K2405 (mesmo PID no renderer) não tiver decisão (RE P1-1b), a UI mostra "identidade não confirmada" e nenhuma escrita é habilitada.
5. **Framing 64 vs 65 por evidência**: no macOS/IOKit a coleção confirma 64 de buffer com byte0 = comando. O codec da K86-01 é parametrizável (reportID zero implícito ou explícito); a K86-02 valida por descritor + leitura autorizada **antes de qualquer escrita** — não transferimos a semântica hidapi-Windows por inferência.
6. Guardas do produto (rev. 3, correções do líder): **perfis K86 podem existir por identidade** e o número de perfis não é demonstrado no JS — não assumir "4"; sem "aplicado" sem resposta confirmada; zero/eco/resposta antiga não é confirmação; valores não legíveis = "—"; firmware/reset de fábrica/calibração desconhecida fora; sem comandos da família mouse (80–85, 208–212) ou Hall (27–30, 101, 156–158, 229) destinados ao teclado.
7. **Parsers por comando, não 0xF1 universal**: a resposta `resp[0]==241` com versão em `resp[1]|resp[2]<<8` é caminho do *driver* (getIotVersion), não resposta do teclado. `getUSBVersion` (offset ≈2762) lê `t[2]<<8|t[1]` da resposta do próprio comando; `getCurrentProfile` (≈3089) byte 1; `getDeBounce` (≈3406) byte 2; `getAutoOsen` (≈21026) exige eco.

## Arquitetura

```
FluidMouse
├─ Services
│  ├─ K86HidService.swift        # IOHIDManager (matching by usagePage 0xFFFF/usage 0x02; guard VID/PID)
│  │                             # IOHIDDeviceGetReport/SetReport (feature, 64 B), fila por conexão,
│  │                             # vendorSleep padrão 100 ms; sem BT nesta fase (RE P1-1 pendente)
│  └─ K86Device.swift            # builders/parsers puros (sem I/O) para teste unitário
├─ Stores
│  ├─ K86Controller.swift        # status/drafts/operações por id (espelha RapooOperationTracker)
│  └─ K86KeymapDraft.swift       # draft puro do remap (matriz por slots do descritor)
└─ Views
   └─ K86View.swift              # aba teclado (⌘5) reusando DesignSystem/UI-01
```

`Package.swift` continua sem mudanças. Testes em `Tests/FluidMouseCoreTests/` (codec/frames) e `Tests/FluidMouseTests/` (controller/draft/UI).

## Capacidades que ENTRAM (evidência K86, com fonte)

| Capacidade | Comandos | Célula |
| --- | --- | --- |
| Enumeração + status conexão (USB) | IORegistry/IOHIDManager (sem protocolo) | K86-02 |
| Leitura de versão (`getUSBVersion`) | GET 128 — resposta `t[2]<<8\|t[1]` (offset ≈2762) | K86-02 |
| Leitura/escrita de debounce (default 10) | GET 145 (byte 2) / SET `[17,0,t]` | K86-02/03 |
| Leitura de matriz opaca (8×64 → 512 B) | GET 137 `[137, camada, seq 0..7]` | K86-01 (codec)/02 (transporte) |
| Escrita de matriz | **excluída até resolver** raw512↔write504, *stripping* do header e semântica dos bytes (RE P1-3) | — |
| Perfil | GET 133 (byte 1) / SET `[5,idx]`; **total não demonstrado, não inventar** | K86-03 |
| Auto-OS toggle | GET 151 (eco exigido, byte 1) / SET `[23,0/1]` | K86-03/04 |
| Economia de energia (bit 4 de KBOPTION) | GET 134 `[134,0]` → `!!t[4]` (leitura) | K86-03/04 |
| FN composto (mapa v2/v3 pendente de RE P1-3) | GET 144 / SET 16/21 | K86-04 (parcial) |

**Não entram (sem evidência K86 ainda)**: RGB/SLED (135–136/7–8), sleep efetivo (146/18), KBOPTION (134/6), bateria vendor, macros (139/11), tela, OTA, magnéticos — cada um com RE amarrado no request; UI mostra "—".

## Células

| Célula | Escopo | Posse | Bloco |
| --- | --- | --- | --- |
| K86-01 | Codec puro **IMPLEMENTADO** (2026-11-04): `K86Codec` (pad 8, checksum Bit7 índice 7 / Bit8 índice 8 que cresce o array / None, pad final 64), `K86Command` whitelist (128/133/145/151/134/137 + SET 5/17/23), `K86Messages` builders, `K86Responses` parsers (rev byte1..2 big-endian, perfil byte1, debounce byte2, autoOS eco, powerSave byte4), montagem opaca de keymap 8×64=512 (fatia vazia → zeros); **sem encoder de keymap/escrita**, sem keycodes, sem 89×4 | `Sources/FluidMouseCore/K86/K86Codec.swift`, `Tests/FluidMouseCoreTests/K86CodecTests.swift` (golden sintéticos calculados à mão) | K86-00 revisada |
| K86-02 | Transporte: IOHIDManager fingerprint, abertura/fechamento da coleção de config, GetReport/SetReport feature (64 B) com guardas, fila + geração por conexão, **probe descritor autorizado** (validar 64/65 por leitura do descritor e leitura de versão) — só depois versões/debounce | `Services/K86HidService.swift`, `K86Device.swift` | K86-01 |
| K86-03 | Controller + drafts + persistência: `runOperation` com settle/geração; draft keymap/debounce/perfil/auto-OS; `UserDefaults` compatível | `Stores/K86Controller.swift`, `K86KeymapDraft.swift`; `AppController.swift` por transferência declarada | K86-02 |
| K86-04 | UI/QA: aba teclado (status, versões, remap read/write, debounce, perfil, auto-OS; "—" para IR/não evidenciado), integração de navegação via transferência, a11y, evidências offscreen | `Views/K86View.swift`; edits em `ContentView`/`FluidMouseApp`/`DesignSystem` por transferência | K86-03 |

## Primeiras escritas (protocolo seguro)

- Ordem obrigatória por comando: (1) descritor lido; (2) GET correspondente pelo menos uma vez por conexão; (3) SET; (4) GET de verificação e comparação. Qualquer divergência → operação falha, estado “não aplicado”, **nunca estado “aplicado” presumido**.
- Escritas só com autorização explícita do líder por comando (K86-02 em diante); reset (cmd 2), flash, bootloader e wipe de fábrica: nunca.
- Sem BT/dongle nesta fase (identidade e PIDs pendentes, RE P1-1). Sem rede, nunca.

## Riscos

- **PID compartilhado** (K86/K2405): mitigado por estado "identidade não confirmada" até leitura decisiva; rótulo nunca afirma "K86" antes disso.
- **Matriz não codificável nesta fase**: leitura = 8×64 = 512 B brutos (inclui byte0..7 de cada fatia — *stripping* não resolvido); escrita = 9×56 = 504 B com header `[9, camada, 0xF8, 0x01, seq]`; a ponte entre os dois formatos e a semântica de cada byte são pré-requisito de qualquer editor (RE P1-3 + probe K86-02).
- **Concorrência Rapoo+K86**: filas por service isoladas; nenhum caminho do K86 navega no RapooHidService.
- **Escopo não cresce por inferência**: novas famílias/comandos só entram por revisão do líder da matriz (`docs/K86_CAPABILITIES.md`).
