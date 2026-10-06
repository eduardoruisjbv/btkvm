#!/usr/bin/env bash
set -euo pipefail
[ "$(uname -s)" = Darwin ] || { echo "Execute no Mac." >&2; exit 1; }
launchctl bootout "gui/$(id -u)/io.github.eduardoruisjbv.btkvm-agent" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/io.github.eduardoruisjbv.btkvm-agent.plist"
rm -rf "$HOME/Applications/btkvm-agent.app"
echo "Agente removido; pareamento e HID continuam disponíveis."
