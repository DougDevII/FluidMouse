# Integração com o mouse Rapoo VT9 Pro

Documento de referência da integração do FluidMouse com o **Rapoo VT9 Pro** (1ª
geração), incluindo o que foi medido no aparelho, o que é herdado da
engenharia reversa do driver oficial da Rapoo e o que ainda **não** está
validado.

Material de origem (fornecido pelo usuário):

- `rapoo-game-dev-driver-1.6.29.md` — relatório de engenharia reversa do
  `RapooGameDev.exe` (driver oficial 1.6.29) com o mapa de registradores do
  VT9 Pro
- `rapoo-game-dev-driver-1.6.29-evidencia/` — artefatos brutos (strings, RTTI,
  QML ids, inventário) e a implementação de referência do projeto OpenMouse
  (`src/rapoo`, `src/drivers/rapoo/hid.ts`, `docs/rapoo-vt9-pro-testing.md`)

Documentos relacionados neste repositório:

- [Protocolo byte a byte](RAPOO_PROTOCOLO.md) — frames, respostas e registradores
- [Diagnóstico](RAPOO_DIAGNOSTICO.md) — como investigar quando algo não funciona
- [Validação](VALIDACAO.md) — o que já foi validado fisicamente

---

## 1. O aparelho

| Item | Valor medido |
| --- | --- |
| Fabricante | Rapoo (`VID 0x24AE`) |
| Modelo | VT9 Pro (1ª geração) |
| PID com cabo | `0x418A` (compósito "Rapoo Gaming Device") |
| PID do receptor | `0x185A` |
| PID no material de referência (outro lote) | `0x4405` (cabo) e `0x1205` (receptor) |

> **Os PIDs variam entre lotes.** O FluidMouse **nunca** casa por PID: ele
> procura a coleção de configuração `0xFF00:0x000E` no descritor de relatório
> e prefere o link que responde. O PID é usado apenas como etiqueta na
> interface (e para distinguir cabo de receptor).

### Coleções HID expostas (medidas no cabo, `0x418A`)

| Uso | Report ID | Observação |
| --- | --- | --- |
| `0xFF00:0x000E` (configuração) | `0xBA` | 31 bytes de report data; **no macOS o buffer de saída leva o report ID no byte 0** (32 bytes) |
| `0xFF00:0x0002` (heartbeat) | `0xBB` | 7 bytes, enviado sozinho ~3 s; traz bateria e link |
| `0xFF00:0x0002` (segunda) | `0xBC` | 11 bytes — **não investigada**, deixada intocada |
| `0xFF0B:0x0104` (status, feature) | `0x2A` | **não existe no descritor deste aparelho** — a leitura de feature 0x2A falha aqui |

O compósito com cabo expõe **dois** dispositivos HID (descritores de 202 e 73
bytes); apenas o primeiro tem a coleção de configuração.

### Cabo e receptor convivem

Com o cabo plugado, o receptor continua enumerado, mas **só o link ativo
responde o canal `0xBA`** (medido: no cabo, o receptor cala). O heartbeat
`0xBB` identifica qual link está em uso — ver [protocolo](RAPOO_PROTOCOLO.md).

---

## 2. Permissões no macOS

O acesso ao canal de configuração é regido pelo TCC, serviço
`kTCCServiceListenEvent` ("**Monitoramento de Entrada**"). Detalhes que
custaram tempo e estão registrados aqui de propósito:

1. **`IOHIDDeviceOpen` devolve sucesso mesmo quando o TCC nega.** A negação
   só aparece depois, como operações silenciosamente inertes (a leitura
   "responde" com o conteúdo velho do buffer). Por isso o FluidMouse consulta
   `CGPreflightListenEventAccess()` e mostra a pendência na interface.
2. **`CGRequestListenEventAccess()`** é a API que dispara o prompt nativo
   ("FluidMouse gostaria de receber entradas de outros aplicativos"). O botão
   **Abrir Monitoramento de Entrada…** do card de pendência abre o painel
   correto (`Privacy_ListenEvent`).
3. **O aplicativo precisa estar em `/Applications`** para que a entrada do TCC
   seja utilizável; a versão em `dist/` é a de desenvolvimento.
4. **A assinatura determina a identidade da entrada do TCC.** O script
   `script/build_and_run.sh` assina com a identidade "Apple Development" do
   usuário (fallback ad hoc), para que a permissão sobreviva aos rebuilds.
   Trocar a assinatura invalida a grant anterior.
5. `tccutil reset ListenEvent br.com.douglas.fluido` limpa registros órfãos
   (entradas apontando para binários removidos, que não "pegam" no toggle).

---

## 3. Arquitetura da implementação

| Arquivo | Responsabilidade |
| --- | --- |
| `Sources/FluidMouseCore/Rapoo/RapooProtocol.swift` | Codec puro: frames, respostas, decodificadores dos registradores, tabelas (polling, debounce), escala de DPI, links do heartbeat. Sem IOKit — testável |
| `Sources/FluidMouse/Services/RapooHidService.swift` | Transporte IOKit: vínculo de link, troca com timeout, watchdog, heartbeat, escritas com read-back |
| `Sources/FluidMouse/Stores/AppController.swift` | Ponte entre a interface e o serviço; expõe `rapooStatus` e as ações de escrita |
| `Sources/FluidMouse/Views/RapooHardwareView.swift` | Aba **Hardware**: status, editores, painel de diagnóstico |
| `Tests/FluidMouseCoreTests/RapooProtocolTests.swift` | 21 testes do codec com os frames medidos no aparelho |

### O laço do serviço

```
a cada 1,2 s (enquanto os registros não chegam) ou 5 s (com tudo em mãos):
  1. CGPreflightListenEventAccess()            → pendência de permissão
  2. leitura leve do estágio ativo (0x898)      → vigia do link
     ├. respondeu  → atualiza o estágio; se ainda não leu tudo, faz a varredura
     └. mudo       → mantém o vínculo (o mouse dormiu) e tenta de novo
  3. query de bateria (0xAA) com timeout
  heartbeat 0xBB → atualiza bateria, carga e link; se o link mudou, re-vincula
```

O vínculo **nunca é descartado só por silêncio**: o firmware do VT9 Pro
silencia o canal `0xBA` e o heartbeat `0xBB` enquanto o mouse está parado, e
volta quando ele se move.

### Por que o I/O roda fora da fila do serviço

Escrever um report para um mouse adormecido **trava dentro do kernel**
(transferência de controle sem resposta). Se isso rodasse na fila serial do
serviço, uma única leitura travada congelaria todas as demais. Por isso:

- cada troca roda em `DispatchQueue.global()` com **timeout** (1,2 s); a
  chamada travada é abandonada e o serviço continua;
- **nunca em `Thread` crua**: medi-se que `IOHIDDeviceGetReport` bloqueia
  indefinidamente numa thread sem run loop (com `DispatchQueue` funciona).

---

## 4. Comportamento do firmware (medido)

- **O mouse dorme.** Parado, ele para de responder `0xBA` e de enviar `0xBB`;
  ao ser movido, volta. Por isso a interface explica que é preciso mexer no
  mouse para a leitura aparecer.
- **Um único slot de resposta.** O `GET_REPORT(Input)` do macOS devolve
  sempre a última resposta produzida pelo aparelho — e ler o mesmo
  registrador duas vezes devolve bytes idênticos, então "a resposta é nova?"
  não é decidível pelo conteúdo. A estratégia adotada é **perguntar duas
  vezes**: a segunda resposta é necessariamente do registrador pedido.
- **Latência de processamento**: ~5 ms no receptor, ~30 ms no cabo.
- **Escala de DPI**: neste firmware os estágios são gravados **divididos por
  50** (`8, 16, 24, 32, 64, 128, 520` → `400, 800, 1200, 1600, 3200, 6400,
  26000`). A escala é inferida pelo código
  (`RapooProtocol.inferDpiScale`) e cada escrita é confirmada por read-back.
- **Contagem de estágios**: o byte `[14]` de `0x888` guarda `estágios − 1`
  (valor `0x07` → 7 estágios habilitados).
- **`0x880` (polling)**: neste aparelho o código de taxa (`0x82` = 4000 Hz)
  aparece no **byte 1** (`01 82 01 ff`); no material do gen1 ele ocupa os
  bytes 0 e 2. O serviço escolhe o slot pelo formato do bloco.
- **Heartbeat `0xBB`** (7 bytes): `bb b0 <link> b0 04 <carga> <bateria%>`
  — link `0x41` = cabo, `0x42` = receptor; carga `0x01` = descarregando,
  `0x02` = carregando.
- **Nunca ler o feature report `0x2B`**: desconecta o mouse até o cabo ser
  replugado. O serviço nunca toca nesse report.

---

## 5. Estado da validação

| Função | Leitura | Escrita | Observação |
| --- | --- | --- | --- |
| Bateria (%) e carga | ✅ | — | fontes: `0xAA`, `0xBB` |
| Link cabo/receptor | ✅ | — | byte de link do `0xBB`, confirmado pelo usuário |
| Estágios de DPI (7) | ✅ | ✅ | escrita validada com read-back (2000 DPI) e restaurada |
| Estágio ativo | ✅ | ✅ | validado ao vivo (0 ↔ 3, restaurado) |
| Polling rate (2.4 GHz / cabo) | ✅ (leitura) | ⏳ | slot de escrita por variante ainda em validação com o usuário |
| Lift-off (código 0–3) | ✅ | ⏳ | escala em mm desconhecida (o app oficial não expõe o valor) |
| Motion sync | ✅ | ⏳ | |
| Debounce (press/release) | ✅ | ⏳ | índices em `[1,2,4,8,16,24,32]` ms |
| Sleep | ✅ | ⏳ | neste aparelho o byte veio `0xFF` (desligado) |
| Angle snap / ripple | ✅ (flags) | ⏳ | byte de flags: bit 0 = angle snap **off**, bit 1 = ripple **off** |
| Notificações / heartbeat | ✅ | — | parser das duas formas (gen1 e firmware atual) |
| Persistência após power cycle | ⏳ | — | ainda não verificada |

O painel **Diagnóstico** da aba Hardware mostra os blocos brutos da última
varredura (`0x880`, `0x884`, `0x888`, `0x898`, `0x8C0`, `0x8C4`) e o PID do
device em uso — é a referência para cada validação de escrita.

---

## 6. Fora do escopo desta fase

O app oficial expõe mais recursos que **não** estão no protocolo
documentado e, portanto, não foram implementados: remapeamento de botões,
macros, iluminação/RGB, OLED, atualização de firmware e equalizador. O
relatório do driver oficial registra esses itens como "não cobertos pelo
protocolo OpenMouse".

---

## 7. Referência rápida

```bash
# build + abrir (a versão em dist/ é a de desenvolvimento)
/path/FluidMouse/script/build_and_run.sh

# logs do serviço (categoria rapoo)
/usr/bin/log stream --info --style compact \
  --predicate 'subsystem == "br.com.douglas.fluido" AND category == "rapoo"'

# probe ao vivo do canal (leitura + medições)
/path/FluidMouse/script/rapoo_probe.swift
```
