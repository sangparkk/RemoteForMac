import AppKit

// Deterministic, vector-drawn artwork shared by the native apps and the web app.
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
func render(_ size: Int, mac: Bool = false) -> Data {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let transform = AffineTransform(scale: CGFloat(size) / 1024)
    (transform as NSAffineTransform).concat()
    func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ radius: CGFloat, _ color: NSColor) {
        color.setFill()
        NSBezierPath(roundedRect: NSRect(x: x, y: y, width: w, height: h), xRadius: radius, yRadius: radius).fill()
    }
    let navy = NSColor(srgbRed: 0.055, green: 0.083, blue: 0.15, alpha: 1)
    let mint = NSColor(srgbRed: 0.41, green: 0.91, blue: 0.75, alpha: 1)
    rect(mac ? 55 : 0, mac ? 55 : 0, mac ? 914 : 1024, mac ? 914 : 1024, mac ? 205 : 0, navy)
    let remote = NSBezierPath(roundedRect: NSRect(x: 314, y: 160, width: 396, height: 704), xRadius: 120, yRadius: 120)
    NSGradient(starting: NSColor(srgbRed: 0.83, green: 0.89, blue: 1, alpha: 1),
        ending: NSColor(srgbRed: 0.52, green: 0.65, blue: 0.94, alpha: 1))!.draw(in: remote, angle: -90)
    rect(460, 744, 104, 24, 12, navy)
    navy.setFill()
    NSBezierPath(ovalIn: NSRect(x: 382, y: 422, width: 260, height: 260)).fill()
    mint.setFill()
    NSBezierPath(ovalIn: NSRect(x: 454, y: 494, width: 116, height: 116)).fill()
    for y: CGFloat in [286, 350] {
        rect(405, y, 86, 32, 16, navy)
        rect(533, y, 86, 32, 16, navy)
    }
    NSGraphicsContext.restoreGraphicsState()
    if !mac {
        let opaque = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
            bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        opaque.draw(bitmap.cgImage!, in: CGRect(x: 0, y: 0, width: size, height: size))
        return NSBitmapImageRep(cgImage: opaque.makeImage()!).representation(using: .png, properties: [:])!
    }
    return bitmap.representation(using: .png, properties: [:])!
}
func write(_ data: Data, _ path: String) throws {
    let url = root.appendingPathComponent(path)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url)
}
func json(_ value: Any, _ path: String) throws {
    try write(JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]), path)
}
let info: [String: Any] = ["author": "xcode", "version": 1]
for platform in ["Phone", "Host"] {
    let catalog = "Resources/\(platform)Assets.xcassets"
    try json(["info": info], "\(catalog)/Contents.json")
    var images: [[String: String]] = []
    if platform == "Phone" {
        try write(render(1024), "\(catalog)/AppIcon.appiconset/icon-1024.png")
        images.append(["idiom": "universal", "platform": "ios", "size": "1024x1024", "filename": "icon-1024.png"])
    } else {
        for size in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let filename = "icon-\(size)@\(scale)x.png"
                try write(render(size * scale, mac: true), "\(catalog)/AppIcon.appiconset/\(filename)")
                images.append(["idiom": "mac", "size": "\(size)x\(size)", "scale": "\(scale)x", "filename": filename])
            }
        }
    }
    try json(["info": info, "images": images], "\(catalog)/AppIcon.appiconset/Contents.json")
}
for size in [180, 192, 512] {
    try write(render(size), "Resources/WebRemote/icon-\(size).png")
}
