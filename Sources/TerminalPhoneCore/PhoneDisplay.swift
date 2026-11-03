import Foundation
@_exported import TerminalUI

/// The generic image-in-cells layout and terminal reply filter live in TerminalUI, shared with terminal-mac.
public typealias PhoneDisplayLayout = ImageLayout
public typealias PhoneMetricFilter = TerminalMetricFilter

/// An iPhone-style body drawn around the simulator screen, measured in display points.
public struct DeviceFrame: Equatable {
    public let screenWidth: Double
    public let screenHeight: Double
    public static let bezel = 12.0, rim = 3.5, button = 3.0
    public init(screenWidth: Int, screenHeight: Int) { self.screenWidth = Double(screenWidth); self.screenHeight = Double(screenHeight) }
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
