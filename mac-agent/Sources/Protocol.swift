import Foundation
import CryptoKit

let serviceUUID = "8ea6e923-cc7d-4b58-93c5-72eb7376b8f1"

enum WireError: Error { case invalid, replay, session }

extension Data {
    mutating func put<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }
}

struct Reader {
    let bytes: [UInt8]
    var offset = 0
    init(_ data: Data) { bytes = Array(data) }
    mutating func take(_ count: Int) throws -> Data {
        guard count >= 0, offset + count <= bytes.count else { throw WireError.invalid }
        defer { offset += count }
        return Data(bytes[offset ..< offset + count])
    }
    mutating func int<T: FixedWidthInteger>(_ type: T.Type) throws -> T {
        let data = try take(MemoryLayout<T>.size)
        var value: T = 0
        for (i, byte) in data.enumerated() { value |= T(truncatingIfNeeded: byte) << (8 * i) }
        return value
    }
    var done: Bool { offset == bytes.count }
}

func newer(_ value: UInt32, than old: UInt32) -> Bool {
    let distance = value &- old
    return distance != 0 && distance < 0x80000000
}
func newerEpoch(_ value: UInt8, than old: UInt8) -> Bool {
    let distance = value &- old
    return distance != 0 && distance < 128
}
func delta(_ value: Int32, _ old: Int32) -> Int32 { value &- old }

struct Replay {
    var high: UInt64? = nil
    var seen = Set<UInt64>()
    mutating func accept(_ counter: UInt64) throws {
        if let high = high, counter <= high && high - counter >= 128 { throw WireError.replay }
        guard !seen.contains(counter) else { throw WireError.replay }
        if high == nil || counter > high! { high = counter }
        let latest = high!
        seen = seen.filter { latest - $0 < 128 }
        seen.insert(counter)
    }
}

struct ReceiveStats {
    var received: UInt32 = 0
    var lost: UInt32 = 0
    var duplicates: UInt32 = 0
    var outOfOrder: UInt32 = 0
    var highest: UInt64? = nil
    mutating func record(_ ctr: UInt64) {
        received &+= 1
        if let old = highest {
            if ctr > old { lost &+= UInt32(truncatingIfNeeded: ctr - old - 1) }
            else {
                outOfOrder &+= 1
                if lost > 0 { lost -= 1 }
            }
        } else { lost &+= UInt32(truncatingIfNeeded: ctr) }
        if highest == nil || ctr > highest! { highest = ctr }
    }
}

final class Session {
    let id: UInt32
    let tx: SymmetricKey
    let rx: SymmetricKey
    var counters: [UInt8: UInt64] = [0: 0, 1: 0]
    var windows: [UInt8: Replay] = [0: Replay(), 1: Replay()]
    var stats: [UInt8: ReceiveStats] = [0: ReceiveStats(), 1: ReceiveStats()]

    init(id: UInt32, privateKey: Curve25519.KeyAgreement.PrivateKey, peerKey: Data,
         pcNonce: Data, macNonce: Data) throws {
        self.id = id
        let peer = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerKey)
        let secret = try privateKey.sharedSecretFromKeyAgreement(with: peer)
        let material = secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: pcNonce + macNonce,
                                                     sharedInfo: Data("btkvm/1".utf8), outputByteCount: 64)
        let data = material.withUnsafeBytes { Data($0) }
        rx = SymmetricKey(data: data.prefix(32))
        tx = SymmetricKey(data: data.suffix(32))
    }
    func nonce(_ direction: UInt8, _ channel: UInt8, _ counter: UInt64) throws -> ChaChaPoly.Nonce {
        var bytes = Data([direction, channel, 0, 0]); bytes.put(counter)
        return try ChaChaPoly.Nonce(data: bytes)
    }
    func encode(_ kind: UInt8, _ channel: UInt8, _ payload: Data) throws -> Data {
        guard let counter = counters[channel], counter < UInt64.max,
              payload.count <= 1168 else { throw WireError.invalid }
        counters[channel] = counter + 1
        var head = Data([0xb7, 1, kind, channel]); head.put(id); head.put(counter)
        let box = try ChaChaPoly.seal(payload, using: tx, nonce: nonce(1, channel, counter), authenticating: head)
        return head + box.ciphertext + box.tag
    }
    func decode(_ packet: Data, _ channel: UInt8) throws -> (UInt8, Data) {
        guard packet.count >= 32 && packet.count <= 1200 else { throw WireError.invalid }
        var reader = Reader(packet)
        guard try reader.int(UInt8.self) == 0xb7, try reader.int(UInt8.self) == 1 else { throw WireError.invalid }
        let kind = try reader.int(UInt8.self)
        guard try reader.int(UInt8.self) == channel, try reader.int(UInt32.self) == id else { throw WireError.session }
        let ctr = try reader.int(UInt64.self)
        let box = try ChaChaPoly.SealedBox(nonce: nonce(0, channel, ctr),
                                         ciphertext: packet.dropFirst(16).dropLast(16), tag: packet.suffix(16))
        let plaintext = try ChaChaPoly.open(box, using: rx, authenticating: packet.prefix(16))
        do { try windows[channel]!.accept(ctr) }
        catch {
            stats[channel]!.duplicates &+= 1
            throw error
        }
        stats[channel]!.record(ctr)
        return (kind, plaintext)
    }
}

struct Mouse {
    var sample: UInt32
    var epoch: UInt8
    var x: Int32
    var y: Int32
    var wheel: Int32
    var horizontal: Int32
    var time: UInt32
    init(_ reader: inout Reader) throws {
        sample = try reader.int(UInt32.self); epoch = try reader.int(UInt8.self)
        x = try reader.int(Int32.self); y = try reader.int(Int32.self)
        wheel = try reader.int(Int32.self); horizontal = try reader.int(Int32.self)
        time = try reader.int(UInt32.self)
    }
}

struct Transition {
    let usage: UInt16
    let down: Bool
    let x: Int32
    let y: Int32
    let sample: UInt32
    init(_ reader: inout Reader) throws {
        usage = try reader.int(UInt16.self)
        let value = try reader.int(UInt8.self)
        guard value <= 1 else { throw WireError.invalid }
        down = value == 1
        x = try reader.int(Int32.self); y = try reader.int(Int32.self)
        sample = try reader.int(UInt32.self)
    }
}

struct Snapshot {
    let epoch: UInt8
    let bootstrap: Bool
    let nextEvent: UInt32
    let mouse: Mouse
    let pressed: Set<UInt16>
    init(_ data: Data) throws {
        var reader = Reader(data)
        epoch = try reader.int(UInt8.self)
        let count = try reader.int(UInt8.self)
        let flags = try reader.int(UInt8.self)
        guard count <= 64 && flags <= 1 else { throw WireError.invalid }
        bootstrap = flags == 1
        nextEvent = try reader.int(UInt32.self)
        mouse = try Mouse(&reader)
        guard mouse.epoch == epoch else { throw WireError.invalid }
        var keys = Set<UInt16>()
        for _ in 0 ..< count { keys.insert(try reader.int(UInt16.self)) }
        guard reader.done else { throw WireError.invalid }
        pressed = keys
    }
}
