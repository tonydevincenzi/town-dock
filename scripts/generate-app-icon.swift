#!/usr/bin/env swift

import AppKit
import Foundation

guard CommandLine.arguments.count == 2 else {
    fputs("usage: generate-app-icon.swift OUTPUT.icns\n", stderr)
    exit(2)
}

let outputURL = URL(fileURLWithPath: CommandLine.arguments[1])
let fileManager = FileManager.default
let temporaryRoot = fileManager.temporaryDirectory
    .appendingPathComponent("town-dock-icon-\(UUID().uuidString)", isDirectory: true)
let iconsetURL = temporaryRoot.appendingPathComponent("TownDock.iconset", isDirectory: true)
try fileManager.createDirectory(at: iconsetURL, withIntermediateDirectories: true)
defer {
    if ProcessInfo.processInfo.environment["KEEP_TOWN_ICONSET"] == nil {
        try? fileManager.removeItem(at: temporaryRoot)
    } else {
        print("Kept iconset at \(iconsetURL.path)")
    }
}

func drawIcon(pixelSize: Int, to url: URL) throws {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixelSize,
        pixelsHigh: pixelSize,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        throw NSError(domain: "TownDockIcon", code: 1)
    }

    bitmap.size = NSSize(width: pixelSize, height: pixelSize)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    NSGraphicsContext.current?.imageInterpolation = .high

    let side = CGFloat(pixelSize)
    let inset = side * 0.055
    let backgroundRect = NSRect(x: inset, y: inset, width: side - inset * 2, height: side - inset * 2)
    let background = NSBezierPath(
        roundedRect: backgroundRect,
        xRadius: side * 0.205,
        yRadius: side * 0.205
    )

    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
    shadow.shadowBlurRadius = side * 0.045
    shadow.shadowOffset = NSSize(width: 0, height: -side * 0.018)
    shadow.set()
    NSGradient(
        starting: NSColor(red: 0.12, green: 0.12, blue: 0.13, alpha: 1),
        ending: NSColor(red: 0.035, green: 0.035, blue: 0.04, alpha: 1)
    )?.draw(in: background, angle: 62)

    NSGraphicsContext.current?.saveGraphicsState()
    NSShadow().set()
    NSColor.white.withAlphaComponent(0.075).setStroke()
    background.lineWidth = max(1, side * 0.008)
    background.stroke()

    let glyphSide = side * 0.57
    let glyphOrigin = (side - glyphSide) / 2
    let scale = glyphSide / 256
    let transform = NSAffineTransform()
    transform.translateX(by: glyphOrigin, yBy: glyphOrigin)
    transform.scale(by: scale)

    NSColor.white.setStroke()
    for layer in [
        [NSPoint(x: 32, y: 176), NSPoint(x: 128, y: 232), NSPoint(x: 224, y: 176), NSPoint(x: 128, y: 120), NSPoint(x: 32, y: 176)],
        [NSPoint(x: 32, y: 128), NSPoint(x: 128, y: 72), NSPoint(x: 224, y: 128)],
        [NSPoint(x: 32, y: 80), NSPoint(x: 128, y: 24), NSPoint(x: 224, y: 80)],
    ] {
        let path = NSBezierPath()
        path.move(to: layer[0])
        for point in layer.dropFirst() { path.line(to: point) }
        path.transform(using: transform as AffineTransform)
        path.lineWidth = 24 * scale
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.stroke()
    }
    NSGraphicsContext.current?.restoreGraphicsState()
    NSGraphicsContext.restoreGraphicsState()

    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "TownDockIcon", code: 2)
    }
    try png.write(to: url)
}

let representations: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

for (name, size) in representations {
    try drawIcon(pixelSize: size, to: iconsetURL.appendingPathComponent(name))
}
func bigEndianData(_ value: UInt32) -> Data {
    var value = value.bigEndian
    return Data(bytes: &value, count: MemoryLayout<UInt32>.size)
}

// Modern ICNS representations use PNG payloads. Writing the small container
// directly avoids iconutil behavior differences between Command Line Tools
// releases while keeping all standard macOS icon sizes.
let chunks: [(String, String)] = [
    ("ic10", "icon_512x512@2x.png"),
    ("ic09", "icon_512x512.png"),
    ("ic08", "icon_256x256.png"),
    ("ic07", "icon_128x128.png"),
    ("icp6", "icon_32x32@2x.png"),
    ("icp5", "icon_32x32.png"),
    ("icp4", "icon_16x16.png"),
]

var payload = Data()
for (type, filename) in chunks {
    let png = try Data(contentsOf: iconsetURL.appendingPathComponent(filename))
    payload.append(type.data(using: .ascii)!)
    payload.append(bigEndianData(UInt32(png.count + 8)))
    payload.append(png)
}

var icns = Data("icns".utf8)
icns.append(bigEndianData(UInt32(payload.count + 8)))
icns.append(payload)
try icns.write(to: outputURL, options: .atomic)
