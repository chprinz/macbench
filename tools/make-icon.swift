// Renders the app icon.
//
// A workbench, because that is what the app is named after and what it is: the
// surface the shared work sits on. One accent mark resting on it stands for
// "something here is new" — the same dot the sidebar uses.
//
// The constraint that shapes everything: it has to survive at sixteen points in
// the Dock. So the slab and the legs carry the same weight, there is no detail
// below about four percent of the canvas, and the whole mark is one silhouette.
import AppKit

let sizes = [16, 32, 64, 128, 256, 512, 1024]
let arguments = CommandLine.arguments
let output = arguments.count > 1
    ? URL(fileURLWithPath: arguments[1])
    : URL(fileURLWithPath: "Branding/MacBench/Assets.xcassets/AppIcon.appiconset")
let accent = arguments.count > 2 ? arguments[2] : "E4572E"
// "bench" draws the bench. Anything else is drawn as letters sitting on the
// bench top — a monogram for a build of your own, on the same plate and palette,
// so the two read as siblings rather than as unrelated apps.
let mark = arguments.count > 3 ? arguments[3] : "bench"

func color(_ hex: String, alpha: CGFloat = 1) -> NSColor {
    var value: UInt64 = 0
    Scanner(string: hex).scanHexInt64(&value)
    return NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
                   green: CGFloat((value >> 8) & 0xFF) / 255,
                   blue: CGFloat(value & 0xFF) / 255, alpha: alpha)
}

func rounded(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

/// Two or three letters sitting on the bench top, the slab carrying the accent.
/// Two shapes, which is all that survives at sixteen points — and the slab keeps
/// the family likeness to the plain bench.
///
/// Placed from the font's own metrics rather than by eye: lower-case letters
/// without ascender or descender have the x-height as their optical height, and
/// anything centred on the line box instead sits noticeably high.
func drawMonogram(_ letters: String, context: CGContext, plate: CGRect) {
    let pointSize = plate.height * 0.50
    let base = NSFont.systemFont(ofSize: pointSize, weight: .black)
    let font = NSFont(descriptor: base.fontDescriptor.withDesign(.rounded) ?? base.fontDescriptor,
                      size: pointSize) ?? base
    let text = NSAttributedString(string: letters, attributes: [
        .font: font,
        .foregroundColor: color("F2EDE6"),
        .kern: -pointSize * 0.04,
    ])

    let textWidth = text.size().width
    let slabHeight = plate.height * 0.095
    let gap = plate.height * 0.05
    let groupHeight = font.xHeight + gap + slabHeight
    let groupBottom = plate.midY - groupHeight / 2

    let slabWidth = textWidth * 1.04
    let slab = CGRect(x: plate.midX - slabWidth / 2, y: groupBottom,
                      width: slabWidth, height: slabHeight)
    context.setFillColor(color(accent).cgColor)
    context.addPath(rounded(slab, slabHeight * 0.32))
    context.fillPath()

    // draw(at:) takes the bottom-left of the line box, which sits a descender
    // below the baseline.
    let baseline = slab.maxY + gap
    text.draw(at: CGPoint(x: plate.midX - textWidth / 2, y: baseline - abs(font.descender)))
}

/// Renders into a bitmap of exactly `pixels` × `pixels`.
///
/// Not `NSImage.lockFocus()`: that draws at the screen's backing scale, so on a
/// Retina Mac every file came out twice its declared size and actool dropped the
/// whole icon set without failing the build. The app then shipped with no icon
/// and nothing said so.
func render(_ pixels: Int) -> Data {
    let size = CGFloat(pixels)
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
        let graphics = NSGraphicsContext(bitmapImageRep: rep)
    else { fatalError("could not make a \(pixels)px bitmap") }
    rep.size = NSSize(width: size, height: size)  // one point, one pixel

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics
    defer { NSGraphicsContext.restoreGraphicsState() }
    let context = graphics.cgContext
    context.setAllowsAntialiasing(true)

    let inset = size * 0.085
    let plate = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let plateRadius = plate.width * 0.225

    context.saveGState()
    context.addPath(rounded(plate, plateRadius))
    context.clip()

    // Warm charcoal, lit from above. Not black: a flat black square in the Dock
    // reads as a hole rather than an object.
    let ground = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                            colors: [color("2A2522").cgColor, color("0E0D0F").cgColor] as CFArray,
                            locations: [0, 1])!
    context.drawLinearGradient(ground, start: CGPoint(x: 0, y: plate.maxY),
                               end: CGPoint(x: 0, y: plate.minY), options: [])

    // A rim of light along the top edge, so the plate has a surface rather than
    // being a coloured rectangle.
    let rim = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                         colors: [color("FFFFFF", alpha: 0.14).cgColor,
                                  color("FFFFFF", alpha: 0).cgColor] as CFArray,
                         locations: [0, 1])!
    context.drawLinearGradient(rim, start: CGPoint(x: 0, y: plate.maxY),
                               end: CGPoint(x: 0, y: plate.maxY - plate.height * 0.22), options: [])
    context.restoreGState()

    if mark != "bench" {
        drawMonogram(mark, context: context, plate: plate)
        return png(from: rep, expecting: pixels)
    }

    // The bench. Slab and legs share one weight so the silhouette holds together
    // when it is sixteen points wide.
    let weight = plate.height * 0.105
    let benchWidth = plate.width * 0.60
    let left = plate.midX - benchWidth / 2
    let legHeight = plate.height * 0.215
    let dot = plate.width * 0.115
    // The dot rests on the bench rather than hovering beside it, and the whole
    // group is centred as one shape: slab, legs and what is sitting on it.
    let gap = plate.height * 0.022
    let groupHeight = dot + gap + weight + legHeight
    let footY = plate.midY - groupHeight / 2
    let slabY = footY + legHeight
    let legInset = weight * 0.55
    let wood = color("F2EDE6")

    context.setFillColor(wood.cgColor)
    context.addPath(rounded(CGRect(x: left, y: slabY, width: benchWidth, height: weight),
                            weight * 0.32))
    for x in [left + legInset, left + benchWidth - legInset - weight] {
        context.addPath(rounded(CGRect(x: x, y: slabY - legHeight, width: weight, height: legHeight),
                                weight * 0.32))
    }
    context.fillPath()

    // Something on the bench is new.
    context.setFillColor(color(accent).cgColor)
    context.fillEllipse(in: CGRect(x: left + benchWidth * 0.62,
                                   y: slabY + weight + gap,
                                   width: dot, height: dot))

    return png(from: rep, expecting: pixels)
}

/// The check that was missing. A mismatch here is exactly the failure that shipped
/// two apps without icons, so it stops the script rather than being written out.
func png(from rep: NSBitmapImageRep, expecting pixels: Int) -> Data {
    guard rep.pixelsWide == pixels, rep.pixelsHigh == pixels else {
        fatalError("rendered \(rep.pixelsWide)×\(rep.pixelsHigh) for a \(pixels)px slot")
    }
    guard let data = rep.representation(using: .png, properties: [:]) else {
        fatalError("could not encode PNG")
    }
    return data
}

try! FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
for pixels in sizes {
    try! render(pixels).write(to: output.appending(path: "icon_\(pixels).png"))
}
var entries: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    entries.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "1x",
                    "filename": "icon_\(points).png"])
    entries.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "2x",
                    "filename": "icon_\(points * 2).png"])
}
let contents: [String: Any] = ["images": entries, "info": ["author": "xcode", "version": 1]]
try! JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    .write(to: output.appending(path: "Contents.json"))
print("wrote \(sizes.count) sizes to \(output.path)")
