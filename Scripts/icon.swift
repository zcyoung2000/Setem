// 生成 App 图标：swift Scripts/icon.swift <out.png>，基于 docs/icon.png 输出 1024×1024
import AppKit

let script = URL(fileURLWithPath: #filePath)
let sourceURL = script.deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("docs/icon.png")
let outputURL = URL(fileURLWithPath: CommandLine.arguments[1])

guard let source = NSImage(contentsOf: sourceURL) else {
    FileHandle.standardError.write("图标源文件不存在：\(sourceURL.path)\n".data(using: .utf8)!)
    exit(1)
}

let size = 1024.0
let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(size),
    pixelsHigh: Int(size),
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
source.draw(
    in: NSRect(origin: .zero, size: NSSize(width: size, height: size)),
    from: .zero,
    operation: .sourceOver,
    fraction: 1,
    respectFlipped: false,
    hints: [.interpolation: NSImageInterpolation.high]
)
NSGraphicsContext.current = nil
try! rep.representation(using: .png, properties: [:])!.write(to: outputURL)
