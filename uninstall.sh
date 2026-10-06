#!/usr/bin/env bash
# Remove btkvm and restores BlueZ to its original state (using the main.conf backup).
set -euo pipefail
AQUI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ "${1:-}" = "--root" ]; then
  systemctl disable --now btkvm.service 2>/dev/null || true
  rm -f /etc/systemd/system/btkvm.service /etc/systemd/system/bluetooth.service.d/btkvm.conf
  rm -f /usr/local/bin/btkvm /usr/local/bin/btkvm-parear /usr/local/bin/btkvm-audio
  rm -f /usr/local/bin/btkvm-stats /run/btkvm-dual.json /run/btkvm-dual.json.tmp
  rm -rf /usr/local/lib/btkvm
  if [ -f /etc/btkvm.conf.bak-btkvm ]; then
    mv /etc/btkvm.conf.bak-btkvm /etc/btkvm.conf
  else
    rm -f /etc/btkvm.conf
  fi
  [ -f /etc/bluetooth/main.conf.bak-btkvm ] && mv /etc/bluetooth/main.conf.bak-btkvm /etc/bluetooth/main.conf
  systemctl daemon-reload
  systemctl restart bluetooth
  exit 0
fi

rm -f "$HOME/.local/bin/btkvm-iniciar" "$HOME/.local/share/applications/btkvm-iniciar.desktop"
if command -v pkexec >/dev/null; then pkexec "$AQUI/uninstall.sh" --root; else sudo "$AQUI/uninstall.sh" --root; fi
echo "btkvm removed. The Mac pairing remains stored in BlueZ (run bluetoothctl remove <address> to delete it)."
