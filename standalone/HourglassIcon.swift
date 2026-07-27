import AppKit

// A template hourglass image; sand level = remaining/window, quantized to whole hours
// so it visibly changes about once per hour.
//   scaleY — flip about the horizontal axis (1 upright, 0 edge-on, -1 upside down).
//   angle  — true rotation (for the resetting spinner).
//   spinning — draw in a square canvas so rotation never clips and the width stays fixed.
func hourglassImage(remaining: Int, windowHours: Int,
                    scaleY: CGFloat = 1, angle: CGFloat = 0, spinning: Bool = false) -> NSImage {
    let hoursLeft = max(0, Int(ceil(Double(remaining) / 3600.0)))
    let frac = min(1.0, Double(min(hoursLeft, windowHours)) / Double(max(1, windowHours)))
    let bw: CGFloat = 11, bh: CGFloat = 15, line: CGFloat = 1.1
    let size = spinning ? NSSize(width: 21, height: 21) : NSSize(width: bw, height: bh)
    let img = NSImage(size: size)
    img.lockFocus()
    defer { img.unlockFocus(); img.isTemplate = true }
    guard let ctx = NSGraphicsContext.current?.cgContext else { return img }
    // Transform about the canvas center: rotate, then vertical scale (flip).
    ctx.translateBy(x: size.width / 2, y: size.height / 2)
    if angle != 0 { ctx.rotate(by: angle) }
    if scaleY != 1 { ctx.scaleBy(x: 1, y: scaleY == 0 ? 0.001 : scaleY) }
    ctx.translateBy(x: -size.width / 2, y: -size.height / 2)
    // Hourglass geometry inside its bw×bh box, centered in the (possibly square) canvas.
    let ox = (size.width - bw) / 2, oy = (size.height - bh) / 2, p = line + 0.5
    let cx = ox + bw / 2, cy = oy + bh / 2, topY = oy + bh - p, botY = oy + p, capL = ox + p, capR = ox + bw - p
    NSColor.black.setStroke(); NSColor.black.setFill()
    let top = NSBezierPath()
    top.move(to: NSPoint(x: capL, y: topY)); top.line(to: NSPoint(x: capR, y: topY)); top.line(to: NSPoint(x: cx, y: cy)); top.close()
    let bot = NSBezierPath()
    bot.move(to: NSPoint(x: capL, y: botY)); bot.line(to: NSPoint(x: capR, y: botY)); bot.line(to: NSPoint(x: cx, y: cy)); bot.close()
    ctx.saveGState(); top.addClip()
    NSBezierPath(rect: NSRect(x: ox, y: cy, width: bw, height: CGFloat(frac) * (topY - cy))).fill()
    ctx.restoreGState()
    ctx.saveGState(); bot.addClip()
    NSBezierPath(rect: NSRect(x: ox, y: botY, width: bw, height: CGFloat(1 - frac) * (cy - botY))).fill()
    ctx.restoreGState()
    top.lineWidth = line; top.stroke(); bot.lineWidth = line; bot.stroke()
    let caps = NSBezierPath(); caps.lineWidth = line
    caps.move(to: NSPoint(x: capL - line / 2, y: topY)); caps.line(to: NSPoint(x: capR + line / 2, y: topY))
    caps.move(to: NSPoint(x: capL - line / 2, y: botY)); caps.line(to: NSPoint(x: capR + line / 2, y: botY))
    caps.stroke()
    return img
}
