// Unprivileged, on-demand process telemetry and identity-checked termination.
// No command lines, environment variables, AppleScript or administrator helper.
#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#include <libproc.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <sys/sysctl.h>
#include <signal.h>
#include <unistd.h>
#include <limits.h>
#include <math.h>

static void emit(id value) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:value options:0 error:nil];
    if (data) { fwrite(data.bytes, 1, data.length, stdout); putchar('\n'); }
}
static NSString *birth(struct proc_bsdinfo b) {
    return [NSString stringWithFormat:@"%llu:%llu", b.pbi_start_tvsec, b.pbi_start_tvusec];
}
static BOOL bsd(pid_t pid, struct proc_bsdinfo *b) {
    return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, b, sizeof(*b)) == sizeof(*b);
}
static NSString *executable(pid_t pid) {
    char buffer[PROC_PIDPATHINFO_MAXSIZE] = {0};
    return proc_pidpath(pid, buffer, sizeof(buffer)) > 0 ? (@(buffer) ?: @"") : @"";
}
static NSString *processName(struct proc_bsdinfo b) {
    char buffer[sizeof(b.pbi_name) + 1] = {0};
    memcpy(buffer, b.pbi_name[0] ? b.pbi_name : b.pbi_comm,
           b.pbi_name[0] ? sizeof(b.pbi_name) : sizeof(b.pbi_comm));
    return @(buffer) ?: @"Unknown process";
}
static NSSet<NSNumber *> *ancestors(void) {
    NSMutableSet *ids = [NSMutableSet setWithObject:@(getpid())];
    pid_t pid = getppid();
    for (int i = 0; pid > 1 && i < 128 && ![ids containsObject:@(pid)]; i++) {
        [ids addObject:@(pid)]; struct proc_bsdinfo b;
        if (!bsd(pid, &b)) break;
        pid = (pid_t)b.pbi_ppid;
    }
    return ids;
}
static NSString *blocked(pid_t pid, struct proc_bsdinfo b, NSString *path, NSSet *parents) {
    if (pid <= 1 || b.pbi_uid != getuid() || getuid() == 0) return @"Owned by macOS or another user";
    if ([parents containsObject:@(pid)]) return @"Runs this monitor or its server";
    if ([path containsString:@"/UniApi.app/"] || [path.lastPathComponent isEqual:@"uniapi-activity"])
        return @"Runs this monitor";
    NSSet *essential = [NSSet setWithArray:@[@"loginwindow", @"WindowServer", @"launchd", @"kernel_task", @"Dock", @"Finder", @"SystemUIServer", @"ControlCenter"]];
    if ([essential containsObject:processName(b)] || (b.pbi_flags & PROC_FLAG_SYSTEM))
        return @"Essential macOS process";
    return nil;
}
static uint64_t sysnumber(const char *name) {
    uint64_t value = 0; size_t size = sizeof(value);
    return sysctlbyname(name, &value, &size, NULL, 0) == 0 ? value : 0;
}
static NSDictionary *sample(void) {
    NSTimeInterval mono = NSProcessInfo.processInfo.systemUptime;
    mach_timebase_info_data_t timebase = {0};
    BOOL hasTimebase = mach_timebase_info(&timebase) == KERN_SUCCESS && timebase.denom != 0;
    NSSet *parents = ancestors();
    int size = proc_listallpids(NULL, 0);
    if (size <= 0) return @{@"error": @"macOS did not return its process list."};
    size += 1024;
    pid_t *pids = calloc((size_t)size, sizeof(pid_t));
    if (!pids) return @{@"error": @"Unable to allocate the process list."};
    int count = proc_listallpids(pids, size * (int)sizeof(pid_t));
    NSMutableArray *processes = [NSMutableArray array];
    int omitted = 0;
    for (int i = 0; i < count && i < size; i++) {
        @autoreleasepool {
            pid_t pid = pids[i];
            if (pid <= 0 || pid == getpid()) continue;
            struct proc_bsdinfo b = {0};
            if (!bsd(pid, &b)) { omitted++; continue; }
            NSString *path = executable(pid);
            struct proc_taskinfo t = {0};
            BOOL hasTask = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &t, sizeof(t)) == sizeof(t);
            // libproc exposes Mach absolute-time units, NOT nanoseconds. On
            // Apple Silicon a raw tick can span many ns; Intel often hides
            // this mistake with a 1:1 timebase. Keep wide intermediates.
            unsigned __int128 cpuNs = 0;
            if (hasTask && hasTimebase) {
                cpuNs = ((unsigned __int128)t.pti_total_user + t.pti_total_system) * timebase.numer / timebase.denom;
            }
            struct rusage_info_v2 r = {0};
            BOOL hasUsage = proc_pid_rusage(pid, RUSAGE_INFO_V2, (rusage_info_t *)&r) == 0;
            struct proc_bsdinfo after = {0};
            // A PID can disappear between these independent libproc calls.
            // Never attach its replacement's counters to the original identity.
            if (!bsd(pid, &after) || ![birth(b) isEqual:birth(after)] || b.pbi_uid != after.pbi_uid) {
                omitted++; continue;
            }
            NSString *reason = blocked(pid, b, path, parents);
            [processes addObject:@{
                @"pid": @(pid), @"ppid": @(b.pbi_ppid), @"uid": @(b.pbi_uid),
                @"started": birth(b), @"name": processName(b), @"path": path,
                @"cpuNs": hasTask && hasTimebase && cpuNs <= UINT64_MAX ? [NSString stringWithFormat:@"%llu", (unsigned long long)cpuNs] : (id)NSNull.null,
                @"memoryBytes": hasUsage ? @(r.ri_phys_footprint) : hasTask ? @(t.pti_resident_size) : (id)NSNull.null,
                @"memoryKind": hasUsage ? @"footprint" : hasTask ? @"resident" : @"unavailable",
                @"threads": hasTask ? @(t.pti_threadnum) : (id)NSNull.null,
                @"readBytes": hasUsage ? @(r.ri_diskio_bytesread) : (id)NSNull.null,
                @"writeBytes": hasUsage ? @(r.ri_diskio_byteswritten) : (id)NSNull.null,
                @"protectedReason": reason ?: (id)NSNull.null
            }];
        }
    }
    free(pids);
    NSMutableArray *apps = [NSMutableArray array];
    for (NSRunningApplication *app in NSWorkspace.sharedWorkspace.runningApplications) {
        if (app.activationPolicy == NSApplicationActivationPolicyProhibited || app.isTerminated || !app.bundleURL) continue;
        // Menu-bar apps are apps too. Embedded accessory helpers remain part
        // of their containing app rather than becoming duplicate app groups.
        if (app.activationPolicy == NSApplicationActivationPolicyAccessory &&
            ([app.bundleURL.path hasPrefix:@"/System/"] ||
             [app.bundleURL.path containsString:@".app/Contents/"] ||
             ![app.bundleURL.pathExtension.lowercaseString isEqual:@"app"])) continue;
        [apps addObject:@{@"pid": @(app.processIdentifier), @"name": app.localizedName ?: @"Application",
                          @"bundlePath": app.bundleURL.path, @"bundleId": app.bundleIdentifier ?: @""}];
    }
    mach_port_t host = mach_host_self();
    host_cpu_load_info_data_t cpu = {0}; mach_msg_type_number_t cpuCount = HOST_CPU_LOAD_INFO_COUNT;
    BOOL hasCpu = host_statistics(host, HOST_CPU_LOAD_INFO, (host_info_t)&cpu, &cpuCount) == KERN_SUCCESS;
    vm_statistics64_data_t vm = {0}; mach_msg_type_number_t vmCount = HOST_VM_INFO64_COUNT;
    BOOL hasVm = host_statistics64(host, HOST_VM_INFO64, (host_info64_t)&vm, &vmCount) == KERN_SUCCESS;
    vm_size_t pageSize = 0; host_page_size(host, &pageSize);
    mach_port_deallocate(mach_task_self(), host);
    uint64_t total = NSProcessInfo.processInfo.physicalMemory;
    // File-backed cache and purgeable pages are reclaimable, not occupied app RAM.
    int64_t usedPages = (int64_t)vm.active_count + vm.inactive_count + vm.wire_count + vm.compressor_page_count - vm.purgeable_count - vm.external_page_count;
    uint64_t used = MIN(total, (uint64_t)MAX((int64_t)0, usedPages) * pageSize);
    struct xsw_usage swap = {0}; size_t swapSize = sizeof(swap);
    BOOL hasSwap = sysctlbyname("vm.swapusage", &swap, &swapSize, NULL, 0) == 0;
    uint64_t pressure = sysnumber("kern.memorystatus_vm_pressure_level");
    return @{
        @"timestamp": @((long long)(NSDate.date.timeIntervalSince1970 * 1000)), @"monotonic": @(mono),
        @"logicalCpus": @(MAX(1, NSProcessInfo.processInfo.activeProcessorCount)), @"totalMemory": @(total),
        @"cpuTicks": hasCpu ? @[@(cpu.cpu_ticks[CPU_STATE_USER]), @(cpu.cpu_ticks[CPU_STATE_SYSTEM]), @(cpu.cpu_ticks[CPU_STATE_IDLE]), @(cpu.cpu_ticks[CPU_STATE_NICE])] : (id)NSNull.null,
        @"memoryUsed": hasVm ? @(used) : (id)NSNull.null,
        @"compressedBytes": hasVm ? @((uint64_t)vm.compressor_page_count * pageSize) : (id)NSNull.null,
        @"swapUsed": hasSwap ? @(swap.xsu_used) : (id)NSNull.null,
        @"pressure": pressure == 1 ? @"normal" : pressure == 2 ? @"warning" : pressure == 4 ? @"critical" : @"unknown",
        @"processes": processes, @"apps": apps, @"omitted": @(omitted)
    };
}

static NSDictionary *terminateRequest(NSDictionary *request) {
    NSString *mode = request[@"mode"];
    NSArray *targets = request[@"targets"];
    if (!([mode isEqual:@"quit"] || [mode isEqual:@"force"]) ||
        ![targets isKindOfClass:NSArray.class] || targets.count < 1 || targets.count > 2048)
        return @{@"error": @"Invalid termination request."};
    NSSet *parents = ancestors();
    NSMutableArray *validated = [NSMutableArray array];
    int gone = 0;
    // Validate the complete request before sending any signal. Recheck at the act itself too.
    for (id target in targets) {
        if (![target isKindOfClass:NSDictionary.class] || ![target[@"pid"] isKindOfClass:NSNumber.class] ||
            ![target[@"started"] isKindOfClass:NSString.class]) return @{@"error": @"Invalid process identity."};
        double value = [target[@"pid"] doubleValue];
        if (value < 2 || value > INT_MAX || value != floor(value)) return @{@"error": @"Invalid process ID."};
        pid_t pid = (pid_t)value; struct proc_bsdinfo b;
        if (!bsd(pid, &b)) { gone++; continue; }
        if (![birth(b) isEqual:target[@"started"]]) return @{@"error": @"A process restarted. Refresh before trying again."};
        NSString *reason = blocked(pid, b, executable(pid), parents);
        if (reason) return @{@"error": reason};
        [validated addObject:target];
    }
    NSMutableArray *failed = [NSMutableArray array]; int requested = 0;
    BOOL appQuit = [request[@"application"] isEqual:@YES] && [mode isEqual:@"quit"];
    for (NSDictionary *target in validated) {
        pid_t pid = [target[@"pid"] intValue]; struct proc_bsdinfo b;
        if (!bsd(pid, &b)) { gone++; continue; }
        if (![birth(b) isEqual:target[@"started"]] || blocked(pid, b, executable(pid), parents)) {
            [failed addObject:@{@"pid": @(pid), @"reason": @"The process identity or permissions changed."}]; continue;
        }
        BOOL sent = NO;
        if (appQuit) {
            NSRunningApplication *app = [NSRunningApplication runningApplicationWithProcessIdentifier:pid];
            // AppKit requests a normal quit, preserving the app's opportunity to ask to save.
            sent = app && [app terminate];
        } else {
            sent = kill(pid, [mode isEqual:@"force"] ? SIGKILL : SIGTERM) == 0;
        }
        if (sent) requested++;
        else [failed addObject:@{@"pid": @(pid), @"reason": @"macOS refused the request or the process exited."}];
    }
    // A boxed C comparison is an NSNumber integer, serialized as 0/1. The
    // HTTP contract requires a JSON boolean on both success and failure.
    return @{@"ok": failed.count == 0 ? @YES : @NO, @"requested": @(requested), @"alreadyExited": @(gone), @"failed": failed};
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc == 2 && strcmp(argv[1], "sample") == 0) { emit(sample()); return 0; }
        if (argc == 2 && strcmp(argv[1], "terminate") == 0) {
            // Bounded input, including when someone calls the helper outside the server.
            NSMutableData *data = [NSMutableData data]; uint8_t buffer[4096]; size_t size;
            while ((size = fread(buffer, 1, sizeof(buffer), stdin)) > 0) {
                [data appendBytes:buffer length:size];
                if (data.length > 262144) { emit(@{@"error": @"Request too large."}); return 1; }
            }
            id request = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if (![request isKindOfClass:NSDictionary.class]) { emit(@{@"error": @"Invalid JSON."}); return 1; }
            NSDictionary *result = terminateRequest(request); emit(result);
            return result[@"error"] ? 1 : 0;
        }
        emit(@{@"error": @"Usage: uniapi-activity sample | terminate (JSON on stdin)"}); return 1;
    }
}
