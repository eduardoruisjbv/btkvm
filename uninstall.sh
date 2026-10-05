#!/usr/bin/env bash
# Remove o btkvm e devolve o BlueZ ao estado original (usa o backup do main.conf).
set -euo pipefail
AQUI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ "${1:-}" = "--root" ]; then
  systemctl disable --now btkvm.service 2>/dev/null || true
  rm -f /etc/systemd/system/btkvm.service /etc/systemd/system/bluetooth.service.d/btkvm.conf
  rm -f /usr/local/bin/btkvm /usr/local/bin/btkvm-parear /usr/local/bin/btkvm-audio
  [ -f /etc/bluetooth/main.conf.bak-btkvm ] && mv /etc/bluetooth/main.conf.bak-btkvm /etc/bluetooth/main.conf
  systemctl daemon-reload
  systemctl restart bluetooth
  exit 0
fi

rm -f "$HOME/.local/bin/btkvm-iniciar" "$HOME/.local/share/applications/btkvm-iniciar.desktop"
if command -v pkexec >/dev/null; then pkexec "$AQUI/uninstall.sh" --root; else sudo "$AQUI/uninstall.sh" --root; fi
echo "btkvm removido. O pareamento com o Mac continua guardado no BlueZ (bluetoothctl remove <endereço> para apagar)."
