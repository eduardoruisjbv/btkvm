import AppKit
import CryptoKit
import IOBluetooth
import Security
import Darwin
import Carbon
import CoreWLAN

func localIPv4() -> [Data] {
    var head: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&head) == 0 else { return [] }
    defer { freeifaddrs(head) }
    var result = [Data](), cursor = head
    while let entry = cursor {
        let item = entry.pointee
        if let address = item.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
           item.ifa_flags & UInt32(IFF_UP) != 0, item.ifa_flags & UInt32(IFF_LOOPBACK) == 0 {
            var raw = UnsafeRawPointer(address).assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr.s_addr
            let data = withUnsafeBytes(of: &raw) { Data($0) }
            if !result.contains(data) { result.append(data) }
        }
        cursor = item.ifa_next
    }
    return Array(result.prefix(8))
}

final class Agent: NSObject, IOBluetoothRFCOMMChannelDelegate, IOBluetoothDeviceAsyncCallbacks {
    let input: Input
    let log: (String) -> Void
    let host: String?
    let udp: Int32
    var udpPort: UInt16 = 0, pcPort: UInt16 = 0
    var udpPeer: sockaddr_in?
    var udpSource: DispatchSourceRead?
    var channel: IOBluetoothRFCOMMChannel?
    var device: IOBluetoothDevice?
    var discovery = [IOBluetoothDevice]()
    var discovering = false
    var discoverUntil: TimeInterval = 0, retryAt: TimeInterval = 0
    var stream = Data(), output = Data()
    var writes = [UnsafeMutableRawPointer: Int]()
    var writing = false
    var session: Session?
    var epoch: UInt8?
    var prepared = false, enabled = false, blocked = false, sleeping = false
    var needsResume = false
    var nextEvent: UInt32 = 0
    var eventBuffer = [UInt32: [Transition]]()
    var pendingSnapshot: Snapshot?
    var lastMouse: Mouse?
    var pointerSample: UInt32?
    var lastAuthenticated: TimeInterval = 0
    var lastTelemetry: TimeInterval = 0
    var timer: Timer?
    var observers = [NSObjectProtocol]()

    init(host: String?, log: @escaping (String) -> Void) throws {
        self.host = host; self.log = log; input = Input(log: log)
        udp = Darwin.socket(AF_INET, SOCK_DGRAM, 0)
        guard udp >= 0 else { throw WireError.invalid }
        super.init()
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        let result = withUnsafePointer(to: &address) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(udp, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else { Darwin.close(udp); throw WireError.invalid }
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(udp, $0, &size) }
        }
        udpPort = UInt16(bigEndian: address.sin_port)
        _ = fcntl(udp, F_SETFL, O_NONBLOCK)
        let source = DispatchSource.makeReadSource(fileDescriptor: udp, queue: .main)
        source.setEventHandler { [weak self] in self?.readUDP() }
        source.resume(); udpSource = source
        timer = Timer.scheduledTimer(withTimeInterval: 0.004, repeats: true) { [weak self] _ in self?.tick() }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification,
                     NSWorkspace.screensDidSleepNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.sleeping = true; self?.disable(sendBye: true)
            })
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification,
                     NSWorkspace.screensDidWakeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.sleeping = false })
        }
        log("UDP porta \(udpPort); aguardando btkvm pareado")
    }
    var canInject: Bool {
        guard !sleeping && !NSNumber(value: IsSecureEventInputEnabled()).boolValue && AXIsProcessTrusted(),
              let current = CGSessionCopyCurrentDictionary() as? [String: Any],
              current[kCGSessionOnConsoleKey as String] as? Bool == true,
              current[kCGSessionLoginDoneKey as String] as? Bool == true else { return false }
        // Optional WindowServer key; supported session/secure-input checks also gate injection.
        return current["CGSSessionScreenIsLocked"] as? Bool != true
    }
    func disable(sendBye: Bool = false) {
        input.releaseAll(); enabled = false; prepared = false
        eventBuffer.removeAll(); pendingSnapshot = nil; lastMouse = nil; pointerSample = nil
        if sendBye { sendBoth(0x3f, Data()) }
    }
    func stop() {
        disable(sendBye: true); timer?.invalidate()
        _ = channel?.close(); udpSource?.cancel(); Darwin.close(udp)
    }
    func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        if !canInject {
            if !blocked { disable(sendBye: true); needsResume = true; log("Input injection unavailable: falling back to HID") }
            blocked = true
        } else { blocked = false }
        if enabled && now - lastAuthenticated > 2 { disable(sendBye: true); needsResume = true; log("Watchdog: released keys after 2 seconds") }
        if enabled && !blocked { input.repeatTick(now) }
        if discovering && now > discoverUntil { discovering = false; device = nil }
        if channel == nil && !discovering && now >= retryAt && !sleeping { discover() }
        if now - lastTelemetry >= 5 {
            let wifi = CWWiFiClient.shared().interface()
            let band = wifi?.wlanChannel()?.channelBand.rawValue
            log("telemetry: agent=\(enabled), BT=\(channel != nil), wifi_rssi=\(wifi?.rssiValue() ?? 0), wifi_band=\(band.map { String($0) } ?? "unavailable"), rx=\(session?.stats.description ?? "no session")")
            lastTelemetry = now
        }
        flush()
    }
    func discover() {
        retryAt = ProcessInfo.processInfo.systemUptime + 3
        if discovery.isEmpty {
            discovery = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []).filter {
                host == nil || ($0.addressString ?? "").caseInsensitiveCompare(host!) == .orderedSame
            }
        }
        guard !discovery.isEmpty else { return }
        let candidate = discovery.removeFirst()
        guard candidate.isPaired() else { return }
        device = candidate; discovering = true; discoverUntil = ProcessInfo.processInfo.systemUptime + 8
        if candidate.performSDPQuery(self) != kIOReturnSuccess { discovering = false }
    }
    func connectionComplete(_ device: IOBluetoothDevice!, status: IOReturn) {}
    func remoteNameRequestComplete(_ device: IOBluetoothDevice!, status: IOReturn) {}
    func sdpQueryComplete(_ candidate: IOBluetoothDevice!, status: IOReturn) {
        guard discovering, let device = device, device == candidate else { return }
        discovering = false
        guard status == kIOReturnSuccess else { return }
        let uuid = UUID(uuidString: serviceUUID)!.uuid
        let bytes = withUnsafeBytes(of: uuid) { Data($0) }
        guard let record = candidate.getServiceRecord(for: IOBluetoothSDPUUID(data: bytes)) else { return }
        var id: BluetoothRFCOMMChannelID = 0
        guard record.getRFCOMMChannelID(&id) == kIOReturnSuccess else { return }
        var opened: IOBluetoothRFCOMMChannel?
        if candidate.openRFCOMMChannelSync(&opened, withChannelID: id, delegate: self) == kIOReturnSuccess {
            channel = opened; stream.removeAll(); output.removeAll(); writing = false
            log("RFCOMM conectado a \(candidate.addressString ?? "PC")")
        }
    }
    func rfcommChannelClosed(_ closed: IOBluetoothRFCOMMChannel!) {
        guard channel == closed else { return }
        channel = nil; output.removeAll(); stream.removeAll(); writing = false
        log("RFCOMM fechado; LAN continua enquanto houver heartbeat autenticado")
    }
    func rfcommChannelData(_ source: IOBluetoothRFCOMMChannel!, data pointer: UnsafeMutableRawPointer!, length: Int) {
        guard source == channel, pointer != nil, length > 0 else { return }
        stream.append(Data(bytes: pointer, count: length))
        do {
            while stream.count >= 2 {
                var reader = Reader(stream)
                let size = Int(try reader.int(UInt16.self))
                guard size >= 16 && size <= 1200 else { throw WireError.invalid }
                if stream.count < size + 2 { break }
                let packet = Data(stream.dropFirst(2).prefix(size))
                stream = Data(stream.dropFirst(size + 2))
                do {
                    if packet[2] == 1 { try hello(packet) } else { try receive(packet, 1) }
                } catch { log("Pacote RFCOMM rejeitado: \(error)") }
            }
        } catch { stream.removeAll(); _ = channel?.close() }
    }
    func rfcommChannelWriteComplete(_ source: IOBluetoothRFCOMMChannel!, refcon: UnsafeMutableRawPointer!, status: IOReturn) {
        if let pointer = refcon, writes.removeValue(forKey: pointer) != nil { pointer.deallocate() }
        guard source == channel else { return }
        writing = false
        if status != kIOReturnSuccess { _ = channel?.close(); channel = nil; output.removeAll() }
        flush()
    }
    func flush() {
        guard let channel = channel, !writing, !output.isEmpty else { return }
        let count = min(output.count, Int(channel.getMTU()))
        guard count > 0 else { return }
        let pointer = UnsafeMutableRawPointer.allocate(byteCount: count, alignment: 1)
        output.prefix(count).copyBytes(to: pointer.assumingMemoryBound(to: UInt8.self), count: count)
        writes[pointer] = count; writing = true
        let result = channel.writeAsync(pointer, length: UInt16(count), refcon: pointer)
        if result == kIOReturnSuccess { output = Data(output.dropFirst(count)) }
        else { writes.removeValue(forKey: pointer); pointer.deallocate(); writing = false }
    }
    func enqueue(_ packet: Data) {
        guard channel != nil, output.count < 4096 else { return }
        output.put(UInt16(packet.count)); output.append(packet); flush()
    }
    func send(_ kind: UInt8, _ payload: Data, _ link: UInt8) {
        guard let session = session, let packet = try? session.encode(kind, link, payload) else { return }
        if link == 1 { enqueue(packet) }
        else if var peer = udpPeer {
            packet.withUnsafeBytes { buffer in
                _ = withUnsafePointer(to: &peer) { p in
                    p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        sendto(udp, buffer.baseAddress, packet.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
        }
    }
    func sendBoth(_ kind: UInt8, _ payload: Data) { send(kind, payload, 0); send(kind, payload, 1) }
    func hello(_ packet: Data) throws {
        guard let device = channel?.getDevice(), device.isPaired(), device.getEncryptionMode() != 0 else { throw WireError.invalid }
        var reader = Reader(packet)
        guard try reader.int(UInt8.self) == 0xb7, try reader.int(UInt8.self) == 1,
              try reader.int(UInt8.self) == 1, try reader.int(UInt8.self) == 1,
              try reader.int(UInt32.self) == 0, try reader.int(UInt64.self) == 0 else { throw WireError.invalid }
        let peerKey = try reader.take(32), pcNonce = try reader.take(16)
        let port = try reader.int(UInt16.self), id = try reader.int(UInt32.self)
        guard reader.done && port != 0 && id != 0 else { throw WireError.invalid }
        let addresses = localIPv4()
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        var nonce = Data(count: 16)
        let result = nonce.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        guard result == errSecSuccess else { throw WireError.invalid }
        let fresh = try Session(id: id, privateKey: privateKey, peerKey: peerKey, pcNonce: pcNonce, macNonce: nonce)
        disable(); session = fresh; pcPort = port; udpPeer = nil; epoch = nil; nextEvent = 0
        needsResume = false
        lastAuthenticated = ProcessInfo.processInfo.systemUptime
        var accept = Data([0xb7, 1, 2, 1]); accept.put(UInt32(0)); accept.put(UInt64(0))
        accept.append(privateKey.publicKey.rawRepresentation); accept.append(nonce)
        accept.put(UInt8(addresses.count)); accept.put(udpPort)
        for address in addresses { accept.append(address) }
        enqueue(accept); log("X25519 session \(id); injection awaits MODE + SNAPSHOT")
    }
    func readUDP() {
        for _ in 0 ..< 32 {
            var buffer = [UInt8](repeating: 0, count: 1201), peer = sockaddr_in()
            var size = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = withUnsafeMutablePointer(to: &peer) { p in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(udp, &buffer, buffer.count, 0, $0, &size) }
            }
            if count < 0 { break }
            guard UInt16(bigEndian: peer.sin_port) == pcPort else { continue }
            do {
                if let previous = udpPeer, previous.sin_addr.s_addr != peer.sin_addr.s_addr { continue }
                try receive(Data(buffer.prefix(count)), 0, peer: peer)
            } catch { /* AEAD/replay failures cannot change state. */ }
        }
    }
    func receive(_ packet: Data, _ link: UInt8, peer: sockaddr_in? = nil) throws {
        guard let session = session else { return }
        let (kind, payload) = try session.decode(packet, link)
        if let peer = peer { udpPeer = peer }
        lastAuthenticated = ProcessInfo.processInfo.systemUptime
        var reader = Reader(payload)
        switch kind {
        case 0x20:
            let stamp = try reader.int(UInt32.self), hbEpoch = try reader.int(UInt8.self)
            _ = try reader.int(UInt16.self)
            guard reader.done else { throw WireError.invalid }
            if let epoch = epoch, newerEpoch(hbEpoch, than: epoch) { disable(); self.epoch = hbEpoch }
            guard canInject else { return }
            if needsResume { sendBoth(0x3f, Data()) }
            let stats = session.stats[link]!
            var ack = Data(); ack.put(stamp); ack.put(hbEpoch)
            ack.put(stats.received); ack.put(stats.lost); ack.put(stats.duplicates); ack.put(stats.outOfOrder)
            send(0x21, ack, link)
        case 0x30:
            let command = try reader.int(UInt8.self), newEpoch = try reader.int(UInt8.self)
            guard reader.done && (command == 1 || command == 2) else { throw WireError.invalid }
            if let old = epoch, old != newEpoch && !newerEpoch(newEpoch, than: old) { return }
            if command == 1 { disable(); epoch = newEpoch; needsResume = false }
            else {
                guard canInject else { return }
                if epoch != newEpoch || (!prepared && !enabled) {
                    disable(); epoch = newEpoch; prepared = true; nextEvent = 0
                    needsResume = false
                }
            }
            sendBoth(0x31, payload)
        case 0x13:
            let snapshot = try Snapshot(payload)
            guard snapshot.epoch == epoch && canInject else { return }
            if snapshot.bootstrap {
                if prepared && !enabled {
                    input.baseline(snapshot.mouse); lastMouse = snapshot.mouse; nextEvent = snapshot.nextEvent
                    pointerSample = snapshot.mouse.sample
                    eventBuffer.removeAll(); input.reconcile(snapshot.pressed); enabled = true; prepared = false
                    log("AGENT epoch \(snapshot.epoch)")
                }
                if enabled { sendBoth(0x14, Data([snapshot.epoch])) }
            } else if enabled {
                if nextEvent == snapshot.nextEvent { input.reconcile(snapshot.pressed) }
                else if newer(snapshot.nextEvent, than: nextEvent) { pendingSnapshot = snapshot }
            }
        case 0x10:
            let mouse = try Mouse(&reader)
            guard reader.done else { throw WireError.invalid }
            guard enabled && !blocked && mouse.epoch == epoch else { return }
            if lastMouse == nil || newer(mouse.sample, than: lastMouse!.sample) {
                let move = pointerSample == nil || newer(mouse.sample, than: pointerSample!)
                input.apply(mouse, move: move); lastMouse = mouse
                if move { pointerSample = mouse.sample }
            }
        case 0x11:
            let seq = try reader.int(UInt32.self), evEpoch = try reader.int(UInt8.self)
            let count = try reader.int(UInt8.self)
            guard count > 0 && count <= 64 else { throw WireError.invalid }
            var transitions = [Transition]()
            for _ in 0 ..< count { transitions.append(try Transition(&reader)) }
            guard reader.done else { throw WireError.invalid }
            guard enabled && !blocked && evEpoch == epoch else { return }
            if seq &- nextEvent < 64 && eventBuffer[seq] == nil { eventBuffer[seq] = transitions }
            var appliedSample: UInt32?
            while let batch = eventBuffer.removeValue(forKey: nextEvent) {
                for event in batch {
                    input.moveTo(event.x, event.y); input.set(event.usage, down: event.down)
                    appliedSample = event.sample
                    if pointerSample == nil || newer(event.sample, than: pointerSample!) { pointerSample = event.sample }
                }
                nextEvent &+= 1
            }
            // Restore a newer pointer sample after a click placed at its event coordinates.
            if let mouse = lastMouse, let sample = appliedSample, newer(mouse.sample, than: sample) {
                input.moveTo(mouse.x, mouse.y)
            }
            if let snapshot = pendingSnapshot {
                if snapshot.nextEvent == nextEvent { input.reconcile(snapshot.pressed); pendingSnapshot = nil }
                else if newer(nextEvent, than: snapshot.nextEvent) { pendingSnapshot = nil }
            }
            let base = nextEvent &- 1
            var bitmap: UInt64 = 0
            for seq in eventBuffer.keys {
                let bit = seq &- base
                if bit >= 1 && bit <= 64 { bitmap |= UInt64(1) << (bit - 1) }
            }
            var ack = Data(); ack.put(base); ack.put(bitmap); ack.put(evEpoch)
            sendBoth(0x12, ack)
        case 0x3f:
            guard payload.isEmpty else { throw WireError.invalid }
            disable()
        default: throw WireError.invalid
        }
    }
}
