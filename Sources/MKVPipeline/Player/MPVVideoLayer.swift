import AppKit
import CMPV
import OpenGL.GL3

/// Renders mpv's video through its OpenGL render API.
///
/// The layer owns the GL context and creates mpv's render context eagerly:
/// with `vo=libmpv`, a file loaded before a render context exists has its
/// video track disabled.
final class MPVVideoLayer: CAOpenGLLayer {
    private let pixelFormat: CGLPixelFormatObj
    private let glContext: CGLContextObj
    private var renderContext: OpaquePointer?

    init?(core: MPVCore) {
        let attributes: [CGLPixelFormatAttribute] = [
            kCGLPFAOpenGLProfile, CGLPixelFormatAttribute(kCGLOGLPVersion_3_2_Core.rawValue),
            kCGLPFAAccelerated,
            kCGLPFADoubleBuffer,
            kCGLPFAAllowOfflineRenderers,
            kCGLPFASupportsAutomaticGraphicsSwitching,
            CGLPixelFormatAttribute(0),
        ]
        var format: CGLPixelFormatObj?
        var formatCount: GLint = 0
        guard CGLChoosePixelFormat(attributes, &format, &formatCount) == kCGLNoError, let format else { return nil }
        var context: CGLContextObj?
        guard CGLCreateContext(format, nil, &context) == kCGLNoError, let context else {
            CGLReleasePixelFormat(format)
            return nil
        }
        pixelFormat = format
        glContext = context
        super.init()

        isOpaque = true
        isAsynchronous = false
        // The preview can be resized; redraw at the new size instead of stretching the last frame.
        needsDisplayOnBoundsChange = true
        backgroundColor = CGColor.black
        autoresizingMask = [.layerWidthSizable, .layerHeightSizable]

        guard createRenderContext(core: core) else { return nil }
    }

    /// Core Animation copies the layer for its presentation tree.
    override init(layer: Any) {
        let other = layer as! MPVVideoLayer
        pixelFormat = other.pixelFormat
        glContext = other.glContext
        renderContext = other.renderContext
        super.init(layer: layer)
    }

    required init?(coder: NSCoder) {
        fatalError("MPVVideoLayer is not archivable")
    }

    private func createRenderContext(core: MPVCore) -> Bool {
        CGLLockContext(glContext)
        CGLSetCurrentContext(glContext)
        defer {
            CGLSetCurrentContext(nil)
            CGLUnlockContext(glContext)
        }

        var initParameters = mpv_opengl_init_params(
            get_proc_address: { _, name in
                // RTLD_DEFAULT: the OpenGL framework is already loaded into the process.
                dlsym(UnsafeMutableRawPointer(bitPattern: -2), name)
            },
            get_proc_address_ctx: nil
        )
        let status = MPV_RENDER_API_TYPE_OPENGL.withCString { apiType in
            withUnsafeMutablePointer(to: &initParameters) { initParameters in
                var parameters = [
                    mpv_render_param(type: MPV_RENDER_PARAM_API_TYPE, data: UnsafeMutableRawPointer(mutating: apiType)),
                    mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, data: initParameters),
                    mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil),
                ]
                return mpv_render_context_create(&renderContext, core.handle, &parameters)
            }
        }
        guard status >= 0, let renderContext else {
            playerLog.error("mpv render context: \(MPVCore.describe(status), privacy: .public)")
            return false
        }

        // Called on mpv's threads whenever a new frame is ready.
        mpv_render_context_set_update_callback(renderContext, { context in
            guard let context else { return }
            // The layer is only touched on the main thread; this just carries the reference there.
            nonisolated(unsafe) let layer = Unmanaged<MPVVideoLayer>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async { layer.setNeedsDisplay() }
        }, Unmanaged.passUnretained(self).toOpaque())
        return true
    }

    /// Must run before the mpv core is destroyed.
    func destroyRenderContext() {
        guard let renderContext else { return }
        self.renderContext = nil
        CGLLockContext(glContext)
        CGLSetCurrentContext(glContext)
        mpv_render_context_set_update_callback(renderContext, nil, nil)
        mpv_render_context_free(renderContext)
        CGLSetCurrentContext(nil)
        CGLUnlockContext(glContext)
    }

    override func copyCGLPixelFormat(forDisplayMask mask: UInt32) -> CGLPixelFormatObj {
        CGLRetainPixelFormat(pixelFormat)
    }

    override func copyCGLContext(forPixelFormat pixelFormat: CGLPixelFormatObj) -> CGLContextObj {
        CGLRetainContext(glContext)
    }

    override func canDraw(
        inCGLContext context: CGLContextObj, pixelFormat: CGLPixelFormatObj,
        forLayerTime time: CFTimeInterval, displayTime: UnsafePointer<CVTimeStamp>?
    ) -> Bool {
        true
    }

    override func draw(
        inCGLContext context: CGLContextObj, pixelFormat: CGLPixelFormatObj,
        forLayerTime time: CFTimeInterval, displayTime: UnsafePointer<CVTimeStamp>?
    ) {
        guard let renderContext else {
            glClearColor(0, 0, 0, 1)
            glClear(GLbitfield(GL_COLOR_BUFFER_BIT))
            glFlush()
            return
        }
        _ = mpv_render_context_update(renderContext)

        var framebuffer: GLint = 0
        glGetIntegerv(GLenum(GL_DRAW_FRAMEBUFFER_BINDING), &framebuffer)
        var viewport = [GLint](repeating: 0, count: 4)
        glGetIntegerv(GLenum(GL_VIEWPORT), &viewport)

        var target = mpv_opengl_fbo(fbo: framebuffer, w: viewport[2], h: viewport[3], internal_format: 0)
        var flipY: Int32 = 1
        // Rendering happens on the main thread; never let mpv hold it until the frame's display time.
        var blockForTargetTime: Int32 = 0
        withUnsafeMutablePointer(to: &target) { target in
            withUnsafeMutablePointer(to: &flipY) { flipY in
                withUnsafeMutablePointer(to: &blockForTargetTime) { blockForTargetTime in
                    var parameters = [
                        mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_FBO, data: target),
                        mpv_render_param(type: MPV_RENDER_PARAM_FLIP_Y, data: flipY),
                        mpv_render_param(type: MPV_RENDER_PARAM_BLOCK_FOR_TARGET_TIME, data: blockForTargetTime),
                        mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil),
                    ]
                    _ = mpv_render_context_render(renderContext, &parameters)
                }
            }
        }
        glFlush()
    }
}

/// Layer-hosting view for the video surface. A click reports to `onClick`; a drag moves the window.
final class MPVVideoView: NSView {
    var onClick: (() -> Void)?

    private let videoLayer: MPVVideoLayer
    private var mouseDownEvent: NSEvent?
    private var didDragWindow = false

    init(videoLayer: MPVVideoLayer) {
        self.videoLayer = videoLayer
        super.init(frame: .zero)
        layer = videoLayer
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("MPVVideoView is not archivable")
    }

    override var mouseDownCanMoveWindow: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownEvent = event
        didDragWindow = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard !didDragWindow, let start = mouseDownEvent, let window, window.isMovable else { return }
        let distance = hypot(
            event.locationInWindow.x - start.locationInWindow.x,
            event.locationInWindow.y - start.locationInWindow.y
        )
        // A few points of slack so an unsteady click still counts as a click.
        guard distance > 3 else { return }
        didDragWindow = true
        window.performDrag(with: start)
    }

    override func mouseUp(with event: NSEvent) {
        defer { mouseDownEvent = nil }
        guard mouseDownEvent != nil, !didDragWindow else { return }
        onClick?()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        videoLayer.contentsScale = window?.backingScaleFactor ?? 2
        videoLayer.setNeedsDisplay()
    }
}
