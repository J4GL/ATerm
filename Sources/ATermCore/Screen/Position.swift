/// A 0-based grid position.
public struct Position: Hashable, Comparable, Sendable, CustomStringConvertible {
    public var row: Int
    public var col: Int

    public init(row: Int, col: Int) {
        self.row = row
        self.col = col
    }

    public static func < (lhs: Position, rhs: Position) -> Bool {
        lhs.row != rhs.row ? lhs.row < rhs.row : lhs.col < rhs.col
    }

    public var description: String { "(\(row), \(col))" }
}
