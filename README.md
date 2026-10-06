# btkvm

**One keyboard and mouse for two computers, wirelessly, with no software on the Mac.**

The Linux PC presents itself to the Mac as a Bluetooth keyboard and mouse. Press **Super+K** to switch the PC keyboard and mouse to the Mac; press it again to switch them back to the PC. The PC can also act as the Mac's **Bluetooth audio receiver** (A2DP sink), so Mac audio plays through the PC's speakers or headphones.

- Nothing to install on the Mac: it sees an ordinary Bluetooth keyboard and mouse.
- No switching desktops by moving the pointer across a screen edge (useful when gaming on the PC).
- Scrolling, mouse buttons, media keys, and horizontal scrolling work.
- If the Mac disconnects while KVM is active, keyboard and mouse input automatically returns to the PC.

> Tested on Nobara 44 (Fedora, GNOME Wayland, PipeWire, BlueZ 5.8x) with a Realtek RTL8821CE adapter and a MacBook. It should work on any BlueZ distribution, but only this setup has been verified.

## How it works

| Component | Purpose |
|---|---|
| `src/btkvm` | Root service that registers a HID profile with BlueZ over D-Bus, opens L2CAP sockets (PSM 17 and 19), captures keyboard and mouse input with `EVIOCGRAB`, and sends HID reports to the Mac. It detects Super+K itself. |
| `systemd/btkvm.service` | Starts `btkvm` with Bluetooth and restarts it if it fails (without a restart limit). |
| `systemd/bluetooth.service.d/btkvm.conf` | Starts `bluetoothd` with `--noplugin=input,hostname`: the `input` plugin occupies the HID ports, and `hostname` would change the device class. |
| `/etc/bluetooth/main.conf` | The installer sets `Class = 0x0005C0` (keyboard + mouse) and `Name`, keeping a `.bak-btkvm` backup. |
| `bin/btkvm-parear` | Makes the PC discoverable for 3 minutes so the Mac can pair. |
| `bin/btkvm-iniciar` + `.desktop` | Application-menu shortcut to restart the service if something fails. |
| `bin/btkvm-audio` | Reconnects the Mac's Bluetooth audio profile if its audio output disappears from macOS. |

Mouse reports are sent at about 125 Hz. Classic Bluetooth cannot sustain a 1000 Hz gaming mouse, so movement is accumulated and batched.

## Installation

Fedora dependencies:

```bash
sudo dnf install python3-dbus python3-evdev python3-gobject bluez
```

Install:

```bash
git clone https://github.com/eduardoruisjbv/btkvm.git
cd btkvm
./install.sh            # Set BTKVM_NAME="My PC" to choose the Bluetooth name
```

The installer asks for your password once (through `pkexec`, or `sudo` without a graphical session) and **restarts Bluetooth**. Headphones and other devices reconnect on their own within a few seconds.

### First use

1. Run `btkvm-parear` on the PC; it remains discoverable for 3 minutes.
2. On the Mac, open **System Settings → Bluetooth**, select the PC's name, and click **Connect**. Confirm the code if prompted.
3. Press **Super+K** to send keyboard and mouse input to the Mac; press it again to switch back.

The Mac's address is saved on the first connection in `/var/lib/btkvm/host`.

## Optional dual mode (LAN + Bluetooth)

The HID mode above remains the default. Dual mode adds an agent on the Mac, UDP over LAN, and a dedicated RFCOMM service over Bluetooth. Events use per-session ephemeral keys (X25519/HKDF + ChaCha20-Poly1305), cumulative mouse counters, ordered key events with ACKs, and state snapshots. Audio continues over A2DP.

```bash
sudo dnf install python3-cryptography
./install.sh --dual
```

The installer writes `mode = dual` and UDP port `45873` to `/etc/btkvm.conf`. Allow this port through the PC's firewall for the Mac's address or network. The handshake advertises addresses automatically, so the agent's IP does not need to be configured. This version supports IPv4. If LAN is unavailable, RFCOMM remains available to the agent.

Build and install the sources in [mac-agent/](mac-agent/README.md) on the Mac, then grant Accessibility, Bluetooth, and Local Network permissions. The agent accepts only the paired PC; the PC accepts RFCOMM only from the Mac registered through HID. Complete normal HID pairing before installing the agent.

Super+K negotiates for up to 3 seconds. If the agent is not ready, btkvm uses the existing HID connection. If HID is disconnected, input is returned to the PC before reconnection is attempted. In agent mode, 4 seconds without an authenticated ACK triggers a fallback to HID. Switching back waits for 1 second of stable ACKs and confirmation of the new state. On the Mac, a watchdog releases keys after 2 seconds without authenticated messages.

```bash
btkvm-stats                 # JSON report, refreshed every 5 seconds
journalctl -u btkvm -f
```

To return to the original mode, set `mode = hid` in `/etc/btkvm.conf` and restart the service. See [docs/PROTOCOLO.md](docs/PROTOCOLO.md) for packet formats and design decisions.

**Implementation status:** PC and Mac source files are included, and Python/Bash syntax has been checked. The Swift agent has not yet been compiled on macOS; transports, permissions, ABNT2 keys, mode switches, and coexistence with A2DP have not been validated on a real Mac. Rates are send limits, not measured performance.

## Mac audio on the PC

The PC is already an A2DP receiver through BlueZ and PipeWire. After pairing:

- On the Mac, open the sound output selector (**Control Center → Sound**) and choose the PC (**Bluetooth**). Mac audio plays through the PC's speakers or headphones.
- If the Bluetooth option disappears on the Mac, run `btkvm-audio` on the PC. It connects the audio profile to the registered Mac.

### Optional: AirPlay (`shairport-sync`)

`extras/airplay/` contains a configuration that also lets the PC appear as an AirPlay 2 destination (`shairport-sync` + `nqptp`; Fedora does not package `nqptp` with AirPlay 2 support, so both must be built from GitHub). In the tested setup, AirPlay appeared on the Mac, but **Bluetooth A2DP was the only path that played reliably**; treat AirPlay as experimental. Allow these ports through the firewall for the local network only: `5353/udp`, `7000/tcp`, `319-320/udp`, `32768-60999/tcp+udp`.

## Troubleshooting

| Symptom | What to do |
|---|---|
| Mac does not reconnect after a Bluetooth adapter reset | Use the **KVM Bluetooth (start)** application-menu shortcut or run `systemctl restart btkvm`. |
| Check what the service is doing | `journalctl -u btkvm -f` |
| Mouse movement stutters slightly | Expected with classic Bluetooth; look for `deferred due to full buffer` in the log. |
| Pair again | Run `btkvm-parear` and connect from the Mac. |
| Scrolling does not work | Upgrade to v0.3.0, which fixes mice that only emit high-resolution scroll events. |

## Uninstall

```bash
./uninstall.sh   # Removes everything and restores main.conf from its backup
```

## Known limitations

- No shared clipboard; only keyboard, mouse, and media controls are supported.
- One Mac at a time.
- PC audio output to the Mac is not covered; only Mac-to-PC audio is supported.

## License

MIT. See [LICENSE](LICENSE). See [CHANGELOG.md](CHANGELOG.md) for the release history.
