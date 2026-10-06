# Changelog

Based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and Semantic Versioning.

## [Unreleased]

### Added
- No code yet; the current HID mode remains unchanged.

## [0.3.1] - 2026-10-05

### Fixed
- **Keyboard and mouse input could be sent to the wrong device.** Any paired device that opened the HID ports (PSM 17/19), such as an iPhone, was treated as "the Mac" and overwrote `/var/lib/btkvm/host`; Super+K then targeted the phone. Only the registered host is now accepted; other devices are rejected and logged (`rejected <address>`). To register a different host, remove `/var/lib/btkvm/host` and pair again.

## [0.3.0] - 2026-10-05

First public release.

### Fixed
- **Mouse scrolling did not work on the Mac.** Mice accessed through layers such as OpenLogi report the wheel only as `REL_WHEEL_HI_RES` (120 units = 1 click), while `btkvm` read only `REL_WHEEL`. High-resolution scrolling is now read with a fractional accumulator (vertical and horizontal); `REL_WHEEL` is used only on devices without `HI_RES`, avoiding double counting.

### Added
- `install.sh` and `uninstall.sh`: complete installation with `pkexec`/`sudo`, backup and restoration of `/etc/bluetooth/main.conf`, and detection of the `bluetoothd` path.
- `bin/btkvm-audio`: reconnects the A2DP sink profile to the Mac if Bluetooth audio disappears from the macOS output selector.
- Configurable session user (`BTKVM_USER`, set by the installer; otherwise uses the active `loginctl` session). It was previously hard-coded.
- Documentation (README), MIT license, and optional AirPlay configuration in `extras/airplay/`.

### Changed
- The HID service name advertised through SDP is now generic (`btkvm Keyboard and Mouse`).

## [0.2.1] - 2026-10-04

### Fixed
- **The service stopped after an adapter reset.** The kernel reinitialized the RTL8821CE adapter (`hci0` → `hci1`), the HCI socket raised `BrokenPipe`, and the service exhausted systemd's restart limit. `btkvm` now discovers the `hciN` adapter itself (`achar_adaptador`), and the unit sets `StartLimitIntervalSec=0`.

### Added
- **KVM Bluetooth (start)** application-menu shortcut to restart the service when the Mac does not reconnect.

## [0.2.0] - 2026-10-03

### Added
- **`btkvm`: the PC acts as the Mac's Bluetooth keyboard and mouse.** Registers a HID profile through D-Bus (`ProfileManager1`), opens L2CAP sockets on PSM 17/19, exclusively captures input devices (`EVIOCGRAB`), and sends keyboard, mouse (16-bit, vertical and horizontal scroll), and media reports.
- The service detects Super+K itself and captures input only after the keys are released, preventing a held key.
- Keyboard and mouse input automatically return to the PC if the Mac disconnects.
- `btkvm-parear` and BlueZ settings (`--noplugin=input,hostname`, `Class = 0x0005C0`).

### Removed
- Input Leap as the KVM mechanism (it switched desktops at the screen edge, which is undesirable for gaming and less consistent).

## [0.1.0] - 2026-10-02

Prototype, not distributed.

### Added
- Network KVM with Input Leap (PC as server, Mac as client).
- AirPlay 2 receiver on the PC using `shairport-sync`, `nqptp`, and `avahi`, with PipeWire output and local-network firewall rules. Fixed a startup race where `shairport-sync` could start before `nqptp` and fall back to AirPlay 1.
