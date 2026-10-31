# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

tinywm is a niri-style scrolling window manager for macOS (Swift 6 package, macOS 14+, menu-bar app). `docs/DEVELOPING.md` is the detailed reference for architecture, config syntax, shortcuts, drag, persistence and cover mode — read it before non-trivial changes and keep it in sync when behavior changes.

## Commands

```sh
swift build
swift test
swift test --filter PersistenceTests            # one suite (swift-testing @Suite / @Test)
swift test --filter "StripTests.someTestName"   # one test
swift run tinywm                                # uses the launching terminal's Accessibility grant
scripts/bundle-tinywm.sh [--install]            # build/tinywm.app, optionally copy to ~/Applications
```

If `swift test` says the `TestingMacros` plugin is not found, add
`-Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing`.
With Command Line Tools only (no Xcode), `no such module 'Testing'` or a missing
`lib_TestingInterop.dylib` needs the framework and library paths too:

```sh
D=/Library/Developer/CommandLineTools/Library/Developer
swift test -Xswiftc -F -Xswiftc $D/Frameworks \
  -Xlinker -rpath -Xlinker $D/Frameworks -Xlinker -rpath -Xlinker $D/usr/lib \
  -Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing
```

Bundle signing: uses `TINYWM_SIGN_IDENTITY`, else a `tinywm self-signed` cert if present (`scripts/make-signing-identity.sh`), else ad hoc (permission grants then reset each rebuild). `TINYWM_HARDENED=1` adds hardened runtime for notarization (`scripts/release.sh`). Bundle ID defaults to `dev.tinywm` (`TINYWM_BUNDLE_ID`).

## Architecture

Three layers, enforced by target dependencies in `Package.swift`:

1. **Pure model** — `WindowCore` (geometry, the `WindowSystem` protocol, clocks, shortcut types, motion constants; no AppKit) and `StripModel` (columns/stacks, workspaces, displays, overview, drop targets, layout restore). No macOS types; tested directly.
2. **`StripEngine`** — owns state, applies model changes to windows through `WindowSystem`, runs motion phases, parses config/rules, recognizes gestures. Testable with a fake `WindowSystem`.
3. **macOS I/O** — `WindowKit` (Accessibility, ScreenCaptureKit, hotkeys, multitouch, release-on-quit) and the `tinywm` executable (AppKit UI and wiring).

Keep macOS types out of layers 1–2; logic belongs there so `StripTests` can cover it.

App target flow: `main.swift` (`TinyWMApp`) shows the menu, opens Preferences → About on first run or without Accessibility, and waits for it; `Runtime` is built once access is granted; `WindowLifecycle` handles window arrivals/moves/focus/removals; `ShortcutCommands` maps shortcuts to actions; `StatusMenu` is the menu bar.

Motion model: on a layout change, pictures (or icon "covers" when Screen Recording is off) of windows animate with springs; real windows are written once shortly after, and pictures fade after they land.

Runtime files: config at `~/.config/tinywm/config` (or `$XDG_CONFIG_HOME`), auto-reloads on save; layout at `~/Library/Application Support/tinywm/layout.json`.

## Conventions

- Tests use swift-testing (`import Testing`, `@Suite`, `@Test`), not XCTest.
- Docs and README use short, plain sentences; match that style when editing them.
