import Foundation

/// Fits an image of `width`×`height` into terminal cells and maps cells back to image pixels.
public struct ImageLayout {
    public let column: Int
    public let row: Int
    public let columns: Int
    public let rows: Int
    public let pixelWidth: Double
    public let pixelHeight: Double
    public let cellWidth: Double
    public let cellHeight: Double
    public let width: Int
    public let height: Int
    public let heightLimited: Bool

    /// Fits the image into a whole terminal, keeping the bottom two rows for status text.
    public init(width: Int, height: Int, columns: Int, rows: Int, cellWidth: Double, cellHeight: Double) {
        self.init(width: width, height: height, column: 1, row: 1, columns: columns, rows: rows - 2, cellWidth: cellWidth, cellHeight: cellHeight)
    }
    /// Fits and centers the image inside the region of cells starting at (column, row).
    public init(width: Int, height: Int, column originColumn: Int, row originRow: Int, columns: Int, rows: Int, cellWidth: Double, cellHeight: Double) {
        self.width = width; self.height = height
        self.cellWidth = cellWidth; self.cellHeight = cellHeight
        let availableColumns = max(1, columns), availableRows = max(1, rows)
        heightLimited = Double(availableRows) * cellHeight / Double(height) <= Double(availableColumns) * cellWidth / Double(width)
        if heightLimited {
            self.rows = availableRows
            pixelHeight = Double(availableRows) * cellHeight
            pixelWidth = pixelHeight * Double(width) / Double(height)
            self.columns = max(1, Int(ceil(pixelWidth / cellWidth)))
        } else {
            self.columns = availableColumns
            pixelWidth = Double(availableColumns) * cellWidth
            pixelHeight = pixelWidth * Double(height) / Double(width)
            self.rows = max(1, Int(ceil(pixelHeight / cellHeight)))
        }
        column = max(1, originColumn + (availableColumns - self.columns) / 2)
        row = max(1, originRow + (availableRows - self.rows) / 2)
    }
    public func point(column: Int, row: Int, clamp: Bool = false) -> (Int, Int)? {
        let x = (Double(column - self.column) + 0.5) * cellWidth
        let y = (Double(row - self.row) + 0.5) * cellHeight
        guard clamp || (x >= 0 && y >= 0 && x < pixelWidth && y < pixelHeight) else { return nil }
        return (max(0, min(width - 1, Int(x * Double(width) / pixelWidth))),
                max(0, min(height - 1, Int(y * Double(height) / pixelHeight))))
    }
}

/// Removes terminal size reports and graphics replies before keystrokes reach the guest.
public struct TerminalMetricFilter {
    public private(set) var cellWidth: Double?
    public private(set) var cellHeight: Double?
    /// iTerm2 reports cells in points plus a Retina scale; other terminals report device pixels.
    public private(set) var cellScale: Double = 1
    /// The terminal's background colour as 0xRRGGBB, from an OSC 11 reply.
    public private(set) var background: UInt32?
    /// Kitty graphics protocol replies, keyed by image ID, such as [31: "OK"].
    public private(set) var graphicsReplies: [Int: String] = [:]
    public private(set) var windowWidth: Double?
    public private(set) var windowHeight: Double?
    private var pending: [UInt8] = []
    public init() {}
    public mutating func feed(_ bytes: [UInt8], flush: Bool = false) -> [UInt8] {
        pending += bytes
        var result: [UInt8] = []
        while !pending.isEmpty {
            guard pending[0] == 27 else { result.append(pending.removeFirst()); continue }
            if pending.count == 1 {
                if flush { result.append(pending.removeFirst()) }
                break
            }
            if pending[1] == 91 {
                guard let end = pending.indices.dropFirst(2).first(where: { (64...126).contains(pending[$0]) }) else { break }
                let sequence = Array(pending[0...end]); pending.removeFirst(end + 1)
                if sequence.last == 116 {
                    let values = String(decoding: sequence.dropFirst(2).dropLast(), as: UTF8.self).split(separator: ";").compactMap { Double($0) }
                    if values.count == 3, values[1] > 0, values[2] > 0, values[1].isFinite, values[2].isFinite {
                        if values[0] == 6 { cellHeight = values[1]; cellWidth = values[2]; continue }
                        if values[0] == 4 { windowHeight = values[1]; windowWidth = values[2]; continue }
                    }
                }
                result += sequence
            } else if pending[1] == 93 {
                guard let end = pending.indices.dropFirst(2).first(where: { pending[$0] == 7 || (pending[$0] == 92 && pending[$0 - 1] == 27) }) else { break }
                let sequence = Array(pending[0...end]); pending.removeFirst(end + 1)
                let text = String(decoding: sequence, as: UTF8.self)
                if let range = text.range(of: "1337;ReportCellSize=") {
                    let values = text[range.upperBound...].split(whereSeparator: { $0 == ";" || $0 == "\u{7}" || $0 == "\u{1b}" || $0 == "\\" }).compactMap { Double($0) }
                    if values.count >= 2, values[0].isFinite, values[1].isFinite, (1...512).contains(values[0]), (1...512).contains(values[1]) { cellHeight = values[0]; cellWidth = values[1] }
                    if values.count >= 3, (1...4).contains(values[2]) { cellScale = values[2] }
                } else if let range = text.range(of: "]11;rgb:") {
                    let channels = text[range.upperBound...].split(whereSeparator: { $0 == "/" || $0 == "\u{7}" || $0 == "\u{1b}" || $0 == "\\" })
                        .prefix(3).compactMap { UInt32($0.prefix(2), radix: 16) }
                    if channels.count == 3 { background = channels[0] << 16 | channels[1] << 8 | channels[2] }
                } else { result += sequence }
            } else if pending[1] == 95 {
                guard let end = pending.indices.dropFirst(2).first(where: { pending[$0] == 92 && pending[$0 - 1] == 27 }) else { break }
                let body = String(decoding: pending[2..<(end - 1)], as: UTF8.self); pending.removeFirst(end + 1)
                if body.hasPrefix("G"), let semicolon = body.firstIndex(of: ";"),
                   let id = body[body.index(after: body.startIndex)..<semicolon].split(separator: ",").first(where: { $0.hasPrefix("i=") }).flatMap({ Int($0.dropFirst(2)) }) {
                    graphicsReplies[id] = String(body[body.index(after: semicolon)...])
                }
            } else { result.append(pending.removeFirst()) }
            if pending.count > 4096 { pending.removeAll() }
        }
        return result
    }
}

