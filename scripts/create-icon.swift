import AppKit
import Foundation

let output = CommandLine.arguments[1]
let sizes = [16, 32, 64, 128, 256, 512, 1024]
try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
func draw(_ size: Int, path: String) {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    let scale = CGFloat(size) / 1024
    let context = NSGraphicsContext.current!.cgContext
    context.scaleBy(x: scale, y: scale)
    let rect = NSRect(x: 64, y: 64, width: 896, height: 896)
    let shape = NSBezierPath(roundedRect: rect, xRadius: 210, yRadius: 210)
    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    NSGradient(starting: NSColor(calibratedRed: 1, green: 0.63, blue: 0.76, alpha: 1), ending: NSColor(calibratedRed: 0.96, green: 0.34, blue: 0.56, alpha: 1))!.draw(in: rect, angle: -55)
    NSGraphicsContext.restoreGraphicsState()
    // A small pair of antenna strokes makes the icon feel at home beside Bilibili.
    NSColor.white.withAlphaComponent(0.9).setStroke()
    let antenna = NSBezierPath(); antenna.lineWidth = 25; antenna.lineCapStyle = .round
    antenna.move(to: NSPoint(x: 416, y: 755)); antenna.line(to: NSPoint(x: 371, y: 804))
    antenna.move(to: NSPoint(x: 608, y: 755)); antenna.line(to: NSPoint(x: 653, y: 804)); antenna.stroke()
    let text = "Bli" as NSString
    let font = NSFont.systemFont(ofSize: 330, weight: .heavy)
    let shadow = NSShadow(); shadow.shadowColor = NSColor(calibratedRed: 0.17, green: 0.51, blue: 0.67, alpha: 0.38); shadow.shadowOffset = NSSize(width: 0, height: -10); shadow.shadowBlurRadius = 0
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white, .kern: -12, .shadow: shadow]
    let extent = text.size(withAttributes: attrs)
    text.draw(at: NSPoint(x: (1024 - extent.width) / 2, y: 350), withAttributes: attrs)
    let dash = NSBezierPath(roundedRect: NSRect(x: 420, y: 232, width: 184, height: 24), xRadius: 12, yRadius: 12)
    NSColor(calibratedRed: 0.14, green: 0.75, blue: 0.91, alpha: 1).setFill(); dash.fill()
    image.unlockFocus()
    guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) else { fatalError("无法生成图标") }
    try! png.write(to: URL(fileURLWithPath: path))
}
for size in sizes { draw(size, path: "\(output)/icon_\(size)x\(size).png") }
for size in [16, 32, 128, 256, 512] { draw(size * 2, path: "\(output)/icon_\(size)x\(size)@2x.png") }
// iconutil accepts only its prescribed filenames.
try? FileManager.default.removeItem(atPath: "\(output)/icon_64x64.png")
try? FileManager.default.removeItem(atPath: "\(output)/icon_1024x1024.png")
