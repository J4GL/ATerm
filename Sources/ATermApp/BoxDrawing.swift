import CoreGraphics

/// Draws box-drawing characters (U+2500–U+257F) and block elements (U+2580–U+259F)
/// geometrically, so lines join across cells without the gaps font glyphs leave.
/// See SPEC/app/rendering.md (APP-RENDER-006).
enum BoxDrawing {
    static func handles(_ scalar: Unicode.Scalar) -> Bool {
        (0x2500...0x259F).contains(scalar.value)
    }

    /// Weights of the four arms, in order up, right, down, left: 0 none, 1 light, 2 heavy, 3 double.
    private static let arms: [String] = [
        "0101", "0202", "1010", "2020", "0101", "0202", "1010", "2020", "0101", "0202", "1010", "2020",
        "0110", "0210", "0120", "0220", "0011", "0012", "0021", "0022", "1100", "1200", "2100", "2200",
        "1001", "1002", "2001", "2002", "1110", "1210", "2110", "1120", "2120", "2210", "1220", "2220",
        "1011", "1012", "2011", "1021", "2021", "2012", "1022", "2022", "0111", "0112", "0211", "0212",
        "0121", "0122", "0221", "0222", "1101", "1102", "1201", "1202", "2101", "2102", "2201", "2202",
        "1111", "1112", "1211", "1212", "2111", "1121", "2121", "2112", "2211", "1122", "1221", "2212",
        "1222", "2122", "2221", "2222", "0101", "0202", "1010", "2020", "0303", "3030", "0310", "0130",
        "0330", "0013", "0031", "0033", "1300", "3100", "3300", "1003", "3001", "3003", "1310", "3130",
        "3330", "1013", "3031", "3033", "0313", "0131", "0333", "1303", "3101", "3303", "1313", "3131",
        "3333", "0110", "0011", "1001", "1100", "0000", "0000", "0000", "0001", "1000", "0100", "0010",
        "0002", "2000", "0200", "0020", "0201", "1020", "0102", "2010",
    ]

    /// Number of dashes of the dashed line characters.
    private static let dashes: [UInt32: Int] = [
        0x2504: 3, 0x2505: 3, 0x2506: 3, 0x2507: 3, 0x2508: 4, 0x2509: 4, 0x250A: 4, 0x250B: 4,
        0x254C: 2, 0x254D: 2, 0x254E: 2, 0x254F: 2,
    ]

    private struct Geometry {
        let rect: CGRect
        let scale: CGFloat
        let light: CGFloat
        let heavy: CGFloat

        init(rect: CGRect, scale: CGFloat) {
            self.rect = rect
            self.scale = scale
            light = max(1 / scale, (rect.width / 8 * scale).rounded() / scale)
            heavy = light * 2
        }

        func align(_ value: CGFloat) -> CGFloat { (value * scale).rounded() / scale }
        /// Left edge of a vertical line of thickness `t` centered in the cell.
        func x0(_ t: CGFloat) -> CGFloat { align(rect.minX + (rect.width - t) / 2) }
        /// Top edge of a horizontal line of thickness `t` centered in the cell.
        func y0(_ t: CGFloat) -> CGFloat { align(rect.minY + (rect.height - t) / 2) }
        func thickness(_ weight: Int) -> CGFloat { weight == 2 ? heavy : light }
    }

    /// Draws `scalar` filling `rect`; returns false when it is not handled here.
    @discardableResult
    static func draw(_ scalar: Unicode.Scalar, in rect: CGRect, color: CGColor, scale: CGFloat,
                     context: CGContext) -> Bool {
        let value = scalar.value
        guard handles(scalar) else { return false }
        let geometry = Geometry(rect: rect, scale: scale)
        context.saveGState()
        defer { context.restoreGState() }
        context.setFillColor(color)
        context.setStrokeColor(color)
        if value >= 0x2580 {
            drawBlock(value, geometry, color: color, context: context)
            return true
        }
        switch value {
        case 0x256D...0x2570:
            drawArc(value, geometry, context: context)
        case 0x2571...0x2573:
            drawDiagonals(value, geometry, context: context)
        default:
            let weights = arms[Int(value - 0x2500)].map { Int(String($0))! }
            if let count = dashes[value] {
                drawDashes(weights, count: count, geometry, context: context)
            } else if weights.contains(3) {
                drawDouble(weights, geometry, context: context)
            } else {
                drawLines(weights, geometry, context: context)
            }
        }
        return true
    }

    // MARK: - Light and heavy lines

    private static func drawLines(_ weights: [Int], _ g: Geometry, context: CGContext) {
        let (up, right, down, left) = (weights[0], weights[1], weights[2], weights[3])
        let rect = g.rect
        let verticals = [up, down].filter { $0 > 0 }.map(g.thickness)
        let horizontals = [left, right].filter { $0 > 0 }.map(g.thickness)
        // Horizontal arms reach the far side of the thickest vertical arm, and vice versa.
        let verticalLeft = verticals.map(g.x0).min()
        let verticalRight = verticals.map { g.x0($0) + $0 }.max()
        let horizontalTop = horizontals.map(g.y0).min()
        let horizontalBottom = horizontals.map { g.y0($0) + $0 }.max()
        if left > 0 {
            let t = g.thickness(left)
            let end = verticalRight ?? g.x0(t) + t
            context.fill(CGRect(x: rect.minX, y: g.y0(t), width: end - rect.minX, height: t))
        }
        if right > 0 {
            let t = g.thickness(right)
            let start = verticalLeft ?? g.x0(t)
            context.fill(CGRect(x: start, y: g.y0(t), width: rect.maxX - start, height: t))
        }
        if up > 0 {
            let t = g.thickness(up)
            let end = horizontalBottom ?? g.y0(t) + t
            context.fill(CGRect(x: g.x0(t), y: rect.minY, width: t, height: end - rect.minY))
        }
        if down > 0 {
            let t = g.thickness(down)
            let start = horizontalTop ?? g.y0(t)
            context.fill(CGRect(x: g.x0(t), y: start, width: t, height: rect.maxY - start))
        }
    }

    private static func drawDashes(_ weights: [Int], count: Int, _ g: Geometry, context: CGContext) {
        let rect = g.rect
        let horizontal = weights[1] > 0
        let t = g.thickness(max(weights[0], weights[1]))
        let length = (horizontal ? rect.width : rect.height) / CGFloat(count)
        for index in 0..<count {
            let start = g.align(CGFloat(index) * length + length * 0.2)
            let dash = max(1 / g.scale, g.align(length * 0.6))
            if horizontal {
                context.fill(CGRect(x: rect.minX + start, y: g.y0(t), width: dash, height: t))
            } else {
                context.fill(CGRect(x: g.x0(t), y: rect.minY + start, width: t, height: dash))
            }
        }
    }

    // MARK: - Double lines

    /// Double lines are two rails around the light center line; single arms meet the rails.
    private static func drawDouble(_ weights: [Int], _ g: Geometry, context: CGContext) {
        let rect = g.rect
        let light = g.light
        let lx = g.x0(light)
        let ly = g.y0(light)
        let (up, right, down, left) = (weights[0] == 3, weights[1] == 3, weights[2] == 3, weights[3] == 3)
        let verticalRails = up || down
        let horizontalRails = left || right

        func fillH(_ y: CGFloat, _ x0: CGFloat, _ x1: CGFloat) {
            if x1 > x0 { context.fill(CGRect(x: x0, y: y, width: x1 - x0, height: light)) }
        }
        func fillV(_ x: CGFloat, _ y0: CGFloat, _ y1: CGFloat) {
            if y1 > y0 { context.fill(CGRect(x: x, y: y0, width: light, height: y1 - y0)) }
        }

        // Horizontal rails: top at ly - light, bottom at ly + light.
        if horizontalRails {
            for (y, blocker, opposite) in [(ly - light, up, down), (ly + light, down, up)] {
                if left && right && !blocker {
                    fillH(y, rect.minX, rect.maxX)
                    continue
                }
                let innerEnd = lx, outerEnd = lx + 2 * light, center = lx + light
                let innerStart = lx + light, outerStart = lx - light
                if left {
                    let end = blocker ? innerEnd : (opposite ? outerEnd : center)
                    fillH(y, rect.minX, end)
                }
                if right {
                    let start = blocker ? innerStart : (opposite ? outerStart : lx)
                    fillH(y, start, rect.maxX)
                }
            }
        }
        // Vertical rails: left at lx - light, right at lx + light.
        if verticalRails {
            for (x, blocker, opposite) in [(lx - light, left, right), (lx + light, right, left)] {
                if up && down && !blocker {
                    fillV(x, rect.minY, rect.maxY)
                    continue
                }
                if up {
                    let end = blocker ? ly : (opposite ? ly + 2 * light : ly + light)
                    fillV(x, rect.minY, end)
                }
                if down {
                    let start = blocker ? ly + light : (opposite ? ly - light : ly)
                    fillV(x, start, rect.maxY)
                }
            }
        }
        // Single arms of mixed characters meet the rails.
        if weights[3] == 1 { fillH(ly, rect.minX, verticalRails ? lx : lx + light) }
        if weights[1] == 1 { fillH(ly, verticalRails ? lx + light : lx, rect.maxX) }
        if weights[0] == 1 { fillV(lx, rect.minY, horizontalRails ? ly : ly + light) }
        if weights[2] == 1 { fillV(lx, horizontalRails ? ly + light : ly, rect.maxY) }
    }

    // MARK: - Arcs and diagonals

    private static func drawArc(_ value: UInt32, _ g: Geometry, context: CGContext) {
        let rect = g.rect
        let cx = g.x0(g.light) + g.light / 2
        let cy = g.y0(g.light) + g.light / 2
        let radius = min(rect.width, rect.height) / 2
        let path = CGMutablePath()
        switch value {
        case 0x256D:  // ╭ down and right
            path.move(to: CGPoint(x: cx, y: rect.maxY))
            path.addArc(tangent1End: CGPoint(x: cx, y: cy), tangent2End: CGPoint(x: rect.maxX, y: cy), radius: radius)
            path.addLine(to: CGPoint(x: rect.maxX, y: cy))
        case 0x256E:  // ╮ down and left
            path.move(to: CGPoint(x: cx, y: rect.maxY))
            path.addArc(tangent1End: CGPoint(x: cx, y: cy), tangent2End: CGPoint(x: rect.minX, y: cy), radius: radius)
            path.addLine(to: CGPoint(x: rect.minX, y: cy))
        case 0x256F:  // ╯ up and left
            path.move(to: CGPoint(x: cx, y: rect.minY))
            path.addArc(tangent1End: CGPoint(x: cx, y: cy), tangent2End: CGPoint(x: rect.minX, y: cy), radius: radius)
            path.addLine(to: CGPoint(x: rect.minX, y: cy))
        default:  // ╰ up and right
            path.move(to: CGPoint(x: cx, y: rect.minY))
            path.addArc(tangent1End: CGPoint(x: cx, y: cy), tangent2End: CGPoint(x: rect.maxX, y: cy), radius: radius)
            path.addLine(to: CGPoint(x: rect.maxX, y: cy))
        }
        context.setLineWidth(g.light)
        context.setLineCap(.butt)
        context.addPath(path)
        context.strokePath()
    }

    private static func drawDiagonals(_ value: UInt32, _ g: Geometry, context: CGContext) {
        let rect = g.rect
        context.setLineWidth(g.light)
        if value != 0x2572 {  // ╱ upper right to lower left
            context.move(to: CGPoint(x: rect.maxX, y: rect.minY))
            context.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        }
        if value != 0x2571 {  // ╲ upper left to lower right
            context.move(to: CGPoint(x: rect.minX, y: rect.minY))
            context.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        }
        context.strokePath()
    }

    // MARK: - Block elements

    private static func drawBlock(_ value: UInt32, _ g: Geometry, color: CGColor, context: CGContext) {
        let rect = g.rect
        let w = rect.width, h = rect.height
        func lower(_ eighths: Int) -> CGRect {
            let height = g.align(h * CGFloat(eighths) / 8)
            return CGRect(x: rect.minX, y: rect.maxY - height, width: w, height: height)
        }
        func leftPart(_ eighths: Int) -> CGRect {
            CGRect(x: rect.minX, y: rect.minY, width: g.align(w * CGFloat(eighths) / 8), height: h)
        }
        let halfW = g.align(w / 2), halfH = g.align(h / 2)
        let upperLeft = CGRect(x: rect.minX, y: rect.minY, width: halfW, height: halfH)
        let upperRight = CGRect(x: rect.minX + halfW, y: rect.minY, width: w - halfW, height: halfH)
        let lowerLeft = CGRect(x: rect.minX, y: rect.minY + halfH, width: halfW, height: h - halfH)
        let lowerRight = CGRect(x: rect.minX + halfW, y: rect.minY + halfH, width: w - halfW, height: h - halfH)

        var rects: [CGRect] = []
        switch value {
        case 0x2580: rects = [CGRect(x: rect.minX, y: rect.minY, width: w, height: halfH)]
        case 0x2581...0x2587: rects = [lower(Int(value - 0x2580))]
        case 0x2588: rects = [rect]
        case 0x2589...0x258F: rects = [leftPart(Int(0x2590 - value))]
        case 0x2590: rects = [CGRect(x: rect.minX + halfW, y: rect.minY, width: w - halfW, height: h)]
        case 0x2591, 0x2592, 0x2593:
            context.setFillColor(color.copy(alpha: CGFloat(value - 0x2590) * 0.25) ?? color)
            rects = [rect]
        case 0x2594: rects = [CGRect(x: rect.minX, y: rect.minY, width: w, height: g.align(h / 8))]
        case 0x2595:
            let width = g.align(w / 8)
            rects = [CGRect(x: rect.maxX - width, y: rect.minY, width: width, height: h)]
        case 0x2596: rects = [lowerLeft]
        case 0x2597: rects = [lowerRight]
        case 0x2598: rects = [upperLeft]
        case 0x2599: rects = [upperLeft, lowerLeft, lowerRight]
        case 0x259A: rects = [upperLeft, lowerRight]
        case 0x259B: rects = [upperLeft, upperRight, lowerLeft]
        case 0x259C: rects = [upperLeft, upperRight, lowerRight]
        case 0x259D: rects = [upperRight]
        case 0x259E: rects = [upperRight, lowerLeft]
        default: rects = [upperRight, lowerLeft, lowerRight]
        }
        context.fill(rects)
    }
}
