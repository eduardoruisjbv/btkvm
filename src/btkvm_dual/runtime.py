"""Network owner for the optional dual mode; input stays on the daemon thread.

The main thread commits a handoff with ready() only after releasing the old
writer. Every queued input carries its epoch; old input cannot cross a handoff.
"""
from __future__ import annotations

import collections
import fcntl
import json
import math
import os
import queue
import select
import socket
import struct
import threading
import time
from dataclasses import dataclass

from .protocol import (Accept, Channel, EventAck, Heartbeat, HeartbeatAck, Hello,
                       KeyTransition, MessageType, Mode, ModeCommand, MouseState,
                       PacketCodec, ProtocolError, create_ephemeral_keypair,
                       derive_session_keys, monotonic_us, new_session_id,
                       pack_events, pack_handshake, pack_snapshot, unpack_handshake)
from .state import ModeMachine, ReliableEventQueue, RunMode, Transition

SERVICE_UUID = "8ea6e923-cc7d-4b58-93c5-72eb7376b8f1"
RFCOMM_CHANNEL = 22


@dataclass(frozen=True)
class RuntimeNotice:
    kind: str
    value: object = None


class DualRuntime:
    """Bounded command queue, coalesced mouse samples and nonblocking I/O."""

    def __init__(self, bind_host="0.0.0.0", bind_port=45873, stats_path="/run/btkvm-dual.json"):
        self._udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self._udp.bind((bind_host, bind_port))
        self._udp.setblocking(False)
        self.udp_port = self._udp.getsockname()[1]
        self._wake_r, self._wake_w = socket.socketpair()
        self._wake_r.setblocking(False)
        self._wake_w.setblocking(False)
        self._commands = queue.Queue(maxsize=128)
        self._notices = queue.SimpleQueue()
        self._mouse_lock = threading.Lock()
        self._latest_mouse = None
        self._overflow = threading.Event()
        self._machine = ModeMachine()
        self._thread = threading.Thread(target=self._run, name="btkvm-dual", daemon=True)
        self.stats_path = stats_path
        self._closed = False

    def start(self):
        self._thread.start()

    def _wake(self):
        try:
            self._wake_w.send(b"x")
        except (BlockingIOError, OSError):
            pass

    def _post(self, name, value=None):
        if self._closed:
            if name == "rfcomm":
                value.close()
            return
        try:
            self._commands.put_nowait((name, value))
        except queue.Full:
            if name == "rfcomm":
                value.close()
            self._overflow.set()
        self._wake()

    def activate(self):
        self._post("activate")

    def deactivate(self):
        self._post("deactivate")

    def attach_rfcomm(self, conn):
        conn.setblocking(False)
        self._post("rfcomm", conn)

    def detach_rfcomm(self):
        self._post("detach")

    def ready(self, epoch, pressed, mouse):
        """Commit AGENT after HID releases have reached its socket."""
        self._post("ready", (epoch, frozenset(pressed), mouse))

    def send_transition(self, epoch, event):
        self._post("event", (epoch, event))

    def send_mouse(self, state):
        with self._mouse_lock:
            self._latest_mouse = state
        self._wake()

    def drain_notices(self, limit=256):
        result = []
        for _ in range(limit):
            try:
                result.append(self._notices.get_nowait())
            except queue.Empty:
                break
        return result

    def close(self):
        self._post("close")
        self._thread.join(timeout=1)
        self._closed = True
        for sock in (self._udp, self._wake_r, self._wake_w):
            sock.close()

    def _notice(self, kind, value=None):
        self._notices.put(RuntimeNotice(kind, value))

    def _run(self):
        conn = None
        incoming, outgoing = bytearray(), bytearray()
        tx, rx = {}, {}
        peers = []
        active_peer = None
        private = None
        nonce = b""
        session = 0
        session_started = 0.0
        negotiating = False
        committed = False
        agent_started = False
        bootstrap_payload = None
        bootstrap_started = None
        events = ReliableEventQueue()
        pressed = set()
        mouse = None
        resume_epoch = None
        pending_mode = None
        last_mode = last_hb = last_snapshot = last_lan_mouse = last_bt_mouse = 0.0
        last_lan_ack = 0.0
        rtts = {channel: collections.deque() for channel in Channel}
        loss_reports = collections.deque()
        lan_degraded = True
        lan_healthy_since = None
        stats = collections.Counter()
        last_stats = 0.0
        bt_rate = 125
        previous_tick = time.monotonic()

        def transition(change):
            nonlocal committed, mouse, resume_epoch, agent_started, bootstrap_payload, pending_mode, bootstrap_started
            if change is None:
                return
            committed = False
            agent_started = False
            bootstrap_payload = None
            bootstrap_started = None
            pending_mode = None
            mouse = None
            resume_epoch = None
            events.reset()
            pressed.clear()
            stats["mode_changes"] += 1
            if change.old == RunMode.AGENT and change.new == RunMode.HID:
                stats["hid_fallbacks"] += 1
            self._notice("mode", change)

        def disconnect(reason):
            nonlocal conn, tx, rx, private, peers, active_peer, session, negotiating, committed
            if conn is not None:
                conn.close()
            conn = None
            # A lost BT link need not kill a healthy authenticated LAN session.
            incoming.clear()
            outgoing.clear()
            if negotiating:
                tx, rx = {}, {}
                private = None
                peers, active_peer = [], None
                session = 0
                negotiating = False
                committed = False
            self._notice("link_lost", reason)

        def encode(kind, payload, channel):
            codec = tx.get(channel)
            if codec is None:
                return None
            return codec.encode(kind, channel, payload)

        def send(kind, payload, channel):
            packet = encode(kind, payload, channel)
            if packet is None:
                return
            try:
                if channel == Channel.LAN:
                    targets = [active_peer] if active_peer else peers
                    for peer in targets:
                        self._udp.sendto(packet, peer)
                        stats["lan_bytes"] += len(packet)
                elif conn is not None:
                    queued = 0
                    try:
                        queued = struct.unpack("I", fcntl.ioctl(conn, 0x5411, struct.pack("I", 0)))[0]
                    except OSError:
                        pass
                    if kind == MessageType.MOUSE and (outgoing or queued > 1024):
                        stats["bt_mouse_dropped"] += 1
                        return
                    # EVENTS remain in the reliable queue when congested. Control
                    # packets are retried every heartbeat; never grow a byte queue.
                    if len(outgoing) > 4096:
                        return
                    outgoing.extend(struct.pack("<H", len(packet)) + packet)
            except (OSError, BlockingIOError):
                stats["send_errors"] += 1

        def both(kind, payload):
            for channel in Channel:
                send(kind, payload, channel)

        def mode(command, epoch):
            nonlocal pending_mode, last_mode
            pending_mode = Mode(command, epoch)
            both(MessageType.MODE, pending_mode.pack())
            last_mode = time.monotonic()

        def fallback(reason):
            if self._machine.mode in (RunMode.AGENT, RunMode.NEGOTIATING):
                transition(self._machine.force_hid(reason))
                self._machine.healthy_since = None
                mode(ModeCommand.HID_TAKEOVER, self._machine.epoch)

        def handshake():
            nonlocal private, nonce, session, tx, rx, peers, active_peer, negotiating, session_started, committed
            if conn is None:
                return
            tx, rx = {}, {}
            peers, active_peer = [], None
            rtts[Channel.LAN].clear()
            rtts[Channel.BLUETOOTH].clear()
            loss_reports.clear()
            events.reset()
            pressed.clear()
            committed = False
            incoming.clear()
            outgoing.clear()
            private, public = create_ephemeral_keypair()
            nonce = os.urandom(16)
            session = new_session_id()
            packet = pack_handshake(MessageType.HELLO, Hello(public, nonce, self.udp_port, session).pack())
            outgoing.extend(struct.pack("<H", len(packet)) + packet)
            session_started = time.monotonic()
            negotiating = True
            self._notice("handshake_started")

        def receive(packet, channel, peer=None):
            nonlocal tx, rx, private, peers, active_peer, negotiating, last_lan_ack, resume_epoch, pending_mode
            nonlocal lan_degraded, lan_healthy_since, bt_rate
            nonlocal agent_started, bootstrap_payload
            if channel == Channel.BLUETOOTH and negotiating:
                kind, data = unpack_handshake(packet)
                if kind != MessageType.ACCEPT or private is None:
                    raise ProtocolError("expected ACCEPT")
                answer = Accept.unpack(data)
                pc_key, mac_key = derive_session_keys(private, answer.public_key, nonce, answer.nonce)
                tx = {ch: PacketCodec(pc_key, session, 0) for ch in Channel}
                rx = {ch: PacketCodec(mac_key, session, 1) for ch in Channel}
                peers = [(ip, answer.udp_port) for ip in answer.addresses]
                private = None
                negotiating = False
                # ACCEPT alone does not enable injection. An authenticated HB_ACK
                # proves both key derivation and that macOS permits injection.
                self._notice("session_ready", peers)
                return
            if channel not in rx:
                return
            kind, data = rx[channel].decode(packet, channel)
            now = time.monotonic()
            if kind == MessageType.HEARTBEAT_ACK:
                ack = HeartbeatAck.unpack(data)
                # While a resume is pending the peer echoes the proposed epoch.
                if ack.epoch not in (self._machine.epoch, resume_epoch):
                    return
                rtt = (((int(now * 1_000_000) & 0xFFFFFFFF) - ack.t_pc_us) & 0xFFFFFFFF) / 1000
                if rtt > 4000:
                    return
                if channel == Channel.LAN:
                    active_peer = peer
                    last_lan_ack = now
                    loss_reports.append((now, ack.received, ack.lost))
                    while loss_reports and now - loss_reports[0][0] > 1:
                        loss_reports.popleft()
                rtts[channel].append((now, rtt))
                while rtts[channel] and now - rtts[channel][0][0] > 1:
                    rtts[channel].popleft()
                if self._machine.mode == RunMode.NEGOTIATING:
                    self._machine.last_authenticated_ack = now
                    if pending_mode is None:
                        mode(ModeCommand.AGENT_RESUME, self._machine.epoch)
                else:
                    transition(self._machine.authenticated_ack(now))
                if self._machine.mode == RunMode.HID and self._machine.healthy_since is not None:
                    if now - self._machine.healthy_since >= 1 and resume_epoch is None:
                        resume_epoch = (self._machine.epoch + 1) & 255
                        mode(ModeCommand.AGENT_RESUME, resume_epoch)
                stats["peer_duplicates"] = ack.duplicates
                stats["peer_out_of_order"] = ack.out_of_order
            elif kind == MessageType.MODE_ACK:
                answer = Mode.unpack(data)
                if pending_mode is None or answer != pending_mode:
                    return
                if answer.command == ModeCommand.AGENT_RESUME and resume_epoch is not None:
                    if (self._machine.last_authenticated_ack is not None
                            and now - self._machine.last_authenticated_ack <= 0.25):
                        change = self._machine.mode_acknowledged(now)
                        if change:
                            transition(change)
                elif answer.command == ModeCommand.AGENT_RESUME and self._machine.mode == RunMode.NEGOTIATING:
                    transition(self._machine.accepted(now))
                pending_mode = None
            elif kind == MessageType.SNAPSHOT_ACK:
                if (committed and len(data) == 1 and data[0] == self._machine.epoch):
                    agent_started = True
                    bootstrap_payload = None
            elif kind == MessageType.EVENTS_ACK and self._machine.mode == RunMode.AGENT:
                ack = EventAck.unpack(data)
                if ack.epoch == self._machine.epoch:
                    stats["events_acked"] += events.acknowledge(ack)
            elif kind == MessageType.BYE:
                fallback("agent cannot inject events")

        try:
            while True:
                readers = [self._wake_r, self._udp] + ([conn] if conn else [])
                writers = [conn] if conn and outgoing else []
                ready, writable, _ = select.select(readers, writers, [], 0.004)
                now = time.monotonic()
                if self._wake_r in ready:
                    try:
                        self._wake_r.recv(65536)
                    except BlockingIOError:
                        pass
                if self._overflow.is_set():
                    self._overflow.clear()
                    fallback("bounded input queue exhausted")
                for _ in range(128):
                    try:
                        command, value = self._commands.get_nowait()
                    except queue.Empty:
                        break
                    if command == "close":
                        both(MessageType.BYE, b"")
                        return
                    if command == "activate":
                        transition(self._machine.activate(now))
                        if conn is None:
                            tx, rx = {}, {}
                            session = 0
                            peers, active_peer = [], None
                        handshake()
                    elif command == "deactivate":
                        transition(self._machine.deactivate())
                        mode(ModeCommand.HID_TAKEOVER, self._machine.epoch)
                        both(MessageType.BYE, b"")
                    elif command == "rfcomm":
                        # Disable the previous agent writer before replacing keys.
                        fallback("RFCOMM reconnected; new session")
                        if conn is not None:
                            conn.close()
                        conn = value
                        if self._machine.mode != RunMode.INACTIVE:
                            handshake()
                    elif command == "detach":
                        disconnect("BlueZ requested disconnection")
                    elif command == "ready":
                        epoch, keys, baseline = value
                        if self._machine.mode == RunMode.AGENT and epoch == self._machine.epoch:
                            pressed = set(keys)
                            mouse = baseline
                            committed = True
                            bootstrap_payload = pack_snapshot(epoch, pressed, events.next_seq, baseline, True)
                            bootstrap_started = now
                            both(MessageType.SNAPSHOT, bootstrap_payload)
                    elif command == "event":
                        epoch, event = value
                        if committed and self._machine.mode == RunMode.AGENT and epoch == self._machine.epoch:
                            try:
                                events.append(epoch, event)
                            except BufferError:
                                fallback("reliable event queue exhausted")
                                continue
                            if event.pressed:
                                pressed.add(event.usage)
                            else:
                                pressed.discard(event.usage)
                with self._mouse_lock:
                    latest, self._latest_mouse = self._latest_mouse, None
                if latest is not None and committed and latest.epoch == self._machine.epoch:
                    mouse = latest

                if conn is not None and conn in writable and outgoing:
                    try:
                        sent = conn.send(outgoing)
                        del outgoing[:sent]
                        stats["bt_bytes"] += sent
                    except BlockingIOError:
                        pass
                    except OSError as exc:
                        disconnect(f"RFCOMM write: {exc}")
                if conn is not None and conn in ready:
                    try:
                        chunk = conn.recv(4096)
                        if not chunk:
                            disconnect("RFCOMM closed")
                        else:
                            incoming.extend(chunk)
                            while len(incoming) >= 2:
                                size = struct.unpack_from("<H", incoming)[0]
                                if size < 16 or size > 1200:
                                    raise ProtocolError("invalid RFCOMM frame")
                                if len(incoming) < size + 2:
                                    break
                                packet = bytes(incoming[2:size + 2])
                                del incoming[:size + 2]
                                receive(packet, Channel.BLUETOOTH)
                    except BlockingIOError:
                        pass
                    except (OSError, ValueError) as exc:
                        disconnect(f"RFCOMM read: {exc}")
                if self._udp in ready:
                    for _ in range(32):
                        try:
                            packet, peer = self._udp.recvfrom(1201)
                            if peer in peers:
                                receive(packet, Channel.LAN, peer)
                        except BlockingIOError:
                            break
                        except (OSError, ValueError):
                            stats["rejected_lan_packets"] += 1

                change = self._machine.tick(now)
                if change:
                    transition(change)
                    mode(ModeCommand.HID_TAKEOVER, self._machine.epoch)
                if bootstrap_payload is not None and bootstrap_started is not None and now - bootstrap_started >= 3:
                    fallback("initial snapshot confirmation timeout")
                if self._machine.mode == RunMode.HID and (self._machine.last_authenticated_ack is None
                        or now - self._machine.last_authenticated_ack > 0.25):
                    self._machine.healthy_since = None
                    if resume_epoch is not None:
                        resume_epoch = None
                        mode(ModeCommand.HID_TAKEOVER, self._machine.epoch)
                if negotiating and now - session_started >= 3:
                    disconnect("handshake timeout")
                if tx and (now - session_started >= 3600 or any(
                        max(codec._counters.values()) >= (1 << 32) for codec in tx.values())):
                    fallback("session rekey")
                    if conn is None:
                        tx, rx = {}, {}
                    else:
                        handshake()

                recent = sorted(value for _, value in rtts[Channel.LAN])
                p95 = recent[max(0, math.ceil(len(recent) * 0.95) - 1)] if recent else 0
                loss = 0.0
                if len(loss_reports) >= 2:
                    first, last = loss_reports[0], loss_reports[-1]
                    received = (last[1] - first[1]) & 0xFFFFFFFF
                    lost = (last[2] - first[2]) & 0xFFFFFFFF
                    loss = lost / max(1, received + lost)
                healthy = bool(last_lan_ack and now - last_lan_ack <= 0.1 and p95 <= 40 and loss <= 0.05)
                if not healthy:
                    lan_degraded, lan_healthy_since = True, None
                elif lan_degraded:
                    if lan_healthy_since is None:
                        lan_healthy_since = now
                    elif now - lan_healthy_since >= 3:
                        lan_degraded = False
                bt_rate = 125 if lan_degraded else 25
                if lan_degraded:
                    stats["degraded_ms"] += int((now - previous_tick) * 1000)
                previous_tick = now
                if tx and now - last_hb >= 0.1:
                    # Always advertise the current writer's epoch, including HID.
                    both(MessageType.HEARTBEAT, Heartbeat(monotonic_us(), self._machine.epoch, bt_rate).pack())
                    last_hb = now
                if pending_mode is not None and now - last_mode >= 0.1:
                    both(MessageType.MODE, pending_mode.pack())
                    last_mode = now
                if bootstrap_payload is not None and now - last_snapshot >= 0.02:
                    both(MessageType.SNAPSHOT, bootstrap_payload)
                    last_snapshot = now
                if committed and agent_started and self._machine.mode == RunMode.AGENT:
                    for seq, epoch, event in events.due(now):
                        both(MessageType.EVENTS, pack_events(seq, epoch, (event,)))
                        stats["events_transmissions"] += 1
                    if mouse is not None:
                        if now - last_snapshot >= 0.1:
                            both(MessageType.SNAPSHOT, pack_snapshot(self._machine.epoch, pressed, events.next_seq, mouse))
                            last_snapshot = now
                        if now - last_lan_mouse >= 0.004:
                            send(MessageType.MOUSE, mouse.pack(), Channel.LAN)
                            last_lan_mouse = now
                        if now - last_bt_mouse >= 1 / bt_rate:
                            send(MessageType.MOUSE, mouse.pack(), Channel.BLUETOOTH)
                            last_bt_mouse = now
                if now - last_stats >= 5:
                    report = dict(stats, mode=self._machine.mode.name, epoch=self._machine.epoch,
                                  lan_loss=round(loss, 4), lan_rtt_p95_ms=round(p95, 2),
                                  bt_rate_hz=bt_rate, udp_port=self.udp_port,
                                  queued_events=len(events.pending), updated_monotonic=now)
                    for ch in Channel:
                        samples = sorted(v for _, v in rtts[ch])
                        for label, percentile in (("p50", .50), ("p95", .95), ("p99", .99)):
                            report[f"{ch.name.lower()}_rtt_{label}_ms"] = round(samples[max(0, math.ceil(len(samples) * percentile) - 1)], 2) if samples else None
                    self._notice("telemetry", report)
                    if self.stats_path:
                        try:
                            with open(self.stats_path + ".tmp", "w") as output:
                                json.dump(report, output)
                            os.replace(self.stats_path + ".tmp", self.stats_path)
                        except OSError:
                            pass
                    last_stats = now
        except Exception as exc:
            self._notice("fatal", str(exc))
        finally:
            if conn is not None:
                conn.close()


def wrap_rfcomm_fd(fd):
    try:
        return socket.socket(fileno=fd)
    except OSError:
        os.close(fd)
        raise
