"""Pure mode and reliable-event state machines shared by the PC runtime."""

from __future__ import annotations

from collections import OrderedDict
from dataclasses import dataclass
from enum import Enum, auto
from typing import Iterable

from .protocol import EventAck, KeyTransition

MASK32 = 0xFFFFFFFF


def seq_distance(a: int, b: int) -> int:
    """Unsigned distance from a to b in the wrapping u32 sequence space."""
    return (b - a) & MASK32


class RunMode(Enum):
    INACTIVE = auto()
    NEGOTIATING = auto()
    AGENT = auto()
    HID = auto()


@dataclass(frozen=True)
class Transition:
    old: RunMode
    new: RunMode
    epoch: int
    reason: str


class ModeMachine:
    """The PC's single-writer guarantee and failover timers."""

    NEGOTIATE_TIMEOUT = 3.0
    AGENT_DEAD_TIMEOUT = 4.0
    RESUME_STABLE_TIME = 1.0

    def __init__(self) -> None:
        self.mode = RunMode.INACTIVE
        self.epoch = 0
        self.negotiation_started: float | None = None
        self.last_authenticated_ack: float | None = None
        self.healthy_since: float | None = None

    def _set(self, new: RunMode, reason: str, bump_epoch: bool = False) -> Transition | None:
        old = self.mode
        if old == new:
            return None
        if bump_epoch:
            self.epoch = (self.epoch + 1) & 0xFF
        self.mode = new
        return Transition(old, new, self.epoch, reason)

    def activate(self, now: float) -> Transition | None:
        if self.mode != RunMode.INACTIVE:
            return self.deactivate("toggle")
        self.negotiation_started = now
        self.last_authenticated_ack = None
        self.healthy_since = None
        return self._set(RunMode.NEGOTIATING, "Super+K")

    def deactivate(self, reason: str = "Super+K") -> Transition | None:
        self.negotiation_started = None
        self.last_authenticated_ack = None
        self.healthy_since = None
        return self._set(RunMode.INACTIVE, reason, bump_epoch=self.mode in (RunMode.AGENT, RunMode.HID))

    def accepted(self, now: float) -> Transition | None:
        if self.mode != RunMode.NEGOTIATING:
            return None
        self.last_authenticated_ack = now
        self.healthy_since = now
        self.negotiation_started = None
        return self._set(RunMode.AGENT, "authenticated handshake")

    def authenticated_ack(self, now: float) -> Transition | None:
        if self.mode == RunMode.INACTIVE:
            return None
        previous = self.last_authenticated_ack
        self.last_authenticated_ack = now
        if self.mode == RunMode.NEGOTIATING:
            self.healthy_since = now
            return None  # MODE_ACK/accepted() is the activation barrier
        if self.mode == RunMode.HID:
            if previous is None or now - previous > 0.25:
                self.healthy_since = now
            elif self.healthy_since is None:
                self.healthy_since = now
        return None

    def force_hid(self, reason: str) -> Transition | None:
        if self.mode not in (RunMode.AGENT, RunMode.NEGOTIATING):
            return None
        self.healthy_since = None
        return self._set(RunMode.HID, reason, bump_epoch=True)

    def mode_acknowledged(self, now: float) -> Transition | None:
        if self.mode != RunMode.HID or self.healthy_since is None:
            return None
        if now - self.healthy_since < self.RESUME_STABLE_TIME:
            return None
        self.healthy_since = None
        return self._set(RunMode.AGENT, "agent heartbeat stable", bump_epoch=True)

    def tick(self, now: float) -> Transition | None:
        if self.mode == RunMode.NEGOTIATING and self.negotiation_started is not None:
            if now - self.negotiation_started >= self.NEGOTIATE_TIMEOUT:
                self.negotiation_started = None
                return self._set(RunMode.HID, "agent negotiation timeout")
        elif self.mode == RunMode.AGENT and self.last_authenticated_ack is not None:
            if now - self.last_authenticated_ack >= self.AGENT_DEAD_TIMEOUT:
                self.healthy_since = None
                return self._set(RunMode.HID, "no authenticated heartbeat for 4 seconds", bump_epoch=True)
        return None


class ReliableEventQueue:
    """Bounded retransmission queue for EVENTS; never silently drops transitions."""

    LIMIT = 64

    def __init__(self) -> None:
        self.next_seq = 0
        self.pending: OrderedDict[int, tuple[int, KeyTransition, float | None]] = OrderedDict()

    def append(self, epoch: int, event: KeyTransition) -> int:
        if len(self.pending) >= self.LIMIT:
            raise BufferError("EVENTS queue full; transition to HID and synchronize physical state")
        seq = self.next_seq
        self.next_seq = (seq + 1) & MASK32
        self.pending[seq] = (epoch & 0xFF, event, None)
        return seq

    def due(self, now: float, interval: float = 0.020) -> tuple[tuple[int, int, KeyTransition], ...]:
        ready = []
        for seq, (epoch, event, sent_at) in tuple(self.pending.items()):
            if sent_at is None or now - sent_at >= interval:
                ready.append((seq, epoch, event))
                self.pending[seq] = (epoch, event, now)
        return tuple(ready)

    def acknowledge(self, ack: EventAck) -> int:
        removed = 0
        for seq in tuple(self.pending):
            if self.pending[seq][0] == ack.epoch and ack.covers(seq):
                del self.pending[seq]
                removed += 1
        return removed

    def clear(self) -> None:
        self.pending.clear()

    def reset(self) -> None:
        self.pending.clear()
        self.next_seq = 0


class OrderedEventReceiver:
    """Buffer out-of-order event packets and expose each transition once in order."""

    WINDOW = 64

    def __init__(self, epoch: int = 0) -> None:
        self.next_seq = 0
        self.epoch = epoch & 0xFF
        self.buffer: dict[int, tuple[int, tuple[KeyTransition, ...]]] = {}

    def receive(self, seq: int, epoch: int, events: Iterable[KeyTransition]) -> tuple[KeyTransition, ...]:
        if epoch != self.epoch:
            return ()
        seq &= MASK32
        distance = seq_distance(self.next_seq, seq)
        if distance >= 0x80000000:  # already applied
            return ()
        if distance >= self.WINDOW:
            raise BufferError("EVENTS gap exceeds receive window")
        self.buffer.setdefault(seq, (epoch & 0xFF, tuple(events)))
        ready: list[KeyTransition] = []
        while self.next_seq in self.buffer:
            _, batch = self.buffer.pop(self.next_seq)
            ready.extend(batch)
            self.next_seq = (self.next_seq + 1) & MASK32
        return tuple(ready)

    def ack(self) -> EventAck:
        base = (self.next_seq - 1) & MASK32
        bitmap = 0
        for seq in self.buffer:
            distance = seq_distance(base, seq)
            if 1 <= distance <= 64:
                bitmap |= 1 << (distance - 1)
        return EventAck(base, bitmap, self.epoch)

    def reset(self, epoch: int, next_seq: int = 0) -> None:
        self.epoch = epoch & 0xFF
        self.next_seq = next_seq & MASK32
        self.buffer.clear()


def reconcile_pressed(current: Iterable[int], snapshot: Iterable[int]) -> tuple[tuple[int, bool], ...]:
    """Return releases then presses needed to make current equal the remote snapshot."""
    have, want = set(current), set(snapshot)
    return tuple((usage, False) for usage in sorted(have - want)) + tuple(
        (usage, True) for usage in sorted(want - have)
    )
