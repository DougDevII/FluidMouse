# Validação da UI — matriz (ondas UI-00 a UI-06)

Data: 2026-10-30 · Célula: UI-06 · Estado: **etapas do escopo implementadas e com QA parcial do líder**. Esta matriz separa o que foi automatizado, renderizado, executado no app real e o que continua pendente. Nada aqui afirma aprovação física completa.

## Legenda

- **Automatizado**: teste com `swift test`, sem dispositivo e sem app.
- **Render offscreen**: `NSHostingView` renderizado fora de tela e salvo em PNG em `.mece/cells/UI-06/evidence`. Não é screenshot do app.
- **App real (CUA)**: bundle `.mece/cells/UI-06/package/FluidMouse.app` aberto e operado pelo líder via automação de acessibilidade. Ver limites da automação abaixo.
- **Pendente**: não executado.

## Evidência de build e suíte

| Verificação | Resultado |
| --- | --- |
| `swift test --scratch-path /private/tmp/FluidMouseLeaderReview` (líder, independente) | exit 0 · 100 casos no total · 1 pulado · 0 falhas |
| `swift test` (executor) | mesmo resultado: 100 casos, 1 pulado (render, sem variável de ambiente), 0 falhas |
| Distribuição | FluidMouseTests 49 + 1 pulado · FluidMouseEventsTests 9 · FluidMouseCoreTests 41 |
| `codesign --verify --strict` do bundle `package/FluidMouse.app` | exit 0 |

"100 casos" é o total com o pulado. Não são 100 que passaram; o pulado é o teste de renderização, que só roda com `FLUIDMOUSE_UI_EVIDENCE_DIR`.

## Matriz

| Área | Automatizado | Render offscreen | App real (CUA) | Pendente / limite |
| --- | --- | --- | --- | --- |
| Build release e empacotamento | build release concluído; bundle assinado e verificado | — | bundle aberto pelo líder | — |
| **Janela principal** | — | não renderiza offscreen (limite do fixture) | **OK**: modo escuro 880×640 e ampliada 1920×968 sem sobreposição; sidebar com 4 linhas independentes | redimensionar 760 px **não testado** |
| **Navegação ⌘1–4** | — | — | **OK**: cada atalho mudou a seção real | — |
| **Ajustes — velocidade** | parser e commit (`ScrollSpeedDraftTests`) | ajustes escuro e claro | **OK**: via AX `setValue` "2,36" + Enter normalizou para 2.4 e o slider foi a 2.4; restaurado para 2.0 e confirmado | digitação real pelo teclado **não** comprovada (ver limites) |
| **Ajustes — reset** | — | — | **OK**: "Restaurar ajustes" abriu a sheet; Escape cancelou sem aplicar | confirmação de aplicar **não** exercitada |
| **Ajustes — valores persistentes** | — | — | **OK**: após os testes, AX confirmou velocidade 2, suavização 0.5, reverse 0, login 1 | — |
| **Ajustes — Tab** | — | — | **OK parcial**: foco passou sidebar → toggle → campo de velocidade | travessia completa **não** exaustiva |
| **Botões — captura** | helpers de linhas (`ButtonSettingsRowsTests`) | botões claro e escuro | **OK parcial**: "Identificar" mostrou banner; Cancelar habilitado; menus desabilitados durante captura; Escape cancelou e reabilitou | **botão físico não capturado** |
| **Botões — layout** | — | claro e escuro | — | — |
| **Mouse — leitura real** | `RapooPollingReadoutTests`, `RapooDpiDraftTests`, `RapooDebounceWriteTests` | — | **OK, somente leitura**: Rapoo PID 185A, receptor, bateria 92%, estágio 4 com DPI 1600, polling 1000, debounce de soltar "—" visíveis | **nenhuma escrita** feita |
| **Mouse — rascunho DPI** | `RapooDpiDraftTests` (inclui fluxo sem dispositivo) | — | **OK**: estágio 1 de 400 para 450 pelo campo; selo "Alterações não aplicadas" apareceu; ⌘4 e ⌘3 preservaram 450 com "no mouse 400"; Descartar voltou para 400 e desabilitou Aplicar | **Aplicar DPI não clicado** |
| **Mouse — controles de hardware** | — | — | **não** operados | pendente (escrita física) |
| **Menu de status** | `ScrollCaptureStateTests` (textos ≤ 30 caracteres) | — | **não** aberto nem clicado (atalhos do menu principal, sim) | **pendente** |
| **Light / Dark** | — | pares gerados; inspecionados: Ajustes escuro e claro, Botões claro e escuro, Teste claro e escuro, Mouse sem dispositivo claro e escuro | janela real em escuro | janela real em **claro** não testada |
| **VoiceOver** | — | — | **não** falado | **pendente** |
| **Troca cabo/receptor** | — | — | **não** testada | **pendente** |
| **Falha e desconexão físicas** | fluxo sem dispositivo (`deviceMissing`) | — | **não** testadas | **pendente** |
| **Sucesso de gravação HID** | sem teste de integração (exigiria dispositivo) | — | **não** | **pendente** |

## Limites da automação

- Digitação via CUA `typeText`/paste não preencheu o campo pela AX. A velocidade foi definida com `setValue`. Isso é limite da automação, não defeito comprovado do app. Digitação real pelo teclado continua **não** comprovada.
- Não há prova de comportamento de firmware para além dos valores lidos. Os fatos acima não cobrem todos os firmwares.

## Correções desta célula

1. Polling por link: `Status.link` tipado e `RapooPollingReadout.activeHz`. Cabo nunca é presumido a partir de nil.
2. Itens do menu de status sem título (regressão de `af02ed5`) restaurados.
3. `.teal` residual trocado por `Design.accent`.
4. Rótulos e ajudas em modificadores, picker de tecla e pickers de polling/repouso.
5. Captura cancelada ao sair da aba de Botões.
6. Rascunho de velocidade confirmado ao sair da aba de Ajustes.
7. Texto "Dormindo — mova o mouse" encurtado.

## Não validado

- Menu de status aberto e clicado.
- VoiceOver falado.
- Troca cabo/receptor.
- Janela principal em claro, em execução real.
- Redimensionar para 760 px, em execução real.
- Falha e desconexão físicas.
- Captura de botão físico.
- Aplicar DPI e qualquer gravação física (DPI, debounce, polling, sono, etc.).
- Travessia completa de Tab e Shift-Tab.

## Estado de distribuição

- Usuário mantém a cópia original `dist/FluidMouse.app` em execução por preservação.
- Nova build está em `.mece/cells/UI-06/package/FluidMouse.app`, pronta para troca manual.
- Não houve commit, push ou instalação.
