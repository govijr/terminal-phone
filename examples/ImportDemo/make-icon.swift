// Draws the 1024 px app icon: a white smiling chat bubble on a pink gradient.
import AppKit
let size = 1024.0
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
NSGradient(starting: NSColor(red: 1.0, green: 0.30, blue: 0.70, alpha: 1),
           ending: NSColor(red: 0.78, green: 0.0, blue: 0.45, alpha: 1))!
    .draw(in: NSRect(x: 0, y: 0, width: size, height: size), angle: -90)
NSColor.white.setFill()
let bubble = NSBezierPath(roundedRect: NSRect(x: 212, y: 300, width: 600, height: 460), xRadius: 230, yRadius: 230)
bubble.fill()
let tail = NSBezierPath()
tail.move(to: NSPoint(x: 300, y: 360)); tail.line(to: NSPoint(x: 230, y: 230)); tail.line(to: NSPoint(x: 420, y: 320)); tail.close(); tail.fill()
let ink = NSColor(red: 0.85, green: 0.05, blue: 0.5, alpha: 1)
ink.setFill()
NSBezierPath(ovalIn: NSRect(x: 380, y: 560, width: 70, height: 90)).fill()
NSBezierPath(ovalIn: NSRect(x: 574, y: 560, width: 70, height: 90)).fill()
ink.setStroke()
let smile = NSBezierPath(); smile.lineWidth = 46; smile.lineCapStyle = .round
smile.appendArc(withCenter: NSPoint(x: 512, y: 520), radius: 150, startAngle: 200, endAngle: 340)
smile.stroke()
image.unlockFocus()
let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
