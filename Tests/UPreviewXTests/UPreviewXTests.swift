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
            "-y", "-f", "lavfi", "-i", "testsrc2=size=320x240:rate=30:duration=2",
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
        let loadExp = expectation(description: "file loaded")
        helper.onLoaded = { loadExp.fulfill() }
        engine.delegate = helper

        try engine.initialize()
        try engine.load(url: tempURL)

        wait(for: [loadExp], timeout: 5.0)
        engine.refreshDiagnostics()

        XCTAssertEqual(engine.diagnostics.codecName, "h264")
        XCTAssertEqual(engine.diagnostics.width, 320)
        XCTAssertEqual(engine.diagnostics.height, 240)

        engine.setVolume(65.0)
        XCTAssertEqual(engine.volume, 65.0, accuracy: 0.1)

        engine.toggleMute()
        XCTAssertTrue(engine.isMuted)
    }
}

private final class EngineTestDelegate: PlaybackEngineDelegate {
    var onLoaded: (() -> Void)?
    private var didFulfill = false

    func playbackEngineDidLoadFile(_ engine: PlaybackEngineProtocol) {
        if !didFulfill {
            didFulfill = true
            onLoaded?()
        }
    }
    func playbackEngineDidRenderFirstFrame(_ engine: PlaybackEngineProtocol, latencyMs: Double) {}
    func playbackEngine(_ engine: PlaybackEngineProtocol, didUpdatePosition position: Double, duration: Double) {}
    func playbackEngine(_ engine: PlaybackEngineProtocol, didUpdatePause isPaused: Bool) {}
    func playbackEngine(_ engine: PlaybackEngineProtocol, didUpdateVolume volume: Double, isMuted: Bool) {}
    func playbackEngine(_ engine: PlaybackEngineProtocol, didUpdateVideoSize size: CGSize) {}
    func playbackEngine(_ engine: PlaybackEngineProtocol, didCompleteSeek latencyMs: Double) {}
    func playbackEngine(_ engine: PlaybackEngineProtocol, didUpdateDiagnostics diagnostics: PlaybackDiagnostics) {}
    func playbackEngine(_ engine: PlaybackEngineProtocol, didEncounterError error: PlaybackEngineError) {}
    func playbackEngineDidReachEndOfFile(_ engine: PlaybackEngineProtocol) {}
}
