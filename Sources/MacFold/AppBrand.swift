import AppKit

@MainActor enum AppBrand {
    static let mark: NSImage = {
        let candidateURLs = [
            Bundle.main.url(forResource: "MacFoldMark", withExtension: "png"),
            Bundle.main.url(forResource: "mark", withExtension: "png"),
            Bundle.main.url(forResource: "Logo", withExtension: "png"),
            Bundle.main.url(forResource: "MacDuoMark", withExtension: "png")
        ].compactMap { $0 }
        for url in candidateURLs {
            if let image = NSImage(contentsOf: url) { return image }
        }
        for fallbackPath in ["Resources/MacFoldMark.png", "docs/assets/mark.png", "docs/assets/Logo.png"] {
            if let image = NSImage(contentsOfFile: fallbackPath) { return image }
        }
        return NSImage(systemSymbolName: "macbook", accessibilityDescription: "Mac Fold") ?? NSImage()
    }()

    private static let _menuBarMark: NSImage = {
        guard let tiff = mark.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let cgImage = rep.cgImage else {
            let fallback = NSImage(systemSymbolName: "macbook", accessibilityDescription: "Mac Fold") ?? NSImage()
            fallback.isTemplate = true
            return fallback
        }
        let width = cgImage.width
        let height = cgImage.height
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        var rawData = [UInt8](repeating: 0, count: height * width * 4)
        guard let ctx = CGContext(
            data: &rawData,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ) else {
            let image = mark.copy() as! NSImage
            image.size = NSSize(width: 22, height: 22)
            image.isTemplate = true
            return image
        }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        for i in stride(from: 0, to: rawData.count, by: 4) {
            let r = rawData[i]
            let g = rawData[i+1]
            let b = rawData[i+2]
            if r < 20 && g < 20 && b < 20 {
                rawData[i] = 0; rawData[i+1] = 0; rawData[i+2] = 0; rawData[i+3] = 0
            } else {
                let brightness = (UInt32(r) + UInt32(g) + UInt32(b)) / 3
                rawData[i] = 0; rawData[i+1] = 0; rawData[i+2] = 0
                rawData[i+3] = UInt8(min(255, max(0, brightness)))
            }
        }
        guard let maskCG = ctx.makeImage() else {
            let image = mark.copy() as! NSImage
            image.size = NSSize(width: 22, height: 22)
            image.isTemplate = true
            return image
        }
        let templateImage = NSImage(cgImage: maskCG, size: NSSize(width: 22, height: 22))
        templateImage.isTemplate = true
        templateImage.accessibilityDescription = "Mac Fold"
        return templateImage
    }()

    static var menuBarMark: NSImage { _menuBarMark }
}
