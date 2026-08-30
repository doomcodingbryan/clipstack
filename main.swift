import AppKit
import Carbon.HIToolbox

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

func label(_ text: String, size: CGFloat, alpha: CGFloat = 1) -> NSTextField {
    let field = NSTextField(labelWithString: text)
    field.font = .systemFont(ofSize: size, weight: .regular)
    field.textColor = NSColor.white.withAlphaComponent(alpha)
    field.lineBreakMode = .byTruncatingTail
    field.maximumNumberOfLines = 1
    field.cell?.truncatesLastVisibleLine = true
    return field
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

let collapsedSize = NSSize(width: 52, height: 48)
let expandedWidth: CGFloat = 300
private let rowHeight: CGFloat = 26
private let iconSide: CGFloat = 28
private let expandedKey = "clipstack.expanded"
private let cornerKey = "clipstack.corner"
private let margin: CGFloat = 16
// Cmd+Shift+Ctrl+V. Cmd+Shift+V is Paste and Match Style, which is not ours to take.
private let hotKeyCode = UInt32(kVK_ANSI_V)
private let hotKeyMods = UInt32(cmdKey | shiftKey | controlKey)
private let hotKeyHint = "⌘⇧⌃V"

enum Corner: Int {
    case bottomLeft, bottomRight, topLeft, topRight

    var isLeft: Bool { self == .bottomLeft || self == .topLeft }
    var isBottom: Bool { self == .bottomLeft || self == .bottomRight }

    static func nearest(to frame: NSRect, in area: NSRect) -> Corner {
        switch (frame.midY < area.midY, frame.midX < area.midX) {
        case (true, true):   return .bottomLeft
        case (true, false):  return .bottomRight
        case (false, true):  return .topLeft
        case (false, false): return .topRight
        }
    }

    /// Where a panel of `size` sits when parked in this corner.
    func frame(for size: NSSize, in area: NSRect) -> NSRect {
        NSRect(
            x: isLeft ? area.minX + margin : area.maxX - size.width - margin,
            y: isBottom ? area.minY + bottomMargin : area.maxY - size.height - margin,
            width: size.width,
            height: size.height
        )
    }
}

/// visibleFrame already excludes a pinned Dock, but an auto-hidden one reserves
/// nothing and still draws above floating panels when revealed — so clear it.
private let bottomMargin: CGFloat = {
    let dock = UserDefaults(suiteName: "com.apple.dock")
    let hidden = dock?.bool(forKey: "autohide") ?? false
    let atBottom = (dock?.string(forKey: "orientation") ?? "bottom") == "bottom"
    return hidden && atBottom ? 80 : margin
}()

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
    // which is a valid Corner and would swallow the default.
    var corner = (UserDefaults.standard.object(forKey: cornerKey) as? Int)
        .flatMap(Corner.init(rawValue:)) ?? .bottomRight
    private var mouseUpMonitor: Any?
    /// Where resizePanel/snap last put the panel — the reference for "did it move?".
    private var parkedOrigin: NSPoint = .zero

    private var root: NSStackView!
    private var listStack: NSStackView!
    private var plusButton: NSButton!
    private var countLabel: NSTextField!
    private var flash: NSTextField!

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
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false

        let backdrop = NSVisualEffectView()
        backdrop.material = .hudWindow
        backdrop.blendingMode = .behindWindow
        backdrop.state = .active
        backdrop.wantsLayer = true
        backdrop.layer?.cornerRadius = 16
        backdrop.layer?.cornerCurve = .continuous
        backdrop.layer?.masksToBounds = true
        // Hairline edge so the pill reads against a dark wallpaper too.
        backdrop.layer?.borderWidth = 1
        backdrop.layer?.borderColor = NSColor(white: 1, alpha: 0.22).cgColor
        panel.contentView = backdrop

        // Right-click anywhere to quit.
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Quit Clipstack", action: #selector(NSApp.terminate(_:)), keyEquivalent: "q"))
        backdrop.menu = menu

        buildViews(in: backdrop)
        render()          // render() parks it in `corner` via resizePanel
        panel.orderFrontRegardless()

        if !registerHotKey(keyCode: hotKeyCode, modifiers: hotKeyMods, action: { [weak self] in
            self?.saveFromHotKey()
        }) {
            // Someone else owns the combo. Say so rather than failing silently.
            FileHandle.standardError.write("Clipstack: \(hotKeyHint) is already taken\n".data(using: .utf8)!)
            show(flash: "hotkey in use")
        }

        // Drag freely, snap on release. There's no windowDidEndMove callback, so
        // the mouse-up is the drag-end signal.
        mouseUpMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] event in
            // Fires on every click in the app, not just drags, so only do the
            // work when the panel has actually left where we parked it.
            if let self, self.panel.frame.origin != self.parkedOrigin {
                self.snapToNearestCorner()
            }
            return event
        }
    }

    private func buildViews(in container: NSView) {
        let toggle = symbolButton("list.clipboard.fill", size: 15,
                                  describedAs: "Show or hide saved clips",
                                  target: self, action: #selector(toggleExpanded))
        toggle.toolTip = "Show or hide saved clips"
        fix(toggle, iconSide, iconSide)

        plusButton = symbolButton("plus.circle.fill", size: 16, target: self, action: #selector(saveClipboard))
        plusButton.toolTip = "Save what's on the clipboard  (\(hotKeyHint))"
        fix(plusButton, iconSide, iconSide)

        countLabel = label("", size: 11, alpha: 0.55)
        flash = label("", size: 11, alpha: 0.9)
        flash.alignment = .right

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)

        let header = NSStackView(views: [toggle, plusButton, countLabel, spacer, flash])
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

    @objc private func toggleExpanded() { setExpanded(!expanded) }

    private func setExpanded(_ on: Bool) {
        guard expanded != on else { return }
        expanded = on
        UserDefaults.standard.set(on, forKey: expandedKey)
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
            if store.add(text) { render() } else { show(flash: "already saved") }
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
        // ponytail: token check beats cancelling a timer — later flashes just win.
        let token = text + String(Date().timeIntervalSince1970)
        flashToken = token
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { [weak self] in
            guard let self, self.flashToken == token else { return }
            self.flash.stringValue = ""
        }
    }
    private var flashToken = ""

    // MARK: Render

    private func render() {
        listStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        plusButton.isHidden = !expanded
        countLabel.isHidden = !expanded
        flash.isHidden = !expanded
        listStack.isHidden = !expanded

        if expanded {
            countLabel.stringValue = "\(store.items.count)/\(maxItems)"

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

        resizePanel()
    }

    private func row(index: Int, text: String) -> NSView {
        let preview = label(text.replacingOccurrences(of: "\n", with: " "), size: 12, alpha: 0.92)
        preview.toolTip = text
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
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 6)
        stack.heightAnchor.constraint(equalToConstant: rowHeight).isActive = true
        stack.wantsLayer = true
        stack.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.09).cgColor
        stack.layer?.cornerRadius = 7
        stack.layer?.cornerCurve = .continuous
        return stack
    }

    /// Resizes in place and re-parks in the current corner, so the panel grows
    /// away from whichever screen edges it's pinned to.
    private func resizePanel() {
        let width = expanded ? expandedWidth : collapsedSize.width

        // Width has to land before measuring: fittingSize asks the labels how tall
        // they are at the *current* width, and at the collapsed 52pt they all lie.
        panel.setFrame(NSRect(origin: panel.frame.origin, size: NSSize(width: width, height: panel.frame.height)),
                       display: false)
        panel.layoutIfNeeded()

        let height = expanded
            ? max(collapsedSize.height, root.fittingSize.height)
            : collapsedSize.height

        guard let area = visibleArea else { return }
        let target = corner.frame(for: NSSize(width: width, height: height), in: area)
        panel.setFrame(target, display: true)
        parkedOrigin = target.origin
    }

    private var visibleArea: NSRect? { (panel.screen ?? NSScreen.main)?.visibleFrame }

    private func snapToNearestCorner() {
        guard let area = visibleArea else { return }
        let landed = Corner.nearest(to: panel.frame, in: area)
        if landed != corner {
            corner = landed
            UserDefaults.standard.set(landed.rawValue, forKey: cornerKey)
        }
        let target = landed.frame(for: panel.frame.size, in: area)
        if target != panel.frame { panel.setFrame(target, display: true, animate: true) }
        parkedOrigin = target.origin
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
