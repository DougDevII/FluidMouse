# Protocolo Rapoo VT9 Pro (macOS / IOKit)

Especificação byte a byte do canal de configuração do **Rapoo VT9 Pro**,
reunindo o que foi **medido no aparelho** com o que está documentado na
engenharia reversa do driver oficial (`RapooGameDev` 1.6.29) e na
implementação de referência do projeto OpenMouse.

Convém ler antes o [documento de integração](RAPOO_VT9_PRO.md), que explica
por que o transporte no macOS tem as particularidades descritas aqui.

---

## 1. Transporte

| Item | Valor |
| --- | --- |
| Coleção de configuração | usage page `0xFF00`, usage `0x000E` |
| Report de comando | `0xBA` — 31 bytes de report data |
| Report de heartbeat | `0xBB` — 7 bytes, enviado sozinho ~3 s |
| Report proibido | `0x2B` — **ler desconecta o mouse**; nunca tocar |

No macOS (IOKit):

- **Enviar**: `IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 0xBA, buffer, 32)`
  — o buffer **inclui o report ID no byte 0** e o resto são os 31 bytes do
  frame. Sem esse ID à frente, o frame é aceito e ignorado.
- **Receber**: `IOHIDDeviceGetReport(device, kIOHIDReportTypeInput, 0xBA, buffer, &len)`
  — devolve a **última resposta produced pelo aparelho** (slot único).

---

## 2. Frame de comando (31 bytes)

```
[0]  byte de conexão   (0xA5 receptor / 0xFF cabo — o aparelho não valida)
[1]  comando           (0xA4 read, 0xA5 write, 0xAA bateria)
[2]  tamanho do payload
[3..6] endereço, u32 little-endian
[7..30] dados (máx. 24 bytes), completados com zeros
```

Exemplos medidos:

```
read  0x880, 4 bytes:   A5 A4 04 80 08 00 00 00 …
write 0x898, 4 bytes:   A5 A5 04 98 08 00 00 02 00 02 01
bateria:                A5 AA 00 00 00 00 00 …
```

---

## 3. Formas de resposta (medidas)

### 3.1 Resposta de bloco — `4 + N` bytes

Firmware deste aparelho:

```
01 02 64 00 | 08 00 10 00 18 00 18 00 40 00 80 00 08 02 07 00
└┬┘ └┬┘ └┬┘ └┬┘ └──────── payload (16 bytes) ─────────┘
 │   │    │    └─ reservado
 │   │    └────── byte 2 = porcentagem da bateria
 │   └─────────── byte 1 = tipo da resposta (2)
 └─────────────── status (0x01 = respondida, ≠0x01 = busy)
```

Firmware do gen1 (driver oficial / OpenMouse):

```
01 00 00 00 | <payload>
└┬┘ └┬┘ └──── byte 1 = marcador (0 = bloco, ≠0 = bateria)
 │   └───────── byte 2 = porcentagem da bateria
 └───────────── status
```

> **Atenção:** o byte 1 **não** serve para distinguir bloco de bateria no
> firmware atual (vale 2 nos dois casos). A distinção correta é pelo
> **tamanho**: 3 bytes → bateria; `4 + N` → bloco.

### 3.2 Resposta de bateria (3 bytes)

```
01 02 64      → status 1, carregando (2), 64% (100)
01 01 62      → status 1, descarregando (1), 62% (98)  [gen1]
```

### 3.3 ACK de escrita (1 byte)

```
01             → a escrita foi aceita
```

É a única resposta com 1 byte — por isso dá para distinguir o ACK de uma
resposta de leitura que ficou no slot.

---

## 4. Mapa de registradores

Endereços = base do perfil 0 (`0x600`) + offsets do driver oficial. Os
endereços são **iguais** nos dois firmwares; muda o **conteúdo**.

| Endereço | Bytes | Significado |
| --- | --- | --- |
| `0x880` | 4 | polling rate — firmware atual: taxa em `[1]`; gen1: receptor `[0]`, cabo `[2]` |
| `0x884` | 4 | `[0]` lift-off (índice), `[1]` motion sync (1 = ligado) |
| `0x888` | 16 | 7 estágios de DPI (u16 LE) + `[14]` contagem |
| `0x898` | 4 | `[0]` estágio ativo (0-based) |
| `0x8C0` | 4 | `[0]` debounce press, `[1]` debounce release, `[2]` sleep (min), `[3]` flags |
| `0x8C4` | 4 | `[0]` ângulo do sensor (graus) |
| `0x8C8` | 16 | tabela DPI Y (gen1) — neste firmware o bloco responde `FF` |

### Flags de `0x8C0[3]`

| Bit | Significado |
| --- | --- |
| 0 | **angle snap desligado** (1 = desligado) |
| 1 | **ripple control desligado** (1 = desligado) |

### Códigos de polling rate

| Código | Hz |
| --- | --- |
| `0x08` | 125 |
| `0x04` | 250 |
| `0x02` | 500 |
| `0x01` | 1000 |
| `0x84` | 2000 |
| `0x82` | 4000 |
| `0x81` | 8000 (não oferecido pelo VT9 Pro) |

### Debounce

Índice na tabela `[1, 2, 4, 8, 16, 24, 32]` ms (mesma para press e release).

### Escala de DPI

| Firmware | Armazenamento | Exemplo |
| --- | --- | --- |
| gen1 | DPI cru (u16) | `90 01` = 400 … `90 65` = 26000 |
| atual | **DPI ÷ 50** | `08 00` = 8 → 400 … `08 02` = 520 → 26000 |

A escala é inferida pela magnitude dos valores
(`RapooProtocol.inferDpiScale`: acima de 2000 → escala 1; senão escala 50).

### Contagem de estágios

`0x888[14]` guarda **estágios − 1** (`0x07` → 7 habilitados; `0x02` → 3).

---

## 5. Heartbeat `0xBB` (7 bytes)

```
bb b0 42 b0 04 01 64
│  │  │  │  │  └─ bateria (%)
│  │  │  │  └──── carga: 1 = descarregando, 2 = carregando
│  │  │  └─────── constante 0x04
│  │  └────────── link: 0x41 = cabo, 0x42 = receptor 2.4 GHz
│  └───────────── constante 0xB0
└──────────────── report ID
```

Forma do gen1 (report ID ausente ou preservado):

```
b0 51 20 03 <link> <bateria%>          → link 0x01 receptor, 0x02 cabo
51 20 03 <link> <bateria%>              → id removido
```

O heartbeat chega mesmo com o mouse parado **enquanto o link está ativo**; ele
é a melhor prova de que o canal está vivo e de qual link está em uso.

---

## 6. Bateria

Três fontes, com formatos diferentes:

1. **Query `0xAA`** → resposta de 3 bytes (`01 02 64`): carga e porcentagem.
   Não passa pelo handshake busy→OK.
2. **Heartbeat `0xBB`** → byte 6 = porcentagem, byte 5 = carga.
3. **Feature `0x2A`** (coleção `0xFF0B:0x0104`) → byte 9 do report data.
   **Não existe no descritor deste aparelho** — a leitura falha aqui.

---

## 7. Escrita (read-modify-write)

Não existe escrita parcial: o bloco inteiro precisa ser reenviado, com os
bytes desconhecidos preservados.

```
1. ler o bloco (read do endereço)
2. alterar apenas os bytes conhecidos
3. escrever o bloco inteiro (0xA5)
4. reler e conferir
```

Sequência implementada no serviço (`writeBlock`): leitura → mutação → escrita
→ ACK de 1 byte → releitura com verificação byte a byte. A releitura usa a
estratégia "perguntar duas vezes" (seção 8).

---

## 8.armadilhas do canal (medidas)

| Armadilha | Consequência | Solução adotada |
| --- | --- | --- |
| Slot único de resposta | Ler o mesmo registrador 2× devolve bytes idênticos; "resposta nova?" é indecidível | **Perguntar 2×**: a 2ª resposta é do registrador pedido |
| Resposta velha com o mesmo formato | Ler `0x880` logo após `0x898` pode devolver o payload do `0x898` | A releitura repetida resolve; a validação por tamanho ajuda |
| Mouse adormecido | `0xBA` e `0xBB` param; escritas travam no kernel | I/O com timeout, sem descartar o vínculo; o heartbeat volta ao mexer o mouse |
| `Thread` crua | `IOHIDDeviceGetReport` bloqueia para sempre | I/O em `DispatchQueue` |
| Negação silenciosa do TCC | `IOHIDDeviceOpen` "funciona" e nada acontece | `CGPreflightListenEventAccess()` + card de pendência |
| Duas instâncias do app | As instâncias roubam as respostas uma da outra | Guarda de instância única no `AppController` |
| `0x2B` | Desconecta o mouse | Nunca lido |
