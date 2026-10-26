# Battery charge limit

UniApi uses unprivileged PowerUI for native MCL and a native-preference
daemon for lower targets. **50% charger-powered operation was verified on the
M4 Pro running macOS 27.0 (26A5425a) on 2026-09-12.** The battery charged
from below 50%, stopped at 50%, and reported zero battery current with the
adapter supplying the full system load. The old CHIE adapter-cycling loop is
retired; it did not satisfy that goal. See [hardware evidence](HARDWARE-VERIFICATION.md).

## Build and installation

```sh
native/battery/build.sh
native/battery/verify.sh
sudo shell/launchd/install-battery-helper.sh install
```

Installation requires one administrator authorization. It copies root-executed
code into `/Library/PrivilegedHelperTools`, registers `app.devved.uniapi-battery`,
and gives the invoking user write access only to
`/Library/Application Support/UniApi/Battery/target`. Outside sudo, pass that
user's numeric UID as the second argument. Target changes and stop requests
then need no password. Root code never runs from the writable checkout.
Uninstall removes only this component's files.

## Control and evidence

Native MCL uses `PowerUISmartChargeClient` in the private PowerUI framework:
`setMCLLimit:error:`, `enableMCL:`, `disableMCL:`,
`getMCLLimitWithError:` and `availableChargeLimitsWithError:`. These are private
interfaces, not a stable Apple SDK contract. Observed levels on Mac16,8 / M4 Pro /
macOS 27.0 (26A5425a): 80,85,90,95,100. Earlier 50% MCL calls returned code 4.
This does not prove other charging-control mechanisms cannot support 50%.

The lower-target backend writes only `mclLimitValue` and
`MCLFeatureState` in the existing `com.apple.smartcharging.topoffprotection`
preference scope, then posts `com.apple.smartcharging.defaultschanged`. These
interoperability keys were identified in AlDente 1.39.2. On 2026-09-12, this
method applied 50% on this Mac: both PowerUI and `pmset -g battlimit`
independently reported 50. This bypasses the ordinary setter's 80% floor.

After Off, preference notification alone changes PowerUI's displayed limit but
does not create a powerd SOC policy. The server first calls the unprivileged
`enable` command, then requests the lower target. Calling enable afterwards
resets the lower target to the native fallback and conflicts with the journal.
`/hold/stop` restores the enabled native baseline; the UI's Off action then
disables it. No second administrator authorization is needed.

Before any preference change, the daemon durably journals the original values
and native service limit in its protected directory. Stops restore those
values, preserve conflicting external edits, and retain the journal until the
PowerUI service confirms restoration. There is **no automatic expiry** for
persistent preferences. A crash restarts the daemon through launchd; an
unrecoverable failure preserves the journal rather than claiming success.

The target grammar accepts 25-95 and rejects embedded NUL, fractions, numeric
prefixes, oversized files, links and FIFOs. Missing/invalid input requests
restoration. Target changes do not accept arbitrary preferences, paths or code.
The helper checks PowerUI's service-reported limit independently from the
preference write and reports pending if it differs. Fresh matching daemon
telemetry is required before describing a physical charging state. `floor: 0`
means the native system owns hysteresis; UniApi does not set a recharge band.

An earlier ChargeInhibit assertion backend was tested and removed: despite a
successful API result and renewed assertion, all 36 samples over three minutes
showed charging with AC attached (approximately 2.8-3.5 A). It did not satisfy
the goal. The test was run as the normal user; an administrator prompt was
withdrawn without installation after that backend failed.

## Corrections to earlier investigation

- `isMCLCurrentlyEnabled:` returns NSUInteger and takes only NSError **. The
  earlier BOOL-pointer invocation was wrong and fabricated false readings.
  Correctly invoked at native80, it returned1 on 2026-09-12. `engaged`
  represents that enabled reading, not a physical-current measurement.
- Earlier bfD0/bfE0/bfF0 probes denied metadata even as root. The new daemon
  records fixed-key metadata and direct reads separately. Metadata refusal
  does not establish which entitlement or firmware rule caused it.
- CHIE disconnects the adapter and increases battery use. Earlier tests
  discharged from above target and restored charging on stop; they did not
  verify a complete50 hold and were not pass-through tests.
- AlDente's installed preferences/binary strings do not establish its beta's
  implementation. The previous claim that it uses adapter cycling was not
  substantiated and has been removed.
- GitHub run34699655689 did not execute its secret scan. Check-run annotation
  103569043179 says recent account payments failed or the spending limit needs
  increasing. Local checks cannot remove that account-level CI block.

## Software verification

`verify.sh` builds and reads native state without mutating charging. It tests
invalid CLI syntax, strict target parsing, mocked preference transactions, rollback, external conflicts, service acknowledgment,
and real symlink/hardlink/FIFO attacks against target/state
files. The pentest gate's `src-battery-files` runs these checks on macOS.
Server tests reject stale or mismatched acknowledgments and prevent a requested
or failed target from becoming a successful hold. These are software checks;
hardware results must be recorded separately below.

Sources: [Apple IOPMLibPrivate.h](https://github.com/apple-oss-distributions/IOKitUser/blob/main/pwr_mgt.subproj/IOPMLibPrivate.h),
[Apple PMAssertions.c](https://github.com/apple-oss-distributions/PowerManagement/blob/main/pmconfigd/PMAssertions.c),
[batt charging implementation](https://github.com/charlie0129/batt/blob/master/pkg/smc/charging.go).

## Hardware verification status

The one-time installer completed on 2026-09-12. The root daemon independently
confirmed direct reads and metadata for bfD0/bfE0/bfF0 all return 0xe00002c1.
The preference path nevertheless applied 50% to both native policy owners,
confirmed by PowerUI and `pmset -g battlimit`. Stopping restored the original
80% policy and removed the restoration journal. Turning the native limit off
then resumed physical charging (approximately +2.3 A, AC attached).
An active 49% test target drained to 49% and then switched to charger power:
0 mA battery current, 0 battery power and approximately 43.9 W from the adapter
matching system load. Changing 49% to 50% resumed physical charging at +2.7 A.
The battery reached 50% and stopped charging at 19:45:53 CEST, with 0 mA
battery current and approximately 48.7 W adapter input matching system load.
PowerUI and both powerd SOC policies reported 50%, and the API reported
`holding-low`. [The hardware report](HARDWARE-VERIFICATION.md) records the
sustained interval and the limits of this verification.

Native policy includes `chargeSocLimitDrain = 1`: the system can draw from the
battery to approach a lower target even while `ExternalConnected` stays true.
Do not describe this transition as charger-powered holding. Check signed
battery current and `PowerTelemetryData` at the settled target.

The user authorized local verification instead of GitHub CI on 2026-09-12.

## Persistent diagnostics

The unprivileged `state` reader includes `battery.telemetry`: an allowlist of
signed current (mA), voltage (mV), available raw temperature and capacity fields,
charger stop reasons, adapter rating, and PowerTelemetryData (power in mW).
Missing fields are omitted, not substituted with zero. The full IOKit tree,
battery/charger serials, and unrelated system data are not collected.

The server records these snapshots every 15 seconds in
`data/logs/battery/battery.jsonl`; `.1` through `.7` are older rotations.
Each JSON line has schema 1, UTC timestamp, server PID, sequence, event, and data.
`sample` joins native telemetry, daemon acknowledgment (including errors and
SMC diagnostic results), requested limit and UI phase. `native.policy` records
Apple's actual SOC policies every minute. Command, request, target, restoration,
phase-change and sampling-gap events explain changes between samples.
Files are 0600 in a 0700 directory, capped at 8 MiB each (64 MiB total); older data
rolls off. A single record is bounded at 64 KiB, with oversized payloads replaced
by a truncation marker. Write failures do not abort charging actions, and nothing is uploaded.
Filesystem and ACL checks are synchronous, so slow local storage can still
add latency to a request. The server must be running; closing the
window does not stop it. Sleep/restart gaps remain gaps.

During the 49% investigation on 2026-09-12, the native target remained 50,
`IsCharging` was false, battery current and battery power were 0, and adapter
input equaled the 46.859 W system load. This rules out active battery drain in
that sample; it does not establish exactly why the gauge moved by one point.
The UI now reports idle below the limit rather than falsely claiming charging.
Do not change the limit just to chase a one-point reading without examining
current, power, native policy and history.
