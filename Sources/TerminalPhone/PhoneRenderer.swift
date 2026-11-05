import CoreGraphics
import CPhoneShim
import Darwin
import Foundation
import ImageIO
import TerminalPhoneCore
import UniformTypeIdentifiers

enum GraphicsTransport: String {
    /// Raw pixels in POSIX shared memory: no encoding, no base64, nothing through the pty.
    case kittySharedMemory = "shm"
    /// PNG chunks through the pty, for kitty-protocol terminals without shared memory.
    case kittyDirect = "png"
    case iterm = "iterm"
    /// Half-block text, for terminals without inline images.
    case blocks = "blocks"
}

/// How escapes reach the terminal: directly, or through tmux.
struct RenderTarget: Equatable {
    /// Wrap image escapes in tmux passthrough.
    var tmux = false
    /// Kitty images as Unicode placeholder text, which tmux keeps on screen like any text.
    var placeholders = false
    var depth = ColorDepth.truecolor
}

struct FramePlacement: Equatable {
    let viewport: PhoneViewport
    /// Opaque fill for transports without alpha (iTerm2 JPEG). Kitty gets transparent corners.
    let background: UInt32?
    /// Cells covered by a menu, which image text (blocks, placeholders) must not overwrite.
    var mask: CellRect? = nil
}

/// Turns video frames into terminal graphics on a background queue. Only the newest frame is
/// kept: if the terminal falls behind, stale frames are dropped rather than queued.
final class PhoneRenderer: @unchecked Sendable {
    struct Stats { var frames = 0; var milliseconds = 0.0; var sourceWidth = 0; var sourceHeight = 0 }
    private let queue = DispatchQueue(label: "terminal-phone.render", qos: .userInteractive)
    private let writer: TerminalWriter
    private let lock = NSLock()
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    /// An empty frame draws the device with a dark screen, before video arrives.
    private var pending: Data?, last: Data?, force = false
    private var busy = false
    private var placement: FramePlacement?
    private var transport: GraphicsTransport
    private var target: RenderTarget
    private var stats = Stats()
    // Only touched on `queue`.
    private var imageID = 0, sequence = 0
    private var drawn: (frame: Data, placement: FramePlacement)?
    private var blocks: HalfBlocks?

    init(writer: TerminalWriter, transport: GraphicsTransport, target: RenderTarget = RenderTarget()) {
        self.writer = writer; self.transport = transport; self.target = target
    }

    var currentStats: Stats { lock.withLock { stats } }
    var currentTransport: GraphicsTransport { lock.withLock { transport } }
    var currentTarget: RenderTarget { lock.withLock { target } }
    func configure(placement: FramePlacement?, transport: GraphicsTransport? = nil, target: RenderTarget? = nil) {
        lock.withLock {
            self.placement = placement
            if let transport { self.transport = transport }
            if let target { self.target = target }
        }
    }
    /// Safe to call from any thread, including the video reader.
    func submit(_ frame: Data, force: Bool = false) {
        let start = lock.withLock { () -> Bool in
            pending = frame; self.force = self.force || force
            if busy { return false }
            busy = true; return true
        }
        if start { queue.async { self.drain() } }
    }
    /// Draws the last frame again, for example after a resize or screen clear.
    func redraw() { submit(lock.withLock { last } ?? Data(), force: true) }
    /// Forgets the current video, for example when switching phones.
    func reset() { lock.withLock { last = nil; pending = nil }; submit(Data(), force: true) }
    /// Removes both double-buffered images. Call before leaving the alternate screen.
    func clear() -> String {
        queue.sync {}
        guard [.kittySharedMemory, .kittyDirect].contains(currentTransport) else { return "" }
        let delete = "\u{1b}_Ga=d,d=I,i=2,q=2;\u{1b}\\\u{1b}_Ga=d,d=I,i=3,q=2;\u{1b}\\"
        return currentTarget.tmux ? TerminalProfile.tmuxPassthrough("\u{1b}_Ga=d,d=I,i=2,q=2;\u{1b}\\") + TerminalProfile.tmuxPassthrough("\u{1b}_Ga=d,d=I,i=3,q=2;\u{1b}\\") : delete
    }

    private func drain() {
        while true {
            let next = lock.withLock { () -> (Data, FramePlacement?, GraphicsTransport, RenderTarget, Bool)? in
                guard let frame = pending else { busy = false; return nil }
                pending = nil; if !frame.isEmpty { last = frame }
                defer { force = false }
                return (frame, placement, transport, target, force)
            }
            guard let (frame, placement, transport, target, force) = next, let placement else { if next == nil { return } else { continue } }
            // The simulator streams continuously; identical frames cost nothing.
            if !force, let drawn, drawn.placement == placement, drawn.frame == frame { continue }
            autoreleasepool {
                let started = DispatchTime.now().uptimeNanoseconds
                var image: CGImage?
                if !frame.isEmpty {
                    guard let source = CGImageSourceCreateWithData(frame as CFData, nil),
                          let decoded = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { return }
                    image = decoded
                }
                guard let escape = encode(image, placement: placement, transport: transport, target: target, force: force) else { return }
                writer.writeAndWait("\u{1b}[\(placement.viewport.row);\(placement.viewport.column)H" + escape)
                drawn = (frame, placement)
                guard let image else { return }
                let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
                lock.withLock {
                    stats.frames += 1; stats.sourceWidth = image.width; stats.sourceHeight = image.height
                    stats.milliseconds = stats.milliseconds == 0 ? elapsed : stats.milliseconds * 0.8 + elapsed * 0.2
                }
            }
        }
    }

    /// A screenshot inside the device frame, with transparent corners. `pixelsPerPoint` is
    /// usually the screen's own scale, so the screen keeps its native sharpness.
    func framed(_ image: CGImage, finish: FrameFinish, width points: Int, height pointsHigh: Int, pixelsPerPoint: Double) -> CGImage? {
        let frame = DeviceFrame(screenWidth: points, screenHeight: pointsHigh, finish: finish)
        let viewport = PhoneViewport(frame: frame, column: 1, row: 1, columns: 1, rows: 1,
                                     cellWidth: (frame.width * pixelsPerPoint).rounded(.up), cellHeight: (frame.height * pixelsPerPoint).rounded(.up))
        let placement = FramePlacement(viewport: viewport, background: nil)
        guard let context = context(placement, data: nil) else { return nil }
        compose(image, placement: placement, into: context)
        return context.makeImage()
    }

    private func context(_ placement: FramePlacement, data: UnsafeMutableRawPointer?) -> CGContext? {
        let v = placement.viewport
        let context = CGContext(data: data, width: v.canvasWidth, height: v.canvasHeight, bitsPerComponent: 8,
                                bytesPerRow: v.canvasWidth * 4, space: colorSpace,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
        context?.interpolationQuality = .high
        return context
    }

    private static func color(_ hex: UInt32, _ alpha: Double = 1) -> CGColor {
        CGColor(srgbRed: Double(hex >> 16 & 255) / 255, green: Double(hex >> 8 & 255) / 255, blue: Double(hex & 255) / 255, alpha: alpha)
    }
    private static func mix(_ a: UInt32, _ b: UInt32, _ t: Double) -> UInt32 {
        func channel(_ shift: UInt32) -> UInt32 {
            let from = Double((a >> shift) & 255), to = Double((b >> shift) & 255)
            let value: Double = from * (1 - t) + to * t
            return UInt32(value.rounded()) << shift
        }
        return channel(16) | channel(8) | channel(0)
    }
    /// Draws the metal body, bezel, side buttons and the rounded screen.
    private func compose(_ image: CGImage?, placement: FramePlacement, into context: CGContext) {
        let v = placement.viewport, f = v.frame, s = v.scale, height = Double(v.canvasHeight)
        if let background = placement.background {
            context.setFillColor(Self.color(background)); context.fill(CGRect(x: 0, y: 0, width: v.canvasWidth, height: v.canvasHeight))
        } else { context.clear(CGRect(x: 0, y: 0, width: v.canvasWidth, height: v.canvasHeight)) }
        // Device points (top-left origin) to canvas pixels (bottom-left origin).
        func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> CGRect {
            CGRect(x: v.originX + x * s, y: height - (v.originY + (y + h) * s), width: w * s, height: h * s)
        }
        func rounded(_ r: CGRect, _ radius: Double) -> CGPath {
            let radius = min(radius * s, r.width / 2, r.height / 2)
            return CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
        }
        let button = DeviceFrame.button, rim = DeviceFrame.rim, finish = f.finish
        // Side buttons: action, volume up, volume down on the left; side button on the right.
        context.setFillColor(Self.color(finish.buttons))
        for (top, length) in [(0.165, 0.035), (0.225, 0.07), (0.31, 0.07)] {
            context.addPath(rounded(rect(0, f.height * top, button + rim + 1, f.height * length), 1.5))
        }
        context.addPath(rounded(rect(f.width - button - rim - 1, f.height * 0.255, button + rim + 1, f.height * 0.11), 1.5))
        context.fillPath()
        // The metal band: a diagonal sheen, lighter where light falls from the top left, then a
        // polished edge highlight. The black bezel and screen sit on top.
        let body = rect(button, 0, f.width - 2 * button, f.height)
        context.saveGState()
        context.addPath(rounded(body, f.screenRadius + f.inset)); context.clip()
        let sheen = [Self.mix(finish.band, 0xffffff, 0.22), finish.band, Self.mix(finish.band, 0x000000, 0.12), Self.mix(finish.band, 0xffffff, 0.08), Self.mix(finish.band, 0x000000, 0.22)]
        if let gradient = CGGradient(colorsSpace: colorSpace, colors: sheen.map { Self.color($0) } as CFArray, locations: [0, 0.35, 0.6, 0.78, 1]) {
            context.drawLinearGradient(gradient, start: CGPoint(x: body.minX, y: body.maxY), end: CGPoint(x: body.maxX, y: body.minY), options: [])
        } else { context.setFillColor(Self.color(finish.band)); context.fill(body) }
        context.restoreGState()
        context.addPath(rounded(body.insetBy(dx: 0.6 * s, dy: 0.6 * s), f.screenRadius + f.inset - 0.6))
        context.setStrokeColor(Self.color(finish.highlight, 0.7)); context.setLineWidth(max(1, 0.8 * s)); context.strokePath()
        context.addPath(rounded(body.insetBy(dx: rim * s, dy: rim * s), f.screenRadius + DeviceFrame.bezel))
        context.setFillColor(Self.color(0x050506)); context.fillPath()
        // The screen itself.
        let screen = rect(f.screenX, f.screenY, f.screenWidth, f.screenHeight)
        context.saveGState()
        context.addPath(rounded(screen, f.screenRadius)); context.clip()
        if let image { context.draw(image, in: screen) } else { context.setFillColor(Self.color(0x000000)); context.fill(screen) }
        context.restoreGState()
    }

    private func encode(_ image: CGImage?, placement: FramePlacement, transport: GraphicsTransport, target: RenderTarget, force: Bool) -> String? {
        let v = placement.viewport
        let wrap: (String) -> String = target.tmux ? TerminalProfile.tmuxPassthrough : { $0 }
        // The canvas covers whole cells exactly, so the terminal draws it 1:1. The phone sits
        // below cell backgrounds, so menus can draw over it and plain text stays readable on it.
        // In tmux the image is a virtual placement shown by placeholder text instead.
        let placeholders = target.placeholders && transport != .iterm && transport != .blocks
        let box = placeholders ? "U=1,c=\(v.columns),r=\(v.rows)" : "C=1,c=\(v.columns),r=\(v.rows),z=-1073741825"
        let next = imageID == 2 ? 3 : 2
        let replace = imageID == 0 ? "" : wrap("\u{1b}_Ga=d,d=I,i=\(imageID),q=2;\u{1b}\\")
        let cells = placeholders ? KittyPlaceholders.cells(imageID: next, column: v.column, row: v.row, columns: v.columns, rows: v.rows, mask: placement.mask) : ""
        switch transport {
        case .kittySharedMemory:
            sequence += 1
            let name = "/tphone.\(getpid()).\(sequence)", size = v.canvasWidth * v.canvasHeight * 4
            let fd = tp_shm_create(name, size)
            guard fd >= 0 else { return nil }
            defer { close(fd) }
            guard let memory = mmap(nil, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0), memory != MAP_FAILED else { tp_shm_unlink(name); return nil }
            defer { munmap(memory, size) }
            guard let context = context(placement, data: memory) else { tp_shm_unlink(name); return nil }
            compose(image, placement: placement, into: context)
            imageID = next
            // The terminal reads and unlinks the object.
            return wrap("\u{1b}_Ga=T,f=32,t=s,s=\(v.canvasWidth),v=\(v.canvasHeight),S=\(size),i=\(next),q=2,\(box);\(Data(name.utf8).base64EncodedString())\u{1b}\\") + cells + replace
        case .kittyDirect:
            guard let png = encoded(image, placement: placement, type: .png, quality: nil) else { return nil }
            let bytes = Array(png.base64EncodedString().utf8)
            var output = "", offset = 0
            while offset < bytes.count {
                let end = min(offset + 4096, bytes.count)
                let header = offset == 0 ? "a=T,f=100,i=\(next),q=2,\(box)," : ""
                output += wrap("\u{1b}_G\(header)m=\(end < bytes.count ? 1 : 0);\(String(decoding: bytes[offset..<end], as: UTF8.self))\u{1b}\\")
                offset = end
            }
            imageID = next
            return output + cells + replace
        case .iterm:
            guard let jpeg = encoded(image, placement: placement, type: .jpeg, quality: 0.92) else { return nil }
            return wrap("\u{1b}]1337;File=inline=1;width=\(v.columns);height=\(v.rows);preserveAspectRatio=0:\(jpeg.base64EncodedString())\u{7}")
        case .blocks:
            return encodeBlocks(image, placement: placement, depth: target.depth, force: force)
        }
    }

    /// Composes the phone at two pixels per cell and writes only the cells that changed.
    private func encodeBlocks(_ image: CGImage?, placement: FramePlacement, depth: ColorDepth, force: Bool) -> String? {
        let v = placement.viewport, width = v.columns, height = v.rows * 2
        guard width > 0, height > 0 else { return nil }
        if blocks?.columns != width || blocks?.rows != v.rows { blocks = HalfBlocks(columns: width, rows: v.rows) }
        let bytesPerRow = width * 4
        var buffer = [UInt8](repeating: 0, count: bytesPerRow * height)
        let cells: [HalfBlocks.Cell]? = buffer.withUnsafeMutableBytes { raw in
            guard let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: bytesPerRow, space: colorSpace,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return nil }
            context.interpolationQuality = .high
            // Draw in the viewport's canvas units; cells are never square, so scale each axis.
            context.scaleBy(x: Double(width) / Double(v.canvasWidth), y: Double(height) / Double(v.canvasHeight))
            compose(image, placement: FramePlacement(viewport: v, background: nil), into: context)
            context.flush()
            return HalfBlocks.cells(rgba: UnsafeRawBufferPointer(raw), bytesPerRow: bytesPerRow, columns: width, rows: v.rows)
        }
        guard let cells else { return nil }
        return blocks!.render(cells, column: v.column, row: v.row, depth: depth, mask: placement.mask, force: force)
    }

    private func encoded(_ image: CGImage?, placement: FramePlacement, type: UTType, quality: Double?) -> Data? {
        guard let context = context(placement, data: nil) else { return nil }
        compose(image, placement: placement, into: context)
        guard let composed = context.makeImage() else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, composed, quality.map { [kCGImageDestinationLossyCompressionQuality: $0] as CFDictionary })
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }

    /// Asks the terminal whether it can read shared memory. The reply arrives on stdin as
    /// `ESC _ G i=31;OK ESC \`. Returns the escape to send and a cleanup for the probe object.
    static func sharedMemoryProbe() -> (query: String, cleanup: () -> Void)? {
        let name = "/tphone.\(getpid()).probe"
        let fd = tp_shm_create(name, 4)
        guard fd >= 0 else { return nil }
        let pixel: [UInt8] = [0, 0, 0, 255]
        _ = pixel.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, 4) }
        close(fd)
        return ("\u{1b}_Gi=31,s=1,v=1,a=q,t=s,f=32,S=4;\(Data(name.utf8).base64EncodedString())\u{1b}\\", { _ = tp_shm_unlink(name) })
    }
}
