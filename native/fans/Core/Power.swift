import Foundation
import IOKit
import IOKit.pwr_mgt

// IOMessage.h iokit_common_msg macros are not imported by Swift.
final class PowerObserver {
    private var port: IONotificationPortRef?
    private var notifier: io_object_t = 0
    private var connection: io_connect_t = 0
    let willSleep: () -> Void
    init(willSleep: @escaping () -> Void) {
        self.willSleep = willSleep
        connection = IORegisterForSystemPower(Unmanaged.passUnretained(self).toOpaque(),&port,{ reference, _, message, argument in
            guard let reference else { return }
            let observer = Unmanaged<PowerObserver>.fromOpaque(reference).takeUnretainedValue()
            if message == 0xe0000280 {
                observer.willSleep()
                IOAllowPowerChange(observer.connection,Int(bitPattern:argument))
            } else if message == 0xe0000270 { IOAllowPowerChange(observer.connection,Int(bitPattern:argument)) }
        },&notifier)
        if let port, let source = IONotificationPortGetRunLoopSource(port)?.takeUnretainedValue() { CFRunLoopAddSource(CFRunLoopGetCurrent(),source,.defaultMode) }
    }
    var available: Bool { connection != 0 }
    deinit {
        if connection != 0 { IODeregisterForSystemPower(&notifier); IOServiceClose(connection) }
        if let port { IONotificationPortDestroy(port) }
    }
}
