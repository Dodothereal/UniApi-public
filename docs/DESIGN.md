# Native interface conventions

The native interface uses the shared components in `NativeComponents.swift`,
the `Theme` tokens and `T3Button` styles in `LegacyTheme.swift`, and the bundled
Lucide icon renderer in `NativeIcon.swift`. Use these components for typography,
color, button sizing, hover states, radii and borders. Theme overrides and the
Light/Dark variants are described in [Settings](SETTINGS.md).

Normal pages use `NativePage` and its finite scrolling viewport. Keep header
actions in that page's normal flow. Workbenches can use their existing frame
when a transcript, project rail or inspector needs the available height. Review
the complete page at wide and narrow sizes; a small isolated component can hide
container sizing problems.

## Empty states

Keep the explanation and its next action in one centered group. `NativeEmptyState`
accepts an optional action title, icon and closure, with the action separated
from the explanatory text by 16 points. Its button remains a separate accessible
control. Do not place an action after the empty state's outer padding; that
makes it look unrelated to the explanation.

Speed's provider setup and Results' Benchmark navigation use this group. The
free-test action has secondary emphasis and is unavailable when no providers
are configured. Code omits its project rail after a successful read returns
no projects; the full workspace then offers Add project. Loading, read failures
and existing projects keep their normal project rail.

Home's destination grid reserves at least 140 points plus its density-scaled
horizontal padding per card. It uses one, two or four columns as that space is
available, so destination names do not break mid-word to fit a four-column row.

## Review scope

Use source-bound native page renders in Light/Dark at representative sizes.
Keep synthetic or empty data labelled. An invisible render can establish layout;
it cannot establish real input, compositor smoothness or service readiness.
Exercise the relevant controls separately and preserve the user's settings.
Motion must respect both the app preference and macOS Reduce Motion. Do not
add frame timers or repeat entrance animations on background refreshes.

## Welcome guide

Setup uses one centered content column with a compact four-step header. Header,
content and footer share the same 636-point maximum width and outer inset. Keep
Skip setup in one place, the header; Back and the primary action stay in the
fixed footer at 40 points high. Content may scroll in short viewports without
moving these actions offscreen.

Use the shared theme, type and Lucide icons. Only selected choice cards receive
an accent outline; neutral cards use a quiet surface. Appearance previews depict
both palettes deliberately, while their surrounding controls use live theme
tokens. Destination cards reserve equal space for their descriptions. Avoid a
second navigation rail, a mock dashboard and repeated setup explanations.
Step transitions are a 200 ms opacity/offset change, with no ongoing animation
work and an immediate reduced-motion path.

## Job history cleanup

Jobs labels its history action **Clear old jobs…** and opens a confirmation
before deleting anything. The confirmation names the seven-day cutoff, the
completed/failed/cancelled states and the job details/logs being removed.
Running and queued jobs, benchmark result files and saved transcripts remain.
The existing queue predicate determines eligibility when confirmed; the UI
does not substitute the currently filtered or visible rows. Cleanup remains
unavailable in read-only mode and while an earlier cleanup is running.

## Provider setup

Codex's API-provider section offers Add provider beside its heading, using the
same form as the Claude Code tab. An empty section explains the next step;
route verification and catalog selection remain separate actions.

## Diagnostic timing

The optional UI recorder separates navigation visits from Statistics
header `refresh` and `rebuild` visits. An action starts its clock before the
asynchronous read begins; retained content cannot satisfy the new visit.
A successful operation receipt and a newly committed payload/benchmark pair
must agree on the exact scan ID and requested scope. This also covers the normal
`stats.scanned` event read replacing the button's original read. Departures and
unmatched reads are recorded as cancelled or incomplete, not successful samples.
Model-detail responses without scan identity remain unmeasured.

Automatic environment-path recording remains read-only-only. An explicit
five-minute recording can be started under Settings diagnostics in the normal
app. Its fixed metadata schema and protected fresh file are separate from the
automatic recorder. Starting and stopping never remount pages, invalidate a
cache or synthesize input. Session IDs reject callbacks and parent-visit links
from earlier recordings; manual visits never use the app-entry label. A fixed
monotonic deadline gates writes even if the expiry task is delayed.

The recorder is disabled by default. View-commit timestamps measure
the hosting view update, and display callbacks establish drawing; neither proves
GPU presentation or animation frame rate. CPU deltas cover this process, and
peak RSS is the process lifetime high-water mark. UI-tool round trips and
Command-R remounts must not be substituted for header Reload measurements.
Timestamps precede their own record write, but earlier recorder work can still
contribute to a later process CPU interval. Reject an incomplete JSONL tail
after a write failure; do not silently accept it as a complete capture.
