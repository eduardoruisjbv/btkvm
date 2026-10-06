"""Wire format and cryptographic primitives for the btkvm dual protocol.

This module deliberately has no socket, D-Bus, evdev, or macOS dependencies.
The field sizes and byte order mirror docs/PROTOCOLO.md.
"""

from __future__ import annotations

import ipaddress
import os
import struct
import time
from dataclasses import dataclass
from enum import IntEnum
from typing import Iterable

MAGIC = 0xB7
VERSION = 1
HEADER = struct.Struct("<BBBBIQ")
HEADER_SIZE = HEADER.size  # 16 bytes
TAG_SIZE = 16
MAX_DATAGRAM = 1200
REPLAY_BITS = 128
REPLAY_MASK = (1 << REPLAY_BITS) - 1


class ProtocolError(ValueError):
    """Malformed, unauthenticated, replayed, or unsupported protocol data."""


class MessageType(IntEnum):
    HELLO = 0x01
    ACCEPT = 0x02
    MOUSE = 0x10
    EVENTS = 0x11
    EVENTS_ACK = 0x12
    SNAPSHOT = 0x13
    SNAPSHOT_ACK = 0x14
    HEARTBEAT = 0x20
    HEARTBEAT_ACK = 0x21
    MODE = 0x30
    MODE_ACK = 0x31
    BYE = 0x3F


class Channel(IntEnum):
    LAN = 0
    BLUETOOTH = 1


class ModeCommand(IntEnum):
    HID_TAKEOVER = 1
    AGENT_RESUME = 2


def _crypto():
    try:
        from cryptography.hazmat.primitives.ciphers.aead import ChaCha20Poly1305
        from cryptography.hazmat.primitives import hashes, serialization
        from cryptography.hazmat.primitives.asymmetric.x25519 import (
            X25519PrivateKey,
            X25519PublicKey,
        )
        from cryptography.hazmat.primitives.kdf.hkdf import HKDF
    except ImportError as exc:  # optional until dual mode is enabled
        raise RuntimeError(
            "dual mode requires python3-cryptography; install it with the btkvm dual option"
        ) from exc
    return ChaCha20Poly1305, hashes, serialization, X25519PrivateKey, X25519PublicKey, HKDF


def _nonce(direction: int, channel: int, counter: int) -> bytes:
    if direction not in (0, 1) or channel not in (0, 1):
        raise ProtocolError("invalid nonce direction or channel")
    if not 0 <= counter < (1 << 64):
        raise ProtocolError("nonce counter exhausted")
    return struct.pack("<BB2xQ", direction, channel, counter)


class ReplayWindow:
    """128-counter anti-replay window that permits authenticated reordering."""

    __slots__ = ("highest", "bitmap")

    def __init__(self) -> None:
        self.highest = -1
        self.bitmap = 0

    def contains(self, counter: int) -> bool:
        if counter < 0 or counter >= (1 << 64):
            return True
        if self.highest < 0 or counter > self.highest:
            return False
        distance = self.highest - counter
        return distance >= REPLAY_BITS or bool(self.bitmap & (1 << distance))

    def mark(self, counter: int) -> None:
        if self.contains(counter):
            raise ProtocolError("replayed or stale packet")
        if self.highest < 0:
            self.highest, self.bitmap = counter, 1
        elif counter > self.highest:
            shift = counter - self.highest
            self.bitmap = 1 if shift >= REPLAY_BITS else ((self.bitmap << shift) | 1) & REPLAY_MASK
            self.highest = counter
        else:
            self.bitmap |= 1 << (self.highest - counter)


class PacketCodec:
    """Authenticated packet codec; callers own one codec per direction."""

    def __init__(self, key: bytes, session_id: int, direction: int):
        if len(key) != 32:
            raise ProtocolError("ChaCha20-Poly1305 keys must be 32 bytes")
        if not 1 <= session_id <= 0xFFFFFFFF:
            raise ProtocolError("encrypted session_id must be non-zero")
        if direction not in (0, 1):
            raise ProtocolError("direction must be 0 (PC→Mac) or 1 (Mac→PC)")
        ChaCha20Poly1305, *_ = _crypto()
        self._aead = ChaCha20Poly1305(key)
        self.session_id = session_id
        self.direction = direction
        self._counters = {Channel.LAN: 0, Channel.BLUETOOTH: 0}
        self._windows = {Channel.LAN: ReplayWindow(), Channel.BLUETOOTH: ReplayWindow()}

    def encode(self, kind: MessageType, channel: Channel, payload: bytes = b"") -> bytes:
        if len(payload) + HEADER_SIZE + TAG_SIZE > MAX_DATAGRAM:
            raise ProtocolError("payload exceeds maximum packet size")
        channel = Channel(channel)
        counter = self._counters[channel]
        if counter >= (1 << 64) - 1:
            raise ProtocolError("nonce counter exhausted; establish a new session")
        self._counters[channel] = counter + 1
        header = HEADER.pack(MAGIC, VERSION, int(kind), int(channel), self.session_id, counter)
        ciphertext = self._aead.encrypt(_nonce(self.direction, int(channel), counter), payload, header)
        return header + ciphertext

    def decode(self, packet: bytes, expected_channel: Channel) -> tuple[MessageType, bytes]:
        if len(packet) < HEADER_SIZE + TAG_SIZE or len(packet) > MAX_DATAGRAM:
            raise ProtocolError("invalid packet length")
        magic, version, kind, channel_value, session_id, counter = HEADER.unpack_from(packet)
        if magic != MAGIC or version != VERSION:
            raise ProtocolError("unsupported packet magic or version")
        try:
            channel = Channel(channel_value)
            message_type = MessageType(kind)
        except ValueError as exc:
            raise ProtocolError("unknown channel or message type") from exc
        if channel != Channel(expected_channel):
            raise ProtocolError("packet arrived on the wrong channel")
        if session_id != self.session_id:
            raise ProtocolError("packet belongs to another session")
        window = self._windows[channel]
        if window.contains(counter):
            raise ProtocolError("replayed or stale packet")
        header = packet[:HEADER_SIZE]
        try:
            payload = self._aead.decrypt(
                _nonce(self.direction, int(channel), counter), packet[HEADER_SIZE:], header
            )
        except Exception as exc:
            raise ProtocolError("invalid authentication tag") from exc
        # Only authenticated counters may move the replay window.
        window.mark(counter)
        return message_type, payload


@dataclass(frozen=True)
class Hello:
    public_key: bytes
    nonce: bytes
    udp_port: int
    session_id: int

    _STRUCT = struct.Struct("<32s16sHI")

    def pack(self) -> bytes:
        if (len(self.public_key) != 32 or len(self.nonce) != 16 or not 1 <= self.udp_port <= 65535
                or not 1 <= self.session_id <= 0xFFFFFFFF):
            raise ProtocolError("invalid HELLO fields")
        return self._STRUCT.pack(self.public_key, self.nonce, self.udp_port, self.session_id)

    @classmethod
    def unpack(cls, data: bytes) -> "Hello":
        if len(data) != cls._STRUCT.size:
            raise ProtocolError("invalid HELLO payload size")
        value = cls(*cls._STRUCT.unpack(data))
        value.pack()  # validate port and session fields on receipt
        return value


@dataclass(frozen=True)
class Accept:
    public_key: bytes
    nonce: bytes
    addresses: tuple[str, ...]
    udp_port: int

    def pack(self) -> bytes:
        if len(self.public_key) != 32 or len(self.nonce) != 16:
            raise ProtocolError("invalid ACCEPT key or nonce")
        if len(self.addresses) > 8 or not 1 <= self.udp_port <= 65535:
            raise ProtocolError("invalid ACCEPT address list or port")
        encoded = []
        for value in self.addresses:
            addr = ipaddress.ip_address(value)
            if addr.version != 4:
                raise ProtocolError("dual v1 advertises IPv4 addresses only")
            encoded.append(addr.packed)
        return self.public_key + self.nonce + struct.pack("<BH", len(encoded), self.udp_port) + b"".join(encoded)

    @classmethod
    def unpack(cls, data: bytes) -> "Accept":
        if len(data) < 51:
            raise ProtocolError("short ACCEPT payload")
        public_key, nonce = data[:32], data[32:48]
        count, port = struct.unpack_from("<BH", data, 48)
        if not port or count > 8 or len(data) != 51 + 4 * count:
            raise ProtocolError("invalid ACCEPT address list")
        addresses = tuple(str(ipaddress.ip_address(data[51 + i * 4:55 + i * 4])) for i in range(count))
        return cls(public_key, nonce, addresses, port)


def create_ephemeral_keypair() -> tuple[object, bytes]:
    _, _, serialization, X25519PrivateKey, _, _ = _crypto()
    private = X25519PrivateKey.generate()
    public = private.public_key().public_bytes(
        encoding=serialization.Encoding.Raw,
        format=serialization.PublicFormat.Raw,
    )
    return private, public


def derive_session_keys(private_key: object, peer_public_key: bytes, nonce_pc: bytes,
                        nonce_mac: bytes) -> tuple[bytes, bytes]:
    """Return (PC→Mac key, Mac→PC key), independent of which peer calls it."""
    _, hashes, _, _, X25519PublicKey, HKDF = _crypto()
    if len(peer_public_key) != 32 or len(nonce_pc) != 16 or len(nonce_mac) != 16:
        raise ProtocolError("invalid X25519 handshake material")
    try:
        secret = private_key.exchange(X25519PublicKey.from_public_bytes(peer_public_key))
    except Exception as exc:
        raise ProtocolError("invalid X25519 public key") from exc
    material = HKDF(
        algorithm=hashes.SHA256(), length=64, salt=nonce_pc + nonce_mac, info=b"btkvm/1"
    ).derive(secret)
    return material[:32], material[32:]


@dataclass(frozen=True)
class MouseState:
    sample_seq: int
    epoch: int
    x_total: int
    y_total: int
    wheel_total: int
    hwheel_total: int
    t_pc_us: int

    _STRUCT = struct.Struct("<IBiiiiI")

    def pack(self) -> bytes:
        try:
            return self._STRUCT.pack(self.sample_seq & 0xFFFFFFFF, self.epoch & 0xFF,
                                     self.x_total, self.y_total, self.wheel_total,
                                     self.hwheel_total, self.t_pc_us & 0xFFFFFFFF)
        except struct.error as exc:
            raise ProtocolError("MOUSE field out of range") from exc

    @classmethod
    def unpack(cls, data: bytes) -> "MouseState":
        if len(data) != cls._STRUCT.size:
            raise ProtocolError("invalid MOUSE payload size")
        return cls(*cls._STRUCT.unpack(data))


@dataclass(frozen=True)
class KeyTransition:
    usage: int  # HID usage page in high byte, usage id in low byte.
    pressed: bool
    x_total: int
    y_total: int
    sample_seq: int = 0


_EVENT_HEAD = struct.Struct("<IBB")
_EVENT_ITEM = struct.Struct("<HBiiI")


def pack_events(ev_seq: int, epoch: int, events: Iterable[KeyTransition]) -> bytes:
    items = tuple(events)
    if len(items) > 64:
        raise ProtocolError("EVENTS batch exceeds the bounded queue")
    out = bytearray(_EVENT_HEAD.pack(ev_seq & 0xFFFFFFFF, epoch & 0xFF, len(items)))
    try:
        for item in items:
            out.extend(_EVENT_ITEM.pack(item.usage, int(item.pressed), item.x_total, item.y_total, item.sample_seq & 0xFFFFFFFF))
    except struct.error as exc:
        raise ProtocolError("EVENTS field out of range") from exc
    return bytes(out)


def unpack_events(data: bytes) -> tuple[int, int, tuple[KeyTransition, ...]]:
    if len(data) < _EVENT_HEAD.size:
        raise ProtocolError("short EVENTS payload")
    ev_seq, epoch, count = _EVENT_HEAD.unpack_from(data)
    if count > 64 or len(data) != _EVENT_HEAD.size + count * _EVENT_ITEM.size:
        raise ProtocolError("invalid EVENTS batch size")
    events = []
    offset = _EVENT_HEAD.size
    for _ in range(count):
        usage, pressed, x, y, sample_seq = _EVENT_ITEM.unpack_from(data, offset)
        if pressed not in (0, 1):
            raise ProtocolError("EVENTS pressed must be 0 or 1")
        events.append(KeyTransition(usage, bool(pressed), x, y, sample_seq))
        offset += _EVENT_ITEM.size
    return ev_seq, epoch, tuple(events)


def pack_snapshot(epoch: int, pressed: Iterable[int], next_ev_seq: int = 0,
                  mouse: MouseState | None = None, bootstrap: bool = False) -> bytes:
    usages = tuple(sorted(set(pressed)))
    if len(usages) > 64 or any(not 0 <= usage <= 0xFFFF for usage in usages):
        raise ProtocolError("invalid SNAPSHOT pressed set")
    baseline = mouse or MouseState(0, epoch, 0, 0, 0, 0, 0)
    return (struct.pack("<BBBI", epoch & 0xFF, len(usages), int(bootstrap), next_ev_seq & 0xFFFFFFFF)
            + baseline.pack() + b"".join(struct.pack("<H", u) for u in usages))


def unpack_snapshot(data: bytes) -> tuple[int, bool, int, MouseState, frozenset[int]]:
    if len(data) < 32:
        raise ProtocolError("short SNAPSHOT payload")
    epoch, count, bootstrap, next_ev_seq = struct.unpack_from("<BBBI", data)
    if bootstrap not in (0, 1) or count > 64 or len(data) != 32 + 2 * count:
        raise ProtocolError("invalid SNAPSHOT payload size")
    mouse = MouseState.unpack(data[7:32])
    if mouse.epoch != epoch:
        raise ProtocolError("SNAPSHOT baseline has a different epoch")
    return epoch, bool(bootstrap), next_ev_seq, mouse, frozenset(struct.unpack_from("<H", data, 32 + 2 * i)[0] for i in range(count))


@dataclass(frozen=True)
class EventAck:
    base: int
    bitmap: int
    epoch: int = 0

    _STRUCT = struct.Struct("<IQB")

    def pack(self) -> bytes:
        return self._STRUCT.pack(self.base & 0xFFFFFFFF, self.bitmap & 0xFFFFFFFFFFFFFFFF, self.epoch & 0xFF)

    @classmethod
    def unpack(cls, data: bytes) -> "EventAck":
        if len(data) != cls._STRUCT.size:
            raise ProtocolError("invalid EVENTS_ACK payload size")
        return cls(*cls._STRUCT.unpack(data))

    def covers(self, ev_seq: int) -> bool:
        distance = (ev_seq - self.base) & 0xFFFFFFFF
        if distance == 0 or distance >= 0x80000000:
            return True  # cumulative base covers itself and every older sequence
        return 1 <= distance <= 64 and bool(self.bitmap & (1 << (distance - 1)))


@dataclass(frozen=True)
class Heartbeat:
    t_pc_us: int
    epoch: int
    bt_rate_hz: int

    _STRUCT = struct.Struct("<IBH")

    def pack(self) -> bytes:
        return self._STRUCT.pack(self.t_pc_us & 0xFFFFFFFF, self.epoch & 0xFF, self.bt_rate_hz & 0xFFFF)

    @classmethod
    def unpack(cls, data: bytes) -> "Heartbeat":
        if len(data) != cls._STRUCT.size:
            raise ProtocolError("invalid heartbeat payload size")
        return cls(*cls._STRUCT.unpack(data))


@dataclass(frozen=True)
class HeartbeatAck:
    t_pc_us: int
    epoch: int
    received: int
    lost: int
    duplicates: int
    out_of_order: int

    _STRUCT = struct.Struct("<IBIIII")

    def pack(self) -> bytes:
        return self._STRUCT.pack(self.t_pc_us & 0xFFFFFFFF, self.epoch & 0xFF,
                                 self.received & 0xFFFFFFFF, self.lost & 0xFFFFFFFF,
                                 self.duplicates & 0xFFFFFFFF, self.out_of_order & 0xFFFFFFFF)

    @classmethod
    def unpack(cls, data: bytes) -> "HeartbeatAck":
        if len(data) != cls._STRUCT.size:
            raise ProtocolError("invalid HEARTBEAT_ACK payload size")
        return cls(*cls._STRUCT.unpack(data))


@dataclass(frozen=True)
class Mode:
    command: ModeCommand
    epoch: int

    _STRUCT = struct.Struct("<BB")

    def pack(self) -> bytes:
        return self._STRUCT.pack(int(self.command), self.epoch & 0xFF)

    @classmethod
    def unpack(cls, data: bytes) -> "Mode":
        if len(data) != cls._STRUCT.size:
            raise ProtocolError("invalid MODE payload size")
        try:
            command, epoch = cls._STRUCT.unpack(data)
            return cls(ModeCommand(command), epoch)
        except ValueError as exc:
            raise ProtocolError("unknown MODE command") from exc


def monotonic_us() -> int:
    return int(time.monotonic() * 1_000_000) & 0xFFFFFFFF


def new_session_id() -> int:
    value = int.from_bytes(os.urandom(4), "little")
    return value or 1


def pack_handshake(kind: MessageType, payload: bytes) -> bytes:
    if kind not in (MessageType.HELLO, MessageType.ACCEPT):
        raise ProtocolError("only HELLO and ACCEPT are cleartext handshake messages")
    return HEADER.pack(MAGIC, VERSION, int(kind), int(Channel.BLUETOOTH), 0, 0) + payload


def unpack_handshake(packet: bytes) -> tuple[MessageType, bytes]:
    if len(packet) < HEADER_SIZE or len(packet) > 1024:
        raise ProtocolError("invalid cleartext handshake length")
    magic, version, kind, channel, session_id, counter = HEADER.unpack_from(packet)
    if (magic, version, channel, session_id, counter) != (MAGIC, VERSION, int(Channel.BLUETOOTH), 0, 0):
        raise ProtocolError("invalid handshake header")
    try:
        message_type = MessageType(kind)
    except ValueError as exc:
        raise ProtocolError("unknown handshake message") from exc
    if message_type not in (MessageType.HELLO, MessageType.ACCEPT):
        raise ProtocolError("cleartext message is not part of the handshake")
    return message_type, packet[HEADER_SIZE:]
