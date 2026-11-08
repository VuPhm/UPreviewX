import AppKit
import QuartzCore
import OpenGL.GL3
import CMPV

/// `CAOpenGLLayer` subclass that renders `libmpv` frames via `mpv_render_context`
/// while preserving automatic graphics switching on dual-GPU Intel MacBook Pro systems.
public final class MPVVideoLayer: CAOpenGLLayer {
    public weak var engine: MPVPlaybackEngine? {
        didSet {
            engine?.onRenderUpdateNeeded = { [weak self] in
                self?.scheduleRenderUpdate()
            }
        }
    }

    private let updateLock = NSLock()
    private var isUpdateScheduled = false

    public override init() {
        super.init()
        configureLayer()
    }

    public override init(layer: Any) {
        super.init(layer: layer)
        if let other = layer as? MPVVideoLayer {
            self.engine = other.engine
        }
        configureLayer()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureLayer()
    }

    private func configureLayer() {
        isOpaque = true
        isAsynchronous = false
        needsDisplayOnBoundsChange = true
        backgroundColor = NSColor.black.cgColor
        contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
    }

    public override func copyCGLPixelFormat(forDisplayMask mask: UInt32) -> CGLPixelFormatObj {
        // Include kCGLPFAAllowOfflineRenderers and kCGLPFASupportsAutomaticGraphicsSwitching
        // to avoid unnecessarily waking the discrete AMD Radeon Pro 5300M GPU on MBP 2019.
        let attrs: [CGLPixelFormatAttribute] = [
            kCGLPFAOpenGLProfile, CGLPixelFormatAttribute(kCGLOGLPVersion_3_2_Core.rawValue),
            kCGLPFAAccelerated,
            kCGLPFADoubleBuffer,
            kCGLPFAAllowOfflineRenderers,
            kCGLPFASupportsAutomaticGraphicsSwitching,
            CGLPixelFormatAttribute(0)
        ]

        var pix: CGLPixelFormatObj?
        var npix: GLint = 0
        CGLChoosePixelFormat(attrs, &pix, &npix)
        if let pix = pix {
            return pix
        }
        return super.copyCGLPixelFormat(forDisplayMask: mask)
    }

    public override func copyCGLContext(forPixelFormat pf: CGLPixelFormatObj) -> CGLContextObj {
        let ctx = super.copyCGLContext(forPixelFormat: pf)
        var swapInterval: GLint = 1
        CGLSetParameter(ctx, kCGLCPSwapInterval, &swapInterval)

        CGLSetCurrentContext(ctx)
        cmpv_prefer_integrated_gpu(UnsafeMutableRawPointer(ctx), UnsafeMutableRawPointer(pf))
        try? engine?.createOpenGLRenderContext()
        return ctx
    }

    public override func releaseCGLContext(_ ctx: CGLContextObj) {
        CGLSetCurrentContext(ctx)
        engine?.destroyOpenGLRenderContext()
        super.releaseCGLContext(ctx)
    }

    public override func canDraw(inCGLContext ctx: CGLContextObj, pixelFormat pf: CGLPixelFormatObj, forLayerTime t: CFTimeInterval, displayTime ts: UnsafePointer<CVTimeStamp>?) -> Bool {
        return engine != nil && bounds.width > 1 && bounds.height > 1
    }

    public override func draw(inCGLContext ctx: CGLContextObj, pixelFormat pf: CGLPixelFormatObj, forLayerTime t: CFTimeInterval, displayTime ts: UnsafePointer<CVTimeStamp>?) {
        guard let engine = engine else { return }

        CGLSetCurrentContext(ctx)

        var fbo: GLint = 0
        glGetIntegerv(GLenum(GL_DRAW_FRAMEBUFFER_BINDING), &fbo)

        let scale = contentsScale
        let pixelW = Int32(max(1.0, bounds.width * scale))
        let pixelH = Int32(max(1.0, bounds.height * scale))

        engine.renderFrameToOpenGL(fbo: fbo, width: pixelW, height: pixelH)
        super.draw(inCGLContext: ctx, pixelFormat: pf, forLayerTime: t, displayTime: ts)
        engine.reportRenderSwap()
    }

    private func scheduleRenderUpdate() {
        updateLock.lock()
        if isUpdateScheduled {
            updateLock.unlock()
            return
        }
        isUpdateScheduled = true
        updateLock.unlock()

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.updateLock.lock()
            self.isUpdateScheduled = false
            self.updateLock.unlock()

            guard let engine = self.engine else { return }
            let flags = engine.pollRenderUpdateFlags()
            if (flags & UInt64(MPV_RENDER_UPDATE_FRAME.rawValue)) != 0 {
                self.display()
            }
        }
    }
}

/// Host `NSView` backing `MPVVideoLayer` for embedding in the native macOS preview window.
public final class MPVVideoView: NSView {
    public let videoLayer = MPVVideoLayer()
    public var onDoubleClick: (() -> Void)?
    public var onContextMenuRequested: ((NSEvent) -> NSMenu?)?

    public init(engine: MPVPlaybackEngine) {
        super.init(frame: NSRect(x: 0, y: 0, width: 960, height: 540))
        wantsLayer = true
        layerContentsRedrawPolicy = .duringViewResize
        videoLayer.engine = engine
        self.layer = videoLayer
    }

    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override var isOpaque: Bool { true }

    public override var mouseDownCanMoveWindow: Bool { true }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if let scale = window?.backingScaleFactor {
            videoLayer.contentsScale = scale
            videoLayer.setNeedsDisplay()
        }
    }

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        videoLayer.frame = bounds
        CATransaction.commit()
    }

    public override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onDoubleClick?()
        } else {
            super.mouseDown(with: event)
        }
    }

    public override func menu(for event: NSEvent) -> NSMenu? {
        if let customMenu = onContextMenuRequested?(event) {
            return customMenu
        }
        return super.menu(for: event)
    }
}

