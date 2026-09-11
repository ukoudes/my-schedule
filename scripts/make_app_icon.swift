import AppKit

let size = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
let canvas = NSRect(x: 0, y: 0, width: size, height: size)
NSGradient(starting: NSColor(red: 0.18, green: 0.83, blue: 0.75, alpha: 1), ending: NSColor(red: 0.06, green: 0.46, blue: 0.43, alpha: 1))!.draw(in: NSBezierPath(roundedRect: canvas, xRadius: 224, yRadius: 224), angle: -45)

NSColor.white.setFill()
NSBezierPath(roundedRect: NSRect(x: 196, y: 204, width: 632, height: 616), xRadius: 84, yRadius: 84).fill()
NSColor.white.setStroke()
for x in [346, 512, 678] {
    let binding = NSBezierPath(); binding.lineWidth = 44; binding.lineCapStyle = .round; binding.move(to: NSPoint(x: x, y: 748)); binding.line(to: NSPoint(x: x, y: 882)); binding.stroke()
}
NSColor(red: 0.06, green: 0.46, blue: 0.43, alpha: 1).setFill()
for y in [470, 624] {
    for x in [310, 466, 622] {
        NSBezierPath(roundedRect: NSRect(x: x, y: y, width: 92, height: 92), xRadius: 22, yRadius: 22).fill()
    }
}
image.unlockFocus()
let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "work/AppIcon.png"))
