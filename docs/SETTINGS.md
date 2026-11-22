# Setup and navigation settings

UniApi stores navigation preferences with macOS application preferences. They are local to the current user and are separate from the provider configuration.

## The Settings page

Settings is one column. It opens with four readings about the running app:
its state (Ready, Preparing, Read-only or Failed), the installed version with
the update state beneath it, uptime and active jobs. Reload is in the header; a
verified update adds **Update to ...** beside it as the page's one primary
action.

Under the readings, a one-line index names the sections in page order:
Appearance, Sidebar, Launch, Telegram, Updates and Diagnostics. Choosing a name
scrolls to that section. The order follows how often each is changed. Larger
editors (colors, sidebar pages, Telegram and the diagnostics report) stay
closed behind a button in their row until opened.

Elsewhere in the app, Command-B switches the sidebar between its full width
and an icon rail, Command-K opens the command palette, and Command-1 to
Command-9 open the first nine visible sidebar pages in their current order.

## Guided setup

A fresh, unconfigured writable installation offers a single-screen welcome that asks what you would like to do. Choose one of four tasks, optionally a look and a spacing, then open its page directly. Each task line names its destination page at the right edge. A selector dial beside the list restates the choice when the window has room. Existing preferences or provider configuration keep the guide out of the way for existing users. `Settings > Launch > Show setup` reopens the same guide without resetting the workspace.

If the app exits before completing or skipping setup, the guide opens again on the next launch with its appearance choices retained. A separate started marker distinguishes those choices and the new window frame from an older installation's settings.

The guide offers Home, Switcher, Statistics and Transcribe as starting pages,
without connecting or downloading anything. Look and spacing share this same
screen, pinned above the footer. Wider viewports show the selector dial;
smaller ones show the task list alone, and very short ones drop the one-line
descriptions rather than scroll. The Open action stays in a fixed footer at 40
points high and names the selected page. Skip for now stays in the header.
Short windows can scroll content while keeping the primary action available.
The heading requests accessibility focus on entry.

Look and spacing choices apply immediately and remain saved when you finish
or skip. Spacing changes the guide's own line height as well as the
destination pages. Motion keeps the existing preference and always respects
macOS Reduce Motion; its controls remain in Settings. Hover/press feedback has
no animation timer or frame callback. Return opens the selected page and Escape
skips; there are no extra steps or Back action. The selected starting page is
a one-time navigation choice, separate from the launch-page setting.

The guide does not sign in, connect providers, download a model, start inference or change routing or hardware controls. Optional integrations remain explicit actions on their own pages.

## Appearance

`Look` chooses Graphite (dark), Paper (light) or Auto, which follows macOS.
`Spacing` chooses Compact, Default or Spacious, and `Motion` chooses System or
Reduced. The stored values are unchanged: `uniapi-theme` holds `dark`, `light`
or `auto`, `uniapi-density` holds `compact`, `standard` or `spacious`, and
`uniapi-motion` holds `system` or `reduced`.

## Colors and themes

The `Colors` row states the palette of the look on screen. `Customize` opens
the editor beneath it. Choose which look to edit, Graphite or Paper; the Meter,
Ocean, Forest and Plum palettes apply to that look independently. Meter is the
default palette. When the edited look is not the one on screen, a line says so.

A ruled strip shows the edited look as it stands: every color as a swatch in
five groups (Ground, Ink, Signal, Rules and Status), with a text sample set in
the look's own ink on its own background. It updates as colors change.

The first rows cover Accent, Link / highlight, Background, Surface and Main
text. `Every color` adds secondary and muted text, sidebar, selection, popover,
field backgrounds, input borders, borders and status colors. Each row has a
swatch that opens the macOS color panel and a six-digit hex field; both edit
the same preference. Hex values apply on Return or leaving the field; invalid
values are rejected. Custom overrides are opaque; Meter may use translucent
rules and fields. Reset restores those original effects. Changes save
immediately. `Contrast checks` measures the foreground/background pairs on a
scale whose centre mark is 4.5:1 and counts the pairs below it; the checks do
not prevent choosing your own colors.

Reset restores one look. Undo palette restores the previous palette state
while keeping later individual edits and the other look. Theme updates use
observable tokens, without recreating pages or adding animation timers. Stable
data-series colors and a few translucent effects retain their original roles.
The bounded local preference document uses `uniapi-custom-theme-v1`; it still
stores the looks as `dark` and `light` and the default palette as `original`.

## Sidebar

`Layout` chooses Full or Icon rail, the same switch as Command-B. `Width` sets
the full sidebar between 180 and 320 points. `Readings` is enabled by default.
Turning it off hides the Jobs, Code and Arena counts and the battery percentage
in the sidebar while leaving the destinations and their content available.

The `Pages` row states how many pages are shown and hidden. `Edit` opens the
page ledger: every section and page in sidebar order, including hidden pages.
Drag a section handle onto another section heading, or a page handle onto a
page in the same section. When moving up, the item is placed before the target;
when moving down, it is placed after it. An insertion line marks the position;
invalid targets are marked and cannot be dropped. Each row also has up and down
buttons for keyboard access and a visibility switch. Home stays at the top,
while Jobs and Settings stay at the bottom; these fixed pages cannot be moved
or hidden. An unavailable Battery page retains its saved preference.

Hidden pages remain valid destinations, including for launch or restoration.
They are left out of the command palette and the Command-number shortcuts.
Some can also be reached from Home; any hidden page can be restored with its
visibility switch. Sections with no visible pages are
omitted. Hiding a page does not change the saved page and section order.

`Restore defaults` in the section heading resets width, page and section
order, page visibility and readings. It does not change whether the sidebar is
full or an icon rail.

## Launch behavior

`On launch, open` chooses Last visited or Launch page. `Launch page` chooses the page used when UniApi opens. Choosing a launch page switches to Launch page, so that choice applies on the next launch. Last visited is the default and preserves the existing behavior: the last selected page wins. With Launch page selected, or when the stored page is no longer an installed destination, UniApi opens the configured launch page. If that value is also unavailable, it opens Home when installed, otherwise the first installed page in the app's declared page order. If no known pages are installed, it falls back to Home.

Read-only preview hosts retain their explicit installed-page selection before these preferences are considered.

When the shell knows that Battery is unsupported, it omits Battery from the launch-page choices. If the launch-page preference is used, a previously saved Battery choice falls back to Home on that Mac; a valid restored last page still takes precedence. The saved choice is preserved in case support becomes available.

`Show setup` in this section reopens the welcome guide.

The backing preference keys are `uniapi-start-page`, `uniapi-restore-last-page`, `uniapi-sidebar`, `uniapi-sidebar-width`, `uniapi-sidebar-order`, `uniapi-sidebar-hidden` and `uniapi-sidebar-badges`. Unrecognized launch and hidden-page entries are ignored. Choose a launch page or turn a sidebar page back on in Settings to replace them.

## Optional Telegram delivery

The Telegram section shows the saved delivery state: Not configured, Off, or Ready. Ready means the saved configuration is enabled and passes local validation; it does not prove delivery. Configure opens four numbered steps: paste the token of a bot created with BotFather, send the bot a message, choose Find my chats to look up and select a destination, then enable delivery. This explicit lookup reads recent bot updates without sending a message, acknowledging updates, or changing webhook settings. An active webhook or another client consuming updates can prevent lookup; a manual chat ID field remains available. The token is masked in Settings until deliberately revealed.

Changes are drafts until Save, with an unsaved-changes notice. Closing the form keeps the draft while Settings stays open; leaving Settings can discard it. Saving uses the app-owned private configuration and validates enabled credentials. Disconnect asks for confirmation before disabling delivery and clearing the saved token and chat ID. Discard changes restores the last saved values. A failed read offers Retry loading. No credentials are imported from other apps. Lookup happens only when requested; configuring or saving does not send a message or run a network test. A read-only session cannot save changes.

## Software update

`Software update` in the Updates section shows the installed version and the newest GitHub release. `Check for updates` looks immediately; a download shows its progress on a ticked scale, and a newer release is downloaded and verified before `Update to ...` appears in that row, in the Settings header and at the bottom of the sidebar. Installing waits for jobs and coding turns to finish, closes the window briefly and reopens the updated app with providers, data and settings unchanged. `Check for updates automatically` is on by default and only finds and downloads releases; it never installs one. See [updating from inside the app](INSTALL.md#updating-from-inside-the-app).

## Notices

Short confirmations and errors appear as a stack of ruled slips at the top
right of the window. Each carries a tick in its status color and the word
Done, Notice or Error before the message, is announced to assistive
technology, and leaves on its own or when dismissed.

## Diagnostics

The Diagnostics section holds performance recording, the data folder, logs and
provider configuration locations with a reveal button each, and the
diagnostics report, which can be shown, copied or saved as text.

## Performance recording

In the Diagnostics section, Start recording saves page timing and process
resource metadata locally for up to five minutes. Use the normal sidebar to
navigate from Speed to Statistics, then use the Statistics header Reload action.
Stop recording closes the file; Show recording reveals it in Finder only when
you ask. Starting a recording does not reopen pages or clear retained data.

Recording is off by default and cannot be started in a read-only session. Each
explicit recording creates a fresh owner-only file under
`UNIAPI_DATA/logs/ui-recordings/`; no path is chosen by a request or webpage.
The recording stops at five minutes, 4 MiB or 4,096 records. An unsafe or changed
output file or a write failure stops it without affecting the page operation.
Files remain local until you choose to share or remove them.

Rows contain a session ID, page name, navigation/refresh/rebuild trigger, phase,
elapsed time, process CPU counters, lifetime peak resident memory and a recording
timestamp. Prompts, model names, provider keys, paths and page contents are not
recorded. Session IDs and page/timing history can still be private. Manual
recordings measure the currently running app; they do not measure cold startup.
View commits and drawing callbacks do not establish GPU presentation or frame
rate, and process CPU or lifetime peak memory are not isolated per-page costs.
