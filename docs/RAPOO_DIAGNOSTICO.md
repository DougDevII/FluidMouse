# Diagnóstico da integração com o VT9 Pro

Guia para investigar quando o FluidMouse **não** reconhece o mouse, não lê os
registradores ou não aplica uma alteração. Registra as causas que já
apareceram — todas resolvidas — para não se repetir o caminho.

## 1. Logs

O serviço escreve na categoria `rapoo` do subsistema `br.com.douglas.fluido`:

```bash
/usr/bin/log stream --info --style compact \
  --predicate 'subsystem == "br.com.douglas.fluido" AND category == "rapoo"'
```

Mensagens úteis:

| Mensagem | Significado |
| --- | --- |
| `vínculo com pid=0x…` | o device foi aberto (o PID indica cabo `0x418A` ou receptor `0x185A`) |
| `0x880: …` / `0x8C0: …` | a varredura de registradores respondeu — **o canal funciona** |
| `notification 0xBB raw: …` | heartbeat recebido (link, carga e bateria) |
| `escrita travada (mouse dormindo?)` | a escrita ficou presa no kernel e foi abandonada |
| `link mudou no heartbeat — re-vinculando` | o cabo/receptor foi trocado; o app troca o device sozinho |
| `IOHIDDeviceOpen recusado` | permissão de Monitoramento de Entrada pendente |

## 2. Probe ao vivo

`script/rapoo_probe.swift` conversa direto com o mouse, sem o app, e imprime
o que o aparelho responde. Útil para separar "o mouse não responde" de "o app
não lê".

```bash
swift script/rapoo_probe.swift            # leitura do mapa + medições
swift script/rapoo_probe.swift --watch    # repete a leitura a cada 2 s
```

O probe testa, em ordem: vínculo do device, leitura dos registradores,
latência da resposta, formato da resposta (bloco vs bateria) e o efeito do
byte de conexão (`0xA5` / `0xFF`).

## 3. Checklist

1. **O app mostra "Permita configurar o mouse"?** → é permissão do TCC.
   Botão **Abrir Monitoramento de Entrada…** → ative o FluidMouse em
   Ajustes → Privacidade e Segurança → Monitoramento de Entrada. Se a entrada
   não aparecer, apague a antiga (aponta para um binário removido) e adicione
   a que está em `/Applications`. Reabra o app depois de conceder.
2. **O app mostra "Cabo USB" ou "Receptor 2.4 GHz" e a bateria, mas os
   registradores ficam vazios?** → o mouse está **adormecido**. O firmware só
   responde `0xBA` com o mouse em movimento: mexa nele por 2–3 segundos e a
   leitura aparece sozinha.
3. **O rótulo de conexão não acompanha a troca de cabo/receptor?** → confira o
   byte de link no heartbeat (`0x41` cabo, `0x42` receptor). O app re-vincula
   sozinho quando ele muda.
4. **O painel Diagnóstico mostra `—` em todos os blocos?** → o canal de
   registros não respondeu: mova o mouse e clique **Atualizar**.
5. **Uma alteração não é aceita?** → toda escrita é confirmada por releitura;
   se o valor não bater, o app mostra "O mouse recusou a alteração de …".
   Compare o bloco no Diagnóstico antes e depois.

## 4. Causas já resolvidas (histórico)

| Sintoma | Causa real | Correção |
| --- | --- | --- |
| Só funcionava no receptor | Resposta do firmware atual é `01 02 <bateria%> 00 <payload>`; o byte 1 não é marcador de bloco | Detecção por **tamanho** da resposta |
| Respostas "novas" nunca chegavam | Slot único: repetir o mesmo registrador devolve bytes idênticos | **Perguntar 2×** e usar a segunda resposta |
| Tudo travava depois de um tempo | `Thread` crua: `IOHIDDeviceGetReport` bloqueia sem run loop | I/O em `DispatchQueue` |
| Congelava ao mover o mouse | `SetReport` para mouse adormecido trava no kernel | I/O com timeout e abandono da chamada |
| Reconhecia e perdia o mouse | Duas instâncias do app disputando o canal | Guarda de instância única |
| Não abria o canal | Negação silenciosa do TCC (o `open` "funciona" e nada acontece) | `CGPreflightListenEventAccess()` + card de pendência |
| Etapa DPI e o valor vinham errados | Resposta velha (bateria) aceita como bloco | Resposta precisa ter `4 + N` bytes |
| Leitura travava o resto do app | Fila serial do protocolo bloqueada por uma escrita | Timeout por operação |

## 5. Coleta para bugs

Ao reportar um problema, anexe:

1. a saída de `log stream` da categoria `rapoo` durante o problema;
2. a saída de `script/rapoo_probe.swift` (com o mouse em movimento);
3. o conteúdo do painel **Diagnóstico** (blocos brutos + PID);
4. o modo de conexão (cabo/receptor) e o que o app oficial mostra.
