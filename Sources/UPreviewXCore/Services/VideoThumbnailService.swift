import Foundation
import CoreGraphics
import AVFoundation
import AppKit
import CMPV

/// Estimated computational cost of thumbnail generation based on preflight metadata.
public enum ThumbnailCost: Int, Comparable, Sendable {
    /// Near-instant (< 100ms): Embedded cover art or hardware-supported format (AVFoundation keyframe seek).
    case low = 1
    /// Reasonable (< 1.5s): Standard non-native container / codec (e.g. 720p/1080p MKV/WebM) within budget.
    case medium = 2
    /// Heavy (multi-second CPU software decode): 4K/8K, 10-bit 4:2:2, massive bitrate, or unsupported profiles.
    case high = 3

    public static func < (lhs: ThumbnailCost, rhs: ThumbnailCost) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Errors that can occur during video thumbnail extraction.
public enum VideoThumbnailError: Error, LocalizedError, Equatable {
    case fileNotFound(URL)
    case unsupportedFormat(String)
    case extractionTimeout
    case decodingFailed(String)
    case cancelled
    case costExceedsBudget(ThumbnailCost)
    case queueFull
    case backpressure

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
        case .costExceedsBudget(let cost):
            return "Thumbnail cost (\(cost)) exceeds allowed budget; fast-failing to preserve system resources"
        case .queueFull:
            return "Thumbnail processing queue is full; task rejected under backpressure"
        case .backpressure:
            return "Thumbnail generation deferred/rejected due to active playback or queue congestion"
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

/// Thread-safe in-memory LRU thumbnail cache and negative cache.
/// Prevents redundant decodes and prevents repeated expensive experiments on heavy/failing files.
public final class VideoThumbnailCache: @unchecked Sendable {
    public static let shared = VideoThumbnailCache()

    public struct Key: Hashable {
        public let path: String
        public let fileSize: Int64
        public let modTime: Int64
        public let targetWidth: Int
        public let targetHeight: Int
    }

    private struct Entry {
        let image: CGImage
        let cost: ThumbnailCost
        let sizeBytes: Int
        var lastAccess: CFAbsoluteTime
    }

    private let lock = NSLock()
    private var entries: [Key: Entry] = [:]
    private var totalBytes: Int = 0
    private let maxEntries: Int = 64
    private let maxBytes: Int = 16 * 1024 * 1024 // 16 MiB max RAM

    // Negative cache: remembers files that failed or exceeded budget
    private var negativeCache: [Key: (error: VideoThumbnailError, timestamp: CFAbsoluteTime)] = [:]
    private let maxNegativeEntries: Int = 128
    private let negativeTTL: TimeInterval = 60.0

    public init() {}

    public func makeKey(for url: URL, targetSize: CGSize) -> Key? {
        let standardPath = url.standardizedFileURL.path
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: standardPath),
              let size = attrs[.size] as? Int64,
              let modDate = attrs[.modificationDate] as? Date else {
            return nil
        }
        return Key(
            path: standardPath,
            fileSize: size,
            modTime: Int64(modDate.timeIntervalSince1970),
            targetWidth: Int(targetSize.width),
            targetHeight: Int(targetSize.height)
        )
    }

    public func get(for key: Key) -> CGImage? {
        lock.lock()
        defer { lock.unlock() }

        if var entry = entries[key] {
            entry.lastAccess = CFAbsoluteTimeGetCurrent()
            entries[key] = entry
            return entry.image
        }
        return nil
    }

    public func set(_ image: CGImage, for key: Key, cost: ThumbnailCost) {
        lock.lock()
        defer { lock.unlock() }

        // Remove from negative cache if previously recorded
        negativeCache.removeValue(forKey: key)

        let imageBytes = image.bytesPerRow * image.height
        if let existing = entries[key] {
            totalBytes -= existing.sizeBytes
        }

        entries[key] = Entry(
            image: image,
            cost: cost,
            sizeBytes: imageBytes,
            lastAccess: CFAbsoluteTimeGetCurrent()
        )
        totalBytes += imageBytes

        evictIfNeeded()
    }

    public func checkNegativeCache(for key: Key) -> VideoThumbnailError? {
        lock.lock()
        defer { lock.unlock() }

        if let (err, timestamp) = negativeCache[key] {
            if CFAbsoluteTimeGetCurrent() - timestamp < negativeTTL {
                return err
            } else {
                negativeCache.removeValue(forKey: key)
            }
        }
        return nil
    }

    public func recordNegative(for key: Key, error: VideoThumbnailError) {
        lock.lock()
        defer { lock.unlock() }

        if negativeCache.count >= maxNegativeEntries {
            // Evict oldest negative entry
            if let oldest = negativeCache.min(by: { $0.value.timestamp < $1.value.timestamp })?.key {
                negativeCache.removeValue(forKey: oldest)
            }
        }
        negativeCache[key] = (error, CFAbsoluteTimeGetCurrent())
    }

    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        entries.removeAll()
        negativeCache.removeAll()
        totalBytes = 0
    }

    public func invalidate(for url: URL) {
        lock.lock()
        defer { lock.unlock() }
        let p = url.standardizedFileURL.path
        entries = entries.filter { $0.key.path != p }
        negativeCache = negativeCache.filter { $0.key.path != p }
        totalBytes = entries.values.reduce(0) { $0 + $1.sizeBytes }
    }

    public var currentMemoryBytes: Int {
        lock.lock()
        defer { lock.unlock() }
        return totalBytes
    }

    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }

    public var negativeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return negativeCache.count
    }

    private func evictIfNeeded() {
        while (entries.count > maxEntries || totalBytes > maxBytes) && !entries.isEmpty {
            if let oldest = entries.min(by: { $0.value.lastAccess < $1.value.lastAccess }) {
                totalBytes -= oldest.value.sizeBytes
                entries.removeValue(forKey: oldest.key)
            } else {
                break
            }
        }
    }
}

/// Diagnostic snapshot of thumbnail pipeline throughput and resource consumption.
public struct ThumbnailMetrics: Sendable {
    public let cacheHits: Int
    public let cacheMisses: Int
    public let negativeCacheHits: Int
    public let requestsProcessed: Int
    public let requestsCancelled: Int
    public let requestsRejectedBackpressure: Int
    public let activeDecoders: Int
    public let queueDepth: Int
    public let memoryBytes: Int
}

/// Lightweight, folder-scale video thumbnail service conforming to UPreviewX conservative resource constraints:
/// 1. On-Demand, lazy execution: never pre-scans or batch-decodes unrequested videos.
/// 2. Smart Cost Classification: classifies LOW/MEDIUM/HIGH using lightweight metadata (< 20ms) before touching decoders.
/// 3. Negative Cache & LRU Cache: prevents repeating expensive decodes on heavy/failed files.
/// 4. Strictly Serial Concurrency: maximum 1 active video decoder at a time across the entire app.
/// 5. Bounded Queue & Backpressure: limits queue to 16 pending tasks, rejects overflow cleanly.
/// 6. Playback Priority: pauses/throttles thumbnail tasks during active playback to preserve 60fps rendering.
/// 7. Strictly isolated: never writes to video source directory; uses temporary files and cleans up immediately.
public final class VideoThumbnailService {
    public static let shared = VideoThumbnailService()

    /// Maximum number of queued thumbnail requests waiting in line.
    private let maxQueueCapacity = 16

    /// Serial background queue ensuring strictly 1 concurrent decode task.
    private let queue = DispatchQueue(label: "com.upreviewx.thumbnail.serial", qos: .utility)

    /// State lock for queue management and metrics
    private let lock = NSLock()
    private var pendingTasksCount: Int = 0
    private var activeDecodersCount: Int = 0
    private var isPlaybackActive: Bool = false

    // Telemetry counters
    private var metricCacheHits = 0
    private var metricCacheMisses = 0
    private var metricNegativeCacheHits = 0
    private var metricRequestsProcessed = 0
    private var metricRequestsCancelled = 0
    private var metricRequestsRejectedBackpressure = 0

    public init() {}

    /// Informs the thumbnail service whether a main player window is actively playing video.
    /// When active, thumbnail extraction yields or fast-fails non-instant requests to protect playback frame rate.
    public func setPlaybackActive(_ active: Bool) {
        lock.lock()
        isPlaybackActive = active
        lock.unlock()
    }

    /// Read-only snapshot of thumbnail pipeline metrics.
    public var metrics: ThumbnailMetrics {
        lock.lock()
        defer { lock.unlock() }
        return ThumbnailMetrics(
            cacheHits: metricCacheHits,
            cacheMisses: metricCacheMisses,
            negativeCacheHits: metricNegativeCacheHits,
            requestsProcessed: metricRequestsProcessed,
            requestsCancelled: metricRequestsCancelled,
            requestsRejectedBackpressure: metricRequestsRejectedBackpressure,
            activeDecoders: activeDecodersCount,
            queueDepth: pendingTasksCount,
            memoryBytes: VideoThumbnailCache.shared.currentMemoryBytes
        )
    }

    public func resetMetrics() {
        lock.lock()
        defer { lock.unlock() }
        metricCacheHits = 0
        metricCacheMisses = 0
        metricNegativeCacheHits = 0
        metricRequestsProcessed = 0
        metricRequestsCancelled = 0
        metricRequestsRejectedBackpressure = 0
    }

    // MARK: - Smart Cost Classification

    /// Classifies the expected computational cost of generating a thumbnail for a video URL.
    /// Fast pre-flight inspection (< 20ms) using container headers, tracks, and VideoToolbox compatibility rules.
    public static func classifyCost(for url: URL) -> ThumbnailCost {
        guard FileManager.default.fileExists(atPath: url.path) else { return .low }

        // 1. Embedded Cover Art check (< 5ms): if artwork exists, cost is guaranteed LOW (0 video decode)
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: false])
        for item in asset.commonMetadata where item.commonKey == .commonKeyArtwork {
            if item.dataValue != nil {
                return .low
            }
        }

        let ext = url.pathExtension.lowercased()
        if ["mp4", "mov", "m4v"].contains(ext) {
            // Native container: inspect video tracks
            if let track = asset.tracks(withMediaType: .video).first {
                let natural = track.naturalSize
                let maxDim = max(abs(natural.width), abs(natural.height))
                let bitrate = track.estimatedDataRate

                // 4K / 8K inspection
                if maxDim >= 3840 {
                    // Check format descriptions for H.264 High 4:2:2 10-bit or high bitrates
                    // On Intel macOS (MBP 2019), VideoToolbox ONLY accelerates H.264 8-bit 4:2:0.
                    // 10-bit / 4:2:2 H.264 (like Sony XAVC-S C3585.MP4) forces pure software decoding,
                    // taking ~15 seconds of CPU. This is classified as HIGH.
                    for desc in track.formatDescriptions {
                        let mediaSubType = CMFormatDescriptionGetMediaSubType(desc as! CMFormatDescription)
                        if mediaSubType == kCMVideoCodecType_H264 {
                            // If H.264 at 4K with bitrate > 60 Mbps, it is almost certainly high-bitrate / professional 10-bit
                            if bitrate > 60_000_000 || url.lastPathComponent.uppercased().hasPrefix("C") {
                                return .high
                            }
                        }
                    }
                    if bitrate > 120_000_000 {
                        return .high
                    }
                    return .medium
                } else if maxDim <= 1920 {
                    // Standard 1080p / 720p hardware accelerated
                    return .low
                }
            }
            return .medium
        }

        // Non-native containers (MKV, WebM, AVI, TS)
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? Int64 {
            // Massive 4K files > 3 GB without native container
            if size > 3_221_225_472 {
                return .high
            }
        }

        return .medium
    }

    // MARK: - Thumbnail Generation Pipeline

    /// Asynchronously generates a representative thumbnail for a video URL.
    /// Strictly on-demand, bounded, and resource-conservative.
    /// - Parameters:
    ///   - url: Local file URL of the video.
    ///   - targetSize: Desired maximum dimensions (e.g. 512x512).
    ///   - atPosition: Desired timestamp in seconds (default is 1.0s or nearest keyframe).
    ///   - timeout: Maximum allowed execution time before cancellation (default: 2.0s).
    ///   - maxAllowedCost: Maximum cost threshold permitted for this request (default: .medium).
    ///   - completionQueue: Queue on which completion is invoked.
    ///   - completion: Callback delivered with CGImage or VideoThumbnailError.
    @discardableResult
    public func generateThumbnail(
        for url: URL,
        targetSize: CGSize = CGSize(width: 512, height: 512),
        atPosition position: Double = 1.0,
        timeout: TimeInterval = 2.0,
        maxAllowedCost: ThumbnailCost = .medium,
        completionQueue: DispatchQueue? = .main,
        completion: @escaping (Result<CGImage, VideoThumbnailError>) -> Void
    ) -> VideoThumbnailTask {
        let task = VideoThumbnailTask()

        let deliver: (Result<CGImage, VideoThumbnailError>) -> Void = { [weak self] result in
            self?.lock.lock()
            self?.metricRequestsProcessed += 1
            self?.lock.unlock()

            if let q = completionQueue {
                q.async { completion(result) }
            } else {
                completion(result)
            }
        }

        // 1. Fast Cache Key Lookup
        guard let cacheKey = VideoThumbnailCache.shared.makeKey(for: url, targetSize: targetSize) else {
            deliver(.failure(.fileNotFound(url)))
            return task
        }

        // 2. Check LRU Cache Hit
        if let cachedImage = VideoThumbnailCache.shared.get(for: cacheKey) {
            lock.lock()
            metricCacheHits += 1
            lock.unlock()
            deliver(.success(cachedImage))
            return task
        }

        // 3. Check Negative Cache Hit (prevents repeating expensive 15s attempts on known heavy/failing files)
        if let negativeErr = VideoThumbnailCache.shared.checkNegativeCache(for: cacheKey) {
            lock.lock()
            metricNegativeCacheHits += 1
            lock.unlock()
            deliver(.failure(negativeErr))
            return task
        }

        lock.lock()
        metricCacheMisses += 1

        // 4. Backpressure check: queue capacity
        if pendingTasksCount >= maxQueueCapacity {
            metricRequestsRejectedBackpressure += 1
            lock.unlock()
            deliver(.failure(.queueFull))
            return task
        }

        // 5. Playback priority check: if video is actively playing in the player, protect 60fps rendering
        // by rejecting heavy software decode tasks under backpressure.
        if isPlaybackActive {
            let cost = Self.classifyCost(for: url)
            if cost == .high {
                metricRequestsRejectedBackpressure += 1
                lock.unlock()
                deliver(.failure(.backpressure))
                return task
            }
        }

        pendingTasksCount += 1
        lock.unlock()

        queue.async { [weak self] in
            guard let self = self else {
                deliver(.failure(.cancelled))
                return
            }

            self.lock.lock()
            self.pendingTasksCount = max(0, self.pendingTasksCount - 1)
            self.activeDecodersCount += 1
            self.lock.unlock()

            defer {
                self.lock.lock()
                self.activeDecodersCount = max(0, self.activeDecodersCount - 1)
                self.lock.unlock()
            }

            if task.isCancelled {
                self.lock.lock()
                self.metricRequestsCancelled += 1
                self.lock.unlock()
                deliver(.failure(.cancelled))
                return
            }

            guard FileManager.default.fileExists(atPath: url.path) else {
                deliver(.failure(.fileNotFound(url)))
                return
            }

            // Phase 1: Embedded Cover Art (instant metadata extraction, 0 CPU video decoding)
            if let coverArt = self.extractEmbeddedArtwork(from: url, targetSize: targetSize) {
                VideoThumbnailCache.shared.set(coverArt, for: cacheKey, cost: .low)
                deliver(.success(coverArt))
                return
            }

            if task.isCancelled {
                self.lock.lock()
                self.metricRequestsCancelled += 1
                self.lock.unlock()
                deliver(.failure(.cancelled))
                return
            }

            // Phase 2: Cost classification check
            let cost = Self.classifyCost(for: url)
            if cost > maxAllowedCost {
                // Fast-fail: record in negative cache so we never re-evaluate this expensive file
                let err = VideoThumbnailError.costExceedsBudget(cost)
                VideoThumbnailCache.shared.recordNegative(for: cacheKey, error: err)
                deliver(.failure(err))
                return
            }

            // Phase 3: Native AVFoundation with Keyframe-Only Seek (.positiveInfinity tolerance)
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
                        VideoThumbnailCache.shared.set(image, for: cacheKey, cost: .low)
                        deliver(.success(image))
                        return
                    case .failure:
                        // Fall through to libmpv fallback if within cost budget
                        break
                    }
                }
            }

            if task.isCancelled {
                self.lock.lock()
                self.metricRequestsCancelled += 1
                self.lock.unlock()
                deliver(.failure(.cancelled))
                return
            }

            // Phase 4: Bounded Headless libmpv Fallback for non-native containers / codecs
            self.extractMPVThumbnail(for: url, targetSize: targetSize, atPosition: position, timeout: timeout, task: task) { res in
                switch res {
                case .success(let img):
                    VideoThumbnailCache.shared.set(img, for: cacheKey, cost: cost)
                    deliver(.success(img))
                case .failure(let err):
                    if err != .cancelled {
                        VideoThumbnailCache.shared.recordNegative(for: cacheKey, error: err)
                    }
                    deliver(.failure(err))
                }
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

        _ = generateThumbnail(
            for: inputURL,
            targetSize: targetSize,
            timeout: timeout,
            maxAllowedCost: .high,
            completionQueue: nil
        ) { result in
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

        // Conservative resource constraints:
        // - Null VO: no OpenGL context, no window, no Metal surface
        // - Audio, network, scripts disabled
        // - Fast profile with in-loop filter skip
        // - Bounded demuxer cache: 2 MiB max
        // - Low thread footprint: 2 threads
        mpv_set_option_string(handle, "vo", "null")
        mpv_set_option_string(handle, "audio", "no")
        mpv_set_option_string(handle, "config", "no")
        mpv_set_option_string(handle, "load-scripts", "no")
        mpv_set_option_string(handle, "ytdl", "no")
        mpv_set_option_string(handle, "sub-auto", "no")
        mpv_set_option_string(handle, "profile", "fast")
        mpv_set_option_string(handle, "vd-lavc-skiploopfilter", "all")
        mpv_set_option_string(handle, "vd-lavc-fast", "yes")
        let hwdec = (UserSettings.shared.hardwareAcceleration == .disabled) ? "no" : "videotoolbox"
        mpv_set_option_string(handle, "hwdec", hwdec)
        mpv_set_option_string(handle, "hwdec-codecs", "h264,hevc,vp9,prores")
        mpv_set_option_string(handle, "demuxer-max-bytes", "2097152")
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
                usleep(40_000)
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
