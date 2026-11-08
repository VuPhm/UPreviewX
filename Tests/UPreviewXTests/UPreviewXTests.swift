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

    func testEnginePlaybackAndControlsWithGeneratedSample() throws {
        let ffmpegPath = "/usr/local/bin/ffmpeg"
        guard FileManager.default.isExecutableFile(atPath: ffmpegPath) else {
            throw XCTSkip("ffmpeg not found at \(ffmpegPath)")
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
        let ffmpegPath = "/usr/local/bin/ffmpeg"
        guard FileManager.default.isExecutableFile(atPath: ffmpegPath) else {
            throw XCTSkip("ffmpeg not found at \(ffmpegPath)")
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
        guard let win = controller.window as? PlayerWindow else {
            XCTFail("Window should be PlayerWindow")
            return
        }

        // Initially at 1.0x speed
        XCTAssertEqual(controller.engine.speed, 1.0)

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

        // Wait 250ms for hold timer to trigger shuttle mode
        let exp = expectation(description: "shuttle activated")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            // Speed should now be fast speed (2.0x)
            XCTAssertEqual(controller.engine.speed, 2.0, accuracy: 0.1)

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
                // Speed remains 2.0x, does not break or crash
                XCTAssertEqual(controller.engine.speed, 2.0, accuracy: 0.1)
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
                // Speed must be restored to original 1.0x immediately
                XCTAssertEqual(controller.engine.speed, 1.0, accuracy: 0.1)
            }
            exp.fulfill()
        }

        wait(for: [exp], timeout: 2.0)

        // 3. Focus loss cancels shuttle and restores state
        win.keyDown(with: keyDownEvent)
        let focusExp = expectation(description: "shuttle cancelled on focus loss")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            XCTAssertEqual(controller.engine.speed, 2.0, accuracy: 0.1)
            // Trigger resign key
            controller.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification))
            XCTAssertEqual(controller.engine.speed, 1.0, accuracy: 0.1)
            focusExp.fulfill()
        }
        wait(for: [focusExp], timeout: 2.0)
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
