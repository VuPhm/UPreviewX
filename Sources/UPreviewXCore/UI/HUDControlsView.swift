import AppKit

/// Interactive slider that reports scrubbing state to avoid fighting with incoming `time-pos` updates.
public final class TimelineSlider: NSSlider {
    public private(set) var isUserScrubbing = false
    public var onScrubChanged: ((Double, Bool) -> Void)?
    private var lastDispatchedTime: CFAbsoluteTime = 0

    public override func mouseDown(with event: NSEvent) {
        isUserScrubbing = true
        super.mouseDown(with: event)
        isUserScrubbing = false
        onScrubChanged?(doubleValue, true)
    }

    public func notifyContinuousValueChange() {
        let now = CFAbsoluteTimeGetCurrent()
        // Coalesce continuous drag seeks to ~60Hz max to keep seek queue responsive
        if now - lastDispatchedTime >= 0.016 {
            lastDispatchedTime = now
            onScrubChanged?(doubleValue, false)
        }
    }
}

/// Container view for the compact volume icon and expandable volume slider.
private final class VolumeContainerView: NSView {
    var onHoverChanged: ((Bool) -> Void)?
    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        onHoverChanged?(true)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onHoverChanged?(false)
    }
}

/// Unobtrusive floating HUD control bar modelled after native macOS media preview bars.
/// Refined to remain minimal, especially for vertical 9:16 portrait video windows.
public final class HUDControlsView: NSVisualEffectView {
    public var onPlayPause: (() -> Void)?
    public var onRewind: (() -> Void)?
    public var onFastForward: (() -> Void)?
    public var onSeek: ((Double, Bool) -> Void)?
    public var onMuteToggle: (() -> Void)?
    public var onVolumeChange: ((Double) -> Void)?
    public var onToggleSpeed: (() -> Void)?
    public var onCaptureFrame: (() -> Void)?
    public var onToggleDiagnostics: (() -> Void)?
    public var onToggleFastPreview: (() -> Void)?
    public var onOpenSettings: (() -> Void)?
    public var onToggleFullscreen: (() -> Void)?
    public var isFastPreviewActive: (() -> Bool)?

    // Primary Controls
    public let rewindButton = NSButton()
    public let playPauseButton = NSButton()
    public let fastForwardButton = NSButton()
    public let currentTimeLabel = NSTextField(labelWithString: "00:00")
    public let timelineSlider = TimelineSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    public let durationLabel = NSTextField(labelWithString: "00:00")

    // Compact Expandable Volume
    private let volumeContainer = VolumeContainerView()
    public let muteButton = NSButton()
    public let volumeSlider = NSSlider(value: 100, minValue: 0, maxValue: 100, target: nil, action: nil)
    private var volumeCollapseTimer: Timer?
    private var isMouseInVolumeContainer = false
    private var isUserDraggingVolume = false

    // Speed Control (1× / 2×)
    public let speedButton = NSButton()

    // Overflow & Window Controls
    public let overflowButton = NSButton()
    public let fullscreenButton = NSButton()

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupView()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupView()
    }

    public override var mouseDownCanMoveWindow: Bool { false }

    private func setupView() {
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.masksToBounds = true
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor

        // 1. Primary Transport Buttons
        configureIconButton(rewindButton, symbolName: "backward.fill", toolTip: "Rewind (Hold to shuttle)", action: #selector(handleRewind))
        configureIconButton(playPauseButton, symbolName: "pause.fill", toolTip: "Play / Pause (Space)", action: #selector(handlePlayPause))
        configureIconButton(fastForwardButton, symbolName: "forward.fill", toolTip: "Fast-Forward (Hold to shuttle)", action: #selector(handleFastForward))

        // 2. Time Labels & Scrubber
        let timeFont = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .medium)
        currentTimeLabel.font = timeFont
        currentTimeLabel.textColor = .white
        currentTimeLabel.alignment = .right
        currentTimeLabel.setContentHuggingPriority(.required, for: .horizontal)
        currentTimeLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

        durationLabel.font = timeFont
        durationLabel.textColor = NSColor.white.withAlphaComponent(0.70)
        durationLabel.alignment = .left
        durationLabel.setContentHuggingPriority(.required, for: .horizontal)
        durationLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        timelineSlider.isContinuous = true
        timelineSlider.controlSize = .small
        timelineSlider.target = self
        timelineSlider.action = #selector(handleTimelineAction(_:))
        timelineSlider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        timelineSlider.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        timelineSlider.onScrubChanged = { [weak self] value, isFinal in
            self?.currentTimeLabel.stringValue = TimeFormatter.format(seconds: value)
            self?.onSeek?(value, isFinal)
        }

        // 3. Compact Expandable Volume Control
        configureIconButton(muteButton, symbolName: "speaker.wave.2.fill", toolTip: "Mute / Unmute (Click or Hover for volume)", action: #selector(handleMuteClick))

        volumeSlider.isContinuous = true
        volumeSlider.controlSize = .mini
        volumeSlider.target = self
        volumeSlider.action = #selector(handleVolumeAction(_:))
        volumeSlider.translatesAutoresizingMaskIntoConstraints = false
        volumeSlider.isHidden = true // Hidden by default, taking zero horizontal space

        let volumeStack = NSStackView(views: [muteButton, volumeSlider])
        volumeStack.orientation = .horizontal
        volumeStack.alignment = .centerY
        volumeStack.spacing = 4
        volumeStack.translatesAutoresizingMaskIntoConstraints = false

        volumeContainer.addSubview(volumeStack)
        volumeContainer.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            volumeStack.leadingAnchor.constraint(equalTo: volumeContainer.leadingAnchor),
            volumeStack.trailingAnchor.constraint(equalTo: volumeContainer.trailingAnchor),
            volumeStack.topAnchor.constraint(equalTo: volumeContainer.topAnchor),
            volumeStack.bottomAnchor.constraint(equalTo: volumeContainer.bottomAnchor),
            volumeSlider.widthAnchor.constraint(equalToConstant: 44)
        ])

        volumeContainer.onHoverChanged = { [weak self] isHovered in
            self?.handleVolumeHoverChanged(isHovered)
        }

        // 4. Dedicated Speed Control Button (1× / 2×)
        speedButton.bezelStyle = .inline
        speedButton.isBordered = false
        speedButton.title = "1×"
        speedButton.font = NSFont.systemFont(ofSize: 10.5, weight: .bold)
        speedButton.contentTintColor = .white
        speedButton.toolTip = "Playback Speed: 1× / 2×"
        speedButton.target = self
        speedButton.action = #selector(handleSpeedToggle)
        speedButton.translatesAutoresizingMaskIntoConstraints = false
        speedButton.wantsLayer = true
        speedButton.layer?.cornerRadius = 4
        speedButton.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.12).cgColor
        NSLayoutConstraint.activate([
            speedButton.widthAnchor.constraint(equalToConstant: 26),
            speedButton.heightAnchor.constraint(equalToConstant: 20)
        ])

        // 5. Overflow Menu Button (Secondary Functions)
        configureIconButton(overflowButton, symbolName: "ellipsis", toolTip: "More Actions", action: #selector(handleOverflowClick))

        // 6. Fullscreen Button
        configureIconButton(fullscreenButton, symbolName: "arrow.up.left.and.arrow.down.right", toolTip: "Toggle Fullscreen (F)", action: #selector(handleFullscreen))

        let mainStack = NSStackView(views: [
            rewindButton,
            playPauseButton,
            fastForwardButton,
            currentTimeLabel,
            timelineSlider,
            durationLabel,
            volumeContainer,
            speedButton,
            overflowButton,
            fullscreenButton
        ])
        mainStack.orientation = .horizontal
        mainStack.alignment = .centerY
        mainStack.spacing = 6
        mainStack.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
        mainStack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(mainStack)
        NSLayoutConstraint.activate([
            mainStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            mainStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            mainStack.topAnchor.constraint(equalTo: topAnchor),
            mainStack.bottomAnchor.constraint(equalTo: bottomAnchor),
            timelineSlider.widthAnchor.constraint(greaterThanOrEqualToConstant: 40)
        ])
    }

    public override func layout() {
        super.layout()
        // Gracefully hide duration label in very narrow portrait windows (< 280 pt) to preserve scrubber
        let isNarrow = bounds.width < 280
        if durationLabel.isHidden != isNarrow {
            durationLabel.isHidden = isNarrow
        }
    }

    private func configureIconButton(_ button: NSButton, symbolName: String, toolTip: String, action: Selector) {
        button.bezelStyle = .regularSquare
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.contentTintColor = .white
        button.toolTip = toolTip
        button.target = self
        button.action = action
        if let img = NSImage(systemSymbolName: symbolName, accessibilityDescription: toolTip) {
            let config = NSImage.SymbolConfiguration(pointSize: 12.0, weight: .semibold)
            button.image = img.withSymbolConfiguration(config)
        }
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 22),
            button.heightAnchor.constraint(equalToConstant: 22)
        ])
    }

    // MARK: - State Updates

    public func updatePosition(_ position: Double, duration: Double) {
        let validDuration = max(0.0, duration)
        timelineSlider.maxValue = validDuration > 0 ? validDuration : 1.0
        durationLabel.stringValue = TimeFormatter.format(seconds: validDuration)
        if !timelineSlider.isUserScrubbing {
            timelineSlider.doubleValue = max(0.0, min(position, timelineSlider.maxValue))
            currentTimeLabel.stringValue = TimeFormatter.format(seconds: position)
        }
    }

    public func updatePauseState(isPaused: Bool) {
        let symbol = isPaused ? "play.fill" : "pause.fill"
        if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: isPaused ? "Play" : "Pause") {
            let config = NSImage.SymbolConfiguration(pointSize: 12.0, weight: .semibold)
            playPauseButton.image = img.withSymbolConfiguration(config)
        }
    }

    public func updateSpeed(_ speed: Double) {
        if abs(speed - 2.0) < 0.15 {
            speedButton.title = "2×"
            speedButton.layer?.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.40).cgColor
        } else if speed > 2.15 {
            speedButton.title = "\(Int(round(speed)))×"
            speedButton.layer?.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.40).cgColor
        } else {
            speedButton.title = "1×"
            speedButton.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.12).cgColor
        }
    }

    public func updateVolume(_ volume: Double, isMuted: Bool) {
        volumeSlider.doubleValue = isMuted ? 0 : volume
        let symbol: String
        if isMuted || volume <= 0.5 {
            symbol = "speaker.slash.fill"
        } else if volume < 50 {
            symbol = "speaker.wave.1.fill"
        } else {
            symbol = "speaker.wave.2.fill"
        }
        if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: "Volume") {
            let config = NSImage.SymbolConfiguration(pointSize: 12.0, weight: .semibold)
            muteButton.image = img.withSymbolConfiguration(config)
        }
    }

    public func updateFullscreenState(isFullscreen: Bool) {
        let symbol = isFullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right"
        if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: "Fullscreen") {
            let config = NSImage.SymbolConfiguration(pointSize: 12.0, weight: .semibold)
            fullscreenButton.image = img.withSymbolConfiguration(config)
        }
    }

    // MARK: - Expandable Volume Logic

    private func handleVolumeHoverChanged(_ isHovered: Bool) {
        isMouseInVolumeContainer = isHovered
        if isHovered {
            volumeCollapseTimer?.invalidate()
            volumeCollapseTimer = nil
            setVolumeSliderExpanded(true)
        } else {
            scheduleVolumeCollapseTimer()
        }
    }

    private func scheduleVolumeCollapseTimer() {
        guard !isMouseInVolumeContainer && !isUserDraggingVolume else { return }
        volumeCollapseTimer?.invalidate()
        volumeCollapseTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            if !self.isMouseInVolumeContainer && !self.isUserDraggingVolume {
                self.setVolumeSliderExpanded(false)
            }
        }
    }

    private func setVolumeSliderExpanded(_ expanded: Bool) {
        guard volumeSlider.isHidden == expanded else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            ctx.allowsImplicitAnimation = true
            volumeSlider.isHidden = !expanded
        }
    }

    // MARK: - Actions

    @objc private func handleRewind() {
        onRewind?()
    }

    @objc private func handlePlayPause() {
        onPlayPause?()
    }

    @objc private func handleFastForward() {
        onFastForward?()
    }

    @objc private func handleTimelineAction(_ sender: TimelineSlider) {
        if sender.isUserScrubbing {
            sender.notifyContinuousValueChange()
        } else {
            onSeek?(sender.doubleValue, true)
        }
    }

    @objc private func handleMuteClick() {
        onMuteToggle?()
        setVolumeSliderExpanded(true)
        scheduleVolumeCollapseTimer()
    }

    @objc private func handleVolumeAction(_ sender: NSSlider) {
        isUserDraggingVolume = true
        onVolumeChange?(sender.doubleValue)
        // Reset collapse timer while adjusting
        volumeCollapseTimer?.invalidate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.isUserDraggingVolume = false
            self?.scheduleVolumeCollapseTimer()
        }
    }

    @objc private func handleSpeedToggle() {
        onToggleSpeed?()
    }

    @objc private func handleFullscreen() {
        onToggleFullscreen?()
    }

    public func buildOverflowMenu() -> NSMenu {
        let menu = NSMenu(title: "Overflow Menu")

        let captureItem = NSMenuItem(title: "Save Current Frame", action: #selector(handleOverflowCapture), keyEquivalent: "")
        captureItem.target = self
        menu.addItem(captureItem)

        let diagItem = NSMenuItem(title: "Playback Diagnostics", action: #selector(handleOverflowDiagnostics), keyEquivalent: "")
        diagItem.target = self
        menu.addItem(diagItem)

        let isFast = isFastPreviewActive?() ?? false
        let fastItem = NSMenuItem(title: "Fast Preview Mode", action: #selector(handleOverflowFastPreview), keyEquivalent: "")
        fastItem.state = isFast ? .on : .off
        fastItem.target = self
        menu.addItem(fastItem)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(handleOverflowSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        return menu
    }

    @objc private func handleOverflowClick() {
        let menu = buildOverflowMenu()
        let point = NSPoint(x: 0, y: overflowButton.bounds.height + 4)
        menu.popUp(positioning: nil, at: point, in: overflowButton)
    }

    @objc private func handleOverflowCapture() {
        onCaptureFrame?()
    }

    @objc private func handleOverflowDiagnostics() {
        onToggleDiagnostics?()
    }

    @objc private func handleOverflowFastPreview() {
        onToggleFastPreview?()
    }

    @objc private func handleOverflowSettings() {
        if let onOpenSettings = onOpenSettings {
            onOpenSettings()
        } else {
            SettingsWindowController.shared.showSettings()
        }
    }
}
