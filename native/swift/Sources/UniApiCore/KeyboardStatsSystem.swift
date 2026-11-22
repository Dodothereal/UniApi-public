import Foundation
import CoreGraphics
import Carbon.HIToolbox

extension NativeKeyboardIO {
    public static func production() -> NativeKeyboardIO {
        let observer = NativeKeyboardObserver.shared
        return .init(
            permitted: { CGPreflightListenEventAccess() },
            requestPermission: { CGRequestListenEventAccess() },
            begin: { observer.begin() }, end: { observer.end() }, take: { observer.take() },
            iso: { KBGetLayoutType(Int16(truncatingIfNeeded: LMGetKbdType())) == UInt32(kKeyboardISO) })
    }
}

/// A listen-only observer of key presses. It cannot change, delay or
/// synthesize input, and macOS withholds presses in secure text fields.
final class NativeKeyboardObserver: @unchecked Sendable {
    static let shared = NativeKeyboardObserver()
    private static let capacity = 8_192
    private let lock = NSLock()
    private var events: [NativeKeyboardEvent] = []
    private var held: Set<Int> = []
    private var port: CFMachPort?
    private var source: CFRunLoopSource?
    private var runLoop: CFRunLoop?

    func take() -> [NativeKeyboardEvent] {
        lock.withLock { defer { events.removeAll(keepingCapacity: true) }; return events }
    }

    func begin() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if port != nil { return true }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue) | CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly, eventsOfInterest: mask,
                                           callback: { _, type, event, context in
            if let context { Unmanaged<NativeKeyboardObserver>.fromOpaque(context).takeUnretainedValue().observe(type, event) }
            return Unmanaged.passUnretained(event)
        }, userInfo: Unmanaged.passUnretained(self).toOpaque()),
              let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else { return false }
        self.port = port; self.source = source; held.removeAll()
        let thread = Thread { [weak self] in
            guard let self else { return }
            let current = CFRunLoopGetCurrent()
            self.lock.withLock { self.runLoop = current }
            CFRunLoopAddSource(current, source, .commonModes)
            CGEvent.tapEnable(tap: port, enable: true)
            CFRunLoopRun()
        }
        thread.name = "UniApi keyboard statistics"; thread.qualityOfService = .utility
        thread.start()
        return true
    }

    func end() {
        lock.lock(); defer { lock.unlock() }
        guard let port else { return }
        CGEvent.tapEnable(tap: port, enable: false)
        if let runLoop, let source { CFRunLoopRemoveSource(runLoop, source, .commonModes); CFRunLoopStop(runLoop) }
        CFMachPortInvalidate(port)
        self.port = nil; source = nil; runLoop = nil; held.removeAll()
    }

    private func observe(_ type: CGEventType, _ event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let port = lock.withLock({ self.port }) { CGEvent.tapEnable(tap: port, enable: true) }
            return
        }
        let code = Int(event.getIntegerValueField(.keyboardEventKeycode)), flags = event.flags
        var repeated = false
        lock.lock(); defer { lock.unlock() }
        if type == .flagsChanged {
            // One event per modifier press and release; only presses count.
            let active: Bool
            switch code {
            case 54, 55: active = flags.contains(.maskCommand)
            case 56, 60: active = flags.contains(.maskShift)
            case 58, 61: active = flags.contains(.maskAlternate)
            case 59, 62: active = flags.contains(.maskControl)
            case 63: active = flags.contains(.maskSecondaryFn)
            case 57: active = true
            default: return
            }
            if code != 57 {
                guard active, !held.contains(code) else { held.remove(code); return }
                held.insert(code)
            }
        } else if type == .keyDown {
            repeated = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        } else { return }
        guard events.count < Self.capacity else { return }
        events.append(.init(code: code, command: flags.contains(.maskCommand), control: flags.contains(.maskControl),
                            option: flags.contains(.maskAlternate), shift: flags.contains(.maskShift), repeated: repeated,
                            time: Date().timeIntervalSince1970 * 1000))
    }
}
