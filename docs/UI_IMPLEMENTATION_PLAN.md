# Plano de implementação da UI macOS — FluidMouse (revisado)

Data: 2026-10-30 (rev. 2, após revisão do líder) · Complemento de: [UI_AUDIT.md](UI_AUDIT.md)
Target: macOS 13+ (sem exigir APIs de macOS 14+ / Liquid Glass) · Padrões: SwiftUI nativo + AppKit onde o SwiftUI não alcança (janela principal, status bar). Fonte de padrões: skill `build-macos-apps/swiftui-patterns` + HIG ["Sidebars"](https://developer.apple.com/design/human-interface-guidelines/sidebars) e ["Settings"](https://developer.apple.com/design/human-interface-guidelines/settings).

## 0. Restrições de produto (fixas, do líder)

1. **Não inventar perfis por dispositivo**: o remapeamento de botões é global por número de botão. A UI comunica isso; nunca sugere "para este mouse".
2. **Não expor registradores desconhecidos como funções suportadas**: `0xBC` e feature `0x2B` ficam intocados; lift-off permanece como "código" até existir escala publicada. 8000 Hz: o codec suporta o código `0x81`, a UI não expõe e a compatibilidade física é desconhecida — manter fora da UI **sem classificar como suportado nem como excluído intencionalmente**.
3. **Não afirmar estado aplicado sem confirmação/releitura** — com importante ressalva do líder: hoje `setDpiTable` **mascara o erro de X** no ramo `scale > 1` (`RapooHidService.swift` L790-792, `error = nil`). Antes de qualquer opção "aplicado" exibir sucesso, a correção de integração (célula UI-00) precisa preservar o primeiro erro.
4. **DPI Y independente não é opção de implementação** sem validação do firmware: manter eixos vinculados (X = Y na tabela grava) e explicar o contrato na UI.
5. Preservar o diff local de `RapooHardwareView.swift` — **preservá-lo basta**; não há autorização nem exigência de commit baseline.
6. Evitar ampliar arquitetura sem ganho: as quatro seções atuais são mantidas, corrigidas e refinadas.

## 1. Arquitetura de informação

```
                    ┌────────────────────────────────────────────┐
 Barra de status    │  Janela de ajustes (única, 880×640         │
 NSStatusItem       │  NavigationSplitView, sidebar + detail)    │
 ─ ícone app/bateria│                                            │
 ─ estado do app    │  ┌─ Sidebar ─────────┐ ┌─ Detail ─────────┐ │
 ─ série mouse      │  │ 1 Ajustes         │ │ A [[Ajustes]]    │ │
 ─ DPI/Hz           │  │ 2 Botões          │ │ B [[Botões]]     │ │
 ─ dormir / atualizar│ │ 3 Mouse           │ │ C [[Mouse]]      │ │
 ─ pausar ajustes   │  │ 4 Teste           │ │ D [[Teste]]      │ │
 ─ permissão        │  └───────────────────┘ └──────────────────┘ │
 ─ ajustes · sair   │  Banner de erro global (topo do detail)    │
                    └────────────────────────────────────────────┘
```

Decisões de arquitetura de informação:

- **4 seções fixas** (Ajustes, Botões, Mouse, Teste), com a permissão de Acessibilidade tratada como cartão persistente que aparece em qualquer seção quando `!trusted` — não como seção própria.
- **Menu de status**: `MenuBarExtra` existe no macOS 13, mas a ordem é **manter o `NSStatusItem` em AppKit** por estabilidade — o menu fixo + atualização de textos é o padrão que resolveu o bug do commit `af02ed5`; migração de scene é decisão opt-in separada.
- Cabeçalho de página por aba (`SectionHeader` + ação contextual) já é o padrão — extrair para componente único reutilizável.

## 2. Wireframes textuais

### 2.1 Ajustes

```
┌──────────────────────────────────────────────────────────────┐
│ ⚠ Cartão permissão (só quando !trusted) — Abrir Acessibilidade…│
├──────────────────────────────────────────────────────────────┤
│ ─[Cartão Suavização]──────────────────────────────────────── │
│ [Interruptor Ativa]  ⏻ Rolagem suave   (novo — espelha menu) │
│ Velocidade    ▬▬▬●▬▬▬▬  2,0×   [campo numérico]              │
│ Suavização    ▬▬▬▬●▬▬▬▬  Equilibrada                         │
│ ─ divider ─                                                            │
│ ⬜ Inverter direção somente do mouse                          │
│    O trackpad mantém a rolagem nativa.                        │
├──────────────────────────────────────────────────────────────┤
│ ─[Cartão Início e modos]──────────────────────────────────── │
│ ⬜ Abrir ao iniciar sessão                                    │
│ (chip "Aguardando autorização" + botão, quando aplicável)     │
│ ℹ Segure ⌥ para usar a rodinha sem suavização.                │
│                     [ Restaurar ajustes ] (confirmação)       │
└──────────────────────────────────────────────────────────────┘
```

### 2.2 Botões

```
┌──────────────────────────────────────────────────────────────┐
│ ─[Cartão Remapeamento]─ subtítulo: global, vale para todos    │
│ 🖱 Mouse reconhecido: Rapoo VT9 Pro (VID …, PID …) (chip)     │
│ [ Identificar botão ] (banner de captura inline quando ativo) │
│ ┌──────────────────────────────────────────────────────────┐ │
│ │ Esquerdo   [ Sem alteração ▾ ]              [◎ identify] │ │
│ │ Direito    [ Tecla ⌘Space ▾ ]               [◎]          │ │
│ │   ↳ editor: ⌘ ⌥ ⌃ ⇧ [tecla] · Apertar e soltar/Ficar…   │ │
│ │ Meio        …                                             │ │
│ │ Extra 1–6   …                                             │ │
│ └──────────────────────────────────────────────────────────┘ │
│ Nota: vale para todos os mice · remapear esquerdo/direito …  │
│                                    [ Limpar tudo ] (confirm) │
└──────────────────────────────────────────────────────────────┘
```

### 2.3 Mouse (VT9 Pro)

```
┌──────────────────────────────────────────────────────────────┐
│ Estados por cartão:                                          │
│ A) permissão pendente · B) ausente · C) dormente · D) legível │
├─ estado D: ─────────────────────────────────────────────────┤
│ ─[Estado]─ bateria + link + PID + "última leitura HH:MM"     │
│ ─[Estágios de DPI]─ 7 linhas: valor único (eixos X/Y          │
│   vinculados — nota: "grava X e Y juntos neste aparelho")     │
│   Estágio ativo [picker] · Estágios habilitados [segment]     │
│   (selo "não aplicado" quando rascunho ≠ mouse)               │
│   [ Aplicar DPI ]  (marcador de operação por id, ver §4)      │
│ ─[Polling]─ receptor [picker] · cabo [picker]                 │
│ ─[Sensor]─ lift-off [picker "Código N"] · motion sync [⏻]     │
│ ─[Timing]─ debounce ×2 [picker ms] · sleep [picker]           │
│           ⬜ angle snap     ⬜ ripple control                  │
│ ▸ Diagnóstico (DisclosureGroup hex + PID)                     │
└──────────────────────────────────────────────────────────────┘
```

### 2.4 Teste

Inalterado em estrutura; pills de estado com ícone contextual + diagnóstico (botão "Zerar contadores" é follow-up opcional).

## 3. Sistema visual adaptativo

Estado atual: a maior parte usa cores/materiais do sistema, **com exceções fixas** — `Design.accent = Color.teal` (`DesignSystem.swift` L11) e tint diretos `Color.teal` em duas views. Ação nesta onda: mover o accent para `Color.accentColor` (ou semântica equivalente) para herdar o tema do sistema; **nenhuma cor fixa nova**; nada de dark mode custom.

Componentes novos em `DesignSystem.swift`:

| Componente | Papel | Nota |
| --- | --- | --- |
| `ErrorBanner(message:dismiss:)` | Cartão de erro no topo do detail, com botão dispensar | Consome `controller.errorMessage`. **Sem retry genérico** — ver §4 R4 |
| `PendingMarker(operationId:)` | Estado "aplicando…" junto ao controle que disparou a escrita | Gancho direto no `OperationState` (§4) — não emulação por status |
| Selo "não aplicado" | Marca o rascunho de DPI pendente de "Aplicar" | `StatusChip` laranja |
| Ícone por estado | `StatusChip` com tint semântico (`red/orange/green`) | padrão novo |

Tipografia: manter os system sizes (11/12/13/15/17) já usados; valores numéricos sempre `.monospacedDigit()`.

## 4. Contratos de estado — remoto (hardware) vs rascunho (UI)

**Rascunho = `@State` local; Remoto = `RapooHidService.Status` via `AppController.rapooStatus`.**

| Regra | Implementação contratada |
| --- | --- |
| R1. Rascunho nunca vaza parcial | Tabela DPI continua sendo aplicada de uma vez por "Aplicar DPI" (rascunho atual preservado) |
| R2. Remoto não sobrescreve rascunho sujo | `syncEditingTables()` roda em `onAppear`/`onChange(status)`, mas só aplica quando **não há rascunho sujo**; se o usuário editou e o status diverge, exibir selo "não aplicado" em vez de sobrescrever silenciosamente |
| R3. **Pendência por operação, não por leitura de status** | `AppController` passa a manter `operationState: [OperationId: OperationResult]` onde cada operação de escrita tem um `id` dado pelo chamador; a conclusão (sucesso/erro) chega pelo **callback** da operação e fica disponível até o próximo uso ou até disconnect (`resetStatus` limpa tudo). **Concorrência impedida**: escritas seguem serializadas (a fila de I/O do serviço já é serial) e o novo pedido do usuário invalida a operação anterior pendente do mesmo controle (sem duas escritas sobrepostas). **Callback de sessão antiga é descartado**: após `resetStatus`/desconexão, um token de geração/época invalida callbacks de operações da sessão anterior — nada atualiza UI com resposta pregressa. **Nunca** esperar "status mudar para o valor pedido": valor idêntico ao atual ou falha deixaria spinner eterno |
| R4. Erro preservado e contextual | Correção UI-00: `setDpiTable` propaga o **primeiro** erro de X (hoje mascarado em `scale > 1`); `ErrorBanner` exibe a mensagem do `RapooError`. "Tentar novamente" do banner é **apenas para operações idempotentes e contextuais** (re-ler status, reconectar) — nunca re-envia escrita de registrador sem contexto |
| R5. Mouse dormiu no meio | `readable == false` → cartão "dormente" substitui as seções de edição; operações pendentes são marcadas como interrompidas (erro de `channelUnresponsive`) |
| R6. Botões: estado é preferência local | `buttonMappings` gravação imediata e síncrona; sem "aplicar" (a captura é a única operação assíncrona) |

## 5. Cronograma por etapas e células (sem estimativas de tempo)

Cronograma de **ordem só**: cada célula inicia quando a anterior está completa e revisada. Valor planejado de entrega: correção de integração → fundação → abas na ordem → acabamento → acessibilidade.

| Etapa | Célula | Tema | Posse de arquivos | Depende de |
| --- | --- | --- | --- | --- |
| 0 | UI-00 | Correção de integração (pré-requisito da UI): `setDpiTable` preserva o primeiro erro de X (remove `error = nil` mascarando); criar superfícies de operação em `AppController` (`operationState`) e testes com doubles | `Services/RapooHidService.swift` (apenas o bloco `setDpiTable` + envoltório de teste), `Stores/AppController.swift` | — |
| 1 | UI-01 | Fundação: sidebar nativa + `ErrorBanner`/`PendingMarker`/selo | `Views/ContentView.swift`, `Views/DesignSystem.swift`, `Stores/AppController.swift` (exposes apenas) | UI-00 |
| 2 | UI-02 | Aba Ajustes | `Views/ScrollSettingsView.swift` | UI-01 |
| 3 | UI-03 | Aba Botões | `Views/ButtonSettingsView.swift` | UI-02 |
| 4 | UI-04 | Aba Mouse: contratos pendente/confirmado com eixos X/Y vinculados | `Views/RapooHardwareView.swift` | UI-03 (+ UI-00 já dentro) |
| 5 | UI-05 | Menu de status + aba Teste | `App/FluidMouseApp.swift`, `Views/ScrollTestView.swift` | UI-04 |
| 6 | UI-06 | Acessibilidade e teclado | rótulos/atalhos em views existentes | UI-05 |

**Registro de posse sobreposta** (transferências explícitas): `DesignSystem.swift` é criado/extendido em UI-01 e passa a ser **somente leitura** para UI-02; se uma célula seguinte precisar editar `DesignSystem.swift` ou `AppController.swift`, a mudança entra na célula como "transferência de posse" declarada (a célula proprietária anterior é marcada como "posse encerrada" e o novo dono é a célula atual). `AppController.swift` muda de dono UI-00 → UI-01 (exposes) → sem posse depois, exceto via transferência declarada.

Critérios de aceite comuns de todas as células: `swift build` e `swift test --scratch-path /private/tmp/FluidMouseTests` executados e verdes (a contagem exata é verificada em execução, não afirmada); nenhuma cor fixa nova; nenhum texto afirmando estado sem confirmação; diff local de `RapooHardwareView.swift` preservado (base do trabalho da UI-04).

## 6. Testes e verificação

- **Testes novos de estado puro (sem HID real)** — exigência da revisão, implementados em UI-00/UI-01 com doubles/stubs (nada de device físico):
  1. `setDpiTable` preserva o **primeiro** erro de X quando a escala é > 1 (hoje: o ramo substitui por `error = nil`);
  2. rascunho DPI sujo + chegada de `status` novo: o sync não sobrescreve a digitação em andamento (rota `syncEditingTables`);
  3. callback de operação com sucesso → `operationState` registra conclusão; com erro → registra erro e limpa na desconexão (`resetStatus`);
  4. binding de `PendingMarker` não fica pendurado quando a escrita retorna erro ou retorna valor idêntico.
- Suíte existente: executar `swift test` e **registrar a contagem real** no relatório da célula (não afirmar número sem execução).
- Verificação manual por célula (`build_and_run.sh --verify`, fora do escopo das células — executada pelo líder/usuário após cada célula): checklist visual por aba, Light/Dark, redimensionamento 760→∞, teclado (Tab, ⌘1–4 **com verificação de fato** — hoje não validado, Esc na captura), VoiceOver nos controles novos.
- Regressões a vigiar: menu de status deixar de responder ao clique (bug já resolvido — não recriar `NSMenu` a cada update); instância duplicada; permissão Input Monitoring.

## 7. Itens fora do escopo obrigatório deste plano

Restrições de produto do líder e follow-ups anotados — nenhum deles é tarefa desta onda:

- Perfis de remapeamento por device (proibido — remapeamento é global).
- Registradores `0xBC` e feature `0x2B` intocados.
- 8000 Hz na UI (aguardando evidência física; codec suporta o código, compatibilidade do aparelho desconhecida).
- Captura de tecla física no editor de teclas (não pedido — o escopo cobre funções já implementadas).
- Atalhos personalizados do macOS nas ações de sistema; brilho em tela externa.
- Notarização/distribuição e sandboxing.
- Migração de `MenuBarExtra`/`Settings` scene (opt-in).
- Botão "Zerar contadores" (follow-up; pode exigir expose em `ScrollService`).
