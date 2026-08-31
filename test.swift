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

        let store = Store(key: "items", defaults: defaults)

        check(store.add("  hello  "), "non-blank saves")
        check(store.items == ["hello"], "trims whitespace")

        check(!store.add("   "), "blank is rejected")
        check(store.items == ["hello"], "blank leaves list alone")

        store.add("world")
        store.add("hello")
        check(store.items == ["hello", "world"], "re-save moves to top without duplicating")

        for i in 0..<20 { store.add("item\(i)") }
        check(store.items.count == maxItems, "capped at \(maxItems), got \(store.items.count)")
        check(store.items.first == "item19", "newest first")
        check(store.items.last == "item10", "oldest dropped")

        store.remove(0)
        check(store.items.first == "item18", "remove drops the right row")
        store.remove(99)
        check(store.items.count == maxItems - 1, "out-of-range remove is a no-op")

        // survives a reload from the same defaults
        let reloaded = Store(key: "items", defaults: defaults)
        check(reloaded.items == store.items, "persisted across instances")

        // clipAction — the pasteboard privacy guard
        check(clipAction(concealed: true, hasContents: true, string: "hunter2") == .skip("skipped — private"),
              "concealed pasteboard is never saved")
        check(clipAction(concealed: false, hasContents: true, string: nil) == .skip("not text"),
              "image/file reports not-text, not empty")
        check(clipAction(concealed: false, hasContents: false, string: nil) == .skip("clipboard empty"),
              "truly empty clipboard says so")
        check(clipAction(concealed: false, hasContents: true, string: "   ") == .skip("clipboard empty"),
              "whitespace-only counts as empty")
        check(clipAction(concealed: false, hasContents: true, string: "  hi  ") == .save("hi"),
              "real text saves, trimmed")

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

        print("ok — \(maxItems)-item cap, dedupe, trim, persistence, clip guard, \(Anchor.allCases.count) anchors")
    }
}
