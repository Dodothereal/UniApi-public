//
//  uniapi-battery
//
//  Sets macOS's own battery charge limit, the one System Settings > Battery
//  shows, through PowerUI's SmartCharge client.
//
//  Native MCL levels are read from PowerUI. The separately installed daemon
//  tests charging-only control for lower targets; it never substitutes adapter
//  cycling for a charging limit. Private API signatures are checked at runtime.
//
//  Build: native/battery/build.sh

#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <dlfcn.h>
#import "hold.h"
#import "smc.h"

// PowerUI is a private framework: there is no header, so every call goes
// through objc_msgSend with the signature read off the runtime. The casts
// below match the type encodings the runtime reports; `unsigned char` for the
// percentage is theirs, not a choice of ours.
#define MSG(ret, ...) ((ret (*)(id, SEL, ##__VA_ARGS__))objc_msgSend)

static id gClient;

static void emit(NSDictionary *value) {
    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingSortedKeys error:&error];
    if (!data) {
        fputs("{\"ok\":false,\"error\":\"Could not encode the reply.\"}\n", stdout);
        exit(1);
    }
    fwrite(data.bytes, 1, data.length, stdout);
    fputc('\n', stdout);
}

static void fail(NSString *message, int code) {
    emit(@{ @"ok": @NO, @"error": message });
    exit(code);
}

/// Loads PowerUI and builds the SmartCharge client. Returns nil where the
/// framework or the class is absent, which is what an older macOS looks like.
static id makeClient(void) {
    if (!dlopen("/System/Library/PrivateFrameworks/PowerUI.framework/PowerUI", RTLD_LAZY)) return nil;
    Class clientClass = objc_getClass("PowerUISmartChargeClient");
    if (!clientClass) return nil;
    // A private selector may survive an OS update with a different signature.
    // Refuse that runtime rather than calling it through an incompatible cast.
    NSDictionary *signatures = @{
        @"isMCLSupported": @[@"B"],
        @"availableChargeLimitsWithError:": @[@"@", @"^@"],
        @"getMCLLimitWithError:": @[@"C", @"^@"],
        @"isMCLCurrentlyEnabled:": @[@"Q", @"^@"],
        @"setMCLLimit:error:": @[@"B", @"C", @"^@"],
        @"enableMCL:": @[@"B", @"^@"],
        @"disableMCL:": @[@"B", @"^@"],
    };
    for (NSString *name in signatures) {
        Method method = class_getInstanceMethod(clientClass, NSSelectorFromString(name));
        if (!method) return nil;
        NSMethodSignature *signature = [NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(method)];
        NSArray *expected = signatures[name];
        if (signature.numberOfArguments != expected.count + 1 || strcmp(signature.methodReturnType, [expected[0] UTF8String])) return nil;
        for (NSUInteger i=1; i<expected.count; i++)
            if (strcmp([signature getArgumentTypeAtIndex:i+1], [expected[i] UTF8String])) return nil;
    }
    id client = [clientClass alloc];
    if (!client) return nil;
    return MSG(id, id)(client, sel_registerName("initWithClientName:"), @"UniApi");
}

static BOOL mclSupported(void) {
    return MSG(BOOL)(gClient, sel_registerName("isMCLSupported"));
}

/// The levels the daemon will accept. Anything else is refused by it.
static NSArray *availableLevels(void) {
    NSError *error = nil;
    id levels = MSG(id, NSError **)(gClient, sel_registerName("availableChargeLimitsWithError:"), &error);
    return [levels isKindOfClass:NSArray.class] ? levels : nil;
}

static int currentLimit(void) {
    NSError *error = nil;
    return MSG(unsigned char, NSError **)(gClient, sel_registerName("getMCLLimitWithError:"), &error);
}

/// This selector returns an NSUInteger state and takes only NSError **.
/// The previous BOOL-pointer call always returned a fabricated false reading.
static BOOL mclEngaged(void) {
    NSError *error = nil;
    NSUInteger enabled = MSG(NSUInteger, NSError **)(gClient, sel_registerName("isMCLCurrentlyEnabled:"), &error);
    return error == nil && enabled == 1;
}

static NSDictionary *batterySnapshot(void) {
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"));
    if (!service) return @{ @"present": @NO };
    CFMutableDictionaryRef raw = NULL;
    if (IORegistryEntryCreateCFProperties(service, &raw, kCFAllocatorDefault, 0) != KERN_SUCCESS || !raw) {
        IOObjectRelease(service);
        return @{ @"present": @NO };
    }
    NSDictionary *p = CFBridgingRelease(raw);
    IOObjectRelease(service);

    NSDictionary *batteryData = p[@"BatteryData"];
    NSDictionary *chargerData = p[@"ChargerData"];
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    out[@"present"] = @YES;

    // CurrentCapacity is already a percentage on Apple Silicon; guard anyway so
    // a firmware reporting raw mAh here cannot show a charge of 5243%.
    NSInteger percent = [p[@"CurrentCapacity"] integerValue];
    if (percent > 100) {
        NSInteger rawNow = [p[@"AppleRawCurrentCapacity"] integerValue];
        NSInteger rawMax = [p[@"AppleRawMaxCapacity"] integerValue];
        percent = rawMax > 0 ? lround((double)rawNow / (double)rawMax * 100.0) : 100;
    }
    out[@"percent"] = @(MAX(0, MIN(100, percent)));
    out[@"charging"] = @([p[@"IsCharging"] boolValue]);
    out[@"externalConnected"] = @([p[@"ExternalConnected"] boolValue]);
    out[@"fullyCharged"] = @([p[@"FullyCharged"] boolValue]);

    NSInteger full = [batteryData[@"FullChargeCapacity"] integerValue];
    NSInteger design = [batteryData[@"DesignCapacity"] integerValue];
    if (full > 0 && design > 0) out[@"health"] = @(lround((double)full / (double)design * 100.0));
    if (p[@"CycleCount"]) out[@"cycleCount"] = @([p[@"CycleCount"] integerValue]);
    if (chargerData[@"NotChargingReason"]) out[@"notChargingReason"] = @([chargerData[@"NotChargingReason"] integerValue]);
    // Allowlist electrical/gauge diagnostics; never dump serial numbers or
    // the full IOKit tree. Signed conversion preserves discharge currents.
    NSMutableDictionary *telemetry = [NSMutableDictionary dictionary];
    for (NSString *key in @[@"Amperage", @"InstantAmperage", @"Voltage", @"Temperature", @"VirtualTemperature", @"SkinTemperature", @"AppleRawCurrentCapacity", @"AppleRawMaxCapacity", @"NominalChargeCapacity", @"MaxCapacity", @"DesignCapacity", @"TimeRemaining", @"AvgTimeToEmpty", @"AvgTimeToFull", @"ExternalChargeCapable", @"AppleRawExternalConnected"]) {
        if ([p[key] isKindOfClass:NSNumber.class]) telemetry[key] = @([p[key] longLongValue]);
    }
    for (NSString *group in @[@"PowerTelemetryData", @"BatteryData", @"ChargerData", @"AdapterDetails"]) {
        NSDictionary *source = p[group];
        if (![source isKindOfClass:NSDictionary.class]) continue;
        NSMutableDictionary *selected = [NSMutableDictionary dictionary];
        for (NSString *key in @[@"SystemPowerIn", @"SystemLoad", @"BatteryPower", @"SystemCurrentIn", @"SystemVoltageIn", @"WallEnergyEstimate", @"AdapterEfficiencyLoss", @"PowerTelemetryErrorCount", @"FullChargeCapacity", @"NominalChargeCapacity", @"RemainingCapacity", @"DesignCapacity", @"CurrentCapacity", @"CycleCount", @"NotChargingReason", @"SlowChargingReason", @"IsCharging", @"Watts", @"Current", @"AdapterVoltage"]) {
            if ([source[key] isKindOfClass:NSNumber.class]) selected[key] = @([source[key] longLongValue]);
        }
        telemetry[group] = selected;
    }
    out[@"telemetry"] = telemetry;
    return out;
}

static NSDictionary *stateDictionary(void) {
    BOOL supported = mclSupported();
    NSArray *levels = supported ? availableLevels() : nil;
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    out[@"ok"] = @YES;
    out[@"supported"] = @(supported);
    out[@"levels"] = levels ?: @[];
    out[@"battery"] = batterySnapshot();
    if (supported) {
        int limit = currentLimit();
        out[@"limit"] = @(limit);
        out[@"engaged"] = @(mclEngaged());
    }
    return out;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 2) fail(@"usage: uniapi-battery state|set <percent>|enable|off|hold <target> <floor>|daemon <config>|release", 64);
        NSString *command = @(argv[1]);

        // The persistent form, started by launchd. Everything about the
        // target comes from the config file, so the app never needs privileges
        // again after the one-time install.
        if ([command isEqualToString:@"daemon"]) {
            if (argc < 3 || argc > 4) fail(@"usage: uniapi-battery daemon <configPath> [band]", 64);
            if (geteuid() != 0) fail(@"The battery daemon must run as root.", 77);
            exit(battery_daemon(argv[2], argc == 4 ? @(argv[3]).intValue : 5));
        }

        if ([command isEqualToString:@"hold"]) {
            if (argc < 4 || argc > 6) fail(@"usage: uniapi-battery hold <target> <floor> [ownerPid] [stampPath]", 64);
            if (geteuid() != 0) fail(@"Holding a level below macOS's own limit needs administrator privileges.", 77);
            exit(battery_hold(@(argv[2]).intValue, @(argv[3]).intValue,
                              argc >= 5 ? (pid_t)@(argv[4]).intValue : 0,
                              argc >= 6 ? argv[5] : NULL));
        }

        // Unconditional recovery: re-enable the adapter and exit. Exists so
        // there is always a way back if a hold session is killed with SIGKILL,
        // which skips every restore path the helper has.
        if ([command isEqualToString:@"release"]) {
            if (geteuid() != 0) fail(@"Releasing the adapter needs administrator privileges.", 77);
            io_connect_t conn = smc_open();
            if (!conn) fail(@"Could not reach the SMC.", 1);
            const uint8_t on = 0x00;
            BOOL ok = smc_write(conn, "CHIE", &on, 1);
            uint8_t back = 0xff;
            smc_read(conn, "CHIE", &back, 1);
            smc_close(conn);
            emit(@{ @"ok": @(ok && back == 0x00), @"adapter": back == 0x00 ? @"enabled" : @"still disabled" });
            return (ok && back == 0x00) ? 0 : 1;
        }

        gClient = makeClient();
        if (!gClient) {
            // Not an error the user can act on, and not a crash: this is what
            // a macOS without the charge-limit service looks like.
            if ([command isEqualToString:@"state"]) {
                emit(@{ @"ok": @YES, @"supported": @NO, @"levels": @[], @"battery": batterySnapshot() });
                return 0;
            }
            fail(@"This Mac's version of macOS does not offer a charge limit.", 1);
        }

        if ([command isEqualToString:@"state"]) {
            if (argc != 2) fail(@"usage: uniapi-battery state", 64);
            emit(stateDictionary());
            return 0;
        }

        if ([command isEqualToString:@"enable"]) {
            if (argc != 2) fail(@"usage: uniapi-battery enable", 64);
            if (!mclSupported()) fail(@"This Mac does not offer a charge limit.", 1);
            NSError *error = nil;
            if (!MSG(BOOL, NSError **)(gClient, sel_registerName("enableMCL:"), &error))
                fail(error.localizedDescription ?: @"Could not enable the charge limit.", 1);
            emit(stateDictionary());
            return 0;
        }

        if ([command isEqualToString:@"set"]) {
            if (argc != 3) fail(@"usage: uniapi-battery set <percent>", 64);
            if (!mclSupported()) fail(@"This Mac does not offer a charge limit.", 1);
            NSString *input = @(argv[2]);
            NSScanner *scanner = [NSScanner scannerWithString:input];
            scanner.charactersToBeSkipped = nil;
            NSInteger want = 0;
            if (![scanner scanInteger:&want] || !scanner.isAtEnd || want < 1 || want > 100)
                fail(@"Choose a whole percentage between 1 and 100.", 64);
            NSArray *levels = availableLevels();
            // Checked here as well as by the daemon so the failure names the
            // levels that would work instead of surfacing "error code 4".
            if (levels.count && ![levels containsObject:@(want)]) {
                fail([NSString stringWithFormat:@"macOS only accepts a charge limit of %@ percent.",
                      [levels componentsJoinedByString:@", "]], 64);
            }
            NSError *error = nil;
            if (!MSG(BOOL, unsigned char, NSError **)(gClient, sel_registerName("setMCLLimit:error:"), (unsigned char)want, &error))
                fail([NSString stringWithFormat:@"macOS refused the charge limit: %@", error.localizedDescription ?: error], 1);
            error = nil;
            if (!MSG(BOOL, NSError **)(gClient, sel_registerName("enableMCL:"), &error))
                fail([NSString stringWithFormat:@"macOS refused to engage the charge limit: %@", error.localizedDescription ?: error], 1);
            // Read back: setting a value and having it stick are different
            // things, and the caller should hear about it from the system.
            usleep(400000);
            NSDictionary *state = stateDictionary();
            if ([state[@"limit"] integerValue] != want)
                fail([NSString stringWithFormat:@"macOS kept a charge limit of %@ percent instead.", state[@"limit"]], 1);
            emit(state);
            return 0;
        }

        if ([command isEqualToString:@"off"]) {
            if (argc != 2) fail(@"usage: uniapi-battery off", 64);
            NSError *error = nil;
            if (!MSG(BOOL, NSError **)(gClient, sel_registerName("disableMCL:"), &error))
                fail([NSString stringWithFormat:@"macOS refused to clear the charge limit: %@", error.localizedDescription ?: error], 1);
            usleep(400000);
            emit(stateDictionary());
            return 0;
        }

        fail(@"Unknown command.", 64);
    }
    return 0;
}
