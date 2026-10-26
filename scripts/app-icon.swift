// Draws the app icon: a bundle of indigo cloth (보따리) tied at the top, on
// hanji-coloured paper. Writes the AppIcon set, plus a PNG for the README.
//
//   swift scripts/app-icon.swift Bottari/Assets.xcassets/AppIcon.appiconset docs/icon.png
import AppKit

let canvas: CGFloat = 1024

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

/// Paths are written in top-left coordinates, the way the drawing was sketched.
struct Pen {
    let path = CGMutablePath()
    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: canvas - y) }
    func move(_ x: CGFloat, _ y: CGFloat) { path.move(to: p(x, y)) }
    func line(_ x: CGFloat, _ y: CGFloat) { path.addLine(to: p(x, y)) }
    func curve(_ x: CGFloat, _ y: CGFloat, _ c1x: CGFloat, _ c1y: CGFloat, _ c2x: CGFloat, _ c2y: CGFloat) {
        path.addCurve(to: p(x, y), control1: p(c1x, c1y), control2: p(c2x, c2y))
    }
    func close() { path.closeSubpath() }
}

func gradient(_ context: CGContext, _ path: CGPath, _ top: UInt32, _ bottom: UInt32, from y0: CGFloat, to y1: CGFloat) {
    context.saveGState()
    context.addPath(path)
    context.clip()
    let colors = [color(top), color(bottom)] as CFArray
    let shading = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1])!
    context.drawLinearGradient(shading, start: CGPoint(x: 0, y: canvas - y0), end: CGPoint(x: 0, y: canvas - y1), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    context.restoreGState()
}

func draw(_ context: CGContext) {
    // The tile: macOS's 824-point rounded square, with its shadow.
    let tile = CGPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824), cornerWidth: 185, cornerHeight: 185, transform: nil)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: color(0x000000, 0.28))
    context.addPath(tile)
    context.setFillColor(color(0xEFE7D8))
    context.fillPath()
    context.restoreGState()
    gradient(context, tile, 0xF7F2E8, 0xE6DBC6, from: 100, to: 924)
    // The ears and the shadow under it weigh the bundle down; lift it to the optical centre.
    context.translateBy(x: 0, y: 28)

    // A soft shadow where the bundle sits.
    context.saveGState()
    context.setFillColor(color(0x5B4A2E, 0.16))
    context.fillEllipse(in: CGRect(x: 250, y: canvas - 846, width: 524, height: 50))
    context.restoreGState()

    // The ears: two corners of the cloth tied together, standing up.
    let leftEar = Pen()
    leftEar.move(486, 462)
    leftEar.curve(366, 292, 452, 410, 392, 352)
    leftEar.curve(536, 440, 418, 262, 512, 344)
    leftEar.close()
    gradient(context, leftEar.path, 0x4D73AB, 0x2C4A78, from: 292, to: 462)

    let rightEar = Pen()
    rightEar.move(538, 462)
    rightEar.curve(672, 318, 576, 420, 642, 372)
    rightEar.curve(490, 442, 650, 296, 512, 350)
    rightEar.close()
    gradient(context, rightEar.path, 0x40639B, 0x24406B, from: 318, to: 462)

    // The body: a square load wrapped in cloth, the shoulders pulled up to the knot.
    let body = Pen()
    body.move(334, 822)
    body.curve(690, 822, 450, 834, 574, 834)
    body.curve(760, 748, 736, 820, 760, 790)
    body.curve(744, 612, 762, 700, 758, 650)
    body.curve(560, 470, 712, 556, 614, 496)
    body.line(464, 470)
    body.curve(280, 612, 410, 496, 312, 556)
    body.curve(264, 748, 266, 650, 262, 700)
    body.curve(334, 822, 264, 790, 288, 820)
    body.close()
    gradient(context, body.path, 0x3E639B, 0x203A63, from: 470, to: 834)

    context.saveGState()
    context.addPath(body.path)
    context.clip()

    // The front flap: its hem crosses the load, the cloth below in its shadow.
    let flap = Pen()
    flap.move(240, 652)
    flap.curve(784, 652, 400, 724, 624, 724)
    flap.line(784, 860)
    flap.line(240, 860)
    flap.close()
    context.addPath(flap.path)
    context.setFillColor(color(0x10213D, 0.22))
    context.fillPath()

    // A scatter of small light flowers, as printed on 보따리 cloth.
    context.setFillColor(color(0xF3EBDD, 0.17))
    for row in 0..<6 {
        for column in 0..<8 {
            let x = 250 + CGFloat(column) * 72 + (row % 2 == 0 ? 0 : 36)
            let y = 500 + CGFloat(row) * 62
            for (dx, dy) in [(0.0, -9.0), (9.0, 0.0), (0.0, 9.0), (-9.0, 0.0)] {
                context.fillEllipse(in: CGRect(x: x + dx - 5.5, y: canvas - (y + dy) - 5.5, width: 11, height: 11))
            }
        }
    }

    // Folds pulled from the knot towards the corners, and the hem itself.
    context.setLineCap(.round)
    context.setLineWidth(13)
    context.setStrokeColor(color(0x132745, 0.5))
    for (from, control, to) in [
        ((474.0, 496.0), (380.0, 560.0), (300.0, 690.0)),
        ((550.0, 496.0), (644.0, 560.0), (724.0, 690.0)),
    ] {
        context.move(to: CGPoint(x: from.0, y: canvas - from.1))
        context.addQuadCurve(to: CGPoint(x: to.0, y: canvas - to.1), control: CGPoint(x: control.0, y: canvas - control.1))
    }
    context.strokePath()
    context.setStrokeColor(color(0xFFFFFF, 0.22))
    context.setLineWidth(8)
    context.move(to: CGPoint(x: 240, y: canvas - 652))
    context.addCurve(to: CGPoint(x: 784, y: canvas - 652), control1: CGPoint(x: 400, y: canvas - 724), control2: CGPoint(x: 624, y: canvas - 724))
    context.strokePath()
    context.restoreGState()

    // The knot, with the crease where the corners cross.
    let knot = CGPath(ellipseIn: CGRect(x: 458, y: canvas - 506, width: 108, height: 78), transform: nil)
    gradient(context, knot, 0x2E4C7C, 0x172C4E, from: 428, to: 506)
    context.saveGState()
    context.addPath(knot)
    context.clip()
    context.setLineCap(.round)
    context.setStrokeColor(color(0x0E1E38, 0.6))
    context.setLineWidth(9)
    context.move(to: CGPoint(x: 488, y: canvas - 496))
    context.addQuadCurve(to: CGPoint(x: 540, y: canvas - 440), control: CGPoint(x: 526, y: canvas - 480))
    context.strokePath()
    context.setStrokeColor(color(0xFFFFFF, 0.2))
    context.setLineWidth(7)
    context.move(to: CGPoint(x: 476, y: canvas - 452))
    context.addQuadCurve(to: CGPoint(x: 508, y: canvas - 438), control: CGPoint(x: 488, y: canvas - 440))
    context.strokePath()
    context.restoreGState()
}

func render(pixels: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    let graphics = NSGraphicsContext(bitmapImageRep: rep)!
    let context = graphics.cgContext
    context.interpolationQuality = .high
    context.scaleBy(x: CGFloat(pixels) / canvas, y: CGFloat(pixels) / canvas)
    draw(context)
    graphics.flushGraphics()
    return rep
}

func write(_ rep: NSBitmapImageRep, to path: String) {
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    print("usage: swift scripts/app-icon.swift <AppIcon.appiconset> [readme.png]")
    exit(1)
}
let set = arguments[1]
try FileManager.default.createDirectory(atPath: set, withIntermediateDirectories: true)
var images: [String] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        write(render(pixels: points * scale), to: "\(set)/\(name)")
        images.append(#"{ "filename" : "\#(name)", "idiom" : "mac", "scale" : "\#(scale)x", "size" : "\#(points)x\#(points)" }"#)
    }
}
let contents = "{\n  \"images\" : [\n    " + images.joined(separator: ",\n    ") + "\n  ],\n  \"info\" : { \"author\" : \"xcode\", \"version\" : 1 }\n}\n"
try contents.write(toFile: "\(set)/Contents.json", atomically: true, encoding: .utf8)
if arguments.count >= 3 {
    try FileManager.default.createDirectory(atPath: (arguments[2] as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    write(render(pixels: 512), to: arguments[2])
}
