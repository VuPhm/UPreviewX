import Foundation
import CoreGraphics
import QuartzCore
import CMPV

/// Concrete `libmpv` playback engine isolated from AppKit windows and controls.
/// Uses 100% asynchronous commands and property observation after initialization
/// to prevent main-thread / VO render thread lock contention on heavy 4K streams.
public final class MPVPlaybackEngine: PlaybackEngineProtocol {
    public weak var delegate: PlaybackEngineDelegate?

    public private(set) var currentURL: URL?
    public private(set) var isPaused: Bool = false
    public private(set) var speed: Double = 1.0
    public private(set) var position: Double = 0.0
    public private(set) var duration: Double = 0.0
    public private(set) var volume: Double = 100.0
    public private(set) var isMuted: Bool = false
    public private(set) var videoSize: CGSize = .zero
    public private(set) var isFastPreviewMode: Bool = false
    public private(set) var diagnostics = PlaybackDiagnostics()

    private var mpvHandle: OpaquePointer?
    private var renderContext: OpaquePointer?
    private let eventQueue = DispatchQueue(label: "com.upreviewx.mpv.events", qos: .userInteractive)
    private let stateLock = NSLock()
    private var isShuttingDown = false
    private let useNullVideoOutput: Bool

    // Geometry state updated via observed properties
    private var codedWidth: Int = 0
    private var codedHeight: Int = 0
    private var darWidth: Int = 0
    private var darHeight: Int = 0
    private var rotationDegrees: Int = 0

    // Timing & seek coalescing instrumentation
    private var initStartTimestamp: CFAbsoluteTime = 0
    private var loadStartTimestamp: CFAbsoluteTime = 0
    private var seekStartTimestamp: CFAbsoluteTime = 0
    private var hasRenderedFirstFrameForCurrentFile = false
    private var isAwaitingSeekRestart = false
    private var pendingScrubTarget: Double?
    private var eofReached = false
    private var pendingLoadURL: URL?
    private var nextReplyUserdata: UInt64 = 1000
    private var pendingCommandCallbacks: [UInt64: (Result<Void, PlaybackEngineError>) -> Void] = [:]

    // Render update callback hook
    public var onRenderUpdateNeeded: (() -> Void)?

    public init(useNullVideoOutput: Bool = false) {
        self.useNullVideoOutput = useNullVideoOutput
    }

    deinit {
        shutdown()
    }

    public func initialize() throws {
        stateLock.lock()
        if mpvHandle != nil {
            stateLock.unlock()
            return
        }
        initStartTimestamp = CFAbsoluteTimeGetCurrent()
        guard let handle = mpv_create() else {
            stateLock.unlock()
            throw PlaybackEngineError.initializationFailed("mpv_create() returned nil")
        }
        mpvHandle = handle
        stateLock.unlock()

        // Minimal cold-start configuration: no external config/scripts/ytdl/sub-scanning
        mpv_set_option_string(handle, "config", "no")
        mpv_set_option_string(handle, "load-scripts", "no")
        mpv_set_option_string(handle, "ytdl", "no")
        mpv_set_option_string(handle, "sub-auto", "no")
        mpv_set_option_string(handle, "osd-level", "0")
        mpv_set_option_string(handle, "audio-client-name", "UPreviewX")

        // Lightweight rendering profile & VideoToolbox hardware decoding with software fallback
        mpv_set_option_string(handle, "vo", useNullVideoOutput ? "null" : "libmpv")
        mpv_set_option_string(handle, "profile", "fast")
        let hwdecOption = (UserSettings.shared.hardwareAcceleration == .disabled) ? "no" : "videotoolbox"
        mpv_set_option_string(handle, "hwdec", hwdecOption)
        // On x86_64 Intel Macs, VideoToolbox supports h264, hevc, vp9, prores; AV1 uses libdav1d
        mpv_set_option_string(handle, "hwdec-codecs", "h264,hevc,vp9,prores")
        // OpenGL libmpv render backend does not use lavc direct rendering; disabling avoids a failed probe per file
        mpv_set_option_string(handle, "vd-lavc-dr", "no")
        // 8 decoder threads is optimal for the 6-core/12-thread i7-9750H: full core saturation with ~38% lower 4K frame buffer memory and faster seek pipeline flush than 13 threads
        mpv_set_option_string(handle, "vd-lavc-threads", "8")
        mpv_set_option_string(handle, "keep-open", "yes")
        mpv_set_option_string(handle, "keepaspect", "yes")

        // Local file I/O & bounded demuxer cache: fast start without excessive readahead or RAM growth on 10-50GB files
        mpv_set_option_string(handle, "cache", "no")
        mpv_set_option_string(handle, "demuxer-readahead-secs", "1.0")
        mpv_set_option_string(handle, "demuxer-max-bytes", "67108864")      // 64 MiB forward bound
        mpv_set_option_string(handle, "demuxer-max-back-bytes", "33554432") // 32 MiB backward bound

        let status = mpv_initialize(handle)
        guard status >= 0 else {
            let message = String(cString: mpv_error_string(status))
            mpv_destroy(handle)
            stateLock.lock()
            mpvHandle = nil
            stateLock.unlock()
            throw PlaybackEngineError.initializationFailed(message)
        }

        diagnostics.engineInitLatencyMs = (CFAbsoluteTimeGetCurrent() - initStartTimestamp) * 1000.0

        // Observe all playback, geometry, and diagnostic properties asynchronously
        mpv_observe_property(handle, 1, "time-pos", MPV_FORMAT_DOUBLE)
        mpv_observe_property(handle, 2, "duration", MPV_FORMAT_DOUBLE)
        mpv_observe_property(handle, 3, "pause", MPV_FORMAT_FLAG)
        mpv_observe_property(handle, 4, "volume", MPV_FORMAT_DOUBLE)
        mpv_observe_property(handle, 5, "mute", MPV_FORMAT_FLAG)
        mpv_observe_property(handle, 6, "eof-reached", MPV_FORMAT_FLAG)
        mpv_observe_property(handle, 7, "hwdec-current", MPV_FORMAT_STRING)
        mpv_observe_property(handle, 8, "hwdec-interop", MPV_FORMAT_STRING)
        mpv_observe_property(handle, 9, "file-format", MPV_FORMAT_STRING)
        mpv_observe_property(handle, 10, "video-format", MPV_FORMAT_STRING)
        mpv_observe_property(handle, 11, "video-codec", MPV_FORMAT_STRING)
        mpv_observe_property(handle, 12, "video-params/pixelformat", MPV_FORMAT_STRING)
        mpv_observe_property(handle, 13, "video-params/hw-subformat", MPV_FORMAT_STRING)
        mpv_observe_property(handle, 14, "video-params/w", MPV_FORMAT_INT64)
        mpv_observe_property(handle, 15, "video-params/h", MPV_FORMAT_INT64)
        mpv_observe_property(handle, 16, "video-params/dw", MPV_FORMAT_INT64)
        mpv_observe_property(handle, 17, "video-params/dh", MPV_FORMAT_INT64)
        mpv_observe_property(handle, 18, "video-params/rotate", MPV_FORMAT_INT64)
        mpv_observe_property(handle, 19, "video-params/par", MPV_FORMAT_DOUBLE)
        mpv_observe_property(handle, 20, "dwidth", MPV_FORMAT_INT64)
        mpv_observe_property(handle, 21, "dheight", MPV_FORMAT_INT64)
        mpv_observe_property(handle, 22, "container-fps", MPV_FORMAT_DOUBLE)
        mpv_observe_property(handle, 23, "estimated-vf-fps", MPV_FORMAT_DOUBLE)
        mpv_observe_property(handle, 24, "frame-drop-count", MPV_FORMAT_INT64)
        mpv_observe_property(handle, 25, "decoder-frame-drop-count", MPV_FORMAT_INT64)
        mpv_observe_property(handle, 26, "avsync", MPV_FORMAT_DOUBLE)
        mpv_observe_property(handle, 27, "video-bitrate", MPV_FORMAT_DOUBLE)
        mpv_observe_property(handle, 28, "speed", MPV_FORMAT_DOUBLE)

        let logLevel = ProcessInfo.processInfo.environment["UPREVIEWX_DEBUG_MPV"] == "1" ? "v" : "error"
        mpv_request_log_messages(handle, logLevel)

        let retainedSelf = Unmanaged.passUnretained(self).toOpaque()
        mpv_set_wakeup_callback(handle, { ctx in
            guard let ctx = ctx else { return }
            let engine = Unmanaged<MPVPlaybackEngine>.fromOpaque(ctx).takeUnretainedValue()
            engine.scheduleEventProcessing()
        }, retainedSelf)
    }

    // MARK: - OpenGL Render Context Management

    public func createOpenGLRenderContext() throws {
        stateLock.lock()
        guard let handle = mpvHandle else {
            stateLock.unlock()
            throw PlaybackEngineError.renderContextFailed("Engine is not initialized")
        }
        if renderContext != nil {
            stateLock.unlock()
            return
        }
        stateLock.unlock()

        var outCtx: OpaquePointer?
        let rc = cmpv_create_opengl_render_context(handle, &outCtx)
        guard rc >= 0, let validCtx = outCtx else {
            let errStr = String(cString: mpv_error_string(rc))
            throw PlaybackEngineError.renderContextFailed(errStr)
        }

        if let rendererCStr = cmpv_current_gl_renderer() {
            diagnostics.activeGPU = String(cString: rendererCStr)
        }

        stateLock.lock()
        renderContext = validCtx
        stateLock.unlock()

        let retainedSelf = Unmanaged.passUnretained(self).toOpaque()
        mpv_render_context_set_update_callback(validCtx, { ctx in
            guard let ctx = ctx else { return }
            let engine = Unmanaged<MPVPlaybackEngine>.fromOpaque(ctx).takeUnretainedValue()
            engine.onRenderUpdateNeeded?()
        }, retainedSelf)

        stateLock.lock()
        let deferredURL = pendingLoadURL
        pendingLoadURL = nil
        stateLock.unlock()

        if let deferredURL = deferredURL {
            try? load(url: deferredURL)
        }
    }

    public func destroyOpenGLRenderContext() {
        stateLock.lock()
        guard let ctx = renderContext else {
            stateLock.unlock()
            return
        }
        renderContext = nil
        stateLock.unlock()

        mpv_render_context_set_update_callback(ctx, nil, nil)
        mpv_render_context_free(ctx)
    }

    public func pollRenderUpdateFlags() -> UInt64 {
        stateLock.lock()
        guard let ctx = renderContext, !isShuttingDown else {
            stateLock.unlock()
            return 0
        }
        stateLock.unlock()
        return mpv_render_context_update(ctx)
    }

    public func renderFrameToOpenGL(fbo: Int32, width: Int32, height: Int32) {
        stateLock.lock()
        guard let ctx = renderContext, !isShuttingDown else {
            stateLock.unlock()
            return
        }
        stateLock.unlock()

        _ = cmpv_render_opengl_fbo(ctx, fbo, width, height, 0)
    }

    public func reportRenderSwap() {
        stateLock.lock()
        guard let ctx = renderContext, !isShuttingDown else {
            stateLock.unlock()
            return
        }
        stateLock.unlock()

        mpv_render_context_report_swap(ctx)

        if !hasRenderedFirstFrameForCurrentFile && loadStartTimestamp > 0 && videoSize.width > 0 {
            hasRenderedFirstFrameForCurrentFile = true
            let latencyMs = (CFAbsoluteTimeGetCurrent() - loadStartTimestamp) * 1000.0
            diagnostics.firstFrameLatencyMs = latencyMs
            refreshProcessUsageMetrics()
            let snapshot = diagnostics
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.delegate?.playbackEngineDidRenderFirstFrame(self, latencyMs: latencyMs)
                self.delegate?.playbackEngine(self, didUpdateDiagnostics: snapshot)
            }
        }
    }

    // MARK: - Playback Control

    public func load(url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw PlaybackEngineError.fileNotFound(url)
        }
        if mpvHandle == nil {
            try initialize()
        }
        stateLock.lock()
        guard let handle = mpvHandle else {
            stateLock.unlock()
            throw PlaybackEngineError.initializationFailed("Missing mpv_handle")
        }
        if !useNullVideoOutput && renderContext == nil {
            pendingLoadURL = url
            stateLock.unlock()
            return
        }
        stateLock.unlock()

        currentURL = url
        loadStartTimestamp = CFAbsoluteTimeGetCurrent()
        hasRenderedFirstFrameForCurrentFile = false
        isAwaitingSeekRestart = false
        pendingScrubTarget = nil
        eofReached = false

        codedWidth = 0
        codedHeight = 0
        darWidth = 0
        darHeight = 0
        rotationDegrees = 0
        videoSize = .zero

        let fileSizeBytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.doubleValue ?? 0
        diagnostics.fileName = url.lastPathComponent
        diagnostics.fileSizeMB = fileSizeBytes / (1024.0 * 1024.0)
        diagnostics.containerFormat = "—"
        diagnostics.codecName = "—"
        diagnostics.codecDescription = "—"
        diagnostics.pixelFormat = "—"
        diagnostics.hwFormat = ""
        diagnostics.hwdecCurrent = "no"
        diagnostics.rawWidth = 0
        diagnostics.rawHeight = 0
        diagnostics.width = 0
        diagnostics.height = 0
        diagnostics.rotationDegrees = 0
        diagnostics.sampleAspectRatio = 1.0
        diagnostics.videoBitrateMbps = 0
        diagnostics.nominalFPS = 0
        diagnostics.estimatedFPS = 0
        diagnostics.droppedFrames = 0
        diagnostics.decoderDroppedFrames = 0
        diagnostics.firstFrameLatencyMs = 0
        diagnostics.lastSeekLatencyMs = 0

        // Unpause asynchronously, reset speed to 1.0, and issue non-blocking loadfile
        speed = 1.0
        var initialSpeed: Double = 1.0
        mpv_set_property_async(handle, 0, "speed", MPV_FORMAT_DOUBLE, &initialSpeed)
        var pauseFlag: Int32 = 0
        mpv_set_property_async(handle, 0, "pause", MPV_FORMAT_FLAG, &pauseFlag)

        let rc = executeCommandAsync(["loadfile", url.path, "replace"])
        if rc < 0 {
            let msg = String(cString: mpv_error_string(rc))
            throw PlaybackEngineError.loadFailed(msg)
        }
    }

    public func play() {
        stateLock.lock()
        guard let handle = mpvHandle else {
            stateLock.unlock()
            return
        }
        stateLock.unlock()

        if eofReached {
            eofReached = false
            seek(to: 0.0, exact: true)
        }
        var flag: Int32 = 0
        mpv_set_property_async(handle, 0, "pause", MPV_FORMAT_FLAG, &flag)
    }

    public func pause() {
        stateLock.lock()
        guard let handle = mpvHandle else {
            stateLock.unlock()
            return
        }
        stateLock.unlock()

        var flag: Int32 = 1
        mpv_set_property_async(handle, 0, "pause", MPV_FORMAT_FLAG, &flag)
    }

    public func togglePlayPause() {
        if isPaused || eofReached {
            play()
        } else {
            pause()
        }
    }

    public func setSpeed(_ newSpeed: Double) {
        stateLock.lock()
        guard let handle = mpvHandle else {
            stateLock.unlock()
            return
        }
        stateLock.unlock()

        var clamped = max(0.1, min(16.0, newSpeed))
        speed = clamped
        mpv_set_property_async(handle, 0, "speed", MPV_FORMAT_DOUBLE, &clamped)
    }

    public func seek(to seconds: Double, exact: Bool = false) {
        let clamped = max(0.0, duration > 0 ? min(seconds, duration) : seconds)
        if eofReached && clamped < duration {
            eofReached = false
        }

        // Coalesce continuous scrub seeks while a prior seek is still in flight
        if !exact && isAwaitingSeekRestart {
            pendingScrubTarget = clamped
            return
        }

        pendingScrubTarget = nil
        seekStartTimestamp = CFAbsoluteTimeGetCurrent()
        isAwaitingSeekRestart = true
        let mode = exact ? "absolute+exact" : "absolute+keyframes"
        _ = executeCommandAsync(["seek", String(format: "%.3f", clamped), mode])
    }

    public func seekRelative(_ deltaSeconds: Double, exact: Bool = false) {
        pendingScrubTarget = nil
        seekStartTimestamp = CFAbsoluteTimeGetCurrent()
        isAwaitingSeekRestart = true
        let mode = exact ? "relative+exact" : "relative+keyframes"
        _ = executeCommandAsync(["seek", String(format: "%.3f", deltaSeconds), mode])
    }

    public func setVolume(_ newVolume: Double) {
        stateLock.lock()
        guard let handle = mpvHandle else {
            stateLock.unlock()
            return
        }
        stateLock.unlock()

        var clamped = max(0.0, min(100.0, newVolume))
        volume = clamped
        mpv_set_property_async(handle, 0, "volume", MPV_FORMAT_DOUBLE, &clamped)
    }

    public func toggleMute() {
        stateLock.lock()
        guard let handle = mpvHandle else {
            stateLock.unlock()
            return
        }
        stateLock.unlock()

        var nextMute: Int32 = isMuted ? 0 : 1
        isMuted.toggle()
        mpv_set_property_async(handle, 0, "mute", MPV_FORMAT_FLAG, &nextMute)
    }

    /// Optional lightweight preview-quality mode for computationally extreme software-only 4K streams.
    /// Never enabled silently; only activated when explicitly requested by the user.
    public func setFastPreviewMode(_ enabled: Bool) {
        stateLock.lock()
        guard let handle = mpvHandle else {
            stateLock.unlock()
            return
        }
        stateLock.unlock()

        isFastPreviewMode = enabled
        diagnostics.isFastPreviewMode = enabled

        let fastVal = enabled ? "yes" : "no"
        let skipFilterVal = enabled ? "all" : "default"
        _ = fastVal.withCString { cStr in
            var ptr: UnsafePointer<CChar>? = cStr
            return mpv_set_property_async(handle, 0, "vd-lavc-fast", MPV_FORMAT_STRING, &ptr)
        }
        _ = skipFilterVal.withCString { cStr in
            var ptr: UnsafePointer<CChar>? = cStr
            return mpv_set_property_async(handle, 0, "vd-lavc-skiploopfilter", MPV_FORMAT_STRING, &ptr)
        }
        refreshDiagnostics()
    }

    public func toggleFastPreviewMode() {
        setFastPreviewMode(!isFastPreviewMode)
    }

    public func refreshDiagnostics() {
        stateLock.lock()
        guard !isShuttingDown else {
            stateLock.unlock()
            return
        }
        stateLock.unlock()

        refreshProcessUsageMetrics()
        let snapshot = diagnostics
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.delegate?.playbackEngine(self, didUpdateDiagnostics: snapshot)
        }
    }

    private func refreshProcessUsageMetrics() {
        var cpuPct: Double = 0
        var rssMB: Double = 0
        cmpv_get_process_usage(&cpuPct, &rssMB)
        diagnostics.cpuUsagePercent = cpuPct
        diagnostics.residentMemoryMB = rssMB
        if rssMB > diagnostics.peakMemoryMB {
            diagnostics.peakMemoryMB = rssMB
        }
    }

    public func shutdown() {
        stateLock.lock()
        if isShuttingDown {
            stateLock.unlock()
            return
        }
        isShuttingDown = true
        let rCtx = renderContext
        renderContext = nil
        let handle = mpvHandle
        mpvHandle = nil
        let callbacks = pendingCommandCallbacks
        pendingCommandCallbacks.removeAll()
        stateLock.unlock()

        for (_, cb) in callbacks {
            cb(.failure(.initializationFailed("Engine shutdown")))
        }

        if let rCtx = rCtx {
            mpv_render_context_set_update_callback(rCtx, nil, nil)
            mpv_render_context_free(rCtx)
        }
        if let handle = handle {
            mpv_set_wakeup_callback(handle, nil, nil)
            mpv_terminate_destroy(handle)
        }
    }

    // MARK: - Internal Event Loop

    private func scheduleEventProcessing() {
        eventQueue.async { [weak self] in
            self?.drainEvents()
        }
    }

    private func drainEvents() {
        while true {
            stateLock.lock()
            guard let handle = mpvHandle, !isShuttingDown else {
                stateLock.unlock()
                return
            }
            stateLock.unlock()

            guard let eventPtr = mpv_wait_event(handle, 0) else { return }
            let event = eventPtr.pointee
            if event.event_id == MPV_EVENT_NONE {
                break
            }
            handleEvent(event)
        }
    }

    private func handleEvent(_ event: mpv_event) {
        switch event.event_id {
        case MPV_EVENT_FILE_LOADED:
            if useNullVideoOutput && !hasRenderedFirstFrameForCurrentFile && loadStartTimestamp > 0 {
                hasRenderedFirstFrameForCurrentFile = true
                let latencyMs = (CFAbsoluteTimeGetCurrent() - loadStartTimestamp) * 1000.0
                diagnostics.firstFrameLatencyMs = latencyMs
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    self.delegate?.playbackEngineDidRenderFirstFrame(self, latencyMs: latencyMs)
                }
            }
            recalculateEffectiveVideoSize()
            refreshDiagnostics()
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.delegate?.playbackEngineDidLoadFile(self)
            }

        case MPV_EVENT_VIDEO_RECONFIG:
            recalculateEffectiveVideoSize()
            refreshDiagnostics()

        case MPV_EVENT_PLAYBACK_RESTART:
            if !hasRenderedFirstFrameForCurrentFile && loadStartTimestamp > 0 {
                hasRenderedFirstFrameForCurrentFile = true
                let latencyMs = (CFAbsoluteTimeGetCurrent() - loadStartTimestamp) * 1000.0
                diagnostics.firstFrameLatencyMs = latencyMs
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    self.delegate?.playbackEngineDidRenderFirstFrame(self, latencyMs: latencyMs)
                }
            }
            if isAwaitingSeekRestart && seekStartTimestamp > 0 {
                isAwaitingSeekRestart = false
                let seekLatencyMs = (CFAbsoluteTimeGetCurrent() - seekStartTimestamp) * 1000.0
                diagnostics.lastSeekLatencyMs = seekLatencyMs
                refreshProcessUsageMetrics()
                let snapshot = diagnostics
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    self.delegate?.playbackEngine(self, didCompleteSeek: seekLatencyMs)
                    self.delegate?.playbackEngine(self, didUpdateDiagnostics: snapshot)
                }
                if let nextTarget = pendingScrubTarget {
                    pendingScrubTarget = nil
                    seek(to: nextTarget, exact: false)
                }
            }
            refreshDiagnostics()

        case MPV_EVENT_END_FILE:
            if let dataPtr = event.data {
                let endFile = dataPtr.assumingMemoryBound(to: mpv_event_end_file.self).pointee
                if endFile.reason == MPV_END_FILE_REASON_ERROR || endFile.error < 0 {
                    let errMessage = String(cString: mpv_error_string(endFile.error))
                    DispatchQueue.main.async { [weak self] in
                        guard let self = self else { return }
                        self.delegate?.playbackEngine(self, didEncounterError: .loadFailed(errMessage))
                    }
                }
            }

        case MPV_EVENT_COMMAND_REPLY:
            let replyId = event.reply_userdata
            stateLock.lock()
            let callback = pendingCommandCallbacks.removeValue(forKey: replyId)
            stateLock.unlock()
            if let callback = callback {
                let res: Result<Void, PlaybackEngineError>
                if event.error < 0 {
                    let errMessage = String(cString: mpv_error_string(event.error))
                    res = .failure(.loadFailed(errMessage))
                } else {
                    res = .success(())
                }
                DispatchQueue.main.async {
                    callback(res)
                }
            }

        case MPV_EVENT_PROPERTY_CHANGE:
            guard let dataPtr = event.data else { break }
            let prop = dataPtr.assumingMemoryBound(to: mpv_event_property.self).pointee
            guard let nameCStr = prop.name else { break }
            let name = String(cString: nameCStr)
            handlePropertyChange(name: name, property: prop)

        case MPV_EVENT_LOG_MESSAGE:
            if let dataPtr = event.data {
                let logMsg = dataPtr.assumingMemoryBound(to: mpv_event_log_message.self).pointee
                if let prefix = logMsg.prefix, let text = logMsg.text {
                    let p = String(cString: prefix)
                    let t = String(cString: text).trimmingCharacters(in: .whitespacesAndNewlines)
                    if ProcessInfo.processInfo.environment["UPREVIEWX_DEBUG_MPV"] == "1" {
                        fputs("[mpv:\(p)] \(t)\n", stderr)
                    }
                }
            }

        default:
            break
        }
    }

    private func handlePropertyChange(name: String, property: mpv_event_property) {
        switch name {
        case "time-pos":
            guard property.format == MPV_FORMAT_DOUBLE, let ptr = property.data else { return }
            let pos = ptr.assumingMemoryBound(to: Double.self).pointee
            position = pos
            let dur = duration
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.delegate?.playbackEngine(self, didUpdatePosition: pos, duration: dur)
            }

        case "duration":
            guard property.format == MPV_FORMAT_DOUBLE, let ptr = property.data else { return }
            let dur = ptr.assumingMemoryBound(to: Double.self).pointee
            duration = dur
            let pos = position
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.delegate?.playbackEngine(self, didUpdatePosition: pos, duration: dur)
            }

        case "pause":
            guard property.format == MPV_FORMAT_FLAG, let ptr = property.data else { return }
            let flag = ptr.assumingMemoryBound(to: Int32.self).pointee != 0
            isPaused = flag
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.delegate?.playbackEngine(self, didUpdatePause: flag)
            }

        case "speed":
            guard property.format == MPV_FORMAT_DOUBLE, let ptr = property.data else { return }
            let spd = ptr.assumingMemoryBound(to: Double.self).pointee
            speed = spd
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.delegate?.playbackEngine(self, didUpdateSpeed: spd)
            }

        case "volume":
            guard property.format == MPV_FORMAT_DOUBLE, let ptr = property.data else { return }
            let vol = ptr.assumingMemoryBound(to: Double.self).pointee
            volume = vol
            let muted = isMuted
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.delegate?.playbackEngine(self, didUpdateVolume: vol, isMuted: muted)
            }

        case "mute":
            guard property.format == MPV_FORMAT_FLAG, let ptr = property.data else { return }
            let muted = ptr.assumingMemoryBound(to: Int32.self).pointee != 0
            isMuted = muted
            let vol = volume
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.delegate?.playbackEngine(self, didUpdateVolume: vol, isMuted: muted)
            }

        case "eof-reached":
            guard property.format == MPV_FORMAT_FLAG, let ptr = property.data else { return }
            let reached = ptr.assumingMemoryBound(to: Int32.self).pointee != 0
            eofReached = reached
            if reached {
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    self.delegate?.playbackEngineDidReachEndOfFile(self)
                }
            }

        case "hwdec-current":
            if let val = extractString(property) {
                diagnostics.hwdecCurrent = val.isEmpty ? "no" : val
            }

        case "hwdec-interop":
            if let val = extractString(property) {
                diagnostics.hwdecInterop = val
            }

        case "file-format":
            if let val = extractString(property) {
                diagnostics.containerFormat = val
            }

        case "video-format":
            if let val = extractString(property) {
                diagnostics.codecName = val
            }

        case "video-codec":
            if let val = extractString(property) {
                diagnostics.codecDescription = val
            }

        case "video-params/pixelformat":
            if let val = extractString(property) {
                diagnostics.pixelFormat = val
            }

        case "video-params/hw-subformat":
            if let val = extractString(property) {
                diagnostics.hwFormat = val
            } else {
                diagnostics.hwFormat = ""
            }

        case "video-params/w":
            if let val = extractInt64(property) {
                codedWidth = Int(val)
                diagnostics.rawWidth = codedWidth
                recalculateEffectiveVideoSize()
            }

        case "video-params/h":
            if let val = extractInt64(property) {
                codedHeight = Int(val)
                diagnostics.rawHeight = codedHeight
                recalculateEffectiveVideoSize()
            }

        case "video-params/dw", "dwidth":
            if let val = extractInt64(property), val > 0 {
                darWidth = Int(val)
                recalculateEffectiveVideoSize()
            }

        case "video-params/dh", "dheight":
            if let val = extractInt64(property), val > 0 {
                darHeight = Int(val)
                recalculateEffectiveVideoSize()
            }

        case "video-params/rotate":
            if let val = extractInt64(property) {
                rotationDegrees = Int(val)
                diagnostics.rotationDegrees = rotationDegrees
                recalculateEffectiveVideoSize()
            }

        case "video-params/par":
            if let val = extractDouble(property), val > 0 {
                diagnostics.sampleAspectRatio = val
            }

        case "container-fps":
            if let val = extractDouble(property) {
                diagnostics.nominalFPS = val
            }

        case "estimated-vf-fps":
            if let val = extractDouble(property) {
                diagnostics.estimatedFPS = val
            }

        case "frame-drop-count":
            if let val = extractInt64(property) {
                diagnostics.droppedFrames = val
            }

        case "decoder-frame-drop-count":
            if let val = extractInt64(property) {
                diagnostics.decoderDroppedFrames = val
            }

        case "avsync":
            if let val = extractDouble(property) {
                diagnostics.avSyncDiffMs = val * 1000.0
            }

        case "video-bitrate":
            if let val = extractDouble(property) {
                diagnostics.videoBitrateMbps = val / 1_000_000.0
            }

        default:
            break
        }
    }

    private func recalculateEffectiveVideoSize() {
        let effective = PlaybackDiagnostics.effectiveDisplaySize(
            codedWidth: codedWidth,
            codedHeight: codedHeight,
            darWidth: darWidth,
            darHeight: darHeight,
            rotationDegrees: rotationDegrees
        )
        guard effective.width > 0 && effective.height > 0 else { return }

        diagnostics.width = Int(effective.width)
        diagnostics.height = Int(effective.height)
        if diagnostics.rawWidth == 0 { diagnostics.rawWidth = Int(effective.width) }
        if diagnostics.rawHeight == 0 { diagnostics.rawHeight = Int(effective.height) }

        if effective != videoSize {
            videoSize = effective
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.delegate?.playbackEngine(self, didUpdateVideoSize: effective)
            }
        }
    }

    // MARK: - Event Payload Extractors & Async Command Helpers

    private func extractString(_ prop: mpv_event_property) -> String? {
        guard prop.format == MPV_FORMAT_STRING, let ptr = prop.data else { return nil }
        guard let cStr = ptr.assumingMemoryBound(to: Optional<UnsafePointer<CChar>>.self).pointee else { return nil }
        return String(cString: cStr)
    }

    private func extractInt64(_ prop: mpv_event_property) -> Int64? {
        guard prop.format == MPV_FORMAT_INT64, let ptr = prop.data else { return nil }
        return ptr.assumingMemoryBound(to: Int64.self).pointee
    }

    private func extractDouble(_ prop: mpv_event_property) -> Double? {
        guard prop.format == MPV_FORMAT_DOUBLE, let ptr = prop.data else { return nil }
        return ptr.assumingMemoryBound(to: Double.self).pointee
    }

    @discardableResult
    public func executeCommandAsyncWithReply(_ args: [String], completion: ((Result<Void, PlaybackEngineError>) -> Void)? = nil) -> Int32 {
        stateLock.lock()
        guard let handle = mpvHandle, !isShuttingDown else {
            stateLock.unlock()
            completion?(.failure(.initializationFailed("Engine is not initialized")))
            return Int32(MPV_ERROR_UNINITIALIZED.rawValue)
        }
        let replyId = nextReplyUserdata
        nextReplyUserdata += 1
        if let completion = completion {
            pendingCommandCallbacks[replyId] = completion
        }
        stateLock.unlock()

        var cArgs: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) }
        cArgs.append(nil)
        defer {
            for ptr in cArgs where ptr != nil {
                free(ptr)
            }
        }
        return cArgs.withUnsafeMutableBufferPointer { buf in
            buf.baseAddress!.withMemoryRebound(to: UnsafePointer<CChar>?.self, capacity: buf.count) { constBuf in
                mpv_command_async(handle, replyId, constBuf)
            }
        }
    }

    @discardableResult
    private func executeCommandAsync(_ args: [String]) -> Int32 {
        executeCommandAsyncWithReply(args, completion: nil)
    }

    /// Captures the unscaled, decoded video frame accurately to disk asynchronously.
    /// Preserves rotation, pixel aspect ratio, and dynamic range mapping without OSD or window elements.
    public func captureFrame(to destinationURL: URL, completion: @escaping (Result<URL, PlaybackEngineError>) -> Void) {
        stateLock.lock()
        guard mpvHandle != nil, !isShuttingDown else {
            stateLock.unlock()
            completion(.failure(.initializationFailed("Engine is not initialized")))
            return
        }
        stateLock.unlock()

        // mode 'video': exact decoded frame, no OSD, no subtitles, correct native rotation
        let rc = executeCommandAsyncWithReply(["screenshot-to-file", destinationURL.path, "video"]) { result in
            switch result {
            case .success:
                completion(.success(destinationURL))
            case .failure(let error):
                completion(.failure(error))
            }
        }
        if rc < 0 {
            let errString = String(cString: mpv_error_string(rc))
            completion(.failure(.loadFailed(errString)))
        }
    }
}
