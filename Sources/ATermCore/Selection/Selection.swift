/// A cell addressed by absolute line index (see SPEC/screen/contract.md) and column.
public struct SelectionPoint: Hashable, Comparable, Sendable, CustomStringConvertible {
    public var line: Int
    public var col: Int

    public init(line: Int, col: Int) {
        self.line = line
        self.col = col
    }

    public static func < (lhs: SelectionPoint, rhs: SelectionPoint) -> Bool {
        lhs.line != rhs.line ? lhs.line < rhs.line : lhs.col < rhs.col
    }

    public var description: String { "(\(line), \(col))" }
}

public enum SelectionGranularity: Sendable {
    case character, word, line
}

/// A selection from an anchor to a head. See SPEC/selection/selection.md.
public struct Selection: Equatable, Sendable {
    public var anchor: SelectionPoint
    public var head: SelectionPoint
    public var granularity: SelectionGranularity

    public init(anchor: SelectionPoint, head: SelectionPoint? = nil, granularity: SelectionGranularity = .character) {
        self.anchor = anchor
        self.head = head ?? anchor
        self.granularity = granularity
    }
}

extension Terminal {
    private static let extraWordCharacters: Set<Unicode.Scalar> = ["_", "-", ".", "/", "~", "+"]

    static func isWordCharacter(_ grapheme: String) -> Bool {
        guard let scalar = grapheme.unicodeScalars.first else { return false }
        if extraWordCharacters.contains(scalar) { return true }
        let properties = scalar.properties
        return properties.isAlphabetic || properties.numericType != nil
    }

    /// The cells covered by a selection, from start to end inclusive, expanded to its granularity.
    public func selectionRange(_ selection: Selection) -> ClosedRange<SelectionPoint> {
        var start = min(selection.anchor, selection.head)
        var end = max(selection.anchor, selection.head)
        switch selection.granularity {
        case .character:
            break
        case .word:
            start = wordBoundary(from: start, forward: false)
            end = wordBoundary(from: end, forward: true)
        case .line:
            start = SelectionPoint(line: logicalLineStart(start.line), col: 0)
            end = SelectionPoint(line: logicalLineEnd(end.line), col: cols - 1)
        }
        start = snappedToLeadingHalf(start)
        return start...max(start, end)
    }

    /// The text of a selection. See SPEC/selection/selection.md.
    public func text(in selection: Selection) -> String {
        let range = selectionRange(selection)
        var result = ""
        var lineIndex = range.lowerBound.line
        while lineIndex <= range.upperBound.line {
            defer { lineIndex += 1 }
            guard let line = line(absolute: lineIndex) else { continue }
            let isLast = lineIndex == range.upperBound.line
            let from = lineIndex == range.lowerBound.line ? range.lowerBound.col : 0
            let to = isLast ? range.upperBound.col + 1 : line.cells.count
            let continues = line.isWrapped && !isLast
            result += line.text(from: from, to: to, trimmingTrailingSpaces: !continues)
            if !isLast && !line.isWrapped { result += "\n" }
        }
        return result
    }

    /// A selection covering the scrollback and the screen down to the last non-blank line.
    public func selectAll() -> Selection {
        let first = isAlternateScreenActive ? firstScreenLineIndex : linesDropped
        var last = firstScreenLineIndex + rows - 1
        while last > first, let line = line(absolute: last), line.text.isEmpty { last -= 1 }
        return Selection(anchor: SelectionPoint(line: first, col: 0), head: SelectionPoint(line: last, col: cols - 1))
    }

    private func snappedToLeadingHalf(_ point: SelectionPoint) -> SelectionPoint {
        guard let line = line(absolute: point.line), point.col > 0, point.col < line.cells.count,
              line.cells[point.col].width == 0 else { return point }
        return SelectionPoint(line: point.line, col: point.col - 1)
    }

    private func wordBoundary(from point: SelectionPoint, forward: Bool) -> SelectionPoint {
        guard let line = line(absolute: point.line), point.col < line.cells.count else { return point }
        var col = point.col
        if line.cells[col].width == 0 && col > 0 { col -= 1 }
        guard Terminal.isWordCharacter(line.character(at: col)) else {
            return SelectionPoint(line: point.line, col: forward && line.cells[col].width == 2 ? col + 1 : col)
        }
        if forward {
            while col + 1 < line.cells.count {
                var next = col + 1
                if line.cells[next].width == 0 { next += 1 }
                guard next < line.cells.count, Terminal.isWordCharacter(line.character(at: next)) else { break }
                col = next
            }
            if line.cells[col].width == 2 { col += 1 }
        } else {
            while col > 0 {
                var previous = col - 1
                if line.cells[previous].width == 0 && previous > 0 { previous -= 1 }
                guard Terminal.isWordCharacter(line.character(at: previous)) else { break }
                col = previous
            }
        }
        return SelectionPoint(line: point.line, col: col)
    }

    private func logicalLineStart(_ index: Int) -> Int {
        var index = index
        while let previous = line(absolute: index - 1), previous.isWrapped { index -= 1 }
        return index
    }

    private func logicalLineEnd(_ index: Int) -> Int {
        var index = index
        while let current = line(absolute: index), current.isWrapped, line(absolute: index + 1) != nil { index += 1 }
        return index
    }
}
