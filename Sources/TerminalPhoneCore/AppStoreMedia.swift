import Foundation

/// A pixel size, always stored as given (portrait or landscape).
public struct PixelSize: Equatable, Hashable, Sendable, CustomStringConvertible {
    public let width: Int, height: Int
    public init(_ width: Int, _ height: Int) { self.width = width; self.height = height }
    public var landscape: Bool { width > height }
    public var swapped: PixelSize { PixelSize(height, width) }
    public var aspect: Double { Double(width) / Double(max(1, height)) }
    /// The same size in the given orientation.
    public func oriented(landscape: Bool) -> PixelSize { self.landscape == landscape ? self : swapped }
    public var description: String { "\(width)x\(height)" }
}

/// App Store Connect display classes, with the screenshot and app preview sizes it accepts.
/// Source: developer.apple.com/help/app-store-connect/reference (screenshot and app preview specifications).
public enum AppStoreDisplay: String, CaseIterable, Sendable {
    case iphone69 = "6.9", iphone65 = "6.5", iphone63 = "6.3", iphone61 = "6.1", iphone55 = "5.5", iphone47 = "4.7"
    case ipad13 = "ipad-13", ipad11 = "ipad-11"

    public var title: String {
        switch self {
        case .iphone69: "iPhone 6.9\" — Dynamic Island, large (17 Pro Max, 16 Pro Max, Air, Plus)"
        case .iphone65: "iPhone 6.5\" — Face ID, large (14 Plus, 13 Pro Max, 11, XR)"
        case .iphone63: "iPhone 6.3\" — Dynamic Island, medium (17 Pro, 17, 16 Pro, 15) — required"
        case .iphone61: "iPhone 6.1\" — Face ID, medium (17e, 16e, 14, 13, 12, X)"
        case .iphone55: "iPhone 5.5\" — Home button, large (8 Plus)"
        case .iphone47: "iPhone 4.7\" — Home button, medium (SE, 8)"
        case .ipad13: "iPad 13\" (iPad Pro, iPad Air 13\") — required for iPad apps"
        case .ipad11: "iPad 11\" (iPad Pro 11\", iPad Air, iPad, iPad mini)"
        }
    }
    public var isPad: Bool { self == .ipad13 || self == .ipad11 }

    /// Accepted screenshot sizes in portrait, preferred (largest) first.
    public var screenshotSizes: [PixelSize] {
        switch self {
        case .iphone69: [PixelSize(1320, 2868), PixelSize(1290, 2796), PixelSize(1260, 2736)]
        case .iphone65: [PixelSize(1284, 2778), PixelSize(1242, 2688)]
        case .iphone63: [PixelSize(1206, 2622), PixelSize(1179, 2556)]
        case .iphone61: [PixelSize(1170, 2532), PixelSize(1125, 2436), PixelSize(1080, 2340)]
        case .iphone55: [PixelSize(1242, 2208)]
        case .iphone47: [PixelSize(750, 1334)]
        case .ipad13: [PixelSize(2064, 2752), PixelSize(2048, 2732)]
        case .ipad11: [PixelSize(1668, 2420), PixelSize(1668, 2388), PixelSize(1640, 2360), PixelSize(1512, 2316), PixelSize(1488, 2266)]
        }
    }

    /// The accepted app preview size in portrait. Previews are not the device's resolution.
    public var previewSize: PixelSize {
        switch self {
        case .iphone69, .iphone65, .iphone63, .iphone61: PixelSize(886, 1920)
        case .iphone55: PixelSize(1080, 1920)
        case .iphone47: PixelSize(750, 1334)
        case .ipad13, .ipad11: PixelSize(1200, 1600)
        }
    }

    /// Accepts "6.9", "6.9in", "6.9-inch", "iphone-6.9", "ipad-13", "13", "ipad13".
    public init?(named raw: String) {
        var key = raw.lowercased().replacingOccurrences(of: "\"", with: "")
        for suffix in ["-inch", "inch", "in"] where key.hasSuffix(suffix) { key = String(key.dropLast(suffix.count)); break }
        if key.hasPrefix("iphone") { key = String(key.dropFirst(6)).trimmingCharacters(in: CharacterSet(charactersIn: "-_ ")) }
        if key == "13" || key == "ipad13" || key == "12.9" { key = "ipad-13" }
        if key == "11" || key == "ipad11" { key = "ipad-11" }
        if key == "6.7" { key = "6.9" }
        guard let match = Self(rawValue: key) else { return nil }
        self = match
    }
    public static var names: String { allCases.map(\.rawValue).joined(separator: ", ") }

    /// The class whose accepted sizes include this screen exactly, in either orientation.
    public static func exact(_ size: PixelSize) -> AppStoreDisplay? {
        let portrait = size.oriented(landscape: false)
        return allCases.first { $0.screenshotSizes.contains(portrait) }
    }
    /// The exact class for this screen, else the largest required class of its shape.
    public static func auto(for size: PixelSize) -> AppStoreDisplay {
        exact(size) ?? (size.oriented(landscape: false).aspect > 0.6 ? .ipad13 : .iphone69)
    }

    /// The screenshot size for a source image: its own size when accepted (no resampling),
    /// otherwise the accepted size closest to its shape, in the source's orientation.
    public func screenshotSize(for source: PixelSize) -> PixelSize {
        let portrait = source.oriented(landscape: false)
        if screenshotSizes.contains(portrait) { return source }
        let best = screenshotSizes.min { abs($0.aspect - portrait.aspect) < abs($1.aspect - portrait.aspect) }!
        return best.oriented(landscape: source.landscape)
    }
    public func previewSize(landscape: Bool) -> PixelSize { previewSize.oriented(landscape: landscape) }
}

/// A rectangle in pixels with a top-left origin.
public struct MediaRect: Equatable, Sendable {
    public var x, y, width, height: Double
    public init(x: Double, y: Double, width: Double, height: Double) { self.x = x; self.y = y; self.width = width; self.height = height }
}

/// Where the phone (its screen, or its framed body) and the caption go on the output canvas.
public struct MediaLayout: Equatable, Sendable {
    public let canvas: PixelSize
    public let content: MediaRect
    public let caption: MediaRect?
    /// True when the screen covers the whole canvas (cropped to fill), with nothing around it.
    public let fills: Bool

    /// `content` is the phone's natural size in pixels. `canvas` nil keeps the natural size,
    /// adding margins only when there is something to show around the phone.
    /// `decorated` means a frame or a background is drawn, so the phone is fitted, not cropped.
    public static func make(content: (width: Double, height: Double), canvas: PixelSize?, decorated: Bool, caption: Bool) -> MediaLayout {
        let cw = max(1, content.width), ch = max(1, content.height)
        guard let canvas else {
            guard decorated || caption else {
                let size = PixelSize(Int(cw.rounded()) & ~1, Int(ch.rounded()) & ~1)
                return MediaLayout(canvas: size, content: MediaRect(x: 0, y: 0, width: Double(size.width), height: Double(size.height)), caption: nil, fills: true)
            }
            let margin = 0.08 * min(cw, ch), band = caption ? 0.2 * (cw < ch ? ch : cw * 0.5) : 0
            let size = PixelSize(Int((cw + 2 * margin).rounded(.up) + 1) & ~1, Int((ch + 2 * margin + band).rounded(.up) + 1) & ~1)
            let x = (Double(size.width) - cw) / 2, y = margin + band
            return MediaLayout(canvas: size, content: MediaRect(x: x, y: y, width: cw, height: ch),
                               caption: caption ? MediaRect(x: margin, y: margin * 0.6, width: Double(size.width) - 2 * margin, height: band) : nil, fills: false)
        }
        let width = Double(canvas.width), height = Double(canvas.height)
        guard decorated || caption else {
            // Aspect fill: the few pixels that differ in shape are cropped, never letterboxed.
            let scale = max(width / cw, height / ch)
            return MediaLayout(canvas: canvas, content: MediaRect(x: (width - cw * scale) / 2, y: (height - ch * scale) / 2, width: cw * scale, height: ch * scale),
                               caption: nil, fills: true)
        }
        let margin = 0.07 * min(width, height)
        let band = caption ? (canvas.landscape ? 0.2 : 0.17) * height : 0
        let area = MediaRect(x: margin, y: margin + band, width: width - 2 * margin, height: height - 2 * margin - band)
        let scale = min(area.width / cw, area.height / ch)
        let placed = MediaRect(x: area.x + (area.width - cw * scale) / 2, y: area.y + (area.height - ch * scale) / 2, width: cw * scale, height: ch * scale)
        return MediaLayout(canvas: canvas, content: placed,
                           caption: caption ? MediaRect(x: margin, y: margin * 0.8, width: width - 2 * margin, height: band) : nil, fills: false)
    }
}

/// What is drawn behind the phone. App Store output is always opaque (App Store Connect
/// rejects alpha); `transparent` is for other uses, as PNG or as a movie with an alpha channel.
public enum MediaBackground: Equatable, Sendable {
    case transparent
    case solid(UInt32)
    /// Top to bottom.
    case gradient(UInt32, UInt32)
    case image(String)

    public static let presets: [(name: String, value: MediaBackground)] = [
        ("light", .gradient(0xf5f5f7, 0xe2e2e8)), ("dark", .gradient(0x1c1c1e, 0x000000)),
        ("midnight", .gradient(0x0b1d3a, 0x3a6df0)), ("sunset", .gradient(0xff7a59, 0xc2185b)),
        ("ocean", .gradient(0x00c6fb, 0x005bea)), ("mint", .gradient(0xd4fc79, 0x96e6a1)),
        ("grape", .gradient(0x8e2de2, 0x4a00e0)), ("white", .solid(0xffffff)), ("black", .solid(0x000000)),
        ("transparent", .transparent)
    ]
    public static var presetNames: String { presets.map(\.name).joined(separator: ", ") }
    public static let standard = presets[0].value

    /// `#1e90ff`, `#0b1d3a,#3a6df0` (a gradient), a preset name, or an image file.
    public static func parse(_ raw: String, fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: ($0 as NSString).expandingTildeInPath) }) -> MediaBackground? {
        let value = raw.trimmingCharacters(in: .whitespaces)
        if let preset = presets.first(where: { $0.name == value.lowercased() }) { return preset.value }
        let parts = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        let colors = parts.compactMap(color)
        if colors.count == parts.count {
            if colors.count == 1 { return .solid(colors[0]) }
            if colors.count == 2 { return .gradient(colors[0], colors[1]) }
        }
        return fileExists(value) ? .image((value as NSString).expandingTildeInPath) : nil
    }
    public static func color(_ raw: String) -> UInt32? {
        var hex = raw.hasPrefix("#") ? String(raw.dropFirst()) : raw
        if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
        guard hex.count == 6, hex.allSatisfy(\.isHexDigit) else { return nil }
        return UInt32(hex, radix: 16)
    }
    /// The colour a caption sits on, to pick black or white text.
    public var topColor: UInt32? {
        switch self { case .solid(let c): c; case .gradient(let top, _): top; case .image, .transparent: nil }
    }
    public static func isLight(_ color: UInt32) -> Bool {
        let r = Double(color >> 16 & 255), g = Double(color >> 8 & 255), b = Double(color & 255)
        return 0.299 * r + 0.587 * g + 0.114 * b > 150
    }
}

/// How an App Store or presentation export looks.
public struct MediaStyle: Equatable, Sendable {
    public enum Size: Equatable, Sendable { case native, appStore(AppStoreDisplay?) }
    public var size: Size
    /// Nil draws the bare screen.
    public var frame: FrameFinish?
    public var background: MediaBackground?
    public var caption: String?
    public var captionColor: UInt32?
    /// The part of the device to show, in fractions of the framed device (see `PhoneViewport.visible`);
    /// nil shows all of it. A zoomed-in viewer passes what it shows.
    public var crop: MediaRect?
    public init(size: Size = .native, frame: FrameFinish? = nil, background: MediaBackground? = nil, caption: String? = nil, captionColor: UInt32? = nil,
                crop: MediaRect? = nil) {
        self.size = size; self.frame = frame; self.background = background; self.caption = caption; self.captionColor = captionColor; self.crop = crop
    }
    public var decorated: Bool { frame != nil || background != nil }
    public var transparent: Bool { background == .transparent }
    /// A frame or caption needs something opaque behind it, unless transparency was asked for.
    public var resolvedBackground: MediaBackground? {
        transparent ? nil : background ?? (decorated || caption != nil ? .standard : nil)
    }
    /// An opaque background shows margins around the phone; a transparent one hugs it.
    public var inset: Bool { resolvedBackground != nil }
    public var plain: Bool { size == .native && !decorated && caption == nil && crop == nil }
}

/// App Store app preview rules that a recording is checked against.
public enum AppPreviewRules {
    public static let minimumSeconds = 15.0, maximumSeconds = 30.0, framesPerSecond = 30
    /// Bits per second: Apple's target is 10–12 Mbps.
    public static let bitRate = 11_000_000
    public static func warnings(seconds: Double) -> [String] {
        seconds < minimumSeconds ? ["App Store Connect needs app previews of at least 15 seconds; this one is \(String(format: "%.1f", seconds)) s. Record longer, e.g. --duration 20."] : []
    }
}

/// The viewer's App Store panel choices, remembered between sessions.
public struct AppStoreSettings: Codable, Equatable, Sendable {
    /// "auto", "shown" (the phone's own size, as the viewer shows it), or an `AppStoreDisplay` raw value.
    public var display: String
    public var frame: Bool
    /// A `MediaBackground` preset name; nil for none.
    public var background: String?
    public var caption: String?
    public init(display: String = "auto", frame: Bool = true, background: String? = "midnight", caption: String? = nil) {
        self.display = display; self.frame = frame; self.background = background; self.caption = caption
    }
    public var chosenDisplay: AppStoreDisplay? { AppStoreDisplay(rawValue: display) }
    public static let displays = ["auto"] + AppStoreDisplay.allCases.map(\.rawValue) + ["shown"]
    public var asShown: Bool { display == "shown" }
    /// App Store Connect rejects transparency, so it is offered only at the phone's own size.
    public static func backgrounds(asShown: Bool) -> [String?] {
        [nil] + MediaBackground.presets.map(\.name).filter { asShown || $0 != "transparent" }
    }
    /// Keeps the background valid after the size changes.
    public mutating func normalize() {
        if !asShown, background == "transparent" { background = nil }
    }

    /// Steps through `options` from `current`, wrapping around.
    public static func step<T: Equatable>(_ options: [T], from current: T, by offset: Int) -> T {
        let index = options.firstIndex(of: current) ?? 0
        return options[((index + offset) % options.count + options.count) % options.count]
    }
    public func style(finish: FrameFinish, crop: MediaRect? = nil) -> MediaStyle {
        var settings = self; settings.normalize()
        return MediaStyle(size: asShown ? .native : .appStore(chosenDisplay), frame: frame ? finish : nil,
                          background: settings.background.flatMap { name in MediaBackground.presets.first { $0.name == name }?.value }, caption: caption, crop: crop)
    }
}

/// Converting a crop of the framed device into a crop of what is actually drawn.
public enum MediaCrop {
    public static let whole = MediaRect(x: 0, y: 0, width: 1, height: 1)
    /// The crop as fractions of the screen alone, for exports without the frame.
    public static func screen(_ crop: MediaRect, in frame: DeviceFrame) -> MediaRect {
        func clamp(_ value: Double) -> Double { min(1, max(0, value)) }
        let x0 = clamp((crop.x * frame.width - frame.screenX) / frame.screenWidth)
        let y0 = clamp((crop.y * frame.height - frame.screenY) / frame.screenHeight)
        let x1 = clamp(((crop.x + crop.width) * frame.width - frame.screenX) / frame.screenWidth)
        let y1 = clamp(((crop.y + crop.height) * frame.height - frame.screenY) / frame.screenHeight)
        guard x1 - x0 > 0.001, y1 - y0 > 0.001 else { return whole }
        return MediaRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }
}

extension PhoneViewport {
    /// The part of the framed device in view, as fractions of it, or nil when all of it shows.
    public var visible: MediaRect? {
        guard overflowsX || overflowsY else { return nil }
        let width = frame.width * scale, height = frame.height * scale
        let x0 = max(0, -originX) / width, y0 = max(0, -originY) / height
        let x1 = min(width, Double(canvasWidth) - originX) / width, y1 = min(height, Double(canvasHeight) - originY) / height
        guard x1 > x0, y1 > y0 else { return nil }
        return MediaRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }
    /// How far one wheel tick of `cells` rows (or columns) moves the pan, as a fraction of the overflow.
    public func panStep(cells: Double = 2) -> (x: Double, y: Double) {
        let overX = frame.width * scale - Double(canvasWidth), overY = frame.height * scale - Double(canvasHeight)
        let cellWidth = Double(canvasWidth) / Double(columns), cellHeight = Double(canvasHeight) / Double(rows)
        return (overX > 0.5 ? min(1, cells * 2 * cellWidth / overX) : 0, overY > 0.5 ? min(1, cells * cellHeight / overY) : 0)
    }
}
