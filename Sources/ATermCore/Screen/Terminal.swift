/// The terminal model: a `VTParserHandler` that turns parser actions into a
/// screen, scrollback and modes. See SPEC/screen.
public final class Terminal: VTParserHandler {
    struct Cursor {
        var row = 0
        var col = 0
        var attributes = Attributes()
        /// Set after writing the last column with autowrap on: the next printable character wraps first.
        var pendingWrap = false
        var charsets = CharsetState()
    }

    struct SavedCursor {
        var cursor: Cursor
        var originMode: Bool
    }

    public weak var delegate: TerminalDelegate?
    public internal(set) var cols: Int
    public internal(set) var rows: Int
    public var scrollbackLimit: Int { scrollback.limit }
    public internal(set) var modes = TerminalModes()
    public internal(set) var palette: Palette
    let defaultPalette: Palette
    public internal(set) var title = ""
    public internal(set) var workingDirectory: String?
    public internal(set) var cursorShape: CursorShape = .block
    public internal(set) var cursorBlinks = false
    public internal(set) var isAlternateScreenActive = false
    /// Lines discarded from the front of the scrollback so far.
    public internal(set) var linesDropped = 0

    public var cursorVisible: Bool { modes.cursorVisible }
    public var cursorPosition: Position { Position(row: cursor.row, col: cursor.col) }
    public var scrollRegion: ClosedRange<Int> { scrollTop...scrollBottom }

    var parser = VTParser()
    /// The active buffer (main or alternate).
    var screen: [Line]
    /// The buffer that is not shown.
    var inactiveScreen: [Line]
    var scrollback: Scrollback
    var cursor = Cursor()
    var savedCursorMain: SavedCursor?
    var savedCursorAlternate: SavedCursor?
    /// The main screen's cursor while the alternate screen is shown (to reflow the hidden main screen).
    var mainCursorWhileAlternate: Cursor?
    var scrollTop = 0
    var scrollBottom: Int
    var tabStops: [Bool]
    var titleStack: [String] = []
    /// Leading cell of the last printed grapheme; cleared by any other action.
    var lastPrinted: Position?
    /// Last printed character, repeated by REP.
    var lastPrintedScalar: Unicode.Scalar?
    /// The grapheme at `lastPrinted` ends with a zero-width joiner.
    var lastGraphemeEndsWithJoiner = false

    public init(cols: Int, rows: Int, scrollbackLimit: Int = 10_000, palette: Palette = .default) {
        let cols = max(1, cols)
        let rows = max(1, rows)
        self.cols = cols
        self.rows = rows
        self.palette = palette
        defaultPalette = palette
        screen = Array(repeating: Line(cols: cols), count: rows)
        inactiveScreen = Array(repeating: Line(cols: cols), count: rows)
        scrollback = Scrollback(limit: scrollbackLimit)
        scrollBottom = rows - 1
        tabStops = Terminal.defaultTabStops(cols: cols)
    }

    static func defaultTabStops(cols: Int) -> [Bool] {
        (0..<cols).map { $0 > 0 && $0 % 8 == 0 }
    }

    // MARK: - Input

    public func feed(_ bytes: [UInt8]) {
        bytes.withUnsafeBufferPointer { feed($0) }
    }

    public func feed(_ bytes: UnsafeBufferPointer<UInt8>) {
        parser.feed(bytes, handler: self)
    }

    // MARK: - Reading the model

    /// Screen row of the active buffer.
    public func line(_ row: Int) -> Line { screen[row] }

    public var scrollbackCount: Int { scrollback.count }

    public func scrollbackLine(_ index: Int) -> Line { scrollback[index] }

    /// Absolute index of screen row 0. See SPEC/screen/contract.md.
    public var firstScreenLineIndex: Int { linesDropped + scrollback.count }

    /// The line at an absolute index, from the scrollback or the active screen.
    public func line(absolute index: Int) -> Line? {
        let relative = index - linesDropped
        guard relative >= 0 else { return nil }
        if relative < scrollback.count { return scrollback[relative] }
        let row = relative - scrollback.count
        return row < rows ? screen[row] : nil
    }

    public func text(row: Int) -> String { screen[row].text }

    public var screenLines: [String] { screen.map(\.text) }

    public var scrollbackLines: [String] { scrollback.allLines.map(\.text) }

    func send(_ text: String) {
        delegate?.terminal(self, send: Array(text.utf8))
    }

    // MARK: - VTParserHandler

    public func print(_ scalar: Unicode.Scalar) {
        var scalar = scalar
        if scalar.value < 0x80 {
            let charset = cursor.charsets.active
            if charset != .ascii { scalar = charset.map(scalar) }
        }
        let width = CharacterWidth.width(of: scalar)
        if width == 0 {
            joinToPreviousGrapheme(scalar)
            return
        }
        if let last = lastPrinted, mayJoinPreviousGrapheme(scalar), joinsPreviousGrapheme(scalar, at: last) {
            appendToGrapheme(scalar, at: last)
            return
        }
        put(scalar, width: width)
    }

    public func printASCII(_ bytes: UnsafeBufferPointer<UInt8>) {
        if cursor.charsets.active != .ascii || modes.insertMode {
            for byte in bytes { print(Unicode.Scalar(byte)) }
            return
        }
        guard let last = bytes.last else { return }
        let attributes = cursor.attributes
        let autoWrap = modes.autoWrap
        var index = 0
        while index < bytes.count {
            if cursor.pendingWrap { performPendingWrap() }
            let row = cursor.row
            let col = cursor.col
            let count = min(cols - col, bytes.count - index)
            writeASCII(UnsafeBufferPointer(rebasing: bytes[index..<(index + count)]), row: row, col: col,
                       attributes: attributes)
            index += count
            let end = col + count
            if end >= cols {
                cursor.col = cols - 1
                cursor.pendingWrap = autoWrap
            } else {
                cursor.col = end
            }
            lastPrinted = Position(row: row, col: end - 1)
        }
        lastPrintedScalar = Unicode.Scalar(last)
    }

    /// Writes a run of ASCII characters that fits on the row, in one pass over its cells.
    private func writeASCII(_ bytes: UnsafeBufferPointer<UInt8>, row: Int, col: Int, attributes: Attributes) {
        let cols = self.cols
        screen.withUnsafeMutableBufferPointer { lines in
            let end = col + bytes.count
            var start = col
            lines[row].cells.withUnsafeMutableBufferPointer { cells in
                // Wide characters cut at either end of the run lose their other half.
                if cells[col].width == 0, col > 0 {
                    cells[col - 1] = Cell(scalar: " ", attributes: cells[col - 1].attributes, width: 1)
                    start = col - 1
                }
                if cells[end - 1].width == 2, end < cols {
                    cells[end] = Cell(scalar: " ", attributes: cells[end].attributes, width: 1)
                }
                for (offset, byte) in bytes.enumerated() {
                    cells[col + offset] = Cell(scalar: Unicode.Scalar(byte), attributes: attributes, width: 1)
                }
            }
            if !lines[row].clusters.isEmpty {
                lines[row].clusters = lines[row].clusters.filter { $0.key < start || $0.key >= end }
            }
        }
    }

    public func execute(_ byte: UInt8) {
        lastPrinted = nil
        switch byte {
        case 0x07:
            delegate?.terminalBell(self)
        case 0x08:
            cursor.pendingWrap = false
            cursor.col = max(0, cursor.col - 1)
        case 0x09:
            tabForward(1)
        case 0x0A, 0x0B, 0x0C:
            index()
            if modes.newLineMode { cursor.col = 0 }
        case 0x0D:
            cursor.pendingWrap = false
            cursor.col = 0
        case 0x0E:
            cursor.charsets.useG1 = true
        case 0x0F:
            cursor.charsets.useG1 = false
        default:
            break
        }
    }

    public func csiDispatch(_ sequence: CSISequence) {
        lastPrinted = nil
        handleCSI(sequence)
    }

    public func escDispatch(intermediates: [UInt8], final: UInt8) {
        lastPrinted = nil
        handleESC(intermediates: intermediates, final: final)
    }

    public func oscDispatch(_ payload: [UInt8], terminator: StringTerminator) {
        lastPrinted = nil
        handleOSC(payload, terminator: terminator)
    }

    public func dcsDispatch(_ sequence: DCSSequence) {
        lastPrinted = nil
    }

    // MARK: - Printing

    func put(_ scalar: Unicode.Scalar, width: Int) {
        if cursor.pendingWrap { performPendingWrap() }
        if width == 2 {
            guard cols >= 2 else { return }
            if cursor.col == cols - 1 {
                guard modes.autoWrap else { return }
                prepareOverwrite(row: cursor.row, col: cursor.col)
                screen[cursor.row].cells[cursor.col] = Cell.widePadding(background: cursor.attributes.background)
                wrapToNextLine()
            }
        }
        if modes.insertMode { insertBlankCells(width) }
        let row = cursor.row
        let col = cursor.col
        prepareOverwrite(row: row, col: col)
        if width == 2 { prepareOverwrite(row: row, col: col + 1) }
        screen[row].cells[col] = Cell(scalar: scalar, attributes: cursor.attributes, width: UInt8(width))
        if width == 2 {
            screen[row].cells[col + 1] = Cell(scalar: " ", attributes: cursor.attributes, width: 0)
        }
        lastPrinted = Position(row: row, col: col)
        lastPrintedScalar = scalar
        lastGraphemeEndsWithJoiner = false
        if col + width >= cols {
            cursor.col = cols - 1
            cursor.pendingWrap = modes.autoWrap
        } else {
            cursor.col = col + width
        }
    }

    func performPendingWrap() {
        cursor.pendingWrap = false
        if modes.autoWrap { wrapToNextLine() }
    }

    func wrapToNextLine() {
        screen[cursor.row].isWrapped = true
        index()
        cursor.col = 0
    }

    /// Before writing cell (row, col): blanks the other half of a wide character it cuts, drops its grapheme.
    func prepareOverwrite(row: Int, col: Int) {
        guard col < cols else { return }
        let cell = screen[row].cells[col]
        if cell.width == 0, col > 0 {
            screen[row].cells[col - 1] = Cell(scalar: " ", attributes: screen[row].cells[col - 1].attributes, width: 1)
            screen[row].clusters[col - 1] = nil
        } else if cell.width == 2, col + 1 < cols {
            screen[row].cells[col + 1] = Cell(scalar: " ", attributes: cell.attributes, width: 1)
        }
        if !screen[row].clusters.isEmpty { screen[row].clusters[col] = nil }
    }

    /// Cheap filter before `joinsPreviousGrapheme`: only these can extend a grapheme.
    func mayJoinPreviousGrapheme(_ scalar: Unicode.Scalar) -> Bool {
        lastGraphemeEndsWithJoiner
            || (0x1F3FB...0x1F3FF).contains(scalar.value)
            || CharacterWidth.isRegionalIndicator(scalar)
    }

    func joinsPreviousGrapheme(_ scalar: Unicode.Scalar, at position: Position) -> Bool {
        let previous = screen[position.row].character(at: position.col).unicodeScalars
        guard let last = previous.last else { return false }
        if last == "\u{200D}" { return CharacterWidth.isEmoji(scalar) }
        if scalar.properties.isEmojiModifier { return previous.first.map(CharacterWidth.isEmoji) ?? false }
        if CharacterWidth.isRegionalIndicator(scalar) {
            return previous.count == 1 && CharacterWidth.isRegionalIndicator(last)
        }
        return false
    }

    func joinToPreviousGrapheme(_ scalar: Unicode.Scalar) {
        guard let target = graphemeTarget() else { return }
        appendToGrapheme(scalar, at: target)
    }

    /// Longest grapheme kept in a cell; further marks are dropped (keeps crafted input cheap).
    static let maxGraphemeScalars = 32

    func appendToGrapheme(_ scalar: Unicode.Scalar, at position: Position) {
        var grapheme = screen[position.row].character(at: position.col)
        guard grapheme.unicodeScalars.count < Self.maxGraphemeScalars else { return }
        grapheme.unicodeScalars.append(scalar)
        screen[position.row].clusters[position.col] = grapheme
        lastPrinted = position
        lastGraphemeEndsWithJoiner = scalar == "\u{200D}"
    }

    /// The cell a zero-width character joins: the last printed one, else the one before the cursor.
    func graphemeTarget() -> Position? {
        if let last = lastPrinted, last.row < rows, last.col < cols, screen[last.row].cells[last.col].width != 0 {
            return last
        }
        var col = cursor.pendingWrap ? cursor.col : cursor.col - 1
        guard col >= 0 else { return nil }
        if screen[cursor.row].cells[col].width == 0, col > 0 { col -= 1 }
        // A padding cell holds no character to extend.
        guard !screen[cursor.row].cells[col].isWidePadding else { return nil }
        return Position(row: cursor.row, col: col)
    }

    /// A blank cell for erase operations: current background, nothing else.
    var blankCell: Cell { Cell.blank(background: cursor.attributes.background) }

    var blankLine: Line { Line(cols: cols, fill: blankCell) }
}
