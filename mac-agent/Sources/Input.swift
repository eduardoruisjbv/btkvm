import AppKit
import CoreGraphics

// USB HID keyboard page -> macOS virtual keycode. Physical key positions keep
// the layout selected in macOS, including its ABNT2/ISO setting.
let keyboardMap: [UInt8: CGKeyCode] = [
    0x04:0, 0x05:11, 0x06:8, 0x07:2, 0x08:14, 0x09:3, 0x0a:5, 0x0b:4,
    0x0c:34, 0x0d:38, 0x0e:40, 0x0f:37, 0x10:46, 0x11:45, 0x12:31, 0x13:35,
    0x14:12, 0x15:15, 0x16:1, 0x17:17, 0x18:32, 0x19:9, 0x1a:13, 0x1b:7,
    0x1c:16, 0x1d:6, 0x1e:18, 0x1f:19, 0x20:20, 0x21:21, 0x22:23, 0x23:22,
    0x24:26, 0x25:28, 0x26:25, 0x27:29, 0x28:36, 0x29:53, 0x2a:51, 0x2b:48,
    0x2c:49, 0x2d:27, 0x2e:24, 0x2f:33, 0x30:30, 0x31:42, 0x32:42, 0x33:41,
    0x34:39, 0x35:50, 0x36:43, 0x37:47, 0x38:44, 0x39:57,
    0x3a:122, 0x3b:120, 0x3c:99, 0x3d:118, 0x3e:96, 0x3f:97,
    0x40:98, 0x41:100, 0x42:101, 0x43:109, 0x44:103, 0x45:111,
    0x49:114, 0x4a:115, 0x4b:116, 0x4c:117, 0x4d:119, 0x4e:121,
    0x4f:124, 0x50:123, 0x51:125, 0x52:126, 0x53:71, 0x54:75, 0x55:67,
    0x56:78, 0x57:69, 0x58:76, 0x59:83, 0x5a:84, 0x5b:85, 0x5c:86,
    0x5d:87, 0x5e:88, 0x5f:89, 0x60:91, 0x61:92, 0x62:82, 0x63:65,
    0x64:10, 0x67:81, 0x68:105, 0x69:107, 0x6a:113, 0x6b:106,
    0x6c:64, 0x6d:79, 0x6e:80, 0x6f:90, 0x85:95, 0x87:94, 0x89:93,
    0xe0:59, 0xe1:56, 0xe2:58, 0xe3:55, 0xe4:62, 0xe5:60, 0xe6:61, 0xe7:54
]
let mediaMap: [UInt8: Int] = [0xe9:0, 0xea:1, 0x6f:2, 0x70:3, 0xe2:7, 0xcd:16, 0xb5:17, 0xb6:18]

final class Input {
    let source = CGEventSource(stateID: .hidSystemState)
    var pressed = Set<UInt16>()
    var x: Int32 = 0
    var y: Int32 = 0
    var wheel: Int32 = 0
    var horizontal: Int32 = 0
    var wheelRemainder: Double = 0
    var horizontalRemainder: Double = 0
    var repeating: UInt16? = nil
    var repeatAt: TimeInterval = 0
    var loggedUnsupported = Set<UInt16>()
    var lastClick: (UInt16, CGPoint, TimeInterval)?
    var clickCounts = [UInt16: Int64]()
    let log: (String) -> Void
    init(log: @escaping (String) -> Void) { self.log = log }

    var flags: CGEventFlags {
        var flags: CGEventFlags = []
        for (usages, mask) in [([UInt16(0x07e0), 0x07e4], CGEventFlags.maskControl),
                                ([UInt16(0x07e1), 0x07e5], .maskShift),
                                ([UInt16(0x07e2), 0x07e6], .maskAlternate),
                                ([UInt16(0x07e3), 0x07e7], .maskCommand)] {
            if usages.contains(where: pressed.contains) { flags.insert(mask) }
        }
        return flags
    }
    func post(_ event: CGEvent?) {
        event?.flags = flags
        event?.post(tap: .cghidEventTap)
    }
    func releaseAll() {
        for usage in pressed.sorted() { set(usage, down: false) }
        repeating = nil
    }
    func baseline(_ mouse: Mouse) {
        x = mouse.x; y = mouse.y; wheel = mouse.wheel; horizontal = mouse.horizontal
        wheelRemainder = 0; horizontalRemainder = 0
    }
    func reconcile(_ want: Set<UInt16>) {
        for usage in pressed.subtracting(want).sorted() { set(usage, down: false) }
        let additions = want.subtracting(pressed).sorted { a, b in
            let aModifier = (0x07e0 ... 0x07e7).contains(a)
            let bModifier = (0x07e0 ... 0x07e7).contains(b)
            return aModifier != bModifier ? aModifier : a < b
        }
        for usage in additions { set(usage, down: true) }
    }
    func set(_ usage: UInt16, down: Bool) {
        guard pressed.contains(usage) != down else { return }
        if down { pressed.insert(usage) } else { pressed.remove(usage) }
        let page = usage >> 8, key = UInt8(truncatingIfNeeded: usage)
        if page == 7, let code = keyboardMap[key] {
            post(CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down))
            if down && key < 0xe0 && key != 0x39 {
                repeating = usage
                let delay = UserDefaults.standard.integer(forKey: "InitialKeyRepeat")
                repeatAt = ProcessInfo.processInfo.systemUptime + Double(delay > 0 ? delay : 25) / 60
            } else if repeating == usage { repeating = nil }
        } else if page == 9 && (1 ... 5).contains(key) {
            let button = CGMouseButton(rawValue: UInt32(key == 1 ? 0 : key == 2 ? 1 : key - 1))!
            let type: CGEventType = key == 1 ? (down ? .leftMouseDown : .leftMouseUp)
                : key == 2 ? (down ? .rightMouseDown : .rightMouseUp) : (down ? .otherMouseDown : .otherMouseUp)
            let position = CGEvent(source: nil)?.location ?? .zero
            if down {
                let now = ProcessInfo.processInfo.systemUptime
                if let previous = lastClick, previous.0 == usage, now - previous.2 <= 0.5,
                   hypot(position.x - previous.1.x, position.y - previous.1.y) <= 4 {
                    clickCounts[usage] = (clickCounts[usage] ?? 1) + 1
                } else { clickCounts[usage] = 1 }
                lastClick = (usage, position, now)
            }
            let event = CGEvent(mouseEventSource: source, mouseType: type,
                                mouseCursorPosition: position, mouseButton: button)
            event?.setIntegerValueField(.mouseEventClickState, value: clickCounts[usage] ?? 1)
            post(event)
        } else if page == 12, let code = mediaMap[key] {
            let data = (code << 16) | ((down ? 0xa : 0xb) << 8)
            let event = NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: [],
                                         timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0,
                                         context: nil, subtype: 8, data1: data, data2: -1)
            event?.cgEvent?.post(tap: .cghidEventTap)
        } else if loggedUnsupported.insert(usage).inserted {
            log(String(format: "HID usage sem mapa macOS: 0x%04x", usage))
        }
    }
    func repeatTick(_ now: TimeInterval) {
        guard let usage = repeating, now >= repeatAt, pressed.contains(usage),
              let code = keyboardMap[UInt8(truncatingIfNeeded: usage)] else { return }
        let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true)
        event?.setIntegerValueField(.keyboardEventAutorepeat, value: 1)
        post(event)
        let interval = UserDefaults.standard.integer(forKey: "KeyRepeat")
        repeatAt = now + Double(interval > 0 ? interval : 2) / 60
    }
    func moveTo(_ targetX: Int32, _ targetY: Int32) {
        let dx = delta(targetX, x), dy = delta(targetY, y)
        x = targetX; y = targetY
        guard dx != 0 || dy != 0 else { return }
        let current = CGEvent(source: nil)?.location ?? .zero
        var point = CGPoint(x: current.x + CGFloat(dx), y: current.y + CGFloat(dy))
        var displayIDs = [CGDirectDisplayID](repeating: 0, count: 32)
        var count: UInt32 = 0
        _ = CGGetActiveDisplayList(32, &displayIDs, &count)
        let screens = displayIDs.prefix(Int(count)).map { CGDisplayBounds($0) }
        if !screens.contains(where: { $0.contains(point) }) {
            let candidates = screens.map { bounds in
                CGPoint(x: max(bounds.minX, min(bounds.maxX - 1, point.x)),
                        y: max(bounds.minY, min(bounds.maxY - 1, point.y)))
            }
            point = candidates.min { a, b in
                hypot(a.x - point.x, a.y - point.y) < hypot(b.x - point.x, b.y - point.y)
            } ?? current
        }
        var type: CGEventType = .mouseMoved
        var button: CGMouseButton = .left
        if pressed.contains(0x0901) { type = .leftMouseDragged }
        else if pressed.contains(0x0902) { type = .rightMouseDragged; button = .right }
        else if let held = pressed.first(where: { (0x0903 ... 0x0905).contains($0) }) {
            type = .otherMouseDragged; button = CGMouseButton(rawValue: UInt32((held & 0xff) - 1))!
        }
        post(CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: button))
    }
    func apply(_ mouse: Mouse, move: Bool = true) {
        if move { moveTo(mouse.x, mouse.y) }
        // One wheel detent (120 units) maps to ten pixels. Keep fractions so
        // high resolution wheels never lose small increments through rounding.
        wheelRemainder += Double(delta(mouse.wheel, wheel)) / 12
        horizontalRemainder += Double(delta(mouse.horizontal, horizontal)) / 12
        wheel = mouse.wheel; horizontal = mouse.horizontal
        let vertical = Int32(clamping: Int64(wheelRemainder.rounded(.towardZero)))
        let lateral = Int32(clamping: Int64(horizontalRemainder.rounded(.towardZero)))
        wheelRemainder -= Double(vertical); horizontalRemainder -= Double(lateral)
        if vertical != 0 || lateral != 0 {
            post(CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                         wheel1: vertical, wheel2: lateral, wheel3: 0))
        }
    }
}
