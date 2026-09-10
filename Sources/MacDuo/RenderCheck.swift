import AppKit
import MetalKit
import FoldCore

/// Offscreen checks use generated pixels only. No ScreenCaptureKit access.
@MainActor enum RenderCheck {
    private struct Frame {
        let pixels: [UInt8]
        let width: Int
        let height: Int
        let gpuMS: Double
        func gray(_ x: Int, _ y: Int) -> Int { Int(pixels[(y*width+x)*4]) }
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw AppError.message(message) }
    }

    private static func target(_ device: MTLDevice, _ width: Int, _ height: Int, shared: Bool = true) throws -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]; d.storageMode = shared ? .shared : .private
        guard let texture = device.makeTexture(descriptor: d) else { throw AppError.message("Test texture unavailable.") }
        return texture
    }

    private static func encode(_ renderer: FoldRenderer, _ source: MTLTexture, _ output: MTLTexture,
                               _ uniforms: FoldUniforms, revision: UInt64? = nil) throws -> MTLCommandBuffer {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = output
        pass.colorAttachments[0].loadAction = .clear; pass.colorAttachments[0].storeAction = .store
        guard let command = renderer.queue.makeCommandBuffer() else { throw AppError.message("Test command unavailable.") }
        var u = uniforms; u.size = SIMD2(Float(output.width), Float(output.height))
        try renderer.encode(command: command, pass: pass, texture: source, uniforms: u, sourceRevision:revision)
        command.commit()
        return command
    }

    private static func read(_ target: MTLTexture, _ command: MTLCommandBuffer) throws -> Frame {
        command.waitUntilCompleted()
        try require(command.status == .completed, command.error?.localizedDescription ?? "GPU command failed.")
        let w = target.width, h = target.height
        var pixels = [UInt8](repeating: 0, count: w*h*4)
        target.getBytes(&pixels, bytesPerRow: w*4, from: MTLRegionMake2D(0,0,w,h), mipmapLevel: 0)
        try require(stride(from: 3, to: pixels.count, by: 4).allSatisfy { pixels[$0] == 255 }, "Overlay lost opacity.")
        return Frame(pixels: pixels, width: w, height: h, gpuMS: (command.gpuEndTime-command.gpuStartTime)*1000)
    }

    private static func render(_ renderer: FoldRenderer, _ source: MTLTexture, _ output: MTLTexture,
                               _ uniforms: FoldUniforms, revision: UInt64? = nil) throws -> Frame {
        try read(output, encode(renderer, source, output, uniforms,revision:revision))
    }

    private static func save(_ frame: Frame, _ url: URL) throws {
        let provider = CGDataProvider(data: Data(frame.pixels) as CFData)!
        let bitmap = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue).union(.byteOrder32Little)
        let image = CGImage(width: frame.width, height: frame.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: frame.width*4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: bitmap, provider: provider, decode: nil,
            shouldInterpolate: false, intent: .defaultIntent)!
        try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!.write(to: url)
    }

    private static func fixture(_ device: MTLDevice, width: Int, height: Int,
                                pixel: (Int, Int) -> UInt8) throws -> MTLTexture {
        let texture = try target(device, width, height)
        var bytes = [UInt8](repeating: 255, count: width*height*4)
        for y in 0..<height { for x in 0..<width {
            let index = (y*width+x)*4, value = pixel(x,y)
            bytes[index] = value; bytes[index+1] = value; bytes[index+2] = value
        } }
        texture.replace(region: MTLRegionMake2D(0,0,width,height), mipmapLevel: 0, withBytes: bytes, bytesPerRow: width*4)
        return texture
    }

    private static func glyphBounds(_ frame: Frame) throws -> (x: Int, y: Int, width: Int, height: Int) {
        var xs: [Int] = [], ys: [Int] = []
        for y in (frame.height*2/3)..<(frame.height*97/100) {
            for x in (frame.width*2/5)..<(frame.width*3/5) where frame.gray(x,y) < 80 { xs.append(x); ys.append(y) }
        }
        guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else {
            throw AppError.message("The hinge glyph disappeared.")
        }
        return (minX, minY, maxX-minX+1, maxY-minY+1)
    }

    private static func variation(_ frame: Frame, rows: Range<Int>) -> Double {
        var total = 0, count = 0
        for y in rows { for x in (frame.width/4)..<(frame.width*3/4) {
            total += abs(frame.gray(x+1,y)-frame.gray(x,y)); count += 1
        } }
        return Double(total)/Double(count)
    }

    private static func edgeRamp(_ frame: Frame, horizontal: Bool) -> Int {
        let length = horizontal ? frame.width : frame.height
        let values = (0..<(length/3)).map { horizontal ? frame.gray($0,frame.height/2) : frame.gray(frame.width/2,$0) }
        return values.filter { $0 > 25 && $0 < 230 }.count
    }

    static func run() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw AppError.message("No Metal device.") }
        let renderer = try FoldRenderer(device: device)
        let args = CommandLine.arguments
        let path = args.firstIndex(of: "--render-check").flatMap { $0+1 < args.count ? args[$0+1] : nil } ?? "render-check"
        let output = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let input = try renderer.makePreviewTexture()
        let surface = try target(device, input.width, input.height)
        var checkpoints: [[String: Any]] = []
        var openPixels: [UInt8] = []
        for step in [0,25,50,75,100,0] {
            var u = FoldUniforms(); u.progress = Float(step)/100
            let frame = try render(renderer, input, surface, u)
            if step == 0 {
                if openPixels.isEmpty { openPixels = frame.pixels }
                else { try require(openPixels == frame.pixels, "Reopening changed the desktop.") }
            }
            if step == 100 {
                try require(stride(from: 0, to: frame.pixels.count, by: 4).allSatisfy {
                    frame.pixels[$0] == 0 && frame.pixels[$0+1] == 0 && frame.pixels[$0+2] == 0
                }, "Closed desktop did not disappear.")
            }
            try save(frame, output.appendingPathComponent("fold-\(step).png"))
            checkpoints.append(["progress": Double(step)/100, "gpuMilliseconds": frame.gpuMS])
        }

        // A small hinge glyph gives a measurable contract for the requested enlargement.
        let w = 960, h = 624
        let glyph = try fixture(device, width: w, height: h) { x,y in
            (x >= w*48/100 && x < w*52/100 && y >= h*88/100 && y < h*92/100) ? 0 : 255
        }
        let testTarget = try target(device,w,h)
        var sharp = FoldUniforms(); sharp.blur = 0; sharp.shadow = 0
        let original = try render(renderer,glyph,testTarget,sharp)
        var sourceBytes = [UInt8](repeating: 0, count: w*h*4)
        glyph.getBytes(&sourceBytes,bytesPerRow:w*4,from:MTLRegionMake2D(0,0,w,h),mipmapLevel:0)
        try require(original.pixels == sourceBytes, "Open output is not an exact pixel passthrough.")
        let initialBounds = try glyphBounds(original)
        var growth: [[String: Any]] = []
        for perspective: Float in [0,0.27165042,0.7,1] {
            var previous = initialBounds
            for p: Float in [0.25,0.5,0.75] {
                sharp.progress = p; sharp.perspective = perspective
                let frame = try render(renderer,glyph,testTarget,sharp), bounds = try glyphBounds(frame)
                try require(bounds.width >= previous.width && bounds.height >= previous.height && bounds.y <= previous.y,
                    "Content shrank or moved away from the hinge expansion.")
                if p == 0.75 {
                    try require(bounds.width > initialBounds.width && bounds.height > initialBounds.height, "Icons did not enlarge.")
                }
                previous = bounds
                growth.append(["progress":p,"perspective":perspective,"width":bounds.width,"height":bounds.height,"top":bounds.y])
            }
        }
        sharp.progress = 0.5; sharp.fadeOnly = 1
        let reduced = try render(renderer,glyph,testTarget,sharp)
        let expected = sourceBytes.enumerated().map { $0.offset%4 == 3 ? UInt8(255) : UInt8((Double($0.element)*0.5).rounded()) }
        try require(zip(reduced.pixels,expected).allSatisfy { abs(Int($0)-Int($1)) <= 1 }, "Reduce Motion changed geometry or did not fade.")

        let checker = try fixture(device,width:w,height:h) { x,y in ((x/10+y/10)%2 == 0) ? 40 : 240 }
        var optics = FoldUniforms(); optics.progress = 0.6; optics.shadow = 0; optics.blur = 0
        let unblurred = try render(renderer,checker,testTarget,optics)
        optics.blur = 0.65
        let blurred = try render(renderer,checker,testTarget,optics)
        let topRows = (h/5)..<(h*2/5), hingeRows = (h*4/5)..<(h*9/10)
        let topRatio = variation(blurred,rows:topRows)/variation(unblurred,rows:topRows)
        let hingeRatio = variation(blurred,rows:hingeRows)/variation(unblurred,rows:hingeRows)
        try require(topRatio < 0.25 && hingeRatio < 0.8 && topRatio < hingeRatio,
            "Defocus must soften both the top and hinge, with the top softer.")
        try save(blurred,output.appendingPathComponent("blur-checker.png"))

        // The user's 90-degree example must already soften content, then return
        // identical pixels when the shared stationary target becomes zero.
        var ninety = FoldUniforms()
        ninety.progress = Float(FoldMath.progress(angle:90,clearAngle:105))
        ninety.perspective = 0.27165042; ninety.shadow = 0; ninety.blur = 0
        let ninetySharp = try render(renderer,checker,testTarget,ninety)
        ninety.blur = 0.65
        let ninetyBlurred = try render(renderer,checker,testTarget,ninety)
        let ninetyRatio = variation(ninetyBlurred,rows:topRows)/variation(ninetySharp,rows:topRows)
        try require(ninetyRatio < 0.9, "90-degree live effect did not visibly soften the top content.")
        ninety.progress = 0
        let ninetyClear = try render(renderer,checker,testTarget,ninety)
        checker.getBytes(&sourceBytes,bytesPerRow:w*4,from:MTLRegionMake2D(0,0,w,h),mipmapLevel:0)
        try require(ninetyClear.pixels == sourceBytes, "Stationary 90-degree output retained blur.")

        let white = try fixture(device,width:w,height:h) { _,_ in 255 }
        let edges = try render(renderer,white,testTarget,optics)
        try require(edgeRamp(edges,horizontal:true) >= w*3/100 && edgeRamp(edges,horizontal:false) >= h*4/100,
            "The side or top fade is too narrow.")
        for x in 0..<w { try require(edges.gray(x,0) <= 8 && edges.gray(x,h-1) <= 8, "Hard top/bottom edge.") }
        for y in 0..<h { try require(edges.gray(0,y) <= 8 && edges.gray(w-1,y) <= 8, "Hard side edge.") }
        try save(edges,output.appendingPathComponent("edge-coverage.png"))
        let largerWhite = try fixture(device,width:w*2,height:h*2) { _,_ in 255 }
        let largerTarget = try target(device,w*2,h*2)
        let largerEdges = try render(renderer,largerWhite,largerTarget,optics)
        try require(abs(edgeRamp(largerEdges,horizontal:true)-2*edgeRamp(edges,horizontal:true)) <= 2,
            "Side falloff changed with Retina resolution.")

        // Three outstanding command buffers share the pyramid. Each must retain
        // its own input's color and return the same image when an angle repeats.
        let black = try fixture(device,width:w,height:h) { _,_ in 0 }
        let batchTargets = try (0..<3).map { _ in try target(device,w,h) }
        var commands: [MTLCommandBuffer] = []
        for (i,texture) in [white,black,white].enumerated() {
            commands.append(try encode(renderer,texture,batchTargets[i],optics,revision:UInt64(i+1)))
        }
        let batch = try commands.enumerated().map { try read(batchTargets[$0.offset],$0.element) }
        try require(batch[0].pixels == batch[2].pixels && batch[1].gray(w/2,h/2) == 0 && batch[0].gray(w/2,h/2) == 255,
            "Blur levels retained another frame or changed after reversal.")

        let cacheReference = try render(renderer,checker,testTarget,optics)
        let builds = renderer.blurBuildCount
        let firstCached = try render(renderer,checker,testTarget,optics,revision:1000)
        let nextCached = try render(renderer,checker,testTarget,optics,revision:1000)
        try require(cacheReference.pixels == firstCached.pixels && firstCached.pixels == nextCached.pixels,
            "Cached blur changed the rendered pixels.")
        try require(renderer.blurBuildCount == builds+1, "An unchanged frame rebuilt its blur pyramid.")
        // A recycled buffer can retain its identity while its content changes.
        let pooled = try fixture(device,width:w,height:h) { _,_ in 255 }
        let beforeReuse = try render(renderer,pooled,testTarget,optics,revision:1001)
        var changedPixels = [UInt8](repeating:0,count:w*h*4)
        for i in stride(from:3,to:changedPixels.count,by:4) { changedPixels[i] = 255 }
        pooled.replace(region:MTLRegionMake2D(0,0,w,h),mipmapLevel:0,withBytes:changedPixels,bytesPerRow:w*4)
        let afterReuse = try render(renderer,pooled,testTarget,optics,revision:1002)
        try require(beforeReuse.gray(w/2,h/2) == 255 && afterReuse.gray(w/2,h/2) == 0,
            "Recycled source retained stale blur pixels.")

        // Both input AND output are native size, including pyramid rebuild cost.
        let nativeInput = try renderer.makePreviewTexture(width:3024,height:1964)
        let nativeTarget = try target(device,3024,1964,shared:false)
        var times: [Double] = []
        for i in 0..<100 {
            var u = FoldUniforms(); u.progress = 0.02+Float(i%40)/41
            let command = try encode(renderer,nativeInput,nativeTarget,u)
            command.waitUntilCompleted()
            try require(command.status == .completed, "Native render failed.")
            if i >= 10 { times.append((command.gpuEndTime-command.gpuStartTime)*1000) }
        }
        times.sort()
        let p95 = times[Int(Double(times.count)*0.95)]
        try require(p95 < 6, "Native GPU p95 exceeded the 6 ms rendering budget.")
        var cachedTimes: [Double] = []
        let beforeCachedBenchmark = renderer.blurBuildCount
        for i in 0..<100 {
            var u = FoldUniforms(); u.progress = 0.02+Float(i%40)/41
            let command = try encode(renderer,nativeInput,nativeTarget,u,revision:2000)
            command.waitUntilCompleted()
            try require(command.status == .completed, "Cached native render failed.")
            if i >= 10 { cachedTimes.append((command.gpuEndTime-command.gpuStartTime)*1000) }
        }
        cachedTimes.sort()
        try require(renderer.blurBuildCount == beforeCachedBenchmark+1, "Static native frames rebuilt the blur.")
        let report: [String: Any] = ["version":"0.1.4","gpu":device.name,"frameChecks":checkpoints,
            "pixelIdentityAndReopen":true,"opaqueAndClosedBlack":true,"reduceMotion":true,"enlargement":growth,
            "topContrastRatio":topRatio,"hingeContrastRatio":hingeRatio,
            "ninetyDegreeTopContrastRatio":ninetyRatio,"stationaryNinetyDegreesExactPixels":true,
            "cachedBlurPixelIdentity":true,"recycledSourceFreshness":true,"staticFramesBuildPyramidOnce":true,
            "cachedNativeGPUTimeMedianMS":cachedTimes[cachedTimes.count/2],
            "cachedNativeGPUTimeP95MS":cachedTimes[Int(Double(cachedTimes.count)*0.95)],
            "sideFadePixels":edgeRamp(edges,horizontal:true),"topFadePixels":edgeRamp(edges,horizontal:false),
            "resolutionIndependentEdges":true,"threeInFlightFrames":true,
            "nativeInputAndOutput":"3024 × 1964","nativeGPUTimeMedianMS":times[times.count/2],"nativeGPUTimeP95MS":p95,
            "note":"Includes blur pyramid and final pass. GPU-only timing excludes capture, window composition, display refresh, and physical lid movement."]
        let json = try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys])
        try json.write(to:output.appendingPathComponent("render-check.json"))
        print(String(data:json,encoding:.utf8)!)

        if args.contains("--animation") {
            let directory = output.appendingPathComponent("animation")
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            let animatedTarget = try target(device,960,624)
            for frame in 0..<180 {
                var u = FoldUniforms(); u.progress = Float(pow(sin(Double(frame)/179 * .pi),2))
                try save(render(renderer,input,animatedTarget,u),directory.appendingPathComponent(String(format:"frame-%03d.png",frame)))
            }
        }
    }
}
