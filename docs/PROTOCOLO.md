# btkvm dual — protocol specification (local implementation v0.1)

Status: **local implementation under review**. PC and Swift agent sources exist; the agent still needs to be compiled on macOS, and the links and mode switches need validation on a real Mac. No functional tests or simulators were run at this stage. Based on a requirements interview on 2026-10-05. The current pure HID mode **does not change** and remains the default.

## 1. Goal and principles

Split the load across two links (LAN/Wi-Fi and Bluetooth) between the PC and Mac so neither link is overloaded, while keeping the current “no software on the Mac” path as a safety net.

1. **Design for the worst case.** Assume the Mac is on 2.4 GHz Wi-Fi (radio and spectrum shared with Bluetooth), with no band or network change.
2. **Packet loss must not cost accuracy.** Mouse state is sent as cumulative counters; duplicated or lost packets do not change the result.
3. **One writer at a time.** Exactly one path (agent or HID) receives events at any instant. Switching is atomic and releases all keys on the old path.
4. **Avoid false positives before reacting quickly.** A keyboard paused for a few seconds is less disruptive than an erratic or doubled mouse.
5. **Measure before making claims.** Every rate and failover decision is observable in telemetry.

## 2. Topology and layers

```
        PC (btkvm, root)                         MacBook
 ┌───────────────────────────┐            ┌─────────────────────────┐
 │ evdev (keyboard/mouse)    │            │  btkvm-agent (Swift)    │
 │      │                    │            │   injects via CGEvent   │
 │  protocol core            │            │                         │
 │   ├─ A: UDP/LAN ──────────┼── Wi-Fi ───┼─► channel A             │
 │   ├─ B: RFCOMM ───────────┼── BT ──────┼─► channel B (dedup)     │
 │   └─ C: HID (current) ────┼── BT ──────┼─► direct to macOS (backup)│
 └───────────────────────────┘            └─────────────────────────┘
```

| Layer | Channel | Role | When it receives events |
|---|---|---|---|
| A | Encrypted UDP over LAN | Primary, low latency | Agent mode |
| B | Dedicated Bluetooth RFCOMM, encrypted | Mirror + handshake + presence | Agent mode (same events as A) |
| C | Bluetooth HID (current `btkvm`) | Final fallback, no agent required | HID mode only; **silent** in agent mode |

Channels A and B carry **the same messages** (same `msg_seq`); the agent applies each one exactly once. HID must never run at the same time as A/B, or macOS would apply movement twice.

Audio is **outside this protocol**. A2DP remains on Bluetooth (Mac and iPhone). The iPhone does not participate in the agent.

## 3. PC states

```
IDLE ──Super+K──► NEGOTIATING ──ACCEPT──► AGENT ──4 s without HB_ACK──► HID
  ▲                    │ (3 s timeout)       │  ▲                        │
  │                    ▼                     │  └──≥1 s of HB_ACK───────┘
  └──Super+K──────── (fall back to HID)◄─────┘
```

- **IDLE**: keyboard/mouse are on the PC. Heartbeats continue if a session exists.
- **NEGOTIATING**: handshake over Bluetooth (§5). If the agent does not respond within 3 seconds, switch directly to **HID** (current behavior), without trapping the user.
- **AGENT**: events travel over A and B.
- **HID**: events travel over HID only. Heartbeats continue over A and B to detect agent recovery.
- Super+K always returns input to the PC from any state.

`mode_epoch` (u8) increments at each AGENT↔HID transition. Every event carries the epoch; the agent discards events from older epochs.

## 4. Packet format

Little-endian. All channels use the same envelope; each channel has its own nonce sequence.

```
 0      1      2      3      4                8                 16        16+N      16+N+16
 ┌──────┬──────┬──────┬──────┬────────────────┬─────────────────┬─────────┬─────────┐
 │magic │ ver  │ type │chan. │  session_id    │   ctr (u64)     │ payload │   tag   │
 └──────┴──────┴──────┴──────┴────────────────┴─────────────────┴─────────┴─────────┘
```

- `magic` = `0xB7`, `ver` = 1, `channel` = 0 (LAN) or 1 (BT).
- `session_id` (u32): random per session; packets from another session are discarded.
- `ctr` (u64): nonce counter **per direction and channel**. AEAD nonce = `dir(1) ‖ channel(1) ‖ 0x0000 ‖ ctr(8)` (12 bytes).
- Cipher: **ChaCha20-Poly1305**; 16-byte header (`magic` through `ctr`) is associated data. Tag is 16 bytes.
- Replay protection: sliding window of 128 counters per (direction, channel). Outside the window or repeated → discard.
- On RFCOMM (byte stream), each packet is prefixed with `len` (u16).

### 4.1 Message types

| Type | Code | Direction | Payload |
|---|---|---|---|
| `HELLO` | 0x01 | PC→Mac (BT) | PC X25519 ephemeral key, nonce, PC UDP port |
| `ACCEPT` | 0x02 | Mac→PC (BT) | Mac X25519 ephemeral key, nonce, UDP address(es) and port |
| `MOUSE` | 0x10 | PC→Mac (A and B) | Cumulative pointer state (§4.2) |
| `EVENTS` | 0x11 | PC→Mac (A and B) | Reliable key/button transitions (§4.3) |
| `EVENTS_ACK` | 0x12 | Mac→PC (A and B) | Highest applied `ev_seq` plus bitmap of following events |
| `SNAPSHOT` | 0x13 | PC→Mac (A and B) | Complete set of pressed keys/buttons (about every 100 ms) |
| `SNAPSHOT_ACK` | 0x14 | Mac→PC (A and B) | Confirms the initial reference for the new epoch before events |
| `HB` | 0x20 | PC→Mac (A and B) | `t_pc_us`, `mode_epoch`, current BT rate |
| `HB_ACK` | 0x21 | Mac→PC (A and B) | Echoes `t_pc_us`, receive statistics per channel (§8) |
| `MODE` | 0x30 | PC→Mac (A and B) | `hid_takeover` or `agent_resume`, with new `mode_epoch` |
| `MODE_ACK` | 0x31 | Mac→PC | Confirms the mode switch |
| `BYE` | 0x3F | Either direction | Ends the session |

`HELLO` and `ACCEPT` do not have a session key yet: they are sent in clear inside the paired, encrypted Bluetooth link (§5), with `session_id` = 0.

### 4.2 `MOUSE` (cumulative, idempotent)

```
sample_seq u32 | epoch u8 | x_total i32 | y_total i32 | wheel_total i32 | hwheel_total i32 | t_pc_us u32
```

- Each `*_total` is a sum from the beginning of the session (32-bit modular arithmetic).
- The agent stores the last applied total and applies **the difference** (`new - previous`, with wrap). A `sample_seq` older than the most recently accepted one is ignored; a repeated sample has no effect.
- The PC always sends the **latest totals**; it never queues old samples.
- Wheel: the PC converts `REL_WHEEL_HI_RES` (120 = 1 click) to 1/120 units in `wheel_total`; the agent converts them to `CGEvent` pixels. This also provides smooth scrolling in agent mode.

### 4.3 `EVENTS` (reliable, ordered, deduplicated)

```
ev_seq u32 | epoch u8 | n u8 | n × { code u16, value u8 (0/1), x_total i32, y_total i32, sample_seq u32 }
```

- Covers keys, media keys, and mouse buttons. Each event carries the cumulative position at that moment so the agent can move the pointer there **before** clicking.
- The PC retransmits over A and B every 20 ms until an `EVENTS_ACK` covers `ev_seq`; the agent applies events in `ev_seq` order and drops duplicates.
- `SNAPSHOT` (about every 100 ms and on every mode switch) resends the complete set of pressed inputs. If the agent thinks a key is stuck but the snapshot says it is released, it releases it; if the snapshot says it is pressed and the agent missed the event, it applies the press.

In the implementation, `code` is `(HID usage page << 8) | usage`: page 7 for keyboard, 9 for buttons, and 12 for media. Each transition's `sample_seq` lets a click be placed before restoring an earlier mouse sample that arrived out of order. Old movement never moves the pointer back after a newer event.

`EVENTS_ACK` = `base u32 | bitmap u64 | epoch u8`. The bitmap acknowledges later packets already held in the window; application remains ordered by `base`. ACKs from another epoch do not remove events from the current queue. The queue holds 64 transitions; if it fills, the PC switches to HID and synchronizes the physical pressed state.

`SNAPSHOT` = `epoch u8 | n u8 | bootstrap u8 | next_ev_seq u32 | MOUSE(25 B) | n × code u16`. A periodic snapshot reconciles state only after transitions before `next_ev_seq`; older snapshots are ignored. The initial snapshot (`bootstrap=1`) establishes cumulative totals without moving the pointer, preventing movement already performed by HID from being applied again. `SNAPSHOT_ACK` contains one byte (`epoch`). The PC repeats the initial reference until this ACK arrives before enabling `MOUSE`/`EVENTS`. If it is not confirmed within 3 seconds, activation returns to HID even if heartbeats are responding.

## 5. Handshake and keys (Bluetooth as invisible authentication)

Runs automatically on each activation (Super+K to enter), with no manual input:

1. The PC sends `HELLO` over channel B (RFCOMM, accepted only over the **encrypted paired Bluetooth link**; unencrypted connections are rejected).
2. The Mac responds with `ACCEPT`, its ephemeral key, and the **IP address and UDP port** where the agent listens. No IP configuration or mDNS discovery is needed.
3. Both sides calculate `secret = X25519(own_ephemeral, remote_ephemeral)` and derive two traffic keys (one per direction) with `HKDF-SHA256(secret, salt = nonce_pc ‖ nonce_mac, info = "btkvm/1")`.
4. LAN traffic is accepted **only** when it decrypts with this key. Packets from intruders on the Wi-Fi network are discarded at the first tag check.
5. A new session starts with each activation; keys are also rotated after 2³² packets or 1 hour.

Implemented `HELLO` fields: `public_key[32] | nonce_pc[16] | udp_port u16 | new_session_id u32`. The handshake header still uses `session_id=0`. `ACCEPT`: `public_key[32] | nonce_mac[16] | count u8 | udp_port u16 | count × IPv4[4]`. Up to eight addresses; zero addresses means RFCOMM only. The PC tries advertised addresses and selects the first to return an ACK with a valid AEAD. IPv6 is not implemented in this version.

The RFCOMM service uses UUID `8ea6e923-cc7d-4b58-93c5-72eb7376b8f1` and channel 22. BlueZ requires authentication; `NewConnection` also checks `Paired`, the registered HID host address, and `BT_SECURITY >= MEDIUM`. The Mac checks pairing and encryption mode before accepting a `HELLO`.

Authenticity: the Bluetooth channel is already authenticated and encrypted by pairing, and ephemeral keys travel inside it. No long-term key is stored on disk in this version.

> Known limitation: an attacker who can impersonate the Mac over Bluetooth (by breaking pairing) can obtain the session. Pinning a long-term identity (Ed25519) is a future improvement (§12).

## 6. Rates and adaptation

| Channel | `MOUSE` rate | Notes |
|---|---|---|
| A (LAN) | Up to ~250 Hz | UDP, no queue |
| B (BT), normal | ~20–30 Hz (floor) | Light traffic; coexists with A2DP |
| B (BT), degraded | ~125 Hz | Only while LAN is unhealthy |

- **LAN health estimate** (1-second window, based on `HB`/`HB_ACK` and returned receive statistics): LAN is **degraded** if `loss > 5%`, or `RTT p95 > 40 ms`, or a response gap is `> 100 ms`.
- **Hysteresis:** enter degraded mode immediately; return to normal after 3 seconds of continuously healthy LAN.
- **No BT queue:** if the RFCOMM output buffer exceeds the limit (`TIOCOUTQ`), discard the `MOUSE` sample (the next packet's totals cover it). Never discard `EVENTS` (small, bounded queue of about 64).
- Size: `MOUSE` = 25 B payload + 16 B header + 16 B tag = 57 B. At 250 Hz on LAN ≈ 14 KB/s; at 25 Hz on BT ≈ 1.4 KB/s; at 125 Hz on BT ≈ 7 KB/s (A2DP SBC uses about 40 KB/s).

## 7. HID fallback (third layer)

- **Trigger:** no valid authenticated `HB_ACK` on **either** channel for **4 seconds**. Silence means no agent response (heartbeat about 10 Hz per channel), not that the user is idle.
- On trigger, the PC increments `mode_epoch`, sends `MODE{hid_takeover}` (best effort), releases all keys on the agent path, and enables HID.
- **Return:** after receiving valid `HB_ACK`s continuously for at least 1 second, the PC sends `MODE{agent_resume}`, waits for `MODE_ACK`, disables HID (all keys released), and returns to agent mode.
- `agent_resume` prepares the agent but does not inject events yet. After `MODE_ACK`, the PC drains HID release reports and sends the initial snapshot; only then does the agent enable injection. Initial negotiation uses the same confirmation.
- `MODE` is repeated every 100 ms until `MODE_ACK`; heartbeats with a newer epoch also make the agent release the previous epoch. Queued input from another epoch is not sent. Without a HID connection, input is returned to the PC before a reconnection attempt, which may block on Bluetooth.
- **Single-writer rule:** in HID mode, the PC **stops** sending `MOUSE`/`EVENTS` to the agent (only `HB`/`MODE` continue), so even if the agent is alive and only ACKs were lost, movement is never doubled.
- **Agent watchdog:** if the agent receives no authenticated PC packet for more than 2 seconds, it releases all keys and buttons it pressed.
- On the macOS login/lock screen, the user agent cannot inject events; HID covers this case.

## 8. Telemetry

Measured on both sides and returned in `HB_ACK`:

| Metric | Side |
|---|---|
| RTT per channel (p50/p95/p99) | PC |
| Received loss per channel, duplicates, out-of-order packets | Mac, returned to PC |
| `MOUSE` samples discarded due to a full buffer (BT) | PC |
| Time in degraded mode, mode switches, HID fallbacks | PC |
| Retransmitted `EVENTS` | PC |
| Wi-Fi band/RSSI, Bluetooth state | Mac (informational) |

- Summary every 5 seconds in `journalctl -u btkvm` and the `btkvm-stats` command.
- `HB_ACK` = `t_pc_us u32 | epoch u8 | received u32 | lost u32 | duplicates u32 | out_of_order u32`, reporting the channel where the HB arrived. Cumulative counters are compared over a 1-second window for adaptation. Wi-Fi RSSI/band are logged on the Mac when the system allows them to be queried.
- `/run/btkvm-dual.json` receives the latest summary; `btkvm-stats` marks reports older than 15 seconds as stale. Nominal rates are not measured latency.
- **Current HID baseline:** the agent has an observe-only `--observe` mode (no injection; requires Input Monitoring permission) that records the interval between events received over HID. This shows jitter and stutter in the current mode for comparison with dual mode. Limitation: HID has no RTT; compare arrival regularity and `deferred due to full buffer` counts already logged by `btkvm`.

## 9. Mac agent (`btkvm-agent`, Swift, single binary)

- Compiled with `swiftc` (Command Line Tools); started at login through a LaunchAgent (`~/Library/LaunchAgents/`).
- macOS permissions: **Accessibility** (inject events), **Bluetooth** (RFCOMM), **Local Network** (UDP), and **Input Monitoring** only for `--observe`.
- Injection: pointer with `CGEvent` (position = current + delta, clamped to the display), wheel with `CGEventCreateScrollWheelEvent2`, keys with `CGEventCreateKeyboardEvent` (HID usage → macOS keycode table), and media keys through system events.
- Channel B: RFCOMM client (`IOBluetooth`) for the PC's dedicated service UUID; reconnects automatically.
- Channel A: UDP socket (`Network.framework`) on the port advertised in `ACCEPT`.
- Log: `~/Library/Logs/btkvm-agent.log`.
- Signing: use a stable signing identity (same bundle ID) so macOS does not revoke permissions on every rebuild.

## 10. Code organization

- `src/btkvm`: optional integration preserving the default HID path. Select the new mode in `/etc/btkvm.conf` (`mode = hid` by default, or `dual`).
- Protocol core as a pure, testable module (no I/O): serialization, AEAD, deduplication, counters, state machine, and rate adaptation.
- Separate transports: LAN (UDP) and BT (RFCOMM via BlueZ `ProfileManager1`, already used by `btkvm`).
- `mac-agent/`: Swift agent package.
- Installer: `--dual` option; without it, existing behavior remains unchanged.

## 11. Tests

Future validation plan. This stage checked only Python/Bash syntax; the properties below have not yet been demonstrated in a simulator or on hardware.

1. **PC protocol core with a network simulator** (loss, duplication, reordering, delay, burst loss, each channel, fixed seed): expected invariants:
   - Final pointer position == exact sum of deltas, regardless of delivery pattern.
   - No key remains stuck at session end, mode switch, or channel loss.
   - Each `EVENTS` transition is applied exactly once and in order.
   - No double delivery between agent and HID in any mode-switch sequence.
2. **Crypto:** replay, tampered packet, wrong session, and repeated nonce are rejected.
3. **PC integration:** two local processes (simulated PC and Python "agent") over loopback.
4. **Mac:** guided manual test (compile, grant permissions, run `--observe`, then dual mode), with telemetry as the result.

## 12. Open questions

- **RFCOMM vs. L2CAP with flush timeout** on channel B: RFCOMM is a reliable stream and can queue when the radio is poor. L2CAP with discard timing would behave like a datagram (better for the mouse). Start with RFCOMM (simpler `IOBluetooth` API) and reconsider based on telemetry.
- **Long-term identity** (pin Ed25519 at first pairing) to harden the handshake.
- **Mac sleep/wake:** automatic RFCOMM reconnection and a new handshake.
- **Multiple Macs:** currently one host at a time.
- **Complete keyboard map:** HID usage → macOS keycode, including ABNT2.
- **Mac radio coexistence:** if adaptive rate is insufficient, consider a lower floor or a "gaming/work" profile.
- **Numerical targets** (p99 latency, stuck keys after N hours): not defined; baseline telemetry will guide them.

## 13. Decisions made (interview summary)

Swift agent · Bluetooth handshake, presence and backup · three layers with silent HID · cumulative counters · UDP + ACKs for keys · per-session key over Bluetooth · adaptive Bluetooth rate with a floor · A2DP remains on Bluetooth · design for the worst case (Mac on 2.4 GHz) · built-in telemetry · HID trigger at about 4 s · "all at once" delivery, with current HID mode intact behind a setting.
