import AppKit
import CoreGraphics
import Foundation

// Fallback bitmap for macOS versions that use AppIcon.appiconset or .icns.
// icon.svg and Layers/ use the same geometry; the layers remain editable for Icon Composer.
let side = 1024
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
                        bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
context.setAllowsAntialiasing(true)
context.setShouldAntialias(true)
context.interpolationQuality = .high
context.translateBy(x: 0, y: CGFloat(side))
context.scaleBy(x: 1, y: -1)

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: space, components: [r / 255, g / 255, b / 255, a])!
}
func rounded(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: CGRect(x: x, y: y, width: w, height: h),
           cornerWidth: radius, cornerHeight: radius, transform: nil)
}
func gradient(_ path: CGPath, _ colors: [CGColor], from: CGPoint, to: CGPoint) {
    context.saveGState()
    context.addPath(path); context.clip()
    let fill = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: nil)!
    context.drawLinearGradient(fill, start: from, end: to, options: [])
    context.restoreGState()
}
func stroke(_ path: CGPath, _ color: CGColor, _ width: CGFloat) {
    context.addPath(path); context.setStrokeColor(color); context.setLineWidth(width); context.strokePath()
}

// A simple blue tile with enough contrast for light and dark desktops.
let tile = rounded(38, 38, 948, 948, 220)
context.saveGState()
context.setShadow(offset: CGSize(width: 0, height: 13), blur: 24, color: color(38, 96, 158, 0.24))
gradient(tile, [color(230, 247, 255), color(138, 194, 250), color(114, 199, 232)],
         from: CGPoint(x: 150, y: 70), to: CGPoint(x: 870, y: 970))
context.restoreGState()
stroke(tile, color(231, 250, 255, 0.95), 7)
context.saveGState(); context.addPath(tile); context.clip()
gradient(rounded(56, 55, 912, 484, 205), [color(255, 255, 255, 0.66), color(255, 255, 255, 0.02)],
         from: CGPoint(x: 480, y: 55), to: CGPoint(x: 480, y: 539))
context.restoreGState()

// One glass-edged wallpaper frame, a small sun, and two broad landscape shapes.
let frame = rounded(174, 252, 676, 512, 92)
context.saveGState()
context.setShadow(offset: CGSize(width: 0, height: 12), blur: 24, color: color(37, 97, 168, 0.23))
context.addPath(frame); context.setFillColor(color(234, 249, 255, 0.84)); context.fillPath()
context.restoreGState()
stroke(frame, color(255, 255, 255, 0.93), 5)
let scene = rounded(208, 286, 608, 444, 62)
gradient(scene, [color(198, 232, 255), color(93, 179, 243)],
         from: CGPoint(x: 320, y: 286), to: CGPoint(x: 700, y: 730))
context.saveGState(); context.addPath(scene); context.clip()
context.setFillColor(color(247, 253, 255, 0.92))
context.fillEllipse(in: CGRect(x: 660, y: 361, width: 78, height: 78))
let mountain = CGMutablePath()
mountain.move(to: CGPoint(x: 208, y: 637))
mountain.addLine(to: CGPoint(x: 430, y: 430))
mountain.addCurve(to: CGPoint(x: 610, y: 615), control1: CGPoint(x: 472, y: 421), control2: CGPoint(x: 554, y: 582))
mountain.addLine(to: CGPoint(x: 816, y: 525))
mountain.addLine(to: CGPoint(x: 816, y: 730))
mountain.addLine(to: CGPoint(x: 208, y: 730))
mountain.closeSubpath()
gradient(mountain, [color(91, 181, 248), color(47, 136, 220)],
         from: CGPoint(x: 425, y: 440), to: CGPoint(x: 525, y: 735))
let foreground = CGMutablePath()
foreground.move(to: CGPoint(x: 208, y: 573))
foreground.addCurve(to: CGPoint(x: 540, y: 687), control1: CGPoint(x: 340, y: 525), control2: CGPoint(x: 424, y: 648))
foreground.addCurve(to: CGPoint(x: 816, y: 581), control1: CGPoint(x: 665, y: 706), control2: CGPoint(x: 734, y: 552))
foreground.addLine(to: CGPoint(x: 816, y: 730))
foreground.addLine(to: CGPoint(x: 208, y: 730))
foreground.closeSubpath()
gradient(foreground, [color(81, 172, 244), color(31, 113, 206)],
         from: CGPoint(x: 290, y: 570), to: CGPoint(x: 640, y: 765))
context.restoreGState()
stroke(scene, color(239, 251, 255, 0.58), 3)

// Large enough to remain recognizable at 32 px; no tiny optical details.
let badge = CGRect(x: 620, y: 596, width: 242, height: 242)
context.saveGState()
context.setShadow(offset: CGSize(width: 0, height: 13), blur: 23, color: color(22, 81, 151, 0.26))
context.setFillColor(color(188, 226, 253, 0.97)); context.fillEllipse(in: badge)
context.restoreGState()
context.setStrokeColor(color(250, 254, 255, 0.96)); context.setLineWidth(6)
context.strokeEllipse(in: badge.insetBy(dx: 3, dy: 3))
let play = CGMutablePath()
play.move(to: CGPoint(x: 708, y: 650))
play.addQuadCurve(to: CGPoint(x: 713, y: 646), control: CGPoint(x: 708, y: 642))
play.addLine(to: CGPoint(x: 793, y: 706))
play.addQuadCurve(to: CGPoint(x: 793, y: 727), control: CGPoint(x: 807, y: 717))
play.addLine(to: CGPoint(x: 713, y: 784))
play.addQuadCurve(to: CGPoint(x: 708, y: 780), control: CGPoint(x: 708, y: 789))
play.closeSubpath()
context.addPath(play); context.setFillColor(color(255, 255, 255)); context.fillPath()

let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "Resources/AppIcon/master-1024.png")
let image = context.makeImage()!
let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
try data.write(to: output)
print(output.path)
