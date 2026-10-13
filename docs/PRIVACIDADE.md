# Privacidade

FluidMouse funciona localmente e não usa serviços remotos, bibliotecas de terceiros, conta ou credenciais de API. O código atual não envia dados pela rede.

## Dados utilizados

- **Eventos de rolagem:** distância, direção, tipo de entrada e modificadores são usados para construir a animação.
- **Posição do cursor:** consultada para emitir os frames no local atual e cancelar a animação quando o cursor se afasta.
- **Cliques:** observados apenas para cancelar movimentos de rolagem pendentes.
- **Aplicativos em execução:** a lista do macOS é consultada para verificar se Smoothy está aberto. A troca do aplicativo em primeiro plano cancela a animação.
- **Estado do sistema:** repouso, retorno à atividade e autorização de Acessibilidade controlam o serviço.

Esses dados são processados em memória. O aplicativo não captura eventos de teclado, conteúdo de janelas, texto digitado, arquivos pessoais, senhas ou credenciais. Ele lê o estado dos modificadores para preservar funções como zoom e a opção de rolagem original.

## Persistência e diagnóstico

As preferências de ativação, velocidade, suavização e inversão de direção são salvas em UserDefaults no domínio `br.com.douglas.fluido`. A opção de início automático é gerenciada pelo serviço nativo SMAppService.

Os contadores de eventos da rodinha, entradas contínuas preservadas e frames emitidos ficam em memória e são reiniciados ao encerrar o processo. Os logs de ciclo de vida registram mensagens operacionais genéricas, sem conteúdo das janelas ou coordenadas do cursor.

## Permissão

Acessibilidade permite ao aplicativo interceptar e substituir os eventos da rodinha. A autorização é concedida pelo usuário nos Ajustes do Sistema e pode ser revogada a qualquer momento. O aplicativo verifica a permissão antes de iniciar o serviço e não altera automaticamente as autorizações do macOS.

## Arquivos do repositório

O repositório contém código-fonte, testes, metadados, licença, documentação e script de compilação. Credenciais, material de assinatura privado, preferências pessoais, logs, relatórios da máquina e bundles de desenvolvimento não fazem parte do código publicado. O identificador de bundle é um identificador público de aplicação, não uma credencial.
