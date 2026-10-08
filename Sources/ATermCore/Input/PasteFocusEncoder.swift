/// Encodes pasted text. See SPEC/input/paste-focus.md.
public enum PasteEncoder {
    private static let endMarker = Array("\u{1B}[201~".utf8)

    public static func encode(_ text: String, bracketed: Bool) -> [UInt8] {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(text.utf8.count + 12)
        var previousWasCR = false
        for byte in text.utf8 {
            if byte == 0x0A {
                if !previousWasCR { bytes.append(0x0D) }
            } else {
                bytes.append(byte)
            }
            previousWasCR = byte == 0x0D
        }
        guard bracketed else { return bytes }
        return Array("\u{1B}[200~".utf8) + removingEndMarkers(bytes) + endMarker
    }

    /// Removes every end marker, including markers formed by removing inner ones:
    /// each byte is appended, and a marker completed at the end of the output is dropped.
    private static func removingEndMarkers(_ bytes: [UInt8]) -> [UInt8] {
        var result: [UInt8] = []
        result.reserveCapacity(bytes.count)
        for byte in bytes {
            result.append(byte)
            if byte == endMarker.last!, result.count >= endMarker.count, result.suffix(endMarker.count).elementsEqual(endMarker) {
                result.removeLast(endMarker.count)
            }
        }
        return result
    }
}

/// Encodes focus changes. See SPEC/input/paste-focus.md.
public enum FocusEncoder {
    public static func encode(focused: Bool, modes: TerminalModes) -> [UInt8]? {
        guard modes.focusReporting else { return nil }
        return Array((focused ? "\u{1B}[I" : "\u{1B}[O").utf8)
    }
}
