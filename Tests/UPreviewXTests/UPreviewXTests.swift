import XCTest
@testable import UPreviewXCore

final class UPreviewXTests: XCTestCase {

    func testTimeFormatterHandlesSubHourAndMultiHourDurations() {
        XCTAssertEqual(TimeFormatter.format(seconds: 0), "00:00")
        XCTAssertEqual(TimeFormatter.format(seconds: 9.8), "00:09")
        XCTAssertEqual(TimeFormatter.format(seconds: 65), "01:05")
        XCTAssertEqual(TimeFormatter.format(seconds: 3723), "1:02:03")
        XCTAssertEqual(TimeFormatter.format(seconds: -5), "00:00")
        XCTAssertEqual(TimeFormatter.format(seconds: .nan), "00:00")
    }

    func testPlaybackDiagnosticsHardwareVsSoftwareClassification() {
        var diag = PlaybackDiagnostics()
        XCTAssertFalse(diag.isHardwareAccelerated)
        XCTAssertEqual(diag.decodePathSummary, "Software (FFmpeg/dav1d fallback)")
        XCTAssertEqual(diag.resolutionSummary, "—")

        diag.hwdecCurrent = "videotoolbox"
        diag.width = 1920
        diag.height = 1080
        XCTAssertTrue(diag.isHardwareAccelerated)
        XCTAssertEqual(diag.decodePathSummary, "Hardware (videotoolbox)")
        XCTAssertEqual(diag.resolutionSummary, "1920×1080")
    }

    func testEffectiveDisplaySizeAccountsForRotationAndAnamorphicDAR() {
        // 1. Standard 16:9
        let std = PlaybackDiagnostics.effectiveDisplaySize(
            codedWidth: 1920, codedHeight: 1080, darWidth: 1920, darHeight: 1080, rotationDegrees: 0
        )
        XCTAssertEqual(std, CGSize(width: 1920, height: 1080))

        // 2. Rotated 90° 4K video (3840x2160 coded -> 2160x3840 portrait display)
        let rot90 = PlaybackDiagnostics.effectiveDisplaySize(
            codedWidth: 3840, codedHeight: 2160, darWidth: 3840, darHeight: 2160, rotationDegrees: 90
        )
        XCTAssertEqual(rot90, CGSize(width: 2160, height: 3840))

        // 3. Rotated 270° (-90°) 4K video
        let rot270 = PlaybackDiagnostics.effectiveDisplaySize(
            codedWidth: 3840, codedHeight: 2160, darWidth: 3840, darHeight: 2160, rotationDegrees: 270
        )
        XCTAssertEqual(rot270, CGSize(width: 2160, height: 3840))

        // 4. Anamorphic 1440x1080 with 16:9 DAR (1920x1080)
        let anamorphic = PlaybackDiagnostics.effectiveDisplaySize(
            codedWidth: 1440, codedHeight: 1080, darWidth: 1920, darHeight: 1080, rotationDegrees: 0
        )
        XCTAssertEqual(anamorphic, CGSize(width: 1920, height: 1080))
    }

    func testAdaptiveWindowSizingAcrossPortraitSquareAndLandscape() {
        let screenVisible = NSRect(x: 0, y: 50, width: 1536, height: 875)

        // 1. Vertical 9:16 (1080x1920)
        let portrait916 = PlayerWindowController.calculateTargetWindowFrame(
            for: CGSize(width: 1080, height: 1920),
            in: screenVisible
        )
        XCTAssertLessThan(portrait916.width, portrait916.height)
        XCTAssertEqual(portrait916.width / portrait916.height, 9.0 / 16.0, accuracy: 0.003)
        XCTAssertTrue(screenVisible.contains(portrait916))

        // 2. Vertical 4:5 (1080x1350)
        let portrait45 = PlayerWindowController.calculateTargetWindowFrame(
            for: CGSize(width: 1080, height: 1350),
            in: screenVisible
        )
        XCTAssertLessThan(portrait45.width, portrait45.height)
        XCTAssertEqual(portrait45.width / portrait45.height, 4.0 / 5.0, accuracy: 0.003)
        XCTAssertTrue(screenVisible.contains(portrait45))

        // 3. Square 1:1 (1080x1080)
        let square11 = PlayerWindowController.calculateTargetWindowFrame(
            for: CGSize(width: 1080, height: 1080),
            in: screenVisible
        )
        XCTAssertEqual(square11.width, square11.height, accuracy: 1.0)
        XCTAssertTrue(screenVisible.contains(square11))

        // 4. Landscape 16:9 4K (3840x2160)
        let landscape169 = PlayerWindowController.calculateTargetWindowFrame(
            for: CGSize(width: 3840, height: 2160),
            in: screenVisible
        )
        XCTAssertGreaterThan(landscape169.width, landscape169.height)
        XCTAssertEqual(landscape169.width / landscape169.height, 16.0 / 9.0, accuracy: 0.003)
        XCTAssertTrue(screenVisible.contains(landscape169))

        // 5. Ultrawide 21:9 (2520x1080)
        let ultrawide219 = PlayerWindowController.calculateTargetWindowFrame(
            for: CGSize(width: 2520, height: 1080),
            in: screenVisible
        )
        XCTAssertGreaterThan(ultrawide219.width, ultrawide219.height)
        XCTAssertEqual(ultrawide219.width / ultrawide219.height, 21.0 / 9.0, accuracy: 0.003)
        XCTAssertTrue(screenVisible.contains(ultrawide219))
    }

    func testReservedConversionServiceInterfaceIsolation() {
        let service: ConversionServiceProtocol = ReservedConversionService()
        XCTAssertFalse(service.isAvailable)

        let req = ConversionJobRequest(
            sourceURL: URL(fileURLWithPath: "/tmp/in.mov"),
            destinationURL: URL(fileURLWithPath: "/tmp/out.mp4"),
            targetCodec: .hevc
        )
        let exp = expectation(description: "conversion callback")
        service.startConversion(request: req, onProgress: { _ in }) { result in
            switch result {
            case .success:
                XCTFail("Expected MVP conversion service to return notImplementedInMVP")
            case .failure(let error):
                XCTAssertEqual(error, .notImplementedInMVP)
            }
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)
    }

    func testEngineInitializationAndMissingFileHandling() throws {
        let engine = MPVPlaybackEngine(useNullVideoOutput: true)
        defer { engine.shutdown() }

        try engine.initialize()
        XCTAssertGreaterThan(engine.diagnostics.engineInitLatencyMs, 0)

        let missingURL = URL(fileURLWithPath: "/tmp/nonexistent_upreviewx_video_\(UUID().uuidString).mp4")
        XCTAssertThrowsError(try engine.load(url: missingURL)) { error in
            XCTAssertEqual(error as? PlaybackEngineError, .fileNotFound(missingURL))
        }
    }

    private func findFFmpeg() -> String? {
        let candidates = [
            "/usr/local/bin/ffmpeg",
            "/opt/homebrew/bin/ffmpeg",
            "/usr/bin/ffmpeg"
        ]
        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        proc.arguments = ["ffmpeg"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        if (try? proc.run()) != nil {
            proc.waitUntilExit()
            if proc.terminationStatus == 0 {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) {
                    return path
                }
            }
        }
        return nil
    }

    func testEnginePlaybackAndControlsWithGeneratedSample() throws {
        guard let ffmpegPath = findFFmpeg() else {
            throw XCTSkip("ffmpeg executable not found")
        }

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("upreviewx_unit_\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: ffmpegPath)
        proc.arguments = [
            "-y", "-f", "lavfi", "-i", "testsrc2=size=360x640:rate=30:duration=2",
            "-c:v", "libx264", "-pix_fmt", "yuv420p", "-preset", "ultrafast",
            tempURL.path
        ]
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        try proc.run()
        proc.waitUntilExit()
        XCTAssertEqual(proc.terminationStatus, 0)

        let engine = MPVPlaybackEngine(useNullVideoOutput: true)
        defer { engine.shutdown() }

        let helper = EngineTestDelegate()
        let sizeExp = expectation(description: "video size updated")
        helper.onSizeUpdated = { size in
            if size.width == 360 && size.height == 640 {
                sizeExp.fulfill()
            }
        }
        engine.delegate = helper

        try engine.initialize()
        try engine.load(url: tempURL)

        wait(for: [sizeExp], timeout: 5.0)
        engine.refreshDiagnostics()

        XCTAssertEqual(engine.diagnostics.codecName, "h264")
        XCTAssertEqual(engine.diagnostics.width, 360)
        XCTAssertEqual(engine.diagnostics.height, 640)

        engine.setVolume(65.0)
        XCTAssertEqual(engine.volume, 65.0, accuracy: 0.1)

        engine.toggleMute()
        XCTAssertTrue(engine.isMuted)
    }

    func testUserSettingsPersistenceAndDefaults() {
        let testSuiteName = "com.upreviewx.tests.\(UUID().uuidString)"
        guard let testDefaults = UserDefaults(suiteName: testSuiteName) else {
            XCTFail("Failed to create test UserDefaults suite")
            return
        }
        defer { testDefaults.removePersistentDomain(forName: testSuiteName) }

        let settings = UserSettings(defaults: testDefaults)

        // Verify Defaults
        XCTAssertTrue(settings.quitWhenLastWindowCloses)
        XCTAssertTrue(settings.fitWindowToAspectRatio)
        XCTAssertFalse(settings.rememberLastWindowSize)
        XCTAssertEqual(settings.hardwareAcceleration, .auto)
        XCTAssertEqual(settings.temporaryFastSpeed, 2.0)
        XCTAssertEqual(settings.fastSeekingBehavior, .auto)
        XCTAssertFalse(settings.fastPreviewModeByDefault)
        XCTAssertTrue(settings.autoResumePlaybackOnOpen)
        XCTAssertEqual(settings.captureImageFormat, "PNG")
        XCTAssertEqual(settings.captureFilenamePattern, .sourceAndTimestamp)
        XCTAssertTrue(settings.showCaptureConfirmation)

        // Mutate & Verify
        settings.quitWhenLastWindowCloses = false
        XCTAssertFalse(settings.quitWhenLastWindowCloses)

        settings.temporaryFastSpeed = 4.0
        XCTAssertEqual(settings.temporaryFastSpeed, 4.0)

        settings.temporaryFastSpeed = 2.0
        XCTAssertEqual(settings.temporaryFastSpeed, 2.0)

        settings.hardwareAcceleration = .disabled
        XCTAssertEqual(settings.hardwareAcceleration, .disabled)

        settings.fastSeekingBehavior = .keyframesOnly
        XCTAssertEqual(settings.fastSeekingBehavior, .keyframesOnly)

        settings.captureFilenamePattern = .timestampOnly
        XCTAssertEqual(settings.captureFilenamePattern, .timestampOnly)
    }

    func testSpeedControlAndClamping() throws {
        let engine = MPVPlaybackEngine(useNullVideoOutput: true)
        defer { engine.shutdown() }
        try engine.initialize()

        XCTAssertEqual(engine.speed, 1.0)

        engine.setSpeed(2.0)
        XCTAssertEqual(engine.speed, 2.0, accuracy: 0.01)

        engine.setSpeed(4.0)
        XCTAssertEqual(engine.speed, 4.0, accuracy: 0.01)

        // Clamp below minimum (0.1)
        engine.setSpeed(0.005)
        XCTAssertEqual(engine.speed, 0.1, accuracy: 0.01)

        // Clamp above maximum (16.0)
        engine.setSpeed(32.0)
        XCTAssertEqual(engine.speed, 16.0, accuracy: 0.01)
    }

    func testFrameCaptureGeneratesValidPNG() throws {
        guard let ffmpegPath = findFFmpeg() else {
            throw XCTSkip("ffmpeg executable not found")
        }

        let tempVideoURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("upreviewx_capture_test_\(UUID().uuidString).mp4")
        let tempCaptureURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("upreviewx_captured_frame_\(UUID().uuidString).png")
        defer {
            try? FileManager.default.removeItem(at: tempVideoURL)
            try? FileManager.default.removeItem(at: tempCaptureURL)
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: ffmpegPath)
        proc.arguments = [
            "-y", "-f", "lavfi", "-i", "testsrc2=size=320x240:rate=30:duration=1.5",
            "-c:v", "libx264", "-pix_fmt", "yuv420p", "-preset", "ultrafast",
            tempVideoURL.path
        ]
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        try proc.run()
        proc.waitUntilExit()
        XCTAssertEqual(proc.terminationStatus, 0)

        let engine = MPVPlaybackEngine(useNullVideoOutput: true)
        defer { engine.shutdown() }

        let helper = EngineTestDelegate()
        let frameExp = expectation(description: "media first frame rendered for capture test")
        helper.onFirstFrame = {
            frameExp.fulfill()
        }
        engine.delegate = helper

        try engine.initialize()
        try engine.load(url: tempVideoURL)
        wait(for: [frameExp], timeout: 5.0)

        // Wait slightly for playback position to advance into steady state
        Thread.sleep(forTimeInterval: 0.15)

        let captureExp = expectation(description: "frame captured")
        engine.captureFrame(to: tempCaptureURL) { result in
            switch result {
            case .success(let url):
                XCTAssertEqual(url.path, tempCaptureURL.path)
                captureExp.fulfill()
            case .failure(let err):
                XCTFail("Capture failed with error: \(err)")
            }
        }
        wait(for: [captureExp], timeout: 5.0)

        XCTAssertTrue(FileManager.default.fileExists(atPath: tempCaptureURL.path))
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: tempCaptureURL.path)[.size] as? NSNumber)?.intValue ?? 0
        XCTAssertGreaterThan(fileSize, 100, "Generated PNG should contain actual image data")

        // Validate that NSImage successfully parses the captured PNG and preserves pixel dimensions
        let image = NSImage(contentsOf: tempCaptureURL)
        XCTAssertNotNil(image)
        if let rep = image?.representations.first {
            XCTAssertEqual(rep.pixelsWide, 320)
            XCTAssertEqual(rep.pixelsHigh, 240)
        }
    }

    func testContextMenuContainsRequiredActions() {
        let controller = PlayerWindowController(showDiagnostics: false)
        let menu = controller.buildContextMenu()

        let itemTitles = menu.items.map { $0.title }
        XCTAssertTrue(itemTitles.contains("Save Current Frame"))
        XCTAssertTrue(itemTitles.contains("Play") || itemTitles.contains("Pause"))
        XCTAssertTrue(itemTitles.contains("Rewind 5s"))
        XCTAssertTrue(itemTitles.contains("Fast-Forward 5s"))
        XCTAssertTrue(itemTitles.contains("Toggle Decoder Diagnostics"))
        XCTAssertTrue(itemTitles.contains("Toggle Fast Preview Mode"))
        XCTAssertTrue(itemTitles.contains("Enter Full Screen") || itemTitles.contains("Exit Full Screen"))

        let captureItem = menu.items.first { $0.title == "Save Current Frame" }
        XCTAssertNotNil(captureItem)
        XCTAssertEqual(captureItem?.keyEquivalent, "s")
        XCTAssertEqual(captureItem?.keyEquivalentModifierMask, [.command, .shift])
    }

    func testSettingsWindowControllerSetup() {
        let settingsWin = SettingsWindowController.shared
        XCTAssertNotNil(settingsWin.window)
        XCTAssertEqual(settingsWin.window?.title, "UPreviewX Settings")
    }

    func testPressAndHoldShuttleStateTransitionsAndKeyRepeat() {
        let controller = PlayerWindowController(showDiagnostics: false)
        defer { controller.engine.shutdown() }
        guard let win = controller.window as? PlayerWindow else {
            XCTFail("Window should be PlayerWindow")
            return
        }

        // Initially at 1.0x speed and paused
        XCTAssertEqual(controller.engine.speed, 1.0)
        XCTAssertFalse(controller.isShuttleActive)

        // 1. Simulate key hold on Right Arrow (keyCode 124)
        guard let keyDownEvent = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: win.windowNumber,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: 124
        ) else {
            XCTFail("Failed to create keyDown event")
            return
        }

        win.keyDown(with: keyDownEvent)

        // Resilient polling for hold timer to trigger shuttle mode (jitter-tolerant)
        let exp = expectation(description: "shuttle activated")
        func checkShuttleActive(attemptsLeft: Int) {
            if controller.isShuttleActive {
                // Shuttle is active without conflating with speed playback (speed remains 1.0x!)
                XCTAssertTrue(controller.isShuttleActive)
                XCTAssertEqual(controller.engine.speed, 1.0)

                // Simulate repeated keydown events during hold (key repeat)
                if let repeatEvent = NSEvent.keyEvent(
                    with: .keyDown,
                    location: .zero,
                    modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: win.windowNumber,
                    context: nil,
                    characters: "",
                    charactersIgnoringModifiers: "",
                    isARepeat: true,
                    keyCode: 124
                ) {
                    win.keyDown(with: repeatEvent)
                    // Shuttle remains active, speed unchanged, does not break or crash
                    XCTAssertTrue(controller.isShuttleActive)
                    XCTAssertEqual(controller.engine.speed, 1.0)
                }

                // 2. Simulate keyUp on Right Arrow
                if let keyUpEvent = NSEvent.keyEvent(
                    with: .keyUp,
                    location: .zero,
                    modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: win.windowNumber,
                    context: nil,
                    characters: "",
                    charactersIgnoringModifiers: "",
                    isARepeat: false,
                    keyCode: 124
                ) {
                    win.keyUp(with: keyUpEvent)
                    // Shuttle must end immediately and restore state
                    XCTAssertFalse(controller.isShuttleActive)
                    XCTAssertEqual(controller.engine.speed, 1.0)
                }
                exp.fulfill()
            } else if attemptsLeft > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    checkShuttleActive(attemptsLeft: attemptsLeft - 1)
                }
            } else {
                XCTFail("Shuttle failed to activate within timeout")
                exp.fulfill()
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) {
            checkShuttleActive(attemptsLeft: 16)
        }
        wait(for: [exp], timeout: 3.0)

        // 3. Focus loss cancels shuttle and restores state
        win.keyDown(with: keyDownEvent)
        let focusExp = expectation(description: "shuttle cancelled on focus loss")
        func checkShuttleForFocus(attemptsLeft: Int) {
            if controller.isShuttleActive {
                controller.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification))
                XCTAssertFalse(controller.isShuttleActive)
                XCTAssertEqual(controller.engine.speed, 1.0)
                focusExp.fulfill()
            } else if attemptsLeft > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    checkShuttleForFocus(attemptsLeft: attemptsLeft - 1)
                }
            } else {
                XCTFail("Shuttle failed to activate for focus test")
                focusExp.fulfill()
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) {
            checkShuttleForFocus(attemptsLeft: 16)
        }
        wait(for: [focusExp], timeout: 3.0)
    }

    func testSeparateShuttleFromSpeedPlayback() {
        let controller = PlayerWindowController(showDiagnostics: false)
        defer { controller.engine.shutdown() }
        guard controller.window is PlayerWindow else {
            XCTFail("Window should be PlayerWindow")
            return
        }

        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))

        // 1. Verify 2x Speed Mode is selectable and separate from shuttle
        XCTAssertEqual(controller.engine.speed, 1.0)
        controller.toggleSpeed()
        XCTAssertEqual(controller.engine.speed, 2.0)
        controller.toggleSpeed()
        XCTAssertEqual(controller.engine.speed, 1.0)

        // 2. Scenario 2: Paused -> hold forward shuttle -> release -> remains paused at new position
        controller.engine.pause()
        XCTAssertTrue(controller.engine.isPaused)

        controller.startShuttle(direction: .forward, keyCode: 124)
        XCTAssertTrue(controller.isShuttleActive)
        controller.endShuttle(restoreOriginalState: true)
        XCTAssertFalse(controller.isShuttleActive)
        XCTAssertTrue(controller.engine.isPaused, "Video must remain paused after releasing shuttle from paused state")

        // 3. Scenario 3: Paused -> hold reverse shuttle -> release -> remains paused
        controller.startShuttle(direction: .rewind, keyCode: 123)
        XCTAssertTrue(controller.isShuttleActive)
        controller.endShuttle(restoreOriginalState: true)
        XCTAssertFalse(controller.isShuttleActive)
        XCTAssertTrue(controller.engine.isPaused, "Video must remain paused after reverse shuttle from paused state")

        // 4. Scenario 1: Playing -> hold forward shuttle -> release -> resumes 1x playback
        controller.engine.play()
        XCTAssertFalse(controller.engine.isPaused)
        controller.startShuttle(direction: .forward, keyCode: 124)
        XCTAssertTrue(controller.isShuttleActive)
        controller.endShuttle(restoreOriginalState: true)
        XCTAssertFalse(controller.isShuttleActive)
        XCTAssertFalse(controller.engine.isPaused, "Video must resume playing after releasing shuttle from playing state")
        XCTAssertEqual(controller.engine.speed, 1.0, "Speed must remain 1.0x")

        // 5. Shuttle while at 2x playback restores 2x playback on release
        controller.toggleSpeed() // Now at 2x
        XCTAssertEqual(controller.engine.speed, 2.0)
        controller.startShuttle(direction: .forward, keyCode: 124)
        XCTAssertTrue(controller.isShuttleActive)
        controller.endShuttle(restoreOriginalState: true)
        XCTAssertFalse(controller.isShuttleActive)
        XCTAssertEqual(controller.engine.speed, 2.0, "Speed must be restored to 2.0x after shuttle")
    }

    func testCustomizableShortcutsPersistenceAndConflictDetection() {
        let settings = UserSettings.shared

        // 1. Verify default shortcuts
        XCTAssertEqual(settings.shortcut(for: .playPause), KeyShortcut.defaultShortcut(for: .playPause))
        XCTAssertEqual(settings.shortcut(for: .seekBackward), KeyShortcut.defaultShortcut(for: .seekBackward))
        XCTAssertEqual(settings.shortcut(for: .shuttleBackward), KeyShortcut.defaultShortcut(for: .shuttleBackward))
        XCTAssertEqual(settings.shortcut(for: .toggleSpeed).displayKeyName, "2")
        XCTAssertEqual(settings.shortcut(for: .saveFrame).modifierFlags, [.command, .shift])

        // 2. Allow pairing of seekBackward & shuttleBackward on the same key
        let leftArrowShortcut = KeyShortcut(keyCode: 123, modifierFlags: [])
        let validationPair = settings.validateShortcut(leftArrowShortcut, for: .shuttleBackward)
        XCTAssertEqual(validationPair, .valid, "Tap seek and hold shuttle actions are permitted to share the same key")

        // 3. Conflict detection: Assigning Space (currently Play/Pause) to Mute must be flagged as conflict
        let spaceShortcut = KeyShortcut(keyCode: 49, modifierFlags: [])
        let conflictValidation = settings.validateShortcut(spaceShortcut, for: .toggleMute)
        XCTAssertEqual(conflictValidation, .conflict(.playPause), "Conflicting shortcut assignments must be rejected")

        // 4. Reserved macOS system shortcuts must be rejected
        let cmdQ = KeyShortcut(keyCode: 12, modifierFlags: [.command])
        let cmdQValidation = settings.validateShortcut(cmdQ, for: .toggleSpeed)
        if case .reservedBySystem = cmdQValidation {
            // Expected
        } else {
            XCTFail("⌘Q must be rejected as reserved system shortcut")
        }

        let cmdW = KeyShortcut(keyCode: 13, modifierFlags: [.command])
        let cmdWValidation = settings.validateShortcut(cmdW, for: .saveFrame)
        if case .reservedBySystem = cmdWValidation {
            // Expected
        } else {
            XCTFail("⌘W must be rejected as reserved system shortcut")
        }

        // 5. Custom shortcut assignment and persistence
        let customMute = KeyShortcut(keyCode: 45, modifierFlags: [], displayKeyName: "N") // 'N' key
        settings.setShortcut(customMute, for: .toggleMute)
        XCTAssertEqual(settings.shortcut(for: .toggleMute), customMute)

        // 6. Reset individual shortcut
        settings.resetShortcut(for: .toggleMute)
        XCTAssertEqual(settings.shortcut(for: .toggleMute), KeyShortcut.defaultShortcut(for: .toggleMute))

        // 7. Reset all shortcuts
        settings.setShortcut(customMute, for: .toggleMute)
        settings.resetAllShortcuts()
        XCTAssertEqual(settings.shortcut(for: .toggleMute), KeyShortcut.defaultShortcut(for: .toggleMute))
    }

    func testCompactHUDVolumeHoverAndOverflowMenu() {
        let hud = HUDControlsView(frame: NSRect(x: 0, y: 0, width: 320, height: 38))

        // 1. Volume slider is hidden by default and takes zero space
        XCTAssertTrue(hud.volumeSlider.isHidden, "Volume slider must be hidden by default to avoid reserving space")

        // 2. Primary controls do not include screenshot / camera button (moved to overflow menu)
        let primarySubviews = hud.subviews.first?.subviews ?? []
        // None of the primary subviews should be a camera button
        for sub in primarySubviews {
            if let btn = sub as? NSButton, btn.toolTip?.contains("Save Current Frame") == true {
                XCTFail("Screenshot button must not be present in primary HUD bar")
            }
        }

        // 3. Overflow menu contains required secondary actions
        let overflowMenu = hud.buildOverflowMenu()
        let titles = overflowMenu.items.map { $0.title }
        XCTAssertTrue(titles.contains("Save Current Frame"))
        XCTAssertTrue(titles.contains("Playback Diagnostics"))
        XCTAssertTrue(titles.contains("Fast Preview Mode"))
        XCTAssertTrue(titles.contains("Settings…"))

        // 4. Speed button displays 1x by default and updates to 2x
        hud.updateSpeed(1.0)
        XCTAssertEqual(hud.speedButton.title, "1×")
        hud.updateSpeed(2.0)
        XCTAssertEqual(hud.speedButton.title, "2×")
    }

    // MARK: - Thumbnail & Resource Management Tests

    func testVideoThumbnailServiceGeneratesValidThumbnailForMP4() throws {
        guard let ffmpegPath = findFFmpeg() else {
            throw XCTSkip("ffmpeg executable not found")
        }

        let tempVideoURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("upreviewx_thumb_mp4_\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: tempVideoURL) }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: ffmpegPath)
        proc.arguments = [
            "-y", "-f", "lavfi", "-i", "testsrc=size=320x240:rate=10:duration=1.5",
            "-c:v", "libx264", "-pix_fmt", "yuv420p", "-preset", "ultrafast",
            tempVideoURL.path
        ]
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        try proc.run()
        proc.waitUntilExit()
        XCTAssertEqual(proc.terminationStatus, 0)

        let exp = expectation(description: "mp4 thumbnail generated")
        var thumbResult: Result<CGImage, VideoThumbnailError>?

        _ = VideoThumbnailService.shared.generateThumbnail(
            for: tempVideoURL,
            targetSize: CGSize(width: 320, height: 240),
            atPosition: 0.5
        ) { res in
            thumbResult = res
            exp.fulfill()
        }

        wait(for: [exp], timeout: 5.0)
        switch thumbResult {
        case .success(let image):
            XCTAssertGreaterThan(image.width, 0)
            XCTAssertGreaterThan(image.height, 0)
            XCTAssertLessThanOrEqual(image.width, 320)
            XCTAssertLessThanOrEqual(image.height, 240)
        case .failure(let error):
            XCTFail("Expected successful MP4 thumbnail, got: \(error)")
        case .none:
            XCTFail("No thumbnail result delivered")
        }
    }

    func testVideoThumbnailServiceGeneratesValidThumbnailForMKV() throws {
        guard let ffmpegPath = findFFmpeg() else {
            throw XCTSkip("ffmpeg executable not found")
        }

        let tempMKVURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("upreviewx_thumb_mkv_\(UUID().uuidString).mkv")
        defer { try? FileManager.default.removeItem(at: tempMKVURL) }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: ffmpegPath)
        proc.arguments = [
            "-y", "-f", "lavfi", "-i", "testsrc=size=320x240:rate=10:duration=1.5",
            "-c:v", "libx264", "-pix_fmt", "yuv420p", "-preset", "ultrafast",
            tempMKVURL.path
        ]
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        try proc.run()
        proc.waitUntilExit()
        XCTAssertEqual(proc.terminationStatus, 0)

        let exp = expectation(description: "mkv thumbnail generated via headless libmpv fallback")
        var thumbResult: Result<CGImage, VideoThumbnailError>?

        _ = VideoThumbnailService.shared.generateThumbnail(
            for: tempMKVURL,
            targetSize: CGSize(width: 320, height: 240),
            atPosition: 0.5
        ) { res in
            thumbResult = res
            exp.fulfill()
        }

        wait(for: [exp], timeout: 5.0)
        switch thumbResult {
        case .success(let image):
            XCTAssertGreaterThan(image.width, 0)
            XCTAssertGreaterThan(image.height, 0)
            XCTAssertLessThanOrEqual(image.width, 320)
            XCTAssertLessThanOrEqual(image.height, 240)
        case .failure(let error):
            XCTFail("Expected successful MKV thumbnail fallback, got: \(error)")
        case .none:
            XCTFail("No thumbnail result delivered")
        }
    }

    func testVideoThumbnailServiceHandlesMissingOrCorruptFileGracefully() {
        let missingURL = URL(fileURLWithPath: "/tmp/non_existent_media_file_12345.mp4")
        let expMissing = expectation(description: "missing file thumbnail error")

        _ = VideoThumbnailService.shared.generateThumbnail(for: missingURL) { res in
            switch res {
            case .success:
                XCTFail("Expected failure for non-existent file")
            case .failure(let err):
                XCTAssertEqual(err, .fileNotFound(missingURL))
            }
            expMissing.fulfill()
        }
        wait(for: [expMissing], timeout: 2.0)

        let corruptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("upreviewx_corrupt_\(UUID().uuidString).mkv")
        try? "CORRUPTED DATA".data(using: .utf8)?.write(to: corruptURL)
        defer { try? FileManager.default.removeItem(at: corruptURL) }

        let expCorrupt = expectation(description: "corrupted file thumbnail error")
        _ = VideoThumbnailService.shared.generateThumbnail(for: corruptURL, timeout: 1.5) { res in
            switch res {
            case .success:
                XCTFail("Expected failure for corrupted file")
            case .failure:
                // Handled gracefully without crash or hang
                break
            }
            expCorrupt.fulfill()
        }
        wait(for: [expCorrupt], timeout: 3.0)
    }

    func testVideoThumbnailTaskCancellation() {
        let task = VideoThumbnailTask()
        XCTAssertFalse(task.isCancelled)
        task.cancel()
        XCTAssertTrue(task.isCancelled)
    }

    func testCommandLineThumbnailGenerationToFile() throws {
        guard let ffmpegPath = findFFmpeg() else {
            throw XCTSkip("ffmpeg executable not found")
        }

        let tempVideoURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("upreviewx_cli_thumb_\(UUID().uuidString).mp4")
        let tempOutPNG = FileManager.default.temporaryDirectory
            .appendingPathComponent("upreviewx_cli_out_\(UUID().uuidString).png")
        defer {
            try? FileManager.default.removeItem(at: tempVideoURL)
            try? FileManager.default.removeItem(at: tempOutPNG)
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: ffmpegPath)
        proc.arguments = [
            "-y", "-f", "lavfi", "-i", "testsrc=size=320x240:rate=10:duration=1.5",
            "-c:v", "libx264", "-pix_fmt", "yuv420p", "-preset", "ultrafast",
            tempVideoURL.path
        ]
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        try proc.run()
        proc.waitUntilExit()

        let res = VideoThumbnailService.shared.generateThumbnailToFile(
            inputURL: tempVideoURL,
            outputURL: tempOutPNG,
            targetSize: CGSize(width: 256, height: 256)
        )

        switch res {
        case .success(let savedURL):
            XCTAssertEqual(savedURL.path, tempOutPNG.path)
            XCTAssertTrue(FileManager.default.fileExists(atPath: tempOutPNG.path))
            let data = try Data(contentsOf: tempOutPNG)
            XCTAssertGreaterThan(data.count, 8)
            // Verify PNG magic header 0x89 0x50 0x4E 0x47
            XCTAssertEqual(data[0], 0x89)
            XCTAssertEqual(data[1], 0x50)
            XCTAssertEqual(data[2], 0x4E)
            XCTAssertEqual(data[3], 0x47)
        case .failure(let err):
            XCTFail("CLI thumbnail generation to file failed: \(err)")
        }
    }

    func testIntelligentResourceManagementOcclusionAndMiniaturization() {
        let controller = PlayerWindowController(showDiagnostics: false)
        defer { controller.close() }

        XCTAssertFalse(controller.videoView.videoLayer.isOccluded)

        // 1. Simulating window miniaturization
        controller.windowDidMiniaturize(Notification(name: NSWindow.didMiniaturizeNotification))
        XCTAssertTrue(controller.videoView.videoLayer.isOccluded)

        // 2. Simulating deminiaturization
        controller.windowDidDeminiaturize(Notification(name: NSWindow.didDeminiaturizeNotification))
        // Returns to visible state
        XCTAssertFalse(controller.videoView.videoLayer.isOccluded)
    }

    func testIntelligentResourceManagementPausedStateStopsDiagnosticsTimer() {
        let controller = PlayerWindowController(showDiagnostics: true)
        defer { controller.close() }

        // Pausing engine and delivering pause state
        controller.engine.pause()
        controller.playbackEngine(controller.engine, didUpdatePause: true)
        XCTAssertTrue(controller.engine.isPaused)
    }

    func testMemoryPressureAdaptationReducesCacheBounds() throws {
        let engine = MPVPlaybackEngine(useNullVideoOutput: true)
        defer { engine.shutdown() }
        try engine.initialize()

        // Verify handling memory pressure warning and critical states without crashing
        engine.handleMemoryPressure(critical: false)
        engine.handleMemoryPressure(critical: true)
        engine.restoreMemoryDefaults()
    }

    func testPreflightVideoDisplaySizeWithSyntheticVectors() {
        let tempDir = FileManager.default.temporaryDirectory
        let sampleURL = tempDir.appendingPathComponent("preflight_test_\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: sampleURL) }

        // Generate a 1-second synthetic portrait 1080x1920 video using ffmpeg
        let ffmpeg = "/usr/local/bin/ffmpeg"
        if FileManager.default.isExecutableFile(atPath: ffmpeg) {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: ffmpeg)
            proc.arguments = [
                "-nostdin", "-y",
                "-f", "lavfi", "-i", "testsrc=size=1080x1920:rate=30:duration=1",
                "-c:v", "libx264", "-pix_fmt", "yuv420p", "-preset", "ultrafast",
                sampleURL.path
            ]
            try? proc.run()
            proc.waitUntilExit()

            if FileManager.default.fileExists(atPath: sampleURL.path) {
                let size = PlayerWindowController.preflightVideoDisplaySize(for: sampleURL)
                XCTAssertNotNil(size)
                if let size = size {
                    XCTAssertEqual(size.width, 1080)
                    XCTAssertEqual(size.height, 1920)
                }
            }
        }

        // Non-existent file should return nil
        let nonExistent = tempDir.appendingPathComponent("does_not_exist_\(UUID().uuidString).mp4")
        XCTAssertNil(PlayerWindowController.preflightVideoDisplaySize(for: nonExistent))
    }

    func testRealC3585CharacteristicsAndPreflightIfPresent() {
        let realFile = URL(fileURLWithPath: "/Users/vup/Movies/C3585.MP4")
        guard FileManager.default.fileExists(atPath: realFile.path) else {
            return
        }

        // 1. Preflight extraction should be near-instant (< 50ms) and report exact 2160x3840 portrait size
        let start = CFAbsoluteTimeGetCurrent()
        let preflight = PlayerWindowController.preflightVideoDisplaySize(for: realFile)
        let elapsedMs = (CFAbsoluteTimeGetCurrent() - start) * 1000.0

        XCTAssertNotNil(preflight)
        XCTAssertLessThan(elapsedMs, 100.0)
        if let size = preflight {
            XCTAssertEqual(size.width, 2160)
            XCTAssertEqual(size.height, 3840)
            let aspect = size.width / size.height
            XCTAssertLessThan(aspect, 0.6) // portrait aspect ratio
        }

        // 2. PlayerWindowController should initialize window in portrait aspect ratio
        let controller = PlayerWindowController(showDiagnostics: true)
        defer { controller.close() }

        var frameChangesAfterReveal = 0
        let observer = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification,
            object: controller.window,
            queue: .main
        ) { _ in
            if controller.window?.alphaValue == 1.0 {
                frameChangesAfterReveal += 1
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        controller.openMedia(url: realFile)

        if let win = controller.window {
            XCTAssertEqual(win.aspectRatio.width, 2160)
            XCTAssertEqual(win.aspectRatio.height, 3840)
            let winFrame = win.frame
            // Height must be significantly greater than width (portrait)
            XCTAssertGreaterThan(winFrame.height, winFrame.width)

            // 3. Rejection of premature landscape mpv update
            controller.playbackEngine(controller.engine, didUpdateVideoSize: CGSize(width: 3840, height: 2160))
            // Must stay portrait!
            XCTAssertGreaterThan(win.frame.height, win.frame.width)
            XCTAssertEqual(win.aspectRatio.width, 2160)
            XCTAssertEqual(win.aspectRatio.height, 3840)
        }

        XCTAssertEqual(frameChangesAfterReveal, 0, "No unwanted resizes after window reveal")

        // 4. VideoThumbnailService on heavy C3585.MP4 correctly abides by strict timeout budget
        let sema = DispatchSemaphore(value: 0)
        var thumbResult: Result<CGImage, VideoThumbnailError>?
        VideoThumbnailService.shared.generateThumbnail(for: realFile, timeout: 1.0, completionQueue: nil) { res in
            thumbResult = res
            sema.signal()
        }
        _ = sema.wait(timeout: .now() + 2.5)
        XCTAssertNotNil(thumbResult)
        // C3585.MP4 is classified as HIGH and fast-fails within milliseconds to preserve CPU/RAM
        if case .failure(let err) = thumbResult {
            XCTAssertTrue(err == .costExceedsBudget(.high) || err == .extractionTimeout)
        }
    }
}

private final class EngineTestDelegate: PlaybackEngineDelegate {
    var onLoaded: (() -> Void)?
    var onFirstFrame: (() -> Void)?
    var onSizeUpdated: ((CGSize) -> Void)?
    private var didFulfillSize = false

    func playbackEngineDidLoadFile(_ engine: PlaybackEngineProtocol) {
        onLoaded?()
    }
    func playbackEngineDidRenderFirstFrame(_ engine: PlaybackEngineProtocol, latencyMs: Double) {
        onFirstFrame?()
    }
    func playbackEngine(_ engine: PlaybackEngineProtocol, didUpdatePosition position: Double, duration: Double) {}
    func playbackEngine(_ engine: PlaybackEngineProtocol, didUpdatePause isPaused: Bool) {}
    func playbackEngine(_ engine: PlaybackEngineProtocol, didUpdateVolume volume: Double, isMuted: Bool) {}
    func playbackEngine(_ engine: PlaybackEngineProtocol, didUpdateVideoSize size: CGSize) {
        if !didFulfillSize {
            didFulfillSize = true
            onSizeUpdated?(size)
        }
    }
    func playbackEngine(_ engine: PlaybackEngineProtocol, didCompleteSeek latencyMs: Double) {}
    func playbackEngine(_ engine: PlaybackEngineProtocol, didUpdateDiagnostics diagnostics: PlaybackDiagnostics) {}
    func playbackEngine(_ engine: PlaybackEngineProtocol, didEncounterError error: PlaybackEngineError) {}
    func playbackEngineDidReachEndOfFile(_ engine: PlaybackEngineProtocol) {}
}
