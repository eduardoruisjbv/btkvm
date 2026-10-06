# btkvm-agent (macOS)

Swift source for the optional dual-mode receiver. **It has not yet been compiled or validated on macOS.** The PC continues to use HID by default.

## Install on the Mac

Requires macOS 11+ and Command Line Tools (`xcode-select --install`). Copy this repository to the Mac, keep normal HID pairing with the PC, then run:

```bash
cd mac-agent
./install.sh
```

The installer builds an app at `~/Applications/btkvm-agent.app` and registers a user-session LaunchAgent. The default signature is ad hoc. To keep a stable signing identity across rebuilds, use the same development identity:

```bash
BTKVM_SIGN_IDENTITY='Apple Development: Name (ID)' ./install.sh
```

The path and bundle ID are fixed. An ad hoc signature may require you to grant permissions again after rebuilding. No session key is stored on disk.

Grant the app **Accessibility**, **Bluetooth**, and **Local Network** permissions in System Settings. The agent searches paired devices for the dedicated btkvm service; it advertises its IPv4 address and UDP port over Bluetooth. On the PC, install with `./install.sh --dual` and allow `45873/udp` through the firewall for the Mac on the LAN. Without IPv4, RFCOMM remains available.

To run directly with a specific PC, first stop the LaunchAgent:

```bash
launchctl bootout gui/$(id -u)/io.github.eduardoruisjbv.btkvm-agent
~/Applications/btkvm-agent.app/Contents/MacOS/btkvm-agent --host AA-BB-CC-DD-EE-FF
```

Do not run two agent instances. To resume automatic startup:

```bash
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/io.github.eduardoruisjbv.btkvm-agent.plist
```

## Observe current HID

Stop the LaunchAgent and keep `mode = hid` on the PC. Run:

```bash
~/Applications/btkvm-agent.app/Contents/MacOS/btkvm-agent --observe
```

This mode requires **Input Monitoring** and records p95/p99 intervals between observed movement events without injecting input or opening a network connection. Pauses over 100 ms are excluded from the distribution. It does not measure RTT or distinguish HID from other mice; use only the PC's mouse during observation. Log: `~/Library/Logs/btkvm-agent.log`.

## Implemented behavior

- RFCOMM through a dedicated UUID discovered by SDP, with reconnection; nonblocking UDP.
- X25519/HKDF-SHA256, ChaCha20-Poly1305, and replay protection over 128 counters per channel.
- Cumulative mouse state, ordered key/button events with ACKs, and snapshots.
- Confirmed epoch change before injecting the initial state; 2-second watchdog.
- CGEvent for keyboard, pointer, dragging, and scroll wheels; system events for media keys.
- Key repeat, modifiers, click positions, and clamping to active displays.
- When the session disallows injection, the agent stops acknowledging heartbeats so HID takes over on the PC. Sleep and user switching release pressed keys.

If one link drops, operation can continue over the other. A Bluetooth reconnection starts a new session and performs a controlled transition through HID. Audio uses A2DP and is independent of the agent.

## Mac validation still pending

Compilation depends on API signatures imported from the macOS SDK. Still to confirm: build, permissions, RFCOMM pairing/encryption, ABNT2/ISO keycodes, media keys, double-click, scrolling, multiple displays, lock/unlock, sleep/wake, and independent link failures during A2DP audio. Unmapped usages (such as some F21–F24 keys, Pause/Scroll Lock, and media Stop) are logged. Scroll speed and double-click thresholds use initial values that should be tuned through real use.

The optional `CGSSessionScreenIsLocked` signal is not a public API. Detection also combines session notifications, console availability, and secure input; some apps with password fields may cause the HID path to be used.

API references: [BlueZ Profile1](https://bluez.readthedocs.io/en/latest/profile-api/), [IOBluetooth RFCOMM](https://developer.apple.com/documentation/iobluetooth/iobluetoothrfcommchannel), and [CGEvent](https://developer.apple.com/documentation/coregraphics/cgevent).

Remove the agent with `./uninstall.sh`. HID pairing remains on macOS.
