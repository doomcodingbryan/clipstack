import Foundation

let maxItems = 10

enum ClipAction: Equatable {
    case save(String)
    case skip(String)   // the message to flash
}

/// What a pasteboard's contents deserve. Pure and AppKit-free so test.swift can
/// check the privacy guard without touching the real clipboard.
func clipAction(concealed: Bool, hasContents: Bool, string: String?) -> ClipAction {
    if concealed { return .skip("skipped — private") }
    guard let string else { return .skip(hasContents ? "not text" : "clipboard empty") }
    let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? .skip("clipboard empty") : .save(trimmed)
}

final class Store {
    private let key: String
    private let defaults: UserDefaults
    var items: [String]

    init(key: String = "clipstack.items", defaults: UserDefaults = .standard) {
        self.key = key
        self.defaults = defaults
        self.items = defaults.stringArray(forKey: key) ?? []
    }

    /// Returns false when there was nothing worth saving — blank, or already at the top.
    @discardableResult
    func add(_ raw: String) -> Bool {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        items.removeAll { $0 == text }          // re-saving moves it back to the top
        items.insert(text, at: 0)
        if items.count > maxItems { items.removeLast(items.count - maxItems) }
        save()
        return true
    }

    func remove(_ index: Int) {
        guard items.indices.contains(index) else { return }
        items.remove(at: index)
        save()
    }

    private func save() { defaults.set(items, forKey: key) }
}
