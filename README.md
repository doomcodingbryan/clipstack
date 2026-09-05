# Clipstack

A tiny floating snippet shelf for macOS — a pill that sits at a screen edge,
expands to show up to 10 snippets you've typed in, and copies any of them back
out with one click.

- Drag it by the ⠿ grip, or by the little arrow pill — the only handle left once hidden. It follows the cursor, then falls to the
  nearest of seven spots when you let go — the four corners, both side middles, and
  bottom centre (top centre belongs to the menu bar)
- Sits flush in the edge, squaring off whichever corners land on one
- Click the pill to open it, ✕ to minimize back down
- Clips are written in, not captured: + or ⌘⇧⌃V opens a text box, ⏎ saves
- Click any clip to copy it out; each shows two wrapped lines of preview
- ⌘⇧⌃1–9 (and ⌘⇧⌃0 for the tenth) copy a clip from anywhere, without looking
- Double-click a clip to rewrite it in place, keeping its slot and shortcut
- Drag a clip up or down to reorder it — that's how it gets a different shortcut
- Pin a clip and the 10-clip cap will never drop it; evictions are announced, not silent
- Right-click a clip for Edit / Pin / Delete; right-click anywhere for Clear All and Quit
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
