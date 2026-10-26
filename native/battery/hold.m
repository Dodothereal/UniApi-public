// Persistent native-MCL preference controller. Only the fixed, journaled
// preference path is used; accepted preference writes still need independent
// service readback and battery telemetry. No adapter-disabling writes occur.
#import "hold.h"
#import "preferences.h"
#import "smc.h"
#import <IOKit/pwr_mgt/IOPMLib.h>
#include <fcntl.h>
#include <signal.h>
#include <sys/stat.h>
#include <sys/acl.h>
#include <unistd.h>
#include <errno.h>
#include <time.h>

static volatile sig_atomic_t stopping;
static void onSignal(int signalNumber) { (void)signalNumber; stopping = 1; }

// Fixed grammar, also exercised directly by the native tests. Embedded NUL,
// oversized input, fractions and numeric prefixes all fail closed.
int battery_parse_target(const char *bytes, size_t length) {
    if (!bytes || length == 0 || length > 16 || memchr(bytes, 0, length)) return 0;
    while (length && (bytes[length-1] == '\n' || bytes[length-1] == '\r')) length--;
    if (length != 2 || bytes[0] < '0' || bytes[0] > '9' || bytes[1] < '0' || bytes[1] > '9') return 0;
    int target = (bytes[0]-'0')*10 + bytes[1]-'0';
    return target >= 25 && target <= 95 ? target : 0;
}

static int readTarget(int directory) {
    int fd = openat(directory, "target", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
    if (fd < 0) return 0;
    struct stat st;
    char bytes[17];
    ssize_t length = -1;
    if (fstat(fd, &st) == 0 && S_ISREG(st.st_mode) && st.st_nlink == 1 && st.st_size <= 16)
        length = read(fd, bytes, sizeof bytes);
    close(fd);
    return length > 0 ? battery_parse_target(bytes, (size_t)length) : 0;
}

static NSDictionary *snapshot(void) {
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"));
    if (!service) return nil;
    CFMutableDictionaryRef raw = NULL;
    kern_return_t result = IORegistryEntryCreateCFProperties(service, &raw, kCFAllocatorDefault, 0);
    IOObjectRelease(service);
    if (result != KERN_SUCCESS || !raw) return nil;
    NSDictionary *p = CFBridgingRelease(raw);
    NSNumber *capacity = p[@"CurrentCapacity"];
    NSNumber *external = p[@"ExternalConnected"];
    NSNumber *charging = p[@"IsCharging"];
    NSNumber *amps = p[@"Amperage"];
    if (![capacity isKindOfClass:NSNumber.class] || capacity.intValue < 0 || capacity.intValue > 100
        || ![external isKindOfClass:NSNumber.class] || ![charging isKindOfClass:NSNumber.class]) return nil;
    return @{ @"percent": capacity, @"external": @([external boolValue]),
              @"charging": @([charging boolValue]), @"amperage": amps ?: @0 };
}

// Read-only diagnostics explicitly separate metadata refusal from read refusal.
// No user-selected keys, addresses, payloads or executable commands are accepted.
static NSArray *diagnostics(void) {
    io_connect_t conn = smc_open();
    NSMutableArray *out = [NSMutableArray array];
    const char *keys[] = { "bfD0", "bfE0", "bfF0", "CH0B", "CH0C", "CHTE", "CHIE" };
    const int lengths[] = { 4, 4, 1, 1, 1, 4, 1 };
    if (!conn) return @[];
    for (int i=0; i<7; i++) {
        uint32_t key=0; for (int j=0;j<4;j++) key=(key<<8)|(uint8_t)keys[i][j];
        NSMutableDictionary *row=[NSMutableDictionary dictionaryWithObject:@(keys[i]) forKey:@"key"];
        for (int op=0;op<2;op++) {
            SMCParam in={0}, back={0}; size_t size=sizeof back;
            in.key=key; in.data8=op ? 5 : 9; in.dataSize=lengths[i];
            kern_return_t kr=IOConnectCallStructMethod(conn,2,&in,sizeof in,&back,&size);
            NSString *prefix=op ? @"read" : @"metadata";
            row[[prefix stringByAppendingString:@"Result"]]=@(kr);
            row[[prefix stringByAppendingString:@"SMCResult"]]=@(back.result);
            if (op && kr==0 && back.result==0) {
                NSMutableArray *bytes=[NSMutableArray array];
                for(int j=0;j<lengths[i];j++) [bytes addObject:@(back.bytes[j])];
                row[@"bytes"]=bytes;
            }
        }
        [out addObject:row];
    }
    smc_close(conn);
    return out;
}

static BOOL report(int directory, NSDictionary *value) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingSortedKeys error:nil];
    if (!data) return NO;
    // Directory is root-owned and not writable by the app. Exclusive creation
    // and rename never follow a state-file symlink, even after an old install.
    unlinkat(directory, "state.new", 0);
    int fd = openat(directory, "state.new", O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC, 0644);
    if (fd < 0) return NO;
    size_t offset=0;
    while (offset<data.length) {
        ssize_t n=write(fd,(const char *)data.bytes+offset,data.length-offset);
        if(n<0 && errno==EINTR) continue;
        if(n<=0) { close(fd); unlinkat(directory,"state.new",0); return NO; }
        offset+=(size_t)n;
    }
    close(fd);
    return renameat(directory,"state.new",directory,"state.json")==0;
}

int battery_daemon(const char *configPath, int band) {
    (void)band;
    if (geteuid()!=0 || !configPath) return 77;
    NSString *path=[@(configPath) stringByDeletingLastPathComponent];
    int directory=open(path.fileSystemRepresentation,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
    struct stat st;
    if(directory<0 || fstat(directory,&st)!=0 || st.st_uid!=0 || (st.st_mode&0022)) {
        if(directory>=0) close(directory);
        fprintf(stderr,"Battery state directory must be root-owned and not group/world-writable.\n"); return 77;
    }
    errno=0;
    acl_t acl=acl_get_fd_np(directory,ACL_TYPE_EXTENDED);
    // Darwin returns NULL/ENOENT for a descriptor with no extended ACL.
    // Reject every present ACL (including an empty one), or other read errors.
    BOOL noACL=acl==NULL && errno==ENOENT;
    if(acl) acl_free(acl);
    if(!noACL) { close(directory); fprintf(stderr,"Battery state directory must have no extended ACL.\n"); return 77; }
    for(int i=0;i<4;i++) signal((int[]){SIGINT,SIGTERM,SIGHUP,SIGQUIT}[i],onSignal);
    NSArray *probes=diagnostics();
    while(!stopping) { @autoreleasepool {
        int target=readTarget(directory);
        NSDictionary *battery=snapshot();
        NSString *failure=nil;
        BOOL ok=battery_preferences_apply(directory,target,&failure);
        int nativeLimit=target ? battery_preferences_limit() : 0;
        NSString *phase=!ok ? (battery_preferences_is_pending() ? @"pending" : @"write-refused") : !target ? @"off" : nativeLimit!=target ? @"pending" : !battery ? @"telemetry-unavailable"
            : ![battery[@"external"] boolValue] ? @"on-battery"
            : [battery[@"percent"] intValue]>=target ? @"inhibiting" : @"charging";
        NSMutableDictionary *state=[@{ @"version":@2, @"pid":@(getpid()), @"updatedAt":@((long long)time(NULL)*1000),
            @"target":@(target), @"floor":@0, @"state":phase,
            @"backend":@"PowerUI preferences", @"nativeLimit":@(nativeLimit), @"diagnostics":probes } mutableCopy];
        if(failure)state[@"error"]=failure;
        if(battery) state[@"battery"]=battery;
        if(!report(directory,state)) { battery_preferences_apply(directory,0,NULL); close(directory); return 1; }
        for(int i=0;i<5 && !stopping;i++) sleep(1);
    } }
    BOOL ok=battery_preferences_apply(directory,0,NULL);
    report(directory,@{ @"version":@2, @"pid":@(getpid()), @"updatedAt":@((long long)time(NULL)*1000), @"target":@0,
                         @"floor":@0, @"state":ok ? @"off" : @"write-refused" });
    close(directory);
    return ok ? 0 : 1;
}

int battery_hold(int target, int floor, pid_t owner, const char *stamp) {
    (void)target; (void)floor; (void)owner; (void)stamp;
    fprintf(stderr,"Session adapter cycling has been retired. Install the charging-only daemon.\n");
    return 64;
}
