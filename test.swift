import Foundation
import CoreGraphics

@main
struct StoreTests {
    static func check(_ ok: Bool, _ what: String) {
        if !ok { print("FAIL: \(what)"); exit(1) }
    }

    static func main() {
        let suite = "clipstack.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = Store(defaults: defaults)

        check(store.add("  hello  ") == .saved, "non-blank saves")
        check(store.items == ["hello"], "trims whitespace")

        check(store.add("   ") == .blank, "blank is rejected")
        check(store.items == ["hello"], "blank leaves list alone")

        store.add("world")
        check(store.add("hello") == .movedUp, "re-save reports the move")
        check(store.items == ["hello", "world"], "and moves to top without duplicating")

        store.move(from: 0, to: 1)
        check(store.items == ["world", "hello"], "move reorders")
        store.move(from: 5, to: 0)
        check(store.items == ["world", "hello"], "out-of-range move is a no-op")

        for i in 0..<20 { store.add("item\(i)") }
        check(store.items.count == maxItems, "capped at \(maxItems), got \(store.items.count)")
        check(store.items.first == "item19", "newest first")

        // The whole point: eviction is named, never silent.
        let dropped = store.add("fresh")
        check(dropped == .evicted("item10"), "says what it dropped, got \(dropped)")

        store.remove(0)
        store.remove(99)
        check(store.items.count == maxItems - 1, "out-of-range remove is a no-op")

        // Pins survive the cap; the oldest *unpinned* clip goes instead.
        store.clear()
        check(store.items.isEmpty, "clear empties")
        for i in 0..<maxItems { store.add("p\(i)") }
        store.togglePin(maxItems - 1)                       // p0, the oldest
        check(store.isPinned("p0"), "pinned the oldest")
        let spared = store.add("newcomer")
        check(spared == .evicted("p1"), "drops the oldest unpinned, got \(spared)")
        check(store.items.contains("p0"), "the pinned one survived")

        // Nothing droppable at all.
        store.clear()
        for i in 0..<maxItems { store.add("q\(i)") }
        for i in 0..<maxItems { store.togglePin(i) }
        check(store.add("nope") == .full, "all pinned reports full")
        check(store.items.count == maxItems, "and saved nothing")
        check(!store.items.contains("nope"), "really nothing")

        // survives a reload from the same defaults
        store.clear()
        store.add("keep me")
        store.togglePin(0)
        let reloaded = Store(defaults: defaults)
        check(reloaded.items == ["keep me"], "items persist across instances")
        check(reloaded.isPinned("keep me"), "pins persist too")

        // Editing rewrites in place — same slot, same shortcut, pin carried over.
        store.clear()
        store.add("alpha"); store.add("beta"); store.add("gamma")   // gamma, beta, alpha
        store.togglePin(1)                                          // beta
        check(store.replace("beta", with: "BETA") == .saved, "edit saves")
        check(store.items == ["gamma", "BETA", "alpha"], "rewrites in place, got \(store.items)")
        check(store.isPinned("BETA") && !store.isPinned("beta"), "the pin follows the text")
        check(store.replace("gamma", with: "   ") == .blank, "blank edit is a no-op")
        check(store.items == ["gamma", "BETA", "alpha"], "and changed nothing")
        check(store.replace("nope", with: "x") == .blank, "editing a vanished clip is a no-op")
        check(store.replace("alpha", with: "gamma") == .saved, "rename onto a twin")
        check(store.items == ["BETA", "gamma"], "absorbs it, no duplicate, got \(store.items)")

        // Anchor geometry — the seven parking spots
        let screen = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let pill = NSSize(width: 52, height: 48)

        check(Anchor.allCases.count == 7, "seven spots, got \(Anchor.allCases.count)")
        for spot in Anchor.allCases {
            let parked = spot.frame(for: pill, in: screen)
            check(screen.contains(parked), "\(spot) parks fully on screen")
            let flush = parked.minX == screen.minX || parked.maxX == screen.maxX
                     || parked.minY == screen.minY || parked.maxY == screen.maxY
            check(flush, "\(spot) sits flush against a screen edge")
            check(Anchor.nearest(to: parked, in: screen) == spot, "\(spot) re-snaps to itself")
        }
        // Dropping near an edge picks the spot on it, not the corner beyond it.
        check(Anchor.nearest(to: NSRect(x: 20, y: 430, width: 52, height: 48), in: screen) == .leftMiddle,
              "left edge, mid height → leftMiddle")
        check(Anchor.nearest(to: NSRect(x: 700, y: 10, width: 52, height: 48), in: screen) == .bottomMiddle,
              "bottom centre → bottomMiddle")
        // No top-centre spot: a drop up there falls to the nearer top corner.
        check(Anchor.nearest(to: NSRect(x: 600, y: 860, width: 52, height: 48), in: screen) == .topLeft,
              "top centre has no spot → nearer top corner")
        // A panel wider than the screen's slack still lands inside it.
        check(Anchor.rightMiddle.frame(for: NSSize(width: 5000, height: 48), in: screen).minX == screen.minX,
              "oversized panel clamps to the screen edge instead of flying off")
        // Square where it touches, rounded where it's exposed.
        check(Anchor.bottomRight.roundedCorners == [.layerMinXMaxYCorner],
              "bottom-right rounds only its exposed top-left corner")
        check(Anchor.topLeft.roundedCorners == [.layerMaxXMinYCorner],
              "top-left rounds only its exposed bottom-right corner")
        check(Anchor.rightMiddle.roundedCorners == [.layerMinXMinYCorner, .layerMinXMaxYCorner],
              "right-middle rounds its whole left side")
        check(Anchor.bottomMiddle.roundedCorners == [.layerMinXMaxYCorner, .layerMaxXMaxYCorner],
              "bottom-middle rounds its whole top side")

        print("ok — cap/evict/pin/move/edit/clear, persistence, \(Anchor.allCases.count) anchors")
    }
}
