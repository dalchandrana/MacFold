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

    private static func meanAbsDiff(_ a: Frame, _ b: Frame) -> Double {
        var total = 0.0
        for i in stride(from: 0, to: a.pixels.count, by: 4) { total += abs(Double(a.pixels[i])-Double(b.pixels[i])) }
        return total/Double(a.pixels.count/4)
    }

    private static func rowMean(_ f: Frame, _ y: Int, _ x: Range<Int>? = nil) -> Double {
        let span = x ?? 0..<f.width
        return Double(span.reduce(0) { $0+f.gray($1,y) })/Double(span.count)
    }

    private static func topLit(_ f: Frame, x: Int, threshold: Int = 24) -> Int {
        for y in 0..<f.height where f.gray(x,y) > threshold { return y }
        return f.height
    }

    private static func litCount(_ f: Frame, row y: Int, threshold: Int = 24) -> Int {
        (0..<f.width).reduce(0) { $0+(f.gray($1,y) > threshold ? 1 : 0) }
    }

    private static func brightCount(_ f: Frame, _ threshold: Int) -> Int {
        stride(from: 0, to: f.pixels.count, by: 4).reduce(0) { $0+(Int(f.pixels[$1]) > threshold ? 1 : 0) }
    }

    private static func brightCentroid(_ f: Frame, _ threshold: Int) -> (x: Double, y: Double, count: Int) {
        var sx = 0.0, sy = 0.0, n = 0
        for y in 0..<f.height { for x in 0..<f.width where f.gray(x,y) > threshold {
            sx += Double(x); sy += Double(y); n += 1
        } }
        return (n == 0 ? 0 : sx/Double(n), n == 0 ? 0 : sy/Double(n), n)
    }

    /// Row index of a height fraction measured up from the hinge.
    private static func row(_ height: Double, _ h: Int) -> Int {
        min(h-1, max(0, Int((1-height)*Double(h))))
    }

    /// Bands of rows whose mean exceeds a level, collapsed to their centres.
    private static func brightRows(_ f: Frame, above level: Double, rows: Range<Int>,
                                   columns: Range<Int>? = nil) -> [Int] {
        var groups: [[Int]] = []
        for y in rows {
            guard rowMean(f,y,columns) > level else { continue }
            if let last = groups.last?.last, y == last+1 { groups[groups.count-1].append(y) } else { groups.append([y]) }
        }
        return groups.map { $0.reduce(0,+)/$0.count }
    }

    /// True when a rectangle of the output still holds the source rectangle,
    /// optionally shifted down by a whole number of rows.
    private static func identical(_ f: Frame, _ source: [UInt8], rows: Range<Int>,
                                  columns: Range<Int>, shiftedBy: Int = 0) -> Bool {
        for y in rows {
            let from = y-shiftedBy
            if from < 0 || from >= f.height { return false }
            for x in columns {
                let a = (y*f.width+x)*4, b = (from*f.width+x)*4
                for channel in 0..<4 where f.pixels[a+channel] != source[b+channel] { return false }
            }
        }
        return true
    }

    /// Screen pixel for a polar sample around the iris centre, in height units.
    private static func irisPoint(_ radius: Double, _ angle: Double, _ f: Frame) -> (Int, Int)? {
        let aspect = Double(f.width)/Double(f.height)
        let uvx = 0.5+radius*cos(angle)/aspect, height = 0.14+radius*sin(angle)
        let x = Int(uvx*Double(f.width)), y = Int((1-height)*Double(f.height))
        guard x >= 0, x < f.width, y >= 0, y < f.height else { return nil }
        return (x,y)
    }

    private static func edgeRamp(_ frame: Frame, horizontal: Bool) -> Int {
        let length = horizontal ? frame.width : frame.height
        let values = (0..<(length/3)).map { horizontal ? frame.gray($0,frame.height/2) : frame.gray(frame.width/2,$0) }
        return values.filter { $0 > 25 && $0 < 230 }.count
    }

    /// Every effect: exact open, exact reopen, opaque black at closure, the shared
    /// Reduce Motion fade, a distinctive intermediate frame, deterministic reversal
    /// and reuse of a cached pyramid. Generated fixtures only.
    private static func checkEffects(_ device: MTLDevice, _ renderer: FoldRenderer,
                                     _ art: MTLTexture, _ output: URL) throws -> [String: Any] {
        let W = 960, H = 624
        let plate = try target(device,W,H)
        let artPlate = try target(device,art.width,art.height)
        let checker = try fixture(device,width:W,height:H) { x,y in ((x/10+y/10)%2 == 0) ? 40 : 240 }
        var checkerBytes = [UInt8](repeating:0,count:W*H*4)
        checker.getBytes(&checkerBytes,bytesPerRow:W*4,from:MTLRegionMake2D(0,0,W,H),mipmapLevel:0)

        var report: [String: Any] = [:]
        var middles: [FoldEffect: Frame] = [:]
        for effect in FoldEffect.allCases {
            var u = FoldUniforms(); u.effect = effect.shaderIndex
            let open = try render(renderer,checker,plate,u)
            try require(open.pixels == checkerBytes,"\(effect.title): the open desktop is not an exact passthrough.")
            if effect != .duo {
                // Opening/clearing must not abruptly remove a shadow or seam at
                // the exact-zero branch. A tiny angle change stays visually tiny.
                u.progress = 0.001
                let onset = try render(renderer,checker,plate,u)
                let maximumJump = zip(onset.pixels,checkerBytes).map { abs(Int($0)-Int($1)) }.max() ?? 0
                try require(maximumJump <= 1,"\(effect.title): near-open transition jumps by \(maximumJump) channel levels.")
                report["\(effect.rawValue)NearOpenMaximumChannelJump"] = maximumJump
            }
            u.progress = 1
            let closed = try render(renderer,checker,plate,u)
            try require(stride(from:0,to:closed.pixels.count,by:4).allSatisfy {
                closed.pixels[$0] == 0 && closed.pixels[$0+1] == 0 && closed.pixels[$0+2] == 0
            },"\(effect.title): the closed lid did not black out.")
            u.progress = 0
            let reopened = try render(renderer,checker,plate,u)
            try require(reopened.pixels == checkerBytes,"\(effect.title): reopening changed the desktop.")
            u.progress = 0.5; u.fadeOnly = 1
            let reduced = try render(renderer,checker,plate,u)
            let halved = checkerBytes.enumerated().map { $0.offset%4 == 3 ? UInt8(255) : UInt8((Double($0.element)*0.5).rounded()) }
            try require(zip(reduced.pixels,halved).allSatisfy { abs(Int($0)-Int($1)) <= 1 },
                "\(effect.title): Reduce Motion did not take the shared fade.")
            u.fadeOnly = 0

            // Ascending then descending through the same angles must repeat exactly,
            // including when the descent reuses a cached blur pyramid.
            var ascending: [[UInt8]] = []
            let steps: [Float] = [0.1,0.25,0.4,0.55,0.7,0.85]
            for step in steps { u.progress = step; ascending.append(try render(renderer,checker,plate,u).pixels) }
            for (index,step) in steps.enumerated().reversed() {
                u.progress = step
                let descending = try render(renderer,checker,plate,u,revision:4000)
                try require(descending.pixels == ascending[index],
                    "\(effect.title): closing and opening did not reverse identically.")
            }
            let builds = renderer.blurBuildCount
            u.progress = 0.5
            let cached = try render(renderer,checker,plate,u,revision:4100)
            let reused = try render(renderer,checker,plate,u,revision:4100)
            try require(reused.pixels == cached.pixels,
                "\(effect.title): a cached pyramid changed the rendered pixels.")
            try require(renderer.blurBuildCount == builds+1,"\(effect.title): an unchanged frame rebuilt its blur pyramid.")

            var a = FoldUniforms(); a.effect = effect.shaderIndex
            for step in [0,25,50,75,100] {
                a.progress = Float(step)/100
                let frame = try render(renderer,art,artPlate,a)
                try save(frame,output.appendingPathComponent("effect-\(effect.rawValue)-\(step).png"))
                if step == 50 { middles[effect] = frame }
            }
            report["\(effect.rawValue)ExactOpenReopenClosedAndReduceMotion"] = true
        }

        // Each effect must look like itself, not like a relabelled neighbour.
        var separation: [String: Double] = [:]
        var worst = 255.0
        for (i,left) in FoldEffect.allCases.enumerated() {
            for right in FoldEffect.allCases.dropFirst(i+1) {
                let difference = meanAbsDiff(middles[left]!,middles[right]!)
                separation["\(left.rawValue)-\(right.rawValue)"] = difference
                worst = min(worst,difference)
            }
        }
        try require(worst >= 6,"Two effects render nearly the same intermediate frame.")
        report["intermediateSeparationMeanChannelDifference"] = separation
        report["smallestIntermediateSeparation"] = worst
        try report.merge(checkRoll(device,renderer,plate,W,H)) { a,_ in a }
        try report.merge(checkShutter(device,renderer,plate,W,H)) { a,_ in a }
        try report.merge(checkFlex(device,renderer,plate,W,H)) { a,_ in a }
        try report.merge(checkIris(device,renderer,plate,W,H)) { a,_ in a }
        return report
    }

    /// Roll: the sheet below the descending cylinder stays exactly the desktop,
    /// material from above the flat region is wrapped onto the roll, the curved
    /// surface carries an interior highlight, and the roll drops a contact shadow.
    private static func checkRoll(_ device: MTLDevice, _ renderer: FoldRenderer,
                                  _ plate: MTLTexture, _ W: Int, _ H: Int) throws -> [String: Any] {
        var u = FoldUniforms(); u.effect = FoldEffect.roll.shaderIndex
        u.blur = 0; u.shadow = 0; u.progress = 0.35
        // A bright band near the top of the image, which only a wrap can bring down.
        let marked = try fixture(device,width:W,height:H) { _,y in
            let height = 1-(Double(y)+0.5)/Double(H)
            return (height >= 0.955 && height <= 0.975) ? 250 : 60
        }
        var markedBytes = [UInt8](repeating:0,count:W*H*4)
        marked.getBytes(&markedBytes,bytesPerRow:W*4,from:MTLRegionMake2D(0,0,W,H),mipmapLevel:0)
        let wrapped = try render(renderer,marked,plate,u)
        let flatFrom = row(0.55,H)
        try require(identical(wrapped,markedBytes,rows:flatFrom..<H,columns:0..<W),
            "Roll: the flat sheet below the roll is not the exact desktop.")
        let sourceBand = brightRows(wrapped,above:150,rows:0..<flatFrom)
        try require(sourceBand.count == 1,"Roll: the wrapped band did not appear exactly once on the roll.")
        try require(sourceBand[0] >= row(0.70,H) && sourceBand[0] <= row(0.55,H),
            "Roll: image content from the top edge did not land on the descending roll.")
        try require(topLit(wrapped,x:W/2) >= row(0.80,H),"Roll: content stayed above the roll.")

        let gradient = try fixture(device,width:W,height:H) { _,y in
            let height: Double = 1-(Double(y)+0.5)/Double(H)
            let value: Int = Int(255*height)
            return UInt8(max(0,min(255,value)))
        }
        let ramp = try render(renderer,gradient,plate,u)
        let rollBand = (row(0.72,H)...row(0.60,H)).map { rowMean(ramp,$0) }
        let rollMean = rollBand.reduce(0,+)/Double(rollBand.count)
        let flatTop = rowMean(ramp,row(0.55,H))
        try require(rollMean >= flatTop+30,
            "Roll: the roll does not carry image content from above the flat sheet.")

        u.shadow = 1
        let plain = try fixture(device,width:W,height:H) { _,_ in 128 }
        let lit = try render(renderer,plain,plate,u)
        let band = Array(row(0.727,H)...row(0.585,H))
        let profile = band.map { rowMean(lit,$0) }
        let peak = profile.max()!
        let peakIndex = profile.firstIndex(of:peak)!
        try require(peak > 140,"Roll: the curved highlight is not brighter than the material.")
        try require(peakIndex >= 4 && peakIndex <= profile.count-5,
            "Roll: the highlight sits on the silhouette instead of on the curve.")
        try require(profile.first! < peak*0.85 && profile.last! < peak*0.85,
            "Roll: the roll is not shaded from its top edge to its underside.")
        let contact = [row(0.565,H),row(0.50,H),row(0.30,H)].map { rowMean(lit,$0) }
        try require(contact[0] < 90 && contact[1] > contact[0]+15 && contact[2] > 124,
            "Roll: the roll does not drop a contact shadow that fades away from it.")

        var descent: [Int] = []
        for step: Float in [0.1,0.2,0.3,0.4,0.5,0.6,0.7,0.8] {
            u.progress = step; u.shadow = 0.65
            descent.append(topLit(try render(renderer,plain,plate,u),x:W/2))
        }
        try require(zip(descent,descent.dropFirst()).allSatisfy { $1 > $0+4 },
            "Roll: the roll does not travel down toward the hinge.")
        return ["rollFlatSheetExactRowsFrom":flatFrom,"rollWrappedBandRow":sourceBand[0],
                "rollHighlightPeak":peak,"rollContactShadowProfile":contact,
                "rollTopOfImageByProgress":descent]
    }

    /// Shutter: four broad panels, each an exact rigid translation of its own band
    /// of desktop pixels, overlapping with lit rims and contact shadows.
    private static func checkShutter(_ device: MTLDevice, _ renderer: FoldRenderer,
                                     _ plate: MTLTexture, _ W: Int, _ H: Int) throws -> [String: Any] {
        let levels = [60,100,140,180]
        let bands = try fixture(device,width:W,height:H) { x,y in
            let up = H-1-y, band = min(3,up*4/H)
            var value = levels[band]
            if up%12 < 6 { value -= 26 }
            if x%24 < 12 { value += 12 }
            if x >= W*30/100 && x < W*36/100 && up >= H*16/100 && up < H*21/100 { value = 250 }
            return UInt8(max(0,min(255,value)))
        }
        var bandBytes = [UInt8](repeating:0,count:W*H*4)
        bands.getBytes(&bandBytes,bytesPerRow:W*4,from:MTLRegionMake2D(0,0,W,H),mipmapLevel:0)
        var u = FoldUniforms(); u.effect = FoldEffect.shutter.shaderIndex
        u.blur = 0; u.shadow = 0; u.perspective = 0; u.progress = 0.25
        let telescoped = try render(renderer,bands,plate,u)
        // At a quarter closed each panel has dropped an exact number of rows.
        var slabs: [[String: Int]] = []
        for j in 0..<4 {
            let drop = 39*(j+1)
            let top = Int(0.1875*Double(j+1)*Double(H)), bottom = Int(0.1875*Double(j)*Double(H))
            let rows = (H-top+4)..<(H-bottom-4)
            try require(identical(telescoped,bandBytes,rows:rows,columns:4..<(W-4),shiftedBy:drop),
                "Shutter: panel \(j) is not an exact rigid translation of its own band.")
            slabs.append(["panel":j,"droppedRows":drop,"firstRow":rows.lowerBound,"lastRow":rows.upperBound-1])
        }
        try require((0..<row(0.76,H)).allSatisfy { rowMean(telescoped,$0) < 2 },
            "Shutter: something is still drawn above the retracted stack.")
        // The marker inside the bottom panel keeps its exact size while it drops.
        func markerBox(_ f: Frame) -> (x: Int, y: Int, width: Int, height: Int)? {
            var xs: [Int] = [], ys: [Int] = []
            for y in (H/2)..<H { for x in 0..<W where f.gray(x,y) > 220 { xs.append(x); ys.append(y) } }
            guard let x0 = xs.min(), let x1 = xs.max(), let y0 = ys.min(), let y1 = ys.max() else { return nil }
            return (x0,y0,x1-x0+1,y1-y0+1)
        }
        u.progress = 0
        guard let restBox = markerBox(try render(renderer,bands,plate,u)) else {
            throw AppError.message("Shutter: the rigid-geometry marker is missing when open.")
        }
        var rigid: [[String: Int]] = []
        for step: Float in [0.25,0.5] {
            u.progress = step
            guard let box = markerBox(try render(renderer,bands,plate,u)) else {
                throw AppError.message("Shutter: the marker disappeared from the front panel.")
            }
            try require(abs(box.width-restBox.width) <= 1 && abs(box.height-restBox.height) <= 1 && box.x == restBox.x,
                "Shutter: panel pixels were scaled instead of translated.")
            try require(box.y > restBox.y+8,"Shutter: the front panel did not telescope toward the hinge.")
            rigid.append(["progress":Int(step*100),"x":box.x,"y":box.y,"width":box.width,"height":box.height])
        }
        // Rims and contact shadows at each overlap, on flat mid-grey.
        let plain = try fixture(device,width:W,height:H) { _,_ in 128 }
        u.progress = 0.5; u.shadow = 1; u.blur = 0.4
        let relief = try render(renderer,plain,plate,u)
        var seams: [[String: Double]] = []
        for seam in 1...3 {
            // Measured against each panel's own material, so the rim and the
            // contact shadow are separated from the depth dimming behind the stack.
            let y = H-Int(0.125*Double(seam)*Double(H))
            let rim = rowMean(relief,y+2), front = rowMean(relief,y+14)
            let shade = rowMean(relief,y-4), behind = rowMean(relief,y-14)
            try require(rim >= front+8,"Shutter: the rim of the panel at seam \(seam) is not lit.")
            try require(behind >= shade+12,"Shutter: no contact shadow above the panel at seam \(seam).")
            seams.append(["seamRow":Double(y),"rimMean":rim,"panelMean":front,
                          "shadowMean":shade,"panelBehindMean":behind])
        }
        return ["shutterRigidPanelRows":slabs,"shutterMarkerGeometry":rigid,"shutterSeams":seams]
    }

    /// Flex: one sheet, curved top and side silhouette, a continuous non-affine
    /// squeeze toward the tipped-back top edge, a reflection band and a late collapse.
    private static func checkFlex(_ device: MTLDevice, _ renderer: FoldRenderer,
                                  _ plate: MTLTexture, _ W: Int, _ H: Int) throws -> [String: Any] {
        var u = FoldUniforms(); u.effect = FoldEffect.flex.shaderIndex
        u.blur = 0; u.shadow = 0; u.progress = 0.5
        let plain = try fixture(device,width:W,height:H) { _,_ in 200 }
        let sheet = try render(renderer,plain,plate,u)
        let middle = topLit(sheet,x:W/2), left = topLit(sheet,x:W/10), right = topLit(sheet,x:W*9/10)
        try require(left > middle+5 && right > middle+5,"Flex: the top silhouette is not curved.")
        let high = litCount(sheet,row:row(0.70,H)), low = litCount(sheet,row:row(0.10,H))
        try require(Double(high) < Double(low)*0.97,"Flex: the side silhouette does not draw in toward the top.")

        // Marker lines from the source must crowd together toward the top edge.
        let ruled = try fixture(device,width:W,height:H) { _,y in
            let height = 1-(Double(y)+0.5)/Double(H)
            for line in [0.25,0.5,0.75] where abs(height-line) < 0.004 { return 240 }
            return 40
        }
        let deformed = try render(renderer,ruled,plate,u)
        // Sampled down the centre line: the dome silhouette curves the interior
        // rows as well, which is the point of the effect.
        let lines = brightRows(deformed,above:130,rows:0..<H,columns:(W/2-40)..<(W/2+40))
        try require(lines.count == 3,"Flex: expected three continuous source lines, measured \(lines).")
        let gaps = [H-1-lines[2],lines[2]-lines[1],lines[1]-lines[0]]
        try require(gaps[0] > gaps[1]+8 && gaps[1] > gaps[2]+8,
            "Flex: the vertical deformation is not a continuous squeeze toward the top.")

        u.shadow = 1
        let shaded = try render(renderer,plain,plate,u)
        let profileRow = row(0.36,H)
        let lit = (0..<W).filter { shaded.gray($0,profileRow) > 24 }
        let peakX = lit.max { shaded.gray($0,profileRow) < shaded.gray($1,profileRow) }!
        try require(peakX < W*35/100,"Flex: the reflection band is not placed by the surface normal.")
        try require(shaded.gray(peakX,profileRow) >= shaded.gray(W*85/100,profileRow)+8,
            "Flex: no reflection or depth shading across the bow.")

        u.shadow = 0.65; u.progress = 0.75
        let early = H-topLit(try render(renderer,plain,plate,u),x:W/2)
        u.progress = 0.95
        let late = H-topLit(try render(renderer,plain,plate,u),x:W/2)
        try require(Double(late) < Double(early)*0.4,"Flex: the sheet does not collapse toward the hinge.")
        return ["flexTopSilhouetteRows":["centre":middle,"left":left,"right":right],
                "flexLitWidthTopVersusHinge":[high,low],"flexSourceLineRows":lines,"flexLineGaps":gaps,
                "flexReflectionPeakColumn":peakX,"flexLitHeightAt75And95":[early,late]]
    }

    /// Iris: the desktop stays exactly where it is inside the aperture, dark blades
    /// overlap with seams and contact shadows, the aperture sits above the hinge,
    /// it closes monotonically, and the blades themselves go black at closure.
    private static func checkIris(_ device: MTLDevice, _ renderer: FoldRenderer,
                                 _ plate: MTLTexture, _ W: Int, _ H: Int) throws -> [String: Any] {
        let checker = try fixture(device,width:W,height:H) { x,y in ((x/10+y/10)%2 == 0) ? 40 : 240 }
        var checkerBytes = [UInt8](repeating:0,count:W*H*4)
        checker.getBytes(&checkerBytes,bytesPerRow:W*4,from:MTLRegionMake2D(0,0,W,H),mipmapLevel:0)
        var u = FoldUniforms(); u.effect = FoldEffect.iris.shaderIndex
        u.blur = 0; u.shadow = 0; u.progress = 0.35
        let closing = try render(renderer,checker,plate,u)
        let aspect = Double(W)/Double(H)
        let columns = Int(0.227*Double(W)), centreX = W/2, centreRow = row(0.14,H)
        let box = (x: centreX-columns, y: max(0,centreRow-Int(0.35*Double(H))))
        try require(identical(closing,checkerBytes,rows:box.y..<H,columns:box.x..<(centreX+columns)),
            "Iris: the desktop inside the aperture moved or was reshaded.")

        let white = try fixture(device,width:W,height:H) { _,_ in 255 }
        u.shadow = 1; u.blur = 0.3; u.progress = 0.55
        let blades = try render(renderer,white,plate,u)
        let corner = (0..<(H/6)).flatMap { y in (0..<(W/6)).map { blades.gray($0,y) } }
        try require(Double(corner.reduce(0,+))/Double(corner.count) < 60,
            "Iris: the blades are not dark, precision blades.")
        // Seams around the closed part of the aperture, and the polygon's own facets.
        var arc: [Int] = []
        for degrees in stride(from:-14,through:194,by:1) {
            guard let point = irisPoint(0.56,Double(degrees)*Double.pi/180,blades) else { continue }
            arc.append(blades.gray(point.0,point.1))
        }
        let seams = zip(arc,arc.dropFirst()).reduce(0) { $0+(abs($1.0-$1.1) > 3 ? 1 : 0) }
        try require(seams >= 3,"Iris: the blades do not overlap with visible seams.")
        var boundary: [Double] = []
        for degrees in stride(from:20,through:160,by:2) {
            let angle = Double(degrees)*Double.pi/180
            var edge = 1.2
            for step in stride(from:0.06,through:1.2,by:0.004) {
                guard let point = irisPoint(step,angle,blades) else { break }
                if blades.gray(point.0,point.1) < 100 { edge = step; break }
            }
            boundary.append(edge)
        }
        let facets = (1..<(boundary.count-1)).reduce(0) {
            $0+((boundary[$1] < boundary[$1-1] && boundary[$1] <= boundary[$1+1]) ? 1 : 0)
        }
        try require(facets >= 2,"Iris: the aperture is not bounded by straight blade edges.")

        func facetAngle(_ progress: Float) throws -> Double {
            var v = FoldUniforms(); v.effect = FoldEffect.iris.shaderIndex
            v.blur = 0; v.shadow = 1; v.progress = progress
            let frame = try render(renderer,white,plate,v)
            var best = (angle: 0.0, radius: 9.9)
            for degrees in stride(from:70,through:130,by:1) {
                let angle = Double(degrees)*Double.pi/180
                for step in stride(from:0.04,through:1.2,by:0.002) {
                    guard let point = irisPoint(step,angle,frame) else { break }
                    if frame.gray(point.0,point.1) < 100 {
                        if step < best.radius { best = (Double(degrees),step) }
                        break
                    }
                }
            }
            return best.angle
        }
        let early = try facetAngle(0.4), later = try facetAngle(0.8)
        let twist = later-early
        try require(twist >= 3 && twist <= 12,"Iris: the blades do not twist as they close.")

        var closingCounts: [Int] = []
        for step: Float in [0.2,0.35,0.5,0.65,0.8] {
            u.progress = step
            closingCounts.append(brightCount(try render(renderer,white,plate,u),128))
        }
        try require(zip(closingCounts,closingCounts.dropFirst()).allSatisfy { $1 < $0 },
            "Iris: the aperture does not close monotonically.")
        u.progress = 0.7
        let placed = try render(renderer,white,plate,u)
        let centroid = brightCentroid(placed,128)
        try require(centroid.count > 0 && centroid.y > Double(H)*0.72 && abs(centroid.x-Double(W)/2) < Double(W)*0.03,
            "Iris: the aperture is not centred just above the hinge.")
        u.progress = 0.98
        let shut = try render(renderer,white,plate,u)
        var bladeMax = 0
        for y in 0..<H { for x in 0..<W {
            let dx = (Double(x)/Double(W)-0.5)*aspect, dy = 1-(Double(y)+0.5)/Double(H)-0.14
            if (dx*dx+dy*dy).squareRoot() > 0.06 { bladeMax = max(bladeMax,shut.gray(x,y)) }
        } }
        try require(bladeMax <= 12,"Iris: the blades are still visible at complete closure.")
        try require(brightCount(shut,100) < W*H/1500,"Iris: too much of the desktop survives at closure.")
        return ["irisFixedDesktopBox":["x":box.x,"y":box.y,"width":columns*2,"height":H-box.y],
                "irisSeamSteps":seams,"irisApertureFacets":facets,"irisTwistDegrees":twist,
                "irisApertureAreaByProgress":closingCounts,
                "irisApertureCentroid":["x":centroid.x,"y":centroid.y],
                "irisBladeMaximumAtClosure":bladeMax]
    }

    /// Native-resolution cost for every effect, worst case: a new source frame
    /// rebuilds the pyramid on each render. GPU-only timings.
    private static func benchmarkEffects(_ device: MTLDevice, _ renderer: FoldRenderer,
                                         _ source: MTLTexture, _ destination: MTLTexture) throws -> [String: Any] {
        var results: [String: Any] = [:]
        for effect in FoldEffect.allCases {
            var times: [Double] = []
            for i in 0..<60 {
                var u = FoldUniforms(); u.effect = effect.shaderIndex
                u.progress = 0.04+Float(i%24)/25
                let command = try encode(renderer,source,destination,u)
                command.waitUntilCompleted()
                try require(command.status == .completed,"\(effect.title): native render failed.")
                if i >= 10 { times.append((command.gpuEndTime-command.gpuStartTime)*1000) }
            }
            times.sort()
            let p95 = times[Int(Double(times.count)*0.95)]
            try require(p95 < 6,"\(effect.title): native GPU p95 exceeded the 6 ms rendering budget.")
            results[effect.rawValue] = ["medianMS":times[times.count/2],"p95MS":p95]
        }
        return results
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

        let effects = try checkEffects(device,renderer,input,output)

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
        let effectTimes = try benchmarkEffects(device,renderer,nativeInput,nativeTarget)
        let report: [String: Any] = ["version":"0.1.5","gpu":device.name,"frameChecks":checkpoints,
            "effectCatalog":FoldEffect.allCases.map { ["id":$0.persistedIdentifier,"shaderIndex":Int($0.shaderIndex),
                "title":$0.title,"prefiltersSource":$0.needsPrefilteredSource] },
            "effectChecks":effects,"effectNativeGPUTimes":effectTimes,
            "effectNativeInputAndOutput":"3024 × 1964 for all five effects",
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
            let animatedTarget = try target(device,960,624)
            for effect in FoldEffect.allCases {
                let directory = output.appendingPathComponent("animation/\(effect.rawValue)")
                try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
                for frame in 0..<180 {
                    var u = FoldUniforms(); u.effect = effect.shaderIndex
                    u.progress = Float(pow(sin(Double(frame)/179 * .pi),2))
                    try save(render(renderer,input,animatedTarget,u),directory.appendingPathComponent(String(format:"frame-%03d.png",frame)))
                }
            }
        }
    }
}
