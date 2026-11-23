# Auditoria de UI do FluidMouse (macOS 13+)

Data: 2026-10-30 · Responsável: agente OpenCode (tarefa #01a18e0e)
Escopo: **análise e planejamento apenas** — nenhum código Swift foi alterado nesta tarefa.

## 1. Baseline git no início da auditoria

- `git status -sb`: `main...origin/main [ahead 3]`
- Commits locais (preservados): `7ac5520` (hardware VT9 Pro), `0047558` (interface padrão macOS + menu de status e bateria), `af02ed5` (fix do menu da barra de status).
- Modificação local preexistente, **preservada sem editar**: `Sources/FluidMouse/Views/RapooHardwareView.swift` (tradução de comentários para pt-BR + novo `pageHeader`, diff não commitado).

Limitações do baseline: nenhuma verificação visual ou em hardware foi executada (proibido nesta tarefa); toda a avaliação de interface é por leitura de código e dos docs de protocolo (`docs/RAPOO_PROTOCOLO.md`, `docs/RAPOO_VT9_PRO.md`, `docs/RAPOO_DIAGNOSTICO.md`, `docs/VALIDACAO.md`).

## 2. Arquitetura atual — papéis por módulo

| Módulo | Arquivos | Papel |
| --- | --- | --- |
| App | `Sources/FluidMouse/App/FluidMouseApp.swift` | `NSApplication` + `AppDelegate`, política `.accessory`, `NSWindow` com `NSHostingView`, `NSStatusItem` com menu em AppKit nativo (não usa `MenuBarExtra`) |
| Stores | `Sources/FluidMouse/Stores/AppController.swift` | Único `ObservableObject` do app: preferências (@Published + `UserDefaults`), reconciliação de permissões/estado a cada 1 s, ponte para `RapooHidService` |
| Views | `ContentView`, `ScrollSettingsView`, `ButtonSettingsView`, `RapooHardwareView`, `ScrollTestView`, `DesignSystem` | Janela de ajustes com `NavigationSplitView` (4 abas) e mini sistema de design |
| Services | `ScrollService`, `ButtonService`, `ButtonActionExecutor`, `DeviceService`, `RapooHidService` | Event taps, execução de ações, listagem de devices, canal HID do VT9 Pro |
| Core | `FluidMouseCore/ScrollEngine`, `ButtonMapping`, `Rapoo/RapooProtocol` | Motor de animação e política, modelo de ações de botões, codec do protocolo Rapoo |

Padrões seguidos: SwiftUI macOS 13+ (`NavigationSplitView`, `List(.sidebar)`, `Picker`, `Toggle`, `DisclosureGroup`), cores/materiais do sistema (sem cores fixas), `@ObservedObject` para o controlador injetado, `@State` para rascunho local (DPI). Fonte de padrões: skill `build-macos-apps/swiftui-patterns`.

## 3. Matriz função → API → controle atual → lacuna → controle proposto

Legenda de status: ✔ implementado · ⚠ experimental (funciona com ressalvas medidas/estáticas, sem validação consolidada) · ✖ não suportado (não prometer na UI).

### 3.1 Ajustes de rolagem (`ScrollSettingsView.swift`)

| Função | API/código | Controle atual (linha) | Lacuna | Controle proposto |
| --- | --- | --- | --- | --- |
| Velocidade ✔ | `AppController.speed` L20; `ScrollService.speed` | `Slider` 0,5–4 ×, passo 0,1 com valor numérico (L20-23) | Sem `TextField` para valor exato; sem rótulo de acessibilidade no valor | Slider + `TextField` numérico espelhado; `accessibilityValue` com "2,0×" |
| Suavização ✔ | `AppController.smoothness` L21 | `Slider` 0–1, passo 0,05 com rótulo qualitativo (L25-34) | Discreto na prática, mas o rótulo "Leve/Equilibrada/Alta" não reflete os 20 passos | Slider com `accessibilityValue` igual ao rótulo; tooltip explicando o efeito |
| Inversão ✔ | `controller.reverse` L22 | `Toggle` com subtítulo (L38-44, `ScrollService` L83) | Nenhuma relevante | Manter; incluir em menu de contexto da linha |
| Pausar ✔ | `controller.enabled` L19 | Indireto: só pelo menu de status (`toggleItem`, `FluidMouseApp` L137) e pelo estado mostrado na aba Teste | Não há interruptor na aba Ajustes — a ação primária está escondida | Interruptor/toggle no topo da aba Ajustes (estado `enabled`), espelhado com o menu |
| Início automático ✔ | `SMAppService` (`setLogin` L152-158) | `Toggle` + chip "Aguardando autorização" + botão "Abrir Ajustes…" (L50-66) | Erro de `setLogin` cai em `errorMessage` que **nunca é exibido** | Alerta/banner de erro global (ver §6) ligado a `controller.errorMessage` |
| Restaurar padrões ✔ | `controller.reset()` L167 | `Button` discreto (L71) | Sem confirmação; vulnerável a clique indevido | `confirmationDialog` antes de aplicar |
| Permissão Acessibilidade ✔ | `AXIsProcessTrusted`/`grantPermission` L144-150 | Cartão laranja com deep-link (L82-100) | Aparece só nesta aba; as outras abas não indicam o estado global | Cartão persistente + estado no menu de status (já existe) e badge na sidebar (§4) |

### 3.2 Remapeamento de botões (`ButtonSettingsView.swift`)

| Função | API/código | Controle atual (linha) | Lacuna | Controle proposto |
| --- | --- | --- | --- | --- |
| Remapeamento global ✔ | `ButtonService.mappings`/`ButtonMappingResolver` | `Menu` por linha com seções Básico/Clique/Rolagem/Sistema/Teclado (L148-175) | **Remapeamento é global por número de botão — não por dispositivo.** UI não deixa isso claro; para mice múltiplos é ambíguo | Texto explícito "vale para todos os mice"; **não inventar perfis por dispositivo** (fora de escopo, registrado como não suportado) |
| Identificar por aperto ✔ | `beginButtonCapture`/`capturedButton` (`AppController` L174-197, `ButtonService` L28-37) | Banner "Aperte o botão físico…" + botões `scope` (L40-51, L129-137) | Durante a captura os demais controles ficam ativos e podem gerar estados confusos; sem contar segue/timeout | Modal/inline com destaque único, "Cancelar" acessível por teclado (Esc), e estado de aguardando visível no ícone do mouse |
| Editor de tecla ✔ | `.key(KeyCombination)` (`ButtonMapping` L45-58), `keyEditor` (L177-220) | Toggles ⌘⌥⌃⇧ + `Picker` de teclas + comportamento Apertar e soltar/Ficar pressionado | Editor abre só quando já existe ação de tecla; teclas fora da lista ANSI (ex.: F13+) impossíveis. Captura da tecla física **fica fora do escopo obrigatório** (o usuário pediu funções já implementadas) | Manter lista atual; melhorar rótulos de acessibilidade; anotar captura de tecla como follow-up futuro |
| Ações de sistema ✔ (parcial ⚠) | `SystemAction` (`ButtonMapping` L18-34), `ButtonActionExecutor.performSystemAction` L96-123 | Menu lista as 15 ações com nomes agradáveis | Atalhos são os padrões do macOS — atalhos customizados não são seguidos; mídia/brilho vêm como NX; brilho só na tela integrada | Rodapé/nota informativa por seção; tooltip nos itens midi/brilho ("comportamento depende do macOS") |
| Limpar tudo ✔ | `clearButtonMappings` L169 | `Button` no fim (L63-68) | Sem confirmação | `confirmationDialog` |
| Lista de 9 botões ✔ | L54-58 | `ForEach` dentro de `ScrollView` com `maxHeight: 250` **aninhado no `ScrollView` externo** | Scroll aninhado gera área de rolagem interna estreita e colisão de gestos | Substituir por `List` natural (ou remover scroll interno e deixar a página rolar) — ver plano fase UI-03 |
| Persistência ✔ | `buttonMappings` L25-33 | `JSONEncoder` → `UserDefaults`, filtrando `.unchanged` | Nenhuma | — |

### 3.3 Hardware VT9 Pro (`RapooHardwareView.swift` — arquivo modificado localmente, fila preservada)

| Função | API/código | Controle atual (linha) | Lacuna | Controle proposto |
| --- | --- | --- | --- | --- |
| Estado/bateria/link ✔ | `RapooHidService.Status` L27-48, heartbeat `0xBB` | Cabeçalho + cartão Estado com ícone de bateria e chips (L125-161) | Quando o channel não responde, bateria pode ficar desatualizada sem aviso | Chip "desde HH:MM" ou "última leitura" quando `readable == false` |
| Estágios de DPI ✔ ⚠ | `decode/encodeDpiTable` (`RapooProtocol` L361-383), `setDpiTable` (`RapooHidService` L778-805) | 7 linhas com `TextField` X/Y + botão "Aplicar DPI" (L179-220) — rascunho local em `@State` sincronizado com `syncEditingTables` (L453-460) | **Lacuna grande (achado estático confirmado na revisão):** X e Y são editáveis na UI, mas `AppController.setRapooDpi` recebe só X e `setDpiTable` grava a mesma tabela nos dois blocos — Y independente não existe. Além disso, no ramo `scale > 1` o código faz `error = nil` (L790-792), **mascarando qualquer erro da escrita X**; não há indicador de rascunho não aplicado nem de escrita em andamento | UI honesta com **eixos vinculados** (contrato atual): campo único de valor por estágio (ou Y desabilitado com nota "grava junto com X"), jamais prometendo X/Y independentes. Selo "não aplicado" enquanto rascunho ≠ status, marcador de operação durante a escrita. Estado "aplicado" só após read-back — e o mascaramento do erro X precisa ser corrigido no serviço (célula UI-00) antes de qualquer afirmação de sucesso |
| Estágio ativo ✔ | `setActiveStage` L807-815 | `Picker` ligado diretamente ao `status.activeStage` (L191-199) | binding set dispara escrita assíncrona; se falhar, o picker volta silenciosamente sem explicação | Picker + estado "aguardando confirmação…" until `status.activeStage`/read-back; erro no banner |
| **8000 Hz** ⚠ | `RapooProtocol.pollingRates` inclui código 0x81 = 8000 Hz (`Protocol` L324-327) | UI oferece 125–4000 Hz (`pollingRates` L16) | O codec suporta 8000 Hz e a UI não expõe; `docs/RAPOO_PROTOCOLO.md` anota "não oferecido pelo VT9 Pro" no estudo do driver, sem evidência física neste aparelho. Não é possível afirmar suporte nem exclusão intencional | Manter fora da UI até haver evidência física; documentar o corte com essa justificativa exata (sem dizer "não suportado pelo hardware") |
| Polling receptor/cabo ✔ ⚠ | `setPollingRate` L755-774, slots `pollingLayout` detectados em runtime (L740-751) | Dois `Picker`s (L249-272) | Mesmo problema de feedback do estágio ativo; layout de slots é inferido (gen1 vs firmware novo) — ⚠ | Mesmo padrão pendente/confirmado; nota experimental para firmware não-gen1 |
| Lift-off ✔ ⚠ | `setLiftOff` L817-825 | `Picker` "Código 0–3" (L279-285) | **O código é exposto sem escala publicada** — rótulo honesto mas pouco utilizável | Manter "Código" + nota de que a altura (0,7–2,0 mm) varia por lote (nota já existe); ⚠ marcado |
| Motion sync ✔ | `setMotionSync` L827-835 | `Toggle` (L286-292) | Nenhuma relevante | — |
| Debounce ✔ | `setDebounce` L837-856 | 2 `Picker`s com tabela ms e "—" para 0xFF (L310-345) | Bom; falha só sem feedback de progresso | Padrão pendente/confirmado |
| Sleep ✔ | `setSleep` L858-874 | `Picker` 1–120 min + alerta para 1 min (L347-358) | Nenhuma | — |
| Angle snap / Ripple ✔ | `setAngleSnapping`/`setRippleControl` L876-910 | 2 `Toggle`s sem labels ocultos (L360-369) | Muito espaçados e sem título descritivo para leitores de tela | `Toggle` com `accessibilityLabel` explicito e agrupamento em `GroupBox` |
| Diagnóstico ✔ | `rawBlocks` L44 do serviço, painel L374-404 | `DisclosureGroup` com blocos hex + PID | Nenhum registrado | Manter, copiável |
| Permissão Monitoramento ✔ | `evaluatePermission` (`RapooHidService` L140-150), `openRapooPermissionSettings` (`AppController` L224-228) | Cartão dedicado com 2 botões (L61-85) | "Tentar novamente" não zera timers visualmente; sem spinner | Spinner + desabilitar botão durante `refreshRapoo` |
| Device ausente ✔ | `resetStatus`/`reattach` | Cartão "Nenhum Rapoo VT9 Pro conectado" (L87-101) | Sem botão para abrir a aba Botões quando o rapoo não responde | Link cruzado opcional |
| Adormecido ✔ | `tickRapoo` adapta watchdog 1,2 s ↔ 5 s (`AppController` L209-218) | Cartão "Configuração dormente" (L163-177) | Bom — texto orienta mover o mouse | Manter |

### 3.4 Menu de barra de status (`FluidMouseApp.swift`)

| Função | API/código | Controle atual (linha) | Lacuna | Controle proposto |
| --- | --- | --- | --- | --- |
| Menu vivo ✔ | `NSStatusItem` + `statusMenu` construído uma vez e atualizado em texto (fix do af02ed5, doc-comment L69-72) | `updateMenu` L132-181 | Itens desabilitados (headers) ainda aparecem no clicar; `sleepingItem` mostrado quando `readable == false` (L146) bom | OK; renomear header "Mouse" apenas quando houver mouse |
| Pausar/ativar ✔ | `controller.enabled.toggle()` L222 | `toggleItem` "Pausar suavização"/"Ativar suavização" (L137) | Faltam ícones de estado (`playpause`) | `NSImage(systemSymbolName:)` no toggle |
| Bateria no ícone ✔ | `statusSymbol` L184-193 | Ícone da bateria do mouse substitui o do app | Nenhuma | — |
| Atualizar mouse ✔ | `refreshRapoo()` L220 | `refreshItem` "Atualizar" (visível quando `rapoo != nil`) | Item não explica o que atualiza | "Atualizar leitura do mouse" |
| Permissão ✔ | `permissionItem` (L138, hidden quando `trusted`) | Item "Conceder Acessibilidade" | Nenhum | — |
| Sair ✔ | `quitItem` L226 | Texto padrão | Nenhum | — |

### 3.5 Teste (`ScrollTestView.swift`)

| Função | API/código | Controle atual (linha) | Lacuna | Controle proposto |
| --- | --- | --- | --- | --- |
| Lista de teste ✔ | `ScrollView`+`LazyVStack` L17-40 | Lista fictícia com 60 linhas e barra de comparação | Bom | Manter |
| Estado ✔ | `controller.status` | `StatusChip` verde/secondary (L43-45) | O texto bruto do status ("Feche o Smoothy para ativar") em pill pequeno | Pill com ícone contextual + versão completa no tooltip |
| Diagnóstico ✔ | contadores L38-40 | 3 `SummaryRow` (L53-62) | Zera apenas em re-captura; sem botão zerar | Botão "Zerar contadores" (fase opcional) |

### 3.6 Shell da janela (`ContentView.swift`, `FluidMouseApp.swift`)

| Função | API/código | Controle atual (linha) | Lacuna | Controle proposto |
| --- | --- | --- | --- | --- |
| Janela ✔ | `NSWindow` + `NSHostingView` (`showSettings` L50-65) | 880×640, titlebar transparente, minimizável/redimensionável | É um app accessory; janela criada manualmente — funciona, mas foge de scene idiomáticas; sem `commands` de menu | Manter o caminho AppKit (seguro para o fluxo atual) **ou** migrar p/ `Window`/`MenuBarExtra` como fase opt-in; se migrar, rever Chat/ativar janela |
| Sidebar ✔ | `NavigationSplitView` + `List(.sidebar)` (L34-70) | Todas as linhas ficam **dentro de um único `VStack`** na `List` (L48-67; `tag`+`keyboardShortcut` por item) | Seleção visual nativa não funciona por linha: a `List` tem uma linha só — selection highlight, foco e acessibilidade degradam | Reescrever como linhas soltas na `List` (uma `Label` por aba, `tag` direto) — fundação da fase UI-01 |
| Badges ✔ | `StatusChip` na sidebar L73-90 | Bateria/count/ativo por aba | Info-diversão; ok | Manter, mover detalhes para cards |
| Atalhos ⌘1–4 ⚠ | `keyboardShortcut` computado por `firstIndex` L64-65 | Aplicados a linhas de `HStack` dentro de um único item da `List` — **não são ações de `Button` nem itens de menu**; sem execução do app não há como afirmar que eles levam a seleção à linha correspondente. Hack frágil (crash se `firstIndex` for nil) | Comportamento **não validado** (achado estático) | Reescrever com shortcuts explícitos por enum em linhas nativas e **verificar a ação em execução** antes de marcar como funcionando |
| Erros ✖→✔ proposto | `controller.errorMessage` (`AppController` L51, set em `setLogin`/`rapooFailure`) | **Nenhum lugar da UI exibe `errorMessage`** — principal lacuna da experiência | Usuário recebe falhas de escrita HID silenciosamente | `ErrorBanner` global (cartão laranja/vermelho no topo do conteúdo) + option "Tentar novamente" |
| Sobre o app ⚠ | `showSettings` como "Sobre" (L29) | Reabre a janela | Sem painel About nativo | `NSApplication.orderFrontStandardAboutPanel` (opcional) |

## 4. Estados de conexão / permissão / erro / pendente / sucesso

| Estado | Onde muda | Representação atual | Cobertura |
| --- | --- | --- | --- |
| Aguardando Acessibilidade | `AppController.reconcile` L130 | `status` string + cartão na aba Ajustes | Parcial (só visível em 1 aba) |
| Smoothy em execução | L129 | string | Fraca (só texto na pill da aba Teste) |
| Mac em repouso | L131 | string | Fraca |
| Permissão de entrada pendente | `RapooHidService.Status.permissionPending` | Cartão dedicado | Boa |
| Device ausente | `status == nil` | Cartão dedicado | Boa |
| Adormecido | `readable == false` | Cartão + item do menu | Boa |
| Escrita em andamento | callbacks `set*` | **nenhuma** | Falta |
| Escrita confirmada | `patchStatus` só em sucesso | **na indireta** (status muda via read-back) | Correta, mas invisível ao usuário (não há sinal positivo) |
| Escrita recusada | `RapooError.writeRejected` → `errorMessage` | **invisível** | Falta — nenhum lugar da UI exibe `errorMessage` |
| Canal sem resposta | `.channelUnresponsive` → `errorMessage` | invisível | Falta |
| Início automático pendente | `loginNeedsApproval` | chip + botão | Boa |

Conclusão: os estados **pré-execução** são bons; os estados **durante/depois de escritas** são o maior buraco (sem spinner, sem confirmação positiva, sem erro visível).

## 5. Acessibilidade e teclado (estado atual)

- **Acessibilidade automática**: controles nativos com texto visível (`Toggle("Angle snapping")`, `Picker("Lift-off (código)")` antes de `labelsHidden()`, botões com título) têm rótulos derivados do sistema. O problema é concentrado em: (a) `Slider` sem `accessibilityValue`; (b) controles com `.labelsHidden()` (a maioria dos `Picker`s de `RapooHardwareView` — rótulo existe no código mas não é acessado); (c) botões só de ícone (`scope` tem `.help` L137, rótulo Role). `Color.accent` fixa em `.teal` (`DesignSystem` L11) — substituir por `Color.accentColor`/semântica para herdar o tema do sistema no futuro.
- Fluxo "identificar por aperto" é **inacessível sem mouse** (por definição precisa de um botão físico — ok), mas o cancelamento deve ter caminho de teclado.
- A sidebar com todas as linhas dentro de um único `VStack` quebra a seleção nativa e o foco de `VoiceOver` por item.
- Contraste: nenhuma checagem executada nesta auditoria (sem inspeção visual); o uso de cores do sistema na maior parte do app reduz o risco, com a exceção do `accent` fixo `.teal`.

## 6. Classificação implementado / experimental / não suportado

**Implementado:** suavização (velocidade, suavização, inversão), Option bypass, remapeamento global de botões, identificar por aperto, tecla + modificadores + comportamento tap/hold, ações de sistema padrão, reconhecimento de mice, VT9 Pro: leitura e escrita de DPI (X), estágio ativo, polling (receptor e cabo), lift-off (código), motion sync, debounce, sleep, angle snap, ripple, bateria, link, diagnóstico bruto, iniciar no login. Aderência ao tema do macOS é **parcial** (cores/materiais do sistema na maior parte, com `accent` fixo `.teal`).

**Experimental (funciona com ressalvas, sem validação consolidada):** tabela DPI Y independente — **não existe**: a UI mostra campos Y, mas a gravação usa a tabela de X e pode mascarar erro de X (L790-792); escala de DPI inferida (`inferDpiScale` L299); layout de slots de polling inferido (L740-751); bateria via feature `0x2A` (fallback — **não existe no descritor deste aparelho** segundo `docs/RAPOO_VT9_PRO.md`; gen1), notificações do firmware gen1, lift-off como "código sem escala", firmware diferente de 1ª geração, atalhos ⌘1–4 da sidebar (não verificados em execução).

**Não suportado (não prometer):** perfis por dispositivo (remapeamento é global — decisão do produto), registradores `0xBC` e feature `0x2B` (intocados de propósito), atalhos personalizados do macOS nas ações de sistema, brilho em telas externas, aceleração da rodinha por app, notarização/distribuição. 8000 Hz fica **fora de classificação** (codec suporta, UI não expõe, compatibilidade física desconhecida — não afirmar nem suporte nem exclusão intencional).

## 7. Limitações da auditoria

- Sem inspeção visual (não abrir o app neste escopo): tudo deduzido do código.
- Sem hardware: o registro de verificação física do autor está em `docs/VALIDACAO.md` (sem atribuir os achados a versões específicas); os estudos de VT9 Pro derivam dos docs de protocolo.
- Contadores de teste/fluidez não reprodutíveis aqui.
- Diferenças de firmware (gen1 vs " novo") podem divergir do que a UI assume hoje; as escolhas conservadoras não escondem funções mas rotulam incerteza.
