#!/usr/bin/env bash
set -euo pipefail
AQUI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ "$(uname -s)" = Darwin ] || { echo "Execute no Mac." >&2; exit 1; }
"$AQUI/build.sh"
APP="$HOME/Applications/btkvm-agent.app"
PLIST="$HOME/Library/LaunchAgents/io.github.eduardoruisjbv.btkvm-agent.plist"
mkdir -p "$HOME/Applications" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
launchctl bootout "gui/$(id -u)/io.github.eduardoruisjbv.btkvm-agent" 2>/dev/null || true
[ ! -d "$APP" ] || mv "$APP" "$APP.previous.$(date +%Y%m%d%H%M%S)"
ditto "$AQUI/build/btkvm-agent.app" "$APP"
# plistlib is not required on modern macOS; XML escape the installed path.
EXECUTAVEL="${APP//&/\&amp;}"; EXECUTAVEL="${EXECUTAVEL//</\&lt;}"; EXECUTAVEL="${EXECUTAVEL//>/\&gt;}"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>io.github.eduardoruisjbv.btkvm-agent</string>
<key>ProgramArguments</key><array><string>$EXECUTAVEL/Contents/MacOS/btkvm-agent</string></array>
<key>RunAtLoad</key><true/><key>KeepAlive</key><true/>
<key>ThrottleInterval</key><integer>5</integer>
<key>LimitLoadToSessionType</key><string>Aqua</string>
</dict></plist>
EOF
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "Instalado em $APP. Conceda Acessibilidade/Bluetooth/Rede local nos Ajustes do Sistema."
