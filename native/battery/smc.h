//
//  smc.h
//  Minimal AppleSMC transport.
//
//  Only what the charge limiter needs: open the connection, read a key, write
//  a key. Ported from the Swift version in native/fans/Core/SMCConnection.swift
//  rather than shared, because this helper is Objective-C (it has to call the
//  header-less PowerUI framework through the ObjC runtime) and mixing the two
//  languages in one clang invocation is not worth the build complexity.
//
//  The struct below is an ABI, not a convenience. Swift and C do not lay out
//  nested structs the same way, so porting this field-by-field produces an
//  80-byte-ish struct whose members land at the wrong offsets; every key then
//  reads as "unavailable", which looks exactly like a Mac without the key.
//  Hence the explicit padding and the static assertions - do not "tidy" them.
//

#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>

typedef struct {
    uint32_t key;                              // 0
    uint8_t  major, minor, build, reserved;    // 4
    uint16_t release;                          // 8
    uint8_t  _pad0[2];                         // 10
    uint16_t pLimitVersion, pLimitLength;      // 12
    uint32_t cpuPLimit, gpuPLimit, memPLimit;  // 16
    uint32_t dataSize;                         // 28
    uint32_t dataType;                         // 32
    uint8_t  dataAttributes;                   // 36
    uint8_t  _pad1;                            // 37
    uint16_t padding;                          // 38
    uint8_t  result;                           // 40
    uint8_t  status;                           // 41
    uint8_t  data8;                            // 42
    uint8_t  _pad2;                            // 43
    uint32_t data32;                           // 44
    uint8_t  bytes[32];                        // 48
} SMCParam;                                    // 80

_Static_assert(sizeof(SMCParam) == 80, "SMCParam must match the AppleSMC kernel ABI exactly");
_Static_assert(offsetof(SMCParam, dataSize) == 28, "keyInfo.dataSize offset");
_Static_assert(offsetof(SMCParam, result) == 40, "result offset");
_Static_assert(offsetof(SMCParam, data8) == 42, "data8 offset");
_Static_assert(offsetof(SMCParam, data32) == 44, "data32 offset");
_Static_assert(offsetof(SMCParam, bytes) == 48, "payload offset");

/// Opens the AppleSMC user client. Returns 0 on failure.
io_connect_t smc_open(void);
void smc_close(io_connect_t conn);

/// Reads a key. Returns the byte count, or -1 if the key is unavailable.
/// A key gated by the firmware answers kIOReturnNotPrivileged and reads -1
/// here even as root - see native/battery/README.md.
int smc_read(io_connect_t conn, const char *key, uint8_t *out, size_t outSize);

/// Writes a key. Returns NO if the firmware rejected it. IOKit reports success
/// for writes the firmware discards, so callers must read back to be sure.
BOOL smc_write(io_connect_t conn, const char *key, const uint8_t *bytes, size_t count);
