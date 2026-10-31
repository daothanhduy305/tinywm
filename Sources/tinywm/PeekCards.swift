import AppKit
import QuartzCore
import WindowCore

/// Cards standing in for columns hidden beside another display.
/// A card shows the part of the window's picture that would be on screen at its place on the
/// strip, or a dark card with the app's icon and the window's title when there is no picture.
/// Clicking a card focuses its window.
@MainActor
final class PeekCards {
    var onClick: (String) -> Void = { _ in }

    private let pictures: WindowPictures
    private var panels: [String: (panel: NSPanel, card: WindowLayer)] = [:]
    private var peeks: [String: Rect] = [:]
    /// Where each window behind a card sits on the strip.
    private var windows: [String: Rect] = [:]
    private var hidden = false
    private var pump: Timer?

    init(pictures: WindowPictures) {
        self.pictures = pictures
        pictures.snapshots.onUpdate.append { [weak self] id in self?.pictureArrived(id) }
    }

    /// Shows a card at each frame (Accessibility coordinates), removing the rest. `windows`
    /// holds each window's full frame on the strip, to line its picture up with the card.
    func show(_ peeks: [String: Rect], windows: [String: Rect]) {
        self.peeks = peeks
        self.windows = windows
        refresh()
    }

    /// Hides the cards while motion pictures cover the screen. The overlay draws them among
    /// the pictures meanwhile, under the focus ring. Cards come back as the pictures start to
    /// fade, showing through them.
    func setHidden(_ on: Bool) {
        hidden = on
        refresh()
    }

    func close() { show([:], windows: [:]) }

    private func refresh() {
        let wanted = hidden ? [:] : peeks
        for (id, ui) in panels where wanted[id] == nil {
            ui.panel.orderOut(nil)
            panels[id] = nil
        }
        keepFresh(Set(wanted.keys))
        // No implicit animations: a card is in place the moment it shows.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        for (id, r) in wanted {
            let ui = panels[id] ?? make(id)
            panels[id] = ui
            ui.panel.setFrame(Screens.appKitRect(r), display: false)
            dress(ui.card, as: id, at: r)
            ui.panel.orderFrontRegardless()
        }
    }

    /// Shows the window's picture lined up with its place on the strip, or its dark card.
    private func dress(_ card: WindowLayer, as id: String, at r: Rect) {
        guard let surface = pictures.snapshots.surface(of: id), let w = windows[id] else {
            Self.dress(card, as: id, covers: pictures.covers)
            return
        }
        card.setPicture(surface, at: CGPoint(x: w.x - r.x, y: w.y - r.y))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        card.opacity = Self.opacity
        CATransaction.commit()
    }

    private func pictureArrived(_ id: String) {
        guard let ui = panels[id], let r = peeks[id] else { return }
        dress(ui.card, as: id, at: r)
    }

    /// Retakes the shown windows' pictures every second, so a card follows its app.
    /// ponytail: one still a second, not a stream; use `beginLive` if cards feel stale.
    private func keepFresh(_ ids: Set<String>) {
        pump?.invalidate()
        pump = nil
        guard !ids.isEmpty, !pictures.coverMode else { return }
        pictures.snapshots.refresh(ids)
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pictures.snapshots.refresh(ids) }
        }
        RunLoop.main.add(timer, forMode: .common)
        pump = timer
    }

    private func make(_ id: String) -> (panel: NSPanel, card: WindowLayer) {
        let p = CardPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        // Under the motion overlay, so a card shows through the pictures as they fade.
        p.level = .normal
        // On the strip's Space only, so a card slides away with it and never covers a fullscreen app.
        p.collectionBehavior = [.ignoresCycle, .stationary]
        p.animationBehavior = .none
        let view = ClickView()
        view.onClick = { [unowned self] in onClick(id) }
        view.wantsLayer = true
        let card = WindowLayer()
        card.frame = view.bounds
        card.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        view.layer?.addSublayer(card)
        p.contentView = view
        return (p, card)
    }

    /// Makes `card` the dark card for window `id`. `PictureMotion` draws the same during motion
    /// for a window with no picture.
    static func dress(_ card: WindowLayer, as id: String, covers: CoverArt) {
        let c = covers.cover(of: id)
        card.setCover(c.cover, icon: c.icon)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        card.backgroundColor = colour
        card.opacity = opacity
        CATransaction.commit()
    }

    static let opacity: Float = 1
    private static let colour = NSColor(white: 0.12, alpha: 1).cgColor

    /// A panel AppKit leaves where it is put, as `FocusHighlight` needs too.
    private final class CardPanel: NSPanel {
        override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    }

    /// Flipped like the motion overlay's view, so the card lays out its icon and title the same.
    private final class ClickView: NSView {
        var onClick: () -> Void = {}
        override var isFlipped: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) { onClick() }
    }
}
