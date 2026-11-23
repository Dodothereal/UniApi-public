# Native interface design

UniApi is drawn as paper and graphite: warm neutral surfaces, ink for the one
primary action of a view, and a single forest accent that marks selection,
focus and values that are changing. Hairlines and tone steps separate things;
shadows are reserved for what floats above the window (menus, the command
palette, notices). Theme overrides and the Light/Dark variants are described
in [Settings](SETTINGS.md).

The system lives in five files. Use them; do not restate their values in a page.

| File | Holds |
| --- | --- |
| `NativeTheme.swift` | `Theme` colour, type, radius and size tokens, density, appearance |
| `NativeControls.swift` | `T3Button`, `T3IconButton`, `T3Switch`, `T3Field`, `.nativeField()`, `T3Segmented`, `NativeTabs`, `NativeMenuSelect`, `MonoChip`, `NativeKbd`, `NativeStatus` |
| `NativeLayout.swift` | `NativePage`, `NativePageBar`, `NativeSheet`, `NativeSection`, `NativeStack`, `NativeDisclosure`, `SettingRow`, `Card`, `NativeLinkRow`, `NativeReadoutStrip`, `NativeReadout`, `NativeTickMeter`, `NativeGrowBar`, `EmptyState`, `NativeError` |
| `NativePatterns.swift` | `NativeSetup`, `NativeInspectorSplit`, `NativeInspector`, `NativeFact`, `NativeIconMenu`, `NativeRouteLine` |
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

A page is one fixed bar and the content under it.

`NativePage` draws the bar (`NativePageBar`, 52 points). Its order is the
same on every page, left to right: the page name, its views (`NativeTabs`),
then on the right a range or source filter, search, icon actions, and one
primary action last. Rare actions go in one `NativeIconMenu`. Actions never
scroll away. A detail view passes `backTitle`/`back`, which the bar shows as
a crumb before the name. A scrolling page has a column at most 1080 points
wide, so every page has the same left edge. A page that lays out its own
panes passes `scrolls: false` and uses `NativePane` for each scrolling part.

There is no title block, subtitle or description under the bar. Content
starts immediately.

A destination can hold several pages as views. `NativeBenchmarkPage` (Run,
Free test, Results, Charts, Runs), `NativeArenaHost` (Judge, Ranking,
Presets, History, Prompts) and `NativeEnergyHost` (Now, History, Sensors,
Preferences, Charge limit) pass `NativeHostTabs` to the page they show, and
the bar draws one strip with the destination's name. The identifiers
`results`, `prompts` and `battery` still resolve; they open their view.

Four patterns from `NativePatterns.swift` carry the interaction on every
page. Use them instead of a page-specific arrangement.

- **Setup steps** (`NativeSetup`). Whatever a page needs before it works (a
  provider, a helper, a permission, a model download, a service) is one
  numbered list where content would start. The next open step carries the
  action; a step that cannot run yet says why. The list is gone when every
  step is done. Do not add a warning, a status mark or a disabled button
  elsewhere for the same thing.
- **List and inspector** (`NativeInspectorSplit`, `NativeInspector`,
  `NativeFact`). A row opens an inspector on the right with its facts and its
  actions pinned at the bottom. Rows do not expand in place and do not open a
  sheet. Escape closes the inspector, arrow keys move between rows, and below
  720 points the inspector covers the list. Activity, Switcher (providers),
  Arena (Ranking, Presets) and Jobs use it.
- **Board** (`NativeBoard`, `NativeHero`, `NativeBoardRow`,
  `NativePaneSection`, `NativePaneFact`). A page of measurements is one
  frame: the headline is the number the chart plots, the table under the
  chart is its legend, and a fixed pane on the right describes the selected
  row, or the whole range when nothing is selected. Selecting a row
  re-scopes the pane in place; it does not open another page. Export sits at
  the foot of the pane. Below 920 points the pane moves under the table.
  Statistics (Usage, Speed, Benchmark) and Energy (Now, History, Sensors)
  use it. `NativeSplitTicks` divides one quantity into its parts on the tick
  scale, as Energy does for where power comes from and where it goes.
- **List and detail panes.** A page about one selected object keeps the list
  on the left and the object on the right: Transcribe, Settings (categories),
  Benchmark Run (providers and models on the left, the run on the right).
- **Route line** (`NativeRouteLine`). A tool's route reads left to right as
  tool, source, model, effort. The stops are the controls and one action on
  the right applies them. Switcher edits it; Home shows it.

Lists are tables: fixed columns, hairlines between rows, a tone step under
the pointer (`nativeRowHover`), and the action revealed where the pointer
is. `NativeLinkRow` is the standard row that goes somewhere. Group with
hairlines and tone steps; a bordered `Card` is for a chart or a keyboard, not
for wrapping a list.

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

When the bar already holds the action, the empty state does not repeat it.
Benchmark's Run view sends a new installation to Switcher to add a provider;
Results sends it to Run. Code omits its project rail after a successful read
returns no projects; the full workspace then offers Add project. Loading,
read failures and existing projects keep their normal project rail.

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
Running and queued jobs appear above Settings as a tray with their progress
on every page; the tray opens Jobs, which is otherwise reached from the
command palette or Home. The footer shows the route new Claude Code sessions
take and opens Switcher; it shows a warning only when the shim is not running. Command-K opens the
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

Setup is one screen titled **Where to start**. It lists Home, Switcher,
Statistics and Transcribe by page name with one line saying what the page
holds, and opens the selected page directly. Appearance and Spacing sit on the
same screen as `T3Segmented` controls. Skip stays in the header. Do not insert
an appearance wizard between the choice and its destination. Motion follows
the existing preference and macOS Reduce Motion; further customization remains
in Settings.

Header, content and footer share one aligned column. The selected choice is
drawn like the selected sidebar row: raised surface, hairline border and the
accent bar on its leading edge. Do not add a checkmark, radio circle, icon well
or outlined group. The primary action is ink, names its destination and stays
in a fixed footer above a hairline.

At sufficiently wide and tall sizes an inert illustration of the shell sits
beside the choices. It uses the real theme tokens and density values and
changes with the choices. It is not a live page, does not contain user data
and must not create an app session, connect a provider or download a model.
Smaller viewports use a two-column grid and omit the illustration. Density
changes only the illustration and destination pages; keep the choice hit
targets stable so customization does not move the selection under the pointer.
Content can scroll while the primary action stays available. Review the
complete view at the exact viewport, disabling AppKit's automatic host sizing
so it cannot conceal clipping by enlarging the window.

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
