# Changelog

Formato baseado em [Keep a Changelog](https://keepachangelog.com/pt-BR/1.1.0/) e versionamento semântico.

## [0.3.1] - 2026-10-05

### Corrigido
- **O teclado e o mouse podiam ser enviados ao dispositivo errado.** Qualquer aparelho pareado que abrisse as portas HID (PSM 17/19), como um iPhone, era tratado como "o Mac" e sobrescrevia `/var/lib/btkvm/host`; o Super+K passava a mirar o celular. Agora só o host registrado é aceito; os outros são recusados e aparecem no log (`recusado <endereço>`). Para registrar outro host, apague `/var/lib/btkvm/host` e pareie de novo.

## [0.3.0] - 2026-10-05

Primeira versão pública.

### Corrigido
- **Scroll do mouse não funcionava no Mac.** Mouses acessados por camadas como o OpenLogi emitem a roda só como `REL_WHEEL_HI_RES` (120 unidades = 1 clique) e o `btkvm` só lia `REL_WHEEL`. Agora a roda de alta resolução é lida com acumulador fracionário (vertical e horizontal), e `REL_WHEEL` só é usado em dispositivos sem `HI_RES`, evitando contagem dupla.

### Adicionado
- `install.sh` e `uninstall.sh`: instalação completa com `pkexec`/`sudo`, backup e restauração do `/etc/bluetooth/main.conf`, detecção do caminho do `bluetoothd`.
- `bin/btkvm-audio`: reconecta o perfil de áudio (A2DP sink) ao Mac quando a saída Bluetooth some no seletor do macOS.
- Usuário da sessão configurável (`BTKVM_USER`, preenchido pelo instalador; sem isso usa a sessão ativa do `loginctl`). Antes estava fixo no código.
- Documentação (README), licença MIT e configuração opcional de AirPlay em `extras/airplay/`.

### Alterado
- O nome do serviço HID anunciado por SDP passou a ser genérico (`btkvm Teclado e Mouse`).

## [0.2.1] - 2026-10-04

### Corrigido
- **Queda do serviço após reset do adaptador.** O kernel reinicializava o adaptador RTL8821CE (`hci0` → `hci1`), o socket HCI dava `BrokenPipe` e o serviço esgotava o limite de reinícios do systemd. Agora o `btkvm` descobre o `hciN` sozinho (`achar_adaptador`) e a unit usa `StartLimitIntervalSec=0`.

### Adicionado
- Atalho **KVM Bluetooth (iniciar)** no menu de aplicativos, para reiniciar o serviço quando o Mac não reconecta.

## [0.2.0] - 2026-10-03

### Adicionado
- **`btkvm`: o PC vira teclado + mouse Bluetooth do Mac.** Perfil HID registrado via D-Bus (`ProfileManager1`), sockets L2CAP nos PSM 17/19, captura exclusiva (`EVIOCGRAB`) dos dispositivos de entrada, relatórios de teclado, mouse (16 bits, roda vertical e horizontal) e mídia.
- Super+K detectado pelo próprio serviço; só captura depois que as teclas são soltas, para não prender tecla pressionada.
- Retorno automático do teclado e do mouse ao PC se o Mac desconectar.
- `btkvm-parear` e ajustes do BlueZ (`--noplugin=input,hostname`, `Class = 0x0005C0`).

### Removido
- Input Leap como mecanismo de KVM (trocava de tela pela borda do mouse, indesejado para jogos, e era menos consistente).

## [0.1.0] - 2026-10-02

Protótipo, não distribuído.

### Adicionado
- KVM por rede com Input Leap (PC servidor, Mac cliente).
- Receptor AirPlay 2 no PC com `shairport-sync` + `nqptp` + `avahi`, saída PipeWire, regras de firewall para a rede local e correção de corrida na inicialização (o `shairport-sync` esperava o `nqptp` para não cair no AirPlay 1).
