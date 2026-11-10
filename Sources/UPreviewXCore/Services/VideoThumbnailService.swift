import Foundation
import CoreGraphics
import AVFoundation
import AppKit
import CMPV

/// Errors that can occur during video thumbnail extraction.
public enum VideoThumbnailError: Error, LocalizedError, Equatable {
    case fileNotFound(URL)
    case unsupportedFormat(String)
    case extractionTimeout
    case decodingFailed(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .fileNotFound(let url):
            return "File not found at \(url.path)"
        case .unsupportedFormat(let reason):
            return "Unsupported format for thumbnail: \(reason)"
        case .extractionTimeout:
            return "Thumbnail extraction exceeded time budget"
        case .decodingFailed(let reason):
            return "Failed to decode thumbnail frame: \(reason)"
        case .cancelled:
            return "Thumbnail generation was cancelled"
        }
    }
}

/// Cancellable task handle for thumbnail generation.
public final class VideoThumbnailTask: @unchecked Sendable {
    private let lock = NSLock()
    private var _isCancelled = false
    private var onCancelHandler: (() -> Void)?

    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isCancelled
    }

    public init(onCancel: (() -> Void)? = nil) {
        self.onCancelHandler = onCancel
    }

    public func cancel() {
        lock.lock()
        guard !_isCancelled else {
            lock.unlock()
            return
        }
        _isCancelled = true
        let handler = onCancelHandler
        onCancelHandler = nil
        lock.unlock()
        handler?()
    }

    func setCancelHandler(_ handler: @escaping () -> Void) {
        lock.lock()
        if _isCancelled {
            lock.unlock()
            handler()
            return
        }
        onCancelHandler = handler
        lock.unlock()
    }
}

/// Lightweight, best-effort video thumbnail service conforming to UPreviewX conservative resource constraints:
/// 1. Prioritizes embedded cover art (APIC/ID3/commonKeyArtwork) for near-instant 0-decode return.
/// 2. Prioritizes native AVFoundation with keyframe-only seek (.positiveInfinity tolerance).
/// 3. Falls back to headless, bounded libmpv single-frame decoding for non-native containers (MKV, WebM, AVI, TS, AV1).
/// 4. Strictly serial: maximum 1 concurrent decode task.
/// 5. Strictly bounded: 4MB demuxer cache, 2 decoder threads, 2.5s hard timeout.
/// 6. Strictly isolated: never writes to video source directory; uses temporary files and cleans up immediately.
public final class VideoThumbnailService {
    public static let shared = VideoThumbnailService()

    /// Dedicated background serial queue ensuring exactly 1 concurrent thumbnail decode task.
    private let queue = DispatchQueue(label: "com.upreviewx.thumbnail.serial", qos: .utility)

    public init() {}

    /// Asynchronously generates a representative thumbnail for a video URL.
    /// - Parameters:
    ///   - url: Local file URL of the video.
    ///   - targetSize: Desired maximum dimensions (e.g. 512x512).
    ///   - atPosition: Desired timestamp in seconds (default is 1.0s or nearest keyframe).
    ///   - timeout: Maximum allowed execution time before cancellation (default: 2.5s).
    ///   - completionQueue: Queue on which completion is invoked (nil executes directly on background task thread).
    ///   - completion: Callback delivered with CGImage or VideoThumbnailError.
    @discardableResult
    public func generateThumbnail(
        for url: URL,
        targetSize: CGSize = CGSize(width: 512, height: 512),
        atPosition position: Double = 1.0,
        timeout: TimeInterval = 2.5,
        completionQueue: DispatchQueue? = .main,
        completion: @escaping (Result<CGImage, VideoThumbnailError>) -> Void
    ) -> VideoThumbnailTask {
        let task = VideoThumbnailTask()

        let deliver: (Result<CGImage, VideoThumbnailError>) -> Void = { result in
            if let q = completionQueue {
                q.async { completion(result) }
            } else {
                completion(result)
            }
        }

        queue.async { [weak self] in
            guard let self = self else {
                deliver(.failure(.cancelled))
                return
            }

            if task.isCancelled {
                deliver(.failure(.cancelled))
                return
            }

            guard FileManager.default.fileExists(atPath: url.path) else {
                deliver(.failure(.fileNotFound(url)))
                return
            }

            // Phase 1: Embedded Cover Art (instant metadata extraction, 0 CPU video decoding)
            if let coverArt = self.extractEmbeddedArtwork(from: url, targetSize: targetSize) {
                deliver(.success(coverArt))
                return
            }

            if task.isCancelled {
                deliver(.failure(.cancelled))
                return
            }

            // Phase 2: Native AVFoundation with Keyframe-Only Seek (.positiveInfinity tolerance)
            if self.isNativeAVAssetSupported(url: url) {
                let sema = DispatchSemaphore(value: 0)
                var avResult: Result<CGImage, VideoThumbnailError>?

                self.extractNativeAVThumbnail(for: url, targetSize: targetSize, atPosition: position) { res in
                    avResult = res
                    sema.signal()
                }

                _ = sema.wait(timeout: .now() + min(timeout, 1.5))
                if let res = avResult {
                    switch res {
                    case .success(let image):
                        deliver(.success(image))
                        return
                    case .failure:
                        // Fall through to libmpv fallback on failure
                        break
                    }
                }
            }

            if task.isCancelled {
                deliver(.failure(.cancelled))
                return
            }

            // Phase 3: Bounded Headless libmpv Fallback for non-native containers / codecs
            self.extractMPVThumbnail(for: url, targetSize: targetSize, atPosition: position, timeout: timeout, task: task) { res in
                deliver(res)
            }
        }

        return task
    }

    /// Synchronous CLI helper that renders a thumbnail directly to a target file URL without launching any GUI.
    public func generateThumbnailToFile(
        inputURL: URL,
        outputURL: URL,
        targetSize: CGSize = CGSize(width: 512, height: 512),
        timeout: TimeInterval = 3.0
    ) -> Result<URL, VideoThumbnailError> {
        let sema = DispatchSemaphore(value: 0)
        var finalResult: Result<URL, VideoThumbnailError> = .failure(.extractionTimeout)

        _ = generateThumbnail(for: inputURL, targetSize: targetSize, timeout: timeout, completionQueue: nil) { result in
            switch result {
            case .success(let cgImage):
                let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
                guard let tiffData = nsImage.tiffRepresentation,
                      let bitmap = NSBitmapImageRep(data: tiffData),
                      let pngData = bitmap.representation(using: .png, properties: [:]) else {
                    finalResult = .failure(.decodingFailed("Failed to encode thumbnail PNG"))
                    sema.signal()
                    return
                }
                do {
                    try pngData.write(to: outputURL, options: .atomic)
                    finalResult = .success(outputURL)
                } catch {
                    finalResult = .failure(.decodingFailed(error.localizedDescription))
                }
            case .failure(let error):
                finalResult = .failure(error)
            }
            sema.signal()
        }

        _ = sema.wait(timeout: .now() + timeout + 0.5)
        return finalResult
    }

    // MARK: - Phase 1: Embedded Cover Art

    private func extractEmbeddedArtwork(from url: URL, targetSize: CGSize) -> CGImage? {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: false])
        let metadata = asset.commonMetadata
        for item in metadata where item.commonKey == .commonKeyArtwork {
            if let data = item.dataValue,
               let source = CGImageSourceCreateWithData(data as CFData, nil),
               let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
                return scaleImageIfNeeded(image, targetSize: targetSize)
            }
        }
        return nil
    }

    // MARK: - Phase 2: Native AVFoundation Keyframe Seek

    private func isNativeAVAssetSupported(url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        let nativeExts: Set<String> = ["mp4", "mov", "m4v", "m4a"]
        return nativeExts.contains(ext)
    }

    private func extractNativeAVThumbnail(
        for url: URL,
        targetSize: CGSize,
        atPosition position: Double,
        completion: @escaping (Result<CGImage, VideoThumbnailError>) -> Void
    ) {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: false])
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = targetSize
        // Seek to nearest keyframe for near-instant execution without GOP pre-decoding
        generator.requestedTimeToleranceBefore = .positiveInfinity
        generator.requestedTimeToleranceAfter = .positiveInfinity

        let targetTime = CMTime(seconds: max(0.5, position), preferredTimescale: 600)
        generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: targetTime)]) { _, image, _, result, error in
            if result == .succeeded, let img = image {
                completion(.success(img))
            } else {
                let msg = error?.localizedDescription ?? "AVAssetImageGenerator failed"
                completion(.failure(.decodingFailed(msg)))
            }
        }
    }

    // MARK: - Phase 3: Bounded Headless libmpv Fallback

    private func extractMPVThumbnail(
        for url: URL,
        targetSize: CGSize,
        atPosition position: Double,
        timeout: TimeInterval,
        task: VideoThumbnailTask,
        completion: @escaping (Result<CGImage, VideoThumbnailError>) -> Void
    ) {
        guard let handle = mpv_create() else {
            completion(.failure(.decodingFailed("mpv_create() returned nil")))
            return
        }

        let tempOutputDir = FileManager.default.temporaryDirectory
        let tempCaptureFile = tempOutputDir.appendingPathComponent("upreviewx_thumb_\(UUID().uuidString).png")

        var isCleanedUp = false
        let cleanupLock = NSLock()

        func cleanupEngine() {
            cleanupLock.lock()
            defer { cleanupLock.unlock() }
            guard !isCleanedUp else { return }
            isCleanedUp = true
            mpv_terminate_destroy(handle)
            try? FileManager.default.removeItem(at: tempCaptureFile)
        }

        task.setCancelHandler {
            cleanupEngine()
        }

        // Extremely conservative resource constraints:
        // - Null VO: no OpenGL context, no window, no Metal surface
        // - Audio disabled
        // - Scripts and network ytdl disabled
        // - Bounded demuxer cache: 4 MiB max (prevents reading 50GB into RAM)
        // - Low thread footprint: 2 threads (avoids saturating CPU cores)
        // - Fast profile: disables heavy filters
        mpv_set_option_string(handle, "vo", "null")
        mpv_set_option_string(handle, "audio", "no")
        mpv_set_option_string(handle, "config", "no")
        mpv_set_option_string(handle, "load-scripts", "no")
        mpv_set_option_string(handle, "ytdl", "no")
        mpv_set_option_string(handle, "sub-auto", "no")
        mpv_set_option_string(handle, "profile", "fast")
        let hwdec = (UserSettings.shared.hardwareAcceleration == .disabled) ? "no" : "videotoolbox"
        mpv_set_option_string(handle, "hwdec", hwdec)
        mpv_set_option_string(handle, "hwdec-codecs", "h264,hevc,vp9,prores")
        mpv_set_option_string(handle, "demuxer-max-bytes", "4194304")
        mpv_set_option_string(handle, "demuxer-max-back-bytes", "0")
        mpv_set_option_string(handle, "vd-lavc-threads", "2")
        mpv_set_option_string(handle, "keep-open", "yes")
        let startVal = String(format: "%.2f", max(0.0, position))
        mpv_set_option_string(handle, "start", startVal)

        guard mpv_initialize(handle) >= 0 else {
            cleanupEngine()
            completion(.failure(.decodingFailed("Failed to initialize headless mpv for thumbnail")))
            return
        }

        // Issue clean non-blocking loadfile replace
        var loadArgs: [UnsafeMutablePointer<CChar>?] = [
            strdup("loadfile"),
            strdup(url.path),
            strdup("replace"),
            nil
        ]
        defer {
            for ptr in loadArgs where ptr != nil { free(ptr) }
        }

        let rc = loadArgs.withUnsafeMutableBufferPointer { buf in
            buf.baseAddress!.withMemoryRebound(to: UnsafePointer<CChar>?.self, capacity: buf.count) { constBuf in
                mpv_command(handle, constBuf)
            }
        }
        guard rc >= 0 else {
            cleanupEngine()
            completion(.failure(.decodingFailed("Failed to load file for thumbnail")))
            return
        }

        let deadline = CFAbsoluteTimeGetCurrent() + timeout
        var captured = false

        while CFAbsoluteTimeGetCurrent() < deadline {
            if task.isCancelled {
                cleanupEngine()
                completion(.failure(.cancelled))
                return
            }

            guard let eventPtr = mpv_wait_event(handle, 0.05) else { continue }
            let event = eventPtr.pointee

            if event.event_id == MPV_EVENT_PLAYBACK_RESTART {
                // Allow decoder thread to complete first frame push
                usleep(50_000)
                var screenshotArgs: [UnsafeMutablePointer<CChar>?] = [
                    strdup("screenshot-to-file"),
                    strdup(tempCaptureFile.path),
                    strdup("video"),
                    nil
                ]
                let ssRc = screenshotArgs.withUnsafeMutableBufferPointer { buf in
                    buf.baseAddress!.withMemoryRebound(to: UnsafePointer<CChar>?.self, capacity: buf.count) { constBuf in
                        mpv_command(handle, constBuf)
                    }
                }
                for ptr in screenshotArgs where ptr != nil { free(ptr) }

                if ssRc >= 0 && FileManager.default.fileExists(atPath: tempCaptureFile.path) {
                    captured = true
                    break
                }
            } else if event.event_id == MPV_EVENT_END_FILE {
                break
            }
        }

        if captured,
           let data = try? Data(contentsOf: tempCaptureFile),
           let source = CGImageSourceCreateWithData(data as CFData, nil),
           let fullImage = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            let finalImage = scaleImageIfNeeded(fullImage, targetSize: targetSize)
            cleanupEngine()
            completion(.success(finalImage))
        } else {
            let timedOut = CFAbsoluteTimeGetCurrent() >= deadline
            cleanupEngine()
            completion(.failure(timedOut ? .extractionTimeout : .decodingFailed("Decoder reached EOF without producing a frame")))
        }
    }

    // MARK: - Image Scaling Helper

    private func scaleImageIfNeeded(_ image: CGImage, targetSize: CGSize) -> CGImage {
        let maxDim = max(targetSize.width, targetSize.height)
        guard maxDim > 0 else { return image }

        let origW = CGFloat(image.width)
        let origH = CGFloat(image.height)
        guard origW > maxDim || origH > maxDim else { return image }

        let aspect = origW / origH
        var targetW = maxDim
        var targetH = maxDim
        if aspect >= 1.0 {
            targetH = (targetW / aspect).rounded()
        } else {
            targetW = (targetH * aspect).rounded()
        }

        let colorSpace = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: Int(targetW),
            height: Int(targetH),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return image
        }

        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: targetW, height: targetH))
        return ctx.makeImage() ?? image
    }
}
