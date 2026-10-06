# btkvm dual — especificação do protocolo (implementação local v0.1)

Status: **implementação local em revisão**. Fontes do PC e do agente Swift existem;
o agente ainda precisa ser compilado no macOS e os links/trocas de modo validados
em um Mac real. Não foram executados testes funcionais ou simuladores nesta etapa.
Resultado de uma entrevista de requisitos em 2026-10-05.
O modo atual (HID puro) **não muda** e continua sendo o padrão.

## 1. Objetivo e princípios

Dividir a carga entre dois links (LAN/Wi-Fi e Bluetooth) entre o PC e o Mac, sem que um sobrecarregue o outro, e sem perder o funcionamento "sem software no Mac" como rede de segurança.

1. **O pior cenário manda.** Projetar para o Mac em Wi-Fi 2,4 GHz (rádio e espectro compartilhados com o Bluetooth), sem trocar de banda ou de rede.
2. **Perder pacote não pode custar precisão.** O estado do mouse viaja como contadores cumulativos; pacotes duplicados ou perdidos não alteram o resultado.
3. **Um escritor por vez.** A cada instante, exatamente um caminho (agente ou HID) recebe os eventos. A troca é atômica e solta todas as teclas do caminho antigo.
4. **Evitar falso positivo é mais importante que reagir rápido.** Um teclado parado por alguns segundos incomoda menos que um mouse errático ou em dobro.
5. **Medir antes de afirmar.** Toda decisão de taxa e de failover é observável na telemetria.

## 2. Topologia e camadas

```
        PC (btkvm, root)                         MacBook
 ┌───────────────────────────┐            ┌─────────────────────────┐
 │ evdev (teclado/mouse)     │            │  btkvm-agent (Swift)    │
 │      │                    │            │   injeta via CGEvent    │
 │  núcleo do protocolo      │            │                         │
 │   ├─ A: UDP/LAN ──────────┼── Wi-Fi ───┼─► canal A               │
 │   ├─ B: RFCOMM ───────────┼── BT ──────┼─► canal B   (dedup)     │
 │   └─ C: HID (atual) ──────┼── BT ──────┼─► macOS direto (reserva)│
 └───────────────────────────┘            └─────────────────────────┘
```

| Camada | Canal | Papel | Quando recebe eventos |
|---|---|---|---|
| A | UDP pela LAN, criptografado | primário, baixa latência | modo agente |
| B | RFCOMM Bluetooth próprio, criptografado | espelho + handshake + presença | modo agente (mesmos eventos de A) |
| C | HID Bluetooth (o `btkvm` atual) | última camada, sem agente | só no modo HID; **mudo** no modo agente |

Os canais A e B carregam **as mesmas mensagens** (mesmo `msg_seq`); o agente aplica cada uma uma única vez. O HID nunca é usado ao mesmo tempo que A/B, senão o macOS aplicaria o movimento em dobro.

Áudio: **fora deste protocolo.** O A2DP continua no Bluetooth (Mac e iPhone). O iPhone não participa do agente.

## 3. Estados do PC

```
INATIVO ──Super+K──► NEGOCIANDO ──ACCEPT──► AGENTE ──4 s sem HB_ACK──► HID
   ▲                     │ (timeout 3 s)       │  ▲                      │
   │                     ▼                     │  └──≥1 s de HB_ACK─────┘
   └──Super+K──────── (cai para HID)◄──────────┘
```

- **INATIVO**: teclado/mouse no PC. Heartbeats continuam se houver sessão.
- **NEGOCIANDO**: handshake pelo BT (§5). Se o agente não responder em 3 s, entra direto em **HID** (comportamento de hoje), sem prender o usuário.
- **AGENTE**: eventos vão por A e B.
- **HID**: eventos vão só pelo HID. Heartbeats continuam por A e B para detectar a volta do agente.
- Super+K sempre volta ao PC, de qualquer estado.

`mode_epoch` (u8) incrementa a cada troca AGENTE↔HID. Todo evento carrega a época; o agente descarta eventos de época antiga.

## 4. Formato dos pacotes

Little-endian. Todos os canais usam o mesmo envelope; cada canal tem sua própria sequência de nonce.

```
 0      1      2      3      4                8                 16        16+N      16+N+16
 ┌──────┬──────┬──────┬──────┬────────────────┬─────────────────┬─────────┬─────────┐
 │magic │ ver  │ tipo │canal │  session_id    │   ctr (u64)     │ payload │   tag   │
 └──────┴──────┴──────┴──────┴────────────────┴─────────────────┴─────────┴─────────┘
```

- `magic` = `0xB7`, `ver` = 1, `canal` = 0 (LAN) ou 1 (BT).
- `session_id` (u32): aleatório por sessão; pacote de outra sessão é descartado.
- `ctr` (u64): contador de nonce **por direção e por canal**. Nonce AEAD = `dir(1) ‖ canal(1) ‖ 0x0000 ‖ ctr(8)` (12 bytes).
- Cifra: **ChaCha20-Poly1305**; cabeçalho de 16 bytes (magic até `ctr`) como dados associados. Tag de 16 bytes.
- Replay: janela deslizante de 128 contadores por (direção, canal). Fora da janela ou repetido → descarta.
- Sobre RFCOMM (fluxo de bytes), cada pacote vai precedido de `len` (u16).

### 4.1 Tipos de mensagem

| Tipo | Código | Direção | Conteúdo |
|---|---|---|---|
| `HELLO` | 0x01 | PC→Mac (BT) | chave efêmera X25519 do PC, nonce, porta UDP do PC |
| `ACCEPT` | 0x02 | Mac→PC (BT) | chave efêmera X25519 do Mac, nonce, IP(s) e porta UDP do Mac |
| `MOUSE` | 0x10 | PC→Mac (A e B) | estado cumulativo do ponteiro (§4.2) |
| `EVENTS` | 0x11 | PC→Mac (A e B) | transições de tecla/botão, confiáveis (§4.3) |
| `EVENTS_ACK` | 0x12 | Mac→PC (A e B) | maior `ev_seq` aplicado + máscara dos seguintes |
| `SNAPSHOT` | 0x13 | PC→Mac (A e B) | conjunto completo de teclas/botões pressionados (a cada ~100 ms) |
| `SNAPSHOT_ACK` | 0x14 | Mac→PC (A e B) | confirma a referência inicial da nova época antes dos eventos |
| `HB` | 0x20 | PC→Mac (A e B) | `t_pc_us`, `mode_epoch`, taxa BT atual |
| `HB_ACK` | 0x21 | Mac→PC (A e B) | eco de `t_pc_us`, estatísticas de recepção por canal (§8) |
| `MODE` | 0x30 | PC→Mac (A e B) | `hid_takeover` ou `agent_resume`, com `mode_epoch` novo |
| `MODE_ACK` | 0x31 | Mac→PC | confirma a troca |
| `BYE` | 0x3F | ambos | encerra a sessão |

`HELLO` e `ACCEPT` ainda não têm chave de sessão: vão em claro dentro do link BT criptografado do pareamento (§5), com `session_id` = 0.

### 4.2 `MOUSE` (cumulativo, idempotente)

```
sample_seq u32 | epoch u8 | x_total i32 | y_total i32 | wheel_total i32 | hwheel_total i32 | t_pc_us u32
```

- Os `*_total` são somas desde o início da sessão (aritmética modular de 32 bits).
- O agente guarda o último total aplicado e aplica **a diferença** (`novo - ultimo`, com wrap). Pacote com `sample_seq` mais antigo que o último aceito é ignorado; repetido não faz nada.
- O PC envia sempre os **totais mais recentes**; nunca acumula fila de amostras antigas.
- Roda: o PC converte `REL_WHEEL_HI_RES` (120 = 1 clique) para unidades de 1/120 em `wheel_total`; o agente converte para pixels do `CGEvent`. Isso torna o scroll suave também no modo agente.

### 4.3 `EVENTS` (confiável, ordenado, deduplicado)

```
ev_seq u32 | epoch u8 | n u8 | n × { codigo u16, valor u8 (0/1), x_total i32, y_total i32, sample_seq u32 }
```

- Cobre teclas, teclas de mídia e botões do mouse. Cada evento leva a posição acumulada no momento, para o agente mover o ponteiro até lá **antes** de clicar.
- O PC reenvia por A e B a cada 20 ms até receber `EVENTS_ACK` cobrindo o `ev_seq`; o agente aplica em ordem de `ev_seq` e descarta duplicados.
- `SNAPSHOT` (a cada ~100 ms e a cada troca de modo) reenvia o conjunto completo de pressionadas. Se o agente achar que uma tecla está presa e o snapshot diz que não, solta; se o snapshot diz que está pressionada e o agente perdeu o evento, aplica.

Na implementação, `codigo` é `(HID usage page << 8) | usage`: página 7 para
teclado, 9 para botões e 12 para mídia. O `sample_seq` de cada transição permite
posicionar um clique antes de restaurar uma amostra de mouse que tenha chegado
adiantada. Movimento antigo não faz o ponteiro voltar após um evento mais recente.

`EVENTS_ACK` = `base u32 | bitmap u64 | epoch u8`. O bitmap confirma os pacotes
seguintes já retidos na janela; a aplicação continua ordenada pelo `base`.
ACKs de outra época não removem eventos da fila atual. A fila tem 64 transições;
se esgotar, o PC entra em HID e sincroniza o conjunto físico pressionado.

`SNAPSHOT` = `epoch u8 | n u8 | bootstrap u8 | next_ev_seq u32 | MOUSE(25 B) |
n × codigo u16`. O snapshot periódico só reconcilia o estado depois das
transições anteriores a `next_ev_seq`; snapshots antigos são ignorados. O
snapshot inicial (`bootstrap=1`) define os totais cumulativos sem mover o
ponteiro, evitando reaplicar o movimento que já foi feito pelo HID.
`SNAPSHOT_ACK` tem um único byte (`epoch`). O PC repete a referência inicial
até esse ACK antes de liberar `MOUSE`/`EVENTS`.
Sem essa confirmação por 3 segundos, a ativação volta ao HID mesmo que os
heartbeats estejam respondendo.

## 5. Handshake e chaves (Bluetooth como autenticação invisível)

Acontece sozinho a cada ativação (Super+K de entrada), sem digitar nada:

1. O PC envia `HELLO` pelo canal B (RFCOMM, só aceito sobre **link criptografado do pareamento BT**; conexão sem criptografia é recusada).
2. O Mac responde `ACCEPT` com sua chave efêmera e o **endereço IP e a porta UDP** onde o agente escuta. Isso elimina configuração de IP e descoberta por mDNS.
3. Ambos calculam `segredo = X25519(efêmera_própria, efêmera_remota)` e derivam duas chaves de tráfego (uma por direção) com `HKDF-SHA256(segredo, salt = nonce_pc ‖ nonce_mac, info = "btkvm/1")`.
4. A LAN passa a ser aceita **somente** com pacotes que decifram com essa chave. Pacotes de intrusos na rede Wi-Fi são descartados na primeira checagem de tag.
5. Nova sessão a cada ativação; rechaveamento também após 2³² pacotes ou 1 hora.

Campos implementados em `HELLO`: `public_key[32] | nonce_pc[16] | udp_port u16 |
new_session_id u32`. O cabeçalho do handshake continua com `session_id=0`.
`ACCEPT`: `public_key[32] | nonce_mac[16] | count u8 | udp_port u16 |
count × IPv4[4]`. Até oito endereços; zero permite usar apenas RFCOMM.
O PC tenta os endereços anunciados e fixa o primeiro que devolver ACK com AEAD
válido. IPv6 não está implementado nesta versão.

O serviço RFCOMM usa UUID `8ea6e923-cc7d-4b58-93c5-72eb7376b8f1` e canal 22.
BlueZ exige autenticação; `NewConnection` também verifica `Paired`, endereço do
host HID registrado e `BT_SECURITY >= MEDIUM`. O Mac verifica o pareamento e o
modo de criptografia antes de aceitar um `HELLO`.

Autenticidade: o canal BT já está autenticado e criptografado pelo pareamento Bluetooth, e as chaves efêmeras viajam dentro dele. Nada de longo prazo é guardado em disco nesta versão.

> Limite conhecido: um atacante que consiga se passar pelo Mac no próprio Bluetooth (quebrando o pareamento) obteria a sessão. A fixação de uma identidade de longo prazo (Ed25519) fica como evolução (§12).

## 6. Taxas e adaptação

| Canal | Taxa de `MOUSE` | Observação |
|---|---|---|
| A (LAN) | até ~250 Hz | UDP, sem fila |
| B (BT), normal | ~20–30 Hz (piso) | leve; convive com o A2DP |
| B (BT), degradado | ~125 Hz | só enquanto a LAN estiver ruim |

- **Estimativa de saúde da LAN** (janela de 1 s, a partir do `HB`/`HB_ACK` e das estatísticas de recepção que o Mac devolve): LAN é **degradada** se `perda > 5 %`, ou `RTT p95 > 40 ms`, ou houver intervalo sem resposta `> 100 ms`.
- **Histerese:** entra em degradado imediatamente; volta ao normal após 3 s contínuos de LAN saudável.
- **Sem fila no BT:** se o buffer de saída do RFCOMM estiver acima do limite (`TIOCOUTQ`), a amostra `MOUSE` é **descartada** (os totais do próximo pacote cobrem). `EVENTS` nunca é descartado (fila pequena e limitada, ~64).
- Tamanho: `MOUSE` = 25 B de payload + 16 B de cabeçalho + 16 B de tag = 57 B. A 250 Hz na LAN ≈ 14 KB/s; a 25 Hz no BT ≈ 1,4 KB/s; a 125 Hz no BT ≈ 7 KB/s (o A2DP SBC usa ~40 KB/s).

## 7. Queda para o HID (3ª camada)

- **Gatilho:** nenhum `HB_ACK` autenticado válido, em **nenhum** dos dois canais, por **4 s**. Silêncio é falta de resposta do agente (heartbeat ~10 Hz por canal), não ociosidade do usuário.
- Ao disparar: o PC incrementa `mode_epoch`, envia `MODE{hid_takeover}` (melhor esforço), solta todas as teclas do caminho do agente e liga o HID.
- **Retorno:** ao receber `HB_ACK` válidos por ≥ 1 s contínuo, o PC envia `MODE{agent_resume}`, espera `MODE_ACK`, desliga o HID (todas as teclas soltas) e volta ao modo agente.
- `agent_resume` prepara o agente, mas ainda não injeta. Após `MODE_ACK`, o PC
  esvazia os relatórios de soltura do HID e entrega o snapshot inicial; somente
  então o agente permite a injeção. A negociação inicial usa a mesma confirmação.
- `MODE` é repetido a cada 100 ms até `MODE_ACK`; heartbeats com época mais nova
  também fazem o agente soltar a época anterior. Entrada enfileirada de outra
  época não é enviada. A ausência de conexão HID devolve a entrada ao PC antes
  de iniciar uma tentativa de reconexão, que pode bloquear no Bluetooth.
- **Regra do escritor único:** no modo HID o PC **para** de enviar `MOUSE`/`EVENTS` ao agente (só `HB`/`MODE`), então mesmo que o agente esteja vivo e só os ACKs tenham se perdido, não há movimento em dobro.
- **Vigia no agente:** se o agente ficar > 2 s sem pacote autenticado do PC, solta todas as teclas e botões que ele mesmo pressionou.
- Quando o macOS está na tela de login/bloqueio, o agente de usuário não injeta; o HID cobre esse caso.

## 8. Telemetria

Medida nos dois lados e devolvida no `HB_ACK`:

| Métrica | Onde |
|---|---|
| RTT por canal (p50/p95/p99) | PC |
| perda recebida por canal, duplicados, fora de ordem | Mac, devolvido ao PC |
| `MOUSE` descartados por buffer cheio (BT) | PC |
| tempo em degradado, trocas de modo, quedas para HID | PC |
| `EVENTS` reenviados | PC |
| banda e RSSI do Wi-Fi, estado do Bluetooth | Mac (informativo) |

- Resumo a cada 5 s no `journalctl -u btkvm` e comando `btkvm-stats`.
- `HB_ACK` = `t_pc_us u32 | epoch u8 | received u32 | lost u32 | duplicates u32 |
  out_of_order u32`, reportando o canal em que chegou o HB. Contadores cumulativos
  são comparados em uma janela de 1 segundo para a adaptação. RSSI/banda do Wi-Fi
  são informativos no log do Mac quando o sistema permite consultá-los.
- `/run/btkvm-dual.json` recebe o último resumo; `btkvm-stats` marca relatórios
  com mais de 15 segundos como antigos. Taxas nominais não são latência medida.
- **Linha de base do HID atual:** o agente tem um modo `--observe` (somente escuta, sem injetar, com permissão de Monitoramento de Entrada) que registra o intervalo entre eventos chegando pelo HID. Mostra jitter e engasgos do modo atual para comparar com o dual. Ressalva: o HID não tem RTT; a comparação é por regularidade de chegada e pela contagem "adiados por buffer cheio" que o `btkvm` já registra.

## 9. Agente do Mac (`btkvm-agent`, Swift, binário único)

- Compilado com `swiftc` (Command Line Tools); iniciado no login por um LaunchAgent (`~/Library/LaunchAgents/`).
- Permissões do macOS: **Acessibilidade** (injetar eventos), **Bluetooth** (RFCOMM), **Rede local** (UDP) e, só para `--observe`, **Monitoramento de Entrada**.
- Injeção: ponteiro com `CGEvent` (posição = atual + diferença, limitada à tela), roda com `CGEventCreateScrollWheelEvent2`, teclas com `CGEventCreateKeyboardEvent` (tabela HID usage → keycode do macOS) e teclas de mídia por eventos de sistema.
- Canal B: cliente RFCOMM (`IOBluetooth`) para um UUID de serviço próprio publicado pelo PC; reconecta sozinho.
- Canal A: soquete UDP (`Network.framework`) na porta anunciada no `ACCEPT`.
- Log em `~/Library/Logs/btkvm-agent.log`.
- Assinatura: assinar com identidade estável (mesmo bundle id) para o macOS não revogar as permissões a cada recompilação.

## 10. Organização do código

- `src/btkvm`: integração opcional, preservando o caminho HID padrão. Novo modo selecionado em `/etc/btkvm.conf` (`modo = hid` padrão, `dual`).
- Núcleo do protocolo como módulo puro e testável (sem I/O): serialização, AEAD, dedup, contadores, máquina de estados, adaptação de taxa.
- Transportes separados: LAN (UDP) e BT (RFCOMM via `ProfileManager1` do BlueZ, que o `btkvm` já usa).
- `mac-agent/`: pacote Swift com o agente.
- Instalador: opção `--dual`; sem ela nada muda.

## 11. Testes

Plano de validação futuro. Esta etapa apenas conferiu sintaxe Python/Bash;
as propriedades abaixo ainda não foram demonstradas em simulador ou hardware.

1. **Núcleo, no PC, com simulador de rede** (perda, duplicação, reordenação, atraso, rajada, em cada canal, com semente fixa): propriedades que sempre devem valer:
   - posição final do ponteiro == soma exata dos deltas, qualquer que seja o padrão de entrega;
   - nenhuma tecla fica presa ao fim da sessão, da troca de modo ou da queda de um canal;
   - cada `EVENTS` aplicado exatamente uma vez e em ordem;
   - nenhuma entrega em dobro entre agente e HID em nenhuma sequência de troca de modo.
2. **Cripto**: replay, pacote adulterado, sessão errada, nonce repetido são rejeitados.
3. **Integração no PC**: dois processos locais (PC simulado e "agente" em Python) por loopback.
4. **No Mac**: teste manual guiado (compilar, conceder permissões, rodar `--observe`, depois o dual) com a telemetria como resultado.

## 12. Questões em aberto

- **RFCOMM × L2CAP com flush timeout** no canal B: RFCOMM é um fluxo confiável e pode formar fila quando o rádio está ruim. Um L2CAP com tempo de descarte se comportaria como datagrama (melhor para o mouse). Começar por RFCOMM (API mais simples no `IOBluetooth`) e reavaliar com a telemetria.
- **Identidade de longo prazo** (Ed25519 fixada no 1º pareamento) para endurecer o handshake.
- **Suspensão do Mac** (sleep/wake): reconexão do RFCOMM e novo handshake automáticos.
- **Mais de um Mac** (hoje um host por vez).
- **Mapa de teclas** completo HID usage → keycode do macOS, incluindo teclado ABNT2.
- **Coexistência no rádio do Mac**: se a taxa adaptativa não bastar, avaliar piso mais baixo ou perfil "jogo/trabalho".
- **Metas numéricas** (p99 de latência, teclas presas em N horas): não definidas; a telemetria da linha de base vai orientar.

## 13. Decisões já tomadas (resumo da entrevista)

Agente em Swift · BT com handshake, presença e reserva · 3 camadas com HID mudo · contadores cumulativos · UDP + ACK nas teclas · chave por sessão via BT · taxa do BT adaptativa com piso · A2DP continua no BT · projeto para pior cenário (Mac em 2,4 GHz) · telemetria embutida · gatilho do HID em ~4 s · entrega "tudo de uma vez", com o modo HID atual intacto atrás de uma chave.
