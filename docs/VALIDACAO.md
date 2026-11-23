# Validação

Versão do código: **1.0.2**.

## Cobertura automatizada

A suíte atual tem **50 testes** (41 em `FluidMouseCoreTests` e 9 em
`FluidMouseEventsTests`): 21 são do codec do mouse Rapoo (descritos na seção
abaixo) e os demais cobrem:

- Conservação da distância nos dois eixos e distribuição entre frames.
- Consistência a 60, 90 e 120 Hz.
- Inversão de direção e cancelamento de movimentos pendentes.
- Acúmulo de entradas rápidas e limite de distância pendente.
- Frações de pixel e valores numéricos inválidos.
- Preservação de entradas contínuas, com fase, momentum, modificadores ou marcador próprio.
- Preferência pela distância em pixels fornecida pelo sistema.
- Uso da posição atual do cursor em cada frame, incluindo coordenadas negativas de telas secundárias.
- Fonte de eventos com supressão zero e passagem dos eventos físicos.
- Preservação da distância, modificadores e proteção contra processamento repetido.
- Ausência de frames quando não há posição válida do cursor.

## Mouse Rapoo VT9 Pro (aba Hardware)

A integração com o canal de configuração do Rapoo VT9 Pro tem 21 testes de
codec próprios (`Tests/FluidMouseCoreTests/RapooProtocolTests.swift`), com os
frames medidos no aparelho real: frame de leitura, frame de escrita, resposta
em bloco, resposta de bateria, ACK de escrita de 1 byte, heartbeat de 7 bytes
do firmware atual e do gen1, escala de DPI (crua e dividida por 50), tabela de
debounce, flags de angle snap/ripple e contagem de estágios.

Verificações físicas realizadas no aparelho do usuário (Rapoo VT9 Pro, 1ª
geração, com cabo e com receptor 2.4 GHz):

- leitura de todo o mapa de registradores (`0x880`, `0x884`, `0x888`, `0x898`,
  `0x8C0`, `0x8C4`), confirmando os valores de DPI, polling, lift-off, motion
  sync, estágio ativo e timing;
- escrita com read-back: alteração do estágio ativo (0 ↔ 3) e de um valor da
  tabela de DPI (1200 → 2000 DPI), com o valor original restaurado depois;
- leitura da bateria por duas fontes (query `0xAA` e heartbeat `0xBB`),
  incluindo o estado de carga;
- identificação do link em uso (cabo ou receptor 2.4 GHz) pelo byte de link do
  heartbeat, confirmada pelo usuário;
- verificação do comportamento do firmware: o canal de configuração só responde
  com o mouse em movimento, e o heartbeat deixa de vir quando o mouse dorme.

A descrição detalhada do protocolo, das medições e dos problemas resolvidos
está em [Integração com o VT9 Pro](RAPOO_VT9_PRO.md),
[Protocolo byte a byte](RAPOO_PROTOCOLO.md) e
[Diagnóstico](RAPOO_DIAGNOSTICO.md).

## Verificações de uso

O aplicativo foi compilado e executado em um Mac Apple Silicon. A assinatura local foi verificada, a interface foi inspecionada e a captura de eventos e emissão de frames foram observadas no aplicativo instalado. Um teste manual confirmou rolagem suave com mouse de rodinha convencional e rolagem nativa do trackpad.

A versão 1.0.1 corrigiu o reaproveitamento da posição antiga do cursor durante a animação. A tremida intermitente relatada anteriormente não reapareceu no teste manual realizado após a correção. A versão 1.0.2 alterou o nome para FluidMouse, preservando o motor de rolagem.

## Limites

- Contadores de frames não medem fluidez visual em todos os aplicativos.
- O resultado de um teste manual não demonstra ausência absoluta de recorrência de um sintoma intermitente.
- A inicialização automática usa SMAppService; a opção foi observada habilitada, mas não foi validada com um novo login nessa sessão de testes.
- Não houve teste físico em Mac Intel ou em versões anteriores do macOS.
- Assinatura ad hoc verificada no disco não equivale a notarização para distribuição pública.
- Eventos contínuos são preservados, em vez de suavizados novamente.

## Revisão antes da publicação

Os arquivos de publicação passam por revisão manual de credenciais, caminhos privados, dados da máquina, persistência e acesso à rede, além de varredura com Gitleaks. Uma varredura sem achados informa que nenhum padrão conhecido foi identificado no escopo revisado; não é uma garantia de ausência de qualquer segredo ou vulnerabilidade.

Em 13/10/2026, o código-fonte da versão 1.0.2 e a árvore preparada para publicação foram revisados com **Gitleaks 8.30.1**, sem achados de padrões conhecidos de segredos. A versão do scanner foi obtida de sua release oficial e conferida pelo checksum disponibilizado nela. O checkout preparado também passou nos **14 testes**, na compilação de produção, na validação do Info.plist e na verificação de sintaxe do script.

O código de aplicação, testes, recursos e script foi comparado byte a byte com a versão 1.0.2 local. As mudanças para publicação foram limitadas à documentação, à atribuição pública da licença e às regras de exclusão de arquivos locais.
