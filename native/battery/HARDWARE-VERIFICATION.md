# 50% charging verification — 2026-09-12

Hardware: Mac16,8, Apple M4 Pro. macOS 27.0, build 26A5425a. SIP enabled.
Tests ran while the Mac remained physically connected to its 96 W adapter.
All times below are Europe/Berlin (CEST). No additional administrator prompts
were used after installing the fixed root-owned helper once.

## Independent observations

The collector sampled AppleSmartBattery through IOKit every ten seconds,
including signed battery current and PowerTelemetryData. It also recorded the
root daemon report and `pmset -g battlimit`. PowerUI readback and the HTTP API
were checked separately. The private raw log is
`data/battery/native-preferences-trial.jsonl` (runtime data, not committed).

| Time | Control / observation | Battery | Current | Power evidence |
| --- | --- | --- | --- | --- |
| 19:09:06 | Off baseline | 79%, charging | +2314 mA | Adapter 82.463 W; system 54.927 W; battery +27.536 W |
| 19:13:57 | Native 50% policy lowering charge | 80%, not charging | -3348 mA | Battery supplying the system during drawdown; this is not holding |
| 19:41:02 | Temporary 49% target reached | 49%, not charging | 0 mA | Adapter and system both 43.858 W; battery 0 W |
| 19:42:33 | Changed 49% to final 50% target | 49%, charging | +2706 mA | Adapter 77.953 W; system 46.061 W; battery +31.892 W |
| 19:45:53 | Charging stopped at final target | 50%, not charging | 0 mA | Adapter and system both 48.742 W; battery 0 W |

PowerUI returned50 and both `manualChargeLimit` policies in `pmset` returned
SOC50. The UniApi API returned `phase: holding-low`, target50, healthy helper,
AC connected and not charging. These policy readings are supporting evidence;
the charge-from-below and subsequent zero-current charger-powered state are
what establish physical operation.

## Sustained final hold

From 19:45:53 through 19:51:45 CEST, 36 samples spanning
351.2 seconds all reported **50%, AC connected and not charging**.
Battery current ranged from -30 to 0 mA. Adapter input ranged
from 44.456 to 49.363 W and supplied at least
99.28% of the measured system load. Small telemetry fluctuations
are recorded rather than claiming the battery current is exactly zero forever.
The configured limit was left at50; no adapter-cycling controller was running.

## Transitions and recovery

- A lower-target stop restored the previous80 native policy and removed the
  root restoration journal before acknowledging completion.
- Off then resumed physical charging, establishing a real positive-current
  control case.
- Starting from Off exposed a bug: preferences alone updated the reported
  target but created no actual SOC policy. The server now enables the native
  policy first, then lets the helper journal and lower that enabled baseline.
  The same sequence was repeated through the live API successfully.
- The API never enables a new baseline during an unacknowledged or conflicted
  restoration, even when the requested target file is zero. The `lower-target
  transition after a stop timeout` regression in
  `server/src/apps/battery/battery.test.ts` covers this.
- Active49-to50 changes do not re-enable the ordinary native setter and do not
  open administrator dialogs. They restore the journaled baseline before the
  next preference transaction.
- Server restarts during the test preserved the daemon and policy. Reboot and
  sleep/wake were not exercised during this session.

## Software checks

Full `tools/verify.sh` passed: server/client typechecks,171 server tests,
51 client tests, client build, native checks, shim suites and live smoke.
The live pentest passed43 checks with zero failures or skips. The secret scan
was clean. An unrelated benchmark process-cancellation integration test failed
once during a full run, passed in isolation and passed on the complete rerun;
no benchmark code was changed to hide it.

A second agent reviewed the helper, filesystem confinement, rollback,
telemetry and transition ordering. All identified blockers were fixed.
The user explicitly accepted local verification instead of GitHub CI; the
remote job had not started because of an account billing/spending-limit block.

This confirms the measured Mac/build and test interval. It does not claim an
overnight, reboot or sleep/wake endurance test. PowerUI remains a private API.
