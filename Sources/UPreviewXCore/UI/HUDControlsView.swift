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

/// Unobtrusive floating HUD control bar modelled after the native macOS QuickTime / QuickLook preview bar.
public final class HUDControlsView: NSVisualEffectView {
    public var onPlayPause: (() -> Void)?
    public var onSeek: ((Double, Bool) -> Void)?
    public var onMuteToggle: (() -> Void)?
    public var onVolumeChange: ((Double) -> Void)?
    public var onToggleDiagnostics: (() -> Void)?
    public var onToggleFullscreen: (() -> Void)?

    private let playPauseButton = NSButton()
    private let currentTimeLabel = NSTextField(labelWithString: "00:00")
    public let timelineSlider = TimelineSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let durationLabel = NSTextField(labelWithString: "00:00")
    private let muteButton = NSButton()
    private let volumeSlider = NSSlider(value: 100, minValue: 0, maxValue: 100, target: nil, action: nil)
    private let diagButton = NSButton()
    private let fullscreenButton = NSButton()

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

        // Play/Pause Button
        configureIconButton(playPauseButton, symbolName: "pause.fill", toolTip: "Play / Pause (Space)", action: #selector(handlePlayPause))

        // Time Labels
        let timeFont = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .medium)
        currentTimeLabel.font = timeFont
        currentTimeLabel.textColor = .white
        currentTimeLabel.alignment = .right
        currentTimeLabel.setContentHuggingPriority(.required, for: .horizontal)

        durationLabel.font = timeFont
        durationLabel.textColor = NSColor.white.withAlphaComponent(0.75)
        durationLabel.alignment = .left
        durationLabel.setContentHuggingPriority(.required, for: .horizontal)

        // Timeline Slider
        timelineSlider.isContinuous = true
        timelineSlider.controlSize = .small
        timelineSlider.target = self
        timelineSlider.action = #selector(handleTimelineAction(_:))
        timelineSlider.onScrubChanged = { [weak self] value, isFinal in
            self?.currentTimeLabel.stringValue = TimeFormatter.format(seconds: value)
            self?.onSeek?(value, isFinal)
        }

        // Mute & Volume
        configureIconButton(muteButton, symbolName: "speaker.wave.2.fill", toolTip: "Mute (M)", action: #selector(handleMute))

        volumeSlider.isContinuous = true
        volumeSlider.controlSize = .mini
        volumeSlider.target = self
        volumeSlider.action = #selector(handleVolumeAction(_:))
        volumeSlider.translatesAutoresizingMaskIntoConstraints = false
        volumeSlider.widthAnchor.constraint(equalToConstant: 64).isActive = true

        // Diagnostics & Fullscreen Buttons
        configureIconButton(diagButton, symbolName: "gauge.with.dots.needle.bottom.50percent", toolTip: "Toggle Decoder Diagnostics (D / Cmd+I)", action: #selector(handleDiagnostics))
        configureIconButton(fullscreenButton, symbolName: "arrow.up.left.and.arrow.down.right", toolTip: "Toggle Fullscreen (F)", action: #selector(handleFullscreen))

        let stack = NSStackView(views: [
            playPauseButton,
            currentTimeLabel,
            timelineSlider,
            durationLabel,
            muteButton,
            volumeSlider,
            diagButton,
            fullscreenButton
        ])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 14, bottom: 8, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            currentTimeLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 42),
            durationLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 42)
        ])
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
            let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
            button.image = img.withSymbolConfiguration(config)
        }
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 26),
            button.heightAnchor.constraint(equalToConstant: 26)
        ])
    }

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
            let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
            playPauseButton.image = img.withSymbolConfiguration(config)
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
            let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
            muteButton.image = img.withSymbolConfiguration(config)
        }
    }

    public func updateFullscreenState(isFullscreen: Bool) {
        let symbol = isFullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right"
        if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: "Fullscreen") {
            let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
            fullscreenButton.image = img.withSymbolConfiguration(config)
        }
    }

    @objc private func handlePlayPause() {
        onPlayPause?()
    }

    @objc private func handleTimelineAction(_ sender: TimelineSlider) {
        if sender.isUserScrubbing {
            sender.notifyContinuousValueChange()
        } else {
            onSeek?(sender.doubleValue, true)
        }
    }

    @objc private func handleMute() {
        onMuteToggle?()
    }

    @objc private func handleVolumeAction(_ sender: NSSlider) {
        onVolumeChange?(sender.doubleValue)
    }

    @objc private func handleDiagnostics() {
        onToggleDiagnostics?()
    }

    @objc private func handleFullscreen() {
        onToggleFullscreen?()
    }
}
