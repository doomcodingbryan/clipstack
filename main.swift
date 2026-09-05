import AppKit
import Carbon.HIToolbox
import QuartzCore

// MARK: - Bits of chrome

func symbolButton(_ name: String, size: CGFloat = 12, describedAs: String? = nil,
                  target: AnyObject, action: Selector) -> NSButton {
    let config = NSImage.SymbolConfiguration(pointSize: size, weight: .semibold)
    let image = NSImage(systemSymbolName: name, accessibilityDescription: describedAs)?
        .withSymbolConfiguration(config)
    let button = NSButton(image: image ?? NSImage(), target: target, action: action)
    button.isBordered = false
    button.bezelStyle = .regularSquare
    button.contentTintColor = .white
    return button
}

/// The grip. Deliberately not `performDrag`: that hands the drag to the window
/// server and returns straight away, so the code after it fires on mouse-*down* and
/// there is no "let go" moment left to fall from. Tracking the events here keeps the
/// pill on the cursor and gives an exact drag-end signal.
final class DragHandle: NSImageView {
    var onDragStart: (() -> Void)?
    var onDrag: ((NSRect) -> Void)?
    var onDragEnd: (() -> Void)?
    /// Pressed and released without moving. Lets one view be both button and handle.
    var onClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        // Where in the pill it was grabbed, so it doesn't jump to centre on the cursor.
        let start = NSEvent.mouseLocation
        let grab = NSPoint(x: start.x - window.frame.minX, y: start.y - window.frame.minY)
        let size = window.frame.size
        var dragged = false

        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if next.type == .leftMouseUp { break }
            if !dragged { dragged = true; onDragStart?() }
            let mouse = NSEvent.mouseLocation
            onDrag?(NSRect(x: mouse.x - grab.x, y: mouse.y - grab.y,
                           width: size.width, height: size.height))
        }
        if dragged { onDragEnd?() } else { onClick?() }
    }
}

/// Labels take no clicks. With the pill's whole body acting as the expand target,
/// a label sitting on top of it would swallow the click before the backdrop saw it.
/// Tooltips move to the enclosing view, which still gets the hit.
final class PassThroughLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The wash shown while dragging: the screen goes dark except for the seven spots
/// the pill can land in, each outlined in a dotted line.
final class ZoneView: NSView {
    var spots: [NSRect] = [] { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let radius: CGFloat = 14

        // One even-odd path — the screen with seven holes cut out of it. The holes
        // are genuinely clear, so the desktop reads through them at full brightness
        // instead of just being a lighter shade of the dim.
        let dim = NSBezierPath(rect: bounds)
        dim.windingRule = .evenOdd
        for spot in spots {
            dim.append(NSBezierPath(roundedRect: spot, xRadius: radius, yRadius: radius))
        }
        NSColor(white: 0, alpha: 0.45).setFill()
        dim.fill()

        let dash: [CGFloat] = [6, 5]
        NSColor(white: 1, alpha: 0.85).setStroke()
        for spot in spots {
            // Inset by half the line width, or the stroke straddles the hole's edge.
            let outline = NSBezierPath(roundedRect: spot.insetBy(dx: 1, dy: 1),
                                       xRadius: radius, yRadius: radius)
            outline.lineWidth = 2
            outline.setLineDash(dash, count: dash.count, phase: 0)
            outline.stroke()
        }
    }
}

/// A saved clip. The whole strip is the copy target — a far easier hit than the
/// 22pt button it replaces, and the reclaimed width goes to the text.
final class ClipRow: NSStackView {
    static let rest: CGFloat = 0.09
    private static let hover: CGFloat = 0.2
    private static let pressed: CGFloat = 0.3

    /// Past this much vertical travel it stops being a click.
    private static let dragThreshold: CGFloat = 4

    var onClick: (() -> Void)?
    var onEdit: (() -> Void)?
    /// Total vertical travel on release, in points. Positive is up the list.
    var onMove: ((CGFloat) -> Void)?

    private var pressY: CGFloat = 0
    private var reordering = false

    // A click is mouse-*up* inside the row, the way every other clickable thing on
    // macOS behaves: press and drag off and it cancels, rather than having already
    // fired the moment you touched it. AppKit routes the drag and up events here
    // because this view took the mouse-down.
    override func mouseDown(with event: NSEvent) {
        pressY = event.locationInWindow.y
        reordering = false
        shade(Self.pressed)
    }

    override func mouseDragged(with event: NSEvent) {
        let dy = event.locationInWindow.y - pressY
        if !reordering, abs(dy) > Self.dragThreshold {
            reordering = true
            layer?.zPosition = 1            // ride over its neighbours
            shade(Self.pressed)
        }
        // Only the dragged row moves. Re-laying out the list mid-drag would destroy
        // the very view holding the mouse; the list catches up on release.
        if reordering { lift(dy) } else { shade(inside(event) ? Self.pressed : Self.rest) }
    }

    override func mouseUp(with event: NSEvent) {
        let dy = event.locationInWindow.y - pressY
        lift(0)
        layer?.zPosition = 0
        if reordering {
            reordering = false
            shade(Self.rest)
            onMove?(dy)
            return
        }
        let hit = inside(event)
        shade(hit ? Self.hover : Self.rest)      // still under the cursor? stay lit
        // The first click of a double already copied. That's harmless, and the
        // alternative is delaying every copy to wait for a second click.
        if hit { event.clickCount >= 2 ? onEdit?() : onClick?() }
    }

    /// Instant, not animated — an implicit CA animation here would trail the cursor.
    private func lift(_ dy: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.transform = CATransform3DMakeTranslation(0, dy, 0)
        CATransaction.commit()
    }

    private func inside(_ event: NSEvent) -> Bool {
        bounds.contains(convert(event.locationInWindow, from: nil))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        // .activeAlways: the panel is non-activating and never key, so hover has to
        // work without the app being frontmost.
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { shade(Self.hover) }
    override func mouseExited(with event: NSEvent) { shade(Self.rest) }

    private func shade(_ alpha: CGFloat) {
        layer?.backgroundColor = NSColor.white.withAlphaComponent(alpha).cgColor
    }
}

/// Borderless panels refuse key status, and without it there is no keyboard input
/// at all. The typing field needs it; `.nonactivatingPanel` still keeps a plain
/// click on the pill from stealing focus from whatever you were working in.
final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }

    /// An accessory app has no main menu, and the main menu is what normally
    /// dispatches ⌘X/⌘C/⌘V/⌘A to the field editor. Without this the text box
    /// silently swallows every one of them.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard mods == .command || mods == .control else {
            return super.performKeyEquivalent(with: event)
        }
        let action: Selector?
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "v":                        action = #selector(NSText.paste(_:))
        case "c" where mods == .command: action = #selector(NSText.copy(_:))
        case "x" where mods == .command: action = #selector(NSText.cut(_:))
        case "a" where mods == .command: action = #selector(NSText.selectAll(_:))
        default:                         action = nil
        }
        guard let action else { return super.performKeyEquivalent(with: event) }
        return NSApp.sendAction(action, to: nil, from: self)
    }
}

/// The pill's body is the way back out of the collapsed state.
final class ClickToExpand: NSVisualEffectView {
    var onClick: (() -> Void)?
    override func mouseDown(with event: NSEvent) { onClick?() }
}

func label(_ text: String, size: CGFloat, alpha: CGFloat = 1) -> NSTextField {
    let field = PassThroughLabel(labelWithString: text)
    field.font = .systemFont(ofSize: size, weight: .regular)
    field.textColor = NSColor.white.withAlphaComponent(alpha)
    field.lineBreakMode = .byTruncatingTail
    field.maximumNumberOfLines = 1
    field.cell?.truncatesLastVisibleLine = true
    return field
}

/// How the panel travels to a new frame.
private enum Move {
    case cut        // first layout: no previous frame to move from
    case unfold     // expand/collapse, growing out of the anchored corner
    case settle     // let go of a drag, falling to the nearest spot

    var duration: TimeInterval {
        switch self {
        case .cut:    return 0
        case .unfold: return 0.18
        case .settle: return 0.24
        }
    }
}

// MARK: - Global hotkey

// Carbon's handler is a bare C function pointer, so these live out here instead of
// being captured. The keyed registry the old one-hotkey global said it would need.
private var hotKeyActions: [UInt32: () -> Void] = [:]
private var hotKeyRefs: [EventHotKeyRef?] = []
private var hotKeyHandlerInstalled = false

/// Registers a system-wide hotkey. Carbon rather than NSEvent's global monitor
/// on purpose: RegisterEventHotKey needs no Accessibility permission, so
/// Clipstack never has to ask the user for one.
private func registerHotKey(id: UInt32, keyCode: UInt32, modifiers: UInt32,
                            action: @escaping () -> Void) -> Bool {
    hotKeyActions[id] = action

    // One handler serves every hotkey — it reads back which one fired.
    if !hotKeyHandlerInstalled {
        hotKeyHandlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var fired = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &fired)
            hotKeyActions[fired.id]?()
            return noErr
        }, 1, &spec, nil, nil)
    }

    var ref: EventHotKeyRef?
    let ok = RegisterEventHotKey(keyCode, modifiers,
                                 EventHotKeyID(signature: OSType(0x434C5053), id: id),
                                 GetApplicationEventTarget(), 0, &ref) == noErr
    if ok { hotKeyRefs.append(ref) }
    return ok
}

// MARK: - App

let collapsedSize = NSSize(width: 72, height: 48)   // insets + grip + count
private let tuckOverlap: CGFloat = 8   // how far the little pill rides over the big one
let expandedWidth: CGFloat = 360
private let rowHeight: CGFloat = 40   // two lines of preview
private let iconSide: CGFloat = 28
private let gripWidth: CGFloat = 16
private let expandedKey = "clipstack.expanded"
private let tuckedKey = "clipstack.tucked"
// ponytail: key string unchanged so an existing saved spot survives the rename.
private let anchorKey = "clipstack.corner"
// Cmd+Shift+Ctrl+V. Cmd+Shift+V is Paste and Match Style, which is not ours to take.
private let hotKeyCode = UInt32(kVK_ANSI_V)
private let hotKeyMods = UInt32(cmdKey | shiftKey | controlKey)
private let hotKeyHint = "⌘⇧⌃V"
private let clipChord = "⌘⇧⌃"
/// Digit key codes are not contiguous, so they get spelled out. Position i picks
/// clip i, with 0 in last place for the tenth — the browser-tab convention.
private let clipKeyCodes: [UInt32] = [
    UInt32(kVK_ANSI_1), UInt32(kVK_ANSI_2), UInt32(kVK_ANSI_3), UInt32(kVK_ANSI_4), UInt32(kVK_ANSI_5),
    UInt32(kVK_ANSI_6), UInt32(kVK_ANSI_7), UInt32(kVK_ANSI_8), UInt32(kVK_ANSI_9), UInt32(kVK_ANSI_0),
]
private func clipShortcutLabel(_ index: Int) -> String { index == 9 ? "0" : "\(index + 1)" }

private func fix(_ view: NSView, _ width: CGFloat, _ height: CGFloat) {
    view.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
        view.widthAnchor.constraint(equalToConstant: width),
        view.heightAnchor.constraint(equalToConstant: height),
    ])
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSTextFieldDelegate, NSWindowDelegate {
    let store = Store()
    var panel: NSPanel!
    // Opens expanded the very first time so you can actually find it on screen;
    // after that it reopens however you left it.
    var expanded = UserDefaults.standard.object(forKey: expandedKey) as? Bool ?? true
    // object(forKey:), not integer(forKey:) — the latter returns 0 when unset,
    // which is a valid Anchor and would swallow the default.
    var anchor = (UserDefaults.standard.object(forKey: anchorKey) as? Int)
        .flatMap(Anchor.init(rawValue:)) ?? .bottomRight
    // bool(forKey:) is fine here — unset means false means not tucked.
    var tucked = UserDefaults.standard.bool(forKey: tuckedKey)

    private var root: NSStackView!
    private var listStack: NSStackView!
    private var plusButton: NSButton!
    private var countLabel: NSTextField!
    private var flash: NSTextField!
    private var closeButton: NSButton!
    private var grip: DragHandle!
    private var tuckHandle: DragHandle!
    private var tuckPanel: NSPanel!
    private var input: NSTextField!
    private var inputRow: NSStackView!
    private var typing = false
    /// The clip being rewritten. nil means a brand new one.
    private var editing: String?

    func applicationDidFinishLaunching(_ note: Notification) {
        NSApp.setActivationPolicy(.accessory)   // no Dock icon, no menu bar

        panel = KeyPanel(
            contentRect: NSRect(origin: .zero, size: collapsedSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false     // its halo is square, so it reads as a box round the pill
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.delegate = self       // for windowDidResignKey

        let backdrop = ClickToExpand()
        backdrop.onClick = { [weak self] in self?.setExpanded(true) }
        backdrop.material = .hudWindow
        backdrop.blendingMode = .behindWindow
        backdrop.state = .active
        backdrop.wantsLayer = true
        backdrop.layer?.cornerRadius = 16
        backdrop.layer?.cornerCurve = .continuous
        backdrop.layer?.masksToBounds = true
        panel.contentView = backdrop

        // Right-click anywhere — including on a clip — reaches these.
        backdrop.menu = makeMenu()

        buildViews(in: backdrop)
        buildTuckPanel()
        render()          // render() parks it in `anchor` via resizePanel
        if !tucked { panel.orderFrontRegardless() }
        raiseTuck()

        // Clip pickers first, so a partial failure doesn't stop the main one.
        let missed = clipKeyCodes.enumerated().filter { index, code in
            !registerHotKey(id: UInt32(index + 2), keyCode: code, modifiers: hotKeyMods) { [weak self] in
                self?.copyFromHotKey(index)
            }
        }
        if !missed.isEmpty {
            FileHandle.standardError.write("Clipstack: \(missed.count) of \(clipKeyCodes.count) clip shortcuts were already taken\n".data(using: .utf8)!)
        }

        if !registerHotKey(id: 1, keyCode: hotKeyCode, modifiers: hotKeyMods, action: { [weak self] in
            self?.typeFromHotKey()
        }) {
            // Someone else owns the combo. Say so rather than failing silently.
            FileHandle.standardError.write("Clipstack: \(hotKeyHint) is already taken\n".data(using: .utf8)!)
            show(flash: "hotkey in use")
        }
    }

    private func buildViews(in container: NSView) {
        grip = DragHandle()
        grip.image = NSImage(systemSymbolName: "line.3.horizontal", accessibilityDescription: "Drag to move")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold))
        grip.contentTintColor = NSColor.white.withAlphaComponent(0.45)
        grip.toolTip = "Drag to move"
        grip.menu = container.menu      // keep right-click-to-quit working over the grip
        // Airborne it belongs to no anchor, so nothing is squared off against an edge.
        grip.onDragStart = { [weak self] in
            guard let self else { return }
            self.panel.contentView?.layer?.maskedCorners = Anchor.allCornersRounded
            self.tuckPanel.orderOut(nil)        // no point trailing the pill mid-flight
            self.showZones(pill: self.panel.frame.size, over: self.panel.frame)
        }
        grip.onDrag = { [weak self] frame in
            guard let self else { return }
            self.panel.setFrame(frame, display: true)
            self.showZones(pill: frame.size, over: frame)
        }
        grip.onDragEnd = { [weak self] in
            guard let self else { return }
            self.hideZones()
            self.settle(from: self.panel.frame)
        }
        fix(grip, gripWidth, iconSide)

        closeButton = symbolButton("xmark", size: 11, describedAs: "Minimize",
                                   target: self, action: #selector(minimize))
        closeButton.toolTip = "Minimize"
        closeButton.contentTintColor = NSColor.white.withAlphaComponent(0.55)
        fix(closeButton, iconSide, iconSide)

        plusButton = symbolButton("plus.circle.fill", size: 16, target: self, action: #selector(openInput))
        plusButton.toolTip = "Add a clip  (\(hotKeyHint))"
        fix(plusButton, iconSide, iconSide)

        countLabel = label("", size: 11, alpha: 0.55)
        flash = label("", size: 11, alpha: 0.9)
        flash.alignment = .right
        flash.alphaValue = 0        // faded up by show(flash:)
        // Lowest resistance in the header, so a long readback truncates itself
        // instead of squeezing the count or the buttons.
        flash.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)

        let header = NSStackView(views: [grip, plusButton, countLabel, spacer, flash, closeButton])
        header.orientation = .horizontal
        header.spacing = 8
        header.alignment = .centerY
        header.distribution = .fill

        input = NSTextField(string: "")
        input.font = .systemFont(ofSize: 12)
        input.textColor = .white
        input.isBordered = false
        input.focusRingType = .none
        input.drawsBackground = false
        input.placeholderAttributedString = NSAttributedString(
            string: "Type a clip, ⏎ to save",
            attributes: [.foregroundColor: NSColor.white.withAlphaComponent(0.35),
                         .font: NSFont.systemFont(ofSize: 12)])
        // Single-line mode centres the text in the cell; scrollable lets a long
        // clip run past the right edge instead of clipping dead.
        input.usesSingleLineMode = true
        input.cell?.wraps = false
        input.cell?.isScrollable = true
        input.delegate = self               // for Escape
        input.target = self
        input.action = #selector(commitInput)   // fires on ⏎

        // Wrapped so the text isn't flush against the rounded edge — NSTextField
        // has no content inset, but a stack has edgeInsets.
        // No fixed height on the field itself: left at its intrinsic one line, the
        // text fills it exactly and .centerY does the centring. Forcing it taller
        // just pins the text to the top of the cell.
        inputRow = NSStackView(views: [input])
        inputRow.orientation = .horizontal
        inputRow.alignment = .centerY
        inputRow.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        inputRow.distribution = .fill
        // ponytail: explicit height, same reason as a clip row — edgeInsets don't
        // survive being measured through the parent stack's fittingSize.
        inputRow.heightAnchor.constraint(equalToConstant: 30).isActive = true
        inputRow.isHidden = true
        inputRow.wantsLayer = true
        inputRow.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.14).cgColor
        inputRow.layer?.cornerRadius = 7
        inputRow.layer?.cornerCurve = .continuous

        listStack = NSStackView()
        listStack.orientation = .vertical
        listStack.spacing = 4
        listStack.alignment = .leading

        // List sits above the header so the pill itself stays put while the
        // panel grows upward off it.
        // Field sits directly above the header, right where the + you pressed is.
        root = NSStackView(views: [listStack, inputRow, header])
        root.orientation = .vertical
        root.spacing = 8
        root.alignment = .leading
        root.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        root.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(root)

        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            root.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            listStack.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -24),
            inputRow.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -24),
        ])
    }

    // MARK: Actions

    @objc private func minimize() { setExpanded(false) }

    private func toggleTuck() {
        tucked.toggle()
        UserDefaults.standard.set(tucked, forKey: tuckedKey)
        if tucked {
            closeInput()
            panel.orderOut(nil)
        } else {
            panel.orderFrontRegardless()
        }
        // resizePanel re-runs place(), which moves and re-points the little one.
        resizePanel()
        raiseTuck()
    }

    /// The arrow points at the edge the pill vanishes into, and back out once it
    /// has. Re-pointed on every move too — dragging to another edge flips it.
    private func updateTuckArrow() {
        let arrow = anchor.tuckArrow
        tuckHandle.image = NSImage(systemSymbolName: tucked ? arrow.show : arrow.hide,
                                   accessibilityDescription: tucked ? "Show the pill" : "Hide the pill")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold))
        tuckHandle.toolTip = tucked ? "Bring the pill back — drag to move it"
                                    : "Hide the pill against the edge — drag to move it"
    }

    /// A pill of its own, riding beside the big one on the side away from the edge
    /// it tucks into — and taking its place at that edge once it's gone.
    private func buildTuckPanel() {
        tuckPanel = NSPanel(contentRect: NSRect(origin: .zero, size: NSSize(width: 24, height: 34)),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        tuckPanel.level = .floating
        tuckPanel.isOpaque = false
        tuckPanel.backgroundColor = .clear
        tuckPanel.hasShadow = false
        tuckPanel.hidesOnDeactivate = false
        tuckPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let blur = NSVisualEffectView()
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 11
        blur.layer?.cornerCurve = .continuous
        blur.layer?.masksToBounds = true
        blur.menu = panel.contentView?.menu       // right-click quits here too
        tuckPanel.contentView = blur

        tuckHandle = DragHandle()
        tuckHandle.imageAlignment = .alignCenter
        tuckHandle.contentTintColor = NSColor.white.withAlphaComponent(0.75)
        tuckHandle.menu = blur.menu
        tuckHandle.onClick = { [weak self] in self?.toggleTuck() }
        tuckHandle.onDragStart = { [weak self] in
            guard let self else { return }
            let loose = Anchor.allCornersRounded         // airborne: nothing squared off
            self.panel.contentView?.layer?.maskedCorners = loose
            self.tuckPanel.contentView?.layer?.maskedCorners = loose
            self.showZones(pill: self.anchoredFrame.size, over: self.anchoredFrame)
        }
        tuckHandle.onDrag = { [weak self] frame in
            guard let self else { return }
            // Untucked, the big pill is still the thing being positioned — carry it
            // along by the same delta so the pair travels as one.
            let dx = frame.minX - self.tuckPanel.frame.minX
            let dy = frame.minY - self.tuckPanel.frame.minY
            self.tuckPanel.setFrame(frame, display: true)
            if !self.tucked {
                self.panel.setFrame(self.panel.frame.offsetBy(dx: dx, dy: dy), display: true)
            }
            self.showZones(pill: self.anchoredFrame.size, over: self.anchoredFrame)
        }
        tuckHandle.onDragEnd = { [weak self] in
            guard let self else { return }
            self.hideZones()
            self.settle(from: self.anchoredFrame)
        }
        tuckHandle.translatesAutoresizingMaskIntoConstraints = false
        blur.addSubview(tuckHandle)
        NSLayoutConstraint.activate([
            tuckHandle.leadingAnchor.constraint(equalTo: blur.leadingAnchor),
            tuckHandle.trailingAnchor.constraint(equalTo: blur.trailingAnchor),
            tuckHandle.topAnchor.constraint(equalTo: blur.topAnchor),
            tuckHandle.bottomAnchor.constraint(equalTo: blur.bottomAnchor),
        ])
    }

    /// Whichever pill is actually on screen doing the anchoring.
    private var anchoredFrame: NSRect { tucked ? tuckPanel.frame : panel.frame }

    /// Kept above the big pill — they overlap now, and the arrow has to stay
    /// visible and clickable. Tucked, the big one is ordered out, so its window
    /// number is no longer a thing to sit above.
    private func raiseTuck() {
        if tucked { tuckPanel.orderFrontRegardless() }
        else { tuckPanel.order(.above, relativeTo: panel.windowNumber) }
    }

    /// Where the little pill sits for a big pill at `pill`.
    private func tuckFrame(beside pill: NSRect) -> NSRect {
        let size = anchor.tuckSide == .down ? NSSize(width: 34, height: 24) : NSSize(width: 24, height: 34)
        if tucked, let area = area(under: NSPoint(x: pill.midX, y: pill.midY)) {
            return anchor.frame(for: size, in: area)
        }
        switch anchor.tuckSide {
        case .left:  return NSRect(x: pill.maxX - tuckOverlap, y: pill.midY - size.height / 2,
                                   width: size.width, height: size.height)
        case .right: return NSRect(x: pill.minX + tuckOverlap - size.width, y: pill.midY - size.height / 2,
                                   width: size.width, height: size.height)
        case .down:  return NSRect(x: pill.midX - size.width / 2, y: pill.maxY - tuckOverlap,
                                   width: size.width, height: size.height)
        }
    }

    private func setExpanded(_ on: Bool) {
        guard expanded != on else { return }
        expanded = on
        UserDefaults.standard.set(on, forKey: expandedKey)

        guard on else {
            closeInput()        // no field to type into once it's folded away
            // Fade the rows out *before* tearing them down, or they blink out of
            // existence a beat ahead of the box that's supposed to contain them.
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.12
                ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
                self.listStack.animator().alphaValue = 0
            }, completionHandler: { [weak self] in self?.render() })
            return
        }
        listStack.alphaValue = 0    // the unfold fades it back up
        render()
    }

    /// Opens the shelf and drops straight into the field — the field being the only
    /// way anything gets in now.
    private func typeFromHotKey() {
        setExpanded(true)
        panel.orderFrontRegardless()
        openInput()
    }

    /// Opens the typing field. Clips only ever come from here.
    @objc private func openInput() { beginInput(on: nil) }

    /// - Parameter clip: the text to rewrite, or nil to write a new one.
    private func beginInput(on clip: String?) {
        editing = clip
        input.stringValue = clip ?? ""
        typing = true
        clearFlash()        // a stale "copied" next to an open editor reads as a result
        render()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(input)
        if clip != nil { input.currentEditor()?.selectAll(nil) }
    }

    @objc private func commitInput() {
        let text = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let rewriting = editing
        closeInput()
        // An edit keeps its slot, so nothing slides in at the top for it.
        switch rewriting.map({ store.replace($0, with: text) }) ?? store.add(text) {
        case .blank:
            return                                      // back out quietly
        case .full:
            show(flash: "shelf full — unpin or delete one", for: 2.6)
        case .movedUp:
            // Otherwise a duplicate looks like a no-op: the count doesn't move and
            // the row it "added" was already there.
            render(newRow: true)
            show(flash: "already saved — moved up", for: 2.2)
        case .saved:
            render(newRow: rewriting == nil)
            show(flash: text, for: 2.2)
        case .evicted(let gone):
            render(newRow: true)
            show(flash: "saved — dropped “\(gone)”", for: 2.6)
        }
    }

    /// - Parameter returningFocus: false when the field is closing *because* focus
    ///   already left — deactivating again there would be shoving an open door.
    private func closeInput(returningFocus: Bool = true) {
        // Also the re-entrancy guard: closing resigns key, which calls back in here.
        guard typing else { return }
        typing = false
        editing = nil
        input.stringValue = ""
        panel.makeFirstResponder(nil)
        if returningFocus { NSApp.deactivate() }
        render()
    }

    /// Clicked away mid-type. Without this the box hangs open with half a clip in
    /// it until you come back and press ⏎ or Escape. Discards, same as Escape.
    func windowDidResignKey(_ note: Notification) {
        closeInput(returningFocus: false)
    }

    /// Escape backs out without saving.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            closeInput()
            return true
        }
        // The field editor turns ⌃V into emacs pageDown, which is nothing at all in
        // a one-line box. Catch it here so ⌃V pastes too.
        if selector == #selector(NSResponder.pageDown(_:)) {
            textView.paste(nil)
            return true
        }
        return false
    }

    /// Whatever app you're in, ⌘⇧⌃n puts clip n on the pasteboard ready to paste.
    private func copyFromHotKey(_ index: Int) {
        guard store.items.indices.contains(index) else { return }
        copy(index)
    }

    private func copy(_ index: Int) {
        guard store.items.indices.contains(index) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(store.items[index], forType: .string)
        show(flash: "copied")
    }

    @objc private func togglePin(_ sender: NSButton) {
        store.togglePin(sender.tag)
        render()
    }

    /// A row dragged `dy` points lands that many row-heights away. Up the screen is
    /// toward index 0, so the travel subtracts.
    private func moveRow(_ index: Int, by dy: CGFloat) {
        let step = rowHeight + listStack.spacing
        let target = max(0, min(store.items.count - 1, index - Int((dy / step).rounded())))
        guard target != index else { return }
        store.move(from: index, to: target)
        render()
    }

    /// Clear All and Quit, built fresh each time: an NSMenuItem belongs to one menu,
    /// so rows can't share the pill's instances.
    private func baseMenuItems() -> [NSMenuItem] {
        let clear = NSMenuItem(title: "Clear All Clips…", action: #selector(clearAll), keyEquivalent: "")
        clear.target = self         // the delegate isn't reliably in the responder chain
        let quit = NSMenuItem(title: "Quit Clipstack", action: #selector(NSApp.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        return [clear, .separator(), quit]
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        baseMenuItems().forEach(menu.addItem)
        return menu
    }

    /// A clip's own menu. Carries the global items too, so no part of the pill is a
    /// dead zone for right-click.
    private func rowMenu(for text: String) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(clipItem("Edit…", #selector(editClip(_:)), text))
        menu.addItem(clipItem(store.isPinned(text) ? "Unpin" : "Pin", #selector(pinClip(_:)), text))
        menu.addItem(clipItem("Delete", #selector(deleteClip(_:)), text))
        menu.addItem(.separator())
        baseMenuItems().forEach(menu.addItem)
        return menu
    }

    /// Carries the clip's text, not its row index — an index goes stale the moment
    /// anything re-renders, and then the menu acts on the wrong clip.
    private func clipItem(_ title: String, _ action: Selector, _ text: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = text
        return item
    }

    @objc private func editClip(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        beginInput(on: text)
    }

    @objc private func pinClip(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String,
              let index = store.items.firstIndex(of: text) else { return }
        store.togglePin(index)
        render()
    }

    @objc private func deleteClip(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String,
              let index = store.items.firstIndex(of: text) else { return }
        store.remove(index)
        render()
    }

    @objc private func clearAll() {
        let alert = NSAlert()
        alert.messageText = "Clear all clips?"
        alert.informativeText = "All \(store.items.count) clips, pinned ones included, will be deleted. This can't be undone."
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        store.clear()
        render()
    }

    @objc private func deleteRow(_ sender: NSButton) {
        store.remove(sender.tag)
        render()
    }

    private func show(flash text: String, for seconds: Double = 1.1) {
        // One line only — a saved clip can be many.
        flash.stringValue = text.replacingOccurrences(of: "\n", with: " ")
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            self.flash.animator().alphaValue = 1
        }
        // ponytail: token check beats cancelling a timer — later flashes just win.
        let token = text + String(Date().timeIntervalSince1970)
        flashToken = token
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, self.flashToken == token else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.3
                self.flash.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                // Re-check: a flash raised during the fade owns the label now.
                guard let self, self.flashToken == token else { return }
                self.flash.stringValue = ""
            })
        }
    }
    private func clearFlash() {
        flashToken = ""             // cancels any fade still pending
        flash.stringValue = ""
        flash.alphaValue = 0
    }
    private var flashToken = ""
    /// The first layout has no previous frame to animate from.
    private var hasLaidOut = false
    private var zonePanel: NSPanel?
    private var zoneScreen: NSScreen?
    private let zoneView = ZoneView()

    // MARK: Render

    private func render(newRow: Bool = false) {
        listStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        plusButton.isHidden = !expanded
        flash.isHidden = !expanded
        listStack.isHidden = !expanded
        closeButton.isHidden = !expanded
        inputRow.isHidden = !(expanded && typing)
        // Bare count when collapsed — it's all the pill has room to say.
        countLabel.stringValue = expanded ? "\(store.items.count)/\(maxItems)" : "\(store.items.count)"

        if expanded {
            if store.items.isEmpty {
                let hint = label("Hit + or \(hotKeyHint) to write a clip", size: 11, alpha: 0.45)
                listStack.addArrangedSubview(hint)
            }
            for (index, text) in store.items.enumerated() {
                let view = row(index: index, text: text)
                listStack.addArrangedSubview(view)
                // Rows fill the panel instead of hugging their text.
                view.widthAnchor.constraint(equalTo: listStack.widthAnchor).isActive = true
            }
        }

        // Purely presentational: from/to only, model values are already final, so
        // there is no state to put back afterwards.
        if newRow, let layer = listStack.arrangedSubviews.first?.layer {
            let slide = CABasicAnimation(keyPath: "transform.translation.y")
            slide.fromValue = 10        // starts above its slot and drops in
            slide.toValue = 0
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            for step in [slide, fade] {
                step.duration = 0.24
                step.timingFunction = CAMediaTimingFunction(name: .easeOut)
                layer.add(step, forKey: step.keyPath)
            }
        }

        resizePanel()
    }

    private func row(index: Int, text: String) -> NSView {
        // Newlines flatten to spaces on purpose: two wrapped lines of running text
        // show far more of a snippet than its first two literal lines would.
        let preview = label(text.replacingOccurrences(of: "\n", with: " "), size: 12, alpha: 0.92)
        preview.maximumNumberOfLines = 2
        preview.usesSingleLineMode = false
        preview.cell?.wraps = true
        preview.cell?.isScrollable = false
        // Low hugging = the label soaks up the spare width, so the buttons stay
        // pinned right instead of trailing short text.
        preview.setContentHuggingPriority(.defaultLow, for: .horizontal)
        preview.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let number = label(clipShortcutLabel(index), size: 10, alpha: 0.38)
        number.alignment = .center
        number.toolTip = "\(clipChord)\(clipShortcutLabel(index)) copies this clip"
        fix(number, 13, 20)

        let held = store.isPinned(text)
        let pin = symbolButton(held ? "pin.fill" : "pin", size: 10,
                               describedAs: held ? "Unpin" : "Pin",
                               target: self, action: #selector(togglePin(_:)))
        pin.tag = index
        pin.contentTintColor = NSColor.white.withAlphaComponent(held ? 0.85 : 0.28)
        pin.toolTip = held ? "Unpin — it can be dropped again" : "Pin — never dropped to make room"
        fix(pin, 18, 20)

        let trash = symbolButton("xmark", size: 10, target: self, action: #selector(deleteRow(_:)))
        trash.tag = index
        trash.contentTintColor = NSColor.white.withAlphaComponent(0.45)
        trash.toolTip = "Delete"
        fix(trash, 18, 20)

        let menu = rowMenu(for: text)
        pin.menu = menu             // NSControls swallow right-clicks; give them one
        trash.menu = menu

        let stack = ClipRow(views: [number, preview, pin, trash])
        stack.menu = menu
        stack.onClick = { [weak self] in self?.copy(index) }
        stack.onMove = { [weak self] dy in self?.moveRow(index, by: dy) }
        stack.onEdit = { [weak self] in self?.beginInput(on: text) }
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.alignment = .centerY
        // ponytail: NSStackView defaults to .gravityAreas, which pools slack at the
        // trailing edge and ignores hugging. .fill is what makes the label stretch.
        stack.distribution = .fill
        // ponytail: explicit row height — NSStackView.edgeInsets doesn't survive
        // being measured through a parent stack's fittingSize, rows come out 16pt.
        stack.toolTip = "\(text)\n\nDouble-click to edit"   // and the untruncated text, free
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 6)
        stack.heightAnchor.constraint(equalToConstant: rowHeight).isActive = true
        stack.wantsLayer = true
        stack.layer?.backgroundColor = NSColor.white.withAlphaComponent(ClipRow.rest).cgColor
        stack.layer?.cornerRadius = 7
        stack.layer?.cornerCurve = .continuous
        return stack
    }

    /// Resizes in place and re-parks on the current anchor, so the panel grows
    /// away from whichever screen edges it's pinned to.
    private func resizePanel() {
        let start = panel.frame
        guard let area = area(under: NSPoint(x: start.midX, y: start.midY)) else { return }
        let width = expanded ? expandedWidth : collapsedSize.width

        // Width has to land before measuring: fittingSize asks the labels how tall
        // they are at the *current* width, and at the collapsed 72pt they all lie.
        panel.setFrame(NSRect(origin: start.origin, size: NSSize(width: width, height: start.height)),
                       display: false)
        panel.layoutIfNeeded()

        let height = expanded
            ? max(collapsedSize.height, root.fittingSize.height)
            : collapsedSize.height

        // Rewind. That measuring resize is not where the animation should start
        // from — leave it in place and the width snaps while only the height eases.
        panel.setFrame(start, display: false)
        place(anchor.frame(for: NSSize(width: width, height: height), in: area),
              on: anchor, hasLaidOut ? .unfold : .cut)
        hasLaidOut = true
    }

    /// Moves the panel and reshapes it — corners on a flush screen edge go square.
    private func place(_ target: NSRect, on spot: Anchor, _ move: Move) {
        anchor = spot
        panel.contentView?.layer?.maskedCorners = spot.roundedCorners
        updateTuckArrow()       // a new edge means a new direction to point in
        let tuck = tuckFrame(beside: target)
        // Squared off only when it's the one sitting in the edge.
        tuckPanel?.contentView?.layer?.maskedCorners = tucked ? spot.roundedCorners : Anchor.allCornersRounded
        guard move != .cut else {
            panel.setFrame(target, display: true)
            tuckPanel?.setFrame(tuck, display: true)
            return
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = move.duration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.panel.animator().setFrame(target, display: true)
            self.tuckPanel?.animator().setFrame(tuck, display: true)
            if move == .unfold { self.listStack.animator().alphaValue = 1 }
        }
    }

    /// The screen a point is over, so a drag can carry the pill to another display.
    private func area(under point: NSPoint) -> NSRect? {
        (NSScreen.screens.first { $0.frame.contains(point) } ?? panel.screen ?? NSScreen.main)?.visibleFrame
    }

    /// Raises the drop-zone wash over whichever screen the pill is on. Cheap to call
    /// on every drag event: it only redraws when the drag crosses to another display.
    private func showZones(pill: NSSize, over frame: NSRect) {
        let middle = NSPoint(x: frame.midX, y: frame.midY)
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(middle) })
                ?? panel.screen ?? NSScreen.main else { return }
        let zones = zonePanel ?? makeZonePanel()
        guard screen != zoneScreen else { return }
        zoneScreen = screen

        zones.setFrame(screen.frame, display: false)
        // Anchor frames are in screen coordinates; the view's are window-relative.
        zoneView.spots = Anchor.allCases.map {
            $0.frame(for: pill, in: screen.visibleFrame)
                .offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
        }
        zones.alphaValue = 1
        zones.order(.below, relativeTo: panel.windowNumber)      // never over the pill
    }

    private func makeZonePanel() -> NSPanel {
        let zones = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        zones.isOpaque = false
        zones.backgroundColor = .clear
        zones.hasShadow = false
        // The drag loop has implicit capture of the mouse, so it keeps running
        // underneath — but only if this thing never eats a click itself.
        zones.ignoresMouseEvents = true
        zones.level = .floating
        zones.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        zones.contentView = zoneView
        zonePanel = zones
        return zones
    }

    /// Fades out as the pill falls. This runs after the drag loop has exited, so
    /// unlike anything mid-drag it gets a runloop to animate on.
    private func hideZones() {
        zoneScreen = nil
        guard let zones = zonePanel else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            zones.animator().alphaValue = 0
        }, completionHandler: {
            zones.orderOut(nil)
            zones.alphaValue = 1
        })
    }

    /// Let go: fall to the spot nearest where it was dropped, on whichever screen it
    /// was dropped on. `moved` is whichever pill was under the cursor.
    private func settle(from moved: NSRect) {
        // Tucked, the big pill is hidden and parked wherever it was last left —
        // possibly a different screen. Bring it along or area(under:) resolves
        // against a stale position and it lands back where it started.
        if tucked {
            panel.setFrame(NSRect(origin: moved.origin, size: panel.frame.size), display: false)
        }
        guard let area = area(under: NSPoint(x: moved.midX, y: moved.midY)) else { return }
        let landed = Anchor.nearest(to: moved, in: area)
        place(landed.frame(for: panel.frame.size, in: area), on: landed, .settle)
        raiseTuck()
        UserDefaults.standard.set(landed.rawValue, forKey: anchorKey)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
