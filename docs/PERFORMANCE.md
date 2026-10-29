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
