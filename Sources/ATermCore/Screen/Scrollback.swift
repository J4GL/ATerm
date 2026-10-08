/// Lines scrolled off the top of the main screen, oldest first, bounded by `limit`.
struct Scrollback {
    let limit: Int
    private var storage: [Line] = []
    private var start = 0

    init(limit: Int) {
        self.limit = max(0, limit)
    }

    var count: Int { storage.count }

    subscript(index: Int) -> Line {
        storage[(start + index) % storage.count]
    }

    /// Appends a line. When the oldest line has to go, returns it so its storage can be reused.
    @discardableResult
    mutating func append(_ line: Line) -> (dropped: Bool, line: Line?) {
        guard limit > 0 else { return (true, nil) }
        if storage.count < limit {
            storage.append(line)
            return (false, nil)
        }
        let evicted = storage[start]
        storage[start] = line
        start = (start + 1) % limit
        return (true, evicted)
    }

    mutating func removeAll() {
        storage.removeAll()
        start = 0
    }

    var allLines: [Line] {
        (0..<storage.count).map { self[$0] }
    }

    /// Removes and returns the `count` newest lines, oldest first.
    mutating func removeLast(_ count: Int) -> [Line] {
        var lines = allLines
        let removed = Array(lines.suffix(count))
        lines.removeLast(min(count, lines.count))
        storage = lines
        start = 0
        return removed
    }

    /// Replaces the content; returns how many leading lines did not fit.
    mutating func replace(with lines: [Line]) -> Int {
        let dropped = max(0, lines.count - limit)
        storage = Array(lines.suffix(limit))
        start = 0
        return dropped
    }
}
