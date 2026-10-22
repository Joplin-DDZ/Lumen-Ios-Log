import AppKit

// 使用矢量形状生成全部图标尺寸，避免额外图像库依赖。
let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
let sizes = [16, 32, 128, 256, 512]
for size in sizes {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let context = NSGraphicsContext(bitmapImageRep: bitmap)!
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
        let shape = NSBezierPath(roundedRect: NSRect(x: 40, y: 40, width: 944, height: 944), xRadius: 215, yRadius: 215)
        NSGradient(starting: NSColor(srgbRed: 0.0, green: 0.36, blue: 0.86, alpha: 1), ending: NSColor(srgbRed: 0.15, green: 0.67, blue: 1, alpha: 1))!.draw(in: shape, angle: 65)
        let heights: [CGFloat] = [95, 195, 335, 465, 335, 195, 95]
        for (index, height) in heights.enumerated() {
            NSColor.white.withAlphaComponent(0.96).setFill()
            NSBezierPath(roundedRect: NSRect(x: 250 + CGFloat(index) * 80, y: (1024 - height) / 2, width: 46, height: height), xRadius: 23, yRadius: 23).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        try bitmap.representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent(name))
    }
}
