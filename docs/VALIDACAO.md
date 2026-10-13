# Validação

Versão do código: **1.0.2**.

## Cobertura automatizada

Os 14 testes existentes cobrem:

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
