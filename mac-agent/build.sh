#!/usr/bin/env bash
set -euo pipefail
AQUI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ "$(uname -s)" = Darwin ] || { echo "Compile este agente no macOS com Command Line Tools." >&2; exit 1; }
APP="$AQUI/build/btkvm-agent.app"
mkdir -p "$APP/Contents/MacOS"
xcrun swiftc -swift-version 5 -O -target "$(uname -m)-apple-macosx11.0" \
  -framework AppKit -framework CoreGraphics -framework IOBluetooth -framework CryptoKit -framework Carbon -framework CoreWLAN \
  "$AQUI/Sources/Protocol.swift" "$AQUI/Sources/Input.swift" "$AQUI/Sources/Agent.swift" "$AQUI/Sources/main.swift" \
  -o "$APP/Contents/MacOS/btkvm-agent"
cp "$AQUI/Info.plist" "$APP/Contents/Info.plist"
# Use the same signing identity and install path for stable macOS permissions.
codesign --force --sign "${BTKVM_SIGN_IDENTITY:--}" --identifier io.github.eduardoruisjbv.btkvm-agent "$APP"
echo "$APP"
