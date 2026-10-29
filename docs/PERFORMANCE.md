# Performance observations

## Installed running-app navigation, 0.1.9

On 2026-10-29, the installed optimized arm64 app was exercised through its real
sidebar and Statistics header. The build targets macOS 14 with SDK 26.5; this
run used macOS 27.2. The default-off Settings recorder was started and stopped
through the application controls. It produced 240 rows for 48 visits in one
process and session, each with a start, first view commit, data view commit,
first host draw and data host draw. No failed or incomplete visit was omitted.

The sequence included three passes through all 14 destinations. Statistics was
visited directly after Speed in each pass, then once more for Reload. Returning
to Settings to stop recording adds its fourth visit. Four Reload clicks were
recorded: an initial click followed by three more once the control was ready.
The first batch stopped when Reload was still disabled; that accepted click is
retained in the results. There is no warm-only exclusion or outlier removal.

These are running-app measurements with retained data, not cold launch. The
source is the reviewed code merged in PR #16. The selected Statistics scope
was Codex, All time, overview. Other pages used their existing selections;
sidebar navigation did not change model routes, submit jobs or set hardware.
UI automation runs on the shared desktop. Its observation overhead and other
processes are not a controlled idle environment.

A data view commit means the page's required model/service state was accepted
by its view. A host draw callback is later, but does not establish GPU display,
frame rate or animation smoothness. Page gates differ: the table compares
current timings, not equal amounts of work or functional coverage.

| Page | Visits | Median data view, ms | Median data draw, ms | Data draw range, ms | Median app CPU at draw, ms |
| --- | ---: | ---: | ---: | ---: | ---: |
| Home | 3 | 10.4 | 293.3 | 273.5–440.7 | 432.4 |
| Speed | 3 | 13.8 | 260.2 | 258.9–621.3 | 271.4 |
| Results | 3 | 38.6 | 448.8 | 416.3–575.1 | 741.2 |
| Prompts | 3 | 29.1 | 174.2 | 143.3–176.6 | 188.7 |
| Arena | 3 | 5.8 | 164.5 | 133.7–172.6 | 167.3 |
| Switcher | 3 | 5.7 | 342.8 | 300.8–346.4 | 349.3 |
| Code | 3 | 29.2 | 137.8 | 130.4–147.0 | 142.4 |
| Statistics | 4 | 22.1 | 323.7 | 216.7–326.9 | 324.5 |
| Activity | 3 | 5.1 | 231.0 | 201.3–245.4 | 241.0 |
| Fan Control | 3 | 22.5 | 198.3 | 193.1–388.5 | 229.7 |
| Battery | 3 | 30.7 | 105.3 | 95.7–114.4 | 107.1 |
| Transcribe | 3 | 6.1 | 165.0 | 146.7–173.9 | 193.5 |
| Jobs | 3 | 13.8 | 265.6 | 265.2–267.7 | 392.0 |
| Settings | 4 | 6.1 | 117.9 | 98.0–174.1 | 110.0 |

Statistics Reload's four data draw times ranged from **266.1 to
1650.6 ms**, with a **935.5 ms median**. Its median
accepted data view time was 907.1 ms; median process CPU through the
accepted data draw was 1346.3 ms. Reload checks for changed history;
it does not substitute a retained response for the requested refresh. Source
stores were live, so this does not isolate changed-file parsing cost.

The process reached a lifetime peak RSS of 664.2 MiB. This is one process's
high-water mark across the session, not memory allocated by any page or a
system-wide footprint. CPU is the app process's accumulated user plus system
time during each visit; it can exceed elapsed time with multiple threads.
Earlier recorder work and unrelated app work contribute. Children, GPU and
other processes are not included. Recording writes add observation overhead.

The current result is responsive data readiness with a measurable draw delay;
Reload is not instant. This run does not establish a speedup percentage because
there is no matched old-version run using the same data and conditions.

## Controlled Speed layout change

A separate retained six-invocation ABBAAB control compared an eager `VStack`
with `LazyVStack` for the complete native Speed page, including its normal
`NativePage`/ScrollView/Card hierarchy. It used 1,000 synthetic report rows,
15 providers and a 1150×840-point viewport, with inactive tasks and reduced
motion. Three samples per arm gave these medians:

| Metric | Eager | Lazy | Reduction |
| --- | ---: | ---: | ---: |
| Initial construction, layout and bitmap draw | 1005.207 ms | 244.488 ms | 75.68% |
| Process CPU | 1066.838 ms | 318.503 ms | 70.15% |

All six comparison PNGs were byte-identical. The production change was only
the report container plus explanatory comments; the control inverse reproduced
the original page. Timing excludes PNG encoding. Separate invocations were
recorded, but per-run PIDs and cold OS-cache evidence were not retained.
This supports that specific layout optimization, not a 70% whole-app CPU
reduction. It does not measure scrolling, current history, startup, RSS or GPU
presentation, and must not be combined with the installed table as one A/B run.

## What still needs separate evidence

- Reload and drawing still have room to improve; the recorded upper bounds are
  retained rather than described as instant.
- Cold entry, sustained scrolling, compositor cadence, energy, process census
  and matched before/after resource measurements are not established here.
- Fresh-user behavior, physical macOS 14, Intel/universal builds and real
  provider streaming verification remain separate from these page visits.
- Accurate token totals, API price coverage and honest unknown costs are
  correctness requirements; none can be replaced by a faster rendered result.

The [validation record](VALIDATION.md) covers source, fixture and native test
checks. Private raw captures and operator data are kept outside the repository;
these aggregate timings contain no prompts, credentials, model identities or
usage totals.

## Summary-only publication, 0.1.10

A diagnostic stack sample of the installed 0.1.9 Reload path showed both
changed-file parsing and full cached-row assembly, followed by construction of
the all-source chart board for publication. Publication consumes only token
total, model count and response count. The selected Codex view then prepares
its own board. Stack counts identify work, not elapsed-time percentages.

Version 0.1.10 replaces that premature chart construction with a cached pure
counter projection. Without lifetime data it keeps original event accumulation
order. With Claude lifetime data it keeps the same Claude reconciliation and
UTC fresh tail, then adds every other source together in original order. The
model count includes cache-only models. Existing view/chart folds, import,
compression, deduplication and generation-publication checks are unchanged.
The counter cache is invalidated with the existing query caches.

A private immutable-backup query control also compared the existing indexed
row traversal with a table scan plus sort. Both produced identical ordered row
digests, but the alternative was slower and used more peak memory, so it was
rejected. The production query was not changed.

Eight new native methods compare the projection with the unchanged full-fold
oracle. They cover every totals field and Double bit pattern, six known sources
plus an unknown harness, shared and cache-only models, empty inputs, strict UTC
watermarks, invalid dates and observable floating-point accumulation order. A
real private service fixture compares both published and requested counters
before loading the overview, across changed and unchanged refresh generations.

A 20,000-record synthetic six-source/lifetime-cache control, in one test process
with ABBAAB order and three samples per arm, measured median elapsed time of
**163.127 ms for the full board versus 6.102 ms for the counter projection**.
Fixture construction and exact equality checks are outside timing. The test
imposes no machine-speed cutoff. This is a component result, not an installed
Reload percentage, CPU reduction, cold-process or memory measurement.

The complete optimized native gate passed 1,279 tests with zero failures.
The reviewed 0.1.10 package was installed through the guarded updater, and its
18 installed app files matched the candidate. Prior usage rows, providers,
client configuration and the complete saved preference domain were preserved.
Normal aged fan-history retention and accumulating rollups were checked
separately; this is not an all-database-bytes-unchanged claim.

## Installed follow-up, 0.1.10

The same real sidebar sequence was repeated on macOS 27.2/arm64 with the Codex,
All time Statistics overview. The first recording contains **235 rows and 47
complete visits**: 44 navigation visits and three admitted Reload operations.
The UI tool attempted four clicks; only three admitted operations appear in the
capture. The records do not establish why one attempt produced no operation,
and there is no invented fourth timing. No recorded failure, incomplete visit
or first sample was removed.

| Page | Visits | Median data view, ms | Median data draw, ms | Data draw range, ms | Median app CPU at draw, ms |
| --- | ---: | ---: | ---: | ---: | ---: |
| Home | 3 | 9.8 | 315.6 | 282.5–393.1 | 433.6 |
| Speed | 3 | 14.7 | 272.4 | 255.0–607.7 | 270.1 |
| Results | 3 | 36.5 | 482.7 | 460.7–602.1 | 548.0 |
| Prompts | 3 | 30.1 | 161.6 | 134.9–185.3 | 181.0 |
| Arena | 3 | 6.3 | 157.8 | 146.4–195.6 | 164.8 |
| Switcher | 3 | 5.9 | 322.3 | 277.3–327.0 | 328.4 |
| Code | 3 | 29.6 | 133.6 | 126.7–142.2 | 140.7 |
| Statistics | 4 | 20.8 | 323.0 | 223.6–332.6 | 321.5 |
| Activity | 3 | 5.3 | 226.9 | 199.8–246.0 | 235.8 |
| Fan Control | 3 | 21.8 | 225.8 | 193.5–390.6 | 252.7 |
| Battery | 3 | 30.6 | 112.7 | 104.4–116.7 | 110.7 |
| Transcribe | 3 | 6.3 | 157.4 | 143.8–165.5 | 194.5 |
| Jobs | 3 | 14.4 | 268.1 | 266.9–273.0 | 391.9 |
| Settings | 4 | 6.6 | 123.3 | 99.2–174.7 | 110.1 |

A separate All apps, All time recording contains **65 rows and 13 complete
visits**: three Home → Speed → Statistics passes, a final Settings visit, and
three Reloads. That scope was already loaded before starting its recording.
Each Reload used a separate real-input call. All 13 recorded visits completed
with no recorded failures or incomplete visits. The two sessions share one
app process but have distinct recording identities.

| Statistics scope/action | Visits | Median data view, ms | Median data draw, ms | Data draw range, ms | Median app CPU at draw, ms |
| --- | ---: | ---: | ---: | ---: | ---: |
| Codex navigation | 4 | 20.8 | 323.0 | 223.6–332.6 | 321.5 |
| Codex Reload | 3 | 242.6 | 274.1 | 220.5–278.5 | 349.8 |
| All apps navigation | 3 | 20.8 | 302.2 | 297.1–316.5 | 303.7 |
| All apps Reload | 3 | 1696.0 | 1759.4 | 1728.8–1775.8 | 2332.5 |

The running process's peak RSS reached 663.0 MiB across these recordings.
It is not page memory or a matched memory comparison. The same host-draw, CPU,
observer-overhead and shared-desktop limitations apply as for 0.1.9.

Codex Reload was quicker in this observation, but source histories were live,
the scan workload was not frozen and sample counts differ. There is no causal
whole-app speedup percentage. All apps Reload still took approximately
1.73–1.78 seconds and remains an optimization target. The capture alone does
not isolate its cause. This is not an instant-loading or compositor-smoothness
completion claim. The original Statistics scope was restored after testing.

## Benchmark timestamp eligibility, 0.1.11–0.1.12

A further diagnostic sample exercised one All-apps Reload only after that scope
had settled. It contained benchmark ledger decoding and timestamp parsing as
well as usage parsing, database assembly and chart folding. Different sampled
instruction addresses do not establish repeated calls, and stack counts are
not elapsed-time percentages.

The candidate keeps the complete benchmark JSON decoder and deduplication
unchanged. A tested partial-decoder shortcut was rejected: an ignored `1e999`
value made the full decoder reject a record that a partial decoder accepted.
A syntax-valid JSON projection would therefore widen existing admission.

Instead, relevant provider/model rows parse timestamps only when a date range
requires filtering or an eligible latency trend needs a clock. All-time spend
retains its original first/last strings, including unparseable dates. The same
parser, finite numeric TTFT requirement, successful latency test and nonempty
run identity remain in force.

Eight new regression methods cover parser-call admission, eligible zero/negative
latencies and numeric run IDs, real timestamp forms, every positive-range
eligibility class, all-time invalid-date spend and first/last strings, ranged
model cutoffs and medians, and complete-row deduplication/rejection. They compare
full legacy outputs and number bit patterns. The full optimized native gate
passed 1,287 tests with zero failures.

A 1,000-row synthetic control with six-digit offset timestamps and 10% eligible
latency tests measured median-three elapsed time of **47.180 ms for eager clocks
versus 4.892 ms for eligible-only clocks**, in one process with ABBAAB order.
Complete legacy fold results are compared outside timing. Parser-call counts
are asserted in the focused helper tests, not in that timing loop. This is a
clock-component result, not CPU, a fresh-process test or an installed app
improvement percentage. The installed follow-up below measures the resulting
0.1.12 app separately.

## Installed follow-up, 0.1.12

Two explicit recordings each contain 65 rows and 13 complete visits in one
running process: three Home → Speed → Statistics passes, three individually
admitted header Reloads and a final Settings visit. Each scope was settled
before starting its recording; each session was explicitly stopped. All 26
visits have all five phases, with no failed/incomplete visits or dropped
samples. The app's 18 installed files matched before and after. The original
Codex/All-time scope was restored. Independent saved-record arithmetic review
reproduced every sample, median, range and CPU total.

| Statistics scope/action | Visits | Median data view, ms | Median data draw, ms | Data draw range, ms | Median app CPU at draw, ms |
| --- | ---: | ---: | ---: | ---: | ---: |
| All apps navigation | 3 | 22.2 | 308.9 | 301.9–313.8 | 302.4 |
| All apps Reload | 3 | 1654.0 | 1720.5 | 1638.7–1736.2 | 2253.5 |
| Codex navigation | 3 | 21.7 | 330.4 | 325.8–331.2 | 325.2 |
| Codex Reload | 3 | 1322.7 | 1352.0 | 1351.6–1353.4 | 1902.4 |

Navigation committed data quickly, but Reload is still not instant. These
histories were live and the work was not frozen between releases. In particular,
the slower Codex Reload observation is retained rather than omitted or presented
as a matched-version regression percentage. The same host-draw, process CPU,
recording-overhead, shared-desktop and small-sample limitations apply. This does
not prove GPU presentation, animation cadence, cold entry or per-page memory.

A separate source-bound diagnostic sample of one settled Codex Reload found
changed-file envelope parsing and full cached-row assembly. It is an inclusive
stack sample, not a timing breakdown or invocation count. An initial diagnostic
sample missed the requested Reload and is not used as its profile.

## In-place fold bucket candidate

The candidate updates stored day/model dictionaries and project session sets
in place. The previous loop copied each nested container into a local tuple
before updating it, creating a second owner and triggering copy-on-write.
Event order, numeric operations, group membership, date handling and all
reported fields remain unchanged; no extra corpus cache is retained.

A source-bound control compared complete legacy/candidate boards, including
every numeric bit pattern, across 216 cases: sorted, reversed and interleaved
records, four time zones, three ranges, source scopes and optional lifetime
cache. All matched. Six separate optimized invocations in ABBAAB order used
40,000 synthetic records; fixture construction and result hashing were outside
timing. The actual binary targets macOS 14 with SDK 26.5.

| Metric | Original copying loop | In-place candidate |
| --- | ---: | ---: |
| Median elapsed time | 87.225 ms | 47.078 ms |
| Median process CPU | 85.936 ms | 46.744 ms |
| Median process peak RSS | 51,167,232 bytes | 51,052,544 bytes |

All six full-result bit-pattern digests match. Process peak RSS includes the
fixture and output and is not page memory. This is a synthetic component
control, not an installed speedup, GPU/FPS result or completion of the remaining
Reload work. Four production regression methods and the full 1,291-test optimized native
gate passed. Installed candidate timing remains pending.
