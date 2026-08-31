# Clipstack

A tiny floating clipboard manager for macOS — a pill that sits at a screen edge,
expands to show up to 10 saved snippets, and copies any of them back out with one click.

- Drag it by the ⠿ grip on its left edge. It hops between seven fixed spots —
  the four corners, both side middles, and bottom centre (top centre belongs to
  the menu bar) — and never rests anywhere in between
- Sits flush in the edge, squaring off whichever corners land on one
- Click the pill to open it, ✕ to minimize back down
- ⌘⇧⌃V (or the on-screen + button) saves the current clipboard
- Skips concealed pasteboard content (password managers mark their entries this way)
- No dependencies — AppKit only

## Build & run

```bash
./build.sh          # runs Store.swift's self-check, then builds Clipstack.app
open Clipstack.app
```

To install it under `/Applications` instead of running it from this folder:

```bash
cp -R Clipstack.app /Applications/
open /Applications/Clipstack.app
```

Right-click the pill to quit.
