#!/usr/bin/env bash
# Install btkvm (PC keyboard/mouse on Mac over Bluetooth) and prepare Mac-to-PC audio.
#
# Usage: ./install.sh                 (prompts for a password via pkexec/sudo for system setup only)
#        ./install.sh --dual          (optional LAN + Bluetooth mode; requires the Mac agent)
# Environment variable options:
#   BTKVM_NAME=Name   PC Bluetooth name (default: hostname)
set -euo pipefail

AQUI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ------------------------------------------------------------ parte root
if [ "${1:-}" = "--root" ]; then
  USUARIO="$2"; NOME="$3"; MODO="${4:-hid}"

  bluetoothd=""
  for p in /usr/libexec/bluetooth/bluetoothd /usr/lib/bluetooth/bluetoothd; do
    [ -x "$p" ] && bluetoothd="$p" && break
  done
  [ -n "$bluetoothd" ] || { echo "bluetoothd not found (install BlueZ)." >&2; exit 1; }

  install -m755 "$AQUI/src/btkvm" /usr/local/bin/btkvm
  install -m755 "$AQUI/bin/btkvm-parear" /usr/local/bin/btkvm-parear
  install -m755 "$AQUI/bin/btkvm-audio" /usr/local/bin/btkvm-audio
  install -m755 "$AQUI/bin/btkvm-stats" /usr/local/bin/btkvm-stats
  install -d /usr/local/lib/btkvm/btkvm_dual
  install -m644 "$AQUI"/src/btkvm_dual/*.py /usr/local/lib/btkvm/btkvm_dual/
  if [ "$MODO" = dual ]; then
    if [ -f /etc/btkvm.conf ] && [ ! -f /etc/btkvm.conf.bak-btkvm ]; then
      cp -a /etc/btkvm.conf /etc/btkvm.conf.bak-btkvm
    fi
    install -m644 "$AQUI/btkvm.conf.example" /etc/btkvm.conf
  fi
  mkdir -p /var/lib/btkvm

  sed "s|@USUARIO@|$USUARIO|" "$AQUI/systemd/btkvm.service" > /etc/systemd/system/btkvm.service

  mkdir -p /etc/systemd/system/bluetooth.service.d
  sed "s|/usr/libexec/bluetooth/bluetoothd|$bluetoothd|" \
    "$AQUI/systemd/bluetooth.service.d/btkvm.conf" > /etc/systemd/system/bluetooth.service.d/btkvm.conf

  # /etc/bluetooth/main.conf: "keyboard+mouse" class and PC name (backed up, idempotently)
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

# ---------------------------------------------------------- user setup
USUARIO="${SUDO_USER:-$USER}"
NOME="${BTKVM_NAME:-$(hostname -s)}"
MODO=hid
case "${1:-}" in
  --dual) MODO=dual ;;
  "") ;;
  *) echo "Usage: $0 [--dual]" >&2; exit 1 ;;
esac

faltam=()
python3 - <<'PY' 2>/dev/null || faltam+=("python3-dbus python3-evdev python3-gobject (dbus, evdev, gi modules)")
import dbus, evdev, gi
PY
if [ "$MODO" = dual ]; then
  python3 -c 'import cryptography' 2>/dev/null || faltam+=("python3-cryptography (dual mode)")
fi
command -v bluetoothctl >/dev/null || faltam+=("bluez")
command -v pkexec >/dev/null || command -v sudo >/dev/null || faltam+=("pkexec or sudo")
if [ "${#faltam[@]}" -gt 0 ]; then
  echo "Missing dependencies:" >&2
  printf '  - %s\n' "${faltam[@]}" >&2
  echo "Fedora: sudo dnf install python3-dbus python3-evdev python3-gobject bluez" >&2
  [ "$MODO" != dual ] || echo "Dual mode: sudo dnf install python3-cryptography" >&2
  exit 1
fi

mkdir -p "$HOME/.local/bin" "$HOME/.local/share/applications"
install -m755 "$AQUI/bin/btkvm-iniciar" "$HOME/.local/bin/btkvm-iniciar"
sed "s|@HOME@|$HOME|" "$AQUI/desktop/btkvm-iniciar.desktop" > "$HOME/.local/share/applications/btkvm-iniciar.desktop"

echo "Installing system components (you will be prompted for your password). Bluetooth will restart:"
echo "Headphones and other devices should reconnect automatically within a few seconds."
if command -v pkexec >/dev/null; then
  pkexec "$AQUI/install.sh" --root "$USUARIO" "$NOME" "$MODO"
else
  sudo "$AQUI/install.sh" --root "$USUARIO" "$NOME" "$MODO"
fi

cat <<EOF

Done. Next steps:
  1. btkvm-parear            (makes the PC discoverable for 3 minutes)
  2. On the Mac: System Settings > Bluetooth > "$NOME" > Connect
  3. Press Super+K to switch the keyboard/mouse between the PC and Mac.
  4. Mac audio on the PC: on the Mac, choose "$NOME" as the Bluetooth audio output.
EOF
if [ "$MODO" = dual ]; then
  echo "Dual mode: build/install mac-agent on the Mac and allow 45873/udp from the Mac on the LAN."
  echo "Details: mac-agent/README.md. Without the agent, the mode uses connected HID as a fallback."
fi
