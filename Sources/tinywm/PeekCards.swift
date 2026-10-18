import AppKit
import QuartzCore
import WindowCore

/// Translucent cover cards standing in for columns hidden beside another display, as
/// `peek-cover = on` asks. Clicking a card focuses its window.
@MainActor
final class PeekCards {
    var onClick: (String) -> Void = { _ in }

    private let covers: CoverArt
    private var panels: [String: (panel: NSPanel, card: WindowLayer)] = [:]
    private var peeks: [String: Rect] = [:]
    private var hidden = false

    init(covers: CoverArt) { self.covers = covers }

    /// Shows a card at each frame (Accessibility coordinates), removing the rest.
    func show(_ peeks: [String: Rect]) {
        self.peeks = peeks
        refresh()
    }

    /// Hides the cards while motion pictures cover the screen. The window's picture stands at
    /// the card's spot meanwhile, so the focus ring can pass over it. Cards come back as the
    /// pictures start to fade, showing through them.
    func setHidden(_ on: Bool) {
        hidden = on
        refresh()
    }

    func close() { show([:]) }

    private func refresh() {
        let wanted = hidden ? [:] : peeks
        for (id, ui) in panels where wanted[id] == nil {
            ui.panel.orderOut(nil)
            panels[id] = nil
        }
        // No implicit animations: a card is in place the moment it shows.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        for (id, r) in wanted {
            let ui = panels[id] ?? make(id)
            panels[id] = ui
            let c = covers.cover(of: id)
            ui.card.setCover(c.cover, icon: c.icon)
            ui.card.backgroundColor = Self.colour
            ui.panel.setFrame(Screens.appKitRect(r), display: false)
            ui.panel.orderFrontRegardless()
        }
    }

    private func make(_ id: String) -> (panel: NSPanel, card: WindowLayer) {
        let p = CardPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        // Under the motion overlay, so a card shows through the pictures as they fade.
        p.level = .normal
        p.collectionBehavior = [.canJoinAllSpaces, .ignoresCycle, .stationary]
        p.animationBehavior = .none
        let view = ClickView()
        view.onClick = { [unowned self] in onClick(id) }
        view.wantsLayer = true
        let card = WindowLayer()
        card.opacity = 0.92
        card.frame = view.bounds
        card.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        view.layer?.addSublayer(card)
        p.contentView = view
        return (p, card)
    }

    private static let colour = NSColor(white: 0.12, alpha: 1).cgColor

    /// A panel AppKit leaves where it is put, as `FocusHighlight` needs too.
    private final class CardPanel: NSPanel {
        override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    }

    private final class ClickView: NSView {
        var onClick: () -> Void = {}
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) { onClick() }
    }
}
