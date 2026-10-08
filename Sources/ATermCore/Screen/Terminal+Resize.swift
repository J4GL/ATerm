/// Resizing: the main screen and its scrollback reflow, the alternate screen is
/// truncated or padded. See SPEC/screen/resize.md.
extension Terminal {
    public func resize(cols newCols: Int, rows newRows: Int) {
        let newCols = max(1, newCols)
        let newRows = max(1, newRows)
        guard newCols != cols || newRows != rows else { return }

        var saved = savedCursorMain?.cursor
        if isAlternateScreenActive {
            var alternateRow = cursor.row
            Self.resizeWithoutReflow(&screen, cursorRow: &alternateRow, cols: newCols, rows: newRows)
            cursor.row = alternateRow
            // The hidden main screen reflows around the cursor it had when the alternate screen was entered.
            var mainCursor = mainCursorWhileAlternate ?? Cursor()
            resizeMainScreen(&inactiveScreen, cursor: &mainCursor, saved: &saved, newCols: newCols, newRows: newRows)
            mainCursorWhileAlternate = mainCursor
        } else {
            resizeMainScreen(&screen, cursor: &cursor, saved: &saved, newCols: newCols, newRows: newRows)
            var unusedRow = 0
            Self.resizeWithoutReflow(&inactiveScreen, cursorRow: &unusedRow, cols: newCols, rows: newRows)
        }
        if let saved, var savedMain = savedCursorMain {
            savedMain.cursor = saved
            savedCursorMain = savedMain
        }

        let oldCols = cols
        cols = newCols
        rows = newRows
        scrollTop = 0
        scrollBottom = newRows - 1
        tabStops = (0..<newCols).map { col in
            col < oldCols ? tabStops[col] : (col > 0 && col % 8 == 0)
        }
        cursor.row = min(cursor.row, newRows - 1)
        cursor.col = min(cursor.col, newCols - 1)
        if cursor.col < newCols - 1 { cursor.pendingWrap = false }
        if var saved = savedCursorAlternate {
            saved.cursor.row = min(saved.cursor.row, newRows - 1)
            saved.cursor.col = min(saved.cursor.col, newCols - 1)
            savedCursorAlternate = saved
        }
        lastPrinted = nil
    }

    // MARK: - Alternate screen

    static func resizeWithoutReflow(_ lines: inout [Line], cursorRow: inout Int, cols: Int, rows: Int) {
        for index in lines.indices {
            lines[index] = resizedLine(lines[index], cols: cols)
        }
        if lines.count > rows {
            let dropTop = max(0, cursorRow - (rows - 1))
            lines.removeFirst(dropTop)
            cursorRow -= dropTop
            lines.removeLast(lines.count - rows)
        } else {
            lines.append(contentsOf: repeatElement(Line(cols: cols), count: rows - lines.count))
        }
    }

    private static func resizedLine(_ line: Line, cols: Int) -> Line {
        var line = line
        line.isWrapped = false
        if line.cells.count > cols {
            line.cells.removeSubrange(cols...)
            if line.cells[cols - 1].width == 2 {
                line.cells[cols - 1] = .blank
                line.clusters[cols - 1] = nil
            }
            line.clusters = line.clusters.filter { $0.key < cols }
        } else if line.cells.count < cols {
            line.cells.append(contentsOf: repeatElement(.blank, count: cols - line.cells.count))
        }
        return line
    }

    // MARK: - Main screen

    private func resizeMainScreen(_ lines: inout [Line], cursor: inout Cursor, saved: inout Cursor?,
                                  newCols: Int, newRows: Int) {
        if newCols == cols {
            resizeRows(&lines, cursor: &cursor, saved: &saved, newRows: newRows)
        } else {
            reflowMainScreen(&lines, cursor: &cursor, saved: &saved, newCols: newCols, newRows: newRows)
        }
    }

    /// Height-only change: lines move between the screen and the scrollback, the cursor line stays visible.
    private func resizeRows(_ lines: inout [Line], cursor: inout Cursor, saved: inout Cursor?, newRows: Int) {
        let used = Array(lines[0...Self.lastUsedRow(lines, cursorRow: cursor.row)])
        let historyCount = scrollback.count
        let cursorIndex = historyCount + cursor.row
        let top = min(max(0, historyCount + used.count - newRows), cursorIndex)
        var newScreen: [Line]
        if top >= historyCount {
            let pushed = top - historyCount
            for line in used[0..<pushed] { pushToScrollback(line) }
            newScreen = Array(used[pushed...].prefix(newRows))
        } else {
            newScreen = scrollback.removeLast(historyCount - top).map { Self.padded($0, cols: cols) }
            newScreen.append(contentsOf: used.prefix(newRows - newScreen.count))
        }
        newScreen.append(contentsOf: repeatElement(Line(cols: cols), count: newRows - newScreen.count))
        lines = newScreen
        // Every line moved by the same amount.
        let shift = historyCount - top
        cursor.row += shift
        if var moved = saved {
            moved.row = min(max(0, moved.row + shift), newRows - 1)
            saved = moved
        }
    }

    private static func padded(_ line: Line, cols: Int) -> Line {
        var line = line
        if line.cells.count < cols {
            line.cells.append(contentsOf: repeatElement(.blank, count: cols - line.cells.count))
        }
        return line
    }

    /// The cursor row or the last non-blank row below it.
    private static func lastUsedRow(_ lines: [Line], cursorRow: Int) -> Int {
        let cursorRow = min(cursorRow, lines.count - 1)
        for row in stride(from: lines.count - 1, to: cursorRow, by: -1) where !isBlank(lines[row]) {
            return row
        }
        return cursorRow
    }

    private struct LogicalLine {
        var cells: [Cell] = []
        var clusters: [Int: String] = [:]
    }

    /// A position followed through the reflow (the cursor, the saved cursor).
    private struct Marker {
        var physicalRow: Int
        var col: Int
        var pendingWrap: Bool
        var logicalLine = 0
        var offset = 0
        var result = Position(row: 0, col: 0)
        var resultPendingWrap = false
    }

    private func reflowMainScreen(_ lines: inout [Line], cursor: inout Cursor, saved: inout Cursor?,
                                  newCols: Int, newRows: Int) {
        // 1. Physical lines: the scrollback, then the screen down to the cursor or the last non-blank row.
        let lastUsedRow = Self.lastUsedRow(lines, cursorRow: cursor.row)
        var physical = scrollback.allLines
        let history = physical.count
        physical.append(contentsOf: lines[0...lastUsedRow])
        var markers = [Marker(physicalRow: history + cursor.row, col: cursor.col, pendingWrap: cursor.pendingWrap)]
        if let saved {
            markers.append(Marker(physicalRow: history + min(saved.row, lastUsedRow), col: saved.col,
                                  pendingWrap: saved.pendingWrap))
        }

        // 2. Join soft-wrapped lines into logical lines, locating the markers in them.
        var logical: [LogicalLine] = []
        var current = LogicalLine()
        for (index, line) in physical.enumerated() {
            let base = current.cells.count
            for m in markers.indices where markers[m].physicalRow == index {
                markers[m].logicalLine = logical.count
                markers[m].offset = base + markers[m].col + (markers[m].pendingWrap ? 1 : 0)
            }
            var cells = line.cells
            if line.isWrapped {
                // The padding left by a wrapped wide character is not text.
                if let last = cells.last, last.isWidePadding { cells.removeLast() }
            } else {
                var end = cells.count
                while end > 0 && cells[end - 1].isDefaultBlank { end -= 1 }
                cells.removeSubrange(end...)
            }
            for (col, grapheme) in line.clusters where col < cells.count {
                current.clusters[base + col] = grapheme
            }
            current.cells.append(contentsOf: cells)
            if !line.isWrapped {
                logical.append(current)
                current = LogicalLine()
            }
        }
        if !current.cells.isEmpty { logical.append(current) }
        if logical.isEmpty { logical.append(LogicalLine()) }

        // 3. Split every logical line at the new width.
        var output: [Line] = []
        for (index, logicalLine) in logical.enumerated() {
            let tracked = markers.indices.filter { markers[$0].logicalLine == index }
            var line = Line(cols: newCols)
            var col = 0
            var positions: [Position] = []
            if !tracked.isEmpty { positions.reserveCapacity(logicalLine.cells.count) }
            for (offset, cell) in logicalLine.cells.enumerated() {
                if cell.width == 0 {
                    if !tracked.isEmpty { positions.append(Position(row: output.count, col: max(0, col - 1))) }
                    continue
                }
                let width = Int(cell.width)
                if width > newCols {
                    if !tracked.isEmpty { positions.append(Position(row: output.count, col: col)) }
                    continue
                }
                if col + width > newCols {
                    for padding in col..<newCols {
                        line.cells[padding] = Cell.widePadding(background: cell.attributes.background)
                    }
                    line.isWrapped = true
                    output.append(line)
                    line = Line(cols: newCols)
                    col = 0
                }
                line.cells[col] = cell
                if width == 2 {
                    let trailing = offset + 1 < logicalLine.cells.count ? logicalLine.cells[offset + 1] : cell
                    line.cells[col + 1] = Cell(scalar: " ", attributes: trailing.attributes, width: 0)
                }
                if let grapheme = logicalLine.clusters[offset] { line.clusters[col] = grapheme }
                if !tracked.isEmpty { positions.append(Position(row: output.count, col: col)) }
                col += width
            }
            output.append(line)

            let isLastLine = index == logical.count - 1
            for m in tracked {
                let offset = markers[m].offset
                if offset < positions.count {
                    markers[m].result = positions[offset]
                    continue
                }
                // Past the text: extrapolate from its end, staying on this line unless it is the last one.
                var row = output.count - 1
                var column = col + (offset - logicalLine.cells.count)
                if offset == logicalLine.cells.count && column == newCols && column > 0 {
                    column = newCols - 1
                    markers[m].resultPendingWrap = true
                } else if column >= newCols && !isLastLine {
                    column = newCols - 1
                } else {
                    while column >= newCols {
                        column -= newCols
                        row += 1
                    }
                }
                markers[m].result = Position(row: row, col: column)
            }
        }
        let cursorRow = markers[0].result.row
        while output.count <= cursorRow { output.append(Line(cols: newCols)) }

        // 4. The screen shows the last rows ending with the cursor; lines above go to the scrollback.
        var top = max(0, output.count - newRows)
        top = min(top, cursorRow)
        var newScreen = Array(output[top..<min(output.count, top + newRows)])
        newScreen.append(contentsOf: repeatElement(Line(cols: newCols), count: newRows - newScreen.count))
        lines = newScreen

        let historyLines = output[0..<top].map { line -> Line in
            var line = line
            if !line.isWrapped {
                var end = line.cells.count
                while end > 0 && line.cells[end - 1].isDefaultBlank { end -= 1 }
                line.cells.removeSubrange(end...)
            }
            return line
        }
        linesDropped += scrollback.replace(with: historyLines)

        cursor.row = cursorRow - top
        cursor.col = min(markers[0].result.col, newCols - 1)
        cursor.pendingWrap = markers[0].resultPendingWrap
        if var moved = saved, markers.count > 1 {
            moved.row = min(max(0, markers[1].result.row - top), newRows - 1)
            moved.col = min(markers[1].result.col, newCols - 1)
            moved.pendingWrap = false
            saved = moved
        }
    }

    private static func isBlank(_ line: Line) -> Bool {
        line.cells.allSatisfy(\.isDefaultBlank)
    }
}
