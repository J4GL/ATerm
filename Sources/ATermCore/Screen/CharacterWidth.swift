/// Display width of a Unicode scalar in cells. See SPEC/screen/contract.md.
public enum CharacterWidth {
    public static func width(of scalar: Unicode.Scalar) -> Int {
        let value = scalar.value
        if value < 0x300 { return 1 }
        if value < 0x10000 { return Int(basicMultilingualPlane[Int(value)]) }
        return computedWidth(of: scalar)
    }

    /// Widths of every BMP scalar, computed once.
    private static let basicMultilingualPlane: [UInt8] = (0..<0x10000).map { value in
        guard let scalar = Unicode.Scalar(UInt32(value)) else { return 1 }
        return UInt8(value < 0x300 ? 1 : computedWidth(of: scalar))
    }

    private static func computedWidth(of scalar: Unicode.Scalar) -> Int {
        let value = scalar.value
        if value >= 0x1160 && value <= 0x11FF { return 0 }
        let properties = scalar.properties
        switch properties.generalCategory {
        case .nonspacingMark, .enclosingMark, .format:
            return 0
        default:
            break
        }
        if properties.isEmojiPresentation || isEastAsianWide(value) { return 2 }
        return 1
    }

    /// True for emoji that may follow a ZWJ inside an emoji sequence.
    static func isEmoji(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value > 0xFF && scalar.properties.isEmoji
    }

    static func isRegionalIndicator(_ scalar: Unicode.Scalar) -> Bool {
        (0x1F1E6...0x1F1FF).contains(scalar.value)
    }

    // East Asian Wide (W) and Fullwidth (F) ranges not covered by Emoji_Presentation.
    private static let wideRanges: [ClosedRange<UInt32>] = [
        0x1100...0x115F, 0x2329...0x232A, 0x2E80...0x303E, 0x3041...0x33FF,
        0x3400...0x4DBF, 0x4E00...0x9FFF, 0xA000...0xA4CF, 0xA960...0xA97F,
        0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE10...0xFE19, 0xFE30...0xFE6F,
        0xFF00...0xFF60, 0xFFE0...0xFFE6, 0x16FE0...0x16FE4, 0x17000...0x18CFF,
        0x1AFF0...0x1B2FF, 0x1F200...0x1F2FF, 0x20000...0x2FFFD, 0x30000...0x3FFFD,
    ]

    private static func isEastAsianWide(_ value: UInt32) -> Bool {
        guard value >= 0x1100 else { return false }
        var low = 0
        var high = wideRanges.count - 1
        while low <= high {
            let mid = (low + high) / 2
            let range = wideRanges[mid]
            if value < range.lowerBound {
                high = mid - 1
            } else if value > range.upperBound {
                low = mid + 1
            } else {
                return true
            }
        }
        return false
    }
}
