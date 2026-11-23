# K86_REVERSE_ENGINEERING_REQUEST — perguntas pontuais ao agente RE

Data: 2026-11-04 · rev. 5 (complemento do usuário integrado) · Solicitante: OpenCode · Fonte atual: `/Volumes/Armazenamento/Reverse-engineering/analises/attackshark-k86-mac` (+ `fluidmouse-complemento/`, 6 chunks com hashes SHA256 conferidos).

Cada item indica: (a) a pergunta, (b) o output requerido, (c) o que desbloqueia e o que pode avançar sem a resposta.

Prioridade sugerida: **P1** bloqueia células já planejadas; **P2** bloqueia features específicas; **P3** cosmético.

## P1 — bloqueia K86-02/03 (transporte e leitura/escrita base)

1. **Dongle do K86 e PIDs BT**: qual PID da lista `wR` (`index.b078bf5f.js`, `{12625,20487/20512/20543/20544/20555}, {13434,41730}`) acompanha o K86? Existe lista separada de PIDs BT para o próprio teclado?
   Output: extração da lógica de `connect: "usb"/"bt"` e das listas completas com o caminho/offset.
   Desbloqueia: modo wireless na K86-02. Avança sem: modo USB only.

1b. **RESOLVIDO (complemento 2026-11-04, hashes OK)** — K86 vs K2405 no PID 0x4015: a escolha é por **catálogo** — filtro por `company` (`KL` em `index` ≈481700–482000) e resolução por **`id` persistido**; nunca por hardware/produto. Consequência para o FluidMouse: escolha do modelo pelo usuário na UI com `id` persistido (`1168` vs `3041`); a identidade física permanece "candidata" até o usuário escolher. Item encerrado — não perguntar de novo.

1c. **PARCIALMENTE RESOLVIDO (complemento 2026-11-04)** — `a5d33148.js` (`findYC3121Device`, offset ≈8312): factory escolhe por **`r[_.name]` de catálogo** (48 variantes, todas o carregam de chunks derivados de `438d24dc.js`). Registro `name:"yc3121_sg8967_3m_soc"` (id:1168) → `b74085e4.js` → `Yc3121_sg8967_3m_soc extends CommonKbYc500` com override APENAS de `defaultMatrix`/`defaultFnMatrix` ⇒ **wire format do 0x4015 = coluna 438d24dc**; o codec atual casa por offset — nada a reescrever. A coluna `5e635fe2.et` (versão cmd 143 `e[8]<<8|e[7]` @3211; boot cmd 143 `resp[9]` em `63fce7a0`) agora É a cadeia do 0x5002 (`95287242.Yc3123_sg_sg8967_3m_1k extends 63fce7a0.C extends 5e635fe2.et`, confirmado nos chunks), MAS o **factory do 0x5002 não está no material** — `a5d33148` não contém `yc3123` — e o nome do registro é `yc3123_sg_sg8967_3m_1k`, não `yc3123_sg8967`.
   **Pergunta remanescente (P1-1c-part2)**: qual módulo/finder do bundle instancia o `95287242` (encontrar `findYc3123…`/equivalente e o registro que mapeia 20482/0x5002), com caminho/offset.
   Desbloqueia: wire format confirmado do 0x5002 (a coluna 438d24dc NÃO é adotada para 0x5002 até lá). Avança sem: transporte K86-02 e codec do 0x4015 funcionam; nenhum estado "confirmado" é publicado.

2. **Respostas de GET pendentes (byte a byte)** — **atualizado na rev. 3**: resolvemos por rastreio direto em `438d24dc.js` (não perguntar de novo):
   - GET_REV (128): resposta `t[2]<<8|t[1]` (offset ≈2762) — resolvido.
   - GET_PROFILE (133): byte 1 (offset ≈3089) — resolvido.
   - GET_DEBOUNCE (145): byte 2 (offset ≈3406) — resolvido.
   - GET_KEYMATRIX (137): 8×64 concatenados, sem checagem de eco (offset ≈5410) — resolvido no *frame*; falta o *stripping* (o que é header e o que é dado de tecla).
   - GET_KBOPTION (134): `[134,0]`, bit 4 = economia de energia (offset ≈7146) — resolvido para esse bit.
   - GET_CMD_AUTOOSEN (151): eco exigido, valor `t[1]===1` (offset ≈21026) — resolvido.
   **Restam**: GET_SLEEPTIME (146) e GET_LEDPARAM (135) — resposta/estrutura completa e detecção de resposta inválida/timeout na classe usada pelo K86.
   Output: dump comentado dos respectivos métodos (e da subclasse `isYC3123`/PID 0x5002).
   Desbloqueia: sleep/RGB na K86-03/04. Avança sem: UI mostra "—".

3. **Subclasse do K86 yc3123** — **atualizado na rev. 5**: a cadeia de classes do 0x5002 foi provada no material (`95287242 extends 63fce7a0.C extends 5e635fe2.et`; overrides: matrizes em 95287242; boot/OTA em 63fce7a0 — `getDeviceIsBoot` cmd 143, resposta válida iff `resp[9]===1` e `upgrade_dev` 186/192 com `BOOT_INFOS` pid 20481=0x5001). Falta o **factory** (ver 1c) e, com ele, o mapa de overrides herdáveis para sleep/luz/tela/macros.
   Output: módulo finder do 95287242 + caminho/offset.
   Desbloqueia: wire do 0x5002 confirmado; saber se sleep/RGB usam stubs da base ou comandos dedicados. Avança sem: K86-03 segue GET-first na coluna 438d24dc para o 0x4015.

## P2 — bloqueia features específicas (K86-03/04)

4. **LIGHTLIST do K86 + SET_SLEDPARAM (8)** — **atualizado na rev. 3**: a construção do `SET_LEDPARAM (7)` JÁ foi rastreada (`setLightSetting`, offset ≈8009): `e[1]=índice no LIGHTLIST do modelo`, `e[2]=MAXSPEED-speed`, `e[3]=bright`, `e[4]=option<<4|(dazzle?6:7)` com exceções (UserPicture `option<<4`; MusicFollow2/3 `option<<4|4`; ScreenColor `0`), `e[5..7]=rgb` (0xFFFFFF trocado por 16449530). **Falta o conteúdo do LIGHTLIST do K86** (derivado de `lightLayout:Be` no `index.b078bf5f.js`) para fechar índices de efeito, além de SET_SLEDPARAM (luz lateral), escalas reais de brilho/velocidade do K86 e o formato do GET 135.
   Output: extração do layout de luz do registro K86 (`lightLayout:Be`) + literal do SET_SLEDPARAM (8) comentado.
   Desbloqueia: aba de RGB. Avança sem: aba não expõe RGB (mostra "—").

5. **SET_SLEEPTIME (18) real do K86**: payload (bytes das duas horas 24h/BT + deep?) e unidade (min/seg).
   Output: dump comentado.
   Desbloqueia: aba de descanso. Avança sem: só leitura "—".

6. **Parse de bateria**: como o daemon popula `driver.Device.battery`/`DangleCommon` (qual report HID de input, máscara).
   Output: trecho do dump Ghidra/callers ou correspondência com o renderer.
   Desbloqueia: bateria na UI. Avança sem: sem bateria.

7. **Vocabulário de keycodes** (defaultMatrix 0x3151 89 teclas; USB usage codes 4..227 vistos em `5e635fe2.js`) e layout dos 4 bytes/tecla (posição do código, o que os outros 3 bytes fazem).
   Output: `configToMatrix`/`matrixToConfigs` comentados.
   Desbloqueia: remap completo na K86-04. Avança sem: remap não-completo ou somente leitura de diff.

8. **Macro keycode/event format** nos frames de 56 bytes (tipos de evento, timestamps, precisão).
   Output: dump de `buffToMacroEvents` e do encode do macro player.

9. **GET/SET_KBOPTION (134/6) — bits restantes**: **atualizado na rev. 3**: bit 4 (economia de energia, `!!t[4]`, offset ≈7146) resolvido. Faltam os outros bits da resposta e as flags restantes da classe `其他设置.LED` (win-lock, wasd-swap, LED extras), além do payload de SET 6.
   Output: dump comentado do encode/decode.
   Desbloqueia: opções gerais na UI. Avança sem: leitura "—" (exceto bit 4).

## P3 — cosmético

10. **TFT screen pipeline** (apenas se decididamente em escopo o painel RGB no futuro): frame header exato dos 56 bytes já mapeado, mas faltam tipos de conteúdo aceitos.

## Nota das revisões 2, 3 e 5 (erratas/proveniência do complemento)

- Rev. 2: listas físicas `E4` (v2) e `L4` (v3) mapeadas (`index.b078bf5f.js` offset ≈1327315).
- Rev. 5 (complemento do usuário, 2026-11-04): material em `fluidmouse-complemento/` com hashes SHA256 conferidos. **Erratas — o relatório complementar é ORIENTAÇÃO, não oracle; nenhum de seus exemplos serve de golden**:
  - Tabela de versões do complemento e seus valores divergentes em debounce (GET `F1`/91 vs o provado 145 em `438d24dc` @3381; matriz `88` vs o provado 137 (`0x89`) em @4123/@5377) e no checksum de SET `[06,0A]` (o original computa EF, não E9 — conferível por `uh()`).
  - Tabela de perfil do 0x5002 diverge do texto do complemento.
  - A diferença **keymap 512→504 NÃO é resolvida por mera divisão de payload** (compile 8×64 vs 9×56+header): os 8 bytes finais/reservados continuam PRESERVADOS e a escrita segue BLOQUEADA até prova da posição do 504 no cabeçalho real (§3.2 do complemento pede confirmação em hardware).
- Rev. 3 (rastreio da K86-01 — não perguntar ao RE o que está no bundle): comprimentos provados — leitura de matriz 8×64 (offset ≈5410), escrita 9×56 com header `[9, camada, 0xF8, 0x01, seq]` (offset ≈20952); getters de versão/perfil/debounce/autoOS/powerSave resolvidos (ver item 2); estrutura do SET_LEDPARAM provada (item 4). Lacunas restantes realocadas: **ponte 512→504 + stripping do header** (agora dentro de P1-3), LIGHTLIST do K86 (P2-4), SLEDPARAM, SLEEPTIME real, bateria, keycodes/4 bytes por tecla, macro format, bits KBOPTION restantes.
- Nenhum pedido exige token/chave/cloud; nada de rede é implementado no FluidMouse.

## Sem perguntas necessárias

- Checksum, padding, report ID 0: já bancados por `index.b078bf5f.js` (classe `iA`).
- Nenhum pedido de "dump inteiro": peça apenas os trechos citados por símbolo.
