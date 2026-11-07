import Foundation
import CoreGraphics
import QuartzCore
import CMPV

/// Concrete `libmpv` playback engine isolated from AppKit windows and controls.
public final class MPVPlaybackEngine: PlaybackEngineProtocol {
    public weak var delegate: PlaybackEngineDelegate?

    public private(set) var currentURL: URL?
    public private(set) var isPaused: Bool = false
    public private(set) var position: Double = 0.0
    public private(set) var duration: Double = 0.0
    public private(set) var volume: Double = 100.0
    public private(set) var isMuted: Bool = false
    public private(set) var videoSize: CGSize = .zero
    public private(set) var diagnostics = PlaybackDiagnostics()

    private var mpvHandle: OpaquePointer?
    private var renderContext: OpaquePointer?
    private let eventQueue = DispatchQueue(label: "com.upreviewx.mpv.events", qos: .userInteractive)
    private let stateLock = NSLock()
    private var isShuttingDown = false
    private let useNullVideoOutput: Bool

    // Timing instrumentation
    private var initStartTimestamp: CFAbsoluteTime = 0
    private var loadStartTimestamp: CFAbsoluteTime = 0
    private var seekStartTimestamp: CFAbsoluteTime = 0
    private var hasRenderedFirstFrameForCurrentFile = false
    private var isAwaitingSeekRestart = false
    private var eofReached = false
    private var pendingLoadURL: URL?

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
        mpv_set_option_string(handle, "hwdec", "videotoolbox")
        // On x86_64 Intel Macs, VideoToolbox supports h264, hevc, vp9, prores; AV1 has no Intel HW decoder and uses libdav1d
        mpv_set_option_string(handle, "hwdec-codecs", "h264,hevc,vp9,prores")
        mpv_set_option_string(handle, "vd-lavc-dr", "yes")
        mpv_set_option_string(handle, "vd-lavc-threads", "0")
        mpv_set_option_string(handle, "keep-open", "yes")
        mpv_set_option_string(handle, "keepaspect", "yes")

        // Bounded demuxer cache to keep RAM low while keeping backward seeks fast
        mpv_set_option_string(handle, "demuxer-max-bytes", "33554432")      // 32 MiB
        mpv_set_option_string(handle, "demuxer-max-back-bytes", "16777216") // 16 MiB

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

        // Observe essential playback & decoder properties
        mpv_observe_property(handle, 1, "time-pos", MPV_FORMAT_DOUBLE)
        mpv_observe_property(handle, 2, "duration", MPV_FORMAT_DOUBLE)
        mpv_observe_property(handle, 3, "pause", MPV_FORMAT_FLAG)
        mpv_observe_property(handle, 4, "volume", MPV_FORMAT_DOUBLE)
        mpv_observe_property(handle, 5, "mute", MPV_FORMAT_FLAG)
        mpv_observe_property(handle, 6, "eof-reached", MPV_FORMAT_FLAG)
        mpv_observe_property(handle, 7, "hwdec-current", MPV_FORMAT_STRING)
        mpv_observe_property(handle, 8, "dwidth", MPV_FORMAT_INT64)
        mpv_observe_property(handle, 9, "dheight", MPV_FORMAT_INT64)

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
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.delegate?.playbackEngineDidRenderFirstFrame(self, latencyMs: latencyMs)
                self.delegate?.playbackEngine(self, didUpdateDiagnostics: self.diagnostics)
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
        eofReached = false
        diagnostics.fileName = url.lastPathComponent
        diagnostics.containerFormat = "—"
        diagnostics.codecName = "—"
        diagnostics.codecDescription = "—"
        diagnostics.pixelFormat = "—"
        diagnostics.hwFormat = ""
        diagnostics.hwdecCurrent = "no"
        diagnostics.width = 0
        diagnostics.height = 0
        diagnostics.nominalFPS = 0
        diagnostics.estimatedFPS = 0
        diagnostics.droppedFrames = 0
        diagnostics.decoderDroppedFrames = 0
        diagnostics.firstFrameLatencyMs = 0
        diagnostics.lastSeekLatencyMs = 0

        // Ensure playback starts unpaused immediately on load
        var pauseFlag: Int32 = 0
        mpv_set_property(handle, "pause", MPV_FORMAT_FLAG, &pauseFlag)

        let rc = executeCommand(["loadfile", url.path, "replace"])
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

    public func seek(to seconds: Double, exact: Bool = false) {
        let clamped = max(0.0, duration > 0 ? min(seconds, duration) : seconds)
        seekStartTimestamp = CFAbsoluteTimeGetCurrent()
        isAwaitingSeekRestart = true
        if eofReached && clamped < duration {
            eofReached = false
        }
        let mode = exact ? "absolute+exact" : "absolute+keyframes"
        _ = executeCommandAsync(["seek", String(format: "%.3f", clamped), mode])
    }

    public func seekRelative(_ deltaSeconds: Double) {
        seekStartTimestamp = CFAbsoluteTimeGetCurrent()
        isAwaitingSeekRestart = true
        _ = executeCommandAsync(["seek", String(format: "%.3f", deltaSeconds), "relative"])
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

    public func refreshDiagnostics() {
        stateLock.lock()
        guard let handle = mpvHandle, !isShuttingDown else {
            stateLock.unlock()
            return
        }
        stateLock.unlock()

        if let fmt = getStringProperty(handle, "file-format") {
            diagnostics.containerFormat = fmt
        }
        if let codec = getStringProperty(handle, "video-format") {
            diagnostics.codecName = codec
        }
        if let codecDesc = getStringProperty(handle, "video-codec") {
            diagnostics.codecDescription = codecDesc
        }
        if let pixFmt = getStringProperty(handle, "video-params/pixelformat") {
            diagnostics.pixelFormat = pixFmt
        }
        if let hwSubFmt = getStringProperty(handle, "video-params/hw-subformat") {
            diagnostics.hwFormat = hwSubFmt
        }
        if let hwdec = getStringProperty(handle, "hwdec-current") {
            diagnostics.hwdecCurrent = hwdec.isEmpty ? "no" : hwdec
        }
        if let interop = getStringProperty(handle, "hwdec-interop") {
            diagnostics.hwdecInterop = interop
        }
        diagnostics.width = Int(getInt64Property(handle, "dwidth") ?? getInt64Property(handle, "width") ?? 0)
        diagnostics.height = Int(getInt64Property(handle, "dheight") ?? getInt64Property(handle, "height") ?? 0)
        diagnostics.nominalFPS = getDoubleProperty(handle, "container-fps") ?? 0.0
        diagnostics.estimatedFPS = getDoubleProperty(handle, "estimated-vf-fps") ?? 0.0
        diagnostics.droppedFrames = getInt64Property(handle, "frame-drop-count") ?? 0
        diagnostics.decoderDroppedFrames = getInt64Property(handle, "decoder-frame-drop-count") ?? 0
        if let avsync = getDoubleProperty(handle, "avsync") {
            diagnostics.avSyncDiffMs = avsync * 1000.0
        }

        var cpuPct: Double = 0
        var rssMB: Double = 0
        cmpv_get_process_usage(&cpuPct, &rssMB)
        diagnostics.cpuUsagePercent = cpuPct
        diagnostics.residentMemoryMB = rssMB

        let snapshot = diagnostics
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.delegate?.playbackEngine(self, didUpdateDiagnostics: snapshot)
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
        stateLock.unlock()

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
            handleEvent(event, handle: handle)
        }
    }

    private func handleEvent(_ event: mpv_event, handle: OpaquePointer) {
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
            refreshDiagnostics()
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.delegate?.playbackEngineDidLoadFile(self)
            }

        case MPV_EVENT_VIDEO_RECONFIG:
            let w = getInt64Property(handle, "dwidth") ?? getInt64Property(handle, "width") ?? 0
            let h = getInt64Property(handle, "dheight") ?? getInt64Property(handle, "height") ?? 0
            if w > 0 && h > 0 {
                let size = CGSize(width: CGFloat(w), height: CGFloat(h))
                videoSize = size
                diagnostics.width = Int(w)
                diagnostics.height = Int(h)
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    self.delegate?.playbackEngine(self, didUpdateVideoSize: size)
                }
            }
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
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    self.delegate?.playbackEngine(self, didCompleteSeek: seekLatencyMs)
                    self.delegate?.playbackEngine(self, didUpdateDiagnostics: self.diagnostics)
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
            if property.format == MPV_FORMAT_STRING, let ptr = property.data {
                if let cStr = ptr.assumingMemoryBound(to: Optional<UnsafePointer<CChar>>.self).pointee {
                    let val = String(cString: cStr)
                    diagnostics.hwdecCurrent = val.isEmpty ? "no" : val
                    refreshDiagnostics()
                }
            }

        case "dwidth", "dheight":
            stateLock.lock()
            guard let handle = mpvHandle else {
                stateLock.unlock()
                return
            }
            stateLock.unlock()
            let w = getInt64Property(handle, "dwidth") ?? 0
            let h = getInt64Property(handle, "dheight") ?? 0
            if w > 0 && h > 0 {
                let newSize = CGSize(width: CGFloat(w), height: CGFloat(h))
                if newSize != videoSize {
                    videoSize = newSize
                    diagnostics.width = Int(w)
                    diagnostics.height = Int(h)
                    DispatchQueue.main.async { [weak self] in
                        guard let self = self else { return }
                        self.delegate?.playbackEngine(self, didUpdateVideoSize: newSize)
                    }
                }
            }

        default:
            break
        }
    }

    // MARK: - Low-Level Property & Command Helpers

    private func executeCommand(_ args: [String]) -> Int32 {
        stateLock.lock()
        guard let handle = mpvHandle, !isShuttingDown else {
            stateLock.unlock()
            return Int32(MPV_ERROR_UNINITIALIZED.rawValue)
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
                mpv_command(handle, constBuf)
            }
        }
    }

    private func executeCommandAsync(_ args: [String]) -> Int32 {
        stateLock.lock()
        guard let handle = mpvHandle, !isShuttingDown else {
            stateLock.unlock()
            return Int32(MPV_ERROR_UNINITIALIZED.rawValue)
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
                mpv_command_async(handle, 0, constBuf)
            }
        }
    }

    private func getStringProperty(_ handle: OpaquePointer, _ name: String) -> String? {
        guard let cStr = mpv_get_property_string(handle, name) else { return nil }
        defer { mpv_free(cStr) }
        return String(cString: cStr)
    }

    private func getDoubleProperty(_ handle: OpaquePointer, _ name: String) -> Double? {
        var value: Double = 0
        let rc = mpv_get_property(handle, name, MPV_FORMAT_DOUBLE, &value)
        return rc >= 0 ? value : nil
    }

    private func getInt64Property(_ handle: OpaquePointer, _ name: String) -> Int64? {
        var value: Int64 = 0
        let rc = mpv_get_property(handle, name, MPV_FORMAT_INT64, &value)
        return rc >= 0 ? value : nil
    }
}
