# btkvm

**Um teclado e um mouse para dois computadores, sem cabo, sem software no Mac.**

O PC Linux se apresenta ao Mac como um teclado + mouse Bluetooth. **Super+K** alterna: o teclado e o mouse do PC passam a controlar o Mac e, no próximo Super+K, voltam para o PC. Além disso, o PC funciona como **caixa de som Bluetooth do Mac** (A2DP sink), então você ouve o áudio do Mac nas caixas ou fones do PC.

- Nada para instalar no Mac: ele só vê um teclado e um mouse Bluetooth comuns.
- Sem trocar de tela pela borda do mouse (bom para quem joga no PC).
- O scroll, os botões, as teclas de mídia e a roda horizontal funcionam.
- Se o Mac desconectar enquanto o KVM está ativo, o teclado e o mouse voltam sozinhos para o PC.

> Testado em Nobara 44 (Fedora, GNOME Wayland, PipeWire, BlueZ 5.8x) com um adaptador Realtek RTL8821CE e um MacBook. Deve funcionar em qualquer distro com BlueZ, mas só esse ambiente foi verificado.

## Como funciona

| Peça | O que faz |
|---|---|
| `src/btkvm` | Serviço (root) que registra um perfil HID no BlueZ via D-Bus, abre os sockets L2CAP (PSM 17 e 19), captura teclado/mouse com `EVIOCGRAB` e envia relatórios HID ao Mac. Detecta Super+K sozinho. |
| `systemd/btkvm.service` | Sobe o `btkvm` com o Bluetooth e reinicia se cair (sem limite de tentativas). |
| `systemd/bluetooth.service.d/btkvm.conf` | Inicia o `bluetoothd` com `--noplugin=input,hostname`: o plugin `input` ocupa as portas HID e o `hostname` trocaria a classe do dispositivo. |
| `/etc/bluetooth/main.conf` | O instalador define `Class = 0x0005C0` (teclado+mouse) e `Name` (com backup `.bak-btkvm`). |
| `bin/btkvm-parear` | Deixa o PC visível por 3 min para o Mac parear. |
| `bin/btkvm-iniciar` + `.desktop` | Atalho no menu de aplicativos para reiniciar o serviço se algo falhar. |
| `bin/btkvm-audio` | Faz o PC conectar o perfil de áudio ao Mac, caso a opção de saída Bluetooth suma no Mac. |

O mouse é enviado a ~125 Hz: o Bluetooth clássico não aguenta os 1000 Hz do mouse, então o movimento é acumulado e agrupado.

## Instalação

Dependências (Fedora):

```bash
sudo dnf install python3-dbus python3-evdev python3-gobject bluez
```

Instalar:

```bash
git clone https://github.com/eduardoruisjbv/btkvm.git
cd btkvm
./install.sh            # BTKVM_NAME="Meu PC" ./install.sh  para escolher o nome Bluetooth
```

O instalador pede a senha uma vez (via `pkexec`, ou `sudo` sem ambiente gráfico) e **reinicia o Bluetooth**: fones e outros dispositivos reconectam sozinhos em alguns segundos.

### Primeiro uso

1. `btkvm-parear` no PC (fica visível por 3 minutos).
2. No Mac: **Ajustes do Sistema → Bluetooth →** nome do PC **→ Conectar**. Confirme o código se aparecer.
3. **Super+K** para levar teclado e mouse ao Mac; **Super+K** de novo para voltar.

O endereço do Mac é gravado na primeira conexão em `/var/lib/btkvm/host`.

## Modo dual opcional (LAN + Bluetooth)

O modo HID acima continua sendo o padrão. O modo dual adiciona um agente no Mac,
UDP pela LAN e um serviço RFCOMM próprio no Bluetooth. Os eventos usam chaves
efêmeras por sessão (X25519/HKDF + ChaCha20-Poly1305), contadores cumulativos do
mouse, teclas ordenadas com ACK e snapshots. O áudio continua no A2DP.

```bash
sudo dnf install python3-cryptography
./install.sh --dual
```

O instalador escreve `/etc/btkvm.conf` com `modo = dual` e porta UDP `45873`.
Libere essa porta no firewall do PC para o endereço/rede do Mac. O handshake
anuncia os endereços automaticamente; não é preciso configurar o IP no agente.
IPv4 é suportado nesta versão. Se a LAN estiver indisponível, o RFCOMM continua
como caminho do agente.

Compile e instale as fontes de [mac-agent/](mac-agent/README.md) no Mac e conceda
Acessibilidade, Bluetooth e Rede local. O agente só aceita o PC pareado; o PC
só aceita RFCOMM criptografado do Mac já registrado pelo HID. Faça o pareamento
HID normal antes de instalar o agente.

Super+K negocia por até 3 segundos. Sem agente pronto, usa o HID já conectado.
Se não houver conexão HID, devolve a entrada ao PC antes de tentar reconectar.
No modo agente, 4 segundos sem ACK autenticado causam a queda para HID. O retorno
espera 1 segundo de ACKs estáveis e a confirmação do novo estado. No Mac, o
watchdog solta as teclas após 2 segundos sem mensagens autenticadas.

```bash
btkvm-stats                 # relatório JSON atualizado a cada 5s
journalctl -u btkvm -f
```

Para voltar ao modo original, defina `modo = hid` em `/etc/btkvm.conf` e reinicie
o serviço. Veja o formato dos pacotes e as decisões em [docs/PROTOCOLO.md](docs/PROTOCOLO.md).

**Estado desta implementação:** fontes locais do PC e Mac adicionadas; sintaxe
Python/Bash conferida. O agente Swift ainda não foi compilado no macOS nem os
transportes, permissões, teclas ABNT2, trocas de modo e coexistência com A2DP foram
validados em um Mac real. As taxas são limites de envio, não medições de desempenho.

## Áudio do Mac no PC

O PC já é um receptor A2DP pelo BlueZ + PipeWire. Depois de parear:

- No Mac, abra o seletor de saída de som (Central de Controle → Som) e escolha o PC (tipo **Bluetooth**). O som do Mac sai pelas caixas/fones do PC.
- Se a opção Bluetooth sumir do Mac, rode no PC: `btkvm-audio`. Ele conecta o perfil de áudio ao Mac registrado.

### Opcional: AirPlay (shairport-sync)

Em `extras/airplay/` há uma configuração para o PC também aparecer como destino AirPlay 2 (`shairport-sync` + `nqptp`, que o Fedora não empacota com AirPlay 2, então precisam ser compilados do GitHub). No ambiente testado o AirPlay aparecia no Mac, mas **o Bluetooth A2DP foi o que tocou de forma confiável**; trate o AirPlay como experimental. Portas a liberar no firewall, só para a rede local: `5353/udp`, `7000/tcp`, `319-320/udp`, `32768-60999 tcp+udp`.

## Solução de problemas

| Sintoma | O que fazer |
|---|---|
| Mac não reconecta depois de reset do adaptador Bluetooth | Atalho **KVM Bluetooth (iniciar)** no menu, ou `systemctl restart btkvm` |
| Ver o que o serviço está fazendo | `journalctl -u btkvm -f` |
| Mouse com leves engasgos | Esperado em Bluetooth clássico; veja `adiados por buffer cheio` no log |
| Parear de novo | `btkvm-parear` e conectar pelo Mac |
| Scroll não anda | Atualize para a v0.3.0 (corrige mouses que só emitem scroll de alta resolução) |

## Desinstalar

```bash
./uninstall.sh   # remove tudo e restaura o main.conf do backup
```

## Limitações conhecidas

- Sem área de transferência compartilhada: só teclado, mouse e mídia.
- Um único Mac por vez.
- O áudio do PC para o Mac não é coberto; só o caminho Mac → PC.

## Licença

MIT. Veja [LICENSE](LICENSE). Histórico em [CHANGELOG.md](CHANGELOG.md).
