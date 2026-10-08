/// One grid cell. See SPEC/screen/contract.md.
public struct Cell: Equatable, Sendable {
    /// The character, or a space for a blank cell. For a multi-scalar grapheme
    /// this is its first scalar; the whole grapheme is in `Line.character(at:)`.
    public var scalar: Unicode.Scalar
    public var attributes: Attributes
    /// 1 for a normal cell, 2 for the leading half of a wide character, 0 for its trailing half.
    public var width: UInt8

    public init(scalar: Unicode.Scalar = " ", attributes: Attributes = Attributes(), width: UInt8 = 1) {
        self.scalar = scalar
        self.attributes = attributes
        self.width = width
    }

    public static let blank = Cell()

    /// A blank cell carrying only a background color (background color erase).
    static func blank(background: TerminalColor) -> Cell {
        Cell(scalar: " ", attributes: Attributes(background: background), width: 1)
    }

    /// The last column of a row left empty because a wide character wrapped: blank on
    /// screen, not part of the text. See SPEC/screen/contract.md.
    static func widePadding(background: TerminalColor) -> Cell {
        Cell(scalar: "\u{0}", attributes: Attributes(background: background), width: 1)
    }

    public var isWidePadding: Bool { scalar == "\u{0}" }

    /// A space or a padding cell: nothing to draw or copy.
    public var isBlank: Bool { scalar == " " || scalar == "\u{0}" }

    /// True for a space with default attributes: what trimming and reflow may drop.
    var isDefaultBlank: Bool { self == .blank }
}

/// One line of cells. Screen lines have exactly `cols` cells; scrollback lines
/// may be shorter (trailing default blanks are trimmed).
public struct Line: Sendable {
    public var cells: [Cell]
    /// True when the text continues on the next line because of autowrap.
    public var isWrapped: Bool
    /// Multi-scalar graphemes, keyed by the column of their leading cell.
    var clusters: [Int: String]

    public init(cols: Int, fill: Cell = .blank) {
        cells = Array(repeating: fill, count: cols)
        isWrapped = false
        clusters = [:]
    }

    init(cells: [Cell], isWrapped: Bool = false, clusters: [Int: String] = [:]) {
        self.cells = cells
        self.isWrapped = isWrapped
        self.clusters = clusters
    }

    /// The multi-scalar grapheme of cell `col`, if it holds one.
    public func cluster(at col: Int) -> String? {
        clusters.isEmpty ? nil : clusters[col]
    }

    /// The full grapheme shown in cell `col` (a space for blank and padding cells).
    public func character(at col: Int) -> String {
        if !clusters.isEmpty, let cluster = clusters[col] { return cluster }
        guard col < cells.count, !cells[col].isWidePadding else { return " " }
        return String(cells[col].scalar)
    }

    /// Text of the line: characters in order, trailing halves skipped, trailing spaces trimmed.
    public var text: String {
        text(from: 0, to: cells.count)
    }

    /// Text of columns `start..<end`, trailing spaces trimmed unless asked otherwise.
    public func text(from start: Int, to end: Int, trimmingTrailingSpaces: Bool = true) -> String {
        let end = min(end, cells.count)
        var last = end - 1
        while trimmingTrailingSpaces && last >= start {
            let cell = cells[last]
            if cell.width != 0 && (!cell.isBlank || clusters[last] != nil) { break }
            last -= 1
        }
        guard last >= start else { return "" }
        var result = ""
        for col in start...last where cells[col].width != 0 && !cells[col].isWidePadding {
            result += character(at: col)
        }
        return result
    }
}
