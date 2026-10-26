import Foundation
import CoreFoundation
import ObjectiveC
import IOKit
import Darwin

/// Signature-checked Swift calls into Apple's existing PowerUI framework.
/// No custom Objective-C helper implements the native app's charging behavior.
/// This adapter is never invoked by fixture tests.
public final class NativePowerUIClient: @unchecked Sendable {
    private let client: NSObject
    private let type: AnyClass
    public static let signatures: [String: [String]] = [
        "initWithClientName:": ["@", "@"], "isMCLSupported": ["B"],
        "availableChargeLimitsWithError:": ["@", "^@"], "getMCLLimitWithError:": ["C", "^@"],
        "isMCLCurrentlyEnabled:": ["Q", "^@"], "setMCLLimit:error:": ["B", "C", "^@"],
        "enableMCL:": ["B", "^@"], "disableMCL:": ["B", "^@"]
    ]
    public static func supportedEncoding(returnType: String, arguments: [String], expected: [String]) -> Bool {
        !expected.isEmpty && returnType == expected[0] && arguments == Array(expected.dropFirst())
    }
    public init() throws {
        guard dlopen(NativeHardwareLocations.powerUIFramework, RTLD_LAZY) != nil, let type = NSClassFromString("PowerUISmartChargeClient") else { throw NativeFailure("Native charge limits are unavailable on this macOS version") }
        for (name, expected) in Self.signatures {
            guard let method = class_getInstanceMethod(type, NSSelectorFromString(name)), method_getNumberOfArguments(method) == UInt32(expected.count + 1) else { throw NativeFailure("The native charging interface changed; no setting was written") }
            let result = method_copyReturnType(method)
            defer { free(result) }
            let arguments = (2..<method_getNumberOfArguments(method)).map { index -> String in let value = method_copyArgumentType(method, index); defer { free(value) }; return value.map { String(cString: $0) } ?? "" }
            guard Self.supportedEncoding(returnType: String(cString: result), arguments: arguments, expected: expected) else { throw NativeFailure("The native charging interface has an incompatible signature") }
        }
        let allocSelector = NSSelectorFromString("alloc"), initSelector = NSSelectorFromString("initWithClientName:")
        guard let allocMethod = class_getClassMethod(type, allocSelector), let initMethod = class_getInstanceMethod(type, initSelector) else { throw NativeFailure("The native charging client could not be created") }
        typealias Allocate = @convention(c) (UnsafeMutableRawPointer, Selector) -> UnsafeMutableRawPointer?
        typealias Initialize = @convention(c) (UnsafeMutableRawPointer, Selector, UnsafeMutableRawPointer) -> UnsafeMutableRawPointer?
        let allocate = unsafeBitCast(method_getImplementation(allocMethod), to: Allocate.self)
        let initialize = unsafeBitCast(method_getImplementation(initMethod), to: Initialize.self)
        let name = "UniApi" as NSString
        guard let allocated = allocate(Unmanaged.passUnretained(type as AnyObject).toOpaque(), allocSelector), let initialized = initialize(allocated, initSelector, Unmanaged.passUnretained(name).toOpaque()) else { throw NativeFailure("The native charging client could not initialize") }
        client = Unmanaged<NSObject>.fromOpaque(initialized).takeRetainedValue()
        self.type = type
    }
    private var pointer: UnsafeMutableRawPointer { Unmanaged.passUnretained(client).toOpaque() }
    private func method(_ name: String) throws -> IMP { guard let method = class_getInstanceMethod(type, NSSelectorFromString(name)) else { throw NativeFailure("The native charging method is unavailable") }; return method_getImplementation(method) }
    private func checked(_ error: UnsafeMutableRawPointer?) throws {
        if let error { throw NativeFailure(Unmanaged<NSError>.fromOpaque(error).takeUnretainedValue().localizedDescription) }
    }
    public func state() throws -> JSONValue {
        typealias Supported = @convention(c) (UnsafeMutableRawPointer, Selector) -> Bool
        typealias Levels = @convention(c) (UnsafeMutableRawPointer, Selector, UnsafeMutablePointer<UnsafeMutableRawPointer?>) -> UnsafeMutableRawPointer?
        typealias Limit = @convention(c) (UnsafeMutableRawPointer, Selector, UnsafeMutablePointer<UnsafeMutableRawPointer?>) -> UInt8
        typealias Enabled = @convention(c) (UnsafeMutableRawPointer, Selector, UnsafeMutablePointer<UnsafeMutableRawPointer?>) -> UInt64
        let supported = unsafeBitCast(try method("isMCLSupported"), to: Supported.self)(pointer, NSSelectorFromString("isMCLSupported"))
        if !supported { return ["ok": true, "supported": false, "levels": [], "limit": nil, "engaged": false, "battery": try NativeBatterySystem.snapshot()] }
        var error: UnsafeMutableRawPointer?
        let levelsPointer = unsafeBitCast(try method("availableChargeLimitsWithError:"), to: Levels.self)(pointer, NSSelectorFromString("availableChargeLimitsWithError:"), &error)
        try checked(error)
        let levels = levelsPointer.map { Unmanaged<NSArray>.fromOpaque($0).takeUnretainedValue() as? [NSNumber] } ?? nil
        error = nil
        let limit = unsafeBitCast(try method("getMCLLimitWithError:"), to: Limit.self)(pointer, NSSelectorFromString("getMCLLimitWithError:"), &error)
        try checked(error); error = nil
        let enabled = unsafeBitCast(try method("isMCLCurrentlyEnabled:"), to: Enabled.self)(pointer, NSSelectorFromString("isMCLCurrentlyEnabled:"), &error)
        try checked(error)
        return ["ok": true, "supported": .bool(supported), "levels": .array((levels ?? []).map { .number($0.doubleValue) }), "limit": .number(Double(limit)), "engaged": .bool(enabled == 1), "battery": try NativeBatterySystem.snapshot()]
    }
    public func set(_ value: Int) throws -> JSONValue {
        let current = try state()
        _ = try NativeHardwarePolicies.batteryTarget(.number(Double(value)), levels: current["levels"].array, hold: false)
        if value == 100 { return try off() }
        typealias Setter = @convention(c) (UnsafeMutableRawPointer, Selector, UInt8, UnsafeMutablePointer<UnsafeMutableRawPointer?>) -> Bool
        var error: UnsafeMutableRawPointer?
        let accepted = unsafeBitCast(try method("setMCLLimit:error:"), to: Setter.self)(pointer, NSSelectorFromString("setMCLLimit:error:"), UInt8(value), &error)
        try checked(error); guard accepted else { throw NativeFailure("macOS did not accept the charge limit") }
        return try state()
    }
    private func change(_ name: String) throws -> JSONValue {
        typealias Change = @convention(c) (UnsafeMutableRawPointer, Selector, UnsafeMutablePointer<UnsafeMutableRawPointer?>) -> Bool
        var error: UnsafeMutableRawPointer?
        let accepted = unsafeBitCast(try method(name), to: Change.self)(pointer, NSSelectorFromString(name), &error)
        try checked(error); guard accepted else { throw NativeFailure("macOS did not accept the charging policy change") }
        return try state()
    }
    public func enable() throws -> JSONValue { try change("enableMCL:") }
    public func off() throws -> JSONValue { try change("disableMCL:") }
}

public enum NativeBatterySystem {
    public static func snapshot() throws -> JSONValue {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return .null }
        defer { IOObjectRelease(service) }
        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS, let properties else { throw NativeFailure("Battery telemetry is unavailable") }
        return snapshot(properties.takeRetainedValue() as NSDictionary)
    }
    static func snapshot(_ p: NSDictionary) -> JSONValue {
        guard let value = p["CurrentCapacity"] as? NSNumber, let external = p["ExternalConnected"] as? NSNumber, let charging = p["IsCharging"] as? NSNumber else { return .null }
        var percent = value.doubleValue
        if percent > 100 {
            guard let current = p["AppleRawCurrentCapacity"] as? NSNumber, let max = p["AppleRawMaxCapacity"] as? NSNumber, max.doubleValue > 0 else { return .null }
            percent = (current.doubleValue / max.doubleValue * 100).rounded()
        }
        guard percent.isFinite, (0...100).contains(percent) else { return .null }
        var result: JSONValue = ["present": true, "percent": .number(percent), "externalConnected": .bool(external.boolValue), "charging": .bool(charging.boolValue), "fullyCharged": .bool((p["FullyCharged"] as? NSNumber)?.boolValue ?? false)]
        let battery = p["BatteryData"] as? NSDictionary, charger = p["ChargerData"] as? NSDictionary
        if let full = battery?["FullChargeCapacity"] as? NSNumber, let design = battery?["DesignCapacity"] as? NSNumber, full.doubleValue > 0, design.doubleValue > 0 { result["health"] = .number((full.doubleValue / design.doubleValue * 100).rounded()) }
        if let cycles = p["CycleCount"] as? NSNumber { result["cycleCount"] = .number(cycles.doubleValue) }
        if let reason = charger?["NotChargingReason"] as? NSNumber { result["notChargingReason"] = .number(reason.doubleValue) }
        var telemetry: JSONObject = [:]
        for key in ["Amperage", "InstantAmperage", "Voltage", "Temperature", "VirtualTemperature", "SkinTemperature", "AppleRawCurrentCapacity", "AppleRawMaxCapacity", "NominalChargeCapacity", "MaxCapacity", "DesignCapacity", "TimeRemaining", "AvgTimeToEmpty", "AvgTimeToFull", "ExternalChargeCapable", "AppleRawExternalConnected"] {
            if let number = p[key] as? NSNumber { telemetry[key] = .number(Double(number.int64Value)) }
        }
        for group in ["PowerTelemetryData", "BatteryData", "ChargerData", "AdapterDetails"] {
            guard let source = p[group] as? NSDictionary else { continue }
            var selected: JSONObject = [:]
            for key in ["SystemPowerIn", "SystemLoad", "BatteryPower", "SystemCurrentIn", "SystemVoltageIn", "WallEnergyEstimate", "AdapterEfficiencyLoss", "PowerTelemetryErrorCount", "FullChargeCapacity", "NominalChargeCapacity", "RemainingCapacity", "DesignCapacity", "CurrentCapacity", "CycleCount", "NotChargingReason", "SlowChargingReason", "IsCharging", "Watts", "Current", "AdapterVoltage"] {
                if let number = source[key] as? NSNumber { selected[key] = .number(Double(number.int64Value)) }
            }
            telemetry[group] = .object(selected)
        }
        result["telemetry"] = .object(telemetry)
        return result
    }
}
