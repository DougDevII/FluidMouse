# K86_CAPABILITIES — matriz função → evidência (Attack Shark K86)

Data: 2026-11-04 · rev. 3 (7 correções do líder na atribuição da K86-01) · Células: K86-00/K86-01 · Autor: OpenCode.
Fonte read-only: `/Volumes/Armazenamento/Reverse-engineering/analises/attackshark-k86-mac` (SHA-256 em `.mece/k86/SOURCE_SHA256.txt`).

## Regras desta revisão (pedidos do líder, acatados)

1. Escopo: **integração nativa Swift/SwiftUI no FluidMouse**. As recomendações de Electron/Rust/daemon do relatório RE são *análise de proveniência*, não nosso plano; nada disso entra.
2. **Sem rede, sem cloud, sem tokens**: nenhum appid/appsecret/chave embutida no binário original (weather ODM, `api*.rongyuan.tech`) será copiado ou usado; FluidMouse permanece offline para o K86.
3. Nada de catálogo amplo por inferência: só entra o que tiver **evidência no caminho K86** (registro do dispositivo → classe → comando). Features de outras famílias (mouse 80–85/208–212, screens OLED/TFT, Hall, OTA BLE, bootloader) estão **fora** do escopo e em seção separada.
4. Nenhum hardware executado nesta célula: IORegistry do líder foi leitura-only.

## 1. Identidade confirmada no Mac (fato novo do líder, 2026-11-04)

IORegistry apenas leitura — **confirma a coleção candidata, não prova modelo/comandos**:

| IOHIDDevice | usagePage / usage | MaxFeatureReport | Papel |
| --- | --- | --- | --- |
| Device 1 | 0x0001 / 0x0006 | 0 | teclado (dinâmica) |
| Device 2 | 0x000C / 0x0001 | 1 | consumer |
| Device 3 (coleção de configuração) | **0xFFFF / 0x0002** | **64** | **canal de comando (feature reports)** |

- Identidade: "Gaming Keyboard", USB, VID 0x3151, PID 0x4015, LocationID 18022400, RegistryEntryID da coleção de config = 4294982852.
- Confronto com o renderer: registro **`id:1168`** (`index.b078bf5f.js`) — `vid:12625 (0x3151), pid:16405 (0x4015)`, `displayName:"K86"`, `name:"yc3121_sg8967_3m_soc"`, `type:"keyboard"`. Histórico de QA anterior ("GamingKeyboard VID3151 PID4015") casa com este registro — **fato histórico, não contrato**. O MESMO PID tem outro registro (`id:3041`, displayName "K2405", company DNS). Escolha de modelo por PID sozinha não é prova. **Complemento 2026-11-04 (hashes OK) resolveu P1-1b/1c para 0x4015**:
a seleção do original é por **catálogo** (`name`+`company`+`id` persistidos; `a5d33148.js` @≈8312 escolhe módulo por `r[_.name]`; filtro `KL` por `company` + `id` em `index` ≈481700–482000) — NÃO por hardware. No FluidMouse a identidade física 0x3151:0x4015 continua **candidata** e a escolha "K86" vs "K2405" será manual na UI por registro de `id`. Estado atual: **teclado presente e confirmado no Mac via IORegistry; nenhum comando HID executado ainda** (diferente de "nenhum teclado conectado").
- PIDs 0x5040/0x504B/0x503F etc. do renderer são **dongles genéricos** (`type:"dongle"`); não são teclado. O registro id:2730 (0x5002, "yc3123") é a outra variante K86, não confirmada neste Mac.

## 2. Layout físico / matriz (prova de seleção de classe)

- Registro id:1168 → **`keyLayout: c.Common89_SG8967_v2`** = "常规89键 带屏旋钮(机械轴)" (*teclado regular de 89 teclas com tela e knob, switches mecânicos*) — string literal em `index.b078bf5f.js` (@≈166434). v3 = idem + sync de tela/idioma.
- Associação layout → array: `case c.Common89_SG8967: case c.Common89_SG8967_v2: return e(E4); case c.Common89_SG8967_v3: return e(L4)` (offset ≈1327315). **E4** = lista física de teclas (`"Escape","Backquote","Digit1",…`); **L4** v3 com knob de volume no fim ("AudioVolumeUp/Mute/Down"). Contagem bruta extraída: E4 87 itens citados, L4 90 — a correlação de cada posição física com a matriz de comandos segue aberta (RE P1-3).
- **Correção do líder (rev. 3) — comprimentos provados no próprio `438d24dc.js`**: leitura `_getKeyMatrix` (offset ≈5410) = **8 leituras `[137, camada, seq]`, 64 B cada, concatenadas = 512 B brutos**; escrita `_setKeyConfig` (offset ≈20952) = **9 pacotes de 56 B** com header `[9, camada, 0xF8, 0x01, seq]` = **504 B**. Logo **"89×4" NÃO está provado**: falta resolver a ponte 512→504, o *stripping* do header de resposta e a semântica de cada byte (`matrixToConfigValues` exige `t.length === defaultMatrix.length`, e o comprimento de `defaultMatrix` para o K86 não foi extraído). O array `Z` de 512 valores em `5e635fe2.js` continua **não verificado** para o K86 — não assumir.
- Consequência honesta: quantidade exata de teclas/modelo físico (89 vs 87+knob) é saída esperada do probe descritor do teclado real na K86-02 (leitura do descritor via IORegistry; nenhuma comunicação até lá).

## 3. Formato de frame (64 vs 65 bytes — a distinção que o líder pediu)

| Transporte | Como o cmd sai | Evidência |
| --- | --- | --- |
| **WebHID (Chrome, path "sem daemon")** | `sendFeatureReport(reportId=0, payload64)` com `payload[0] = cmd FEA`; payload mínimo 8 bytes com padding; **na wire o Chrome envia 65 bytes com prefixo 0x00** | relatório RE §3.1; classe `iA.sendFeature` (`index.b078bf5f.js` offset 861651): `a[7]=255-(uh(a.slice(0,7))&255)` (Bit7), `a[8]=255-(uh(a.slice(0,8))&255)` (Bit8), padding em `t.length<8` |
| **hidapi/Windows (daemon)** | decompile mostra **pass-through puro**: `hid_send_feature_report` @008b0b60 envia o buffer do gRPC **sem inserir/injetar report ID** (`dump_iot_driver_c.txt`, `hid_get_feature_report` @008b00d0 idem) — a semântica é da hidapi Windows (buf[0] = report ID para HidD_SetFeature); por isso o original funcionava com o payload do renderer como está, e **essa semântica não pode ser transferida por inferência** | `decompile-nativo/dump_iot_driver_c.txt` linhas 191–199 e 571–599 |
| **macOS/IOKit (nosso)** | `IOHIDDeviceSetReport/GetReport` (kIOHIDReportTypeFeature): reportID é parâmetro separado, o buffer é o payload; a coleção 0xFFFF:0x0002 tem `MaxFeatureReportSize=64` **na IORegistry real** → o descritor não reserva byte de prefixo: o frame de 64 bytes com byte0 = cmd é **compatível**, mas a primeira escrita/leitura ocorre **só com autorização, comparando descritor + resposta** | IORegistry do líder (MaxFeature 64); API IOKit padrão |

Checksum (Bit7/Bit8/None), padding mínimo de 8 bytes ANTES do checksum e byte-alvo fixo (índice 7 Bit7 / 8 Bit8, mesmo em mensagens longas — classe `iA.sendFeature`): C. **Correção do líder (rev. 3):** a resposta `resp[1]|resp[2]<<8` com `resp[0]==0xF1` (241) do relatório RE pertence ao **caminho do driver** (`getIotVersion`/getVersion) e NÃO é resposta universal do teclado — parser de teclado usa os bytes por comando (§4).

## 4. Comandos do K86 (classe-base de teclado; única família autorizada no escopo)

Fonte: `chunks-renderer/438d24dc.js`, atribuições `FEA_CMD_*` no arquivo (colisões de outras famílias registradas em `fea_cmds_por_chunk.txt` e **explicitamente excluídas** abaixo).

| Função | GET | SET | Payload/leitura observados | Pode avançar sem RE? |
| --- | --- | --- | --- | --- |
| Versão USB/RF | 128 (`GET_REV`) / 143 | — | `getUSBVersion` (offset ≈2762): mensagem `[128]`; resposta **`t[2]<<8 \| t[1]`** (sem 0xF1 — esse byte é caminho do driver, não do teclado) | Sim (leitura) |
| Versão tela | 173 | — | fora de escopo (tela) | — |
| Perfil | 133 | 5 | `getCurrentProfile` (offset ≈3089): GET `[133]`, resposta **byte 1**; SET `[5,idx]`. **Total de perfis NÃO demonstrado — não assumir "4"** | Leitura Sim; escrita com valor lido como referência |
| Debounce | 145 | 17 | `getDeBounce` (offset ≈3406): resposta **byte 2**; SET (offset ≈3051) `[17,0,t]`; default 10 no registro K86 | Sim |
| Matriz/remap | 137 | 9 | `_getKeyMatrix` (offset ≈5410): 8 leituras `[137, camada, seq]`, **512 B brutos concatenados** — comprimento ≠ 89×4; `_setKeyConfig` (offset ≈20952): 9 pacotes de 56 B com header `[9, camada, 0xF8, 0x01, seq]` = **504 B**. `matrixToConfigValues` exige `t.length === defaultMatrix.length` — comprimento real do defaultMatrix e o *stripping* do header da resposta **não resolvidos** (RE P1-3); sem encoder nesta fase | Leitura opaca Sim; escrita Não |
| FN composto | 144 | 16 / 21 SIMPLE | layout por registro v2/v3 | Sim (com guardas) |
| Macros | 139 | 11 / 22 SIMPLE | frames 56B: `[11,idx,seq,56,last,…]` | só com vocab de keycode (RE P2-8) |
| KBOPTION | 134 | 6 | `getKbPowerSaveMode` (offset ≈7146): `[134,0]`, **bit 4**=economia de energia (`!!t[4]`); demais bits RE | bit 4 leitura Sim; resto "—" |
| LEDPARAM (RGB principal) | 135 | 7 | **estrutura demonstrada** (`setLightSetting` offset ≈8009 / `getLightSetting` ≈8694): `e[1]=índice LIGHTLIST, e[2]=MAXSPEED-speed, e[3]=bright, e[4]=option<<4\|(dazzle?6:7)` com exceções por tipo; `e[5..7]=rgb` (0xFFFFFF→16449530). Falta **LIGHTLIST do K86** (`lightLayout:Be` no index) — RE P2-4 reescrito | Não (aguardando LIGHTLIST) |
| SLEDPARAM (luz lateral) | 136 | 8 | **RE** | não |
| SLEEPTIME | 146 | 18 | base stub `{time_bt:120,time_24:120,deep:28*60}` (offset ≈10943); implementação real por variante RE | leitura "—" até RE |
| AUTOOSEN (Win/Mac) | 151 | 23 | `setAutoOsen` (offset ≈21057): `[23,0/1]`; `getAutoOsen` (offset ≈21026): **exige eco** (`t[0]!==151`→falha), valor `t[1]===1` | Sim |
| Reset de protocolo | — | 2 | fora de escopo (não exposto) | — |
| Info/dispositivo (SKU) | 143/208 | 80 | `getSku/skuToText` presentes na base | leitura "—" até RE |

**Números da família mouse** (80–85 SET_*MOUSE, 208–212 MOUSE_GET_*) e **comandos de Hall (27–30,101,156–158,229)**, de **tela (32–50,160–171,178)** e **OTA/bootloader (44,48,49,172,176,177,192–196,64–68)**: **fora da matriz**, mesmo que apareçam no bundle. Nenhum deles chega ao service do K86.

## 5. Bateria/status vendor

- Contrato original: daemon entrega `driver.Device.battery` (proto linhas 31–40) alimentado por reports vendor que **não temos dump** (RE P2-6). Até lá: **sem bateria na UI** (mostrar "—").

## 6. Recursos explícitamente fora de escopo (não planejar, não implementar)

Tela TFT/OLED/GIF/clima/relógio do display; OTA BLE/GATT (nordic/OLED bootloader); reset de fábrica/flash/bootloader; calibração magnética/rapid-trigger (K86 está `noMagneticSwitch:true` nos dois registros — e isso não é prova de ausência de hardware, apenas do software); mute de microfone; active-window; KV-daemon; cloud/appid/appsecret; control-recoil; `SET_WANGBA_RESET`. Nada de Electron/Rust/daemon; nada de abrir apps.

## 7. Ambiguidades abertas (não resolver por inferência)

1. **K86 vs K2405** (0x4015): RESOLVIDO estaticamente pelo complemento 2026-11-04 — decisão por catálogo (`company`+`id`+`name`), não por hardware; ver §provenância no RE request. Restam: o **loader do 0x5002** (nenhum módulo do material instancia o `95287242`; `a5d33148` não contém `yc3123`) e a confirmação em hardware (do alcance final do resolver).
2. PIDs 0x5040/0x504B: dongles genéricos; qualquer uso wireless depende de RE P1-1 (PIDs BT/dongle do K86).
3. Variante 0x5002 ("yc3123") não confirmada neste Mac; planejo para casar por fingerprint da coleção (0xFFFF:0x0002) + PID.
4. **Matriz do K86**: comprimento de `defaultMatrix`, ponte 512 (leitura bruta) → 504 (escrita 9×56) e *stripping* do header de resposta (RE P1-3; descritor real na K86-02). Sem isso, keymap é apenas leitura opaca.
5. Semântica exata do byte de report ID em IOKit para esta coleção (64 vs 65): resolver **por probe descritor + leitura autorizada** na K86-02, nunca por inferência de hidapi-Windows.

## 8. Elegibilidade final para implementação (revisão 2)

| Grupo | Elegível | Condição |
| --- | --- | --- |
| Enumeração pela fingerprint (VID/PID/coleção 0xFFFF:0x0002, "identidade não confirmada") | Sim | implementada na K86-02, sem trocas automáticas |
| Versão (GET_REV 128) | Sim | leitura autorizada; parse `t[2]<<8\|t[1]`; eco é guarda do controller/transporte (não do parser) |
| Debounce 145/17 | Sim | roundtrip |
| Matriz 137 (leitura opaca) | Sim | 8 fatias × 64 → 512 B; **estrita** — fatia ausente rejeitada; diagnóstico separado rastreia missing/isComplete e não alimenta estado confirmado |
| Matriz 9 (escrita) | Não | RE P1-3: ponte 512→504 + stripping + semântica |
| Perfil 133/5 | Parcial | leitura byte 1; escrita de índice; total não demonstrado |
| AUTOOSEN 151/23 | Sim | GET exige eco (`t[0]!==151`→falha); zero não é confirmação |
| KBOPTION bit 4 (134) | Sim (bit 4) | demais bits "—" (RE P2-9) |
| FN 144/16, 21 | Parcial | mapa v2/v3 (RE) |
| RGB/SLED/LED | Não (por enquanto) | estrutura de bytes provada (offset ≈8009), falta LIGHTLIST do K86 (RE P2-4) |
| Sleep 146/18 | Não (por enquanto) | RE P2-5; UI mostra "—" |
| Bateria | Não (por enquanto) | RE P2-6 |
| Macros 139/11 | Não (por enquanto) | RE P2-7/8 |

**P1-1c (RESOLVIDA para 0x4015 em 2026-11-04, complemento do usuário com hashes OK):** `findYC3121Device` (`a5d33148.js`) escolhe por catálogo `r[_.name]` e instância `b74085e4.Yc3121_sg8967_3m_soc extends CommonKbYc500 (438d24dc)` com override APENAS de matrizes ⇒ **wire format do 0x4015 = coluna 438d24dc**, que é onde o codec K86 atual casa por offset. A coluna divergente (`5e635fe2.et`: versão cmd 143 `e[8]<<8|e[7]` @3211; boot cmd 143 `resp[9]` em `63fce7a0`) só se aplica à cadeia 0x5002 — cujo **factory ainda NÃO está no material** (nenhum loader instancia o `95287242`). Nenhum parser invertido foi publicado; a consulta física GET_REV permanece pendente de revisão do líder (gate `K86GetRevProbeGate` no código).

O plano segue regido por "leitura-first": toda escrita requer leitura anterior bem-sucedida no mesmo token, com correlação requisição↔resposta garantida pela camada de transporte (nunca pelo parser isolado), e zero/eco/resposta antiga não transformam "enviado" em "aplicado".
