# Native interface: the Meter design language

UniApi measures things: latency, tokens per second, tokens, cost, watts, RPM,
charge, keystrokes, minutes of audio. The interface is a bench of precision
instruments, not a dashboard of boxes. Five rules hold on every screen.

1. **Reading first.** A page opens with the one reading or state the person
   came for, set large. The one action the page exists for sits top right as
   the only primary button. Detail follows as a ledger, most used first.
   No hero copy and no paragraph under a title; an explanation is a one-line
   hint, a tooltip or an empty state.
2. **Ruled ledger, not cards.** Content sits on the canvas on one grid.
   Alignment, whitespace and hairline rules give it structure. A filled well is
   for something you edit, plot, play or drop onto. Never a grid of bordered
   boxes, and never a box inside a box.
3. **The tick scale.** One motif recurs: graduated ticks, as on a ruler or
   gauge. It appears under the page title, on meters and sliders, on chart
   axes, on dials and in the mark. A two-point signal tick marks what is
   selected.
4. **Chrome is monochrome, color is data.** Buttons, navigation and selection
   are ink on graphite or paper. Hue belongs to data series and status. One
   signal color (orange by default) marks live, now, selected and focused, and
   is never used as a series color or a decorative fill.
5. **Motion explains.** Content is on screen at once: retained data shows
   immediately and updates in place, with no skeletons and no blocking
   spinners. Motion is short and causal. The selection marker slides, numbers
   roll, meters sweep from their previous value, a panel grows from the
   control that opened it. Nothing loops unless something is live.

## Tokens (`Theme.swift`)

| Role | Token | Graphite | Paper |
| --- | --- | --- | --- |
| Bench | `Theme.canvas` | `#0F1012` | `#F4F3EF` |
| Index | `Theme.sidebarBG` | `#0A0B0C` | `#EBEAE5` |
| Filled ground | `Theme.well`, `Theme.field`, `Theme.popover` | `#181A1D` | `#FFFFFF` |
| Hover, pressed | `Theme.hover`, `Theme.pressed` | white 5%, 9% | black 4.5%, 8% |
| Text | `Theme.ink`, `.dim`, `.muted`, `.faint` | `#F0F1F2` to `#53585F` | `#131416` to `#A9ABAF` |
| Hairlines | `Theme.rule`, `Theme.ruleStrong` | white 9%, 17% | black 10%, 20% |
| Signal | `Theme.signal` | `#FF5A1F` | `#E5480C` |
| Status | `Theme.ok`, `.warn`, `.fail` and their `Fg` text variants | | |
| Plots | `Theme.track`, `.grid`, `.baseline`, `.crosshair`, `Theme.pairPalette` | | |

Radii are 5 for controls, 7 for wells and 12 for sheets. Shadows belong only
to popovers and sheets. No gradients and no translucency. A person can override
the base tokens under Settings; see [Settings](SETTINGS.md). Use the tokens,
never a literal color.

Older names such as `Theme.accent`, `Theme.surface` and `Theme.border` still
resolve to the tokens above so that every file keeps compiling. Do not use
them in new code.

## Type

Three voices, all system fonts.

| Voice | Call | Use |
| --- | --- | --- |
| Expanded | `Theme.display()` 24 | Page title, a named state set large |
| Expanded | `Theme.heading()` 12 | Section name on its rule |
| Expanded, uppercase | `MicroLabel` 9.5 | Eyebrows, column heads, units |
| Condensed numerals | `Theme.readout(_:)` at 54, 34, 24 or 17 | Every measured reading |
| Plain | `Theme.ui(13)`, `ui(12.5)` muted, `ui(11.5)` | Body, secondary, fine print |
| Monospace | `Theme.mono(10.5...12)` | Identifiers, model names, timestamps, code |

Numbers in a column are right-aligned with tabular digits and their unit
follows as a `MicroLabel`. Do not introduce other sizes.

## Layout

A four-point base with steps 4, 8, 12, 16, 24, 32 and 48. `NativePage` supplies
the margin, the 960-point content column and the gap between sections. All
content shares one left edge and one right edge. Row heights are 28 dense,
36 standard and 44 for a setting. `ColumnFlow` gives equal columns that wrap on
a narrow page; do not hand-roll `GeometryReader` breakpoints for that.

## The kit (`Kit.swift`)

| Component | Purpose |
| --- | --- |
| `NativePage(title:eyebrow:readiness:) { actions } content: { }` | Page container: eyebrow, expanded title, actions, tick rule |
| `Band(title:hint:) { trailing } content: { }` | A named section; the title sits on a rule |
| `Readout`, `ReadoutStrip` | A reading: label, condensed numerals, unit, one line of detail |
| `LedgerHead`, `LedgerRow(selected:action:)` | Column heads and ruled rows; hover bleeds into the margin |
| `OptionRow(title:detail:) { control }` | One setting with its control on the right |
| `Well` | Filled ground for an editor, plot, transcript or drop target |
| `Press(.primary / .secondary / .quiet / .danger)` | Button styles; one primary per page |
| `IconPress` | 28-point square glyph button |
| `Stops` | Choose one of a few; a signal bar slides to the choice |
| `Flip` | Two-position switch |
| `Entry`, `Pick` | Text field and menu trigger |
| `Tag`, `KeyCap`, `MicroLabel` | Identifier or state chip, a key, an engraved caption |
| `Scale`, `Dial` | Linear meter and 240-degree gauge with ticks |
| `Rule`, `TickRule`, `TickScale` | Hairline, ruler hairline, the tick shape itself |
| `Blank` | Empty or failed-read state |
| `Notice(text:tone:)` | Inline message |

`Compat.swift` keeps the earlier names (`Card`, `T3Button`, `T3Segmented`,
`SettingRow` and so on) drawing with the kit until every page is rebuilt. New
code uses the kit names. Icons come from the bundled Lucide renderer in
`NativeIcon.swift` at 1.6 to 1.75 stroke; check that a name exists in
`NativeIconPaths.swift` before using it.

## Empty states

`Blank` sits on the content edge where the content will be, not centered in a
void: a dashed glyph tile, one sentence saying what is missing, and at most one
action that fixes it. A failed read uses the same shape with a secondary Retry.
An empty page still shows its structure (section names, column heads) so the
person can see what will appear.

## The shell

The index is 212 points wide and collapses with Command-B to an icon rail
rather than disappearing. Rows are 28 points with a live reading on the right
where the page has one. The selected row carries the signal tick, and that one
marker slides between rows. Command-K opens the jump palette (pages and shell
commands); Command-1 to Command-9 open the first nine visible pages. The footer
states where Claude Code is routed and whether the shim is up. Order, hidden
pages, readings and width remain preferences.

Changing page never animates the page tree: the destination appears complete.
Only the index marker moves.

## Review scope

Review the complete page in Graphite and Paper at wide and narrow sizes; an
isolated component hides container sizing problems. Keep synthetic or empty
data labelled. An invisible render can establish layout; it cannot establish
real input, compositor smoothness or service readiness. Exercise the relevant
controls separately and preserve the user's settings. Motion must respect both
the app preference and macOS Reduce Motion. Do not add frame timers or repeat
entrance animations on background refreshes. Keep keyboard access, header
traits and selected traits on anything rebuilt.

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
