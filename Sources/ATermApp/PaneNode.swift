import AppKit

/// How a split places its two children: side by side (`horizontal`, Split Right) or stacked (`vertical`, Split
/// Down).
enum PaneAxis {
    case horizontal, vertical
}

/// Window ▸ Select Pane Left, Right, Above and Below.
enum PaneDirection {
    case left, right, up, down
}

/// The panes of a tab: a binary tree of splits, laid out in whole points with a 1-point divider between the two
/// children of each split. See SPEC/app/splits.md.
indirect enum PaneNode {
    case pane(TerminalPane)
    /// `ratio` is the first child's share of the split's length minus the divider.
    case split(PaneAxis, ratio: CGFloat, PaneNode, PaneNode)

    static let dividerThickness: CGFloat = 1

    /// The divider of the split at `path` from the root (false: first child, true: second), and that split's frame.
    struct Divider: Equatable {
        let path: [Bool]
        let axis: PaneAxis
        let frame: NSRect
        let splitFrame: NSRect
    }

    struct Layout {
        var frames: [(pane: TerminalPane, frame: NSRect)] = []
        var dividers: [Divider] = []
    }

    /// In tree order: first child before second.
    var panes: [TerminalPane] {
        switch self {
        case .pane(let pane): [pane]
        case .split(_, _, let first, let second): first.panes + second.panes
        }
    }

    /// The tree with `target` replaced by a split of proportion 1/2 along `axis`, `target` first and `pane` second.
    func splitting(_ target: TerminalPane, _ axis: PaneAxis, with pane: TerminalPane) -> PaneNode {
        switch self {
        case .pane(let leaf):
            leaf === target ? .split(axis, ratio: 0.5, self, .pane(pane)) : self
        case .split(let splitAxis, let ratio, let first, let second):
            .split(splitAxis, ratio: ratio, first.splitting(target, axis, with: pane),
                   second.splitting(target, axis, with: pane))
        }
    }

    /// The node at `path` from this one (false: first child, true: second).
    func node(at path: ArraySlice<Bool>) -> PaneNode? {
        guard let step = path.first else { return self }
        guard case .split(_, _, let first, let second) = self else { return nil }
        return (step ? second : first).node(at: path.dropFirst())
    }

    /// The tree with the split at `path` given `ratio`.
    func settingRatio(_ ratio: CGFloat, at path: ArraySlice<Bool>) -> PaneNode {
        guard case .split(let axis, let current, let first, let second) = self else { return self }
        guard let step = path.first else { return .split(axis, ratio: ratio, first, second) }
        return step
            ? .split(axis, ratio: current, first, second.settingRatio(ratio, at: path.dropFirst()))
            : .split(axis, ratio: current, first.settingRatio(ratio, at: path.dropFirst()), second)
    }

    /// The tree with every split given the proportion of its children's weights: the panes share the space equally.
    func equalized() -> PaneNode {
        guard case .split(let axis, _, let first, let second) = self else { return self }
        let weights = (first.weight(axis), second.weight(axis))
        return .split(axis, ratio: weights.0 / (weights.0 + weights.1), first.equalized(), second.equalized())
    }

    /// A pane weighs 1; a split along `axis` the sum of its children's weights, a split across it the larger one.
    func weight(_ axis: PaneAxis) -> CGFloat {
        switch self {
        case .pane:
            1
        case .split(let splitAxis, _, let first, let second):
            splitAxis == axis ? first.weight(axis) + second.weight(axis) : max(first.weight(axis), second.weight(axis))
        }
    }

    /// The tree without `target`, its sibling taking its split's place; nil when the tree is `target` alone.
    func removing(_ target: TerminalPane) -> PaneNode? {
        switch self {
        case .pane(let leaf):
            return leaf === target ? nil : self
        case .split(let axis, let ratio, let first, let second):
            guard let remainingFirst = first.removing(target) else { return second }
            guard let remainingSecond = second.removing(target) else { return first }
            return .split(axis, ratio: ratio, remainingFirst, remainingSecond)
        }
    }

    /// Where the sibling of `target` lies: after it for a first child, before it for a second.
    func directionToSibling(of target: TerminalPane) -> PaneDirection? {
        switch self {
        case .pane:
            return nil
        case .split(let axis, _, let first, let second):
            if case .pane(let leaf) = first, leaf === target { return axis == .horizontal ? .right : .down }
            if case .pane(let leaf) = second, leaf === target { return axis == .horizontal ? .left : .up }
            return first.directionToSibling(of: target) ?? second.directionToSibling(of: target)
        }
    }

    /// The pane of `frames` next to `pane` toward `direction`: among the panes entirely on that side that overlap
    /// it across, the nearest, then the one overlapping it most, then the top-most (left, right) or the left-most
    /// (up, down).
    static func neighbor(of pane: TerminalPane, toward direction: PaneDirection,
                         in frames: [(pane: TerminalPane, frame: NSRect)]) -> TerminalPane? {
        guard let origin = frames.first(where: { $0.pane === pane })?.frame else { return nil }
        var best: (pane: TerminalPane, rank: (gap: CGFloat, overlap: CGFloat, position: CGFloat))?
        for (candidate, frame) in frames where candidate !== pane {
            let gap: CGFloat
            switch direction {
            case .left: gap = origin.minX - frame.maxX
            case .right: gap = frame.minX - origin.maxX
            case .up: gap = origin.minY - frame.maxY
            case .down: gap = frame.minY - origin.maxY
            }
            let overlap: CGFloat
            let position: CGFloat
            switch direction {
            case .left, .right:
                overlap = min(origin.maxY, frame.maxY) - max(origin.minY, frame.minY)
                position = frame.minY
            case .up, .down:
                overlap = min(origin.maxX, frame.maxX) - max(origin.minX, frame.minX)
                position = frame.minX
            }
            guard gap >= 0, overlap > 0 else { continue }
            let rank = (gap: gap, overlap: -overlap, position: position)
            if let best, best.rank <= rank { continue }
            best = (candidate, rank)
        }
        return best?.pane
    }

    /// The frame of every pane and divider in `rect`; `minimum` is a pane's smallest size.
    func layout(in rect: NSRect, minimum: NSSize) -> Layout {
        var layout = Layout()
        place(in: rect, minimum: minimum, path: [], into: &layout)
        return layout
    }

    private func place(in rect: NSRect, minimum: NSSize, path: [Bool], into layout: inout Layout) {
        switch self {
        case .pane(let pane):
            layout.frames.append((pane, rect))
        case .split(let axis, let ratio, let first, let second):
            let parts = Self.divide(rect, axis, ratio: ratio,
                                    minimums: (first.minimumLength(axis, minimum), second.minimumLength(axis, minimum)))
            first.place(in: parts.first, minimum: minimum, path: path + [false], into: &layout)
            layout.dividers.append(Divider(path: path, axis: axis, frame: parts.divider, splitFrame: rect))
            second.place(in: parts.second, minimum: minimum, path: path + [true], into: &layout)
        }
    }

    /// Splits `rect` along `axis`: the first child gets `round(ratio × (L − 1))` points, kept between the
    /// children's minimums when `L` is long enough for both, then the divider, then the second child the rest.
    static func divide(_ rect: NSRect, _ axis: PaneAxis, ratio: CGFloat,
                       minimums: (first: CGFloat, second: CGFloat) = (0, 0))
        -> (first: NSRect, divider: NSRect, second: NSRect) {
        let length = axis == .horizontal ? rect.width : rect.height
        let available = max(0, length - dividerThickness)
        var first = (available * ratio).rounded()
        if available >= minimums.first + minimums.second {
            first = min(max(first, minimums.first), available - minimums.second)
        }
        first = min(max(first, 0), available)
        switch axis {
        case .horizontal:
            return (NSRect(x: rect.minX, y: rect.minY, width: first, height: rect.height),
                    NSRect(x: rect.minX + first, y: rect.minY, width: dividerThickness, height: rect.height),
                    NSRect(x: rect.minX + first + dividerThickness, y: rect.minY,
                           width: available - first, height: rect.height))
        case .vertical:
            return (NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: first),
                    NSRect(x: rect.minX, y: rect.minY + first, width: rect.width, height: dividerThickness),
                    NSRect(x: rect.minX, y: rect.minY + first + dividerThickness,
                           width: rect.width, height: available - first))
        }
    }

    /// The smallest length of the subtree along `axis`, `minimum` being a pane's smallest size.
    func minimumLength(_ axis: PaneAxis, _ minimum: NSSize) -> CGFloat {
        switch self {
        case .pane:
            axis == .horizontal ? minimum.width : minimum.height
        case .split(let splitAxis, _, let first, let second):
            splitAxis == axis
                ? first.minimumLength(axis, minimum) + Self.dividerThickness + second.minimumLength(axis, minimum)
                : max(first.minimumLength(axis, minimum), second.minimumLength(axis, minimum))
        }
    }
}
