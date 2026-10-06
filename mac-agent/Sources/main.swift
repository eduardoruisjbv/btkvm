import AppKit
import CoreGraphics
import Darwin

let logPath = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/btkvm-agent.log")
try? FileManager.default.createDirectory(at: logPath.deletingLastPathComponent(), withIntermediateDirectories: true)
if !FileManager.default.fileExists(atPath: logPath.path) { _ = FileManager.default.createFile(atPath: logPath.path, contents: Data()) }
let logFile = try? FileHandle(forWritingTo: logPath)
logFile?.seekToEndOfFile()
func log(_ message: String) {
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
    print(line, terminator: "")
    if let bytes = line.data(using: .utf8) { logFile?.write(bytes) }
}

final class Observer {
    var tap: CFMachPort?
    var runSource: CFRunLoopSource?
    var lastMouse: Double?
    var intervals = [Double]()
    var timer: Timer?
    func start() {
        guard CGPreflightListenEventAccess() || CGRequestListenEventAccess() else {
            log("Conceda Monitoramento de Entrada ao btkvm-agent para --observe"); exit(1)
        }
        let types: [CGEventType] = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                options: .listenOnly, eventsOfInterest: mask, callback: { _, type, event, context in
            let observer = Unmanaged<Observer>.fromOpaque(context!).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = observer.tap { CGEvent.tapEnable(tap: tap, enable: true) }
            } else {
                let now = Double(event.timestamp) / 1_000_000
                if let previous = observer.lastMouse {
                    let interval = now - previous
                    if interval > 0 && interval <= 100 { observer.intervals.append(interval) }
                }
                observer.lastMouse = now
            }
            return Unmanaged.passUnretained(event)
        }, userInfo: Unmanaged.passUnretained(self).toOpaque())
        guard let tap = tap else { log("Falha ao criar escuta de entrada"); exit(1) }
        runSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let samples = self.intervals.sorted(); self.intervals.removeAll()
            if !samples.isEmpty {
                let p95 = samples[max(0, Int(ceil(Double(samples.count) * 0.95)) - 1)]
                let p99 = samples[max(0, Int(ceil(Double(samples.count) * 0.99)) - 1)]
                log("observe 5s: n=\(samples.count), p95=\(p95)ms, p99=\(p99)ms; sem RTT")
            }
        }
        log("--observe: intervalos do mouse recebidos pelo macOS, sem injeção nem rede; pausas >100ms excluídas")
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.contains("--help") { print("btkvm-agent [--host AA-BB-CC-DD-EE-FF] | --observe"); exit(0) }
var host: String?
if let index = arguments.firstIndex(of: "--host") {
    guard index + 1 < arguments.count else { log("Falta endereço após --host"); exit(1) }
    host = arguments[index + 1]
}
_ = NSApplication.shared
NSApp.setActivationPolicy(.accessory)
var observer: Observer?
var agent: Agent?
if arguments.contains("--observe") { observer = Observer(); observer?.start() }
else {
    let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
    if !AXIsProcessTrustedWithOptions(options) { log("Conceda Acessibilidade ao btkvm-agent; usando HID enquanto isso") }
    do { agent = try Agent(host: host, log: log) }
    catch { log("Não foi possível iniciar: \(error)"); exit(1) }
}
var signals = [DispatchSourceSignal]()
for value in [SIGINT, SIGTERM] {
    signal(value, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: value, queue: .main)
    source.setEventHandler { agent?.stop(); exit(0) }
    source.resume(); signals.append(source)
}
RunLoop.main.run()
