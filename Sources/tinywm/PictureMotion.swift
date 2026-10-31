import AppKit
import QuartzCore
import StripEngine
import WindowCore
import WindowKit

/// Pictures in motion: window pictures slide over the desktop picture while each
/// real window is written once underneath, and the pictures fade only after the windows landed.
@MainActor
final class PictureMotion: StripPresenter {
    /// Real windows are written 0.034 s after the pictures go up, so the pictures cover them first.
    let writeDelay = 0.034
    /// Gives up waiting 0.95 s after the motion settled, or 1.4 s after it began.
    var settleTimeout = 0.95
    var startTimeout = 1.4
    /// How long the pictures take to fade out.
    var fadeDuration = 0.2
    var stiffness = Spring.stiffness
    /// Told when pictures start covering the screen (true) and when they start fading (false).
    var onActive: (Bool) -> Void = { _ in }
    /// Told when pictures cover the screen (true) and once they are fully gone (false).
    var onCovering: (Bool) -> Void = { _ in }
    /// The focus border's look, and whether it is on. The ring in the pictures matches it.
    var ringStyle = FocusHighlight.Style()
    var showRing: () -> Bool = { true }

    private let snapshots: ScreenCaptureSnapshots
    /// Shows each window's picture, or its cover in cover mode.
    private let pictures: WindowPictures
    private let windows: AXWindows
    private let panel: NSPanel
    private let root = CALayer()
    private let backdrop = CALayer()
    private var layers: [String: WindowLayer] = [:]
    /// Peek cards, over the pictures and under the ring, as `PeekCards` shows them between motions.
    private var cards: [String: WindowLayer] = [:]
    /// Where the motion just begun takes each picture (overlay coordinates), for `showCards`.
    private var cardMoves: [String: (from: NSRect, to: NSRect)] = [:]
    /// The focus border drawn over the pictures.
    private let ring = CALayer()
    /// Where the ring was last sent, which is where the real border sits between motions.
    private var ringTarget: NSRect?
    /// The focused window the ring target belongs to.
    private var ringOwner: String?
    private var backdropURL: URL?
    private let meter = FrameMeter()

    private enum Phase {
        /// The panel is hidden.
        case idle
        /// Fingers or a drag place the pictures directly, and no motion has taken over yet.
        case previewing
        /// The pictures spring to their targets while the real windows are written underneath.
        case moving
        /// The panel fades out over the windows, which are in place.
        case fading
    }
    private var phase = Phase.idle
    /// True while the panel is up, in any phase but idle.
    private var active: Bool { phase != .idle }

    /// Counts motions. Each callback carries the token of the motion it belongs to, and one from
    /// an earlier motion is ignored.
    private var token = 0

    /// What one motion waits for before the pictures fade. `begin` starts a new one.
    private struct Motion {
        /// When the motion began, for the timings in the log; 0 once it has ended.
        var began: CFTimeInterval = 0
        var settledAt: Double?
        /// The windows the engine wrote, once it has written them all.
        var issued: Set<String>?
        var landed: Set<String> = []
        /// Resized windows still waiting for a picture at their new size.
        var needsPicture: Set<String> = []
        /// Final size, in points, of each window that changes size, to recognise its new picture.
        var targetSizes: [String: CGSize] = [:]
        /// Windows whose newest picture waits for the motion to end.
        var deferred: Set<String> = []
    }
    private var current = Motion()
    /// Pictures are retaken this often while anything moves. A motion lasts under half a
    /// second, so a picture taken as it begins stays good, and capturing more often costs drawing time.
    var motionRate = 4.0
    /// Pictures keep refreshing this long after motion ends, so quick repeated moves stay current.
    var liveLinger = 1.0

    /// The usable screen area in Accessibility coordinates; the pictures cover exactly this.
    var viewport = Rect(x: 0, y: 0, width: 1, height: 1) { didSet { place() } }
    /// The screen this overlay covers, for its desktop picture.
    var screen: () -> NSScreen? = { NSScreen.main }

    init(pictures: WindowPictures, windows: AXWindows) {
        self.pictures = pictures
        self.snapshots = pictures.snapshots
        self.windows = windows
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        panel.animationBehavior = .none
        panel.alphaValue = 0

        // A flipped view gives its layer a top-left origin, matching Accessibility coordinates.
        // Setting isGeometryFlipped on a view's own layer does not stick: AppKit resets it.
        let view = FlippedView()
        view.wantsLayer = true
        view.layer?.addSublayer(root)
        root.masksToBounds = true
        root.backgroundColor = NSColor(white: 0.12, alpha: 1).cgColor
        backdrop.contentsGravity = .resizeAspectFill
        root.addSublayer(backdrop)
        ring.zPosition = 10
        ring.isHidden = true
        root.addSublayer(ring)
        panel.contentView = view
        snapshots.onUpdate.append { [weak self] id in self?.pictureArrived(id) }
    }

    /// Just under opaque: macOS then still counts the windows behind the overlay as visible, so
    /// apps like Chromium keep drawing them and their pictures stay complete.
    static let coveringAlpha: CGFloat = 0.999

    /// Ends a motion still on screen as a fade would, since the fade's completion never runs
    /// once the overlay is gone, and covering would otherwise stay counted.
    func close() {
        if active {
            token += 1
            phase = .idle
            meter.stop(label)
            current = Motion()
            onActive(false)
            onCovering(false)
            snapshots.endLive(after: liveLinger)
        }
        panel.orderOut(nil)
    }

    // MARK: StripPresenter

    func begin(moves: [String: (from: Rect, to: Rect)], still: [String: Rect], focused: String?, lifted: String?) -> Int? {
        guard pictures.available else { return nil }
        current = Motion(began: CACurrentMediaTime())
        token += 1
        // A cover fits any size, so in cover mode no resized window waits for a new picture.
        if !pictures.coverMode {
            for (id, m) in moves where abs(m.from.width - m.to.width) > 1 || abs(m.from.height - m.to.height) > 1 {
                current.needsPicture.insert(id)
                current.targetSizes[id] = CGSize(width: m.to.width, height: m.to.height)
            }
        }

        // Pictures that a drag moved aside glide on from where they are, though their windows
        // are written without motion.
        var glides = moves
        if active {
            for (id, r) in still where moves[id] == nil {
                if let p = layers[id]?.presentation(), !p.frame.equalTo(local(r)) { glides[id] = (r, r) }
            }
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        refreshBackdrop()
        // A picture already in flight continues from where it is on screen.
        var start: [String: NSRect] = [:]
        var startScale: [String: CGFloat] = [:]
        for (id, m) in glides {
            if active, let layer = layers[id] {
                let p = phase == .previewing ? layer : layer.presentation() ?? layer
                start[id] = unscaled(p)
                startScale[id] = scale(of: p)
            } else {
                start[id] = local(m.from)
            }
        }
        let shown = Set(moves.keys).union(still.keys)
        for (id, layer) in layers where !shown.contains(id) {
            layer.removeFromSuperlayer()
            layers[id] = nil
        }
        for id in shown {
            let layer = layers[id] ?? makeLayer(id)
            layer.removeAllAnimations()
            layer.frame = start[id] ?? local(still[id]!)
            // The lifted picture travels over the others.
            layer.zPosition = id == lifted ? 1 : 0
            // The picture shows at its own size and is clipped, never stretched. A window that
            // changes size gets live pictures at its new size as soon as it has relaid out.
            pictures.show(id, on: layer, growingTo: current.targetSizes[id])
        }
        // The ring sits at the destination and only resizes, unless it follows a lifted window.
        let ringOpacity: Float = ring.isHidden ? 0 : (phase == .previewing ? ring.opacity : ring.presentation()?.opacity ?? ring.opacity)
        var ringTo: NSRect?
        if showRing(), let focused, let end = moves[focused]?.to ?? still[focused] {
            ringTo = outset(local(end))
            let from: NSRect
            if active, !ring.isHidden, let p = ring.presentation() { from = unscaled(p) }
            else if let last = ringTarget { from = last }
            else { from = outset(start[focused] ?? local(end)) }
            styleRing()
            ring.removeAllAnimations()
            ring.frame = from
            if focused != lifted, let ringTo {
                ring.position = NSPoint(x: ringTo.midX, y: ringTo.midY)
            }
            ring.isHidden = false
        } else if showRing(), ringOpacity > 0 {
            ring.frame = ring.presentation()?.frame ?? ring.frame
            ring.removeAllAnimations()
        } else {
            ring.removeAllAnimations()
            ring.isHidden = true
        }
        ring.opacity = ringOpacity
        CATransaction.commit()
        // The first frame on screen must already show the pictures, never an empty panel.
        CATransaction.flush()

        // A fade already reported the motion as over, so a motion that interrupts it starts a new one.
        if phase == .idle || phase == .fading { onActive(true) }
        if !active {
            panel.orderFrontRegardless()
            onCovering(true)
        }
        phase = .moving
        if let view = panel.contentView { meter.start(on: view) }
        // Cancels a fade still running from the previous motion.
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0
            panel.animator().alphaValue = Self.coveringAlpha
        }

        cardMoves = glides.reduce(into: [:]) { out, g in
            out[g.key] = (start[g.key] ?? local(g.value.from), local(g.value.to))
        }
        let motion = token
        CATransaction.begin()
        var longest: CFTimeInterval = 0
        for (id, m) in glides {
            guard let layer = layers[id] else { continue }
            let from = layer.frame
            let to = local(m.to)
            layer.frame = to
            let s = startScale[id] ?? 1
            let group: CAAnimationGroup
            if id == lifted {
                group = lift(from: from, to: to, scale: s)
                layer.followCover(from: from.size, to: to.size) { keyframes("position", [$0, $0, $1, $1]) }
            } else if lifted != nil {
                // The others slide at the same time, so the lifted picture passes over them.
                group = slide(from: from, to: to)
                layer.followCover(from: from.size, to: to.size) { keyframes("position", [$0, $0, $1, $1]) }
            } else {
                group = springs(from: from, to: to)
                layer.followCover(from: from.size, to: to.size) { spring("position", $0, $1) }
            }
            // A picture still shrunk from an interrupted lift grows back as it goes.
            if id != lifted, s < 1 {
                group.animations?.append(spring("transform.scale", NSNumber(value: Double(s)), NSNumber(value: 1)))
            }
            longest = max(longest, group.duration)
            layer.add(group, forKey: "move")
        }
        if let ringTo {
            let from = ring.frame
            ring.frame = ringTo
            if focused != nil, focused == lifted {
                let group = lift(from: from, to: ringTo)
                longest = max(longest, group.duration)
                ring.add(group, forKey: "move")
            } else if from.size != ringTo.size {
                let size = spring("bounds.size", NSValue(size: from.size), NSValue(size: ringTo.size))
                longest = max(longest, size.duration)
                ring.add(size, forKey: "move")
            }
            ringTarget = ringTo
            ringOwner = focused
        }
        CATransaction.setDisableActions(true)
        ring.opacity = ringTo == nil ? 0 : 1
        if !ring.isHidden, ringOpacity != ring.opacity {
            let opacity = spring("opacity", NSNumber(value: ringOpacity), NSNumber(value: ring.opacity))
            longest = max(longest, opacity.duration)
            ring.add(opacity, forKey: "opacity")
        }
        CATransaction.commit()
        snapshots.beginLive(shown, rate: motionRate)
        Log.note("motion", "\(label) begins \(moves.count) moves, \(shown.count) shown, \(pictures.coverMode ? "covers" : "pictures"); "
            + "setup \(ms(since: current.began)) ms, spring \(Int(longest * 1000)) ms")
        DispatchQueue.main.asyncAfter(deadline: .now() + longest) { [weak self] in
            MainActor.assumeIsolated { self?.settled(motion) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + startTimeout) { [weak self] in
            MainActor.assumeIsolated { self?.fade(motion, because: "start timeout") }
        }
        return motion
    }

    func preview(frames: [String: Rect], focused: String?, ring: (rect: Rect, opacity: Double)?) -> Bool {
        guard pictures.available else { return false }
        token += 1 // a fade or settle still pending from an earlier motion no longer applies
        // Once a drag is on screen, each frame only moves the pictures. Contact frames come
        // faster than the display, so this stays cheap and does not wait on the render server.
        if phase == .previewing, Set(frames.keys) == Set(layers.keys) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for (id, r) in frames {
                layers[id]?.removeAllAnimations()
                layers[id]?.frame = local(r)
            }
            previewRing(frames: frames, focused: focused, override: ring)
            CATransaction.commit()
            return true
        }
        // Cards stand still while fingers drag the strip, so they go until the strip settles.
        showCards([:])
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if !active { refreshBackdrop() }
        for (id, layer) in layers where frames[id] == nil {
            layer.removeFromSuperlayer()
            layers[id] = nil
        }
        for (id, r) in frames {
            let isNew = layers[id] == nil
            let layer = layers[id] ?? makeLayer(id)
            layer.removeAllAnimations()
            if isNew || !active { pictures.show(id, on: layer) }
            layer.frame = local(r)
        }
        previewRing(frames: frames, focused: focused, override: ring)
        CATransaction.commit()
        CATransaction.flush()
        if phase == .idle || phase == .fading { onActive(true) }
        if !active {
            panel.orderFrontRegardless()
            onCovering(true)
            snapshots.beginLive(Set(frames.keys), rate: motionRate)
        }
        phase = .previewing
        if let view = panel.contentView { meter.start(on: view) }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0
            panel.animator().alphaValue = Self.coveringAlpha
        }
        return true
    }

    private func previewRing(frames: [String: Rect], focused: String?, override: (rect: Rect, opacity: Double)?) {
        if showRing(), let focused, let r = override?.rect ?? frames[focused] {
            styleRing()
            ring.removeAllAnimations()
            if override == nil, let ringTarget, ringOwner == focused { ring.frame = ringTarget }
            else {
                ring.frame = outset(local(r))
                ringTarget = ring.frame
                ringOwner = focused
            }
            ring.opacity = Float(override?.opacity ?? 1)
            ring.isHidden = false
        } else {
            ring.isHidden = true
        }
    }

    func arrange(frames: [String: Rect]) -> Bool {
        guard phase == .previewing else { return preview(frames: frames, focused: nil) }
        token += 1 // a fade or settle still pending from an earlier motion no longer applies
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (id, layer) in layers where frames[id] == nil {
            layer.removeFromSuperlayer()
            layers[id] = nil
        }
        for (id, r) in frames {
            let to = local(r)
            guard let layer = layers[id] else {
                let layer = makeLayer(id)
                pictures.show(id, on: layer)
                layer.frame = to
                continue
            }
            let from = layer.presentation()?.frame ?? layer.frame
            layer.removeAnimation(forKey: "move")
            layer.frame = to
            if !from.equalTo(to) {
                layer.add(springs(from: from, to: to), forKey: "move")
                layer.followCover(from: from.size, to: to.size) { spring("position", $0, $1) }
            }
        }
        CATransaction.commit()
        return true
    }

    func endPreview() {
        guard phase == .previewing else { return }
        fade(token)
    }

    func writesIssued(_ ids: Set<String>, token: Int) {
        guard token == self.token else { return }
        current.issued = ids
        advance()
    }

    func landed(_ id: String, token: Int) {
        guard token == self.token else { return }
        current.landed.insert(id)
        // A resized window needs a fresh picture before the real one can show through cleanly.
        if current.needsPicture.contains(id) { snapshots.resize([id]) }
        advance()
    }

    /// A window written without motion may still show its old picture, taken before it moved.
    func wrote(_ id: String) {
        if !pictures.coverMode { snapshots.resize([id]) }
    }

    // MARK: Landing

    private func settled(_ motion: Int) {
        guard motion == token else { return }
        if ring.opacity == 0 { ring.isHidden = true }
        current.settledAt = CACurrentMediaTime()
        Log.note("motion", "\(label) settled after \(ms(since: current.began)) ms")
        let waiting = current.deferred
        current.deferred = []
        for id in waiting { pictureArrived(id) }
        advance()
        DispatchQueue.main.asyncAfter(deadline: .now() + settleTimeout) { [weak self] in
            MainActor.assumeIsolated { self?.fade(motion, because: "settle timeout") }
        }
    }

    /// New frames of a resizing window go straight onto its layer, so its new layout shows while
    /// it is still moving. Once a frame matches the final size, the landing can finish.
    private func pictureArrived(_ id: String) {
        if id == ScreenCaptureSnapshots.wallpaperID {
            if active { refreshBackdrop() }
            return
        }
        guard active, !pictures.coverMode, let layer = layers[id] else { return }
        let surface = snapshots.surface(of: id)
        // A shrinking window's new picture is smaller than its frame until the motion ends; the
        // old, larger picture keeps covering the frame until then.
        if current.settledAt == nil, let surface, layer.wouldLeaveGap(surface, growingTo: current.targetSizes[id]) {
            current.deferred.insert(id)
            return
        }
        layer.setPicture(surface, growingTo: current.targetSizes[id])
        guard current.needsPicture.contains(id) else { return }
        if current.landed.contains(id), let size = current.targetSizes[id], layer.pictureFits(size) {
            current.needsPicture.remove(id)
            advance()
        }
    }

    /// Fades once the motion settled, every written window landed, and resized ones were re-pictured.
    private func advance() {
        guard phase == .moving, current.settledAt != nil, let issued = current.issued, issued.isSubset(of: current.landed),
              current.needsPicture.isDisjoint(with: current.landed) else { return }
        fade(token, because: "landed")
    }

    private func fade(_ motion: Int, because reason: String = "preview ended") {
        guard active, motion == token else { return }
        if current.began > 0 {
            let waiting = current.needsPicture.isEmpty ? "" : ", still waiting for \(current.needsPicture.count) pictures"
            Log.note("motion", "\(label) fades after \(ms(since: current.began)) ms (\(reason)\(waiting))")
        }
        token += 1 // later callbacks for this motion are ignored
        let done = token
        phase = .fading
        // The real border moves under the pictures now, so it is in place as they fade.
        onActive(false)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = fadeDuration
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.token == done else { return }
                self.phase = .idle
                self.meter.stop(self.label)
                self.current = Motion()
                self.onCovering(false)
                self.snapshots.endLive(after: self.liveLinger)
            }
        })
    }

    private var label: String { screen()?.localizedName ?? "display" }

    private func ms(since t: CFTimeInterval) -> Int { Int((CACurrentMediaTime() - t) * 1000) }

    // MARK: Drawing

    private func spring(_ key: String, _ a: NSValue, _ b: NSValue) -> CASpringAnimation {
        Spring.critical(key, from: a, to: b, stiffness: stiffness)
    }

    private func springs(from: NSRect, to: NSRect) -> CAAnimationGroup {
        let move = spring("position", NSValue(point: NSPoint(x: from.midX, y: from.midY)),
                          NSValue(point: NSPoint(x: to.midX, y: to.midY)))
        let size = spring("bounds.size", NSValue(size: from.size), NSValue(size: to.size))
        let group = CAAnimationGroup()
        group.animations = [move, size]
        group.duration = max(move.duration, size.duration)
        return group
    }

    /// How far a lifted picture shrinks, and how long its shrink, slide and grow take together.
    static let liftScale: CGFloat = 0.9
    static let liftDuration: CFTimeInterval = 0.5

    /// Shrinks a picture where it is, slides it to `to`, then grows it back.
    private func lift(from: NSRect, to: NSRect, scale: CGFloat = 1) -> CAAnimationGroup {
        let small = Self.liftScale
        let group = slide(from: from, to: to)
        group.animations?.append(keyframes("transform.scale", [scale, small, small, 1].map { NSNumber(value: Double($0)) }))
        return group
    }

    /// Moves a picture to `to` in the slide step of a lift, holding still while the lifted one shrinks and grows.
    private func slide(from: NSRect, to: NSRect) -> CAAnimationGroup {
        let a = NSValue(point: NSPoint(x: from.midX, y: from.midY)), b = NSValue(point: NSPoint(x: to.midX, y: to.midY))
        let group = CAAnimationGroup()
        group.animations = [
            keyframes("position", [a, a, b, b]),
            keyframes("bounds.size", [from.size, from.size, to.size, to.size].map { NSValue(size: $0) }),
        ]
        group.duration = Self.liftDuration
        return group
    }

    /// Steps of a lift: shrink in the first fifth, slide until three quarters, then grow.
    private func keyframes(_ key: String, _ values: [Any]) -> CAKeyframeAnimation {
        let k = CAKeyframeAnimation(keyPath: key)
        k.values = values
        k.keyTimes = [0, 0.2, 0.75, 1]
        k.timingFunctions = [.init(name: .easeOut), .init(name: .easeInEaseOut), .init(name: .easeOut)]
        k.duration = Self.liftDuration
        return k
    }

    /// A layer's frame on screen without its scale, as a picture caught mid-lift has.
    private func unscaled(_ p: CALayer) -> NSRect {
        NSRect(x: p.position.x - p.bounds.width / 2, y: p.position.y - p.bounds.height / 2,
               width: p.bounds.width, height: p.bounds.height)
    }

    private func scale(of p: CALayer) -> CGFloat { (p.value(forKeyPath: "transform.scale") as? CGFloat) ?? 1 }

    /// The ring sits just outside the window, like the real border.
    private func outset(_ r: NSRect) -> NSRect { r.insetBy(dx: -ringStyle.borderWidth, dy: -ringStyle.borderWidth) }

    private func styleRing() {
        let color = ringStyle.color.cgColor
        ring.borderWidth = ringStyle.borderWidth
        ring.borderColor = color
        ring.cornerRadius = ringStyle.cornerRadius + ringStyle.borderWidth / 2
        ring.shadowColor = color
        ring.shadowOpacity = ringStyle.glowRadius > 0 ? 0.9 : 0
        ring.shadowRadius = ringStyle.glowRadius
        ring.shadowOffset = .zero
    }

    private func refreshBackdrop() {
        // The captured desktop is what is really on screen. The desktop picture's file can differ,
        // for example with dynamic or aerial wallpapers, so it is only a fallback until a capture exists.
        guard let screen = screen() else { return }
        if let id = Screens.displayID(of: screen), let captured = snapshots.wallpaper(of: id) {
            backdrop.contents = captured
            backdropURL = nil
            return
        }
        let url = NSWorkspace.shared.desktopImageURL(for: screen)
        guard url != backdropURL || backdrop.contents == nil else { return }
        backdropURL = url
        if let url, let image = NSImage(contentsOf: url),
           let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            backdrop.contents = cg
        }
    }

    /// Puts a peek card at each frame (Accessibility coordinates). The engine reports right
    /// after a motion begins. A card then covers just the on-screen part of its window's picture
    /// with the same spring: it fades in as the window slides behind it, and fades out as the
    /// window comes out, so the window and its card never seem to swap.
    /// A window with a picture needs no card here: its picture sits at its place on the strip and
    /// the overlay clips it to the screen, which is what the `PeekCards` panel shows too.
    func showCards(_ peeks: [String: Rect]) {
        let peeks = peeks.filter { snapshots.surface(of: $0.key) == nil }
        let moving = cardMoves
        cardMoves = [:]
        func onScreen(_ r: NSRect) -> NSRect {
            let c = r.intersection(root.bounds)
            return c.isNull || c.isEmpty ? r : c
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (id, card) in cards where peeks[id] == nil {
            cards[id] = nil
            guard let m = moving[id] else { card.removeFromSuperlayer(); continue }
            slide(card, from: card.presentation()?.frame ?? card.frame, to: onScreen(m.to), fade: (PeekCards.opacity, 0)) {
                card.removeFromSuperlayer()
            }
        }
        for (id, r) in peeks {
            let to = local(r)
            let card = cards[id] ?? WindowLayer()
            let isNew = cards[id] == nil
            if isNew {
                card.zPosition = 5
                root.addSublayer(card)
                cards[id] = card
            }
            PeekCards.dress(card, as: id, covers: pictures.covers)
            if let m = moving[id] {
                let from = isNew ? onScreen(m.from) : card.presentation()?.frame ?? card.frame
                slide(card, from: from, to: to, fade: isNew ? (0, PeekCards.opacity) : nil)
            } else {
                card.removeAllAnimations()
                card.frame = to
            }
        }
        CATransaction.commit()
    }

    /// Springs a card like a picture, fading it over the visible part of the motion.
    private func slide(_ card: WindowLayer, from: NSRect, to: NSRect, fade: (Float, Float)?,
                       then done: (@MainActor () -> Void)? = nil) {
        card.removeAllAnimations()
        card.frame = to
        let group = springs(from: from, to: to)
        card.add(group, forKey: "move")
        card.followCover(from: from.size, to: to.size) { spring("position", $0, $1) }
        if let (a, b) = fade {
            card.opacity = b
            let f = CABasicAnimation(keyPath: "opacity")
            f.fromValue = a
            f.toValue = b
            f.duration = group.duration * 0.6
            f.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            card.add(f, forKey: "fade")
        }
        if let done {
            DispatchQueue.main.asyncAfter(deadline: .now() + group.duration) { MainActor.assumeIsolated { done() } }
        }
    }

    private func makeLayer(_ id: String) -> WindowLayer {
        let layer = WindowLayer()
        root.addSublayer(layer)
        layers[id] = layer
        return layer
    }


    private func local(_ r: Rect) -> NSRect {
        NSRect(x: r.x - viewport.x, y: r.y - viewport.y, width: r.width, height: r.height)
    }

    /// Converts the Accessibility viewport (top-left origin) to an AppKit frame.
    private func place() {
        let frame = Screens.appKitRect(viewport)
        panel.setFrame(frame, display: false)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        root.frame = NSRect(origin: .zero, size: frame.size)
        // The desktop picture spans the whole screen, so offset it to line up with the real desktop.
        if let screen = screen() {
            let whole = Screens.axRect(screen.frame)
            backdrop.frame = NSRect(x: whole.x - viewport.x, y: whole.y - viewport.y, width: whole.width, height: whole.height)
        } else {
            backdrop.frame = root.bounds
        }
        CATransaction.commit()
    }
}

/// A view whose layer tree uses a top-left origin.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
