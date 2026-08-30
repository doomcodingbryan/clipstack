import Foundation

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

        print("ok — \(maxItems)-item cap, dedupe, trim, persistence, clip guard")
    }
}
