import Foundation
@_exported import TerminalUI

/// The generic image-in-cells layout and terminal reply filter live in TerminalUI, shared with terminal-mac.
public typealias PhoneDisplayLayout = ImageLayout
public typealias PhoneMetricFilter = TerminalMetricFilter

/// The colour of the phone's metal band and buttons, after real iPhone finishes.
public enum FrameFinish: String, CaseIterable, Equatable, Sendable {
    case graphite, black, silver, white, gold, orange, red, pink, yellow, green, blue, purple

    /// The band's base colour, its polished edge highlight, and the side buttons.
    public var band: UInt32 { colors.band }
    public var highlight: UInt32 { colors.highlight }
    public var buttons: UInt32 { colors.buttons }
    public var displayName: String {
        switch self {
        case .graphite: "Graphite"
        case .black: "Space Black"
        case .silver: "Silver"
        case .white: "White"
        case .gold: "Gold"
        case .orange: "Cosmic Orange"
        case .red: "Red"
        case .pink: "Pink"
        case .yellow: "Yellow"
        case .green: "Sage"
        case .blue: "Deep Blue"
        case .purple: "Deep Purple"
        }
    }
    private var colors: (band: UInt32, highlight: UInt32, buttons: UInt32) {
        switch self {
        case .graphite: (0x4a4a50, 0x8e8e96, 0x3a3a40)
        case .black: (0x2a2a2d, 0x5e5e64, 0x1f1f22)
        case .silver: (0xc9cbce, 0xf6f7f8, 0xa9abaf)
        case .white: (0xe9e7e1, 0xffffff, 0xcfccc4)
        case .gold: (0xd9c39b, 0xf8ead0, 0xbea77d)
        case .orange: (0xe0692a, 0xffae78, 0xbf541b)
        case .red: (0xb01e2b, 0xe8636d, 0x8c1621)
        case .pink: (0xedc3c9, 0xfdeaec, 0xd6a5ad)
        case .yellow: (0xefd468, 0xfff1ad, 0xd3b74c)
        case .green: (0x6b8468, 0xa9c0a6, 0x566c54)
        case .blue: (0x2d3f5e, 0x7186ad, 0x22314a)
        case .purple: (0x564773, 0x9a89bf, 0x43375c)
        }
    }
    /// Accepts the raw name or the display name, ignoring case and spaces ("cosmic orange", "space-black").
    public init?(named name: String) {
        let key = name.lowercased().filter { $0.isLetter }
        guard let match = Self.allCases.first(where: { $0.rawValue == key || $0.displayName.lowercased().filter(\.isLetter) == key }) else { return nil }
        self = match
    }
    public var next: FrameFinish { let all = Self.allCases; return all[(all.firstIndex(of: self)! + 1) % all.count] }
    public static var names: String { allCases.map(\.rawValue).joined(separator: ", ") }
}

/// An iPhone-style body drawn around the simulator screen, measured in display points.
public struct DeviceFrame: Equatable {
    public let screenWidth: Double
    public let screenHeight: Double
    public var finish: FrameFinish
    public static let bezel = 9.5, rim = 6.0, button = 3.0
    public init(screenWidth: Int, screenHeight: Int, finish: FrameFinish = .graphite) {
        self.screenWidth = Double(screenWidth); self.screenHeight = Double(screenHeight); self.finish = finish
    }
    public var inset: Double { Self.bezel + Self.rim }
    public var width: Double { screenWidth + 2 * (inset + Self.button) }
    public var height: Double { screenHeight + 2 * inset }
    public var screenX: Double { Self.button + inset }
    public var screenY: Double { inset }
    /// Close to modern Face ID iPhones: about 55 pt on a 402 pt wide screen.
    public var screenRadius: Double { screenWidth * 0.137 }
}

/// Where the framed phone sits in the terminal. The image always covers whole cells; the device
/// is centered in it, or, when zoomed past the region, cropped at the `pan` fraction (0...1).
public struct PhoneViewport: Equatable {
    public let frame: DeviceFrame
    public let column: Int, row: Int, columns: Int, rows: Int
    public let canvasWidth: Int, canvasHeight: Int
    /// Canvas pixels per display point, when fitted and after zoom.
    public let fitScale: Double, scale: Double
    /// The device's top-left corner in canvas pixels. Negative when cropped.
    public let originX: Double, originY: Double
    public let overflowsX: Bool, overflowsY: Bool

    /// `cellWidth` and `cellHeight` are in the same device pixels as the canvas.
    public init(frame: DeviceFrame, column regionColumn: Int, row regionRow: Int, columns regionColumns: Int, rows regionRows: Int,
                cellWidth: Double, cellHeight: Double, zoom: Double = 1, pan: (x: Double, y: Double) = (0.5, 0.5)) {
        self.frame = frame
        let regionColumns = max(1, regionColumns), regionRows = max(1, regionRows)
        fitScale = max(0.001, min(Double(regionColumns) * cellWidth / frame.width, Double(regionRows) * cellHeight / frame.height))
        scale = fitScale * max(0.05, zoom)
        let fullWidth = frame.width * scale, fullHeight = frame.height * scale
        columns = max(1, min(regionColumns, Int(ceil(fullWidth / cellWidth - 0.001))))
        rows = max(1, min(regionRows, Int(ceil(fullHeight / cellHeight - 0.001))))
        column = regionColumn + (regionColumns - columns) / 2
        row = regionRow + (regionRows - rows) / 2
        canvasWidth = max(1, Int((Double(columns) * cellWidth).rounded()))
        canvasHeight = max(1, Int((Double(rows) * cellHeight).rounded()))
        overflowsX = fullWidth > Double(canvasWidth) + 0.5
        overflowsY = fullHeight > Double(canvasHeight) + 0.5
        originX = overflowsX ? -(fullWidth - Double(canvasWidth)) * min(1, max(0, pan.x)) : (Double(canvasWidth) - fullWidth) / 2
        originY = overflowsY ? -(fullHeight - Double(canvasHeight)) * min(1, max(0, pan.y)) : (Double(canvasHeight) - fullHeight) / 2
    }
    private var cellPixelWidth: Double { Double(canvasWidth) / Double(columns) }
    private var cellPixelHeight: Double { Double(canvasHeight) / Double(rows) }

    /// Maps a terminal cell to simulator display points, or nil outside the screen.
    /// `clamp` keeps a drag that leaves the screen pinned to its edge.
    public func point(column: Int, row: Int, clamp: Bool = false) -> (Int, Int)? {
        let cx = (Double(column - self.column) + 0.5) * cellPixelWidth
        let cy = (Double(row - self.row) + 0.5) * cellPixelHeight
        let x = (cx - originX) / scale - frame.screenX, y = (cy - originY) / scale - frame.screenY
        guard clamp || (cx >= 0 && cy >= 0 && cx < Double(canvasWidth) && cy < Double(canvasHeight) &&
                        x >= 0 && y >= 0 && x < frame.screenWidth && y < frame.screenHeight) else { return nil }
        return (max(0, min(Int(frame.screenWidth) - 1, Int(x))), max(0, min(Int(frame.screenHeight) - 1, Int(y))))
    }
    /// Whole cells that lie on the visible part of the screen, for text drawn over it.
    public var screenCells: (column: Int, row: Int, columns: Int, rows: Int) {
        let x0 = max(0, originX + frame.screenX * scale), x1 = min(Double(canvasWidth), originX + (frame.screenX + frame.screenWidth) * scale)
        let y0 = max(0, originY + frame.screenY * scale), y1 = min(Double(canvasHeight), originY + (frame.screenY + frame.screenHeight) * scale)
        let c0 = Int(ceil(x0 / cellPixelWidth)), r0 = Int(ceil(y0 / cellPixelHeight))
        return (column + c0, row + r0, max(0, Int(floor(x1 / cellPixelWidth)) - c0), max(0, Int(floor(y1 / cellPixelHeight)) - r0))
    }
}
