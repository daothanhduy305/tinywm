# Developing tinywm

tinywm is a scrolling window manager for macOS. Windows sit in columns on a strip that slides
under the screen, and workspaces stack vertically, as in niri.

## Targets

| Target | Role |
|---|---|
| `WindowCore` | Geometry types, the `WindowSystem` protocol, clocks, shortcut types and motion constants. No AppKit. |
| `StripModel` | Pure model of columns, stacks, workspaces, displays and the overview. |
| `StripEngine` | Engine that drives the strip: commands, config, rules, gestures and motion phases. |
| `WindowKit` | macOS access: Accessibility, screen capture, hotkeys, trackpad input. |
| `tinywm` | The menu-bar app that wires the above together. |
| `StripTests` | Unit tests for the model and engine. |

## The app target

- `TinyWMApp` in `main.swift` starts the app. It shows the menu and the welcome window, then waits for Accessibility access.
- `Runtime` holds everything that needs that access. The app builds it once, when access is granted.
- `WindowLifecycle` handles what the system reports about windows: arrivals, moves, focus, hides, removals and screen locks.
  A new native tab takes the place of the tab it hides, with the same column and width.
  A focused window that closes stays on the strip for half a second. Ghostty closes a tab's
  window before it shows the next tab, and that tab then takes the column and keeps focus.
- `WindowTracker` asks the window server about each window several times a second. Most apps
  send no destroyed notification on close, and none when they switch tabs. A window gone from
  the window server is removed. A window that stops being shown makes its app's windows be
  read again, so the tab that replaced it is found. A slower sweep of each app's window list catches the rest.
- `ShortcutCommands` turns each shortcut into its action.
- `StatusMenu` shows the menu-bar menu and reports what the user chooses.

## Build and test

```sh
swift build
swift test
```

If `swift test` reports that the plugin for module `TestingMacros` is not found, pass the
path of the command line tools plugins:

```sh
swift test -Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing
```

## Run

```sh
swift run tinywm
```

tinywm needs the Accessibility permission. A binary started with `swift run` uses the grant
of the terminal that launched it, so grant access to that terminal.

Live window pictures need the Screen Recording permission. Without it, windows move at once
while live pictures are on.

## Cover mode

By default ScreenCaptureKit is off: moving windows show as cards with the app's icon and the
window's title. **Show Live Window Pictures (Screen Recording)** in the status menu records the
windows instead. The choice is stored in UserDefaults under `liveWindowPictures` and applies
from the next motion.

- `ScreenCaptureSnapshots.inert` stops every capture and drops every picture. No capture runs,
  and nothing asks for the Screen Recording permission.
- Every overlay shows a cover instead of a picture: a card in the app's icon colour, blended at
  0.72 over the window background colour, with the icon and the window's title in the middle.
  An app without an icon gets a plain card with the title.
- Covers move with the same springs as pictures and fade the same way. Landing does not wait
  for a fresh picture of a resized window, since a cover fits any size.
- The desktop behind the pictures comes from the desktop picture's file.

`WindowCore/Cover.swift` holds the colour blend, the icon's average colour and what a cover
shows, covered by `CoverTests`. `tinywm/Covers.swift` reads icons and titles, and
`WindowPictures` picks a picture or a cover for `PictureMotion`, the overview and the drag.

## Build tinywm.app

```sh
scripts/bundle-tinywm.sh            # builds build/tinywm.app
scripts/bundle-tinywm.sh --install  # also copies it to ~/Applications (quit tinywm first)
```

The bundle runs without a terminal, appears by name in System Settings → Privacy & Security,
and stores its settings under its bundle ID (`dev.tinywm`; override with `TINYWM_BUNDLE_ID`).

macOS ties permission grants to the app's signature. Without a signing identity the script signs
ad hoc, and the signature changes on every build, so macOS may ask for permissions again. To keep
them across rebuilds, create a code-signing certificate once:

1. Open Keychain Access → Certificate Assistant → Create a Certificate.
2. Name it, for example `tinywm dev`. Set Identity Type to Self Signed Root and Certificate
   Type to Code Signing.
3. Build with `TINYWM_SIGN_IDENTITY="tinywm dev" scripts/bundle-tinywm.sh --install`.

## Releases

Releases are free: signed with the self-signed identity from `scripts/make-signing-identity.sh`,
not notarized. Every release must use the same identity, or users lose their Accessibility grant.

Pushing a tag like `v0.2.0` runs `.github/workflows/release.yml`. It tests, builds with
`scripts/release-free.sh`, publishes the GitHub release, and rewrites `Casks/tinywm.rb` in
`daothanhduy305/homebrew-tinywm`. It needs these repository secrets:

- `SIGNING_P12`: `base64 -i tinywm.p12`, the identity exported from Keychain Access.
- `SIGNING_P12_PASSWORD`: the password chosen at export.
- `TAP_TOKEN`: a token that can push to the tap repo.

`scripts/release-free.sh 0.2.0` builds the same zip locally. `scripts/release.sh` is the notarized
route and needs a paid Apple Developer ID.

## tinywm configuration

tinywm reads `~/.config/tinywm/config` (or `$XDG_CONFIG_HOME/tinywm/config`). The file is
optional: without it, or for any line you leave out, the defaults below apply. Choose **Edit
Config…** in the status menu to create it from a commented template and open it. The file
reloads by itself when you save it, or on **Reload Config**. When a newer tinywm brings a setting
or binding the file does not mention, at launch or on **Edit Config…** it adds it at the end,
commented, showing the default. A line that cannot be read is
skipped, and **Config Errors** in the menu lists it with its line number.

```
# comments and blank lines are ignored
meta = right-command            # or control-option
gap = 8
default-width = 0.333
width-presets = 0.333, 0.5, 0.667
focus-border = on
swipe = on          # trackpad swipes on or off
swipe-fingers = 3   # 3 or 4
restore-layout = on # save the layout and restore it at start
peek-cover = off                # on: a column beside another display hides behind a card showing its picture, not narrowed
center-focus = off              # on: scrolling to a window centres it, unless that would show space past the strip's ends; a swipe settles on a centred column
overview-as-mission-control = off # on: ⌘Tab opens the overview instead of the macOS app switcher
overview-floating = vertical      # vertical, horizontal or off: the shelf of floating windows in the overview
focus-crosses-displays = off    # on: focus and move continue past the strip's ends onto the next display
bind focus-left = n             # the meta key is implied
bind move-left = shift+n
unbind focus-left-arrow         # removes a default binding
```

- Keys: letters, digits, `left right up down pageup pagedown esc tab return space`, and
  `= - [ ] , . / ; ' \ `` ` `` (also spelled `equal minus leftbracket rightbracket comma period slash
  semicolon quote backslash grave`).
- Extra modifiers: `shift`, `option` and `control`, joined with `+` (`shift+option+left`,
  `control+h`). With `meta = control-option` the extra modifier is `command` instead of
  `option`, and `control` is not available, since ⌃ is already part of the meta key.
- If two lines put actions on one key, the later line wins and the clash is reported. A line
  that takes the key of a shipped default unbinds that default without a report.
- Action names are listed in the table below and in the template.

### Your own shortcuts

`run` ties a key to a shell command, and `send` ties it to another key combination. The key
follows the binding rules above, so it can take a default's key.

```
run shift+return = open -na Ghostty   # /bin/sh -c, with Homebrew on the PATH
send d = cmd+space                    # press ⌘Space, for a launcher
```

- `send` modifiers are `cmd`, `shift`, `option` and `ctrl`. The right ⌘ that is still held is
  left out, so the app sees exactly the combination written.
- tinywm marks the keys it sends, so its own event tap lets them through.
- A `#` starts a comment, also inside a command.

### Rules

Rules say how tinywm treats particular apps or windows. Each line names an app by bundle ID or
app name (case-insensitive, exact match), optionally followed by a colon and a window title
substring in quotes. Several patterns can share a line, separated by commas.

Patterns can be looser than an exact name:

| Pattern | Matches |
| --- | --- |
| `Slack` | The app named Slack, or the bundle ID `slack`, ignoring case. |
| `com.jetbrains.*` | Any bundle ID or name that fits, with `*` standing for any run of characters. |
| `/^micro/` | A regular expression, found anywhere in the bundle ID or the name, ignoring case. |
| `Brave Browser: "/meet\.google/"` | A regular expression for the window title. A plain title is a substring. |

A comma inside slashes or quotes does not split the line.

| Kind | Effect |
| --- | --- |
| `float` | Matching windows open floating, off the strip. Meta + T tiles one. |
| `ignore` | The app is not managed at all; its windows return to where they were. Takes no title. |
| `no-focus` | New windows join without taking focus or scrolling the strip. If the app takes focus on its own, focus goes back to the window that had it. |
| `open-on` | New windows open on a display, a workspace, or both, as in niri's `open-on-output` and `open-on-workspace`. |

```
float    = com.apple.calculator, System Settings
float    = Brave Browser: "Picture in Picture"
ignore   = com.apple.finder
no-focus = Slack, com.spotify.client
open-on  = /^microcube/ -> workspace 2
open-on  = Slack, Pulse -> display LS37D80xU workspace 1
```

An `open-on` line has the patterns, then `->`, then `display <name>`, `workspace <n>`, or both.

- `display <name>` matches the start of the display's name, ignoring case, such as `Built-in`.
  If no connected display matches, the window opens where it would without the rule.
- `workspace <n>` counts from 1 at the top workspace. A number past the last workspace means a
  new workspace below it, since empty workspaces between others close.
- The rule applies to windows that open while tinywm runs, not to windows already open.
- The window does not switch your view. It takes focus only when it opens on the display and
  workspace you are on. If the app brings its window to the front itself, tinywm follows it.
- When several `open-on` lines match a window, the first one wins.

- Each kind may appear on any number of lines; the effective set is the union of all of them.
- Rules win over tinywm's own guess about which windows can be tiled.
- Rules apply as soon as the file reloads. Newly ignored apps are released, apps no longer
  ignored are tiled, and a float rule also floats matching windows that are already tiled.
- A `no-focus` app that comes to the front without a click or key press in the last 0.4
  seconds is treated as acting on its own. Clicks, Cmd-Tab and tinywm's own focus keys still work.

## tinywm shortcuts

The meta key is right ⌘ by default; set `meta = control-option` for ⌃⌥. Vim letters and arrow
keys both work out of the box.

| Shortcut | Action | Config name |
| --- | --- | --- |
| Meta + H / J / K / L | Focus left, down, up, right | `focus-left` `focus-down` `focus-up` `focus-right` |
| Meta + arrows | The same | `focus-left-arrow` and so on |
| Meta + ⇧ + H / J / K / L, or arrows | Move the column or window | `move-left` `move-left-arrow` and so on |
| Meta + U / I | Workspace below / above | `workspace-down` `workspace-up` |
| Meta + ⇧ + U / I | Move the window to the workspace below / above, keeping its width | `workspace-move-down` `workspace-move-up` |
| Meta + ⌥ + ↓ / ↑, or Page Down / Page Up | Workspace below / above | `workspace-down-arrow`, `workspace-down-page` and so on |
| Meta + ⇧ + ⌥ + ↓ / ↑, or ⇧ + Page Down / Page Up | Move the window to that workspace | `workspace-move-down-arrow`, `workspace-move-down-page` and so on |
| Meta + 1 to 9 | Focus a column | `focus-column-1` to `focus-column-9` |
| Meta + R / E | Cycle the column width wider / narrower | `width-cycle` `width-cycle-back` |
| Meta + F | Full width | `width-full` |
| Meta + ⇧ + T | Half width | `width-half` |
| Meta + C | Center the column | `center` |
| Meta + = / - | Wider / narrower | `wider` `narrower` |
| Meta + ] / [ | Stack into the right / left column | `stack-right` `stack-left` |
| Meta + ⇧ + ] | Pop out of the stack | `pop-out` |
| Meta + T | Float or tile the window | `float` |
| Meta + V | Focus the floating windows one after another, then the strip again | `float-focus` |
| Meta + . / , | Focus the next / previous display | `display-next` `display-previous` |
| Meta + ⇧ + . / , | Move the window to the next / previous display | `display-move-next` `display-move-previous` |
| Meta + W / A / S / D | Focus the display above, left, below or right | `display-up` `display-left` `display-down` `display-right` |
| Meta + ⇧ + W / A / S / D | Move the window to that display | `display-move-up` and so on |
| Meta + Esc | Overview | `overview` |
| Meta + Q | Close the window | `close-window` |
| Meta + left drag | Move the window with the mouse | none |

The overview opens on every display with windows, each with its focused window highlighted. It first
waits up to 150 ms for new pictures of the windows on screen, so they don't jump from an old
picture; pictures that arrive later fade in. In the active display's overview, the arrows and the
focus keys held with the meta key move the selection, Tab and ⇧Tab step through windows, Return or
Meta + Esc confirms, and Esc cancels. A search bar at the top of every display holds one shared
query; the bar on the display with the keys is bright and takes typing as soon as the overview
opens, so plain letters type rather than move. Clicking another display's bar moves the keys there.
The windows whose app name and title don't contain every typed word fade, and the selection jumps to
the first match. Tab and the arrows then move among matches only, and the keys cross only to a
display with a match. The bar edits like any text field, with a caret, ⌥⌫, ⌘⌫, ⌥←/→ and paste, while
the plain arrows still move the selection. Esc clears the search before it cancels. The search
covers every display, and when the keys' display has no match, the keys move to one that does. At an
edge, the arrow and focus keys move on to the display lying that way, landing on its window at the
edge they came in by. The display the keys steer has the bright ring; the others' rings are faint.
When the active display has no windows, the next display's overview takes the keys. Pointing at a
window on any display highlights it, and a click focuses it and makes its display the active one.
Drag a tiled window picture to move it to a column or workspace on any display. The other pictures
move aside to open a gap. Empty rows above and below let you create a workspace. The picture shrinks
while dragged and grows into its new place. When the pointer leaves a display,
its highlight goes back to its focused window, or to the one the keys chose. Each picture casts a
soft shadow and has a faint edge, so light windows stand out from the desktop. `overview-floating`
puts floating windows on a shelf, a dock-like plate that stays put while the rows pan: `vertical`
(the default) stacks them down the right side as pictures of the same width, `horizontal` lines them
up along the bottom as pictures of the same height, and `off` shows them at their real place, above
the strip. Fullscreen windows sit on the shelf too, after the floating ones; picking one switches to
its Space. The arrow keys move right into a vertical shelf and left out of it, or down into a
horizontal one. Each picture has its app name and window title under it. Right-click a picture and
choose Rename…, or press Meta + R, to name the selected window. The `width-cycle` key renames too,
if it is bound elsewhere. Return saves, Esc cancels, and an empty name brings the title back. The
label then reads `Name (App)`, the minimap shows the name, and the search matches the name, the app
and the title. Picking a window does not show the minimap. With `overview-as-mission-control = on`,
⌘Tab with either ⌘ key opens the overview like Meta + Esc, and the macOS app switcher no longer
shows; ⌘Tab again confirms.

An app with windows on several displays, such as a browser, may make another of its windows key
right after tinywm focuses one. Within a second and with no click or key press since, tinywm
focuses the window it asked for once more, so focus stays on the display you went to.
`StripEngine/FocusRequest.swift` decides this.

## Dragging windows

Hold the meta key and press the left button anywhere on a managed window. The click does not
reach the app. Once the pointer moves 5 points, the drag begins and the pointer turns into a
closed hand.

- The window's picture follows the pointer at full size, with a shadow. The display shows
  pictures, so no real window moves during the drag. Every screen dims, except for a hole
  around the dragged picture.
- A blurred grey slot shows exactly where the window will land and how big it will be. Each
  half of a column inserts a new column on its side, and so do the gaps and the strip's ends.
  Dropping into a stack is off for now.
- When a target holds for 0.15 seconds, the other pictures move aside as if the window were
  already there, so the slot sits in a real gap. The targets then follow the pictures on
  screen.
- With the pointer within 40 points of a display's left or right edge, the strip scrolls that
  way, faster closer to the edge, up to 1200 points a second. It stops at the strip's ends.
- A target stays until the pointer is 16 points past its zone, so it does not flicker.
- Any tiled display can take the window. Its own slot puts it back.
- On release the real windows take the frames their pictures already show, and the pictures
  fade. Released where no slot shows, or with Esc, the window goes back.
- A floating window's picture follows the pointer, and the window keeps its new place. Let go
  over another tiled display, it floats there. The same goes for one moved by its title bar.
- A press without a drag focuses the window, as the click would have.

The target logic lives in `StripModel/DropTarget.swift`. `dropHint` maps the pointer to a
target, and `DropTracker` adds the hysteresis. `dropLayout` gives the strip as it would be after
the drop, `baseTarget` turns a target found on that layout back into the strip's own indices,
and `edgeScrollSpeed` gives the scroll speed near an edge. `Strip.place` does the move. The
engine shows the layout with `previewDrop`, scrolls it with `dragScroll` and writes it with
`endDrag`. `StripEngine/WindowDrag.swift` runs the drag across displays. `MetaKey` reads the
mouse through its event tap, and `DragOverlay` draws the picture, the slot and the dim.
Shortcuts wait while a drag is under way. The stacking code stays in place behind
`DropStyle.stacking`, and its tests are disabled until it comes back.

## Architecture

The code has three layers.

1. The model modules (`WindowCore`, `StripModel`) are pure. They hold no macOS types and are
   tested directly.
2. `StripEngine` owns the state, applies model changes to windows through the `WindowSystem`
   protocol, and runs the motion phases.
3. `WindowKit` and `tinywm` talk to macOS. They read and write windows through Accessibility,
   take window pictures with ScreenCaptureKit, and read gestures.

When a layout changes, pictures of the windows glide to their new places. The real windows
are written once, a moment after the pictures go up. The pictures fade after the windows land.
A window moved by a command (move, stack, pop out, to another workspace or display) shrinks a little, slides over the other
pictures to its new place while they slide too, then grows back. A full-width one that keeps its place shrinks and
grows where it is while its neighbour passes behind it.

macOS cannot hide a single window, so columns off the screen wait just past its edge with a
thin sliver showing. A column partly on screen would spill onto a display next to it, so it is
narrowed to the part on screen. With less than 100 points showing, it hides instead.
`stripFrames` places them. A narrowed window that refuses its width does not resize its column.
With `peek-cover = on` the column hides and a card stands in for its part on screen. The card
shows the window's picture as it would sit on the strip, so a column cut at the left edge
shows its right part. The picture is retaken every second while the card shows. Without a
picture, as with live pictures off, the card is dark with the app's icon and the window's
title. Clicking the card focuses the window.
`blockedPeeks` gives the cards' frames, `StripEngine.peekStrip` the windows' frames on the
strip, and `PeekCards` draws them.
During motion a window with a picture needs no card: its picture moves to its place on the
strip and the overlay cuts it at the screen edge. For a dark card, the overlay draws the same
card over the pictures and under the focus ring, so
the ring passes over it. The window's picture moves to and from the card's spot. The card
springs with it over the picture's part on screen, fading in as the window slides behind it and
out as it comes back. The card's panel shows again under the pictures as they fade.

## Trackpad swipes

A sideways swipe drags the strip under your fingers and settles on the nearest column; an up or
down swipe changes workspace. When the main thread falls behind, contact frames waiting for it
are merged, so the strip jumps to the fingers instead of replaying old frames. While that many fingers are down, an event tap keeps the scroll
and gesture events macOS makes from them away from apps, so the app under the pointer does not
scroll or go back. Scrolls stay blocked until one begins in a new touch, so the scroll macOS
restarts as fingers lift, and its momentum, are blocked too. `SwipeShield` decides what to drop;
`ScrollTap` is the tap. macOS's own gestures run before any tap and cannot be stopped. If macOS
also uses that many fingers (switching Spaces, Mission Control or three-finger drag), both react
to every swipe, and the menu shows a warning that opens Trackpad settings. Turn the macOS
gesture off or move it to the other finger count, or set `swipe-fingers` to the count macOS does not use.

## Layout persistence

tinywm writes `~/Library/Application Support/tinywm/layout.json` about a second after the layout
changes and on quit. The file maps each display UUID to its workspaces: strips with columns
(width, stacked windows, focused window), scroll, floating windows and the active workspace.
Window IDs like `w3` change every run, so each window is stored as a descriptor: CGWindowID,
bundle ID, title, pid and the name given in the overview, if any. A name comes back with the window
its slot is matched to. After tinywm restarts the CGWindowID always finds it. After the app
relaunches the match goes by title, so a name can be lost, or land on a similar window of the same app.

At startup `LayoutPersistence` holds the windows the first scan finds. After a short settle
time, `SavedLayout.plan` matches them to saved slots, each slot used once: first CGWindowID with
the same pid and app, then bundle ID with the exact title, then bundle ID with a similar title. Last, an app's
windows left over take its slots left over, in saved order, so a relaunched browser whose titles
all changed still gets its places.
Each display's workspaces are rebuilt and normalised, written once without motion, and windows
that no slot claimed join the usual way. Displays that are unplugged or switched off keep their
saved layout in the file. With `restore-layout = off` the file is neither read nor written.

Each display setup keeps its own layout. A setup is the set of attached displays, by UUID; their
arrangement and resolution do not count, and turning tiling off for one is not a new setup. When
the setup changes, `StripDisplays.update` keeps the layout of the setup being left. If the new
setup was seen before, every display gets that setup's layout back, without the windows that closed
since. Windows the layout does not name stay on their display, or join the first display if theirs
went away. A window keeps its place in the other setups while it is fullscreen, on a display
that is not tiled, or swapped for another tab; only closing it drops it. In a setup not seen before, windows of a display
that went away move to the first display and go back when it returns. The file keeps these layouts
under `setups`, keyed by the sorted UUIDs joined with commas. At startup the current setup's layout
is restored, else each display's own; the other setups are matched against the same windows so a
later switch finds them.
The matching and rebuilding live in `StripModel/LayoutRestore.swift` and are covered by
`PersistenceTests`.

When a tiled window closes, its column width is kept for its app in the user defaults. The
app's next window opens at that width. Apps tinywm has not seen yet use `default-width`.

A column first asks its window for its share of the screen. If the window takes another width,
because its app has a minimum or maximum width, the column takes the window's width instead
(`refused` in `StripEngine`, after a second read 0.3 s later). Nothing is saved per app; the fit
lasts until the column's share or the screen changes, and then the window is asked again.
Windows off the screen or trimmed beside another display never change their column's width.
