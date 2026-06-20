import AppKit
import Metal
import QuartzCore
import simd

/// An NSView subclass that hosts a CAMetalLayer configured for EDR (Extended Dynamic Range).
/// Receives linear BT.2020 float data, uploads it to a texture, and renders it via a
/// Metal render pipeline that converts to Display-P3 linear and outputs RGBA16Float for EDR.
final class HDRMetalView: NSView {

    // MARK: - Metal objects

    private var device: MTLDevice!
    private var commandQueue: MTLCommandQueue!
    private var renderPipeline: MTLRenderPipelineState!
    private var samplerState: MTLSamplerState!

    /// The source texture in RGBA32Float (linear BT.2020, padded to RGBA)
    private var sourceTexture: MTLTexture?

    /// Uniform buffer carrying per-frame color-management state to the shader.
    private var uniformBuffer: MTLBuffer!

    /// Working-RGB -> XYZ(D50) matrix received with the current frame.
    private var rgbToXYZ: simd_float3x3 = matrix_identity_float3x3

    /// Last logged EDR headroom, so we only print when it changes.
    private static var lastLoggedHeadroom: Float = -1

    /// EDR headroom applied by the most recent render. The refresh timer uses
    /// this to detect display brightness/headroom changes and re-render.
    private var lastRenderedHeadroom: Float = -1
    /// Periodic timer that re-renders when the display's EDR headroom changes
    /// (e.g. the user adjusts brightness) even without a new frame from darktable,
    /// so the HDR preview never goes stale against the current display state.
    private var headroomTimer: Timer?

    /// When true, pixels exceeding the display's EDR headroom are highlighted.
    /// Toggled with the "c" key. Defaults to off for an unobstructed preview.
    var showClipping: Bool = false {
        didSet { if sourceTexture != nil { render() } }
    }

    // Layout must match `struct Uniforms` in ShaderSource.swift.
    private struct Uniforms {
        var rgbToXYZ: simd_float3x3   // working RGB -> XYZ(D50)
        var edrHeadroom: Float        // display max EDR component value
        var showClipping: Float       // 0 or 1
        var _pad0: Float = 0
        var _pad1: Float = 0
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

    // MARK: - Metal layer

    override var wantsUpdateLayer: Bool { true }

    private var metalLayer: CAMetalLayer {
        return layer as! CAMetalLayer
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
            fatalError("No Metal-capable GPU found.")
        }
        self.device = device

        setupLayer()
        setupMetal()
        startHeadroomTracking()
    }

    /// Re-render when the display's EDR headroom changes (e.g. the user adjusts
    /// brightness), even if darktable has not sent a new frame. Without this the
    /// preview keeps the headroom from its last frame and looks wrong (SDR after
    /// brightness goes up, or not-yet-HDR after brightness comes down). The poll
    /// is cheap; a re-render only happens when the headroom actually shifts.
    private func startHeadroomTracking() {
        headroomTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self = self, self.sourceTexture != nil else { return }
            let cur = Float(self.window?.screen?.maximumExtendedDynamicRangeColorComponentValue ?? 1.0)
            if abs(cur - self.lastRenderedHeadroom) > 0.01 {
                self.render()
            }
        }
    }

    // MARK: - Layer setup

    override func makeBackingLayer() -> CALayer {
        return CAMetalLayer()
    }

    private func setupLayer() {
        let ml = metalLayer
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
        commandQueue = device.makeCommandQueue()!

        // Compile shaders from the embedded source string at runtime.
        // This avoids SPM resource bundle complexities and works in all contexts.
        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: metalShaderSource, options: nil)
        } catch {
            fatalError("Failed to compile Metal shaders: \(error)")
        }

        guard
            let vertexFn   = library.makeFunction(name: "vertexPassthrough"),
            let fragmentFn = library.makeFunction(name: "fragmentHDR")
        else {
            fatalError("Metal shader functions not found. Ensure Shaders.metal is included in the target.")
        }

        let pipelineDesc = MTLRenderPipelineDescriptor()
        pipelineDesc.vertexFunction   = vertexFn
        pipelineDesc.fragmentFunction = fragmentFn
        // Output pixel format must match the CAMetalLayer
        pipelineDesc.colorAttachments[0].pixelFormat = .rgba16Float

        do {
            renderPipeline = try device.makeRenderPipelineState(descriptor: pipelineDesc)
        } catch {
            fatalError("Failed to create render pipeline: \(error)")
        }

        // Bilinear sampler – good quality for scaling the image to window size
        let samplerDesc = MTLSamplerDescriptor()
        samplerDesc.minFilter             = .linear
        samplerDesc.magFilter             = .linear
        samplerDesc.mipFilter             = .notMipmapped
        samplerDesc.sAddressMode          = .clampToEdge
        samplerDesc.tAddressMode          = .clampToEdge
        samplerState = device.makeSamplerState(descriptor: samplerDesc)!

        // Uniform buffer (single struct, reused every frame)
        uniformBuffer = device.makeBuffer(
            length: MemoryLayout<Uniforms>.stride,
            options: .storageModeShared
        )!
    }

    // MARK: - Texture upload

    /// Called from the main thread with new pixel data from darktable.
    /// `pixels` is interleaved RGB float32 in the working profile's linear
    /// primaries, row-major, top-to-bottom. `rgbToXYZ` is the row-major 3x3
    /// matrix converting those primaries to XYZ(D50).
    func updateTexture(width: Int, height: Int, pixels: [Float], rgbToXYZ: [Float]) {
        guard width > 0, height > 0 else { return }

        self.rgbToXYZ = HDRMetalView.matrix3x3(fromRowMajor: rgbToXYZ)

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
            sourceTexture = device.makeTexture(descriptor: desc)!
        }

        guard let tex = sourceTexture else { return }

        // Expand RGB → RGBA (Metal has no native RGB32Float texture format)
        let pixelCount = width * height
        var rgba = [Float](repeating: 1.0, count: pixelCount * 4)
        for i in 0 ..< pixelCount {
            rgba[i * 4 + 0] = pixels[i * 3 + 0]
            rgba[i * 4 + 1] = pixels[i * 3 + 1]
            rgba[i * 4 + 2] = pixels[i * 3 + 2]
            rgba[i * 4 + 3] = 1.0
        }

        rgba.withUnsafeBytes { ptr in
            tex.replace(
                region: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0,
                withBytes: ptr.baseAddress!,
                bytesPerRow: width * 4 * MemoryLayout<Float>.size
            )
        }

        render()
    }

    // MARK: - Rendering

    private func render() {
        guard
            let drawable = metalLayer.nextDrawable(),
            let texture  = sourceTexture
        else { return }

        // Read current EDR headroom from the screen. This is the headroom
        // AVAILABLE RIGHT NOW (depends on the display being in HDR mode and its
        // brightness); maximumPotential... is the display's capability ceiling.
        // When current == 1.0 the display exposes no headroom, so nothing can
        // render brighter than reference white regardless of the signal.
        let headroom = Float(
            window?.screen?.maximumExtendedDynamicRangeColorComponentValue ?? 1.0
        )
        let potentialHeadroom = Float(
            window?.screen?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1.0
        )
        if abs(headroom - HDRMetalView.lastLoggedHeadroom) > 0.01 {
            HDRMetalView.lastLoggedHeadroom = headroom
            print("HDRMetalView: EDR headroom current=\(headroom) potential=\(potentialHeadroom)")
        }
        lastRenderedHeadroom = headroom

        // Write uniforms
        var uniforms = Uniforms(rgbToXYZ: rgbToXYZ,
                                edrHeadroom: headroom,
                                showClipping: showClipping ? 1.0 : 0.0)
        memcpy(uniformBuffer.contents(), &uniforms, MemoryLayout<Uniforms>.stride)

        let rpDesc = MTLRenderPassDescriptor()
        rpDesc.colorAttachments[0].texture    = drawable.texture
        rpDesc.colorAttachments[0].loadAction  = .clear
        rpDesc.colorAttachments[0].storeAction = .store
        rpDesc.colorAttachments[0].clearColor  = MTLClearColorMake(0, 0, 0, 1)

        guard
            let cmdBuf  = commandQueue.makeCommandBuffer(),
            let encoder = cmdBuf.makeRenderCommandEncoder(descriptor: rpDesc)
        else { return }

        encoder.setRenderPipelineState(renderPipeline)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.setFragmentSamplerState(samplerState, index: 0)
        encoder.setFragmentBuffer(uniformBuffer, offset: 0, index: 0)

        // Full-screen triangle (no vertex buffer needed; positions generated in vertex shader)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)

        encoder.endEncoding()
        cmdBuf.present(drawable)
        cmdBuf.commit()
    }

    // MARK: - Layout

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        metalLayer.drawableSize = CGSize(
            width:  newSize.width  * scale,
            height: newSize.height * scale
        )
        // Defer render until the next run loop pass so the CAMetalLayer drawable
        // pool has time to resize before we request a new drawable.
        if sourceTexture != nil {
            DispatchQueue.main.async { [weak self] in self?.render() }
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let scale = window?.backingScaleFactor {
            metalLayer.contentsScale = scale
        }
        // Become first responder so the clipping-warning toggle key works.
        window?.makeFirstResponder(self)
    }

    // MARK: - Keyboard

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        // "c" toggles the clipping (over-range) warning overlay.
        if event.charactersIgnoringModifiers?.lowercased() == "c" {
            showClipping.toggle()
        } else {
            super.keyDown(with: event)
        }
    }
}
