import AppKit
import AVFoundation

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
    private var expectedDisplayAspect: CGFloat?
    private var hasRenderedFirstFrame = false

    // Safe Shuttle State
    public enum ShuttleDirection {
        case forward
        case rewind
    }

    private struct ShuttleSession {
        let direction: ShuttleDirection
        let wasPaused: Bool
        let originalSpeed: Double
        let triggerKeyCode: UInt16
    }

    private var activeShuttleSession: ShuttleSession?
    public var isShuttleActive: Bool { activeShuttleSession != nil }
    private var shuttleHoldTimer: Timer?
    private var shuttleSeekTimer: Timer?
    private var pendingShuttleDirection: ShuttleDirection?
    private var pendingShuttleKeyCode: UInt16?
    private var isShuttleSeekInFlight = false
    private var pendingShuttleStep: Double?

    // Active Keyboard Shortcuts
    private var shortcuts: [ShortcutAction: KeyShortcut] = [:]

    // Subtle Visual Indicators
    private let shuttleBadgeView = NSVisualEffectView()
    private let shuttleBadgeLabel = NSTextField(labelWithString: "")

    private let toastView = NSVisualEffectView()
    private let toastLabel = NSTextField(labelWithString: "")
    private var toastDismissTimer: Timer?
    private var toastActionURL: URL?
    private var memoryPressureSource: DispatchSourceMemoryPressure?

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
        setupMemoryPressureMonitoring()
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
        hudView.onToggleSpeed = { [weak self] in
            self?.toggleSpeed()
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
        hudView.onToggleFastPreview = { [weak self] in
            self?.toggleFastPreviewMode()
            self?.resetAutoHideTimer()
        }
        hudView.onOpenSettings = {
            SettingsWindowController.shared.showSettings()
        }
        hudView.isFastPreviewActive = { [weak self] in
            self?.engine.isFastPreviewMode ?? false
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

        let preferredHUDWidth = hudView.widthAnchor.constraint(equalToConstant: 440)
        preferredHUDWidth.priority = .defaultHigh

        NSLayoutConstraint.activate([
            hudView.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            hudView.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16),
            preferredHUDWidth,
            hudView.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 10),
            hudView.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -10),
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

        reloadShortcuts()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleUserSettingsDidChange),
            name: .userSettingsDidChange,
            object: nil
        )

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

    private func setupMemoryPressureMonitoring() {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            guard let self = self else { return }
            let event = source.data
            let isCritical = event.contains(.critical)
            self.engine.handleMemoryPressure(critical: isCritical)
        }
        source.resume()
        self.memoryPressureSource = source
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

    /// Fast pre-flight track metadata inspection (< 20ms) for MP4/MOV/M4V containers.
    /// Reads track dimensions and affine rotation transform without GOP decoding,
    /// enabling the window to adopt the exact target aspect ratio before it is ever shown.
    public static func preflightVideoDisplaySize(for url: URL) -> CGSize? {
        let ext = url.pathExtension.lowercased()
        guard ["mp4", "mov", "m4v"].contains(ext) else { return nil }
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: false])
        var displaySize: CGSize?
        let sema = DispatchSemaphore(value: 0)
        Task.detached {
            if let tracks = try? await asset.loadTracks(withMediaType: .video),
               let track = tracks.first,
               let natural = try? await track.load(.naturalSize),
               let transform = try? await track.load(.preferredTransform),
               natural.width > 0, natural.height > 0 {
                let applied = natural.applying(transform)
                let w = abs(applied.width)
                let h = abs(applied.height)
                if w > 0 && h > 0 {
                    displaySize = CGSize(width: w, height: h)
                }
            }
            sema.signal()
        }
        _ = sema.wait(timeout: .now() + 0.05)
        return displaySize
    }

    private func applyAdaptiveWindowSize(_ size: CGSize, isPreflight: Bool = false) {
        guard size.width > 0 && size.height > 0, let win = window else { return }

        // If pre-flight metadata determined an expected aspect ratio (e.g. portrait 9:16),
        // reject premature intermediate updates from mpv that have opposite orientation
        // (e.g. landscape 3840x2160 emitted before mpv has parsed video-params/rotate).
        if !isPreflight, let expected = expectedDisplayAspect {
            let currentAspect = size.width / size.height
            let isExpectedPortrait = expected < 0.95
            let isCurrentPortrait = currentAspect < 0.95
            if isExpectedPortrait != isCurrentPortrait {
                return
            }
        }

        // Lock window frame aspect ratio (matches fullSizeContentView viewport)
        win.aspectRatio = size

        guard !isFullscreen, !userDidManuallyResizeWindow else {
            if hasRenderedFirstFrame { revealWindowIfNeeded() }
            return
        }

        guard UserSettings.shared.fitWindowToAspectRatio else {
            if hasRenderedFirstFrame { revealWindowIfNeeded() }
            return
        }

        guard size != lastAppliedVideoSize else {
            if hasRenderedFirstFrame { revealWindowIfNeeded() }
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

        if hasRenderedFirstFrame {
            revealWindowIfNeeded()
        }
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
        hasRenderedFirstFrame = false
        updateWindowTitle(for: url)
        window?.representedURL = url
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Clear previous video frame so switching files never flashes stale content
        videoView.videoLayer.setNeedsDisplay()

        // Fast pre-flight track metadata inspection (< 20ms)
        if let preflight = Self.preflightVideoDisplaySize(for: url) {
            expectedDisplayAspect = preflight.width / preflight.height
            applyAdaptiveWindowSize(preflight, isPreflight: true)
        } else {
            expectedDisplayAspect = nil
        }

        // Force immediate CGLContext and mpv_render_context creation before loading the file
        videoView.videoLayer.display()

        // Fallback timer (1.2s) only for audio-only, broken, or non-visual files that produce no video frames
        initialRevealTimer?.invalidate()
        initialRevealTimer = Timer.scheduledTimer(withTimeInterval: 1.2, repeats: false) { [weak self] _ in
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

    public func toggleSpeed() {
        let current = engine.speed
        let target = (abs(current - 2.0) < 0.15) ? 1.0 : 2.0
        engine.setSpeed(target)
        hudView.updateSpeed(target)
        showToast(message: target == 2.0 ? "Playback Speed: 2×" : "Playback Speed: 1×")
        resetAutoHideTimer()
    }

    private func updateWindowTitle(for url: URL) {
        let suffix = engine.isFastPreviewMode ? " — [Fast Preview]" : ""
        window?.title = url.lastPathComponent + suffix
    }

    // MARK: - Safe Shuttle Playback & Seeking

    public func startShuttle(direction: ShuttleDirection, keyCode: UInt16 = 0) {
        guard activeShuttleSession == nil else { return }
        let settings = UserSettings.shared
        let wasPaused = engine.isPaused
        let originalSpeed = engine.speed

        let effectiveKeyCode = keyCode != 0 ? keyCode : (direction == .forward ? 124 : 123)

        activeShuttleSession = ShuttleSession(
            direction: direction,
            wasPaused: wasPaused,
            originalSpeed: originalSpeed,
            triggerKeyCode: effectiveKeyCode
        )

        // Pause playback during shuttle navigation so decoder focuses purely on keyframe seeking
        if !wasPaused {
            engine.pause()
        }

        // Heavy codecs (e.g. software 4K): reduce seeking frequency to avoid decoder stall (0.35s / 4s step); normal: 0.18s / 2s step
        let isHeavy = (settings.fastSeekingBehavior == .keyframesOnly) ||
                      (!engine.diagnostics.isHardwareAccelerated && (engine.diagnostics.rawWidth >= 3840 || engine.diagnostics.width >= 3840))

        let interval: TimeInterval = isHeavy ? 0.35 : 0.18
        let step = (direction == .forward) ? (isHeavy ? 4.0 : 2.0) : (isHeavy ? -4.0 : -2.0)

        // Perform initial seek immediately
        performShuttleSeek(step: step)

        shuttleSeekTimer?.invalidate()
        shuttleSeekTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.performShuttleSeek(step: step)
        }

        let badgeText = (direction == .forward) ? "▶▶ Shuttle Forward" : "◀◀ Shuttle Rewind"
        showShuttleBadge(text: badgeText)
        showControlsImmediately()
    }

    private func performShuttleSeek(step: Double) {
        guard activeShuttleSession != nil else { return }
        if isShuttleSeekInFlight {
            pendingShuttleStep = step
            return
        }
        isShuttleSeekInFlight = true
        pendingShuttleStep = nil
        engine.seekRelative(step, exact: false)
    }

    private func handleShuttleSeekCompleted() {
        isShuttleSeekInFlight = false
        if let nextStep = pendingShuttleStep, activeShuttleSession != nil {
            pendingShuttleStep = nil
            performShuttleSeek(step: nextStep)
        }
    }

    public func endShuttle(restoreOriginalState: Bool = true) {
        shuttleHoldTimer?.invalidate()
        shuttleHoldTimer = nil
        pendingShuttleDirection = nil
        pendingShuttleKeyCode = nil

        shuttleSeekTimer?.invalidate()
        shuttleSeekTimer = nil
        pendingShuttleStep = nil
        isShuttleSeekInFlight = false

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

    @objc private func handleUserSettingsDidChange() {
        reloadShortcuts()
    }

    private func reloadShortcuts() {
        var map: [ShortcutAction: KeyShortcut] = [:]
        for action in ShortcutAction.allCases {
            map[action] = UserSettings.shared.shortcut(for: action)
        }
        self.shortcuts = map
    }

    private func handleKeyDown(_ event: NSEvent) -> Bool {
        showControlsImmediately()
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        if flags.contains(.command) && event.charactersIgnoringModifiers == "," {
            SettingsWindowController.shared.showSettings()
            return true
        }

        if hudView.timelineSlider.isUserScrubbing {
            return false
        }

        // 1. Configurable instant action shortcuts
        if shortcuts[.saveFrame]?.matches(event: event) == true {
            captureCurrentFrame()
            return true
        }
        if shortcuts[.toggleDiagnostics]?.matches(event: event) == true {
            toggleDiagnosticsOverlay()
            return true
        }
        if shortcuts[.toggleFastPreview]?.matches(event: event) == true {
            toggleFastPreviewMode()
            return true
        }
        if shortcuts[.toggleSpeed]?.matches(event: event) == true {
            toggleSpeed()
            return true
        }
        if shortcuts[.toggleMute]?.matches(event: event) == true {
            engine.toggleMute()
            return true
        }
        if shortcuts[.toggleFullscreen]?.matches(event: event) == true {
            toggleFullscreen()
            return true
        }
        if shortcuts[.playPause]?.matches(event: event) == true {
            endShuttle(restoreOriginalState: true)
            engine.togglePlayPause()
            return true
        }

        // 2. Rewind Seek / Shuttle
        let isRewindMatch = (shortcuts[.shuttleBackward]?.matches(event: event) == true) ||
                            (shortcuts[.seekBackward]?.matches(event: event) == true)
        if isRewindMatch {
            if event.isARepeat { return true }
            if activeShuttleSession != nil || shuttleHoldTimer != nil { return true }
            pendingShuttleDirection = .rewind
            pendingShuttleKeyCode = event.keyCode
            shuttleHoldTimer = Timer.scheduledTimer(withTimeInterval: 0.18, repeats: false) { [weak self] _ in
                self?.shuttleHoldTimer = nil
                self?.startShuttle(direction: .rewind, keyCode: event.keyCode)
            }
            return true
        }

        // 3. Forward Seek / Shuttle
        let isForwardMatch = (shortcuts[.shuttleForward]?.matches(event: event) == true) ||
                             (shortcuts[.seekForward]?.matches(event: event) == true)
        if isForwardMatch {
            if event.isARepeat { return true }
            if activeShuttleSession != nil || shuttleHoldTimer != nil { return true }
            pendingShuttleDirection = .forward
            pendingShuttleKeyCode = event.keyCode
            shuttleHoldTimer = Timer.scheduledTimer(withTimeInterval: 0.18, repeats: false) { [weak self] _ in
                self?.shuttleHoldTimer = nil
                self?.startShuttle(direction: .forward, keyCode: event.keyCode)
            }
            return true
        }

        // 4. Default Volume & Escape keys
        switch event.keyCode {
        case 126: // Up Arrow
            engine.setVolume(engine.volume + 5.0)
            return true
        case 125: // Down Arrow
            engine.setVolume(engine.volume - 5.0)
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

        // 1. Released before hold threshold -> short seek
        if let pendingCode = pendingShuttleKeyCode, pendingCode == event.keyCode, shuttleHoldTimer != nil {
            shuttleHoldTimer?.invalidate()
            shuttleHoldTimer = nil
            let dir = pendingShuttleDirection
            pendingShuttleDirection = nil
            pendingShuttleKeyCode = nil

            let exact = flags.contains(.shift)
            if dir == .rewind {
                let step = exact ? -1.0 : -5.0
                engine.seekRelative(step, exact: exact)
                return true
            } else if dir == .forward {
                let step = exact ? 1.0 : 5.0
                engine.seekRelative(step, exact: exact)
                return true
            }
            return false
        }

        // 2. Active shuttle release: matches by triggerKeyCode regardless of modifier changes
        if let session = activeShuttleSession, session.triggerKeyCode == event.keyCode {
            endShuttle(restoreOriginalState: true)
            return true
        }

        return false
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
            hudView.updatePosition(engine.position, duration: engine.duration)
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
        // When paused or occluded, suppress recurring diagnostics polling to maintain ~0% idle CPU
        guard !engine.isPaused, (window?.occlusionState.contains(.visible) != false) else {
            engine.refreshDiagnostics()
            return
        }
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
        hudView.updateSpeed(engine.speed)
        hudView.updateVolume(engine.volume, isMuted: engine.isMuted)
        diagnosticsView.update(with: engine.diagnostics)
    }

    public func playbackEngineDidRenderFirstFrame(_ engine: PlaybackEngineProtocol, latencyMs: Double) {
        revealWindowIfNeeded()
        diagnosticsView.update(with: engine.diagnostics)
        onFirstFrameRendered?(engine.diagnostics)
    }

    public func playbackEngine(_ engine: PlaybackEngineProtocol, didUpdatePosition position: Double, duration: Double) {
        // Event-driven throttling: do not perform layout & string formatting when HUD is hidden
        guard !isControlsHidden else { return }
        hudView.updatePosition(position, duration: duration)
    }

    public func playbackEngine(_ engine: PlaybackEngineProtocol, didUpdatePause isPaused: Bool) {
        hudView.updatePauseState(isPaused: isPaused)
        if isPaused {
            showControlsImmediately()
            // Stop recurring diagnostics timer while paused so idle CPU stabilizes near 0.0%
            stopDiagnosticsTimer()
            engine.refreshDiagnostics()
        } else {
            resetAutoHideTimer()
            if !diagnosticsView.isHidden && (window?.occlusionState.contains(.visible) != false) {
                startDiagnosticsTimer()
            }
        }
    }

    public func playbackEngine(_ engine: PlaybackEngineProtocol, didUpdateVolume volume: Double, isMuted: Bool) {
        hudView.updateVolume(volume, isMuted: isMuted)
    }

    public func playbackEngine(_ engine: PlaybackEngineProtocol, didUpdateVideoSize size: CGSize) {
        applyAdaptiveWindowSize(size, isPreflight: false)
    }

    public func playbackEngine(_ engine: PlaybackEngineProtocol, didCompleteSeek latencyMs: Double) {
        handleShuttleSeekCompleted()
        diagnosticsView.update(with: engine.diagnostics)
    }

    public func playbackEngine(_ engine: PlaybackEngineProtocol, didUpdateSpeed speed: Double) {
        hudView.updateSpeed(speed)
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

    public func windowDidChangeOcclusionState(_ notification: Notification) {
        guard let win = window else { return }
        let isVisible = win.occlusionState.contains(.visible)
        handleVisibilityStateChange(isVisible: isVisible)
    }

    public func windowDidMiniaturize(_ notification: Notification) {
        handleVisibilityStateChange(isVisible: false)
    }

    public func windowDidDeminiaturize(_ notification: Notification) {
        handleVisibilityStateChange(isVisible: true)
    }

    private func handleVisibilityStateChange(isVisible: Bool) {
        videoView.videoLayer.isOccluded = !isVisible
        if !isVisible {
            stopDiagnosticsTimer()
        } else {
            if !diagnosticsView.isHidden && !engine.isPaused {
                startDiagnosticsTimer()
            }
        }
    }

    public func windowWillClose(_ notification: Notification) {
        endShuttle(restoreOriginalState: false)
        memoryPressureSource?.cancel()
        memoryPressureSource = nil
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
