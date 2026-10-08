import AppKit
import CoreText
import ATermCore

struct GlyphKey: Hashable {
    let scalar: UInt32
    let bold: Bool
    let italic: Bool
}

/// A glyph ready to draw: its font (the terminal font or a fallback, scaled to fit) and horizontal offset.
struct GlyphEntry {
    let font: CTFont
    let glyph: CGGlyph
    let offset: CGFloat
}

/// Rendering: backgrounds, glyphs, decorations, cursor and marked text. See SPEC/app/rendering.md.
extension TerminalView {
    private struct Colors {
        var foreground: RGB
        var background: RGB
    }

    private struct Defaults {
        let foreground: RGB
        let background: RGB
    }

    /// Glyphs sharing a font, a color and a baseline, drawn in one call.
    private struct GlyphRun {
        var font: CTFont?
        var color: RGB?
        var glyphs: [CGGlyph] = []
        var xs: [CGFloat] = []
        var baseline: CGFloat = 0
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let palette = terminal.palette
        let reverse = terminal.modes.reverseVideo
        let defaults = Defaults(foreground: reverse ? palette.background : palette.foreground,
                                background: reverse ? palette.foreground : palette.background)
        context.setFillColor(cgColor(defaults.background))
        context.fill(dirtyRect)

        let rows = terminal.rows
        let firstRow = max(0, Int((dirtyRect.minY - Self.padding.height) / cellSize.height))
        let lastRow = min(rows - 1, Int((dirtyRect.maxY - Self.padding.height) / cellSize.height))
        let selectionRange = selection.map { terminal.selectionRange($0) }
        let firstLine = firstDisplayedLineIndex
        if firstRow <= lastRow {
            for row in firstRow...lastRow {
                drawRow(row, line: displayedLine(row), absoluteLine: firstLine + row, selection: selectionRange,
                        defaults: defaults, palette: palette, context: context)
            }
        }
        drawCursor(defaults: defaults, palette: palette, context: context)
        drawMarkedText(defaults: defaults, context: context)
        if showsActiveFrame {
            // Along the inside of the bounds, in the padding: never over a cell.
            context.setStrokeColor(cgColor(Self.accentColor))
            context.setLineWidth(1)
            context.stroke(bounds.insetBy(dx: 0.5, dy: 0.5))
        }
    }

    // MARK: - Rows

    private func colors(of cell: Cell, selected: Bool, defaults: Defaults, palette: Palette) -> Colors {
        let attributes = cell.attributes
        var foreground = palette.resolve(attributes.foreground, fallback: defaults.foreground)
        var background = palette.resolve(attributes.background, fallback: defaults.background)
        if attributes.flags.contains(.inverse) { swap(&foreground, &background) }
        if attributes.flags.contains(.dim) { foreground = Self.blend(foreground, background) }
        if attributes.flags.contains(.hidden) { foreground = background }
        if selected { background = Self.selectionColor }
        return Colors(foreground: foreground, background: background)
    }

    private static func blend(_ a: RGB, _ b: RGB) -> RGB {
        RGB(UInt8((Int(a.r) + Int(b.r)) / 2), UInt8((Int(a.g) + Int(b.g)) / 2), UInt8((Int(a.b) + Int(b.b)) / 2))
    }

    private func drawRow(_ row: Int, line: Line, absoluteLine: Int, selection: ClosedRange<SelectionPoint>?,
                         defaults: Defaults, palette: Palette, context: CGContext) {
        let cols = terminal.cols
        let cells = line.cells
        let top = Self.padding.height + CGFloat(row) * cellSize.height
        func isSelected(_ col: Int) -> Bool {
            guard let selection else { return false }
            return selection.contains(SelectionPoint(line: absoluteLine, col: col))
        }
        func cell(_ col: Int) -> Cell { col < cells.count ? cells[col] : .blank }

        // Backgrounds, merged into runs of the same color.
        var col = 0
        while col < cols {
            let background = colors(of: cell(col), selected: isSelected(col), defaults: defaults, palette: palette).background
            var end = col + 1
            while end < cols,
                  colors(of: cell(end), selected: isSelected(end), defaults: defaults, palette: palette).background == background {
                end += 1
            }
            if background != defaults.background {
                context.setFillColor(cgColor(background))
                context.fill(CGRect(x: Self.padding.width + CGFloat(col) * cellSize.width, y: top,
                                    width: CGFloat(end - col) * cellSize.width, height: cellSize.height))
            }
            col = end
        }

        // Glyphs.
        let baseline = top + fonts.baseline
        var run = GlyphRun(baseline: baseline)
        for col in 0..<min(cols, cells.count) {
            let cell = cells[col]
            guard cell.width != 0 else { continue }
            let cluster = line.cluster(at: col)
            guard !cell.isBlank || cluster != nil else { continue }
            let attributes = cell.attributes
            guard !attributes.flags.contains(.hidden) else { continue }
            let foreground = colors(of: cell, selected: isSelected(col), defaults: defaults, palette: palette).foreground
            let x = Self.padding.width + CGFloat(col) * cellSize.width
            let bold = attributes.flags.contains(.bold)
            let italic = attributes.flags.contains(.italic)
            if let cluster {
                flush(&run, context: context)
                drawCluster(cluster, x: x, baseline: baseline, cells: Int(cell.width), bold: bold, italic: italic,
                            color: foreground, context: context)
                continue
            }
            if BoxDrawing.handles(cell.scalar) {
                flush(&run, context: context)
                BoxDrawing.draw(cell.scalar, in: CGRect(x: x, y: top, width: cellSize.width, height: cellSize.height),
                                color: cgColor(foreground), scale: backingScale, context: context)
                continue
            }
            guard let entry = glyphEntry(for: cell.scalar, bold: bold, italic: italic, cells: Int(cell.width)) else {
                continue
            }
            if run.font !== entry.font || run.color != foreground {
                flush(&run, context: context)
                run.font = entry.font
                run.color = foreground
            }
            run.glyphs.append(entry.glyph)
            run.xs.append(x + entry.offset)
        }
        flush(&run, context: context)

        // Decorations.
        for col in 0..<min(cols, cells.count) {
            let cell = cells[col]
            let attributes = cell.attributes
            guard cell.width != 0,
                  attributes.underline != .none || !attributes.flags.isDisjoint(with: [.strikethrough, .overline])
            else { continue }
            let foreground = colors(of: cell, selected: isSelected(col), defaults: defaults, palette: palette).foreground
            let x = Self.padding.width + CGFloat(col) * cellSize.width
            let width = cellSize.width * CGFloat(max(1, Int(cell.width)))
            drawDecorations(attributes, x: x, width: width, top: top, baseline: baseline, foreground: foreground,
                            palette: palette, context: context)
        }
    }

    private func flush(_ run: inout GlyphRun, context: CGContext) {
        if let font = run.font, let color = run.color, !run.glyphs.isEmpty {
            drawGlyphs(font, run.glyphs, xs: run.xs, baseline: run.baseline, color: color, context: context)
        }
        run.glyphs.removeAll(keepingCapacity: true)
        run.xs.removeAll(keepingCapacity: true)
    }

    /// Draws glyphs on a baseline given in view coordinates: the text space is flipped
    /// back to y-up around the baseline so glyphs stand upright in this flipped view.
    private func drawGlyphs(_ font: CTFont, _ glyphs: [CGGlyph], xs: [CGFloat], baseline: CGFloat, color: RGB,
                            context: CGContext) {
        context.saveGState()
        context.translateBy(x: 0, y: baseline)
        context.scaleBy(x: 1, y: -1)
        context.textMatrix = .identity
        context.setFillColor(cgColor(color))
        let positions = xs.map { CGPoint(x: $0, y: 0) }
        CTFontDrawGlyphs(font, glyphs, positions, glyphs.count, context)
        context.restoreGState()
    }

    private func drawDecorations(_ attributes: Attributes, x: CGFloat, width: CGFloat, top: CGFloat, baseline: CGFloat,
                                 foreground: RGB, palette: Palette, context: CGContext) {
        let thickness = fonts.lineThickness
        if attributes.underline != .none {
            let color = attributes.underlineColor == .default
                ? foreground : palette.resolve(attributes.underlineColor, fallback: foreground)
            context.setFillColor(cgColor(color))
            context.setStrokeColor(cgColor(color))
            let y = min(baseline + fonts.underlineOffset, top + cellSize.height - thickness)
            switch attributes.underline {
            case .none:
                break
            case .single:
                context.fill(CGRect(x: x, y: y, width: width, height: thickness))
            case .double:
                let lower = min(y + thickness * 2, top + cellSize.height - thickness)
                context.fill(CGRect(x: x, y: lower - thickness * 2, width: width, height: thickness))
                context.fill(CGRect(x: x, y: lower, width: width, height: thickness))
            case .curly:
                let amplitude = max(thickness, 1.5)
                let path = CGMutablePath()
                let steps = 8
                path.move(to: CGPoint(x: x, y: y))
                for step in 1...steps {
                    let px = x + width * CGFloat(step) / CGFloat(steps)
                    let py = y + (step % 2 == 0 ? 0 : amplitude)
                    path.addLine(to: CGPoint(x: px, y: py))
                }
                context.setLineWidth(thickness)
                context.addPath(path)
                context.strokePath()
            case .dotted, .dashed:
                let segment = attributes.underline == .dotted ? thickness * 2 : cellSize.width / 2
                var position = x
                while position < x + width {
                    context.fill(CGRect(x: position, y: y, width: min(segment, x + width - position), height: thickness))
                    position += segment * 2
                }
            }
        }
        context.setFillColor(cgColor(foreground))
        if attributes.flags.contains(.strikethrough) {
            let y = alignedToPixel(baseline - fonts.strikethroughOffset - thickness / 2)
            context.fill(CGRect(x: x, y: y, width: width, height: thickness))
        }
        if attributes.flags.contains(.overline) {
            context.fill(CGRect(x: x, y: top, width: width, height: thickness))
        }
    }

    // MARK: - Glyphs

    /// The glyph for a character, from the terminal font or a fallback font scaled to fit its cells.
    func glyphEntry(for scalar: Unicode.Scalar, bold: Bool, italic: Bool, cells: Int) -> GlyphEntry? {
        let key = GlyphKey(scalar: scalar.value, bold: bold, italic: italic)
        if let cached = glyphCache[key] { return cached.glyph == 0 ? nil : cached }
        let font = fonts.font(bold: bold, italic: italic)
        let text = String(scalar)
        var characters = Array(text.utf16)
        var glyphs = [CGGlyph](repeating: 0, count: characters.count)
        var chosen = font
        if !CTFontGetGlyphsForCharacters(font, &characters, &glyphs, characters.count) || glyphs[0] == 0 {
            chosen = CTFontCreateForString(font, text as CFString, CFRange(location: 0, length: characters.count))
            glyphs = [CGGlyph](repeating: 0, count: characters.count)
            CTFontGetGlyphsForCharacters(chosen, &characters, &glyphs, characters.count)
        }
        var offset: CGFloat = 0
        if chosen !== font, glyphs[0] != 0 {
            var advance = CGSize.zero
            CTFontGetAdvancesForGlyphs(chosen, .horizontal, &glyphs, &advance, 1)
            let available = cellSize.width * CGFloat(max(1, cells))
            if advance.width > available {
                chosen = CTFontCreateCopyWithAttributes(chosen, CTFontGetSize(chosen) * available / advance.width, nil, nil)
                advance.width = available
            }
            offset = max(0, (available - advance.width) / 2)
        }
        let entry = GlyphEntry(font: chosen, glyph: glyphs[0], offset: offset)
        glyphCache[key] = entry
        return glyphs[0] == 0 ? nil : entry
    }

    /// Draws a multi-scalar grapheme (combining marks, emoji sequences) with Core Text shaping.
    private func drawCluster(_ text: String, x: CGFloat, baseline: CGFloat, cells: Int, bold: Bool, italic: Bool,
                             color: RGB, context: CGContext) {
        let attributes: [CFString: Any] = [
            kCTFontAttributeName: fonts.font(bold: bold, italic: italic),
            kCTForegroundColorFromContextAttributeName: true,
        ]
        let string = CFAttributedStringCreate(nil, text as CFString, attributes as CFDictionary)!
        let line = CTLineCreateWithAttributedString(string)
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        let available = cellSize.width * CGFloat(max(1, cells))
        let factor = width > available && width > 0 ? available / width : 1
        context.saveGState()
        context.setFillColor(cgColor(color))
        context.translateBy(x: x, y: baseline)
        context.scaleBy(x: factor, y: -factor)
        context.textMatrix = .identity
        context.textPosition = CGPoint(x: factor < 1 ? 0 : (available - width) / 2, y: 0)
        CTLineDraw(line, context)
        context.restoreGState()
    }

    /// Draws one cell's character in the given color (used for text under a block cursor).
    private func drawCharacter(of line: Line, col: Int, color: RGB, context: CGContext, top: CGFloat) {
        guard col < line.cells.count else { return }
        let cell = line.cells[col]
        guard cell.width != 0 else { return }
        let x = Self.padding.width + CGFloat(col) * cellSize.width
        let bold = cell.attributes.flags.contains(.bold)
        let italic = cell.attributes.flags.contains(.italic)
        if let cluster = line.cluster(at: col) {
            drawCluster(cluster, x: x, baseline: top + fonts.baseline, cells: Int(cell.width), bold: bold, italic: italic,
                        color: color, context: context)
        } else if BoxDrawing.handles(cell.scalar) {
            BoxDrawing.draw(cell.scalar, in: CGRect(x: x, y: top, width: cellSize.width, height: cellSize.height),
                            color: cgColor(color), scale: backingScale, context: context)
        } else if !cell.isBlank, let entry = glyphEntry(for: cell.scalar, bold: bold, italic: italic, cells: Int(cell.width)) {
            drawGlyphs(entry.font, [entry.glyph], xs: [x + entry.offset], baseline: top + fonts.baseline, color: color,
                       context: context)
        }
    }

    // MARK: - Cursor and marked text

    private func drawCursor(defaults: Defaults, palette: Palette, context: CGContext) {
        guard terminal.cursorVisible, effectiveScrollOffset == 0, markedText == nil, blinkVisible else { return }
        let rect = cursorRect()
        let color = cgColor(palette.cursor)
        let position = terminal.cursorPosition
        switch terminal.cursorShape {
        case .block:
            if isFocused {
                context.setFillColor(color)
                context.fill(rect)
                let line = terminal.line(position.row)
                let col = Int(((rect.minX - Self.padding.width) / cellSize.width).rounded())
                drawCharacter(of: line, col: col, color: defaults.background, context: context, top: rect.minY)
            } else {
                context.setStrokeColor(color)
                context.setLineWidth(1)
                context.stroke(rect.insetBy(dx: 0.5, dy: 0.5))
            }
        case .underline:
            let height = max(2 / backingScale, (cellSize.height * 0.1 * backingScale).rounded() / backingScale)
            context.setFillColor(color)
            context.fill(CGRect(x: rect.minX, y: rect.maxY - height, width: rect.width, height: height))
        case .bar:
            let width = max(2 / backingScale, (1.5 * backingScale).rounded() / backingScale)
            context.setFillColor(color)
            context.fill(CGRect(x: rect.minX, y: rect.minY, width: width, height: rect.height))
        }
    }

    /// Text being composed by an input method, drawn underlined at the cursor.
    private func drawMarkedText(defaults: Defaults, context: CGContext) {
        guard let markedText, markedText.length > 0 else { return }
        let position = terminal.cursorPosition
        var col = position.col
        let top = Self.padding.height + CGFloat(position.row) * cellSize.height
        let baseline = top + fonts.baseline
        for character in markedText.string {
            let scalar = character.unicodeScalars.first!
            let width = max(1, CharacterWidth.width(of: scalar))
            guard col + width <= terminal.cols else { break }
            let x = Self.padding.width + CGFloat(col) * cellSize.width
            let cellWidth = cellSize.width * CGFloat(width)
            context.setFillColor(cgColor(defaults.background))
            context.fill(CGRect(x: x, y: top, width: cellWidth, height: cellSize.height))
            if character.unicodeScalars.count > 1 {
                drawCluster(String(character), x: x, baseline: baseline, cells: width, bold: false, italic: false,
                            color: defaults.foreground, context: context)
            } else if let entry = glyphEntry(for: scalar, bold: false, italic: false, cells: width) {
                drawGlyphs(entry.font, [entry.glyph], xs: [x + entry.offset], baseline: baseline,
                           color: defaults.foreground, context: context)
            }
            context.setFillColor(cgColor(defaults.foreground))
            let thickness = fonts.lineThickness
            context.fill(CGRect(x: x, y: top + cellSize.height - thickness * 2, width: cellWidth, height: thickness))
            col += width
        }
    }

    /// Rounds a coordinate to the device pixel grid so thin lines stay crisp.
    func alignedToPixel(_ value: CGFloat) -> CGFloat {
        (value * backingScale).rounded() / backingScale
    }

    func cgColor(_ rgb: RGB) -> CGColor {
        if let cached = colorCache[rgb] { return cached }
        let color = CGColor(srgbRed: CGFloat(rgb.r) / 255, green: CGFloat(rgb.g) / 255, blue: CGFloat(rgb.b) / 255, alpha: 1)
        colorCache[rgb] = color
        return color
    }
}
