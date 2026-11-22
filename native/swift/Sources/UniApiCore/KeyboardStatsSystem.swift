import Foundation
import CoreGraphics
import Carbon.HIToolbox
import IOKit

extension NativeKeyboardIO {
    public static func production() -> NativeKeyboardIO {
        let observer = NativeKeyboardObserver.shared
        return .init(
            permitted: { CGPreflightListenEventAccess() },
            requestPermission: { CGRequestListenEventAccess() },
            begin: { observer.begin() }, end: { observer.end() }, take: { observer.take() },
            hardware: { hardware(type: observer.keyboardType() ?? Int(LMGetKbdType())) })
    }

    /// Keyboard types macOS assigns to boards it does not recognise.
    private static let genericTypes: Set<Int> = [40, 41, 42]

    static func hardware(type: Int) -> NativeKeyboardHardware {
        let standard: NativeKeyboardLayout.Standard
        switch Int(KBGetLayoutType(Int16(truncatingIfNeeded: type))) {
        case kKeyboardISO: standard = .iso
        case kKeyboardJIS: standard = .jis
        default: standard = .ansi
        }
        return .init(devices: devices(), standard: standard, generic: genericTypes.contains(type))
    }

    /// Names of connected keyboards from the I/O Registry. Reading them needs
    /// no permission and observes no input.
    static func devices() -> [NativeKeyboardDevice] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOHIDDevice"), &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var result: [NativeKeyboardDevice] = []
        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { break }
            defer { IOObjectRelease(service) }
            func value(_ key: String) -> Any? { IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() }
            guard (value("PrimaryUsagePage") as? Int) == 1, (value("PrimaryUsage") as? Int) == 6 else { continue }
            let vendor = value("VendorID") as? Int ?? 0
            let device = NativeKeyboardDevice(name: String((value("Product") as? String ?? "").prefix(80)), builtIn: (value("Built-In") as? Bool) == true,
                                              apple: vendor == 0x05AC || vendor == 0x004C)
            if !result.contains(device) { result.append(device) }
        }
        return result
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
    private var lastType: Int?
    private var port: CFMachPort?
    private var source: CFRunLoopSource?
    private var runLoop: CFRunLoop?

    /// Type of the keyboard that sent the most recent key press.
    func keyboardType() -> Int? { lock.withLock { lastType } }

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
        let keyboard = Int(event.getIntegerValueField(.keyboardEventKeyboardType))
        var repeated = false
        lock.lock(); defer { lock.unlock() }
        if keyboard > 0 { lastType = keyboard }
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
