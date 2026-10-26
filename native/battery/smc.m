#import "smc.h"

enum { kSMCReadBytes = 5, kSMCWriteBytes = 6, kSMCReadKeyInfo = 9 };
static const uint32_t kSMCSelector = 2;

static uint32_t fourCC(const char *key) {
    return ((uint32_t)key[0] << 24) | ((uint32_t)key[1] << 16) | ((uint32_t)key[2] << 8) | (uint32_t)key[3];
}

static kern_return_t call(io_connect_t conn, SMCParam *in, SMCParam *out) {
    size_t outSize = sizeof(SMCParam);
    return IOConnectCallStructMethod(conn, kSMCSelector, in, sizeof(SMCParam), out, &outSize);
}

io_connect_t smc_open(void) {
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (!service) return 0;
    io_connect_t conn = 0;
    kern_return_t kr = IOServiceOpen(service, mach_task_self(), 0, &conn);
    IOObjectRelease(service);
    return kr == kIOReturnSuccess ? conn : 0;
}

void smc_close(io_connect_t conn) { if (conn) IOServiceClose(conn); }

/// Key info doubles as the existence check: the data size is needed for both
/// reads and writes, and a gated key fails here rather than at the transfer.
static BOOL keyInfo(io_connect_t conn, const char *key, uint32_t *size) {
    SMCParam in = {0}, out = {0};
    in.key = fourCC(key);
    in.data8 = kSMCReadKeyInfo;
    if (call(conn, &in, &out) != kIOReturnSuccess) return NO;
    if (out.result != 0 || out.dataSize == 0 || out.dataSize > sizeof(out.bytes)) return NO;
    *size = out.dataSize;
    return YES;
}

int smc_read(io_connect_t conn, const char *key, uint8_t *outBytes, size_t outSize) {
    if (!conn || strlen(key) != 4) return -1;
    uint32_t size = 0;
    if (!keyInfo(conn, key, &size)) return -1;
    if (size > outSize) return -1;
    SMCParam in = {0}, out = {0};
    in.key = fourCC(key);
    in.dataSize = size;
    in.data8 = kSMCReadBytes;
    if (call(conn, &in, &out) != kIOReturnSuccess || out.result != 0) return -1;
    memcpy(outBytes, out.bytes, size);
    return (int)size;
}

BOOL smc_write(io_connect_t conn, const char *key, const uint8_t *bytes, size_t count) {
    if (!conn || strlen(key) != 4 || count > sizeof(((SMCParam *)0)->bytes)) return NO;
    uint32_t size = 0;
    if (!keyInfo(conn, key, &size)) return NO;
    // The firmware expects exactly the key's own width; a short write is
    // accepted by IOKit and then discarded.
    if (size != count) return NO;
    SMCParam in = {0}, out = {0};
    in.key = fourCC(key);
    in.dataSize = size;
    in.data8 = kSMCWriteBytes;
    memcpy(in.bytes, bytes, count);
    if (call(conn, &in, &out) != kIOReturnSuccess) return NO;
    return out.result == 0;
}
