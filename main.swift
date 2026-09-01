import AppKit
import Carbon.HIToolbox
import QuartzCore

extension NSPasteboard.PasteboardType {
    /// nspasteboard.org convention: password managers set this so clipboard
    /// tools don't archive secrets. Cheaper than a setting nobody finds.
    static let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
}

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
        // A plain click on the grip isn't a drag — nothing to fall back from.
        if dragged { onDragEnd?() }
    }
}

/// Labels take no clicks. With the pill's whole body acting as the expand target,
/// a label sitting on top of it would swallow the click before the backdrop saw it.
/// Tooltips move to the enclosing view, which still gets the hit.
final class PassThroughLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
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

// Carbon's handler is a bare C function pointer, so the callback lives out here
// instead of being captured. ponytail: one global for one hotkey — a keyed
// registry is what you'd add on the day there's a second one.
private var hotKeyAction: (() -> Void)?
private var hotKeyRef: EventHotKeyRef?

/// Registers a system-wide hotkey. Carbon rather than NSEvent's global monitor
/// on purpose: RegisterEventHotKey needs no Accessibility permission, so
/// Clipstack never has to ask the user for one.
private func registerHotKey(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) -> Bool {
    hotKeyAction = action

    var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                             eventKind: UInt32(kEventHotKeyPressed))
    InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
        hotKeyAction?()
        return noErr
    }, 1, &spec, nil, nil)

    let id = EventHotKeyID(signature: OSType(0x434C5053), id: 1)   // 'CLPS'
    return RegisterEventHotKey(keyCode, modifiers, id,
                               GetApplicationEventTarget(), 0, &hotKeyRef) == noErr
}

// MARK: - App

let collapsedSize = NSSize(width: 72, height: 48)   // insets + grip + count
let expandedWidth: CGFloat = 300
private let rowHeight: CGFloat = 26
private let iconSide: CGFloat = 28
private let gripWidth: CGFloat = 16
private let expandedKey = "clipstack.expanded"
// ponytail: key string unchanged so an existing saved spot survives the rename.
private let anchorKey = "clipstack.corner"
// Cmd+Shift+Ctrl+V. Cmd+Shift+V is Paste and Match Style, which is not ours to take.
private let hotKeyCode = UInt32(kVK_ANSI_V)
private let hotKeyMods = UInt32(cmdKey | shiftKey | controlKey)
private let hotKeyHint = "⌘⇧⌃V"

private func fix(_ view: NSView, _ width: CGFloat, _ height: CGFloat) {
    view.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
        view.widthAnchor.constraint(equalToConstant: width),
        view.heightAnchor.constraint(equalToConstant: height),
    ])
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = Store()
    var panel: NSPanel!
    // Opens expanded the very first time so you can actually find it on screen;
    // after that it reopens however you left it.
    var expanded = UserDefaults.standard.object(forKey: expandedKey) as? Bool ?? true
    // object(forKey:), not integer(forKey:) — the latter returns 0 when unset,
    // which is a valid Anchor and would swallow the default.
    var anchor = (UserDefaults.standard.object(forKey: anchorKey) as? Int)
        .flatMap(Anchor.init(rawValue:)) ?? .bottomRight

    private var root: NSStackView!
    private var listStack: NSStackView!
    private var plusButton: NSButton!
    private var countLabel: NSTextField!
    private var flash: NSTextField!
    private var closeButton: NSButton!

    func applicationDidFinishLaunching(_ note: Notification) {
        NSApp.setActivationPolicy(.accessory)   // no Dock icon, no menu bar

        panel = NSPanel(
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

        // Right-click anywhere to quit.
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Quit Clipstack", action: #selector(NSApp.terminate(_:)), keyEquivalent: "q"))
        backdrop.menu = menu

        buildViews(in: backdrop)
        render()          // render() parks it in `anchor` via resizePanel
        panel.orderFrontRegardless()

        if !registerHotKey(keyCode: hotKeyCode, modifiers: hotKeyMods, action: { [weak self] in
            self?.saveFromHotKey()
        }) {
            // Someone else owns the combo. Say so rather than failing silently.
            FileHandle.standardError.write("Clipstack: \(hotKeyHint) is already taken\n".data(using: .utf8)!)
            show(flash: "hotkey in use")
        }
    }

    private func buildViews(in container: NSView) {
        let grip = DragHandle()
        grip.image = NSImage(systemSymbolName: "line.3.horizontal", accessibilityDescription: "Drag to move")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold))
        grip.contentTintColor = NSColor.white.withAlphaComponent(0.45)
        grip.toolTip = "Drag to move"
        grip.menu = container.menu      // keep right-click-to-quit working over the grip
        // Airborne it belongs to no anchor, so nothing is squared off against an edge.
        grip.onDragStart = { [weak self] in
            self?.panel.contentView?.layer?.maskedCorners = Anchor.allCornersRounded
        }
        grip.onDrag = { [weak self] frame in self?.panel.setFrame(frame, display: true) }
        grip.onDragEnd = { [weak self] in self?.settle() }
        fix(grip, gripWidth, iconSide)

        closeButton = symbolButton("xmark", size: 11, describedAs: "Minimize",
                                   target: self, action: #selector(minimize))
        closeButton.toolTip = "Minimize"
        closeButton.contentTintColor = NSColor.white.withAlphaComponent(0.55)
        fix(closeButton, iconSide, iconSide)

        plusButton = symbolButton("plus.circle.fill", size: 16, target: self, action: #selector(saveClipboard))
        plusButton.toolTip = "Save what's on the clipboard  (\(hotKeyHint))"
        fix(plusButton, iconSide, iconSide)

        countLabel = label("", size: 11, alpha: 0.55)
        flash = label("", size: 11, alpha: 0.9)
        flash.alignment = .right
        flash.alphaValue = 0        // faded up by show(flash:)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)

        let header = NSStackView(views: [grip, plusButton, countLabel, spacer, flash, closeButton])
        header.orientation = .horizontal
        header.spacing = 8
        header.alignment = .centerY
        header.distribution = .fill

        listStack = NSStackView()
        listStack.orientation = .vertical
        listStack.spacing = 4
        listStack.alignment = .leading

        // List sits above the header so the pill itself stays put while the
        // panel grows upward off it.
        root = NSStackView(views: [listStack, header])
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
        ])
    }

    // MARK: Actions

    @objc private func minimize() { setExpanded(false) }

    private func setExpanded(_ on: Bool) {
        guard expanded != on else { return }
        expanded = on
        UserDefaults.standard.set(on, forKey: expandedKey)

        guard on else {
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

    /// The hotkey opens the shelf before saving: every scrap of feedback we have
    /// — the flash, the count, the new row — is hidden while collapsed, so
    /// saving without expanding would be completely silent.
    private func saveFromHotKey() {
        setExpanded(true)
        panel.orderFrontRegardless()
        saveClipboard()
    }

    @objc private func saveClipboard() {
        let pb = NSPasteboard.general
        let types = pb.types ?? []
        switch clipAction(concealed: types.contains(.concealed),
                          hasContents: !types.isEmpty,
                          string: pb.string(forType: .string)) {
        case .skip(let why):
            show(flash: why)
        case .save(let text):
            if store.add(text) { render(newRow: true) } else { show(flash: "already saved") }
        }
    }

    @objc private func copyRow(_ sender: NSButton) {
        guard store.items.indices.contains(sender.tag) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(store.items[sender.tag], forType: .string)
        show(flash: "copied")
    }

    @objc private func deleteRow(_ sender: NSButton) {
        store.remove(sender.tag)
        render()
    }

    private func show(flash text: String) {
        flash.stringValue = text
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            self.flash.animator().alphaValue = 1
        }
        // ponytail: token check beats cancelling a timer — later flashes just win.
        let token = text + String(Date().timeIntervalSince1970)
        flashToken = token
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { [weak self] in
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
    private var flashToken = ""
    /// The first layout has no previous frame to animate from.
    private var hasLaidOut = false

    // MARK: Render

    private func render(newRow: Bool = false) {
        listStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        plusButton.isHidden = !expanded
        flash.isHidden = !expanded
        listStack.isHidden = !expanded
        closeButton.isHidden = !expanded
        // Bare count when collapsed — it's all the pill has room to say.
        countLabel.stringValue = expanded ? "\(store.items.count)/\(maxItems)" : "\(store.items.count)"

        if expanded {
            if store.items.isEmpty {
                let hint = label("Copy something, then hit + or \(hotKeyHint)", size: 11, alpha: 0.45)
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
        let preview = label(text.replacingOccurrences(of: "\n", with: " "), size: 12, alpha: 0.92)
        // Low hugging = the label soaks up the spare width, so the buttons stay
        // pinned right instead of trailing short text.
        preview.setContentHuggingPriority(.defaultLow, for: .horizontal)
        preview.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let copy = symbolButton("doc.on.doc", size: 11, target: self, action: #selector(copyRow(_:)))
        copy.tag = index
        copy.toolTip = "Copy"
        fix(copy, 22, 20)

        let trash = symbolButton("xmark", size: 10, target: self, action: #selector(deleteRow(_:)))
        trash.tag = index
        trash.contentTintColor = NSColor.white.withAlphaComponent(0.45)
        trash.toolTip = "Delete"
        fix(trash, 18, 20)

        let stack = NSStackView(views: [preview, copy, trash])
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.alignment = .centerY
        // ponytail: NSStackView defaults to .gravityAreas, which pools slack at the
        // trailing edge and ignores hugging. .fill is what makes the label stretch.
        stack.distribution = .fill
        // ponytail: explicit row height — NSStackView.edgeInsets doesn't survive
        // being measured through a parent stack's fittingSize, rows come out 16pt.
        stack.toolTip = text        // on the row, not the click-through label
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 6)
        stack.heightAnchor.constraint(equalToConstant: rowHeight).isActive = true
        stack.wantsLayer = true
        stack.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.09).cgColor
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
        guard move != .cut else { return panel.setFrame(target, display: true) }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = move.duration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.panel.animator().setFrame(target, display: true)
            if move == .unfold { self.listStack.animator().alphaValue = 1 }
        }
    }

    /// The screen a point is over, so a drag can carry the pill to another display.
    private func area(under point: NSPoint) -> NSRect? {
        (NSScreen.screens.first { $0.frame.contains(point) } ?? panel.screen ?? NSScreen.main)?.visibleFrame
    }

    /// Let go: fall to the spot nearest wherever the pill was dropped, on whichever
    /// screen it was dropped on.
    private func settle() {
        let middle = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
        guard let area = area(under: middle) else { return }
        let landed = Anchor.nearest(to: panel.frame, in: area)
        place(landed.frame(for: panel.frame.size, in: area), on: landed, .settle)
        UserDefaults.standard.set(landed.rawValue, forKey: anchorKey)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
