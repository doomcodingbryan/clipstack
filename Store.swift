import Foundation
import CoreGraphics
import QuartzCore

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

    /// The corners to round: every one not sitting on a screen edge the pill is
    /// flush against, so each flush side stays a straight, unbroken line.
    /// Layer coords, so minY is the bottom — NSVisualEffectView isn't flipped.
    var roundedCorners: CACornerMask {
        var mask: CACornerMask = [.layerMinXMinYCorner, .layerMaxXMinYCorner,
                                  .layerMinXMaxYCorner, .layerMaxXMaxYCorner]
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
