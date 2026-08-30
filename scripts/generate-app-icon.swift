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
    .appendingPathComponent("town-sheriff-icon-\(UUID().uuidString)", isDirectory: true)
let iconsetURL = temporaryRoot.appendingPathComponent("TownSheriff.iconset", isDirectory: true)
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
        throw NSError(domain: "TownSheriffIcon", code: 1)
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

    let glyphSide = side * 0.60
    let glyphOrigin = (side - glyphSide) / 2
    let shieldStarSVG = """
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 256 256" fill="#fff"><path d="M76.86,115.54a12,12,0,0,1,15.6-6.68L116,118.28V96a12,12,0,0,1,24,0v22.28l23.54-9.42a12,12,0,0,1,8.92,22.28L147,141.33,161.6,160.8a12,12,0,1,1-19.2,14.4L128,156l-14.4,19.2a12,12,0,1,1-19.2-14.4L109,141.33,83.54,131.14A12,12,0,0,1,76.86,115.54ZM228,56v56c0,54.29-26.32,87.22-48.4,105.29-23.71,19.39-47.44,26-48.44,26.29a12.1,12.1,0,0,1-6.32,0c-1-.28-24.73-6.9-48.44-26.29C54.32,199.22,28,166.29,28,112V56A20,20,0,0,1,48,36H208A20,20,0,0,1,228,56Zm-24,4H52v52c0,35.71,13.09,64.69,38.91,86.15A126.14,126.14,0,0,0,128,219.38a126.28,126.28,0,0,0,37.09-21.23C190.91,176.69,204,147.71,204,112Z"/></svg>
    """
    guard let glyph = NSImage(data: Data(shieldStarSVG.utf8)) else {
        throw NSError(domain: "TownSheriffIcon", code: 2)
    }
    glyph.draw(
        in: NSRect(x: glyphOrigin, y: glyphOrigin, width: glyphSide, height: glyphSide),
        from: .zero,
        operation: .sourceOver,
        fraction: 1
    )
    NSGraphicsContext.current?.restoreGraphicsState()
    NSGraphicsContext.restoreGraphicsState()

    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "TownSheriffIcon", code: 3)
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
