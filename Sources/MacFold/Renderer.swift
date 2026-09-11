import AppKit
import MetalKit
import CoreVideo
import FoldCore

/// 48 bytes, mirrored field for field by `Uniforms` in `FoldShader.source`.
struct FoldUniforms: Equatable {
    var progress: Float = 0
    var perspective: Float = 0.7
    var blur: Float = 0.65
    var shadow: Float = 0.65
    var size = SIMD2<Float>(1, 1)
    var fadeOnly: Float = 0
    var effect: UInt32 = FoldEffect.fallback.shaderIndex
    // A negative value retains normalized-progress fixtures; app paths provide physical defocus.
    var defocus: Float = -1
    var coverage: Float = 1
    // Negative values keep normalized-progress fixtures convenient. App paths supply radians.
    var tilt: Float = -1
    var reserved: Float = 0

    var selectedEffect: FoldEffect { FoldEffect.resolve(shaderIndex: effect) }
}

final class FrameStore: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: CVPixelBuffer?
    private var revision: UInt64 = 0
    private var acceptedStream: ObjectIdentifier?
    func put(_ value: CVPixelBuffer) {
        lock.lock(); buffer = value; revision &+= 1; lock.unlock()
    }
    func get() -> (CVPixelBuffer?, UInt64) {
        lock.lock(); defer { lock.unlock() }; return (buffer, revision)
    }
    var hasFrame: Bool { lock.lock(); defer { lock.unlock() }; return buffer != nil }
    func acceptStream(_ stream: ObjectIdentifier) {
        lock.lock(); acceptedStream = stream; buffer = nil; revision &+= 1; lock.unlock()
    }
    func invalidateStream() {
        lock.lock(); acceptedStream = nil; buffer = nil; revision &+= 1; lock.unlock()
    }
    /// Check identity and replace the frame under the same lock as stop().
    /// Nil means rejected; true means this stream has just regained a frame.
    func put(_ value: CVPixelBuffer, from stream: ObjectIdentifier) -> Bool? {
        lock.lock(); defer { lock.unlock() }
        guard acceptedStream == stream else { return nil }
        let first = buffer == nil
        buffer = value; revision &+= 1
        return first
    }
    func clear(from stream: ObjectIdentifier) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard acceptedStream == stream else { return false }
        let changed = buffer != nil; buffer = nil; revision &+= 1
        return changed
    }
}

/// Immutable pipelines are shared; command queues and mutable textures stay per renderer.
@MainActor private final class FoldPipelines {
    private static var devices: [ObjectIdentifier:FoldPipelines] = [:]
    let render: MTLRenderPipelineState
    let downsample: MTLComputePipelineState
    static func shared(for device: MTLDevice) throws -> FoldPipelines {
        let key = ObjectIdentifier(device)
        if let existing = devices[key] { return existing }
        let pipelines = try FoldPipelines(device:device)
        devices[key] = pipelines
        return pipelines
    }
    private init(device: MTLDevice) throws {
        let library = try device.makeLibrary(source:FoldShader.source,options:nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name:"foldVertex")
        descriptor.fragmentFunction = library.makeFunction(name:"foldFragment")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        render = try device.makeRenderPipelineState(descriptor:descriptor)
        guard let function = library.makeFunction(name:"foldDownsample") else {
            throw AppError.message("Blur shader unavailable.")
        }
        downsample = try device.makeComputePipelineState(function:function)
    }
}

final class FoldRenderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let pipeline: MTLRenderPipelineState
    private let downsamplePipeline: MTLComputePipelineState
    private var blurPyramid: MTLTexture?
    private var blurLevels: [MTLTexture] = []
    private var blurredRevision: UInt64?
    private var renderedRevision: UInt64?
    private var renderedUniforms: FoldUniforms?
    private var cache: CVMetalTextureCache?
    private var importedBuffer: CVPixelBuffer?
    private var importedTexture: CVMetalTexture?
    private var importedRevision: UInt64?
    private let inFlight = DispatchSemaphore(value: 3)
    var frames: FrameStore?
    var fallback: MTLTexture?
    var parameters: () -> FoldUniforms = { FoldUniforms() }
    var animatedState: (() -> FoldVisualState?)?
    var blendsWithDesktop = false
    private var animation = FoldVisualAnimation()
    private var presentationGeneration: UInt64 = 0
    private var needsPresentationCallback = true
    var reportsEveryPresentation = false
    var pausesWhenSettled = false
    var keepsAnimating: () -> Bool = { false }
    var onFailure: ((String) -> Void)?
    var onPresented: (() -> Void)?
    private(set) var progress: Double = 0
    private var lastTime = ProcessInfo.processInfo.systemUptime
    private(set) var drawnFrames = 0
    private(set) var skippedFrames = 0
    private(set) var blurBuildCount = 0
    private(set) var textureImportCount = 0
    private(set) var lastGPUTimeMS: Double = 0
    var transientTextureBytes: Int { blurPyramid?.allocatedSize ?? 0 }

    @MainActor init(device: MTLDevice) throws {
        self.device = device
        guard let queue = device.makeCommandQueue() else { throw AppError.message("Metal command queue unavailable.") }
        self.queue = queue
        let pipelines = try FoldPipelines.shared(for:device)
        pipeline = pipelines.render
        downsamplePipeline = pipelines.downsample
        super.init()
        guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache) == kCVReturnSuccess else {
            throw AppError.message("Metal texture cache unavailable.")
        }
    }

    func configure(_ view: MTKView) {
        view.device = device
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColorMake(0, 0, 0, 1)
        view.framebufferOnly = true
        view.preferredFramesPerSecond = 60
        view.delegate = self
        view.isPaused = false
        view.enableSetNeedsDisplay = false
    }

    func resetProgress(to value: Double) {
        progress = value; lastTime = ProcessInfo.processInfo.systemUptime
        renderedUniforms = nil
        animation.reset()
        invalidatePresentation()
    }

    func invalidatePresentation() { presentationGeneration &+= 1; needsPresentationCallback = true }

    /// Completed or queued Metal commands retain their own resources. Clearing
    /// our references lets the desktop's full-size buffers retire after the last
    /// command, while keeping the compiled pipelines ready for the next movement.
    func releaseTransientResources() {
        invalidatePresentation()
        blurLevels.removeAll(); blurPyramid = nil; blurredRevision = nil
        importedTexture = nil; importedBuffer = nil; importedRevision = nil
        renderedUniforms = nil; renderedRevision = nil
        if let cache { CVMetalTextureCacheFlush(cache,0) }
    }

    /// The same captured frame can be presented at several lid angles. Import it
    /// once, retaining both its pixel buffer and Core Video texture until replaced.
    func importFrame(_ pixelBuffer: CVPixelBuffer, revision: UInt64) throws -> CVMetalTexture {
        if importedRevision == revision, importedBuffer === pixelBuffer, let importedTexture { return importedTexture }
        guard let cache else { throw AppError.message("Metal texture cache unavailable.") }
        var cvTexture: CVMetalTexture?
        let result = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault,cache,pixelBuffer,
            nil,.bgra8Unorm,CVPixelBufferGetWidth(pixelBuffer),CVPixelBufferGetHeight(pixelBuffer),0,&cvTexture)
        guard result == kCVReturnSuccess, let cvTexture, CVMetalTextureGetTexture(cvTexture) != nil else {
            throw AppError.message("The current desktop frame could not be prepared for Metal.")
        }
        importedBuffer = pixelBuffer; importedTexture = cvTexture; importedRevision = revision
        textureImportCount += 1
        return cvTexture
    }

    func wake(_ view: MTKView) {
        guard view.window?.occlusionState.contains(.visible) == true else { return }
        if view.isPaused { lastTime = ProcessInfo.processInfo.systemUptime; animation.prime(at:lastTime) }
        view.isPaused = false
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { renderedUniforms = nil }

    func draw(in view: MTKView) {
        dispatchPrecondition(condition:.onQueue(.main))
        guard view.window?.isVisible == true, inFlight.wait(timeout: .now()) == .success else { return }
        var committed = false
        defer { if !committed { inFlight.signal() } }
        let frame = frames?.get()
        let pixelBuffer = frame?.0
        let revision = pixelBuffer == nil ? 0 : frame!.1
        guard pixelBuffer != nil || fallback != nil else { return }
        let now = ProcessInfo.processInfo.systemUptime
        var uniforms = parameters()
        let target = uniforms.progress > 0 ? FoldVisualState(progress:Double(uniforms.progress),
            defocus:Double(max(0,uniforms.defocus)),
            tilt:Double(uniforms.tilt >= 0 ? uniforms.tilt : uniforms.progress * .pi/2)) : .clear
        let visual = animatedState?() ?? animation.sample(target:target,at:now)
        progress = visual.progress
        lastTime = now
        uniforms.progress = Float(visual.progress)
        uniforms.defocus = Float(visual.defocus)
        uniforms.tilt = Float(visual.tilt)
        uniforms.coverage = blendsWithDesktop ? Float(visual.coverage) : 1
        uniforms.size = SIMD2(Float(view.drawableSize.width), Float(view.drawableSize.height))
        let settled = visual.isNear(target) && !keepsAnimating()
        if renderedRevision == revision && renderedUniforms == uniforms {
            skippedFrames += 1
            if pausesWhenSettled && settled { view.isPaused = true }
            return
        }
        var cvTexture: CVMetalTexture?
        var texture = fallback
        if let pixelBuffer {
            do {
                cvTexture = try importFrame(pixelBuffer,revision:revision)
                texture = cvTexture.flatMap { CVMetalTextureGetTexture($0) }
            } catch { onFailure?(error.localizedDescription); return }
        }
        guard let texture else { return }
        guard let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let command = queue.makeCommandBuffer() else { return }
        do { try encode(command: command, pass: pass, texture: texture, uniforms: uniforms, sourceRevision:revision) }
        catch { blurredRevision = nil; renderedUniforms = nil; onFailure?(error.localizedDescription); return }
        let retainedTexture = cvTexture
        let generation = presentationGeneration
        let reportsPresentation = onPresented != nil && (needsPresentationCallback || reportsEveryPresentation)
        command.addCompletedHandler { [weak self, inFlight, pixelBuffer, retainedTexture] buffer in
            withExtendedLifetime((pixelBuffer, retainedTexture)) {}
            inFlight.signal()
            // Normal successful frames need no UI work after the first reveal.
            // Errors always return to main; synthetic checks retain every callback.
            guard reportsPresentation || buffer.status == .error else { return }
            DispatchQueue.main.async {
                guard let self, self.presentationGeneration == generation else { return }
                if buffer.status == .error {
                    self.blurredRevision = nil; self.renderedUniforms = nil
                    self.onFailure?(buffer.error?.localizedDescription ?? "Metal rendering failed.")
                }
                self.lastGPUTimeMS = max(0, (buffer.gpuEndTime-buffer.gpuStartTime)*1000)
                if buffer.status == .completed { self.onPresented?() }
            }
        }
        command.present(drawable)
        committed = true
        command.commit()
        needsPresentationCallback = false
        drawnFrames += 1
        renderedRevision = revision; renderedUniforms = uniforms
        if pausesWhenSettled && settled { view.isPaused = true }
    }

    /// Rebuild on each new source frame. Reuse it when only the fold angle changes.
    /// All passes use this renderer's serial queue and tracked resources. Ending each
    /// encoder orders writes before the next level reads the same texture allocation.
    private func prepareBlur(command: MTLCommandBuffer, input: MTLTexture, revision: UInt64?) throws -> MTLTexture {
        if blurPyramid?.width != input.width || blurPyramid?.height != input.height || blurPyramid?.pixelFormat != input.pixelFormat {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: input.pixelFormat,
                width: input.width, height: input.height, mipmapped: true)
            descriptor.mipmapLevelCount = min(9, descriptor.mipmapLevelCount)
            descriptor.storageMode = .private
            descriptor.usage = [.shaderRead, .shaderWrite, .pixelFormatView]
            guard let texture = device.makeTexture(descriptor: descriptor) else {
                throw AppError.message("Blur texture allocation failed.")
            }
            var levels: [MTLTexture] = []
            for level in 0..<texture.mipmapLevelCount {
                guard let view = texture.makeTextureView(pixelFormat: texture.pixelFormat, textureType: .type2D,
                    levels: level..<(level+1), slices: 0..<1) else { throw AppError.message("Blur level unavailable.") }
                levels.append(view)
            }
            blurPyramid = texture; blurLevels = levels
            blurredRevision = nil
        }
        if let revision, blurredRevision == revision, let pyramid = blurPyramid { return pyramid }
        guard let pyramid = blurPyramid, let blit = command.makeBlitCommandEncoder() else {
            throw AppError.message("Blur copy encoder unavailable.")
        }
        blit.copy(from: input, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(),
            sourceSize: MTLSize(width: input.width, height: input.height, depth: 1),
            to: pyramid, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin())
        blit.endEncoding()
        for level in 1..<blurLevels.count {
            guard let encoder = command.makeComputeCommandEncoder() else { throw AppError.message("Blur encoder unavailable.") }
            encoder.setComputePipelineState(downsamplePipeline)
            encoder.setTexture(blurLevels[level-1], index: 0)
            encoder.setTexture(blurLevels[level], index: 1)
            encoder.dispatchThreads(MTLSize(width: blurLevels[level].width, height: blurLevels[level].height, depth: 1),
                threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
            encoder.endEncoding()
        }
        blurredRevision = revision
        blurBuildCount += 1
        return pyramid
    }

    func encode(command: MTLCommandBuffer, pass: MTLRenderPassDescriptor, texture: MTLTexture, uniforms: FoldUniforms, sourceRevision: UInt64? = nil) throws {
        let moving = uniforms.progress > 0.00001 && uniforms.progress < 1 && uniforms.fadeOnly < 0.5
        // Duo skips the pyramid at zero Softness. Geometrically minified effects,
        // including Ghost, still need it to keep fine source pixels stable.
        let needsBlur = moving && (uniforms.blur > 0 || uniforms.selectedEffect.needsPrefilteredSource)
        let blurred = needsBlur ? try prepareBlur(command: command, input: texture, revision:sourceRevision) : texture
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { throw AppError.message("Render encoder unavailable.") }
        var uniforms = uniforms
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.setFragmentTexture(blurred, index: 1)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<FoldUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }

    func makeSyntheticFrame() throws -> CVPixelBuffer {
        let input = try makePreviewTexture()
        let w = input.width, h = input.height
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.bgra8Unorm,width:w,height:h,mipmapped:false)
        descriptor.usage = .renderTarget; descriptor.storageMode = .shared
        guard let target = device.makeTexture(descriptor:descriptor), let command = queue.makeCommandBuffer() else {
            throw AppError.message("Cannot create the overlay test frame.")
        }
        let pass = MTLRenderPassDescriptor();pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear;pass.colorAttachments[0].storeAction = .store
        try encode(command:command,pass:pass,texture:input,uniforms:FoldUniforms())
        command.commit();command.waitUntilCompleted()
        guard command.status == .completed else { throw AppError.message("Test frame rendering failed.") }
        var pixel: CVPixelBuffer?
        let attributes: [String:Any] = [kCVPixelBufferMetalCompatibilityKey as String:true,
                                       kCVPixelBufferIOSurfacePropertiesKey as String:[:]]
        guard CVPixelBufferCreate(kCFAllocatorDefault,w,h,kCVPixelFormatType_32BGRA,attributes as CFDictionary,&pixel) == kCVReturnSuccess,
              let pixel else { throw AppError.message("Test pixel buffer unavailable.") }
        CVPixelBufferLockBaseAddress(pixel,[])
        target.getBytes(CVPixelBufferGetBaseAddress(pixel)!,bytesPerRow:CVPixelBufferGetBytesPerRow(pixel),from:MTLRegionMake2D(0,0,w,h),mipmapLevel:0)
        CVPixelBufferUnlockBaseAddress(pixel,[])
        return pixel
    }

    func makePreviewTexture(width: Int = 1440, height: Int = 936) throws -> MTLTexture {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width*4, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw AppError.message("Preview image could not be created.")
        }
        context.scaleBy(x: CGFloat(width)/1440, y: CGFloat(height)/936)

        // 1. Deep Cosmic Obsidian Base Gradient
        let bgColors = [
            NSColor(red: 0.03, green: 0.03, blue: 0.06, alpha: 1.0).cgColor,
            NSColor(red: 0.07, green: 0.06, blue: 0.12, alpha: 1.0).cgColor,
            NSColor(red: 0.05, green: 0.04, blue: 0.09, alpha: 1.0).cgColor
        ] as CFArray
        let bgGradient = CGGradient(colorsSpace: colorSpace, colors: bgColors, locations: [0.0, 0.55, 1.0])!
        context.drawLinearGradient(bgGradient, start: CGPoint(x: 720, y: 936), end: CGPoint(x: 720, y: 0), options: [])

        // 2. Ambient Color Glows (Warm Sunset & Cosmic Violet)
        let glowOrange = CGGradient(colorsSpace: colorSpace, colors: [
            NSColor(red: 0.98, green: 0.46, blue: 0.14, alpha: 0.28).cgColor,
            NSColor(red: 0.98, green: 0.46, blue: 0.14, alpha: 0.0).cgColor
        ] as CFArray, locations: [0.0, 1.0])!
        context.drawRadialGradient(glowOrange, startCenter: CGPoint(x: 950, y: 480), startRadius: 0,
                                   endCenter: CGPoint(x: 950, y: 480), endRadius: 520, options: [])

        let glowViolet = CGGradient(colorsSpace: colorSpace, colors: [
            NSColor(red: 0.58, green: 0.18, blue: 0.88, alpha: 0.25).cgColor,
            NSColor(red: 0.58, green: 0.18, blue: 0.88, alpha: 0.0).cgColor
        ] as CFArray, locations: [0.0, 1.0])!
        context.drawRadialGradient(glowViolet, startCenter: CGPoint(x: 420, y: 520), startRadius: 0,
                                   endCenter: CGPoint(x: 420, y: 520), endRadius: 560, options: [])

        // 3. Flowing Cosmic Silk Ribbon Waves
        func drawRibbon(points: [(CGPoint, CGPoint, CGPoint, CGPoint)], colors: [CGColor], alpha: CGFloat = 0.55) {
            context.saveGState()
            context.setAlpha(alpha)
            let path = CGMutablePath()
            path.move(to: points[0].0)
            for seg in points {
                path.addCurve(to: seg.3, control1: seg.1, control2: seg.2)
            }
            path.addLine(to: CGPoint(x: 1440, y: 0))
            path.addLine(to: CGPoint(x: 0, y: 0))
            path.closeSubpath()
            let grad = CGGradient(colorsSpace: colorSpace, colors: colors as CFArray, locations: [0.0, 1.0])!
            context.addPath(path)
            context.clip()
            context.drawLinearGradient(grad, start: CGPoint(x: 200, y: 900), end: CGPoint(x: 1240, y: 100), options: [])
            context.restoreGState()
        }

        // Violet Wave
        drawRibbon(points: [
            (CGPoint(x: 0, y: 420), CGPoint(x: 380, y: 680), CGPoint(x: 920, y: 220), CGPoint(x: 1440, y: 540))
        ], colors: [
            NSColor(red: 0.65, green: 0.15, blue: 0.85, alpha: 0.85).cgColor,
            NSColor(red: 0.32, green: 0.08, blue: 0.62, alpha: 0.50).cgColor
        ], alpha: 0.60)

        // Vibrant Amber/Orange Fold Wave
        drawRibbon(points: [
            (CGPoint(x: 0, y: 310), CGPoint(x: 420, y: 560), CGPoint(x: 980, y: 140), CGPoint(x: 1440, y: 430))
        ], colors: [
            NSColor(red: 1.0, green: 0.62, blue: 0.18, alpha: 0.90).cgColor,
            NSColor(red: 0.92, green: 0.32, blue: 0.08, alpha: 0.60).cgColor
        ], alpha: 0.70)

        // Electric Cyber Cyan Ribbon
        drawRibbon(points: [
            (CGPoint(x: 0, y: 220), CGPoint(x: 480, y: 440), CGPoint(x: 940, y: 90), CGPoint(x: 1440, y: 320))
        ], colors: [
            NSColor(red: 0.12, green: 0.72, blue: 0.95, alpha: 0.80).cgColor,
            NSColor(red: 0.04, green: 0.35, blue: 0.68, alpha: 0.40).cgColor
        ], alpha: 0.55)

        // Deep Shadow Wave for Physical Folding Dimension
        drawRibbon(points: [
            (CGPoint(x: 0, y: 150), CGPoint(x: 520, y: 320), CGPoint(x: 1000, y: 60), CGPoint(x: 1440, y: 210))
        ], colors: [
            NSColor(red: 0.08, green: 0.07, blue: 0.15, alpha: 0.95).cgColor,
            NSColor(red: 0.03, green: 0.03, blue: 0.08, alpha: 0.95).cgColor
        ], alpha: 0.80)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)

        // 4. macOS Top Menu Bar
        NSColor(white: 0.03, alpha: 0.55).setFill()
        NSRect(x: 0, y: 904, width: 1440, height: 32).fill()
        NSColor(white: 1.0, alpha: 0.12).setFill()
        NSRect(x: 0, y: 904, width: 1440, height: 1).fill()

        // Apple Logo glyph
        let menuAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .regular),
            .foregroundColor: NSColor.white.withAlphaComponent(0.85)
        ]
        let boldMenuAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .bold),
            .foregroundColor: NSColor.white
        ]
        ("" as NSString).draw(at: CGPoint(x: 24, y: 911), withAttributes: boldMenuAttrs)
        ("Mac Fold" as NSString).draw(at: CGPoint(x: 48, y: 911), withAttributes: boldMenuAttrs)
        var menuX: CGFloat = 130
        for item in ["File", "Edit", "View", "Window", "Help"] {
            (item as NSString).draw(at: CGPoint(x: menuX, y: 911), withAttributes: menuAttrs)
            menuX += (item as NSString).size(withAttributes: menuAttrs).width + 18
        }
        // Right status bar items
        let statusText = "􀛨   􀙇   􀊫   􀉮   Tue Sep 11  9:41 AM" as NSString
        let statusSize = statusText.size(withAttributes: menuAttrs)
        statusText.draw(at: CGPoint(x: 1440 - statusSize.width - 24, y: 911), withAttributes: menuAttrs)

        // 5. Center Glassmorphic Hero Card
        let cardRect = NSRect(x: 440, y: 350, width: 560, height: 260)
        let cardPath = NSBezierPath(roundedRect: cardRect, xRadius: 26, yRadius: 26)
        NSColor(red: 0.08, green: 0.08, blue: 0.14, alpha: 0.65).setFill()
        cardPath.fill()

        // Card Specular Border
        context.saveGState()
        cardPath.lineWidth = 1.5
        NSColor(white: 1.0, alpha: 0.22).setStroke()
        cardPath.stroke()
        context.restoreGState()

        // Card Glow Header & Logo
        var logoDrawn = false
        let logoImagePaths = [
            Bundle.main.url(forResource: "MacFoldMark", withExtension: "png")?.path,
            "Resources/MacFoldMark.png",
            "docs/assets/mark.png",
            "docs/assets/Logo.png"
        ].compactMap { $0 }

        for path in logoImagePaths {
            if let image = NSImage(contentsOfFile: path) {
                let logoRect = NSRect(x: 476, y: 476, width: 68, height: 68)
                // Soft ambient backing glow
                NSColor(red: 1.0, green: 0.55, blue: 0.18, alpha: 0.35).setFill()
                NSBezierPath(ovalIn: logoRect.insetBy(dx: -8, dy: -8)).fill()
                image.draw(in: logoRect)
                logoDrawn = true
                break
            }
        }
        if !logoDrawn {
            NSColor(red: 1.0, green: 0.55, blue: 0.18, alpha: 0.9).setFill()
            NSBezierPath(roundedRect: NSRect(x: 476, y: 476, width: 68, height: 68), xRadius: 18, yRadius: 18).fill()
        }

        // Title & Description
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 42, weight: .bold),
            .foregroundColor: NSColor.white
        ]
        let subAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 16, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.72)
        ]
        ("Mac Fold" as NSString).draw(at: CGPoint(x: 564, y: 494), withAttributes: titleAttrs)
        ("Physical Lid Motion & Display Engine" as NSString).draw(at: CGPoint(x: 566, y: 468), withAttributes: subAttrs)

        // Feature Pills
        func drawPill(text: String, dotColor: NSColor, x: CGFloat, y: CGFloat) {
            let pillAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                .foregroundColor: NSColor.white.withAlphaComponent(0.92)
            ]
            let textSize = (text as NSString).size(withAttributes: pillAttrs)
            let pillRect = NSRect(x: x, y: y, width: textSize.width + 36, height: 32)
            NSColor(white: 1.0, alpha: 0.10).setFill()
            NSBezierPath(roundedRect: pillRect, xRadius: 16, yRadius: 16).fill()
            NSColor(white: 1.0, alpha: 0.18).setStroke()
            NSBezierPath(roundedRect: pillRect, xRadius: 16, yRadius: 16).stroke()
            dotColor.setFill()
            NSBezierPath(ovalIn: NSRect(x: x + 12, y: y + 11, width: 10, height: 10)).fill()
            (text as NSString).draw(at: CGPoint(x: x + 28, y: y + 8), withAttributes: pillAttrs)
        }

        drawPill(text: "120Hz ProMotion Ready", dotColor: NSColor(red: 0.25, green: 0.88, blue: 0.52, alpha: 1.0),
                 x: 476, y: 395)
        drawPill(text: "6 Real-Time Metal Shaders", dotColor: NSColor(red: 1.0, green: 0.56, blue: 0.18, alpha: 1.0),
                 x: 720, y: 395)

        // 6. Realistic macOS Glass Dock
        let dockWidth: CGFloat = 580
        let dockHeight: CGFloat = 76
        let dockRect = NSRect(x: (1440 - dockWidth) / 2, y: 26, width: dockWidth, height: dockHeight)
        let dockPath = NSBezierPath(roundedRect: dockRect, xRadius: 24, yRadius: 24)
        NSColor(white: 0.12, alpha: 0.65).setFill()
        dockPath.fill()
        NSColor(white: 1.0, alpha: 0.25).setStroke()
        dockPath.lineWidth = 1.0
        dockPath.stroke()

        // 7 Detailed App Icons in Dock
        let iconSize: CGFloat = 52
        let iconSpacing: CGFloat = 24
        let totalIconsWidth = 7 * iconSize + 6 * iconSpacing
        let startIconX = dockRect.minX + (dockWidth - totalIconsWidth) / 2
        let iconY = dockRect.minY + (dockHeight - iconSize) / 2 + 2

        for i in 0..<7 {
            let ix = startIconX + CGFloat(i) * (iconSize + iconSpacing)
            let irect = NSRect(x: ix, y: iconY, width: iconSize, height: iconSize)
            let ipath = NSBezierPath(roundedRect: irect, xRadius: 13, yRadius: 13)

            switch i {
            case 0: // Finder
                let fGrad = CGGradient(colorsSpace: colorSpace, colors: [
                    NSColor(red: 0.35, green: 0.72, blue: 0.98, alpha: 1.0).cgColor,
                    NSColor(red: 0.12, green: 0.40, blue: 0.85, alpha: 1.0).cgColor
                ] as CFArray, locations: [0.0, 1.0])!
                context.saveGState(); ipath.addClip()
                context.drawLinearGradient(fGrad, start: CGPoint(x: ix, y: iconY+iconSize), end: CGPoint(x: ix+iconSize, y: iconY), options: [])
                context.restoreGState()
                ("🙂" as NSString).draw(at: CGPoint(x: ix + 12, y: iconY + 11),
                                       withAttributes: [.font: NSFont.systemFont(ofSize: 26)])
            case 1: // Safari
                let sGrad = CGGradient(colorsSpace: colorSpace, colors: [
                    NSColor(red: 0.15, green: 0.55, blue: 0.98, alpha: 1.0).cgColor,
                    NSColor(red: 0.05, green: 0.28, blue: 0.75, alpha: 1.0).cgColor
                ] as CFArray, locations: [0.0, 1.0])!
                context.saveGState(); ipath.addClip()
                context.drawLinearGradient(sGrad, start: CGPoint(x: ix, y: iconY+iconSize), end: CGPoint(x: ix, y: iconY), options: [])
                context.restoreGState()
                ("🧭" as NSString).draw(at: CGPoint(x: ix + 12, y: iconY + 11),
                                       withAttributes: [.font: NSFont.systemFont(ofSize: 26)])
            case 2: // Terminal
                NSColor(white: 0.14, alpha: 1.0).setFill()
                ipath.fill()
                NSColor(white: 0.30, alpha: 1.0).setStroke()
                ipath.stroke()
                (">_" as NSString).draw(at: CGPoint(x: ix + 10, y: iconY + 15),
                                        withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 22, weight: .bold),
                                                         .foregroundColor: NSColor(red: 0.3, green: 0.95, blue: 0.5, alpha: 1.0)])
            case 3: // Mac Fold (Featured App)
                NSColor(red: 0.08, green: 0.08, blue: 0.12, alpha: 1.0).setFill()
                ipath.fill()
                NSColor(red: 1.0, green: 0.55, blue: 0.18, alpha: 0.9).setStroke()
                ipath.lineWidth = 1.5
                ipath.stroke()
                if let path = logoImagePaths.first, let img = NSImage(contentsOfFile: path) {
                    img.draw(in: irect.insetBy(dx: 6, dy: 6))
                } else {
                    ("∞" as NSString).draw(at: CGPoint(x: ix + 14, y: iconY + 10),
                                          withAttributes: [.font: NSFont.systemFont(ofSize: 32, weight: .bold),
                                                           .foregroundColor: NSColor(red: 1.0, green: 0.6, blue: 0.2, alpha: 1.0)])
                }
            case 4: // Code / Xcode
                let xGrad = CGGradient(colorsSpace: colorSpace, colors: [
                    NSColor(red: 0.12, green: 0.45, blue: 0.92, alpha: 1.0).cgColor,
                    NSColor(red: 0.05, green: 0.22, blue: 0.65, alpha: 1.0).cgColor
                ] as CFArray, locations: [0.0, 1.0])!
                context.saveGState(); ipath.addClip()
                context.drawLinearGradient(xGrad, start: CGPoint(x: ix, y: iconY+iconSize), end: CGPoint(x: ix, y: iconY), options: [])
                context.restoreGState()
                ("🛠️" as NSString).draw(at: CGPoint(x: ix + 12, y: iconY + 11),
                                        withAttributes: [.font: NSFont.systemFont(ofSize: 25)])
            case 5: // Photos
                NSColor.white.setFill()
                ipath.fill()
                ("🌸" as NSString).draw(at: CGPoint(x: ix + 11, y: iconY + 11),
                                       withAttributes: [.font: NSFont.systemFont(ofSize: 27)])
            case 6: // Settings
                let gGrad = CGGradient(colorsSpace: colorSpace, colors: [
                    NSColor(white: 0.65, alpha: 1.0).cgColor,
                    NSColor(white: 0.42, alpha: 1.0).cgColor
                ] as CFArray, locations: [0.0, 1.0])!
                context.saveGState(); ipath.addClip()
                context.drawLinearGradient(gGrad, start: CGPoint(x: ix, y: iconY+iconSize), end: CGPoint(x: ix, y: iconY), options: [])
                context.restoreGState()
                ("⚙️" as NSString).draw(at: CGPoint(x: ix + 12, y: iconY + 11),
                                        withAttributes: [.font: NSFont.systemFont(ofSize: 26)])
            default: break
            }

            // Running indicator dot under active apps
            if [0, 2, 3].contains(i) {
                NSColor.white.withAlphaComponent(0.85).setFill()
                NSBezierPath(ovalIn: NSRect(x: ix + iconSize / 2 - 2, y: dockRect.minY + 4, width: 4, height: 4)).fill()
            }
        }

        NSGraphicsContext.restoreGraphicsState()
        guard let image = context.makeImage() else { throw AppError.message("Preview image is unavailable.") }
        return try MTKTextureLoader(device:device).newTexture(cgImage:image,options:[.SRGB:false,.origin:MTKTextureLoader.Origin.topLeft])
    }
}

enum AppError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let s) = self { return s }; return nil }
}
