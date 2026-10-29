import AppKit
import WindowCore

/// Shows a window's size briefly over its display.
@MainActor
final class SizeHUD {
    private let panel: NSPanel
    private let view = SizeHUDView(frame: NSRect(x: 0, y: 0, width: 180, height: 180))
    private let shareLabel = CATextLayer()
    private let pixelsLabel = CATextLayer()
    private var token = 0

    init() {
        panel = NSPanel(contentRect: view.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        view.wantsLayer = true
        let layer = view.layer!
        layer.backgroundColor = NSColor(white: 0.16, alpha: 1).cgColor
        layer.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor
        layer.borderWidth = 1
        layer.cornerRadius = 24
        layer.cornerCurve = .continuous
        shareLabel.font = NSFont.systemFont(ofSize: 44, weight: .bold)
        shareLabel.fontSize = 44
        shareLabel.foregroundColor = NSColor.white.cgColor
        shareLabel.alignmentMode = .center
        shareLabel.frame = CGRect(x: 0, y: 41, width: 180, height: 55)
        pixelsLabel.font = NSFont.systemFont(ofSize: 15)
        pixelsLabel.fontSize = 15
        pixelsLabel.foregroundColor = NSColor.white.withAlphaComponent(0.7).cgColor
        pixelsLabel.alignmentMode = .center
        pixelsLabel.frame = CGRect(x: 0, y: 108, width: 180, height: 22)
        layer.addSublayer(shareLabel)
        layer.addSublayer(pixelsLabel)
        panel.contentView = view
    }

    func show(share: Double, pixels: CGSize, on viewport: Rect) {
        token += 1
        let mine = token
        let frame = Screens.appKitRect(viewport)
        let center = NSPoint(x: frame.midX, y: frame.midY)
        let scale = NSScreen.screens.first(where: { $0.frame.contains(center) })?.backingScaleFactor ?? 1
        panel.setFrame(NSRect(x: center.x - 90, y: center.y - 90, width: 180, height: 180), display: false)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        view.layer?.removeAllAnimations()
        view.layer?.opacity = 1
        shareLabel.contentsScale = scale
        pixelsLabel.contentsScale = scale
        shareLabel.string = "\(Int((share * 100).rounded()))%"
        pixelsLabel.string = "\(Int(pixels.width.rounded())) × \(Int(pixels.height.rounded()))"
        CATransaction.commit()
        panel.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self, token == mine else { return }
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1
            fade.toValue = 0
            fade.duration = 0.2
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            view.layer?.opacity = 0
            view.layer?.add(fade, forKey: "fade")
            CATransaction.commit()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                guard let self, token == mine else { return }
                panel.orderOut(nil)
            }
        }
    }

    func hide() {
        token += 1
        view.layer?.removeAllAnimations()
        panel.orderOut(nil)
    }
}

private final class SizeHUDView: NSView {
    override var isFlipped: Bool { true }
}
