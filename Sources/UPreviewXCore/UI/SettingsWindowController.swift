import AppKit

/// Interactive AppKit button for recording and assigning custom keyboard shortcuts.
public final class ShortcutRecorderButton: NSButton {
    public let actionType: ShortcutAction
    public var onShortcutChanged: ((KeyShortcut) -> Void)?
    public var onStatusChanged: ((String, Bool) -> Void)?

    public private(set) var isRecording = false {
        didSet {
            updateAppearance()
        }
    }

    public init(actionType: ShortcutAction) {
        self.actionType = actionType
        super.init(frame: .zero)
        bezelStyle = .rounded
        font = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .semibold)
        target = self
        action = #selector(handleClick)
        wantsLayer = true
        updateAppearance()
    }

    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override var acceptsFirstResponder: Bool { true }

    public func updateShortcutDisplay() {
        let sc = UserSettings.shared.shortcut(for: actionType)
        title = sc.displayString
        updateAppearance()
    }

    private func updateAppearance() {
        if isRecording {
            title = "Press Shortcut…"
            layer?.borderColor = NSColor.systemBlue.cgColor
            layer?.borderWidth = 1.5
            layer?.cornerRadius = 5
        } else {
            let sc = UserSettings.shared.shortcut(for: actionType)
            title = sc.displayString
            layer?.borderColor = NSColor.separatorColor.cgColor
            layer?.borderWidth = 0.5
            layer?.cornerRadius = 5
        }
    }

    @objc private func handleClick() {
        if isRecording {
            cancelRecording()
        } else {
            startRecording()
        }
    }

    public func startRecording() {
        isRecording = true
        window?.makeFirstResponder(self)
        onStatusChanged?("Recording for \"\(actionType.displayName)\". Press new keys, or Esc to cancel.", false)
    }

    public func cancelRecording() {
        isRecording = false
        updateShortcutDisplay()
        onStatusChanged?("", false)
    }

    public override func keyDown(with event: NSEvent) {
        guard isRecording else {
            super.keyDown(with: event)
            return
        }

        // Escape cancels recording
        if event.keyCode == 53 {
            cancelRecording()
            return
        }

        let relevantMods = event.modifierFlags.intersection([.command, .option, .shift, .control])
        let candidate = KeyShortcut(keyCode: event.keyCode, modifierFlags: relevantMods)

        let validation = UserSettings.shared.validateShortcut(candidate, for: actionType)
        switch validation {
        case .valid:
            UserSettings.shared.setShortcut(candidate, for: actionType)
            isRecording = false
            updateShortcutDisplay()
            onShortcutChanged?(candidate)
            onStatusChanged?("Assigned \(candidate.displayString) to \(actionType.displayName).", false)
        case .reservedBySystem(let reason):
            NSSound.beep()
            onStatusChanged?(reason, true)
        case .conflict(let conflictingAction):
            NSSound.beep()
            onStatusChanged?("Cannot assign \(candidate.displayString): conflicts with \"\(conflictingAction.displayName)\".", true)
        }
    }

    public override func resignFirstResponder() -> Bool {
        if isRecording {
            cancelRecording()
        }
        return super.resignFirstResponder()
    }
}

/// Native macOS AppKit Settings window controller.
public final class SettingsWindowController: NSWindowController {
    public static let shared = SettingsWindowController()

    private let tabView = NSTabView()
    private let segmentedControl = NSSegmentedControl()

    // General Controls
    private let quitOnCloseCheckbox = NSButton(checkboxWithTitle: "Quit when the last video window closes", target: nil, action: nil)
    private let fitAspectCheckbox = NSButton(checkboxWithTitle: "Open videos and fit window to video aspect ratio", target: nil, action: nil)
    private let rememberSizeCheckbox = NSButton(checkboxWithTitle: "Remember last window size", target: nil, action: nil)

    // Playback Controls
    private let hwdecPopup = NSPopUpButton()
    private let fastSpeedControl = NSSegmentedControl(labels: ["2×", "4×"], trackingMode: .selectOne, target: nil, action: nil)
    private let seekingBehaviorPopup = NSPopUpButton()
    private let fastPreviewCheckbox = NSButton(checkboxWithTitle: "Enable Fast Preview Mode by default", target: nil, action: nil)
    private let autoResumeCheckbox = NSButton(checkboxWithTitle: "Resume playback automatically when opening a file", target: nil, action: nil)

    // Frame Capture Controls
    private let capturePathField = NSTextField(labelWithString: "")
    private let capturePatternPopup = NSPopUpButton()
    private let showConfirmationCheckbox = NSButton(checkboxWithTitle: "Show confirmation banner after saving", target: nil, action: nil)

    // Shortcuts Controls
    private var shortcutButtons: [ShortcutRecorderButton] = []
    private let shortcutStatusLabel = NSTextField(labelWithString: "")

    public init() {
        let styleMask: NSWindow.StyleMask = [.titled, .closable]
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 460),
            styleMask: styleMask,
            backing: .buffered,
            defer: false
        )
        window.title = "UPreviewX Settings"
        window.center()
        window.isReleasedWhenClosed = false
        super.init(window: window)

        setupUI()
        loadSettings()
    }

    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public func showSettings() {
        loadSettings()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func setupUI() {
        guard let win = window, let contentView = win.contentView else { return }

        // Top Segmented Bar for Tabs
        segmentedControl.segmentCount = 4
        segmentedControl.setLabel("General", forSegment: 0)
        segmentedControl.setLabel("Playback", forSegment: 1)
        segmentedControl.setLabel("Frame Capture", forSegment: 2)
        segmentedControl.setLabel("Shortcuts", forSegment: 3)
        segmentedControl.selectedSegment = 0
        segmentedControl.target = self
        segmentedControl.action = #selector(handleTabSegmentChanged(_:))
        segmentedControl.translatesAutoresizingMaskIntoConstraints = false

        // Tab View
        tabView.tabViewType = .noTabsNoBorder
        tabView.translatesAutoresizingMaskIntoConstraints = false

        let generalTab = NSTabViewItem(identifier: "General")
        generalTab.view = buildGeneralTabView()
        tabView.addTabViewItem(generalTab)

        let playbackTab = NSTabViewItem(identifier: "Playback")
        playbackTab.view = buildPlaybackTabView()
        tabView.addTabViewItem(playbackTab)

        let captureTab = NSTabViewItem(identifier: "FrameCapture")
        captureTab.view = buildCaptureTabView()
        tabView.addTabViewItem(captureTab)

        let shortcutsTab = NSTabViewItem(identifier: "Shortcuts")
        shortcutsTab.view = buildShortcutsTabView()
        tabView.addTabViewItem(shortcutsTab)

        contentView.addSubview(segmentedControl)
        contentView.addSubview(tabView)

        NSLayoutConstraint.activate([
            segmentedControl.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
            segmentedControl.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            segmentedControl.heightAnchor.constraint(equalToConstant: 24),

            tabView.topAnchor.constraint(equalTo: segmentedControl.bottomAnchor, constant: 14),
            tabView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            tabView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            tabView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16)
        ])
    }

    // MARK: - Tab Views

    private func buildGeneralTabView() -> NSView {
        let view = NSView()

        quitOnCloseCheckbox.target = self
        quitOnCloseCheckbox.action = #selector(handleGeneralSettingChanged)

        fitAspectCheckbox.target = self
        fitAspectCheckbox.action = #selector(handleGeneralSettingChanged)

        rememberSizeCheckbox.target = self
        rememberSizeCheckbox.action = #selector(handleGeneralSettingChanged)

        let stack = NSStackView(views: [
            quitOnCloseCheckbox,
            fitAspectCheckbox,
            rememberSizeCheckbox
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16)
        ])

        return view
    }

    private func buildPlaybackTabView() -> NSView {
        let view = NSView()

        // Hardware Acceleration
        let hwLabel = NSTextField(labelWithString: "Hardware acceleration:")
        hwLabel.font = .systemFont(ofSize: 12, weight: .medium)
        hwdecPopup.removeAllItems()
        for mode in HardwareAccelerationMode.allCases {
            hwdecPopup.addItem(withTitle: mode.displayName)
            hwdecPopup.lastItem?.representedObject = mode
        }
        hwdecPopup.target = self
        hwdecPopup.action = #selector(handlePlaybackSettingChanged)

        let hwNote = NSTextField(labelWithString: "Note: Hardware acceleration changes take effect on next opened file.")
        hwNote.font = .systemFont(ofSize: 10.5)
        hwNote.textColor = .secondaryLabelColor

        let hwBox = NSStackView(views: [hwLabel, hwdecPopup, hwNote])
        hwBox.orientation = .vertical
        hwBox.alignment = .leading
        hwBox.spacing = 4

        // Fast Playback Speed
        let speedLabel = NSTextField(labelWithString: "Temporary fast playback speed:")
        speedLabel.font = .systemFont(ofSize: 12, weight: .medium)
        fastSpeedControl.target = self
        fastSpeedControl.action = #selector(handlePlaybackSettingChanged)
        let speedBox = NSStackView(views: [speedLabel, fastSpeedControl])
        speedBox.orientation = .horizontal
        speedBox.alignment = .centerY
        speedBox.spacing = 10

        // Fast Seeking Mode
        let seekLabel = NSTextField(labelWithString: "Fast seeking behavior:")
        seekLabel.font = .systemFont(ofSize: 12, weight: .medium)
        seekingBehaviorPopup.removeAllItems()
        for mode in FastSeekingMode.allCases {
            seekingBehaviorPopup.addItem(withTitle: mode.displayName)
            seekingBehaviorPopup.lastItem?.representedObject = mode
        }
        seekingBehaviorPopup.target = self
        seekingBehaviorPopup.action = #selector(handlePlaybackSettingChanged)
        let seekBox = NSStackView(views: [seekLabel, seekingBehaviorPopup])
        seekBox.orientation = .horizontal
        seekBox.alignment = .centerY
        seekBox.spacing = 10

        // Checkboxes
        fastPreviewCheckbox.target = self
        fastPreviewCheckbox.action = #selector(handlePlaybackSettingChanged)

        autoResumeCheckbox.target = self
        autoResumeCheckbox.action = #selector(handlePlaybackSettingChanged)

        let stack = NSStackView(views: [
            hwBox,
            speedBox,
            seekBox,
            fastPreviewCheckbox,
            autoResumeCheckbox
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 6),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16)
        ])

        return view
    }

    private func buildCaptureTabView() -> NSView {
        let view = NSView()

        let folderLabel = NSTextField(labelWithString: "Save captured frames to:")
        folderLabel.font = .systemFont(ofSize: 12, weight: .medium)

        capturePathField.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        capturePathField.lineBreakMode = .byTruncatingMiddle
        capturePathField.isSelectable = true
        capturePathField.isEditable = false
        capturePathField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let chooseFolderButton = NSButton(title: "Choose…", target: self, action: #selector(handleChooseCaptureFolder))
        let revealButton = NSButton(title: "Reveal", target: self, action: #selector(handleRevealCaptureFolder))

        let folderRow = NSStackView(views: [capturePathField, chooseFolderButton, revealButton])
        folderRow.orientation = .horizontal
        folderRow.alignment = .centerY
        folderRow.spacing = 8

        let folderBox = NSStackView(views: [folderLabel, folderRow])
        folderBox.orientation = .vertical
        folderBox.alignment = .leading
        folderBox.spacing = 4

        // Image Format
        let formatLabel = NSTextField(labelWithString: "Image format:")
        formatLabel.font = .systemFont(ofSize: 12, weight: .medium)
        let formatPopup = NSPopUpButton()
        formatPopup.addItem(withTitle: "PNG (Lossless 8-bit)")
        formatPopup.isEnabled = false
        let formatNote = NSTextField(labelWithString: "HDR and high-bit-depth streams are tone-mapped to standard 8-bit sRGB PNG.")
        formatNote.font = .systemFont(ofSize: 10.5)
        formatNote.textColor = .secondaryLabelColor

        let formatBox = NSStackView(views: [
            NSStackView(views: [formatLabel, formatPopup]),
            formatNote
        ])
        formatBox.orientation = .vertical
        formatBox.alignment = .leading
        formatBox.spacing = 3

        // Filename Pattern
        let patternLabel = NSTextField(labelWithString: "Filename pattern:")
        patternLabel.font = .systemFont(ofSize: 12, weight: .medium)
        capturePatternPopup.removeAllItems()
        for pat in CaptureFilenamePattern.allCases {
            capturePatternPopup.addItem(withTitle: pat.displayName)
            capturePatternPopup.lastItem?.representedObject = pat
        }
        capturePatternPopup.target = self
        capturePatternPopup.action = #selector(handleCaptureSettingChanged)
        let patternBox = NSStackView(views: [patternLabel, capturePatternPopup])
        patternBox.orientation = .vertical
        patternBox.alignment = .leading
        patternBox.spacing = 4

        // Confirmation Checkbox
        showConfirmationCheckbox.target = self
        showConfirmationCheckbox.action = #selector(handleCaptureSettingChanged)

        let stack = NSStackView(views: [
            folderBox,
            formatBox,
            patternBox,
            showConfirmationCheckbox
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 11
        stack.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 6),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16)
        ])

        return view
    }

    private func buildShortcutsTabView() -> NSView {
        let container = NSView()
        shortcutButtons.removeAll()

        let headerLabel = NSTextField(labelWithString: "Click any shortcut button to record a new key combination. Press Esc to cancel.")
        headerLabel.font = .systemFont(ofSize: 11, weight: .regular)
        headerLabel.textColor = .secondaryLabelColor
        headerLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(headerLabel)

        let rowsStack = NSStackView()
        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.spacing = 7
        rowsStack.translatesAutoresizingMaskIntoConstraints = false

        for action in ShortcutAction.allCases {
            let row = buildShortcutRow(for: action)
            rowsStack.addArrangedSubview(row)
            row.leadingAnchor.constraint(equalTo: rowsStack.leadingAnchor).isActive = true
            row.trailingAnchor.constraint(equalTo: rowsStack.trailingAnchor).isActive = true
        }

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let clipView = NSClipView()
        clipView.drawsBackground = false
        clipView.documentView = rowsStack
        scrollView.contentView = clipView

        container.addSubview(scrollView)

        shortcutStatusLabel.font = .systemFont(ofSize: 11, weight: .medium)
        shortcutStatusLabel.textColor = .systemBlue
        shortcutStatusLabel.lineBreakMode = .byWordWrapping
        shortcutStatusLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(shortcutStatusLabel)

        let restoreAllButton = NSButton(title: "Restore All Defaults", target: self, action: #selector(handleRestoreAllShortcuts))
        restoreAllButton.bezelStyle = .rounded
        restoreAllButton.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(restoreAllButton)

        NSLayoutConstraint.activate([
            headerLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 4),
            headerLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            headerLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),

            scrollView.topAnchor.constraint(equalTo: headerLabel.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            scrollView.bottomAnchor.constraint(equalTo: shortcutStatusLabel.topAnchor, constant: -8),

            rowsStack.widthAnchor.constraint(equalTo: scrollView.widthAnchor, constant: -18),

            shortcutStatusLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            shortcutStatusLabel.trailingAnchor.constraint(equalTo: restoreAllButton.leadingAnchor, constant: -12),
            shortcutStatusLabel.centerYAnchor.constraint(equalTo: restoreAllButton.centerYAnchor),

            restoreAllButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            restoreAllButton.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -4)
        ])

        return container
    }

    private func buildShortcutRow(for action: ShortcutAction) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: action.displayName)
        titleLabel.font = .systemFont(ofSize: 12, weight: .regular)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let recorder = ShortcutRecorderButton(actionType: action)
        recorder.translatesAutoresizingMaskIntoConstraints = false
        shortcutButtons.append(recorder)

        recorder.onStatusChanged = { [weak self] message, isError in
            self?.shortcutStatusLabel.stringValue = message
            self?.shortcutStatusLabel.textColor = isError ? .systemRed : .systemBlue
        }

        let resetButton = NSButton()
        resetButton.bezelStyle = .roundRect
        resetButton.isBordered = false
        resetButton.toolTip = "Restore default shortcut"
        if let img = NSImage(systemSymbolName: "arrow.counterclockwise", accessibilityDescription: "Reset") {
            let conf = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
            resetButton.image = img.withSymbolConfiguration(conf)
        }
        resetButton.target = self
        resetButton.action = #selector(handleIndividualShortcutReset(_:))
        resetButton.identifier = NSUserInterfaceItemIdentifier(action.rawValue)
        resetButton.translatesAutoresizingMaskIntoConstraints = false

        row.addSubview(titleLabel)
        row.addSubview(recorder)
        row.addSubview(resetButton)

        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(equalToConstant: 26),

            titleLabel.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 4),
            titleLabel.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: recorder.leadingAnchor, constant: -8),

            recorder.trailingAnchor.constraint(equalTo: resetButton.leadingAnchor, constant: -8),
            recorder.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            recorder.widthAnchor.constraint(greaterThanOrEqualToConstant: 100),
            recorder.heightAnchor.constraint(equalToConstant: 24),

            resetButton.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -4),
            resetButton.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            resetButton.widthAnchor.constraint(equalToConstant: 20),
            resetButton.heightAnchor.constraint(equalToConstant: 20)
        ])

        return row
    }

    // MARK: - State Management

    private func loadSettings() {
        let settings = UserSettings.shared

        // General
        quitOnCloseCheckbox.state = settings.quitWhenLastWindowCloses ? .on : .off
        fitAspectCheckbox.state = settings.fitWindowToAspectRatio ? .on : .off
        rememberSizeCheckbox.state = settings.rememberLastWindowSize ? .on : .off

        // Playback
        for item in hwdecPopup.itemArray {
            if (item.representedObject as? HardwareAccelerationMode) == settings.hardwareAcceleration {
                hwdecPopup.select(item)
                break
            }
        }
        fastSpeedControl.selectedSegment = (settings.temporaryFastSpeed >= 3.0) ? 1 : 0
        for item in seekingBehaviorPopup.itemArray {
            if (item.representedObject as? FastSeekingMode) == settings.fastSeekingBehavior {
                seekingBehaviorPopup.select(item)
                break
            }
        }
        fastPreviewCheckbox.state = settings.fastPreviewModeByDefault ? .on : .off
        autoResumeCheckbox.state = settings.autoResumePlaybackOnOpen ? .on : .off

        // Frame Capture
        capturePathField.stringValue = settings.captureOutputDirectoryURL.path
        for item in capturePatternPopup.itemArray {
            if (item.representedObject as? CaptureFilenamePattern) == settings.captureFilenamePattern {
                capturePatternPopup.select(item)
                break
            }
        }
        showConfirmationCheckbox.state = settings.showCaptureConfirmation ? .on : .off

        // Shortcuts
        for btn in shortcutButtons {
            btn.updateShortcutDisplay()
        }
        shortcutStatusLabel.stringValue = ""
    }

    @objc private func handleTabSegmentChanged(_ sender: NSSegmentedControl) {
        tabView.selectTabViewItem(at: sender.selectedSegment)
    }

    @objc private func handleGeneralSettingChanged() {
        let settings = UserSettings.shared
        settings.quitWhenLastWindowCloses = (quitOnCloseCheckbox.state == .on)
        settings.fitWindowToAspectRatio = (fitAspectCheckbox.state == .on)
        settings.rememberLastWindowSize = (rememberSizeCheckbox.state == .on)
    }

    @objc private func handlePlaybackSettingChanged() {
        let settings = UserSettings.shared
        if let mode = hwdecPopup.selectedItem?.representedObject as? HardwareAccelerationMode {
            settings.hardwareAcceleration = mode
        }
        settings.temporaryFastSpeed = (fastSpeedControl.selectedSegment == 1) ? 4.0 : 2.0
        if let seekMode = seekingBehaviorPopup.selectedItem?.representedObject as? FastSeekingMode {
            settings.fastSeekingBehavior = seekMode
        }
        settings.fastPreviewModeByDefault = (fastPreviewCheckbox.state == .on)
        settings.autoResumePlaybackOnOpen = (autoResumeCheckbox.state == .on)
    }

    @objc private func handleCaptureSettingChanged() {
        let settings = UserSettings.shared
        if let pat = capturePatternPopup.selectedItem?.representedObject as? CaptureFilenamePattern {
            settings.captureFilenamePattern = pat
        }
        settings.showCaptureConfirmation = (showConfirmationCheckbox.state == .on)
    }

    @objc private func handleChooseCaptureFolder() {
        let panel = NSOpenPanel()
        panel.title = "Select Frame Capture Directory"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = UserSettings.shared.captureOutputDirectoryURL

        if panel.runModal() == .OK, let selectedURL = panel.url {
            UserSettings.shared.captureOutputDirectoryURL = selectedURL
            capturePathField.stringValue = selectedURL.path
        }
    }

    @objc private func handleRevealCaptureFolder() {
        let url = UserSettings.shared.captureOutputDirectoryURL
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: url.path)
    }

    @objc private func handleIndividualShortcutReset(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue,
              let action = ShortcutAction(rawValue: raw) else { return }
        UserSettings.shared.resetShortcut(for: action)
        for btn in shortcutButtons where btn.actionType == action {
            btn.updateShortcutDisplay()
        }
        shortcutStatusLabel.stringValue = "Restored default shortcut for \(action.displayName)."
        shortcutStatusLabel.textColor = .systemBlue
    }

    @objc private func handleRestoreAllShortcuts() {
        UserSettings.shared.resetAllShortcuts()
        for btn in shortcutButtons {
            btn.updateShortcutDisplay()
        }
        shortcutStatusLabel.stringValue = "Restored all shortcuts to defaults."
        shortcutStatusLabel.textColor = .systemBlue
    }
}
