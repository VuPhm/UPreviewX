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
}

private final class EngineTestDelegate: PlaybackEngineDelegate {
    var onLoaded: (() -> Void)?
    var onSizeUpdated: ((CGSize) -> Void)?
    private var didFulfillSize = false

    func playbackEngineDidLoadFile(_ engine: PlaybackEngineProtocol) {
        onLoaded?()
    }
    func playbackEngineDidRenderFirstFrame(_ engine: PlaybackEngineProtocol, latencyMs: Double) {}
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
