import AVFoundation
import CoreGraphics
import ImageIO
import TerminalMacCore
import TerminalPhoneCore
import UniformTypeIdentifiers

/// Records a phone: the screen as a movie, and every input during it as a replayable flow.
/// Simulators record with simctl; real iPhones record WebDriverAgent's MJPEG stream.
@MainActor
final class PhoneRecording {
    let phone: Phone
    let movie: URL
    let started = Date()
    private let cli: PhoneCLI
    private var process: Process?
    private var reader: MJPEGReader?
    private var writer: JPEGMovieWriter?

    private init(cli: PhoneCLI, phone: Phone, movie: URL) { self.cli = cli; self.phone = phone; self.movie = movie }

    static func start(cli: PhoneCLI, phone: Phone, movie: URL) async throws -> PhoneRecording {
        let recording = PhoneRecording(cli: cli, phone: phone, movie: movie)
        if phone.isDevice {
            let agent = try await PhoneDevices.connect(cli, phone, progress: false)
            // Stream settings apply to new connections only, so a viewer's stream is left alone.
            try await agent.configureStream(scale: DeviceLiveSession.maxScale, quality: 70)
            let writer = try JPEGMovieWriter(url: movie)
            recording.writer = writer
            recording.reader = MJPEGReader(url: WebDriverAgent.url(host: agent.host, port: WebDriverAgent.mjpegPort),
                                           onFrame: { writer.append($0) }, onEnd: { _ in })
        } else {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: cli.xcrun)
            process.arguments = ["simctl", "io", phone.udid, "recordVideo", "--codec=h264", "--force", movie.path]
            process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            try process.run()
            recording.process = process
        }
        return recording
    }

    /// Finishes the movie (waiting up to a few seconds) and writes the flow next to it.
    /// Returns the flow's location, or nil when nothing was done to the phone.
    @discardableResult
    func stop(flowNextTo base: URL? = nil) -> URL? {
        if let process {
            // simctl finishes writing the movie when interrupted.
            process.interrupt()
            let deadline = Date().addingTimeInterval(5)
            while process.isRunning && Date() < deadline { usleep(20_000) }
            self.process = nil
        }
        reader?.cancel(); reader = nil
        writer?.finish(); writer = nil
        guard let directory = try? cli.store.directory(phone.name) else { return nil }
        let entries = PhoneActionLog.read(PhoneActionLog.url(in: directory), since: started)
        guard !entries.isEmpty else { return nil }
        let flow = (base ?? movie).deletingPathExtension().appendingPathExtension("flow.yaml")
        let stamp = ISO8601DateFormatter().string(from: started)
        let header = "Recorded from \(phone.name) (\(phone.displayModel)) at \(stamp).\nReplay: terminal-phone replay --phone \(phone.name) '\(flow.lastPathComponent)'"
        do { try PhoneFlow.render(entries, header: header).write(to: flow, atomically: true, encoding: .utf8); return flow }
        catch { return nil }
    }

    /// Converts a movie to an animated GIF, about 10 frames a second and at most 360 points wide.
    static func gif(from movie: URL, to output: URL, fps: Double = 10, maxWidth: Double = 360) async throws {
        let asset = AVURLAsset(url: movie)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else { throw Failure("The recording is empty") }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxWidth * 2, height: maxWidth * 4)
        let tolerance = CMTime(seconds: 0.5 / fps, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance; generator.requestedTimeToleranceAfter = tolerance
        let count = max(1, Int(duration * fps))
        guard let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.gif.identifier as CFString, count, nil) else { throw Failure("Cannot write \(output.path)") }
        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let delay = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1 / fps, kCGImagePropertyGIFUnclampedDelayTime: 1 / fps]] as CFDictionary
        for index in 0..<count {
            let (image, _) = try await generator.image(at: CMTime(seconds: Double(index) / fps, preferredTimescale: 600))
            CGImageDestinationAddImage(destination, image, delay)
        }
        guard CGImageDestinationFinalize(destination) else { throw Failure("Cannot finish \(output.path)") }
    }
}

/// Writes JPEG frames as they arrive into an H.264 QuickTime movie, timed by arrival.
/// Frames that arrive while the encoder is busy are dropped rather than queued.
final class JPEGMovieWriter: @unchecked Sendable {
    private let url: URL
    private let queue = DispatchQueue(label: "terminal-phone.movie")
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var start: CFAbsoluteTime?, last = CMTime.zero
    private var finished = false

    init(url: URL) throws {
        self.url = url
        try? FileManager.default.removeItem(at: url)
    }

    func append(_ jpeg: Data) {
        let now = CFAbsoluteTimeGetCurrent()
        queue.async { [self] in
            guard !finished, let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return }
            if writer == nil { open(width: image.width, height: image.height) }
            guard let writer, let input, let adaptor, writer.status == .writing, input.isReadyForMoreMediaData,
                  let pool = adaptor.pixelBufferPool else { return }
            let first = start == nil
            if first { start = now; writer.startSession(atSourceTime: .zero) }
            let time = CMTime(seconds: now - start!, preferredTimescale: 600)
            guard first || time > last else { return }
            var buffer: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let buffer else { return }
            CVPixelBufferLockBaseAddress(buffer, [])
            let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer),
                                    bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            context?.draw(image, in: CGRect(x: 0, y: 0, width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer)))
            CVPixelBufferUnlockBaseAddress(buffer, [])
            if adaptor.append(buffer, withPresentationTime: time) { last = time }
        }
    }

    private func open(width: Int, height: Int) {
        // H.264 wants even dimensions.
        let width = width & ~1, height = height & ~1
        guard width > 0, height > 0, let writer = try? AVAssetWriter(outputURL: url, fileType: .mov) else { return }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height])
        input.expectsMediaDataInRealTime = true
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height])
        guard writer.canAdd(input) else { return }
        writer.add(input)
        guard writer.startWriting() else { return }
        self.writer = writer; self.input = input; self.adaptor = adaptor
    }

    /// Blocks until the movie is written, at most a few seconds.
    func finish() {
        let done = DispatchSemaphore(value: 0)
        queue.async { [self] in
            finished = true
            guard let writer, let input, writer.status == .writing else { done.signal(); return }
            input.markAsFinished()
            writer.endSession(atSourceTime: last)
            writer.finishWriting { done.signal() }
        }
        _ = done.wait(timeout: .now() + 10)
    }
}
