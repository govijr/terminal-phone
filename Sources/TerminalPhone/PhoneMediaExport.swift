import AppKit
import AVFoundation
import CoreText
import ImageIO
import TerminalMacCore
import TerminalPhoneCore
import UniformTypeIdentifiers

/// Draws a phone screen onto a canvas: optionally inside the device frame, over a background,
/// under a caption, and cropped to part of the device (what a zoomed-in viewer shows).
/// The background and caption are drawn once, so video frames are cheap.
final class MediaComposer {
    let layout: MediaLayout
    /// The canvas keeps an alpha channel only when a transparent background was asked for.
    let transparent: Bool
    private let style: MediaStyle
    private let landscape: Bool
    /// The portrait device frame in points, when the frame is drawn.
    private let device: DeviceFrame?
    /// Everything that can show, in pixels: the framed device, or the bare screen.
    private let content: (width: Double, height: Double)
    private let base: CGImage
    private let body: CGImage?
    private static let space = CGColorSpace(name: CGColorSpace.sRGB)!

    /// `source` is the screen in pixels; `scale` its pixels per point, which sizes the frame.
    /// `canvas` nil keeps the natural size (of the crop, when there is one).
    init(style: MediaStyle, source: PixelSize, scale: Double, canvas: PixelSize?) throws {
        self.style = style
        landscape = source.landscape
        transparent = style.transparent
        var content = (width: Double(source.width), height: Double(source.height))
        var device: DeviceFrame?
        if let finish = style.frame {
            let portrait = source.oriented(landscape: false)
            let frame = DeviceFrame(screenWidth: Int((Double(portrait.width) / scale).rounded()), screenHeight: Int((Double(portrait.height) / scale).rounded()), finish: finish)
            content = landscape ? (frame.height * scale, frame.width * scale) : (frame.width * scale, frame.height * scale)
            device = frame
        }
        self.content = content; self.device = device
        // The crop is measured on the framed device, so work it out against that frame even when
        // only the screen is drawn.
        let portrait = source.oriented(landscape: false)
        let reference = device ?? DeviceFrame(screenWidth: Int((Double(portrait.width) / scale).rounded()), screenHeight: Int((Double(portrait.height) / scale).rounded()))
        cropReference = reference
        let crop = Self.contentCrop(style.crop, framed: device != nil, landscape: landscape, reference: reference)
        layout = MediaLayout.make(content: (content.width * crop.width, content.height * crop.height), canvas: canvas,
                                  decorated: style.inset, caption: style.caption != nil)

        guard let context = Self.context(layout.canvas, alpha: transparent) else { throw Failure("Cannot allocate a \(layout.canvas) canvas") }
        let height = Double(layout.canvas.height)
        let full = CGRect(x: 0, y: 0, width: layout.canvas.width, height: layout.canvas.height)
        if transparent { context.clear(full) } else { context.setFillColor(.black); context.fill(full) }
        if let background = style.resolvedBackground { try Self.draw(background, in: context, rect: full) }
        if let caption = style.caption, let box = layout.caption {
            let color = style.captionColor ?? (style.resolvedBackground?.topColor.map { MediaBackground.isLight($0) ? 0x111114 : 0xffffff } ?? 0xffffff)
            Self.draw(caption, color: color, in: context, rect: CGRect(x: box.x, y: height - box.y - box.height, width: box.width, height: box.height))
        }
        guard let base = context.makeImage() else { throw Failure("Cannot draw the background") }
        self.base = base
        if let device {
            // Drawn at the screen's own density; each frame scales it into place.
            let black = Self.context(PixelSize(1, 1), alpha: false).flatMap { $0.setFillColor(.black); $0.fill(CGRect(x: 0, y: 0, width: 1, height: 1)); return $0.makeImage() }!
            let renderer = PhoneRenderer(writer: TerminalWriter(), transport: .blocks)
            guard var body = renderer.framed(black, finish: device.finish, width: Int(device.screenWidth), height: Int(device.screenHeight), pixelsPerPoint: scale) else {
                throw Failure("Cannot draw the device frame")
            }
            if landscape, let turned = Self.clockwise(body) { body = turned }
            self.body = body
        } else { body = nil }
    }
    private let cropReference: DeviceFrame

    /// A device crop as fractions of what is drawn. Landscape phones are never cropped.
    private static func contentCrop(_ crop: MediaRect?, framed: Bool, landscape: Bool, reference: DeviceFrame) -> MediaRect {
        guard let crop, !landscape else { return MediaCrop.whole }
        return framed ? crop : MediaCrop.screen(crop, in: reference)
    }

    /// Where things land for one crop, in canvas pixels with a top-left origin: the visible
    /// part, the whole device (which may reach past the canvas), and the screen within it.
    private func geometry(_ crop: MediaRect?) -> (visible: MediaRect, device: MediaRect, screen: MediaRect) {
        let c = Self.contentCrop(crop, framed: device != nil, landscape: landscape, reference: cropReference)
        let placed = crop == style.crop ? layout.content
            : MediaLayout.make(content: (content.width * c.width, content.height * c.height), canvas: layout.canvas, decorated: style.inset, caption: style.caption != nil).content
        let width = placed.width / c.width, height = placed.height / c.height
        let whole = MediaRect(x: placed.x - c.x * width, y: placed.y - c.y * height, width: width, height: height)
        guard let frame = device else { return (placed, whole, whole) }
        // Fractions of the portrait body; a landscape phone is the body turned clockwise.
        let fx = frame.screenX / frame.width, fy = frame.screenY / frame.height
        let fw = frame.screenWidth / frame.width, fh = frame.screenHeight / frame.height
        let screen = landscape
            ? MediaRect(x: whole.x + (1 - fy - fh) * whole.width, y: whole.y + fx * whole.height, width: fh * whole.width, height: fw * whole.height)
            : MediaRect(x: whole.x + fx * whole.width, y: whole.y + fy * whole.height, width: fw * whole.width, height: fh * whole.height)
        return (placed, whole, screen)
    }

    /// Draws the whole picture with `screen` in place, cropped to `crop` (the style's by default).
    func draw(_ screen: CGImage, crop: MediaRect?? = nil, into context: CGContext) {
        let g = geometry(crop ?? style.crop)
        let height = Double(layout.canvas.height)
        func cg(_ r: MediaRect) -> CGRect { CGRect(x: r.x, y: height - r.y - r.height, width: r.width, height: r.height) }
        let canvas = CGRect(x: 0, y: 0, width: layout.canvas.width, height: layout.canvas.height)
        context.interpolationQuality = .high
        if transparent { context.clear(canvas) }
        context.draw(base, in: canvas)
        context.saveGState()
        context.clip(to: cg(g.visible).intersection(canvas))
        if let body { context.draw(body, in: cg(g.device)) }
        let rect = cg(g.screen)
        // The screen's corners are rounded wherever they can be seen against something.
        let rounded = device != nil || (style.background != nil && !layout.fills)
        if rounded {
            let radius = 0.137 * min(rect.width, rect.height)
            context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)); context.clip()
        }
        context.draw(screen, in: rect)
        context.restoreGState()
    }

    func image(_ screen: CGImage) throws -> CGImage {
        guard let context = Self.context(layout.canvas, alpha: transparent) else { throw Failure("Cannot allocate a \(layout.canvas) canvas") }
        draw(screen, into: context)
        guard let image = context.makeImage() else { throw Failure("Cannot compose the screenshot") }
        return image
    }

    /// PNG or JPEG by extension. Only a transparent composition has an alpha channel, and JPEG cannot hold one.
    static func write(_ image: CGImage, to url: URL) throws {
        let jpeg = ["jpg", "jpeg"].contains(url.pathExtension.lowercased())
        if jpeg, image.alphaInfo != .noneSkipLast, image.alphaInfo != .none { throw Failure("A transparent background needs a .png file") }
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, (jpeg ? UTType.jpeg : UTType.png).identifier as CFString, 1, nil) else { throw Failure("Cannot write \(url.path)") }
        CGImageDestinationAddImage(destination, image, (jpeg ? [kCGImageDestinationLossyCompressionQuality: 0.95] : [:]) as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw Failure("Cannot write \(url.path)") }
    }

    /// Opaque RGB unless `alpha`: App Store Connect rejects images with an alpha channel.
    static func context(_ size: PixelSize, alpha: Bool) -> CGContext? {
        let info = alpha ? CGImageAlphaInfo.premultipliedLast : CGImageAlphaInfo.noneSkipLast
        let context = CGContext(data: nil, width: size.width, height: size.height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                bitmapInfo: info.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
        context?.interpolationQuality = .high
        return context
    }

    private static func cg(_ hex: UInt32) -> CGColor {
        CGColor(srgbRed: Double(hex >> 16 & 255) / 255, green: Double(hex >> 8 & 255) / 255, blue: Double(hex & 255) / 255, alpha: 1)
    }

    private static func draw(_ background: MediaBackground, in context: CGContext, rect: CGRect) throws {
        switch background {
        case .transparent: break
        case .solid(let color): context.setFillColor(cg(color)); context.fill(rect)
        case .gradient(let top, let bottom):
            guard let gradient = CGGradient(colorsSpace: space, colors: [cg(top), cg(bottom)] as CFArray, locations: [0, 1]) else { return }
            context.drawLinearGradient(gradient, start: CGPoint(x: rect.midX, y: rect.maxY), end: CGPoint(x: rect.midX, y: rect.minY), options: [])
        case .image(let path):
            guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                throw Failure("Cannot read the background image \(path)")
            }
            let scale = max(rect.width / Double(image.width), rect.height / Double(image.height))
            let w = Double(image.width) * scale, h = Double(image.height) * scale
            context.draw(image, in: CGRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h))
        }
    }

    /// Bold, centred, shrunk until it fits the band.
    private static func draw(_ text: String, color: UInt32, in context: CGContext, rect: CGRect) {
        let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .center; paragraph.lineBreakMode = .byWordWrapping
        var size = min(rect.width * 0.11, rect.height * 0.42)
        var setter: CTFramesetter, fitted: CGSize
        repeat {
            let attributed = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: size, weight: .bold), .paragraphStyle: paragraph,
                                                                           .foregroundColor: NSColor(cgColor: cg(color)) ?? .white])
            setter = CTFramesetterCreateWithAttributedString(attributed)
            fitted = CTFramesetterSuggestFrameSizeWithConstraints(setter, CFRange(), nil, CGSize(width: rect.width, height: .greatestFiniteMagnitude), nil)
            size *= 0.92
        } while fitted.height > rect.height && size > 8
        let box = CGRect(x: rect.minX, y: rect.midY - fitted.height / 2, width: rect.width, height: fitted.height.rounded(.up) + 1)
        context.saveGState(); context.textMatrix = .identity
        CTFrameDraw(CTFramesetterCreateFrame(setter, CFRange(), CGPath(rect: box, transform: nil), nil), context)
        context.restoreGState()
    }

    /// Turns an image a quarter turn clockwise.
    private static func clockwise(_ image: CGImage) -> CGImage? {
        guard let context = CGContext(data: nil, width: image.height, height: image.width, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return nil }
        context.translateBy(x: 0, y: Double(image.width)); context.rotate(by: -.pi / 2)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()
    }

    /// Pixels per point for a screen of unknown origin: 3 for modern iPhones, 2 for iPads and older iPhones.
    static func guessScale(_ size: PixelSize) -> Double {
        let portrait = size.oriented(landscape: false)
        return portrait.width >= 1000 && portrait.aspect < 0.6 ? 3 : 2
    }

    static func decode(_ data: Data) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw Failure("The phone returned an invalid screenshot")
        }
        return image
    }
}

/// Re-encodes a recording through a `MediaComposer`: constant 30 fps H.264, and for App Store
/// previews the accepted size, 10–12 Mbps, High Profile 4.0 and a silent stereo AAC track.
enum MediaVideoExport {
    struct Result { let size: PixelSize; let seconds: Double; let warnings: [String] }

    /// `pointWidth` is the screen's short side in points, which sizes the frame; without it the
    /// scale is guessed from the pixels.
    /// `recordedSeconds` is how long the recording ran: simulators stop writing frames while the
    /// screen is still, so the movie can end early and its last frame is held to that length.
    /// `crops` follows a zoomed viewer as it pans: each crop applies from its time (seconds into
    /// the recording) until the next; before the first, `style.crop` applies.
    static func export(_ movie: URL, to output: URL, style: MediaStyle, pointWidth: Double?, recordedSeconds: Double? = nil, maxSeconds: Double? = nil,
                       crops: [(time: Double, crop: MediaRect?)] = []) async throws -> Result {
        if style.transparent, output.pathExtension.lowercased() != "mov" { throw Failure("A transparent background needs a .mov file (HEVC with alpha)") }
        let asset = AVURLAsset(url: movie)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw Failure("\(movie.lastPathComponent) has no video") }
        let natural = try await track.load(.naturalSize)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else { throw Failure("The recording is empty") }
        let source = PixelSize(Int(natural.width.rounded()), Int(natural.height.rounded()))
        var warnings: [String] = []
        let canvas: PixelSize?, appStore: Bool
        if case .appStore(let display) = style.size {
            canvas = (display ?? AppStoreDisplay.auto(for: source)).previewSize(landscape: source.landscape); appStore = true
        } else { canvas = nil; appStore = false }
        let short = Double(min(source.width, source.height))
        let scale = pointWidth.map { short / $0 } ?? MediaComposer.guessScale(source)
        let composer = try MediaComposer(style: style, source: source, scale: scale, canvas: canvas)
        let size = composer.layout.canvas
        let limit = min(max(duration, recordedSeconds ?? 0), maxSeconds ?? .infinity)
        if limit < max(duration, recordedSeconds ?? 0) { warnings.append("Trimmed to the first \(Int(limit)) s: App Store Connect accepts previews of at most 30 seconds.") }
        if appStore { warnings += AppPreviewRules.warnings(seconds: limit) }

        let reader = try AVAssetReader(asset: asset)
        let frames = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        frames.alwaysCopiesSampleData = false
        guard reader.canAdd(frames) else { throw Failure("Cannot read \(movie.lastPathComponent)") }
        reader.add(frames)

        try? FileManager.default.removeItem(at: output)
        let type: AVFileType = switch output.pathExtension.lowercased() { case "mp4": .mp4; case "m4v": .m4v; default: .mov }
        let writer = try AVAssetWriter(outputURL: output, fileType: type)
        let fps = AppPreviewRules.framesPerSecond
        let bitRate = appStore ? AppPreviewRules.bitRate : max(6_000_000, min(40_000_000, size.width * size.height * fps / 7))
        // Transparency needs HEVC with alpha (QuickTime, Safari, Final Cut, Keynote); everything else is H.264.
        var compression: [String: Any] = [AVVideoAverageBitRateKey: bitRate, AVVideoExpectedSourceFrameRateKey: fps, AVVideoMaxKeyFrameIntervalKey: fps]
        if !style.transparent { compression[AVVideoProfileLevelKey] = appStore ? AVVideoProfileLevelH264High40 : AVVideoProfileLevelH264HighAutoLevel }
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: style.transparent ? AVVideoCodecType.hevcWithAlpha : AVVideoCodecType.h264, AVVideoWidthKey: size.width, AVVideoHeightKey: size.height,
            AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2, AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                                        AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2],
            AVVideoCompressionPropertiesKey: compression
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: size.width, kCVPixelBufferHeightKey as String: size.height])
        guard writer.canAdd(video) else { throw Failure("Cannot encode a \(size) video") }
        writer.add(video)
        let audio = appStore ? try SilentAudio() : nil
        if let audio { guard writer.canAdd(audio.input) else { throw Failure("Cannot add the audio track") }; writer.add(audio.input) }

        guard reader.startReading() else { throw Failure("Cannot read \(movie.lastPathComponent): \(reader.error?.localizedDescription ?? "unknown error")") }
        guard writer.startWriting() else { throw Failure("Cannot write \(output.path): \(writer.error?.localizedDescription ?? "unknown error")") }
        writer.startSession(atSourceTime: .zero)
        defer { if reader.status == .reading { reader.cancelReading() } }

        // Simulators only write a frame when the screen changes, so each output frame shows the
        // newest source frame at or before its time, and an unchanged frame reuses its buffer.
        let count = max(1, Int((limit * Double(fps)).rounded(.down)))
        var next = frames.copyNextSampleBuffer()
        let start = next.map { CMSampleBufferGetPresentationTimeStamp($0).seconds } ?? 0
        var current: CGImage?, changed = true, last: CVPixelBuffer?
        var crop: MediaRect? = style.crop, cropIndex = 0
        var index = 0, audioFrames = 0, videoDone = false, audioDone = audio == nil
        let totalAudio = Int(Double(count) / Double(fps) * Double(SilentAudio.rate))
        var progressAt = Date()
        do {
            while !videoDone || !audioDone {
                var moved = false
                if !videoDone, video.isReadyForMoreMediaData {
                    let time = Double(index) / Double(fps)
                    while let sample = next, CMSampleBufferGetPresentationTimeStamp(sample).seconds - start <= time + 0.0005 {
                        if let image = image(sample) { current = image; changed = true }
                        next = frames.copyNextSampleBuffer()
                    }
                    while cropIndex < crops.count, crops[cropIndex].time <= time + 0.0005 {
                        if crops[cropIndex].crop != crop { crop = crops[cropIndex].crop; changed = true }
                        cropIndex += 1
                    }
                    if changed || last == nil {
                        guard let pool = adaptor.pixelBufferPool, let buffer = render(current, crop: crop, composer: composer, pool: pool) else { throw Failure("Cannot allocate video frames") }
                        last = buffer; changed = false
                    }
                    guard adaptor.append(last!, withPresentationTime: CMTime(value: CMTimeValue(index), timescale: CMTimeScale(fps))) else {
                        throw Failure("Cannot encode the video: \(writer.error?.localizedDescription ?? "unknown error")")
                    }
                    index += 1; moved = true
                    // Finish each track as soon as it is complete: the writer interleaves tracks and
                    // would otherwise wait for more of one before accepting the other.
                    if index == count { video.markAsFinished(); videoDone = true }
                }
                if !audioDone, let audio, audio.input.isReadyForMoreMediaData,
                   videoDone || Double(audioFrames) / Double(SilentAudio.rate) <= Double(index) / Double(fps) + 1 {
                    let length = min(SilentAudio.chunk, totalAudio - audioFrames)
                    guard let sample = audio.silence(frames: length, at: audioFrames), audio.input.append(sample) else {
                        throw Failure("Cannot encode the audio track: \(writer.error?.localizedDescription ?? "unknown error")")
                    }
                    audioFrames += length; moved = true
                    if audioFrames >= totalAudio { audio.input.markAsFinished(); audioDone = true }
                }
                if writer.status == .failed { throw Failure("Cannot encode the video: \(writer.error?.localizedDescription ?? "unknown error")") }
                if moved { progressAt = Date() }
                else {
                    guard Date().timeIntervalSince(progressAt) < 15 else { throw Failure("Encoding stalled at frame \(index) of \(count)") }
                    usleep(1_000)
                }
            }
            writer.endSession(atSourceTime: CMTime(value: CMTimeValue(count), timescale: CMTimeScale(fps)))
            await writer.finishWriting()
            guard writer.status == .completed else { throw Failure("Cannot finish \(output.path): \(writer.error?.localizedDescription ?? "unknown error")") }
        } catch {
            // Never leave a half-written movie behind: it has no index and no player opens it.
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: output)
            throw error
        }
        return Result(size: size, seconds: Double(count) / Double(fps), warnings: warnings)
    }

    private static func image(_ sample: CMSampleBuffer) -> CGImage? {
        guard let buffer = CMSampleBufferGetImageBuffer(sample) else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly); defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        return CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer), bitsPerComponent: 8,
                         bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                         bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)?.makeImage()
    }

    private static func render(_ screen: CGImage?, crop: MediaRect?, composer: MediaComposer, pool: CVPixelBufferPool) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, []); defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer), bitsPerComponent: 8,
                                      bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: (composer.transparent ? CGImageAlphaInfo.premultipliedFirst : .noneSkipFirst).rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        if let screen { composer.draw(screen, crop: .some(crop), into: context) }
        else { context.setFillColor(.black); context.fill(CGRect(x: 0, y: 0, width: composer.layout.canvas.width, height: composer.layout.canvas.height)) }
        return buffer
    }
}

/// A silent stereo track: App Store Connect expects previews to carry 256 kbps stereo AAC.
private final class SilentAudio {
    static let rate = 44_100, chunk = 4_410
    let input: AVAssetWriterInput
    private let format: CMAudioFormatDescription

    init() throws {
        var description = AudioStreamBasicDescription(mSampleRate: Double(Self.rate), mFormatID: kAudioFormatLinearPCM,
                                                      mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
                                                      mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 2, mBitsPerChannel: 16, mReserved: 0)
        var format: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(allocator: nil, asbd: &description, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
                                             extensions: nil, formatDescriptionOut: &format) == noErr, let format else { throw Failure("Cannot describe the audio track") }
        self.format = format
        var layout = AudioChannelLayout(); layout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo
        input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVNumberOfChannelsKey: 2, AVSampleRateKey: Self.rate, AVEncoderBitRateKey: 256_000,
            AVChannelLayoutKey: Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size)
        ], sourceFormatHint: format)
        input.expectsMediaDataInRealTime = false
    }

    func silence(frames: Int, at start: Int) -> CMSampleBuffer? {
        let bytes = frames * 4
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil, customBlockSource: nil,
                                                 offsetToData: 0, dataLength: bytes, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block) == noErr, let block,
              CMBlockBufferFillDataBytes(with: 0, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes) == noErr else { return nil }
        var sample: CMSampleBuffer?
        guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: frames,
                                                                   presentationTimeStamp: CMTime(value: CMTimeValue(start), timescale: CMTimeScale(Self.rate)),
                                                                   packetDescriptions: nil, sampleBufferOut: &sample) == noErr else { return nil }
        return sample
    }
}
