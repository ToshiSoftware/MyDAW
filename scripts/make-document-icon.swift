// Draws the .mydaw document icon (a page with the app icon in the middle)
// from AppIcon.iconset and writes DocumentIcon.icns in the project root.
// Run from the project root: swift scripts/make-document-icon.swift
import AppKit

let fileManager = FileManager.default
let projectURL = URL(fileURLWithPath: fileManager.currentDirectoryPath)
let appIconURL = projectURL.appendingPathComponent("AppIcon.iconset/icon_512x512@2x.png")
guard let appIcon = NSImage(contentsOf: appIconURL),
      let appIconImage = appIcon.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    fatalError("Could not read \(appIconURL.path)")
}

let iconsetURL = fileManager.temporaryDirectory.appendingPathComponent("DocumentIcon.iconset")
try? fileManager.removeItem(at: iconsetURL)
try fileManager.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

/// Draws the icon at `pixels` × `pixels`. Coordinates are in a 1024 grid,
/// origin bottom left.
func drawIcon(pixels: Int) -> Data {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let context = CGContext(
        data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    let scale = CGFloat(pixels) / 1024
    context.scaleBy(x: scale, y: scale)
    context.interpolationQuality = .high

    // The page, with its top right corner folded over.
    let page = CGRect(x: 172, y: 60, width: 680, height: 904)
    let fold: CGFloat = 170
    let radius: CGFloat = 36
    let outline = CGMutablePath()
    outline.move(to: CGPoint(x: page.minX + radius, y: page.minY))
    outline.addLine(to: CGPoint(x: page.maxX - radius, y: page.minY))
    outline.addQuadCurve(to: CGPoint(x: page.maxX, y: page.minY + radius), control: CGPoint(x: page.maxX, y: page.minY))
    outline.addLine(to: CGPoint(x: page.maxX, y: page.maxY - fold))
    outline.addLine(to: CGPoint(x: page.maxX - fold, y: page.maxY))
    outline.addLine(to: CGPoint(x: page.minX + radius, y: page.maxY))
    outline.addQuadCurve(to: CGPoint(x: page.minX, y: page.maxY - radius), control: CGPoint(x: page.minX, y: page.maxY))
    outline.addLine(to: CGPoint(x: page.minX, y: page.minY + radius))
    outline.addQuadCurve(to: CGPoint(x: page.minX + radius, y: page.minY), control: CGPoint(x: page.minX, y: page.minY))
    outline.closeSubpath()

    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: CGColor(gray: 0, alpha: 0.35))
    context.addPath(outline)
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fillPath()
    context.restoreGState()

    context.addPath(outline)
    context.setStrokeColor(CGColor(gray: 0.72, alpha: 1))
    context.setLineWidth(max(4, 1.2 / scale))
    context.strokePath()

    // The folded-over corner.
    let flap = CGMutablePath()
    flap.move(to: CGPoint(x: page.maxX - fold, y: page.maxY))
    flap.addLine(to: CGPoint(x: page.maxX - fold, y: page.maxY - fold + radius))
    flap.addQuadCurve(to: CGPoint(x: page.maxX - fold + radius, y: page.maxY - fold), control: CGPoint(x: page.maxX - fold, y: page.maxY - fold))
    flap.addLine(to: CGPoint(x: page.maxX, y: page.maxY - fold))
    flap.closeSubpath()
    context.saveGState()
    context.setShadow(offset: CGSize(width: -4, height: -6), blur: 12, color: CGColor(gray: 0, alpha: 0.25))
    context.addPath(flap)
    context.setFillColor(CGColor(gray: 0.9, alpha: 1))
    context.fillPath()
    context.restoreGState()
    context.addPath(flap)
    context.setStrokeColor(CGColor(gray: 0.72, alpha: 1))
    context.setLineWidth(max(4, 1.2 / scale))
    context.setLineJoin(.round)
    context.strokePath()

    // The app icon in the middle of the page, with rounded corners.
    let iconSize: CGFloat = 430
    let iconRect = CGRect(x: page.midX - iconSize / 2, y: page.midY - iconSize / 2 - 30, width: iconSize, height: iconSize)
    let iconPath = CGPath(roundedRect: iconRect, cornerWidth: iconSize * 0.225, cornerHeight: iconSize * 0.225, transform: nil)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -6), blur: 14, color: CGColor(gray: 0, alpha: 0.3))
    context.addPath(iconPath)
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fillPath()
    context.restoreGState()
    context.saveGState()
    context.addPath(iconPath)
    context.clip()
    context.draw(appIconImage, in: iconRect)
    context.restoreGState()

    let rep = NSBitmapImageRep(cgImage: context.makeImage()!)
    return rep.representation(using: .png, properties: [:])!
}

for points in [16, 32, 128, 256, 512] {
    for factor in [1, 2] {
        let name = factor == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        try drawIcon(pixels: points * factor).write(to: iconsetURL.appendingPathComponent(name))
    }
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconsetURL.path, "-o", projectURL.appendingPathComponent("DocumentIcon.icns").path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }
print("Wrote DocumentIcon.icns")
