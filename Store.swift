import Foundation
import CoreGraphics
import QuartzCore

let maxItems = 10

/// What became of a save. Five outcomes because there are five things worth
/// telling someone, and "it silently dropped your oldest clip" is one of them.
enum SaveResult: Equatable {
    case blank                  // nothing typed
    case saved                  // new, at the top
    case movedUp                // already on the shelf; moved back to the top
    case evicted(String)        // saved, and this fell off the end to make room
    case full                   // at capacity with every clip pinned
}

final class Store {
    private let defaults: UserDefaults
    private let key = "clipstack.items"
    private let pinKey = "clipstack.pinned"
    var items: [String]
    /// Pins keyed by text, not index — clips are unique by text, and this way
    /// nothing already saved needs migrating.
    private var pins: Set<String>

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.items = defaults.stringArray(forKey: key) ?? []
        self.pins = Set(defaults.stringArray(forKey: pinKey) ?? [])
    }

    func isPinned(_ text: String) -> Bool { pins.contains(text) }

    func togglePin(_ index: Int) {
        guard items.indices.contains(index) else { return }
        let text = items[index]
        if pins.contains(text) { pins.remove(text) } else { pins.insert(text) }
        save()
    }

    /// Puts `text` at the top, and says what that cost. A pinned clip is never the
    /// one dropped to make room; if they all are, nothing is saved at all.
    @discardableResult
    func add(_ raw: String) -> SaveResult {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .blank }

        if items.contains(text) {
            items.removeAll { $0 == text }
            items.insert(text, at: 0)
            save()
            return .movedUp
        }

        var dropped: String?
        if items.count >= maxItems {
            guard let oldestLoose = items.lastIndex(where: { !pins.contains($0) }) else { return .full }
            dropped = items.remove(at: oldestLoose)
        }
        items.insert(text, at: 0)
        save()
        return dropped.map(SaveResult.evicted) ?? .saved
    }

    func remove(_ index: Int) {
        guard items.indices.contains(index) else { return }
        items.remove(at: index)
        save()
    }

    /// Rewrites a clip where it stands. Unlike add() it keeps its position — and so
    /// its ⌘⇧⌃n — and carries its pin across to the new text. Addressed by text
    /// rather than index: rows are rebuilt constantly and an index goes stale.
    @discardableResult
    func replace(_ old: String, with raw: String) -> SaveResult {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, items.contains(old) else { return .blank }
        guard text != old else { return .saved }

        let wasPinned = pins.contains(old)
        // Renaming onto another clip's text absorbs it rather than duplicating.
        if let twin = items.firstIndex(of: text) { items.remove(at: twin) }
        // Re-find: that removal may have shifted everything left of it.
        guard let slot = items.firstIndex(of: old) else { return .blank }
        items[slot] = text
        pins.remove(old)
        if wasPinned { pins.insert(text) }
        save()
        return .saved
    }

    /// Reordering is how a clip gets a different ⌘⇧⌃n.
    func move(from: Int, to: Int) {
        guard items.indices.contains(from), items.indices.contains(to), from != to else { return }
        items.insert(items.remove(at: from), at: to)
        save()
    }

    func clear() {
        items.removeAll()
        pins.removeAll()
        save()
    }

    private func save() {
        pins.formIntersection(items)        // a pin on a gone clip is just litter
        defaults.set(items, forKey: key)
        defaults.set(Array(pins), forKey: pinKey)
    }
}

// MARK: - Screen anchoring

/// The seven places the panel can park: both side edges at three heights each,
/// minus top-centre, which belongs to the menu bar and the notch.
enum Anchor: Int, CaseIterable {
    // ponytail: raw values 0–3 are frozen — they are what is already sitting in
    // UserDefaults from the four-corner version. New spots append.
    case bottomLeft, bottomRight, topLeft, topRight, leftMiddle, rightMiddle, bottomMiddle

    /// Where this spot sits in the usable area, 0…1 on each axis.
    private var unit: (x: CGFloat, y: CGFloat) {
        switch self {
        case .bottomLeft:   return (0, 0)
        case .bottomMiddle: return (0.5, 0)
        case .bottomRight:  return (1, 0)
        case .leftMiddle:   return (0, 0.5)
        case .rightMiddle:  return (1, 0.5)
        case .topLeft:      return (0, 1)
        case .topRight:     return (1, 1)
        }
    }

    /// Where a panel of `size` sits when parked here — flush into the edges, no inset.
    func frame(for size: NSSize, in area: NSRect) -> NSRect {
        NSRect(x: area.minX + max(0, area.width - size.width) * unit.x,
               y: area.minY + max(0, area.height - size.height) * unit.y,
               width: size.width,
               height: size.height)
    }

    enum TuckSide { case left, right, down }

    /// Which way this spot tucks away: toward the screen edge it's flush against.
    /// A corner slides sideways rather than down — side edges win.
    var tuckSide: TuckSide {
        if unit.x == 0 { return .left }
        if unit.x == 1 { return .right }
        return .down                                // bottomMiddle
    }

    var tuckArrow: (hide: String, show: String) {
        switch tuckSide {
        case .left:  return ("chevron.left", "chevron.right")
        case .right: return ("chevron.right", "chevron.left")
        case .down:  return ("chevron.down", "chevron.up")
        }
    }

    /// The shape in mid-drag, when the pill belongs to no anchor at all.
    static let allCornersRounded: CACornerMask = [.layerMinXMinYCorner, .layerMaxXMinYCorner,
                                                  .layerMinXMaxYCorner, .layerMaxXMaxYCorner]

    /// The corners to round: every one not sitting on a screen edge the pill is
    /// flush against, so each flush side stays a straight, unbroken line.
    /// Layer coords, so minY is the bottom — NSVisualEffectView isn't flipped.
    var roundedCorners: CACornerMask {
        var mask = Anchor.allCornersRounded
        if unit.x == 0 { mask.subtract([.layerMinXMinYCorner, .layerMinXMaxYCorner]) }   // flush left
        if unit.x == 1 { mask.subtract([.layerMaxXMinYCorner, .layerMaxXMaxYCorner]) }   // flush right
        if unit.y == 0 { mask.subtract([.layerMinXMinYCorner, .layerMaxXMinYCorner]) }   // flush bottom
        if unit.y == 1 { mask.subtract([.layerMinXMaxYCorner, .layerMaxXMaxYCorner]) }   // flush top
        return mask
    }

    /// The spot whose resting place is closest to where the panel was dropped.
    /// ponytail: recomputes each distance per comparison — seven spots, once per drag.
    static func nearest(to frame: NSRect, in area: NSRect) -> Anchor {
        allCases.min { $0.distance(to: frame, in: area) < $1.distance(to: frame, in: area) } ?? .bottomRight
    }

    private func distance(to dropped: NSRect, in area: NSRect) -> CGFloat {
        let rest = frame(for: dropped.size, in: area)
        return hypot(rest.midX - dropped.midX, rest.midY - dropped.midY)
    }
}
