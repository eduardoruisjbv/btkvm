# btkvm-agent (macOS)

Fontes Swift do receptor opcional do modo dual. **Ainda não compiladas ou
validadas no macOS nesta etapa.** O PC continua usando HID por padrão.

## Instalar no Mac

Requer macOS 11+ e Command Line Tools (`xcode-select --install`). Copie este
repositório para o Mac, mantenha o pareamento HID normal com o PC e execute:

```bash
cd mac-agent
./install.sh
```

O instalador compila uma aplicação em `~/Applications/btkvm-agent.app` e registra
um LaunchAgent da sessão de usuário. Por padrão a assinatura é ad hoc. Para
manter uma identidade de assinatura estável em recompilações, use a mesma
identidade de desenvolvimento:

```bash
BTKVM_SIGN_IDENTITY='Apple Development: Nome (ID)' ./install.sh
```

O caminho e o bundle id são fixos. A assinatura ad hoc pode exigir conceder
permissões novamente depois de recompilar. Nenhuma chave de sessão fica no disco.

Conceda **Acessibilidade**, **Bluetooth** e **Rede local** à aplicação nos Ajustes
do Sistema. O agente procura nos dispositivos pareados o serviço próprio do
btkvm; ele anuncia seus IPv4 e sua porta UDP pelo Bluetooth. No PC, instale com
`./install.sh --dual` e libere `45873/udp` para o Mac na LAN. Sem IPv4, o caminho
RFCOMM permanece disponível.

Para executar diretamente com um PC específico, primeiro pare o LaunchAgent:

```bash
launchctl bootout gui/$(id -u)/io.github.eduardoruisjbv.btkvm-agent
~/Applications/btkvm-agent.app/Contents/MacOS/btkvm-agent --host AA-BB-CC-DD-EE-FF
```

Não execute duas instâncias do agente. Para voltar ao início automático:

```bash
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/io.github.eduardoruisjbv.btkvm-agent.plist
```

## Observar o HID atual

Pare o LaunchAgent e mantenha `modo = hid` no PC. Execute:

```bash
~/Applications/btkvm-agent.app/Contents/MacOS/btkvm-agent --observe
```

Esse modo requer **Monitoramento de Entrada** e registra p95/p99 dos intervalos
de movimento observados, sem injeção nem conexão de rede. Pausas acima de 100ms
são excluídas da distribuição. Não mede RTT nem distingue HID de outros mouses;
use somente o mouse do PC durante a observação. Log: `~/Library/Logs/btkvm-agent.log`.

## Comportamento implementado

- RFCOMM pelo UUID próprio, consultado por SDP, com reconexão; UDP não bloqueante.
- X25519/HKDF-SHA256, ChaCha20-Poly1305, replay de 128 contadores por canal.
- Mouse cumulativo, eventos de tecla/botão ordenados com ACK e snapshots.
- Troca de época confirmada antes de injetar o estado inicial; watchdog de 2s.
- CGEvent para teclado, ponteiro, arraste e rodas; eventos de sistema para mídia.
- Repetição de teclas, modificadores e posição dos cliques; limite aos monitores ativos.
- Quando a sessão não permite injeção, deixa de confirmar heartbeats para acionar
  o HID no PC. Suspensão e troca de usuário soltam as teclas.

A queda de um link permite continuar no outro. Uma reconexão Bluetooth começa
uma nova sessão e faz uma transição controlada pelo HID. O áudio usa A2DP e não
participa do agente.

## Validação pendente no Mac

A compilação depende das assinaturas importadas pelo SDK do macOS. Ainda faltam
confirmação de compilação, permissões, pareamento/criptografia RFCOMM, keycodes
ABNT2/ISO, mídia, clique duplo, scroll, monitores múltiplos, bloqueio/desbloqueio,
sleep/wake e falhas independentes dos links durante áudio A2DP. Usages sem mapa
(como algumas teclas F21–F24, Pause/Scroll Lock e Stop de mídia) são registrados
no log. A velocidade do scroll e o limiar de clique duplo usam valores iniciais
que devem ser ajustados com uso real.

O sinal opcional `CGSSessionScreenIsLocked` não é uma API pública. A detecção
combina também notificações da sessão, disponibilidade do console e entrada
segura; alguns aplicativos com campos de senha podem provocar uso do HID.

Referências das APIs: [BlueZ Profile1](https://bluez.readthedocs.io/en/latest/profile-api/),
[IOBluetooth RFCOMM](https://developer.apple.com/documentation/iobluetooth/iobluetoothrfcommchannel),
[CGEvent](https://developer.apple.com/documentation/coregraphics/cgevent).

Para remover o agente: `./uninstall.sh`. O pareamento HID continua no macOS.
