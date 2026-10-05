#!/usr/bin/env bash
# Instala o btkvm (teclado/mouse do PC no Mac via Bluetooth) e prepara o áudio Mac -> PC.
#
# Uso:   ./install.sh                 (pede a senha via pkexec/sudo só para a parte de sistema)
# Opções por variável de ambiente:
#   BTKVM_NAME=Nome   nome Bluetooth do PC (padrão: hostname)
set -euo pipefail

AQUI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ------------------------------------------------------------ parte root
if [ "${1:-}" = "--root" ]; then
  USUARIO="$2"; NOME="$3"

  bluetoothd=""
  for p in /usr/libexec/bluetooth/bluetoothd /usr/lib/bluetooth/bluetoothd; do
    [ -x "$p" ] && bluetoothd="$p" && break
  done
  [ -n "$bluetoothd" ] || { echo "bluetoothd não encontrado (instale o BlueZ)." >&2; exit 1; }

  install -m755 "$AQUI/src/btkvm" /usr/local/bin/btkvm
  install -m755 "$AQUI/bin/btkvm-parear" /usr/local/bin/btkvm-parear
  install -m755 "$AQUI/bin/btkvm-audio" /usr/local/bin/btkvm-audio
  mkdir -p /var/lib/btkvm

  sed "s|@USUARIO@|$USUARIO|" "$AQUI/systemd/btkvm.service" > /etc/systemd/system/btkvm.service

  mkdir -p /etc/systemd/system/bluetooth.service.d
  sed "s|/usr/libexec/bluetooth/bluetoothd|$bluetoothd|" \
    "$AQUI/systemd/bluetooth.service.d/btkvm.conf" > /etc/systemd/system/bluetooth.service.d/btkvm.conf

  # /etc/bluetooth/main.conf: classe "teclado+mouse" e nome do PC (com backup, idempotente)
  [ -f /etc/bluetooth/main.conf.bak-btkvm ] || cp /etc/bluetooth/main.conf /etc/bluetooth/main.conf.bak-btkvm
  python3 - "$NOME" <<'PY'
import re, sys
nome = sys.argv[1]
caminho = "/etc/bluetooth/main.conf"
linhas = open(caminho).read().splitlines()
alvo = {"Class": "0x0005C0", "Name": nome}
feito = set()
saida, em_general = [], False
for l in linhas:
    sec = re.match(r"\s*\[(.+)\]", l)
    if sec:
        if em_general:
            saida += [f"{k} = {v}" for k, v in alvo.items() if k not in feito]
            feito |= set(alvo)
        em_general = sec.group(1) == "General"
    m = re.match(r"\s*#?\s*(Class|Name)\s*=", l)
    if em_general and m and m.group(1) not in feito:
        saida.append(f"{m.group(1)} = {alvo[m.group(1)]}")
        feito.add(m.group(1))
        continue
    saida.append(l)
if em_general:
    saida += [f"{k} = {v}" for k, v in alvo.items() if k not in feito]
open(caminho, "w").write("\n".join(saida) + "\n")
PY

  systemctl daemon-reload
  systemctl restart bluetooth
  systemctl enable btkvm.service
  systemctl restart btkvm.service
  exit 0
fi

# ---------------------------------------------------------- parte do usuário
USUARIO="${SUDO_USER:-$USER}"
NOME="${BTKVM_NAME:-$(hostname -s)}"

faltam=()
python3 - <<'PY' 2>/dev/null || faltam+=("python3-dbus python3-evdev python3-gobject (módulos dbus, evdev, gi)")
import dbus, evdev, gi
PY
command -v bluetoothctl >/dev/null || faltam+=("bluez")
command -v pkexec >/dev/null || command -v sudo >/dev/null || faltam+=("pkexec ou sudo")
if [ "${#faltam[@]}" -gt 0 ]; then
  echo "Dependências ausentes:" >&2
  printf '  - %s\n' "${faltam[@]}" >&2
  echo "Fedora: sudo dnf install python3-dbus python3-evdev python3-gobject bluez" >&2
  exit 1
fi

mkdir -p "$HOME/.local/bin" "$HOME/.local/share/applications"
install -m755 "$AQUI/bin/btkvm-iniciar" "$HOME/.local/bin/btkvm-iniciar"
sed "s|@HOME@|$HOME|" "$AQUI/desktop/btkvm-iniciar.desktop" > "$HOME/.local/share/applications/btkvm-iniciar.desktop"

echo "Instalando a parte de sistema (vai pedir a senha). O Bluetooth será reiniciado:"
echo "fones e outros dispositivos reconectam sozinhos em alguns segundos."
if command -v pkexec >/dev/null; then
  pkexec "$AQUI/install.sh" --root "$USUARIO" "$NOME"
else
  sudo "$AQUI/install.sh" --root "$USUARIO" "$NOME"
fi

cat <<EOF

Pronto. Próximos passos:
  1. btkvm-parear            (deixa o PC visível por 3 min)
  2. No Mac: Ajustes > Bluetooth > "$NOME" > Conectar
  3. Super+K alterna teclado/mouse entre PC e Mac.
  4. Áudio do Mac no PC: no Mac, escolha "$NOME" como saída de som Bluetooth.
EOF
