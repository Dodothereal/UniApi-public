# Native interface conventions

The native interface is built from the `Theme` tokens and `T3Button` styles in
`LegacyTheme.swift`, the page furniture in `NativeComponents.swift`, the layout
vocabulary in `NativeDesign.swift` and the bundled Lucide icon renderer in
`NativeIcon.swift`. Theme overrides and the Light/Dark variants are described
in [Settings](SETTINGS.md).

## Principles

- **Canvas, not cards.** Content sits directly on the page. Structure comes
  from one alignment grid, hairline rules (`NativeRule`) and type scale. Filled
  surfaces are for things you type into and things that float.
- **Numbers are the interface.** Measured values use `Theme.display` (condensed,
  tabular digits) through `NativeFigure` or `NativeNumberText`. Monospace is for
  literal IDs, paths, keys and model identifiers only.
- **Warm graphite and paper.** One vermilion accent marks selection, primary
  focus and live data. Success, warning and failure colours describe status and
  nothing else.
- **No filler text.** Pages have no subtitle. Do not add captions that restate
  a heading, "Live" pills, decorative eyebrows or instructions for self-evident
  controls. Put a necessary explanation in `.help` or behind a disclosure.
- **Absence collapses.** Zero-value items are left out or summarised in one
  line; they are not drawn as empty tiles.

## Page structure

Normal pages use `NativePage`: a centered column under one pinned
`NativePageBar` holding the title and the page's actions. Reload, export and
similar secondary actions are `T3IconButton`s with a `.help` label; the bar has
at most one filled primary button. Workbenches (Code) can use their own frame
when a transcript, project rail or inspector needs the available height.

Inside a page use:

- `NativeSection` for a titled group with a hairline and optional trailing
  controls.
- `NativeLedgerRow` for lists of things. Rows are separated by rules, not
  boxed; the selected row carries an accent rail.
- `NativeFigure` / `NativeFigureRow` for headline readings.
- `NativeGutterGroup` for settings: the group name sits in a left gutter and
  every control aligns in one right column.
- `NativeStatusText` for a status that is not normal. Normal states are silent.

The shell provides Command-K (jump to any page, including pages hidden from the
sidebar) and Command-B (sidebar). The sidebar selection is one marker that
moves between rows.

## Empty states

`NativeEmptyState` states what is absent in the display face, left-aligned on
the page grid, with at most one primary action directly below it. Leave
`detail` empty unless the user needs a fact they cannot infer. Code omits its
project rail after a successful read returns no projects; the workspace then
offers Add project.

## Review scope

Use source-bound native page renders in Light/Dark at representative sizes.
Keep synthetic or empty data labelled. An invisible render can establish layout;
it cannot establish real input, compositor smoothness or service readiness.
Exercise the relevant controls separately and preserve the user's settings.
Motion must respect both the app preference and macOS Reduce Motion. Do not
add frame timers or repeat entrance animations on background refreshes.

## Welcome guide

Setup is one screen: choose a task (Look around, Connect a model, Explore usage
or Transcribe audio), with its Home, Switcher, Statistics or Transcribe destination
shown below. Adjust appearance and spacing if desired, then open the selected
page directly. Skip
for now stays in the header. Do not insert an appearance wizard between the
user's task choice and its destination. Motion follows the existing preference
and macOS Reduce Motion; further customization remains in Settings.

Header, content and footer share one aligned column. Use a 24–26 point heading,
short descriptions, consistent Lucide icon slots and a single checkmark for
selection. Avoid nested icon wells, radio circles, outlined groups and repeated
selection decoration. The primary action names its destination and remains
40 points high in a fixed footer.

At sufficiently wide and tall sizes, a small labelled, inert appearance
illustration sits beside the choices. It uses the real theme tokens and density values and changes
with the choices. It is not a live page, does not contain user data and must not
create an app session, connect a provider or download a model. Smaller viewports
use a two-column task grid and omit the illustration. Appearance and Spacing
then use equal-width columns with matching label baselines. Density changes
only the preview and destination pages; keep the task hit targets stable so
customization does not move the selection under the pointer. Do not put
clickable-looking chevrons in the inert illustration. Content can scroll while
the primary action stays available. Review the complete view at the exact viewport, disabling AppKit's
automatic host sizing so it cannot conceal clipping by enlarging the window.

The heading has accessibility heading semantics and requests focus on entry.
Controls retain keyboard activation and selected traits. Hover and press effects
are brief and disabled under reduced motion, with no ongoing animation work.

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
