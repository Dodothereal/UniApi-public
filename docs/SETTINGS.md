# Setup and navigation settings

UniApi stores navigation preferences with macOS application preferences. They are local to the current user and are separate from the provider configuration.

## Guided setup

A fresh, unconfigured writable installation offers a four-step welcome: introduction, appearance, starting point and finish. Existing preferences or provider configuration keep it out of the way for existing users. `Settings > Show setup` reopens the same guide without resetting the workspace.

If the app exits before completing or skipping setup, the guide opens again on the next launch with its appearance choices retained. A separate started marker distinguishes those choices and the new window frame from an older installation's settings.

The guide uses a compact four-step header rather than a second sidebar. Each screen focuses on one task: introduction, appearance, first page and a short review. Appearance controls preview System/Light/Dark; page choices use an equal-sized two-column grid. Navigation stays in a fixed footer with 40-point controls, a single Skip setup action stays in the header, and each step begins at the top. Short windows scroll the content while keeping navigation available. The last action names the page it will open.

Theme, spacing and motion choices apply immediately. Transitions last 200 ms and respect both the app's reduced-motion preference and macOS Reduce Motion. The guide has no animation timer or frame callback. Back retains your choices, and Skip leaves you in the workspace. Return advances, Escape skips, and Command-Left goes back. Finishing can open Home, Switcher, Statistics or Transcribe; this is a one-time navigation choice, separate from the launch-page setting.

The guide does not sign in, connect providers, download a model, start inference or change routing or hardware controls. Optional integrations remain explicit actions on their own pages.

## Colors and themes

Choose Light, Dark or Auto for the app appearance. Under Customize colors,
Original, Ocean, Forest and Plum presets apply to the selected Light or Dark
variant independently. The page clearly distinguishes the app appearance from
the variant being edited; a preview shows changes to an inactive variant.

The first controls cover Accent, Link / highlight, Background, Surface and Main
text. Advanced colors covers secondary and muted text, sidebar, selection,
popover, field backgrounds, input borders, borders and status colors. Color
pickers and six-digit hex fields edit the same preference. Hex values apply on
Return or leaving the field; invalid values are rejected. Custom overrides are opaque; Original may use translucent borders and fields.
Reset restores those original effects. Changes save immediately. Contrast checks explain foreground/background combinations; they
do not prevent choosing your own colors.

Reset restores one variant. Undo palette restores the previous preset state
while keeping later individual edits and the other variant. Theme updates use
observable tokens, without recreating pages or adding animation timers. Stable
data-series colors and a few translucent effects retain their original roles.
The bounded local preference document uses `uniapi-custom-theme-v1`.

## Launch behavior

`Launch page` chooses the page used when UniApi opens. Choosing a launch page turns off `Restore last visited page`, so that choice applies on the next launch. Restoration is enabled by default and preserves the existing behavior: the last selected page wins. When restoration is disabled, or the stored page is no longer an installed destination, UniApi opens the configured launch page. If that value is also unavailable, it opens Home when installed, otherwise the first installed page in the app's declared page order. If no known pages are installed, it falls back to Home.

Read-only preview hosts retain their explicit installed-page selection before these preferences are considered.

When the shell knows that Battery is unsupported, it omits Battery from the launch-page choices. If the launch-page preference is used, a previously saved Battery choice falls back to Home on that Mac; a valid restored last page still takes precedence. The saved choice is preserved in case support becomes available.

## Sidebar

Open `Edit sidebar` for a preview of the navigation layout, including hidden pages. Drag a section handle onto another section heading, or a page handle onto a page in the same section. When moving up, the item is placed before the target; when moving down, it is placed after it. An insertion line marks the position; invalid targets are marked and cannot be dropped. Each row also has a Move menu for keyboard access and a visibility switch. Home stays at the top, while Jobs and Settings stay at the bottom; these anchored pages cannot be moved or hidden. An unavailable Battery page retains its saved preference.

Hidden pages remain valid destinations, including for launch or restoration. Some can also be reached from Home; any hidden page can be restored with its visibility control. Sections with no visible pages are omitted. Hiding a page does not change the saved page and section order.

`Show badges` is enabled by default. Turning it off hides the Jobs, Code and Arena counts and the battery percentage in the sidebar while leaving the destinations and their content available. `Restore sidebar layout defaults` resets width, page and section order, page visibility and badges. It does not change whether the sidebar is open.

The backing preference keys are `uniapi-start-page`, `uniapi-restore-last-page`, `uniapi-sidebar-order`, `uniapi-sidebar-hidden` and `uniapi-sidebar-badges`. Unrecognized launch and hidden-page entries are ignored. Choose a launch page or turn a sidebar page back on in Settings to replace them.

## Optional Telegram delivery

Settings shows the saved delivery state: Not configured, Off, or Ready. Ready means the saved configuration is enabled and passes local validation; it does not prove delivery. Configure expands the form: create a bot with BotFather, send it a message, and choose Find my chats to look up and select a destination. This explicit lookup reads recent bot updates without sending a message, acknowledging updates, or changing webhook settings. An active webhook or another client consuming updates can prevent lookup; a manual chat ID field remains available. The token is masked in Settings until deliberately revealed.

Changes are drafts until Save, with an unsaved-changes notice. Closing the form keeps the draft while Settings stays open; leaving Settings can discard it. Saving uses the app-owned private configuration and validates enabled credentials. Disconnect asks for confirmation before disabling delivery and clearing the saved token and chat ID. Discard changes restores the last saved values. A failed read offers Retry loading. No credentials are imported from other apps. Lookup happens only when requested; configuring or saving does not send a message or run a network test. A read-only session cannot save changes.

Application diagnostics and storage actions are available under the Diagnostics and storage disclosure.

## Performance recording

Under Diagnostics and storage, Start recording saves page timing and process
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
