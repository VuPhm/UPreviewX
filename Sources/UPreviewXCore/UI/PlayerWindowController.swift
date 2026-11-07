import AppKit

/// Custom `NSWindow` that forwards media playback keyboard shortcuts directly to the controller.
public final class PlayerWindow: NSWindow {
    public var onKeyShortcut: ((NSEvent) -> Bool)?

    public override var canBecomeKey: Bool { true }
    public override var canBecomeMain: Bool { true }

    public override func keyDown(with event: NSEvent) {
        if onKeyShortcut?(event) == true {
            return
        }
        super.keyDown(with: event)
    }
}

/// Native macOS video preview window controller with adaptive aspect-ratio sizing.
public final class PlayerWindowController: NSWindowController, NSWindowDelegate, PlaybackEngineDelegate {
    public let engine: MPVPlaybackEngine
    public let videoView: MPVVideoView
    public let hudView = HUDControlsView()
    public let diagnosticsView = DiagnosticsOverlayView()

    public var onWindowWillClose: ((PlayerWindowController) -> Void)?
    public var onFirstFrameRendered: ((PlaybackDiagnostics) -> Void)?

    private var hideControlsTimer: Timer?
    private var diagnosticsTimer: Timer?
    private var initialRevealTimer: Timer?
    private var trackingArea: NSTrackingArea?
    private var lastAppliedVideoSize: CGSize = .zero
    private var userDidManuallyResizeWindow = false
    private var isProgrammaticWindowResize = false
    private var isFullscreen = false
    private var isControlsHidden = false

    public init(showDiagnostics: Bool = false) {
        let playbackEngine = MPVPlaybackEngine()
        self.engine = playbackEngine
        self.videoView = MPVVideoView(engine: playbackEngine)

        let initialRect = NSRect(x: 0, y: 0, width: 640, height: 480)
        let style: NSWindow.StyleMask = [
            .titled,
            .closable,
            .miniaturizable,
            .resizable,
            .fullSizeContentView
        ]
        let win = PlayerWindow(
            contentRect: initialRect,
            styleMask: style,
            backing: .buffered,
            defer: false
        )
        win.title = "UPreviewX"
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .visible
        win.isMovableByWindowBackground = true
        win.backgroundColor = .black
        win.appearance = NSAppearance(named: .darkAqua)
        // Compact minSize so narrow 9:16 portrait windows are never forced wide
        win.minSize = NSSize(width: 210, height: 210)
        win.collectionBehavior = [.fullScreenPrimary, .managed]
        win.isReleasedWhenClosed = false
        // Start transparent until video geometry arrives so vertical videos never flash in a 16:9 frame
        win.alphaValue = 0.0
        win.center()

        super.init(window: win)
        win.delegate = self
        playbackEngine.delegate = self

        setupUI(in: win, showDiagnostics: showDiagnostics)
        try? playbackEngine.initialize()
    }

    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupUI(in win: PlayerWindow, showDiagnostics: Bool) {
        let container = NSView(frame: win.contentView?.bounds ?? .zero)
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.cgColor
        container.autoresizingMask = [.width, .height]
        win.contentView = container

        videoView.frame = container.bounds
        videoView.autoresizingMask = [.width, .height]
        videoView.onDoubleClick = { [weak self] in
            self?.toggleFullscreen()
        }
        container.addSubview(videoView)

        // HUD Controls: overlaid compactly on video, adaptable to narrow portrait windows
        hudView.translatesAutoresizingMaskIntoConstraints = false
        hudView.onPlayPause = { [weak self] in
            self?.engine.togglePlayPause()
            self?.resetAutoHideTimer()
        }
        hudView.onSeek = { [weak self] seconds, exact in
            self?.engine.seek(to: seconds, exact: exact)
            self?.resetAutoHideTimer()
        }
        hudView.onMuteToggle = { [weak self] in
            self?.engine.toggleMute()
            self?.resetAutoHideTimer()
        }
        hudView.onVolumeChange = { [weak self] vol in
            self?.engine.setVolume(vol)
            self?.resetAutoHideTimer()
        }
        hudView.onToggleDiagnostics = { [weak self] in
            self?.toggleDiagnosticsOverlay()
            self?.resetAutoHideTimer()
        }
        hudView.onToggleFullscreen = { [weak self] in
            self?.toggleFullscreen()
        }
        container.addSubview(hudView)

        // Diagnostics Overlay
        diagnosticsView.translatesAutoresizingMaskIntoConstraints = false
        diagnosticsView.isHidden = !showDiagnostics
        container.addSubview(diagnosticsView)

        let preferredHUDWidth = hudView.widthAnchor.constraint(equalToConstant: 500)
        preferredHUDWidth.priority = .defaultLow

        NSLayoutConstraint.activate([
            hudView.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            hudView.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16),
            preferredHUDWidth,
            hudView.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 12),
            hudView.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -12),
            hudView.heightAnchor.constraint(equalToConstant: 38),

            diagnosticsView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            diagnosticsView.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -12),
            diagnosticsView.topAnchor.constraint(equalTo: container.topAnchor, constant: 34)
        ])

        win.onKeyShortcut = { [weak self] event in
            self?.handleKeyDown(event) ?? false
        }

        installMouseTracking(on: container)
        if showDiagnostics {
            startDiagnosticsTimer()
        }
        resetAutoHideTimer()
    }

    private func installMouseTracking(on view: NSView) {
        let options: NSTrackingArea.Options = [
            .mouseMoved,
            .mouseEnteredAndExited,
            .activeAlways,
            .inVisibleRect
        ]
        let area = NSTrackingArea(rect: view.bounds, options: options, owner: self, userInfo: nil)
        view.addTrackingArea(area)
        trackingArea = area
    }

    // MARK: - Adaptive Window Geometry Calculation

    /// Calculates an aspect-accurate, centered window frame constrained to the screen's `visibleFrame`
    /// (which excludes the macOS menu bar and Dock).
    /// Supports portrait (9:16, 4:5), square (1:1), and landscape (16:9, 21:9) video dimensions.
    public static func calculateTargetWindowFrame(
        for videoDisplaySize: CGSize,
        in visibleFrame: NSRect
    ) -> NSRect {
        guard videoDisplaySize.width > 0, videoDisplaySize.height > 0 else {
            return visibleFrame
        }

        let maxW = floor(visibleFrame.width * 0.90)
        let maxH = floor(visibleFrame.height * 0.88)
        let aspect = videoDisplaySize.width / videoDisplaySize.height

        var targetW = videoDisplaySize.width
        var targetH = videoDisplaySize.height

        // Constrain oversized dimensions while preserving exact display aspect ratio
        if targetW > maxW {
            targetW = maxW
            targetH = (targetW / aspect).rounded()
        }
        if targetH > maxH {
            targetH = maxH
            targetW = (targetH * aspect).rounded()
        }

        // Enforce a sensible minimum preview size while strictly preserving aspect ratio
        let minShortEdge: CGFloat = 240.0
        if min(targetW, targetH) < minShortEdge {
            if aspect >= 1.0 {
                targetH = min(maxH, minShortEdge)
                targetW = min(maxW, (targetH * aspect).rounded())
            } else {
                targetW = min(maxW, minShortEdge)
                targetH = min(maxH, (targetW / aspect).rounded())
            }
        }

        let originX = (visibleFrame.origin.x + (visibleFrame.width - targetW) / 2.0).rounded()
        let originY = (visibleFrame.origin.y + (visibleFrame.height - targetH) / 2.0).rounded()
        return NSRect(x: originX, y: originY, width: targetW, height: targetH)
    }

    private func applyAdaptiveWindowSize(_ size: CGSize) {
        guard size.width > 0 && size.height > 0, let win = window else { return }

        // Lock window frame aspect ratio (matches fullSizeContentView viewport)
        win.aspectRatio = size

        guard !isFullscreen, !userDidManuallyResizeWindow else {
            revealWindowIfNeeded()
            return
        }

        guard size != lastAppliedVideoSize else {
            revealWindowIfNeeded()
            return
        }
        lastAppliedVideoSize = size

        let screenVisible = (win.screen ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let targetFrame = Self.calculateTargetWindowFrame(for: size, in: screenVisible)

        isProgrammaticWindowResize = true
        win.setFrame(targetFrame, display: true, animate: false)
        isProgrammaticWindowResize = false

        revealWindowIfNeeded()
    }

    private func revealWindowIfNeeded() {
        initialRevealTimer?.invalidate()
        initialRevealTimer = nil
        if let win = window, win.alphaValue < 1.0 {
            win.alphaValue = 1.0
        }
    }

    // MARK: - Public Actions

    public func openMedia(url: URL) {
        lastAppliedVideoSize = .zero
        userDidManuallyResizeWindow = false
        updateWindowTitle(for: url)
        window?.representedURL = url
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Force immediate CGLContext and mpv_render_context creation before loading the file
        videoView.videoLayer.display()

        // Fallback timer to reveal window if an audio-only or broken file produces no video reconfig
        initialRevealTimer?.invalidate()
        initialRevealTimer = Timer.scheduledTimer(withTimeInterval: 0.18, repeats: false) { [weak self] _ in
            self?.revealWindowIfNeeded()
        }

        do {
            try engine.load(url: url)
            resetAutoHideTimer()
        } catch let error as PlaybackEngineError {
            revealWindowIfNeeded()
            presentErrorAlert(error)
        } catch {
            revealWindowIfNeeded()
            presentErrorAlert(.loadFailed(error.localizedDescription))
        }
    }

    public func toggleFullscreen() {
        window?.toggleFullScreen(nil)
    }

    public func toggleDiagnosticsOverlay() {
        diagnosticsView.isHidden.toggle()
        if !diagnosticsView.isHidden {
            engine.refreshDiagnostics()
            startDiagnosticsTimer()
        } else {
            stopDiagnosticsTimer()
        }
    }

    public func toggleFastPreviewMode() {
        engine.toggleFastPreviewMode()
        if let url = engine.currentURL {
            updateWindowTitle(for: url)
        }
    }

    private func updateWindowTitle(for url: URL) {
        let suffix = engine.isFastPreviewMode ? " — [Fast Preview]" : ""
        window?.title = url.lastPathComponent + suffix
    }

    // MARK: - Keyboard Shortcuts

    private func handleKeyDown(_ event: NSEvent) -> Bool {
        showControlsImmediately()
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        if flags.contains(.command) {
            if event.charactersIgnoringModifiers?.lowercased() == "i" {
                toggleDiagnosticsOverlay()
                return true
            }
            return false
        }

        switch event.keyCode {
        case 49: // Space
            engine.togglePlayPause()
            return true
        case 123: // Left Arrow
            let exact = flags.contains(.shift)
            let step = exact ? -1.0 : -5.0
            engine.seekRelative(step, exact: exact)
            return true
        case 124: // Right Arrow
            let exact = flags.contains(.shift)
            let step = exact ? 1.0 : 5.0
            engine.seekRelative(step, exact: exact)
            return true
        case 126: // Up Arrow
            engine.setVolume(engine.volume + 5.0)
            return true
        case 125: // Down Arrow
            engine.setVolume(engine.volume - 5.0)
            return true
        case 46: // M
            engine.toggleMute()
            return true
        case 3: // F
            toggleFullscreen()
            return true
        case 2: // D
            toggleDiagnosticsOverlay()
            return true
        case 35: // P
            toggleFastPreviewMode()
            return true
        case 53: // Escape
            if isFullscreen {
                toggleFullscreen()
                return true
            }
            return false
        default:
            return false
        }
    }

    // MARK: - Auto-Hiding Unobtrusive Controls

    public override func mouseMoved(with event: NSEvent) {
        showControlsImmediately()
    }

    public override func mouseEntered(with event: NSEvent) {
        showControlsImmediately()
    }

    private func showControlsImmediately() {
        if isControlsHidden {
            isControlsHidden = false
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                hudView.animator().alphaValue = 1.0
                setTitlebarButtonsAlpha(1.0)
            }
        }
        resetAutoHideTimer()
    }

    private func resetAutoHideTimer() {
        hideControlsTimer?.invalidate()
        guard !engine.isPaused else { return }
        hideControlsTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { [weak self] _ in
            self?.hideControlsIfAppropriate()
        }
    }

    private func hideControlsIfAppropriate() {
        guard !engine.isPaused, !hudView.timelineSlider.isUserScrubbing else { return }
        if let win = window, let contentView = win.contentView {
            let mouseInWindow = win.mouseLocationOutsideOfEventStream
            let mouseInHUD = hudView.convert(mouseInWindow, from: nil)
            if hudView.bounds.contains(mouseInHUD) && contentView.bounds.contains(mouseInWindow) {
                resetAutoHideTimer()
                return
            }
        }
        isControlsHidden = true
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.28
            hudView.animator().alphaValue = 0.0
            setTitlebarButtonsAlpha(0.0)
        }
    }

    private func setTitlebarButtonsAlpha(_ alpha: CGFloat) {
        guard let win = window else { return }
        win.standardWindowButton(.closeButton)?.animator().alphaValue = alpha
        win.standardWindowButton(.miniaturizeButton)?.animator().alphaValue = alpha
        win.standardWindowButton(.zoomButton)?.animator().alphaValue = alpha
    }

    private func startDiagnosticsTimer() {
        stopDiagnosticsTimer()
        diagnosticsTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.engine.refreshDiagnostics()
        }
    }

    private func stopDiagnosticsTimer() {
        diagnosticsTimer?.invalidate()
        diagnosticsTimer = nil
    }

    // MARK: - PlaybackEngineDelegate

    public func playbackEngineDidLoadFile(_ engine: PlaybackEngineProtocol) {
        hudView.updatePosition(engine.position, duration: engine.duration)
        hudView.updatePauseState(isPaused: engine.isPaused)
        hudView.updateVolume(engine.volume, isMuted: engine.isMuted)
        diagnosticsView.update(with: engine.diagnostics)
    }

    public func playbackEngineDidRenderFirstFrame(_ engine: PlaybackEngineProtocol, latencyMs: Double) {
        revealWindowIfNeeded()
        diagnosticsView.update(with: engine.diagnostics)
        onFirstFrameRendered?(engine.diagnostics)
    }

    public func playbackEngine(_ engine: PlaybackEngineProtocol, didUpdatePosition position: Double, duration: Double) {
        hudView.updatePosition(position, duration: duration)
    }

    public func playbackEngine(_ engine: PlaybackEngineProtocol, didUpdatePause isPaused: Bool) {
        hudView.updatePauseState(isPaused: isPaused)
        if isPaused {
            showControlsImmediately()
        } else {
            resetAutoHideTimer()
        }
    }

    public func playbackEngine(_ engine: PlaybackEngineProtocol, didUpdateVolume volume: Double, isMuted: Bool) {
        hudView.updateVolume(volume, isMuted: isMuted)
    }

    public func playbackEngine(_ engine: PlaybackEngineProtocol, didUpdateVideoSize size: CGSize) {
        applyAdaptiveWindowSize(size)
    }

    public func playbackEngine(_ engine: PlaybackEngineProtocol, didCompleteSeek latencyMs: Double) {
        diagnosticsView.update(with: engine.diagnostics)
    }

    public func playbackEngine(_ engine: PlaybackEngineProtocol, didUpdateDiagnostics diagnostics: PlaybackDiagnostics) {
        diagnosticsView.update(with: diagnostics)
    }

    public func playbackEngine(_ engine: PlaybackEngineProtocol, didEncounterError error: PlaybackEngineError) {
        revealWindowIfNeeded()
        presentErrorAlert(error)
    }

    public func playbackEngineDidReachEndOfFile(_ engine: PlaybackEngineProtocol) {
        showControlsImmediately()
    }

    private func presentErrorAlert(_ error: PlaybackEngineError) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Cannot Open Video"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "OK")
        if let win = window, win.isVisible {
            alert.beginSheetModal(for: win)
        } else {
            alert.runModal()
        }
    }

    // MARK: - NSWindowDelegate

    public func windowWillStartLiveResize(_ notification: Notification) {
        if !isProgrammaticWindowResize && !isFullscreen {
            userDidManuallyResizeWindow = true
        }
    }

    public func windowDidEnterFullScreen(_ notification: Notification) {
        isFullscreen = true
        hudView.updateFullscreenState(isFullscreen: true)
    }

    public func windowDidExitFullScreen(_ notification: Notification) {
        isFullscreen = false
        hudView.updateFullscreenState(isFullscreen: false)
    }

    public func windowWillClose(_ notification: Notification) {
        initialRevealTimer?.invalidate()
        initialRevealTimer = nil
        hideControlsTimer?.invalidate()
        hideControlsTimer = nil
        stopDiagnosticsTimer()
        engine.shutdown()
        onWindowWillClose?(self)
    }
}
