# Graph Report - btkvm  (2026-10-26)

## Corpus Check
- 24 files · ~18,551 words
- Verdict: corpus is large enough that graph structure adds value.
- Unclassified: 9 file(s) not represented in the graph (top: (none) 2, .conf 2, .service 2)

## Summary
- 410 nodes · 833 edges · 20 communities (8 shown, 12 thin omitted)
- Extraction: 92% EXTRACTED · 8% INFERRED · 0% AMBIGUOUS · INFERRED: 63 edges (avg confidence: 0.88)
- Token cost: 0 input · 0 output

## Graph Freshness
- Built from commit: `53876c41`
- Run `git rev-parse HEAD` and compare to check if the graph is stale.
- Run `graphify update .` after code changes (no API cost).

## Community Hubs (Navigation)
- .receive
- runtime.py
- DualRuntime
- btkvm dual — protocol specification (local implementation v0.1)
- Agent
- ReliableEventQueue
- Changelog
- Agent.swift
- ModeMachine
- WireError
- ReplayWindow
- build.sh script
- install.sh
- mac-agent/uninstall.sh
- uninstall.sh

## God Nodes (most connected - your core abstractions)
1. `Agent` - 40 edges
2. `DualRuntime` - 31 edges
3. `ProtocolError` - 30 edges
4. `Input` - 20 edges
5. `Reader` - 14 edges
6. `ModeMachine` - 14 edges
7. `btkvm dual — protocol specification (local implementation v0.1)` - 14 edges
8. `Session` - 13 edges
9. `receive()` - 13 edges
10. `ReliableEventQueue` - 13 edges

## Surprising Connections (you probably didn't know these)
- `DualRuntime` --uses--> `EventAck`  [INFERRED]
  src/btkvm_dual/runtime.py → src/btkvm_dual/protocol.py
- `DualRuntime` --uses--> `ModeMachine`  [INFERRED]
  src/btkvm_dual/runtime.py → src/btkvm_dual/state.py
- `DualRuntime` --uses--> `ReliableEventQueue`  [INFERRED]
  src/btkvm_dual/runtime.py → src/btkvm_dual/state.py
- `DualRuntime` --uses--> `RunMode`  [INFERRED]
  src/btkvm_dual/runtime.py → src/btkvm_dual/state.py
- `Agent` --references--> `Input`  [EXTRACTED]
  mac-agent/Sources/Agent.swift → mac-agent/Sources/Input.swift

## Import Cycles
- None detected.

## Communities (20 total, 12 thin omitted)

### Community 0 - ".receive"
Cohesion: 0.07
Nodes (17): Foundation, localIPv4(), Input, .flags, log(), Data, delta(), Mouse (+9 more)

### Community 1 - "runtime.py"
Cohesion: 0.06
Nodes (14): DualProfile, register(), create_ephemeral_keypair(), _crypto(), derive_session_keys(), monotonic_us(), MouseState, new_session_id() (+6 more)

### Community 2 - "DualRuntime"
Cohesion: 0.07
Nodes (23): Accept, Channel, Heartbeat, HeartbeatAck, Hello, MessageType, Mode, ModeCommand (+15 more)

### Community 4 - "btkvm dual — protocol specification (local implementation v0.1)"
Cohesion: 0.05
Nodes (33): 10. Code organization, 11. Tests, 12. Open questions, 13. Decisions made (interview summary), 1. Goal and principles, 2. Topology and layers, 3. PC states, 4.1 Message types (+25 more)

### Community 6 - "ReliableEventQueue"
Cohesion: 0.12
Nodes (7): EventAck, KeyTransition, pack_events(), unpack_events(), OrderedEventReceiver, ReliableEventQueue, seq_distance()

### Community 7 - "Changelog"
Cohesion: 0.10
Nodes (20): [0.1.0] - 2026-10-02, [0.2.0] - 2026-10-03, [0.2.1] - 2026-10-04, [0.3.0] - 2026-10-05, [0.3.1] - 2026-10-05, [0.4.0] - 2026-10-26, Added, Added (+12 more)

### Community 8 - "Agent.swift"
Cohesion: 0.13
Nodes (9): AppKit, Carbon, CoreGraphics, CoreWLAN, CryptoKit, Darwin, IOBluetooth, Observer (+1 more)

### Community 10 - "WireError"
Cohesion: 0.40
Nodes (4): WireError, invalid, replay, session

## Knowledge Gaps
- **11 isolated node(s):** `IOBluetooth`, `Security`, `Carbon`, `CoreWLAN`, `.canInject` (+6 more)
  These have ≤1 connection - possible missing edges or undocumented components. (Counts symbols only; 134 node(s) total have ≤1 connection when file, concept and rationale nodes are included.)
- **12 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `Agent` connect `Agent` to `Agent.swift`, `.receive`?**
  _High betweenness centrality (0.043) - this node is a cross-community bridge._
- **Are the 14 inferred relationships involving `DualRuntime` (e.g. with `Accept` and `Channel`) actually correct?**
  _`DualRuntime` has 14 INFERRED edges - model-reasoned connections that need verification._
- **What connects `IOBluetooth`, `Security`, `Carbon` to the rest of the system?**
  _11 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `.receive` be split into smaller, more focused modules?**
  _Cohesion score 0.06790890269151138 - nodes in this community are weakly interconnected._
- **Why does `DualRuntime` connect `DualRuntime` to `runtime.py`, `ReliableEventQueue`, `ModeMachine`?**
  _High betweenness centrality (0.043) - this node is a cross-community bridge._
- **Should `runtime.py` be split into smaller, more focused modules?**
  _Cohesion score 0.05501165501165501 - nodes in this community are weakly interconnected._
- **Why does `ProtocolError` connect `DualRuntime` to `runtime.py`, `ReplayWindow`, `ReliableEventQueue`?**
  _High betweenness centrality (0.028) - this node is a cross-community bridge._