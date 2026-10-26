import Foundation
import Darwin

// Runtime lookup keeps unsupported private HID symbols from preventing app launch.
// Protocol constants: Apple vendor temperature usage 0xff00/5, event type 15.
final class HIDTemperatures {
    typealias Create = @convention(c) (CFAllocator?) -> Unmanaged<CFTypeRef>?
    typealias Match = @convention(c) (CFTypeRef, CFDictionary) -> Int32
    typealias Services = @convention(c) (CFTypeRef) -> Unmanaged<CFArray>?
    typealias Property = @convention(c) (CFTypeRef, CFString) -> Unmanaged<CFTypeRef>?
    typealias Event = @convention(c) (CFTypeRef, Int64, Int32, Int64) -> Unmanaged<CFTypeRef>?
    typealias Value = @convention(c) (CFTypeRef, Int32) -> Double
    private let library: UnsafeMutableRawPointer?
    private var client: CFTypeRef?
    private var services: Services?
    private var property: Property?
    private var event: Event?
    private var value: Value?
    init() {
        library = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit",RTLD_LAZY)
        guard let library,
              let c = dlsym(library,"IOHIDEventSystemClientCreate"),
              let m = dlsym(library,"IOHIDEventSystemClientSetMatching"),
              let s = dlsym(library,"IOHIDEventSystemClientCopyServices"),
              let p = dlsym(library,"IOHIDServiceClientCopyProperty"),
              let e = dlsym(library,"IOHIDServiceClientCopyEvent"),
              let v = dlsym(library,"IOHIDEventGetFloatValue") else { return }
        client = unsafeBitCast(c,to:Create.self)(kCFAllocatorDefault)?.takeRetainedValue()
        guard let client else { return }
        _ = unsafeBitCast(m,to:Match.self)(client,["PrimaryUsagePage":0xff00,"PrimaryUsage":5] as CFDictionary)
        services = unsafeBitCast(s,to:Services.self); property = unsafeBitCast(p,to:Property.self)
        event = unsafeBitCast(e,to:Event.self); value = unsafeBitCast(v,to:Value.self)
    }
    func read() -> [Sensor] {
        guard let client, let services, let property, let event, let value,
              let list = services(client)?.takeRetainedValue() else { return [] }
        var result: [Sensor] = []
        for i in 0..<CFArrayGetCount(list) {
            let service = unsafeBitCast(CFArrayGetValueAtIndex(list,i),to:CFTypeRef.self)
            guard let name = property(service,"Product" as CFString)?.takeRetainedValue() as? String,
                  let reading = event(service,15,0,0)?.takeRetainedValue() else { continue }
            let temperature = value(reading,15 << 16)
            guard temperature.isFinite, temperature >= 10, temperature < 130 else { continue }
            if name.contains("pACC") || name.contains("eACC") || name.contains("GPU") || name.contains("SOC") {
                result.append(Sensor(id:"HID:"+name,value:temperature))
            }
        }
        return result.sorted { $0.id < $1.id }
    }
    deinit { client = nil; if let library { dlclose(library) } }
}
