/// Cursor movement, scrolling, erasing and editing. See SPEC/screen.
extension Terminal {
    // MARK: - Cursor movement

    /// Moves to an absolute screen position, clamped to the screen.
    func moveCursor(row: Int, col: Int) {
        cursor.pendingWrap = false
        cursor.row = min(max(0, row), rows - 1)
        cursor.col = min(max(0, col), cols - 1)
    }

    /// Moves to a position given by CUP-style parameters (0-based), honoring origin mode.
    func moveCursorAddressed(row: Int, col: Int) {
        if modes.originMode {
            moveCursor(row: min(scrollTop + row, scrollBottom), col: col)
        } else {
            moveCursor(row: row, col: col)
        }
    }

    func setAddressedRow(_ row: Int) {
        moveCursorAddressed(row: row, col: cursor.col)
    }

    func cursorUp(_ count: Int) {
        let limit = cursor.row >= scrollTop ? scrollTop : 0
        moveCursor(row: max(limit, cursor.row - count), col: cursor.col)
    }

    func cursorDown(_ count: Int) {
        let limit = cursor.row <= scrollBottom ? scrollBottom : rows - 1
        moveCursor(row: min(limit, cursor.row + count), col: cursor.col)
    }

    func cursorForward(_ count: Int) {
        moveCursor(row: cursor.row, col: cursor.col + count)
    }

    func cursorBackward(_ count: Int) {
        moveCursor(row: cursor.row, col: cursor.col - count)
    }

    /// Line feed: moves down, scrolling the region when at its bottom margin.
    func index() {
        cursor.pendingWrap = false
        if cursor.row == scrollBottom {
            scrollUp(1)
        } else if cursor.row < rows - 1 {
            cursor.row += 1
        }
    }

    /// Reverse index: moves up, scrolling the region down when at its top margin.
    func reverseIndex() {
        cursor.pendingWrap = false
        if cursor.row == scrollTop {
            scrollDown(1)
        } else if cursor.row > 0 {
            cursor.row -= 1
        }
    }

    // MARK: - Tabs

    func tabForward(_ count: Int) {
        cursor.pendingWrap = false
        var col = cursor.col
        for _ in 0..<max(1, count) {
            col += 1
            while col < cols - 1 && !tabStops[col] { col += 1 }
            if col >= cols - 1 {
                col = cols - 1
                break
            }
        }
        cursor.col = col
    }

    func tabBackward(_ count: Int) {
        cursor.pendingWrap = false
        var col = cursor.col
        for _ in 0..<max(1, count) {
            col -= 1
            while col > 0 && !tabStops[col] { col -= 1 }
            if col <= 0 {
                col = 0
                break
            }
        }
        cursor.col = col
    }

    // MARK: - Scrolling

    /// Scrolls the region up; lines leaving the top of the main screen go to the scrollback.
    func scrollUp(_ count: Int) {
        let height = scrollBottom - scrollTop + 1
        let count = min(max(1, count), height)
        let toScrollback = scrollTop == 0 && !isAlternateScreenActive
        let blank = blankCell
        for _ in 0..<count {
            // Moving the line out keeps its storage uniquely referenced: no copy when trimming it.
            let line = screen.remove(at: scrollTop)
            var fresh: Line
            if toScrollback, let recycled = pushToScrollback(line) {
                fresh = recycled
                fresh.cells.removeAll(keepingCapacity: true)
                fresh.cells.append(contentsOf: repeatElement(blank, count: cols))
                fresh.isWrapped = false
                fresh.clusters = [:]
            } else {
                fresh = Line(cols: cols, fill: blank)
            }
            screen.insert(fresh, at: scrollBottom)
        }
    }

    func scrollDown(_ count: Int) {
        let height = scrollBottom - scrollTop + 1
        let count = min(max(1, count), height)
        screen.removeSubrange((scrollBottom - count + 1)...scrollBottom)
        screen.insert(contentsOf: repeatElement(blankLine, count: count), at: scrollTop)
    }

    /// Appends a line to the scrollback (trailing blanks trimmed); returns the line it evicted, if any.
    @discardableResult
    func pushToScrollback(_ line: Line) -> Line? {
        var line = line
        if !line.isWrapped {
            var end = line.cells.count
            while end > 0 && line.cells[end - 1].isDefaultBlank { end -= 1 }
            if end < line.cells.count { line.cells.removeSubrange(end...) }
        }
        let evicted = scrollback.append(line)
        if evicted.dropped { linesDropped += 1 }
        return evicted.line
    }

    // MARK: - Erasing

    /// Blanks columns `start..<end` of a row, with the other halves of cut wide characters.
    func eraseCells(row: Int, from start: Int, to end: Int) {
        let start = max(0, start)
        let end = min(cols, end)
        guard start < end else { return }
        if screen[row].cells[start].width == 0 && start > 0 {
            screen[row].cells[start - 1] = blankCell
            screen[row].clusters[start - 1] = nil
        }
        if screen[row].cells[end - 1].width == 2 && end < cols {
            screen[row].cells[end] = blankCell
        }
        let blank = blankCell
        for col in start..<end { screen[row].cells[col] = blank }
        if !screen[row].clusters.isEmpty {
            for col in start..<end { screen[row].clusters[col] = nil }
        }
    }

    func eraseInDisplay(_ mode: Int) {
        switch mode {
        case 0:
            eraseInLine(0)
            for row in (cursor.row + 1)..<rows { screen[row] = blankLine }
        case 1:
            for row in 0..<cursor.row { screen[row] = blankLine }
            eraseInLine(1)
        case 2:
            for row in 0..<rows { screen[row] = blankLine }
        case 3:
            linesDropped += scrollback.count
            scrollback.removeAll()
        default:
            break
        }
    }

    func eraseInLine(_ mode: Int) {
        switch mode {
        case 0:
            eraseCells(row: cursor.row, from: cursor.col, to: cols)
            screen[cursor.row].isWrapped = false
        case 1:
            eraseCells(row: cursor.row, from: 0, to: cursor.col + 1)
        case 2:
            eraseCells(row: cursor.row, from: 0, to: cols)
            screen[cursor.row].isWrapped = false
        default:
            break
        }
    }

    // MARK: - Editing

    /// Blanks both halves of the wide character covering `col`, if any.
    func splitWideCharacter(row: Int, col: Int) {
        guard col >= 0, col < cols else { return }
        let width = screen[row].cells[col].width
        let leading = width == 0 ? col - 1 : col
        guard width != 1, leading >= 0, leading + 1 < cols else { return }
        for index in leading...(leading + 1) {
            screen[row].cells[index] = Cell(scalar: " ", attributes: screen[row].cells[index].attributes, width: 1)
            screen[row].clusters[index] = nil
        }
    }

    /// ICH: inserts blanks at the cursor, shifting the rest of the line right.
    func insertBlankCells(_ count: Int) {
        let row = cursor.row
        let col = cursor.col
        let count = min(max(1, count), cols - col)
        if screen[row].cells[col].width == 0 { splitWideCharacter(row: row, col: col) }
        var cells = screen[row].cells
        cells.insert(contentsOf: repeatElement(blankCell, count: count), at: col)
        cells.removeLast(count)
        let cutAtEnd = cells[cols - 1].width == 2
        if cutAtEnd { cells[cols - 1] = blankCell }
        screen[row].cells = cells
        shiftClusters(row: row, from: col, by: count)
        if cutAtEnd { screen[row].clusters[cols - 1] = nil }
    }

    /// DCH: deletes cells at the cursor, shifting the rest of the line left.
    func deleteCells(_ count: Int) {
        let row = cursor.row
        let col = cursor.col
        let count = min(max(1, count), cols - col)
        if screen[row].cells[col].width == 0 { splitWideCharacter(row: row, col: col) }
        if col + count < cols, screen[row].cells[col + count].width == 0 {
            splitWideCharacter(row: row, col: col + count)
        }
        var cells = screen[row].cells
        cells.removeSubrange(col..<(col + count))
        cells.append(contentsOf: repeatElement(blankCell, count: count))
        screen[row].cells = cells
        shiftClusters(row: row, from: col, by: -count)
    }

    /// Moves graphemes at or after `start` by `delta` columns, dropping those pushed out.
    func shiftClusters(row: Int, from start: Int, by delta: Int) {
        guard !screen[row].clusters.isEmpty else { return }
        var shifted: [Int: String] = [:]
        for (col, grapheme) in screen[row].clusters {
            if col < start {
                shifted[col] = grapheme
            } else if delta < 0 && col < start - delta {
                continue
            } else {
                let target = col + delta
                if target >= 0 && target < cols { shifted[target] = grapheme }
            }
        }
        screen[row].clusters = shifted
    }

    /// ECH: blanks cells from the cursor without moving it.
    func eraseCharacters(_ count: Int) {
        eraseCells(row: cursor.row, from: cursor.col, to: cursor.col + max(1, count))
    }

    /// IL: inserts blank lines at the cursor row, inside the scroll region.
    func insertLines(_ count: Int) {
        guard cursor.row >= scrollTop && cursor.row <= scrollBottom else { return }
        let count = min(max(1, count), scrollBottom - cursor.row + 1)
        screen.removeSubrange((scrollBottom - count + 1)...scrollBottom)
        screen.insert(contentsOf: repeatElement(blankLine, count: count), at: cursor.row)
        cursor.col = 0
        cursor.pendingWrap = false
    }

    /// DL: deletes lines at the cursor row, inside the scroll region.
    func deleteLines(_ count: Int) {
        guard cursor.row >= scrollTop && cursor.row <= scrollBottom else { return }
        let count = min(max(1, count), scrollBottom - cursor.row + 1)
        screen.removeSubrange(cursor.row..<(cursor.row + count))
        screen.insert(contentsOf: repeatElement(blankLine, count: count), at: scrollBottom - count + 1)
        cursor.col = 0
        cursor.pendingWrap = false
    }

    /// REP: repeats the last printed character.
    func repeatLastCharacter(_ count: Int) {
        guard let scalar = lastPrintedScalar else { return }
        let width = CharacterWidth.width(of: scalar)
        guard width > 0 else { return }
        for _ in 0..<min(max(1, count), 65_535) { put(scalar, width: width) }
    }

    /// Empties the scrollback and moves the line holding the cursor to the top of an otherwise
    /// empty screen (Clear Scrollback). The alternate screen is left alone.
    public func clearScrollbackKeepingCursorLine() {
        if !isAlternateScreenActive {
            var first = cursor.row
            while first > 0 && screen[first - 1].isWrapped { first -= 1 }
            var last = cursor.row
            while last < rows - 1 && screen[last].isWrapped { last += 1 }
            let kept = Array(screen[first...last])
            screen = kept + Array(repeating: Line(cols: cols), count: rows - kept.count)
            cursor.row -= first
            // Discarded screen lines count as dropped so absolute line indices stay stable.
            linesDropped += first
        }
        linesDropped += scrollback.count
        scrollback.removeAll()
        lastPrinted = nil
    }

    /// DECALN: fills the screen with `E`.
    func screenAlignmentTest() {
        let cell = Cell(scalar: "E")
        for row in 0..<rows { screen[row] = Line(cols: cols, fill: cell) }
        scrollTop = 0
        scrollBottom = rows - 1
        moveCursor(row: 0, col: 0)
    }
}
