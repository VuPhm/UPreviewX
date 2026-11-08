import AppKit

/// Custom `NSWindow` that forwards media playback keyboard shortcuts directly to the controller.
public final class PlayerWindow: NSWindow {
    public var onKeyShortcut: ((NSEvent) -> Bool)?
    public var onKeyUp: ((NSEvent) -> Bool)?

    public override var canBecomeKey: Bool { true }
    public override var canBecomeMain: Bool { true }

    public override func keyDown(with event: NSEvent) {
        if onKeyShortcut?(event) == true {
            return
        }
        super.keyDown(with: event)
    }

    public override func keyUp(with event: NSEvent) {
        if onKeyUp?(event) == true {
            return
        }
        super.keyUp(with: event)
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

    // Safe Shuttle State
    private enum ShuttleDirection {
        case forward
        case rewind
    }

    private struct ShuttleSession {
        let direction: ShuttleDirection
        let wasPaused: Bool
        let originalSpeed: Double
        let isKeyframeSeeking: Bool
    }

    private var activeShuttleSession: ShuttleSession?
    private var shuttleHoldTimer: Timer?
    private var shuttleSeekTimer: Timer?
    private var pendingShuttleDirection: ShuttleDirection?

    // Subtle Visual Indicators
    private let shuttleBadgeView = NSVisualEffectView()
    private let shuttleBadgeLabel = NSTextField(labelWithString: "")

    private let toastView = NSVisualEffectView()
    private let toastLabel = NSTextField(labelWithString: "")
    private var toastDismissTimer: Timer?
    private var toastActionURL: URL?

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
        videoView.onContextMenuRequested = { [weak self] _ in
            self?.buildContextMenu()
        }
        container.addSubview(videoView)

        // HUD Controls: overlaid compactly on video, adaptable to narrow portrait windows
        hudView.translatesAutoresizingMaskIntoConstraints = false
        hudView.onRewind = { [weak self] in
            self?.engine.seekRelative(-5.0, exact: false)
            self?.resetAutoHideTimer()
        }
        hudView.onPlayPause = { [weak self] in
            self?.engine.togglePlayPause()
            self?.resetAutoHideTimer()
        }
        hudView.onFastForward = { [weak self] in
            self?.engine.seekRelative(5.0, exact: false)
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
        hudView.onCaptureFrame = { [weak self] in
            self?.captureCurrentFrame()
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

        // Subtle Temporary Shuttle Badge
        shuttleBadgeView.translatesAutoresizingMaskIntoConstraints = false
        shuttleBadgeView.material = .hudWindow
        shuttleBadgeView.blendingMode = .withinWindow
        shuttleBadgeView.state = .active
        shuttleBadgeView.wantsLayer = true
        shuttleBadgeView.layer?.cornerRadius = 14
        shuttleBadgeView.layer?.masksToBounds = true
        shuttleBadgeView.layer?.borderWidth = 0.5
        shuttleBadgeView.layer?.borderColor = NSColor.white.withAlphaComponent(0.20).cgColor
        shuttleBadgeView.alphaValue = 0.0

        shuttleBadgeLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .bold)
        shuttleBadgeLabel.textColor = .white
        shuttleBadgeLabel.alignment = .center
        shuttleBadgeLabel.translatesAutoresizingMaskIntoConstraints = false
        shuttleBadgeView.addSubview(shuttleBadgeLabel)
        container.addSubview(shuttleBadgeView)

        // Subtle Toast Notification Pill
        toastView.translatesAutoresizingMaskIntoConstraints = false
        toastView.material = .hudWindow
        toastView.blendingMode = .withinWindow
        toastView.state = .active
        toastView.wantsLayer = true
        toastView.layer?.cornerRadius = 14
        toastView.layer?.masksToBounds = true
        toastView.layer?.borderWidth = 0.5
        toastView.layer?.borderColor = NSColor.white.withAlphaComponent(0.20).cgColor
        toastView.alphaValue = 0.0

        toastLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        toastLabel.textColor = .white
        toastLabel.alignment = .center
        toastLabel.translatesAutoresizingMaskIntoConstraints = false
        toastView.addSubview(toastLabel)
        container.addSubview(toastView)

        let toastClick = NSClickGestureRecognizer(target: self, action: #selector(handleToastClicked))
        toastView.addGestureRecognizer(toastClick)

        // Diagnostics Overlay
        diagnosticsView.translatesAutoresizingMaskIntoConstraints = false
        diagnosticsView.isHidden = !showDiagnostics
        container.addSubview(diagnosticsView)

        let preferredHUDWidth = hudView.widthAnchor.constraint(equalToConstant: 530)
        preferredHUDWidth.priority = .defaultLow

        NSLayoutConstraint.activate([
            hudView.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            hudView.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16),
            preferredHUDWidth,
            hudView.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 12),
            hudView.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -12),
            hudView.heightAnchor.constraint(equalToConstant: 38),

            shuttleBadgeView.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            shuttleBadgeView.bottomAnchor.constraint(equalTo: hudView.topAnchor, constant: -10),
            shuttleBadgeView.heightAnchor.constraint(equalToConstant: 28),
            shuttleBadgeLabel.leadingAnchor.constraint(equalTo: shuttleBadgeView.leadingAnchor, constant: 14),
            shuttleBadgeLabel.trailingAnchor.constraint(equalTo: shuttleBadgeView.trailingAnchor, constant: -14),
            shuttleBadgeLabel.centerYAnchor.constraint(equalTo: shuttleBadgeView.centerYAnchor),

            toastView.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            toastView.topAnchor.constraint(equalTo: container.topAnchor, constant: 36),
            toastView.heightAnchor.constraint(equalToConstant: 28),
            toastView.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 16),
            toastView.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -16),
            toastLabel.leadingAnchor.constraint(equalTo: toastView.leadingAnchor, constant: 14),
            toastLabel.trailingAnchor.constraint(equalTo: toastView.trailingAnchor, constant: -14),
            toastLabel.centerYAnchor.constraint(equalTo: toastView.centerYAnchor),

            diagnosticsView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            diagnosticsView.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -12),
            diagnosticsView.topAnchor.constraint(equalTo: container.topAnchor, constant: 34)
        ])

        win.onKeyShortcut = { [weak self] event in
            self?.handleKeyDown(event) ?? false
        }
        win.onKeyUp = { [weak self] event in
            self?.handleKeyUp(event) ?? false
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppDidResignActive),
            name: NSApplication.didResignActiveNotification,
            object: nil
        )

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

        guard UserSettings.shared.fitWindowToAspectRatio else {
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

        let targetFrame: NSRect
        if UserSettings.shared.rememberLastWindowSize {
            let lastSize = UserSettings.shared.lastWindowSize
            let aspect = size.width / size.height
            let adjustedHeight = max(240, (lastSize.width / aspect).rounded())
            let originX = (screenVisible.origin.x + (screenVisible.width - lastSize.width) / 2.0).rounded()
            let originY = (screenVisible.origin.y + (screenVisible.height - adjustedHeight) / 2.0).rounded()
            targetFrame = NSRect(x: originX, y: originY, width: lastSize.width, height: adjustedHeight)
        } else {
            targetFrame = Self.calculateTargetWindowFrame(for: size, in: screenVisible)
        }

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
        endShuttle(restoreOriginalState: false)
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
            if !UserSettings.shared.autoResumePlaybackOnOpen {
                engine.pause()
            }
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

    // MARK: - Safe Shuttle Playback & Seeking

    private func startShuttle(direction: ShuttleDirection) {
        guard activeShuttleSession == nil else { return }
        let settings = UserSettings.shared
        let wasPaused = engine.isPaused
        let originalSpeed = engine.speed

        let isHeavy = (settings.fastSeekingBehavior == .keyframesOnly) ||
                      (!engine.diagnostics.isHardwareAccelerated && (engine.diagnostics.rawWidth >= 3840 || engine.diagnostics.width >= 3840))

        let useKeyframeSeeking = (direction == .rewind) || isHeavy || (settings.fastSeekingBehavior != .auto && settings.fastSeekingBehavior != .exact)

        activeShuttleSession = ShuttleSession(
            direction: direction,
            wasPaused: wasPaused,
            originalSpeed: originalSpeed,
            isKeyframeSeeking: useKeyframeSeeking
        )

        if useKeyframeSeeking {
            if !wasPaused {
                engine.pause()
            }
            let step = (direction == .forward) ? 2.0 : -2.0
            engine.seekRelative(step, exact: false)
            shuttleSeekTimer?.invalidate()
            shuttleSeekTimer = Timer.scheduledTimer(withTimeInterval: 0.22, repeats: true) { [weak self] _ in
                self?.engine.seekRelative(step, exact: false)
            }
            let badgeText = (direction == .forward) ? "▶▶ Fast Seeking" : "◀◀ Rewind"
            showShuttleBadge(text: badgeText)
        } else {
            let targetSpeed = settings.temporaryFastSpeed
            engine.setSpeed(targetSpeed)
            if wasPaused {
                engine.play()
            }
            showShuttleBadge(text: "▶▶ \(Int(targetSpeed))×")
        }
        showControlsImmediately()
    }

    public func endShuttle(restoreOriginalState: Bool = true) {
        shuttleHoldTimer?.invalidate()
        shuttleHoldTimer = nil
        pendingShuttleDirection = nil

        shuttleSeekTimer?.invalidate()
        shuttleSeekTimer = nil

        hideShuttleBadge()

        guard let session = activeShuttleSession else { return }
        activeShuttleSession = nil

        if restoreOriginalState {
            engine.setSpeed(session.originalSpeed)
            if session.wasPaused {
                engine.pause()
            } else {
                engine.play()
            }
        }
    }

    private func showShuttleBadge(text: String) {
        shuttleBadgeLabel.stringValue = text
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            shuttleBadgeView.animator().alphaValue = 1.0
        }
    }

    private func hideShuttleBadge() {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.20
            shuttleBadgeView.animator().alphaValue = 0.0
        }
    }

    // MARK: - Frame Capture Workflow

    @objc public func captureCurrentFrame() {
        guard let url = engine.currentURL else { return }
        let settings = UserSettings.shared
        let outputDir = settings.captureOutputDirectoryURL
        do {
            try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        } catch {
            showToast(message: "Failed to create capture folder: \(error.localizedDescription)", isError: true)
            return
        }

        let pos = max(0.0, engine.position)
        let totalSeconds = Int(pos)
        let mins = totalSeconds / 60
        let secs = totalSeconds % 60
        let millis = Int((pos.truncatingRemainder(dividingBy: 1.0)) * 1000)
        let timeString = String(format: "%02dm%02d.%03ds", mins, secs, millis)

        let baseName: String
        switch settings.captureFilenamePattern {
        case .timestampOnly:
            baseName = "frame_\(timeString)"
        case .sourceAndTimestamp:
            let cleanSource = url.deletingPathExtension().lastPathComponent
                .replacingOccurrences(of: "/", with: "-")
                .replacingOccurrences(of: ":", with: "-")
            baseName = "\(cleanSource)_frame_\(timeString)"
        }

        var targetURL = outputDir.appendingPathComponent("\(baseName).png")
        if FileManager.default.fileExists(atPath: targetURL.path) {
            var counter = 1
            while FileManager.default.fileExists(atPath: targetURL.path) {
                targetURL = outputDir.appendingPathComponent("\(baseName)-\(counter).png")
                counter += 1
            }
        }

        engine.captureFrame(to: targetURL) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let savedURL):
                if settings.showCaptureConfirmation {
                    self.showToast(message: "Saved frame: \(savedURL.lastPathComponent)", actionURL: savedURL)
                }
            case .failure(let error):
                self.showToast(message: "Capture failed: \(error.localizedDescription)", isError: true)
            }
        }
    }

    public func showToast(message: String, actionURL: URL? = nil, isError: Bool = false) {
        toastDismissTimer?.invalidate()
        toastActionURL = actionURL
        toastLabel.stringValue = message
        toastLabel.textColor = isError ? NSColor.systemRed : NSColor.white
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.20
            toastView.animator().alphaValue = 1.0
        }
        toastDismissTimer = Timer.scheduledTimer(withTimeInterval: isError ? 3.5 : 2.5, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.30
                self.toastView.animator().alphaValue = 0.0
            }
        }
    }

    @objc private func handleToastClicked() {
        if let url = toastActionURL {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    // MARK: - Context Menu

    public func buildContextMenu() -> NSMenu {
        let menu = NSMenu(title: "Video Context")

        let captureItem = NSMenuItem(title: "Save Current Frame", action: #selector(contextMenuCaptureFrame), keyEquivalent: "s")
        captureItem.keyEquivalentModifierMask = [.command, .shift]
        captureItem.target = self
        menu.addItem(captureItem)

        menu.addItem(.separator())

        let playPauseTitle = engine.isPaused ? "Play" : "Pause"
        let playPauseItem = NSMenuItem(title: playPauseTitle, action: #selector(contextMenuPlayPause), keyEquivalent: " ")
        playPauseItem.keyEquivalentModifierMask = []
        playPauseItem.target = self
        menu.addItem(playPauseItem)

        let rewindItem = NSMenuItem(title: "Rewind 5s", action: #selector(contextMenuRewind), keyEquivalent: "")
        rewindItem.target = self
        menu.addItem(rewindItem)

        let forwardItem = NSMenuItem(title: "Fast-Forward 5s", action: #selector(contextMenuForward), keyEquivalent: "")
        forwardItem.target = self
        menu.addItem(forwardItem)

        menu.addItem(.separator())

        let diagItem = NSMenuItem(title: "Toggle Decoder Diagnostics", action: #selector(contextMenuDiagnostics), keyEquivalent: "i")
        diagItem.keyEquivalentModifierMask = [.command]
        diagItem.target = self
        menu.addItem(diagItem)

        let fastPreviewItem = NSMenuItem(title: "Toggle Fast Preview Mode", action: #selector(contextMenuFastPreview), keyEquivalent: "p")
        fastPreviewItem.keyEquivalentModifierMask = []
        fastPreviewItem.target = self
        menu.addItem(fastPreviewItem)

        menu.addItem(.separator())

        let fullscreenTitle = isFullscreen ? "Exit Full Screen" : "Enter Full Screen"
        let fsItem = NSMenuItem(title: fullscreenTitle, action: #selector(contextMenuFullscreen), keyEquivalent: "f")
        fsItem.keyEquivalentModifierMask = [.command, .control]
        fsItem.target = self
        menu.addItem(fsItem)

        return menu
    }

    @objc private func contextMenuCaptureFrame() {
        captureCurrentFrame()
    }

    @objc private func contextMenuPlayPause() {
        engine.togglePlayPause()
        resetAutoHideTimer()
    }

    @objc private func contextMenuRewind() {
        engine.seekRelative(-5.0, exact: false)
        resetAutoHideTimer()
    }

    @objc private func contextMenuForward() {
        engine.seekRelative(5.0, exact: false)
        resetAutoHideTimer()
    }

    @objc private func contextMenuDiagnostics() {
        toggleDiagnosticsOverlay()
        resetAutoHideTimer()
    }

    @objc private func contextMenuFastPreview() {
        toggleFastPreviewMode()
        resetAutoHideTimer()
    }

    @objc private func contextMenuFullscreen() {
        toggleFullscreen()
    }

    // MARK: - Keyboard Shortcuts

    private func handleKeyDown(_ event: NSEvent) -> Bool {
        showControlsImmediately()
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        if flags.contains(.command) {
            if flags.contains(.shift) && event.charactersIgnoringModifiers?.lowercased() == "s" {
                captureCurrentFrame()
                return true
            }
            if event.charactersIgnoringModifiers?.lowercased() == "i" {
                toggleDiagnosticsOverlay()
                return true
            }
            if event.charactersIgnoringModifiers == "," {
                SettingsWindowController.shared.showSettings()
                return true
            }
            return false
        }

        if hudView.timelineSlider.isUserScrubbing {
            return false
        }

        switch event.keyCode {
        case 49: // Space
            endShuttle(restoreOriginalState: true)
            engine.togglePlayPause()
            return true
        case 123: // Left Arrow
            if event.isARepeat { return true }
            if activeShuttleSession != nil || shuttleHoldTimer != nil { return true }
            pendingShuttleDirection = .rewind
            shuttleHoldTimer = Timer.scheduledTimer(withTimeInterval: 0.20, repeats: false) { [weak self] _ in
                self?.shuttleHoldTimer = nil
                self?.startShuttle(direction: .rewind)
            }
            return true
        case 124: // Right Arrow
            if event.isARepeat { return true }
            if activeShuttleSession != nil || shuttleHoldTimer != nil { return true }
            pendingShuttleDirection = .forward
            shuttleHoldTimer = Timer.scheduledTimer(withTimeInterval: 0.20, repeats: false) { [weak self] _ in
                self?.shuttleHoldTimer = nil
                self?.startShuttle(direction: .forward)
            }
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

    private func handleKeyUp(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        switch event.keyCode {
        case 123: // Left Arrow released
            if shuttleHoldTimer != nil {
                shuttleHoldTimer?.invalidate()
                shuttleHoldTimer = nil
                pendingShuttleDirection = nil
                let exact = flags.contains(.shift)
                let step = exact ? -1.0 : -5.0
                engine.seekRelative(step, exact: exact)
                return true
            } else if activeShuttleSession?.direction == .rewind {
                endShuttle(restoreOriginalState: true)
                return true
            }
            return false

        case 124: // Right Arrow released
            if shuttleHoldTimer != nil {
                shuttleHoldTimer?.invalidate()
                shuttleHoldTimer = nil
                pendingShuttleDirection = nil
                let exact = flags.contains(.shift)
                let step = exact ? 1.0 : 5.0
                engine.seekRelative(step, exact: exact)
                return true
            } else if activeShuttleSession?.direction == .forward {
                endShuttle(restoreOriginalState: true)
                return true
            }
            return false

        default:
            return false
        }
    }

    @objc private func handleAppDidResignActive() {
        endShuttle(restoreOriginalState: true)
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

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - NSWindowDelegate

    public func windowWillStartLiveResize(_ notification: Notification) {
        if !isProgrammaticWindowResize && !isFullscreen {
            userDidManuallyResizeWindow = true
        }
    }

    public func windowDidEndLiveResize(_ notification: Notification) {
        if let win = window, UserSettings.shared.rememberLastWindowSize {
            UserSettings.shared.lastWindowSize = win.frame.size
        }
    }

    public func windowDidResignKey(_ notification: Notification) {
        endShuttle(restoreOriginalState: true)
    }

    public func windowDidResignMain(_ notification: Notification) {
        endShuttle(restoreOriginalState: true)
    }

    public func windowWillEnterFullScreen(_ notification: Notification) {
        endShuttle(restoreOriginalState: true)
    }

    public func windowDidEnterFullScreen(_ notification: Notification) {
        isFullscreen = true
        endShuttle(restoreOriginalState: true)
        hudView.updateFullscreenState(isFullscreen: true)
    }

    public func windowWillExitFullScreen(_ notification: Notification) {
        endShuttle(restoreOriginalState: true)
    }

    public func windowDidExitFullScreen(_ notification: Notification) {
        isFullscreen = false
        endShuttle(restoreOriginalState: true)
        hudView.updateFullscreenState(isFullscreen: false)
    }

    public func windowWillClose(_ notification: Notification) {
        endShuttle(restoreOriginalState: false)
        toastDismissTimer?.invalidate()
        toastDismissTimer = nil
        NotificationCenter.default.removeObserver(self)
        initialRevealTimer?.invalidate()
        initialRevealTimer = nil
        hideControlsTimer?.invalidate()
        hideControlsTimer = nil
        stopDiagnosticsTimer()
        engine.shutdown()
        onWindowWillClose?(self)
    }
}
