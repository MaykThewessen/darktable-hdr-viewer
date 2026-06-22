import AppKit
import Metal
import QuartzCore
import CoreVideo
import simd

/// An NSView subclass that hosts a CAMetalLayer configured for EDR (Extended Dynamic Range).
/// Receives linear working-RGB float data, uploads it to a texture, and renders it via a
/// Metal render pipeline that converts to Display-P3 linear and outputs RGBA16Float for EDR.
///
/// The view continuously auto-adjusts to the CURRENT display EDR headroom: a CVDisplayLink
/// tied to the window's current display re-checks the headroom every vsync and re-renders
/// only when something actually changed (new frame, or a headroom/screen change). This keeps
/// the preview correct as the user changes brightness or drags the window between displays,
/// without waiting for a new frame from darktable and without burning the GPU at full rate.
final class HDRMetalView: NSView {

    // MARK: - Metal objects

    /// Optional so a missing GPU / failed shader compile degrades gracefully (log + render
    /// nothing) instead of a hard crash. Every render path guards on these being present.
    private var device: MTLDevice?
    private var commandQueue: MTLCommandQueue?
    private var renderPipeline: MTLRenderPipelineState?
    private var samplerState: MTLSamplerState?

    /// True once setupMetal() built a usable pipeline. When false the view renders nothing.
    private var metalReady = false

    /// The source texture in RGBA32Float (linear working-RGB, padded to RGBA).
    private var sourceTexture: MTLTexture?

    /// Uniform buffer carrying per-frame color-management state to the shader.
    private var uniformBuffer: MTLBuffer?

    /// Working-RGB -> XYZ(D50) matrix received with the current frame.
    private var rgbToXYZ: simd_float3x3 = matrix_identity_float3x3

    /// Last logged EDR headroom, so we only print when it changes.
    private static var lastLoggedHeadroom: Float = -1

    // MARK: - Auto-adjust state

    /// EDR headroom applied by the most recent render. Compared against the live screen
    /// value each display-link tick to detect brightness/headroom changes and re-render.
    private var lastRenderedHeadroom: Float = -1

    /// The headroom of the window's current screen, cached on the MAIN thread whenever the
    /// screen or screen parameters change. The display-link callback (background thread)
    /// reads only this cached value, never touching AppKit/NSScreen off-main.
    private var cachedScreenHeadroom: Float = 1.0

    /// Set on the main thread whenever new frame data arrives, the clipping toggle flips,
    /// the layout changes, or the screen/headroom changes. The display-link callback marshals
    /// to main, and only re-encodes when this is set, so an idle preview costs ~zero GPU.
    private var needsRender = false

    /// CVDisplayLink driving continuous auto-adjust, retargeted to the window's current
    /// display on every screen change. Fires on a background thread.
    private var displayLink: CVDisplayLink?

    /// The CGDirectDisplayID the display link is currently bound to, so we only retarget
    /// (which briefly stops/starts the link) when the display actually changes.
    private var currentDisplayID: CGDirectDisplayID = 0

    /// When true, pixels exceeding the display's EDR headroom are highlighted.
    /// Toggled with the "c" key. Defaults to off for an unobstructed preview.
    var showClipping: Bool = false {
        didSet { setNeedsRenderAndRefresh() }
    }

    /// When true, a per-frame auto-exposure gain (computed in updateTexture) seats
    /// the scene-referred input at a sensible level by mapping the frame's log-average
    /// (geometric-mean) luminance to a target middle-gray. Toggled with the "e" key.
    /// Defaults to ON; toggling off applies a unit gain so the user can A/B it.
    var autoExposure: Bool = true {
        didSet { setNeedsRenderAndRefresh() }
    }

    /// Target middle-gray the log-average luminance is mapped to (scene-linear 18%).
    private static let middleGray: Float = 0.18

    /// Floor for the per-pixel luminance inside the log() to avoid log(0) = -inf,
    /// and a guard band for the resulting scale so a degenerate frame can't blow up.
    private static let lumEpsilon: Float = 1e-6

    /// Per-frame auto-exposure gain computed from the latest frame's log-average
    /// working luminance. 1.0 until the first frame arrives, and whenever auto-
    /// exposure is toggled off the shader receives 1.0 regardless of this value.
    private var exposureScale: Float = 1.0

    /// True when the current frame is scene-referred (no display transform applied
    /// in darktable). Auto-exposure is applied ONLY to such frames; display-referred
    /// (filmic/sigmoid) frames are already correctly exposed and must pass through
    /// unchanged so the preview stays WYSIWYG.
    private var sceneReferred = false

    // Layout must match `struct Uniforms` in ShaderSource.swift.
    private struct Uniforms {
        var rgbToXYZ: simd_float3x3   // working RGB -> XYZ(D50)
        var edrHeadroom: Float        // display max EDR component value
        var showClipping: Float       // 0 or 1
        var exposureScale: Float = 1  // per-frame auto-exposure gain (1.0 = off)
        var _pad0: Float = 0
    }

    /// Build a column-major simd matrix from a row-major 9-float RGB->XYZ matrix.
    /// Row-major means xyz[i] = sum_j m[i*3+j] * rgb[j]; simd computes
    /// M * v = col0*v.x + col1*v.y + col2*v.z, so column j = (m[0][j], m[1][j], m[2][j]).
    private static func matrix3x3(fromRowMajor m: [Float]) -> simd_float3x3 {
        guard m.count == 9 else { return matrix_identity_float3x3 }
        return simd_float3x3(columns: (
            SIMD3<Float>(m[0], m[3], m[6]),
            SIMD3<Float>(m[1], m[4], m[7]),
            SIMD3<Float>(m[2], m[5], m[8])
        ))
    }

    /// Robust per-frame auto-exposure anchor: the log-average (geometric-mean)
    /// working luminance, exp(mean(log(max(lum, eps)))). Returns the gain that maps
    /// that anchor to `middleGray`, i.e. `middleGray / logAvgLum`, so multiplying
    /// the working RGB by it seats the scene-referred image at a sensible level
    /// regardless of its arbitrary absolute scale. The geometric mean is dominated
    /// by the bulk of the image and is insensitive to a few extreme highlights,
    /// which makes it a stable anchor for scene-linear data with sparse specular
    /// peaks.
    ///
    /// Working luminance per pixel is Y = m[3]*r + m[4]*g + m[5]*b, the Y (middle)
    /// row of the row-major working-RGB -> XYZ(D50) matrix, so it is exact for the
    /// frame's actual primaries (no fixed weight assumption). Non-finite pixels and
    /// non-positive luminance are skipped. Guards against an empty/degenerate frame
    /// by returning a unit gain (no-op) rather than NaN/Inf.
    private static func computeExposureScale(width: Int,
                                             height: Int,
                                             pixels: [Float],
                                             rgbToXYZ: [Float]) -> Float {
        guard rgbToXYZ.count == 9 else { return 1.0 }
        let yr = rgbToXYZ[3], yg = rgbToXYZ[4], yb = rgbToXYZ[5]
        let pixelCount = width * height
        guard pixelCount > 0, pixels.count >= pixelCount * 3 else { return 1.0 }

        var logSum = 0.0
        var count = 0
        pixels.withUnsafeBufferPointer { src in
            for i in 0 ..< pixelCount {
                let r = src[i * 3 + 0]
                let g = src[i * 3 + 1]
                let b = src[i * 3 + 2]
                let lum = yr * r + yg * g + yb * b
                // Skip non-finite or non-positive luminance: log() needs lum > 0,
                // and clamping to eps for huge swaths of black would bias the mean.
                guard lum.isFinite, lum > lumEpsilon else { continue }
                logSum += Double(log(lum))
                count += 1
            }
        }
        guard count > 0 else { return 1.0 }

        let logAvgLum = Float(exp(logSum / Double(count)))
        guard logAvgLum.isFinite, logAvgLum > lumEpsilon else { return 1.0 }

        let scale = middleGray / logAvgLum
        guard scale.isFinite, scale > 0 else { return 1.0 }
        return scale
    }

    // MARK: - Metal layer

    override var wantsUpdateLayer: Bool { true }

    /// Safe accessor: returns nil if the backing layer is not (yet) a CAMetalLayer.
    private var metalLayer: CAMetalLayer? {
        return layer as? CAMetalLayer
    }

    // MARK: - Init

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        wantsLayer = true

        guard let device = MTLCreateSystemDefaultDevice() else {
            // No Metal-capable GPU: degrade to a black view rather than crashing the
            // user's daily-driver tool. Nothing will render but the app stays alive.
            NSLog("HDRMetalView: no Metal-capable GPU found; rendering disabled.")
            return
        }
        self.device = device

        setupLayer()
        setupMetal()

        // Observe display reconfiguration (resolution, HDR enable, brightness-driven
        // headroom changes that come through as screen-parameter changes, displays
        // added/removed). Window-move-between-screens is handled separately below.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged(_:)),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    // MARK: - Layer setup

    override func makeBackingLayer() -> CALayer {
        let ml = CAMetalLayer()
        return ml
    }

    private func setupLayer() {
        guard let ml = metalLayer else { return }
        ml.device = device
        // RGBA16Float is required for EDR values above 1.0
        ml.pixelFormat = .rgba16Float
        ml.framebufferOnly = true

        // Extended Dynamic Range: allow values above 1.0 to reach the display
        ml.wantsExtendedDynamicRangeContent = true

        // Use the extended linear Display-P3 colorspace so Metal values map correctly
        // to physical display output without OS-level tone mapping.
        if let cs = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3) {
            ml.colorspace = cs
        }

        ml.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
        ml.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
    }

    // MARK: - Metal setup

    private func setupMetal() {
        guard let device = device else { return }
        guard let queue = device.makeCommandQueue() else {
            NSLog("HDRMetalView: failed to create command queue; rendering disabled.")
            return
        }
        commandQueue = queue

        // Compile shaders from the embedded source string at runtime.
        // This avoids SPM resource bundle complexities and works in all contexts.
        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: metalShaderSource, options: nil)
        } catch {
            // Degrade gracefully: a shader-compile failure should not take down the app.
            NSLog("HDRMetalView: failed to compile Metal shaders: \(error); rendering disabled.")
            return
        }

        guard
            let vertexFn   = library.makeFunction(name: "vertexPassthrough"),
            let fragmentFn = library.makeFunction(name: "fragmentHDR")
        else {
            NSLog("HDRMetalView: Metal shader functions not found; rendering disabled.")
            return
        }

        let pipelineDesc = MTLRenderPipelineDescriptor()
        pipelineDesc.vertexFunction   = vertexFn
        pipelineDesc.fragmentFunction = fragmentFn
        // Output pixel format must match the CAMetalLayer
        pipelineDesc.colorAttachments[0].pixelFormat = .rgba16Float

        do {
            renderPipeline = try device.makeRenderPipelineState(descriptor: pipelineDesc)
        } catch {
            NSLog("HDRMetalView: failed to create render pipeline: \(error); rendering disabled.")
            return
        }

        // Bilinear sampler – good quality for scaling the image to window size
        let samplerDesc = MTLSamplerDescriptor()
        samplerDesc.minFilter             = .linear
        samplerDesc.magFilter             = .linear
        samplerDesc.mipFilter             = .notMipmapped
        samplerDesc.sAddressMode          = .clampToEdge
        samplerDesc.tAddressMode          = .clampToEdge
        guard let sampler = device.makeSamplerState(descriptor: samplerDesc) else {
            NSLog("HDRMetalView: failed to create sampler state; rendering disabled.")
            return
        }
        samplerState = sampler

        // Uniform buffer (single struct, reused every frame)
        guard let ubuf = device.makeBuffer(
            length: MemoryLayout<Uniforms>.stride,
            options: .storageModeShared
        ) else {
            NSLog("HDRMetalView: failed to create uniform buffer; rendering disabled.")
            return
        }
        uniformBuffer = ubuf

        metalReady = true
    }

    // MARK: - Texture upload

    /// Called from the main thread with new pixel data from darktable.
    /// `pixels` is interleaved RGB float32 in the working profile's linear
    /// primaries, row-major, top-to-bottom. `rgbToXYZ` is the row-major 3x3
    /// matrix converting those primaries to XYZ(D50).
    func updateTexture(width: Int, height: Int, pixels: [Float], rgbToXYZ: [Float],
                       sceneReferred: Bool) {
        guard width > 0, height > 0 else { return }
        guard metalReady, let device = device else { return }
        // Defensive: the caller guarantees interleaved RGB, but never trust a length
        // mismatch into an out-of-bounds read on the daily driver.
        guard pixels.count >= width * height * 3 else {
            NSLog("HDRMetalView: pixel buffer too small (\(pixels.count) < \(width * height * 3)); frame dropped.")
            return
        }

        self.rgbToXYZ = HDRMetalView.matrix3x3(fromRowMajor: rgbToXYZ)
        self.sceneReferred = sceneReferred
        // Auto-exposure normalizes scene-referred input only. Display-referred
        // frames (filmic/sigmoid output) are already correctly exposed, so a unit
        // gain keeps the preview WYSIWYG instead of re-brightening a graded image.
        self.exposureScale = sceneReferred
            ? HDRMetalView.computeExposureScale(width: width, height: height,
                                                pixels: pixels, rgbToXYZ: rgbToXYZ)
            : 1.0

        // (Re)create the texture if dimensions changed
        if sourceTexture == nil
            || sourceTexture!.width  != width
            || sourceTexture!.height != height
        {
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba32Float,   // Metal does not support RGB32Float natively
                width:  width,
                height: height,
                mipmapped: false
            )
            desc.usage = [.shaderRead]
            desc.storageMode = .shared
            guard let tex = device.makeTexture(descriptor: desc) else {
                NSLog("HDRMetalView: texture allocation failed for \(width)x\(height); frame dropped.")
                return
            }
            sourceTexture = tex
        }

        guard let tex = sourceTexture else { return }

        // Expand RGB → RGBA (Metal has no native RGB32Float texture format)
        let pixelCount = width * height
        var rgba = [Float](repeating: 1.0, count: pixelCount * 4)
        pixels.withUnsafeBufferPointer { src in
            rgba.withUnsafeMutableBufferPointer { dst in
                for i in 0 ..< pixelCount {
                    dst[i * 4 + 0] = src[i * 3 + 0]
                    dst[i * 4 + 1] = src[i * 3 + 1]
                    dst[i * 4 + 2] = src[i * 3 + 2]
                    // dst[i * 4 + 3] already 1.0 from the initializer
                }
            }
        }

        rgba.withUnsafeBytes { ptr in
            guard let base = ptr.baseAddress else { return }
            tex.replace(
                region: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0,
                withBytes: base,
                bytesPerRow: width * 4 * MemoryLayout<Float>.size
            )
        }

        // A new frame must always be drawn. Render immediately (we are on main) and also
        // ensure the display link is running so subsequent headroom changes get picked up.
        needsRender = true
        ensureDisplayLinkRunning()
        render()
    }

    // MARK: - Continuous auto-adjust (CVDisplayLink)

    /// Refresh the cached screen headroom/colorspace on the MAIN thread and flag a render.
    /// Safe to call from any AppKit callback (screen change, layout, toggle).
    private func setNeedsRenderAndRefresh() {
        refreshScreenState()
        needsRender = true
        ensureDisplayLinkRunning()
    }

    /// Read the current screen's EDR headroom and update the metal layer's per-display
    /// properties (colorspace, contentsScale). MUST run on the main thread because it
    /// touches NSWindow/NSScreen and the CAMetalLayer.
    private func refreshScreenState() {
        let screen = window?.screen
        let headroom = Float(screen?.maximumExtendedDynamicRangeColorComponentValue ?? 1.0)
        cachedScreenHeadroom = max(headroom, 1.0)

        if let ml = metalLayer {
            // Re-assert the extended linear Display-P3 colorspace for the (possibly new)
            // display, and match its backing scale, so a window dragged to another screen
            // keeps mapping values correctly and stays sharp.
            if ml.colorspace == nil,
               let cs = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3) {
                ml.colorspace = cs
            }
            let scale = window?.backingScaleFactor
                ?? screen?.backingScaleFactor
                ?? NSScreen.main?.backingScaleFactor
                ?? 2.0
            if ml.contentsScale != scale {
                ml.contentsScale = scale
                // Keep the drawable size consistent with the new scale.
                ml.drawableSize = CGSize(width: bounds.width * scale,
                                         height: bounds.height * scale)
            }
        }

        // Retarget the display link to the screen the window now lives on so it ticks at
        // that display's refresh rate.
        retargetDisplayLinkIfNeeded()
    }

    /// Create the display link lazily and start it. Idempotent.
    private func ensureDisplayLinkRunning() {
        if displayLink == nil {
            var link: CVDisplayLink?
            let status = CVDisplayLinkCreateWithActiveCGDisplays(&link)
            guard status == kCVReturnSuccess, let link = link else {
                NSLog("HDRMetalView: CVDisplayLink creation failed (status \(status)); falling back to frame-driven rendering only.")
                return
            }
            // The output callback runs on a background thread and only marshals to
            // main. Pass a RETAINED reference as its context: CVDisplayLinkStop does
            // not reliably join an already-executing callback, so an unretained
            // pointer could be dereferenced just as the view is freed. Holding this
            // +1 for the process lifetime is intentional — this is the app's single
            // persistent preview surface (created once, never torn down while the
            // window exists; stopped, not destroyed, when the window is hidden).
            let opaqueSelf = Unmanaged.passRetained(self).toOpaque()
            CVDisplayLinkSetOutputCallback(link, { (_, _, _, _, _, ctx) -> CVReturn in
                guard let ctx = ctx else { return kCVReturnSuccess }
                let view = Unmanaged<HDRMetalView>.fromOpaque(ctx).takeUnretainedValue()
                view.displayLinkTick()
                return kCVReturnSuccess
            }, opaqueSelf)
            displayLink = link
            retargetDisplayLinkIfNeeded()
        }
        if let link = displayLink, !CVDisplayLinkIsRunning(link) {
            CVDisplayLinkStart(link)
        }
    }

    /// Bind the display link to the CGDirectDisplay the window currently occupies, so it
    /// fires at that display's vsync. Only acts when the display actually changed.
    private func retargetDisplayLinkIfNeeded() {
        guard let link = displayLink else { return }
        // Resolve the current display id from the window's screen.
        let displayID: CGDirectDisplayID
        if let screen = window?.screen,
           let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            displayID = CGDirectDisplayID(num.uint32Value)
        } else {
            displayID = CGMainDisplayID()
        }
        guard displayID != currentDisplayID, displayID != 0 else { return }
        currentDisplayID = displayID
        CVDisplayLinkSetCurrentCGDisplay(link, displayID)
    }

    /// Called from the CVDisplayLink BACKGROUND thread every vsync. Does NO AppKit, NO
    /// drawable access here: it only marshals to the main thread, which owns all the
    /// state and the only place we touch NSScreen / CAMetalLayer.
    private func displayLinkTick() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            // Re-read the live screen headroom on main. (Brightness changes on the
            // built-in XDR panel surface here continuously, often without a screen-
            // parameters notification.)
            let live = Float(self.window?.screen?.maximumExtendedDynamicRangeColorComponentValue ?? 1.0)
            let liveClamped = max(live, 1.0)
            if abs(liveClamped - self.cachedScreenHeadroom) > 0.001 {
                self.cachedScreenHeadroom = liveClamped
                self.needsRender = true
            }
            // Re-render only when something changed: a new frame, a toggle, a layout
            // change, or the headroom shifted. Avoids busy full-rate GPU when idle.
            if self.needsRender && abs(self.cachedScreenHeadroom - self.lastRenderedHeadroom) > 0.001 {
                self.needsRender = true
            }
            if self.needsRender {
                self.render()
            }
        }
    }

    @objc private func screenParametersChanged(_ note: Notification) {
        // Always on the main thread for AppKit notifications.
        setNeedsRenderAndRefresh()
        render()
    }

    // MARK: - Rendering

    /// MUST be called on the main thread. Encodes one frame, fully fail-safe: any missing
    /// Metal object, nil drawable, or encoder failure simply skips the frame.
    private func render() {
        guard metalReady,
              let commandQueue = commandQueue,
              let renderPipeline = renderPipeline,
              let samplerState = samplerState,
              let uniformBuffer = uniformBuffer,
              let metalLayer = metalLayer,
              let texture = sourceTexture
        else { return }

        // Read current EDR headroom from the screen. This is the headroom AVAILABLE RIGHT
        // NOW (depends on the display being in HDR mode and its brightness);
        // maximumPotential... is the display's capability ceiling. When current == 1.0 the
        // display exposes no headroom, so nothing renders brighter than reference white.
        // window?.screen is nil while the window is off all screens -> default to 1.0 (SDR).
        let screen = window?.screen
        let headroom = max(Float(screen?.maximumExtendedDynamicRangeColorComponentValue ?? 1.0), 1.0)
        let potentialHeadroom = Float(screen?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1.0)
        cachedScreenHeadroom = headroom

        if abs(headroom - HDRMetalView.lastLoggedHeadroom) > 0.01 {
            HDRMetalView.lastLoggedHeadroom = headroom
            print("HDRMetalView: EDR headroom current=\(headroom) potential=\(potentialHeadroom)")
        }

        guard let drawable = metalLayer.nextDrawable() else {
            // Drawable pool momentarily exhausted (e.g. mid-resize). Keep the dirty flag
            // set so the next display-link tick retries; do not clear needsRender.
            return
        }

        // Write uniforms. When auto-exposure is toggled off we pass a unit gain so
        // the shader is a no-op (lets the user A/B the normalization).
        var uniforms = Uniforms(rgbToXYZ: rgbToXYZ,
                                edrHeadroom: headroom,
                                showClipping: showClipping ? 1.0 : 0.0,
                                exposureScale: autoExposure ? exposureScale : 1.0)
        memcpy(uniformBuffer.contents(), &uniforms, MemoryLayout<Uniforms>.stride)

        let rpDesc = MTLRenderPassDescriptor()
        rpDesc.colorAttachments[0].texture     = drawable.texture
        rpDesc.colorAttachments[0].loadAction  = .clear
        rpDesc.colorAttachments[0].storeAction = .store
        rpDesc.colorAttachments[0].clearColor  = MTLClearColorMake(0, 0, 0, 1)

        guard
            let cmdBuf  = commandQueue.makeCommandBuffer(),
            let encoder = cmdBuf.makeRenderCommandEncoder(descriptor: rpDesc)
        else {
            // Command buffer / encoder creation failed: skip this frame, keep dirty flag.
            return
        }

        encoder.setRenderPipelineState(renderPipeline)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.setFragmentSamplerState(samplerState, index: 0)
        encoder.setFragmentBuffer(uniformBuffer, offset: 0, index: 0)

        // Full-screen triangle (no vertex buffer needed; positions generated in vertex shader)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)

        encoder.endEncoding()
        cmdBuf.present(drawable)
        cmdBuf.commit()

        // Frame committed for the current state: clear the dirty flag and record the
        // headroom we drew with, so the display link stays idle until something changes.
        lastRenderedHeadroom = headroom
        needsRender = false
    }

    // MARK: - Layout

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        guard let ml = metalLayer else { return }
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        ml.drawableSize = CGSize(
            width:  newSize.width  * scale,
            height: newSize.height * scale
        )
        // Defer render until the next run loop pass so the CAMetalLayer drawable pool has
        // time to resize before we request a new drawable.
        if sourceTexture != nil {
            needsRender = true
            DispatchQueue.main.async { [weak self] in self?.render() }
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        // Observe the window moving to another screen (different headroom / colorspace /
        // backing scale). The notification fires on the main thread.
        NotificationCenter.default.removeObserver(
            self, name: NSWindow.didChangeScreenNotification, object: nil)
        if let window = window {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowChangedScreen(_:)),
                name: NSWindow.didChangeScreenNotification,
                object: window
            )
        }

        if window != nil {
            setNeedsRenderAndRefresh()
            ensureDisplayLinkRunning()
            // Become first responder so the clipping-warning toggle key works.
            window?.makeFirstResponder(self)
        } else {
            // Window closed / removed: stop ticking the GPU until a new frame re-attaches.
            stopDisplayLink()
        }
    }

    /// The window moved to a different screen: re-read headroom/colorspace/scale and
    /// retarget the display link to the new display.
    @objc private func windowChangedScreen(_ note: Notification) {
        setNeedsRenderAndRefresh()
        render()
    }

    /// Backing properties (e.g. backing scale on display change) updated.
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        setNeedsRenderAndRefresh()
    }

    // MARK: - Keyboard

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "c":
            // Toggle the clipping (over-range) warning overlay.
            showClipping.toggle()
        case "e":
            // Toggle per-frame auto-exposure / reference-white normalization (A/B).
            autoExposure.toggle()
        default:
            super.keyDown(with: event)
        }
    }

    // MARK: - Display-link lifecycle

    private func stopDisplayLink() {
        if let link = displayLink, CVDisplayLinkIsRunning(link) {
            CVDisplayLinkStop(link)
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        if let link = displayLink {
            if CVDisplayLinkIsRunning(link) {
                CVDisplayLinkStop(link)
            }
            // Clear the callback so no late tick can fire. Note: the passRetained
            // context from ensureDisplayLinkRunning keeps this view alive for the
            // process lifetime by design, so deinit is not normally reached; we do
            // NOT release that +1 here (an unbalanced release would over-release).
            CVDisplayLinkSetOutputCallback(link, { _, _, _, _, _, _ in kCVReturnSuccess }, nil)
        }
        displayLink = nil
    }
}
