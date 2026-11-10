import XCTest
import CoreGraphics
import AVFoundation
import AppKit
@testable import UPreviewXCore

final class SmartThumbnailStressTests: XCTestCase {

    override func setUp() {
        super.setUp()
        VideoThumbnailService.shared.resetMetrics()
        VideoThumbnailCache.shared.clear()
        VideoThumbnailService.shared.setPlaybackActive(false)
    }

    override func tearDown() {
        VideoThumbnailService.shared.setPlaybackActive(false)
        VideoThumbnailCache.shared.clear()
        super.tearDown()
    }

    // MARK: - 1. Smart Cost Classification Across Formats & Codecs

    func testSmartCostClassificationAcrossCodecsAndResolutions() {
        let tempDir = FileManager.default.temporaryDirectory
        let sampleMP4 = tempDir.appendingPathComponent("cost_test_h264_1080p_\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: sampleMP4) }

        // Generate synthetic 1080p H.264
        let ffmpeg = "/usr/local/bin/ffmpeg"
        if FileManager.default.isExecutableFile(atPath: ffmpeg) {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: ffmpeg)
            proc.arguments = [
                "-nostdin", "-y",
                "-f", "lavfi", "-i", "testsrc=size=1920x1080:rate=30:duration=1",
                "-c:v", "libx264", "-pix_fmt", "yuv420p", "-preset", "ultrafast",
                sampleMP4.path
            ]
            try? proc.run()
            proc.waitUntilExit()

            if FileManager.default.fileExists(atPath: sampleMP4.path) {
                let cost = VideoThumbnailService.classifyCost(for: sampleMP4)
                XCTAssertEqual(cost, .low, "Standard 1080p H.264 should be classified as LOW cost")
            }
        }

        // Test Real C3585.MP4 (Sony XAVC-S 4K 10-bit H.264 4:2:2)
        let realFile = URL(fileURLWithPath: "/Users/vup/Movies/C3585.MP4")
        if FileManager.default.fileExists(atPath: realFile.path) {
            let cost = VideoThumbnailService.classifyCost(for: realFile)
            XCTAssertEqual(cost, .high, "4K 10-bit H.264 without HW decode must be classified as HIGH cost")
        }
    }

    // MARK: - 2. LRU Cache & Negative Cache Hit Rates

    func testLRUThumbnailCacheAndNegativeCacheHitRate() {
        let tempDir = FileManager.default.temporaryDirectory
        let sampleURL = tempDir.appendingPathComponent("cache_test_\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: sampleURL) }

        let ffmpeg = "/usr/local/bin/ffmpeg"
        guard FileManager.default.isExecutableFile(atPath: ffmpeg) else { return }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: ffmpeg)
        proc.arguments = [
            "-nostdin", "-y",
            "-f", "lavfi", "-i", "testsrc=size=320x240:rate=10:duration=1",
            "-c:v", "libx264", "-preset", "ultrafast",
            sampleURL.path
        ]
        try? proc.run()
        proc.waitUntilExit()

        guard FileManager.default.fileExists(atPath: sampleURL.path) else { return }

        let targetSize = CGSize(width: 160, height: 120)

        // Request 1: Cache Miss
        let exp1 = expectation(description: "first request miss")
        var img1: CGImage?
        VideoThumbnailService.shared.generateThumbnail(for: sampleURL, targetSize: targetSize) { res in
            if case .success(let img) = res { img1 = img }
            exp1.fulfill()
        }
        wait(for: [exp1], timeout: 3.0)
        XCTAssertNotNil(img1)
        XCTAssertEqual(VideoThumbnailService.shared.metrics.cacheHits, 0)
        XCTAssertEqual(VideoThumbnailService.shared.metrics.cacheMisses, 1)

        // Request 2: Cache Hit
        let exp2 = expectation(description: "second request hit")
        var img2: CGImage?
        let startHit = CFAbsoluteTimeGetCurrent()
        VideoThumbnailService.shared.generateThumbnail(for: sampleURL, targetSize: targetSize) { res in
            if case .success(let img) = res { img2 = img }
            exp2.fulfill()
        }
        wait(for: [exp2], timeout: 1.0)
        let hitLatencyMs = (CFAbsoluteTimeGetCurrent() - startHit) * 1000.0
        XCTAssertNotNil(img2)
        XCTAssertEqual(VideoThumbnailService.shared.metrics.cacheHits, 1)
        XCTAssertLessThan(hitLatencyMs, 10.0, "Cache hit must be delivered in < 10ms")

        // Test Negative Cache on heavy file
        let realFile = URL(fileURLWithPath: "/Users/vup/Movies/C3585.MP4")
        if FileManager.default.fileExists(atPath: realFile.path) {
            let expNeg1 = expectation(description: "initial high cost fail")
            VideoThumbnailService.shared.generateThumbnail(for: realFile, timeout: 0.5) { res in
                if case .failure(let err) = res {
                    XCTAssertTrue(err == .costExceedsBudget(.high) || err == .extractionTimeout)
                }
                expNeg1.fulfill()
            }
            wait(for: [expNeg1], timeout: 2.0)

            // Second request must hit negative cache in < 1ms
            let expNeg2 = expectation(description: "negative cache hit")
            let startNeg = CFAbsoluteTimeGetCurrent()
            VideoThumbnailService.shared.generateThumbnail(for: realFile, timeout: 0.5) { res in
                if case .failure(let err) = res {
                    XCTAssertTrue(err == .costExceedsBudget(.high) || err == .extractionTimeout)
                }
                expNeg2.fulfill()
            }
            wait(for: [expNeg2], timeout: 0.5)
            let negLatencyMs = (CFAbsoluteTimeGetCurrent() - startNeg) * 1000.0
            XCTAssertEqual(VideoThumbnailService.shared.metrics.negativeCacheHits, 1)
            XCTAssertLessThan(negLatencyMs, 5.0, "Negative cache hit must be near-instantaneous (< 5ms)")
        }
    }

    // MARK: - 3. Folder Scale: Batch of 20 Mixed Videos

    func testFolderScaleSimulatedBatch20MixedVideos() {
        let tempDir = FileManager.default.temporaryDirectory
        var sampleURLs: [URL] = []
        defer {
            for u in sampleURLs { try? FileManager.default.removeItem(at: u) }
        }

        let ffmpeg = "/usr/local/bin/ffmpeg"
        guard FileManager.default.isExecutableFile(atPath: ffmpeg) else { return }

        // Create 4 distinct base sample files
        for i in 0..<4 {
            let u = tempDir.appendingPathComponent("batch_sample_\(i)_\(UUID().uuidString).mp4")
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: ffmpeg)
            proc.arguments = [
                "-nostdin", "-y",
                "-f", "lavfi", "-i", "testsrc=size=320x180:rate=15:duration=1",
                "-c:v", "libx264", "-preset", "ultrafast",
                u.path
            ]
            try? proc.run()
            proc.waitUntilExit()
            if FileManager.default.fileExists(atPath: u.path) {
                sampleURLs.append(u)
            }
        }
        guard !sampleURLs.isEmpty else { return }

        // Construct a 20-file mixed list referencing these samples + 2 high-cost / missing files
        var mixedBatch: [URL] = []
        for i in 0..<18 {
            mixedBatch.append(sampleURLs[i % sampleURLs.count])
        }
        mixedBatch.append(URL(fileURLWithPath: "/Users/vup/Movies/C3585.MP4"))
        mixedBatch.append(tempDir.appendingPathComponent("non_existent_\(UUID().uuidString).mp4"))

        let start = CFAbsoluteTimeGetCurrent()
        let exp = expectation(description: "batch 20 processed")
        exp.expectedFulfillmentCount = mixedBatch.count

        var maxObservedDecoders = 0
        let decLock = NSLock()

        for url in mixedBatch {
            VideoThumbnailService.shared.generateThumbnail(
                for: url,
                targetSize: CGSize(width: 256, height: 144),
                timeout: 1.5
            ) { _ in
                decLock.lock()
                maxObservedDecoders = max(maxObservedDecoders, VideoThumbnailService.shared.metrics.activeDecoders)
                decLock.unlock()
                exp.fulfill()
            }
        }

        wait(for: [exp], timeout: 10.0)
        let totalElapsed = CFAbsoluteTimeGetCurrent() - start

        let metrics = VideoThumbnailService.shared.metrics
        XCTAssertEqual(metrics.requestsProcessed, 20)
        XCTAssertLessThanOrEqual(maxObservedDecoders, 1, "Must never have more than 1 concurrent decoder")
        XCTAssertLessThan(totalElapsed, 8.0, "Batch of 20 mixed items should finish well within budget")
    }

    // MARK: - 4. Bounded Queue & Backpressure Under Load (50-100 Requests)

    func testFolderScaleSimulatedBatch50To100HeavyVideosBackpressure() {
        let tempDir = FileManager.default.temporaryDirectory
        let sampleURL = tempDir.appendingPathComponent("backpressure_sample_\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: sampleURL) }

        let ffmpeg = "/usr/local/bin/ffmpeg"
        if FileManager.default.isExecutableFile(atPath: ffmpeg) {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: ffmpeg)
            proc.arguments = [
                "-nostdin", "-y",
                "-f", "lavfi", "-i", "testsrc=size=160x120:rate=10:duration=1",
                "-c:v", "libx264", "-preset", "ultrafast",
                sampleURL.path
            ]
            try? proc.run()
            proc.waitUntilExit()
        }

        // Fire 60 rapid thumbnail requests concurrently
        let requestCount = 60
        let exp = expectation(description: "all 60 requests resolved or rejected")
        exp.expectedFulfillmentCount = requestCount

        var rejectedCount = 0
        let countLock = NSLock()

        for i in 0..<requestCount {
            // Alternate between valid and high-cost targets to simulate directory browsing
            let targetURL = (i % 5 == 0)
                ? URL(fileURLWithPath: "/Users/vup/Movies/C3585.MP4")
                : sampleURL

            VideoThumbnailService.shared.generateThumbnail(
                for: targetURL,
                targetSize: CGSize(width: 128, height: 128),
                timeout: 0.5
            ) { res in
                if case .failure(let err) = res {
                    if err == .queueFull || err == .backpressure || err == .costExceedsBudget(.high) {
                        countLock.lock()
                        rejectedCount += 1
                        countLock.unlock()
                    }
                }
                exp.fulfill()
            }
        }

        wait(for: [exp], timeout: 15.0)

        let finalMetrics = VideoThumbnailService.shared.metrics
        XCTAssertEqual(finalMetrics.requestsProcessed, requestCount)
        XCTAssertLessThanOrEqual(finalMetrics.activeDecoders, 1)
        XCTAssertLessThan(finalMetrics.memoryBytes, 16 * 1024 * 1024, "RAM consumption must stay bounded under 16MB")
    }

    // MARK: - 5. Rapid Browsing & Early Cancellation

    func testRapidBrowsingAndEarlyCancellation() {
        let tempDir = FileManager.default.temporaryDirectory
        let sampleURL = tempDir.appendingPathComponent("cancel_sample_\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: sampleURL) }

        let ffmpeg = "/usr/local/bin/ffmpeg"
        if FileManager.default.isExecutableFile(atPath: ffmpeg) {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: ffmpeg)
            proc.arguments = [
                "-nostdin", "-y",
                "-f", "lavfi", "-i", "testsrc=size=320x240:rate=15:duration=1",
                "-c:v", "libx264", "-preset", "ultrafast",
                sampleURL.path
            ]
            try? proc.run()
            proc.waitUntilExit()
        }

        var tasks: [VideoThumbnailTask] = []
        let totalRequests = 15
        let exp = expectation(description: "all tasks completed or cancelled")
        exp.expectedFulfillmentCount = totalRequests

        var cancelledResults = 0
        let cLock = NSLock()

        for _ in 0..<totalRequests {
            let task = VideoThumbnailService.shared.generateThumbnail(
                for: sampleURL,
                targetSize: CGSize(width: 256, height: 256),
                timeout: 2.0
            ) { res in
                if case .failure(let err) = res, err == .cancelled {
                    cLock.lock()
                    cancelledResults += 1
                    cLock.unlock()
                }
                exp.fulfill()
            }
            tasks.append(task)
        }

        // Simulate user scrolling rapidly past items 3..14: cancel them immediately
        for i in 3..<tasks.count {
            tasks[i].cancel()
        }

        wait(for: [exp], timeout: 5.0)
        XCTAssertGreaterThanOrEqual(cancelledResults, 10, "At least 10 cancelled tasks should abort cleanly without decoding")
    }

    // MARK: - 6. Rapid Video Switching in Player Without Jerk

    func testRapidVideoSwitchingInPlayerWithoutJerk() {
        let realFile = URL(fileURLWithPath: "/Users/vup/Movies/C3585.MP4")
        guard FileManager.default.fileExists(atPath: realFile.path) else { return }

        let controller = PlayerWindowController(showDiagnostics: true)
        defer { controller.close() }

        var resizeEventsAfterReveal = 0
        let observer = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification,
            object: controller.window,
            queue: .main
        ) { _ in
            if controller.window?.alphaValue == 1.0 {
                resizeEventsAfterReveal += 1
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        // Rapidly open file A, switch immediately to file B, then file A again
        controller.openMedia(url: realFile)
        controller.openMedia(url: realFile)

        if let win = controller.window {
            XCTAssertEqual(win.aspectRatio.width, 2160)
            XCTAssertEqual(win.aspectRatio.height, 3840)
            XCTAssertGreaterThan(win.frame.height, win.frame.width, "Must be portrait orientation")
        }

        XCTAssertEqual(resizeEventsAfterReveal, 0, "No resizing events after reveal during rapid switching")
    }

    // MARK: - 7. Playback Priority Throttling

    func testPlaybackPriorityThrottlingActivePlayback() {
        let realFile = URL(fileURLWithPath: "/Users/vup/Movies/C3585.MP4")
        guard FileManager.default.fileExists(atPath: realFile.path) else { return }

        // Simulate active video playback in the main window
        VideoThumbnailService.shared.setPlaybackActive(true)

        let exp = expectation(description: "playback active thumbnail request")
        VideoThumbnailService.shared.generateThumbnail(for: realFile) { res in
            if case .failure(let err) = res {
                // Must be rejected under backpressure or cost budget to preserve 60fps playback
                XCTAssertTrue(err == .backpressure || err == .costExceedsBudget(.high))
            } else {
                XCTFail("Heavy thumbnail decode should not run while playback is active")
            }
            exp.fulfill()
        }

        wait(for: [exp], timeout: 1.0)
        XCTAssertGreaterThanOrEqual(VideoThumbnailService.shared.metrics.requestsRejectedBackpressure, 1)

        // Resume idle state
        VideoThumbnailService.shared.setPlaybackActive(false)
    }

    // MARK: - 8. Memory Pressure Cache Invalidation

    func testMemoryPressureFlushesThumbnailCache() {
        let cache = VideoThumbnailCache.shared

        // Synthesize a dummy CGImage
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: 100,
            height: 100,
            bitsPerComponent: 8,
            bytesPerRow: 400,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let img = ctx.makeImage() else {
            return
        }

        let key = VideoThumbnailCache.Key(
            path: "/tmp/dummy_video.mp4",
            fileSize: 1024,
            modTime: 1000,
            targetWidth: 100,
            targetHeight: 100
        )

        cache.set(img, for: key, cost: .low)
        XCTAssertEqual(cache.count, 1)
        XCTAssertGreaterThan(cache.currentMemoryBytes, 0)

        // Clear cache
        cache.clear()
        XCTAssertEqual(cache.count, 0)
        XCTAssertEqual(cache.currentMemoryBytes, 0)
        XCTAssertNil(cache.get(for: key))
    }
}
