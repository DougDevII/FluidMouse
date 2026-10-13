# FluidMouse

Utilitário nativo e gratuito de macOS que transforma os saltos da rodinha do mouse em uma rolagem gradual. Funciona em segundo plano pela barra de menus e preserva a rolagem nativa do trackpad.

## Recursos

- Ajustes de velocidade e suavização.
- Rolagem vertical e horizontal.
- Pausa pelo menu e uso temporário da rodinha sem suavização ao segurar **Option (⌥)**.
- Inversão de direção apenas do mouse.
- Inicialização opcional ao entrar na sessão.
- Área de teste e contadores locais de diagnóstico.
- Processamento local, sem conta, mensalidade ou dependência do Smoothy.

## Requisitos

- macOS 13 ou posterior.
- Xcode ou Command Line Tools com Swift 5.9 ou posterior para compilar.
- Permissão de Acessibilidade para interceptar e substituir os eventos da rodinha.

O código usa somente frameworks nativos da Apple, sem dependências de terceiros. A compilação usa a arquitetura do Mac em que é executada. Os testes de uso até esta versão foram realizados em Apple Silicon; Mac Intel e versões anteriores do macOS não foram testados fisicamente.

## Compilar e instalar

```bash
git clone https://github.com/DougDevII/FluidMouse.git
cd FluidMouse
./script/build_and_run.sh --package
open dist/FluidMouse.app
```

O script gera `dist/FluidMouse.app`, cria o ícone, assina o aplicativo localmente e verifica a assinatura. Para instalar, mova o aplicativo para **Aplicativos** e abra essa cópia antes de conceder a permissão.

A assinatura é **ad hoc**, voltada ao uso local. O aplicativo não tem notarização nem Apple Developer ID para distribuição pública. Recompilações podem exigir renovar a autorização em Acessibilidade.

## Usar

1. Abra **FluidMouse** em Aplicativos.
2. Clique em **Abrir Acessibilidade…** e habilite FluidMouse em Ajustes do Sistema → Privacidade e Segurança → Acessibilidade. O nome desse painel pode variar entre versões do macOS.
3. Encerre o Smoothy, se estiver aberto. FluidMouse aguarda enquanto ele está em execução para evitar processamento duplo. Desative outros suavizadores durante o teste.
4. Confira **Rolagem suave ativa** e experimente a rodinha na aba **Teste de rolagem**.
5. Ajuste **Velocidade** e **Suavização** conforme sua preferência. Se a rolagem avançar demais, reduza a velocidade; para reduzir o deslizamento, diminua a suavização.

Se a entrada já estiver habilitada após uma atualização, mas FluidMouse continuar em **Aguardando Acessibilidade**, remova somente sua entrada e adicione novamente a cópia instalada em Aplicativos.

Fechar a janela mantém o aplicativo funcionando em segundo plano. Para encerrá-lo, use o ícone de mouse na barra de menus → **Sair do FluidMouse**. Marque **Abrir ao iniciar sessão** para iniciá-lo automaticamente.

Segure **Option (⌥)** para usar temporariamente a rodinha sem suavização. Eventos com Control ou Command também passam sem alteração, preservando ações como zoom. Shift continua disponível para rolagem horizontal.

## Funcionamento e limites

O serviço intercepta eventos discretos com um event tap de CoreGraphics. A distância da rodinha é distribuída em pequenos eventos por pixel ao longo do tempo, usando decaimento exponencial e acumuladores por eixo. O temporizador de animação funciona somente enquanto há movimento pendente, com até 120 atualizações por segundo conforme a tela principal.

Entradas repetidas são mescladas. Inverter a direção cancela a animação anterior naquele eixo. Pausar, clicar, mudar de aplicativo, afastar o cursor da posição de rolagem, entrar em repouso ou começar a rolar com o trackpad cancela movimentos pendentes.

**Eventos contínuos e eventos com fase ou momentum são preservados.** A distinção é pelo tipo do evento, não por marca ou identificação USB. Isso mantém o trackpad nativo e dispositivos ou drivers que já fornecem rolagem contínua sem alteração. Não há garantia de suavizar um mouse cujo driver já emite eventos contínuos.

O identificador interno `br.com.douglas.fluido` é mantido para compatibilidade com as preferências das versões anteriores do aplicativo.

## Desenvolvimento e testes

```bash
swift test --scratch-path /private/tmp/FluidMouseTests
./script/build_and_run.sh
```

A pasta temporária evita metadados que alguns provedores de arquivos adicionam aos bundles de teste. Sem argumentos, o script compila em debug e abre o aplicativo. Também oferece `--verify`, `--logs`, `--telemetry` e `--debug`. O script encerra processos FluidMouse e da versão anterior Fluido antes de reconstruir o aplicativo.

| Diretório | Responsabilidade |
| --- | --- |
| `Sources/FluidMouseCore` | Política de entrada e motor de animação |
| `Sources/FluidMouseEvents` | Construção dos frames de CoreGraphics |
| `Sources/FluidMouse/Services` | Captura, temporizador e postagem de eventos |
| `Sources/FluidMouse/Stores` | Preferências, permissões e ciclo de vida |
| `Sources/FluidMouse/App` | Janela e menu da barra de menus |
| `Sources/FluidMouse/Views` | Ajustes e área de teste |
| `Tests` | Testes do motor e regressões dos eventos |
| `Resources` | Metadados e gerador do ícone |

Consulte [privacidade](docs/PRIVACIDADE.md) e [validação](docs/VALIDACAO.md) para conhecer os dados utilizados e os limites dos testes.

## Remover

Desative **Abrir ao iniciar sessão**, encerre o aplicativo e mova FluidMouse de Aplicativos para a Lixeira. Opcionalmente, remova sua entrada em Acessibilidade. As preferências locais podem permanecer sem processos executando.

## Licença

[MIT](LICENSE).
