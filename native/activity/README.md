# Activity on macOS

UniApi's Mac > Activity page is a task manager inside the existing window.
The Objective-C helper is unprivileged, on-demand and stateless. It uses the
macOS SDK's libproc, Mach, sysctl and AppKit APIs. It does not install a daemon,
ask for administrator access, read command arguments or read environments.

## Build and test

```sh
bash native/activity/build.sh
bash native/activity/verify.sh
```

The binary is atomically installed to `data/bin/uniapi-activity`. Both the shell
build and macOS release packaging include it. macOS 14+ is the deployment
target, matching the shell. Native checks skip other platforms; the TypeScript
model, route and presentation tests run everywhere. `test_helper.py` samples
real telemetry and exercises termination only against sleep processes it
creates itself. It also proves that invalid and stale identities and the
helper's ancestors are refused.

## Measurement contract

`sample` returns one JSON object. The server retains the previous sample and
calculates differences using monotonic elapsed time. Status requests coalesce,
with a 750 ms minimum cache interval. There is no background sampling when the
page is closed; the visible page defaults to 2 seconds, with 1- and 5-second
options, and pauses when hidden. The client keeps up to two minutes of history
in memory and marks gaps rather than fabricating samples.

Process CPU uses `PROC_PIDTASKINFO`'s total user plus system Mach absolute-time
ticks, converted to nanoseconds with `mach_timebase_info` before serialization:

```
percent = delta CPU nanoseconds / 1e9 / elapsed seconds / logical cores * 100
```

Every app uses the entire Mac as the denominator, not the sum of the busy apps.
One fully busy core on a 12-core Mac is 8.3%. This is logical-core CPU time,
not weighted performance, energy or the machine's theoretical throughput.
Apple Silicon's efficiency and performance cores are counted equally.
First samples, new identities, backward counters, changes in core count and
gaps over 15 seconds have unavailable interval counters. PID plus start time
is the identity; PID reuse never joins two counter histories. Host CPU uses
the difference in Mach busy/idle ticks, including unsigned counter rollover.

App memory is `RUSAGE_INFO_V2.ri_phys_footprint`, falling back to resident
memory when only task information is accessible. Both the bytes and the
percentage of installed RAM are shown. Missing memory remains null. Group
values sum measured members and carry a partial flag when counters are missing
or a resident fallback was necessary. They are not a partition of total RAM:
shared memory, compression and unlisted system processes matter.

System used memory is `(active + inactive + wired + compressor - purgeable -
external/file-backed) * page size`, bounded by installed RAM. Pressure comes
from the system pressure level (or is unavailable); swap comes from
`vm.swapusage`. Disk I/O is observed per-process read/write-byte deltas per
second; it is not an invented percentage of disk throughput. GPU, energy and
network percentages are not inferred from unrelated counters.

App grouping starts with AppKit's regular running applications and top-level
menu-bar applications (embedded accessory helpers stay with their host and
system accessory agents stay in All activity), then follows
same-user process ancestry, then a unique matching executable bundle path.
Ambiguous instances and shared system WebKit/XPC hosts stay separate. Never
attribute every process named WebKit to whichever browser is using most CPU.
Protected or vanished processes that cannot even be enumerated are counted
separately. Unreadable counters are not silently represented as zero.

## Termination boundary

The server accepts a strict identity key and `quit` or `force`, never a caller's
arbitrary signal, executable path or shell string. It collects a fresh snapshot
and resolves the current group before calling the helper with a bounded JSON
request on stdin. An already-running poll is allowed to finish, then a new
sample resolves membership after the quit request. The helper validates all identities before sending anything,
then rechecks each identity and permission immediately before acting.

`quit` on an application calls `NSRunningApplication.terminate` for its root
only, so normal save handling remains possible. A process quit sends SIGTERM.
`force` sends SIGKILL to current, individually validated group members; it never
signals a negative PID or Unix process group. Expanded process actions affect
that single process only. No elevated retry is offered. Other users' processes,
PID 0/1, root execution, the helper's ancestors, UniApi and essential session
processes are refused. macOS can still refuse a request, and a normal quit can
be cancelled by its app; responses report requests sent, not guaranteed exits.
PID/start-time revalidation narrows the signal race, but is not an atomic
kernel process handle; do not describe it as a pidfd guarantee.

The UI requires one explicit confirmation for force quit. It preserves row
positions, including disabled placeholders for exited rows, while the pointer
or keyboard focus is in the table. Selection and confirmation carry immutable
identity keys, never a row number. Sampling errors disable termination.

## Primary references

- [Apple XNU process information structures](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/sys/proc_info.h)
- [AppKit normal application termination](https://developer.apple.com/documentation/appkit/nsrunningapplication/terminate())
- [Apple XNU resource accounting](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/sys/resource.h)

The local SDK headers and the native smoke test are the version-specific
ground truth for this machine. No third-party process-monitor library is used.

## Timebase and serialization traps

`fill_taskprocinfo` in Apple's XNU source fills the CPU counters from Mach
absolute times. Treating these values as nanoseconds understated CPU usage by
about 41.7 times on the tested Apple Silicon Mac. Intel's common 1:1 timebase
can hide the mistake. Always obtain the runtime timebase and use wide
intermediates for conversion. The native test burns 0.25 seconds of actual CPU
time in a disposable child and compares the helper delta to that child's
`time.process_time()`; it tests the units without assuming an unloaded machine.
Primary implementation: [XNU task accounting](https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/kern/bsd_kern.c).

Boxed C comparisons such as `@(count == 0)` serialize as JSON integers, not
booleans. Return `@YES` / `@NO` explicitly for the `ok` field. Native tests assert
the exact JSON types for successful and refused requests, rather than testing
truthiness. Samples also recheck birth time and UID after reading counters so
rapid PID replacement cannot combine different process identities.
