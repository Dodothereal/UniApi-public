# Native interface design

UniApi is drawn as paper and graphite: warm neutral surfaces, ink for the one
primary action of a view, and a single forest accent that marks selection,
focus and values that are changing. Hairlines and tone steps separate things;
shadows are reserved for what floats above the window (menus, the command
palette, notices). Theme overrides and the Light/Dark variants are described
in [Settings](SETTINGS.md).

The system lives in four files. Use them; do not restate their values in a page.

| File | Holds |
| --- | --- |
| `NativeTheme.swift` | `Theme` colour, type, radius and size tokens, density, appearance |
| `NativeControls.swift` | `T3Button`, `T3IconButton`, `T3Switch`, `T3Field`, `.nativeField()`, `T3Segmented`, `NativeTabs`, `NativeMenuSelect`, `MonoChip`, `NativeKbd`, `NativeStatus` |
| `NativeLayout.swift` | `NativePage`, `NativePageBar`, `NativeSheet`, `NativeSection`, `NativeStack`, `NativeDisclosure`, `SettingRow`, `Card`, `NativeLinkRow`, `NativeReadoutStrip`, `NativeReadout`, `NativeTickMeter`, `NativeGrowBar`, `EmptyState`, `NativeError` |
| `NativeMotion.swift` | `NativeMotion` curves and springs, `nativeEntrance`, `NativeNumberText`, visibility and reduced motion |

Icons are the bundled Lucide set through `NativeIcon` (stroke 1.7). Pick the
icon that names the object or the verb; do not decorate text with one.

## Tokens

- Surfaces, lightest to deepest: `Theme.raised`, `surface`, `bg`, `sunken`.
  `surface` is a sheet lying on the page `bg`; `sunken` is recessed (sidebar,
  wells). Never put a `Card` inside a `Card`.
- Ink: `ink`, `dim`, `muted`, `faint`. `faint` is for rulers, placeholders,
  group labels and disabled marks, not for text someone must read.
- Lines: `rule` between rows, `border` around a sheet, `input` around
  something that takes input.
- Signal: `accent` for selection, focus, switches that are on and live
  progress; `link` for accent-coloured text. A primary button is ink
  (`T3Button(.primary)`), not accent.
- Status: `okFg`, `warnFg`, `failFg` for text and marks, `ok`, `warn`, `fail`
  for fills. State is always a word or an icon as well (`NativeStatus`);
  colour alone never says it.
- Series: `Theme.pairColor(_:)` for provider/model pairs, `Theme.series` for
  up to five unrelated chart series. Charts do not borrow the accent or a
  status colour for a series.
- Type: `Theme.ui` for text, `Theme.num` for readouts that change in place
  (proportional face, tabular figures), `Theme.mono` for identifiers, paths,
  model names and logs. Sizes: 11, 12 (`textXs`), 13 (`textSm`, body),
  15 (`textBase`), 18, 22, 28. Apply `Theme.tracking(size)` at 15 and above.
- Geometry: a four point grid. Radius 4 (chips), 6, 7 (controls), 12 (sheets),
  16. Controls are 24, 28 or 34 points high.

## Pages

A page is one fixed bar and one column.

`NativePage` draws the bar (`NativePageBar`, 52 points): the page name, its
views as `NativeTabs`, and its actions on the right. Actions never scroll
away. A detail view passes `backTitle`/`back`, which the bar shows as a
crumb before the name. The column is at most 1080 points wide and centred, so
every page has the same left edge; do not pass a narrower width. A workbench
that owns its whole frame passes `scrolls: false` and lays out its panes
under the bar.

There is no title block, subtitle or description under the bar. Content
starts immediately.

Three grammars cover every page:

- **Board** (Home, Statistics, Results, Activity, Fan Control, Battery, Energy,
  Keyboard Stats, Jobs). Lead with the numbers that matter as one
  `NativeReadoutStrip`, then charts and tables, each a `Card` or a
  `NativeSection` with a short literal name.
- **Sheet** (Settings, Switcher, Speed, Transcribe). `NativeSheet` holds
  `NativeSection`s; each is named in the left margin with its controls in the
  column beside it, and sections are ruled apart. The margin label moves above
  its content when the column is narrow.
- **Workbench** (Code, Prompts, Arena). A list rail, the main pane and an
  optional inspector, separated by hairlines rather than gaps.

Lists are tables: fixed columns, `NativeStack` hairlines between rows, a tone
step under the pointer (`nativeRowHover`), and the action revealed where the
pointer is. `NativeLinkRow` is the standard row that goes somewhere.

`NativeTickMeter` is the UniApi meter for a level, a load, a share or
progress. A chart bar stays a `NativeGrowBar`.

## Words

Write the name of the thing or the action and stop.

- No description of what a page or section is for.
- No status that only says the page works ("Live", "Up to date", "Ready"
  beside something that is plainly ready). Show state when it is not the
  normal state, or when the user can act on it.
- A section name is one or two literal words. If the content is
  self-explanatory, it has no name at all.
- A setting carries a description only when its consequence is not in its
  name.
- No slogans, no second sentence that restates the first.

## Empty states

`EmptyState` sits where content would start: left edge, top of its container,
with the one next action. Do not centre it in the page and do not place an
action outside it. Loading uses `ShimmerText` in the same position.

Speed's provider setup and Results' Benchmark navigation use this group. The
free-test action has secondary emphasis and is unavailable when no providers
are configured. Code omits its project rail after a successful read returns
no projects; the full workspace then offers Add project. Loading, read failures
and existing projects keep their normal project rail.

## Motion

Motion explains a change; it is never decoration.

- Enter on `NativeMotion.out`/`outExpo`, leave on `exit` (about a third
  shorter), travel on `inOut`. Things that slide between two places (selection
  plates, segmented thumbs, tab underlines, switches) use the springs and stay
  interruptible.
- Hover reveals a border, a tone step, a detail or the verb. Nothing lifts or
  grows. Press compresses to 0.97.
- A page's content fades up once on arrival. Background refreshes do not
  replay entrances. Numbers change through `NativeNumberText`.
- Charts draw their final geometry; bars grow from their baseline once.
- Everything respects the app preference and macOS Reduce Motion
  (`nativeReducedMotion`) and stops when the page is hidden
  (`nativeMotionVisible`). No frame timers on hidden pages.

## Shell

The sidebar is recessed (`sidebarBG`), with a selection plate that slides
between rows. Command-B collapses it to an icon rail; it never disappears.
The footer shows the route new Claude Code sessions take and opens Switcher;
it shows a warning only when the shim is not running. Command-K opens the
command palette: type part of a page or command name, arrow keys move, Return
runs, Escape closes.

The window buttons sit over the sidebar's title strip. Page bars and the
sidebar run to the top edge of the window.

## Review scope

Use source-bound native page renders in Light/Dark at representative sizes.
Keep synthetic or empty data labelled. An invisible render can establish layout;
it cannot establish real input, compositor smoothness or service readiness.
Exercise the relevant controls separately and preserve the user's settings.
Review the complete page at wide and narrow sizes; a small isolated component
can hide container sizing problems.

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
