import Foundation

/// Operating system commands: titles, working directory, colors, completion requests. See SPEC/screen/reports.md.
extension Terminal {
    func handleOSC(_ payload: [UInt8], terminator: StringTerminator) {
        let separator = payload.firstIndex(of: UInt8(ascii: ";")) ?? payload.endIndex
        guard let command = Int(String(decoding: payload[..<separator], as: UTF8.self)) else { return }
        let argument = separator < payload.endIndex
            ? String(decoding: payload[(separator + 1)...], as: UTF8.self)
            : ""
        let hasArgument = separator < payload.endIndex

        switch command {
        case 0, 2:
            setTitle(argument)
        case 4:
            setOrQueryIndexedColors(argument, terminator: terminator)
        case 7:
            setWorkingDirectory(argument)
        case 10, 11, 12:
            guard hasArgument else { return }
            setOrQueryDynamicColor(command, spec: argument, terminator: terminator)
        case 104:
            resetIndexedColors(argument)
        case 110:
            updatePalette { $0.foreground = defaultPalette.foreground }
        case 111:
            updatePalette { $0.background = defaultPalette.background }
        case 112:
            updatePalette { $0.cursor = defaultPalette.cursor }
        case ShellIntegration.completionRequestCode:
            requestCompletion(argument)
        default:
            break
        }
    }

    private func setTitle(_ newTitle: String) {
        title = newTitle
        delegate?.terminalTitleDidChange(self)
    }

    private func setWorkingDirectory(_ argument: String) {
        guard let url = URL(string: argument), url.scheme == "file" else { return }
        let path = url.path
        guard !path.isEmpty else { return }
        workingDirectory = path
        delegate?.terminalWorkingDirectoryDidChange(self)
    }

    /// `<nonce>;<line>`: the line may hold `;` too.
    private func requestCompletion(_ argument: String) {
        guard let separator = argument.firstIndex(of: ";") else { return }
        delegate?.terminal(self, didRequestCompletionOf: String(argument[argument.index(after: separator)...]),
                           nonce: String(argument[..<separator]))
    }

    // MARK: - Colors

    private func updatePalette(_ change: (inout Palette) -> Void) {
        var updated = palette
        change(&updated)
        guard updated != palette else { return }
        palette = updated
        delegate?.terminalPaletteDidChange(self)
    }

    private func setOrQueryIndexedColors(_ argument: String, terminator: StringTerminator) {
        let parts = argument.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
        var changes: [(Int, RGB)] = []
        var index = 0
        while index + 1 < parts.count {
            defer { index += 2 }
            guard let colorIndex = Int(parts[index]), (0...255).contains(colorIndex) else { continue }
            let spec = parts[index + 1]
            if spec == "?" {
                reply("4;\(colorIndex);\(Self.colorSpec(palette.colors[colorIndex]))", terminator: terminator)
            } else if let color = Self.parseColor(spec) {
                changes.append((colorIndex, color))
            }
        }
        if !changes.isEmpty {
            updatePalette { palette in
                for (colorIndex, color) in changes { palette.colors[colorIndex] = color }
            }
        }
    }

    private func resetIndexedColors(_ argument: String) {
        let indices = argument.split(separator: ";").compactMap { Int($0) }.filter { (0...255).contains($0) }
        updatePalette { palette in
            if indices.isEmpty {
                palette.colors = defaultPalette.colors
            } else {
                for index in indices { palette.colors[index] = defaultPalette.colors[index] }
            }
        }
    }

    private func setOrQueryDynamicColor(_ command: Int, spec: String, terminator: StringTerminator) {
        let spec = spec.split(separator: ";", omittingEmptySubsequences: false).first.map(String.init) ?? ""
        if spec == "?" {
            let color: RGB
            switch command {
            case 10: color = palette.foreground
            case 11: color = palette.background
            default: color = palette.cursor
            }
            reply("\(command);\(Self.colorSpec(color))", terminator: terminator)
            return
        }
        guard let color = Self.parseColor(spec) else { return }
        updatePalette { palette in
            switch command {
            case 10: palette.foreground = color
            case 11: palette.background = color
            default: palette.cursor = color
            }
        }
    }

    private func reply(_ body: String, terminator: StringTerminator) {
        send("\u{1B}]\(body)\(terminator == .bel ? "\u{07}" : "\u{1B}\\")")
    }

    /// `rgb:rrrr/gggg/bbbb`, the format xterm answers color queries with.
    static func colorSpec(_ color: RGB) -> String {
        func channel(_ value: UInt8) -> String {
            let hex = String(value, radix: 16)
            let byte = hex.count == 1 ? "0" + hex : hex
            return byte + byte
        }
        return "rgb:\(channel(color.r))/\(channel(color.g))/\(channel(color.b))"
    }

    /// Parses `rgb:h/h/h` (1–4 hex digits per channel) and `#rgb` forms (1–4 digits per channel).
    static func parseColor(_ spec: String) -> RGB? {
        if spec.hasPrefix("rgb:") {
            let channels = spec.dropFirst(4).split(separator: "/", omittingEmptySubsequences: false)
            guard channels.count == 3 else { return nil }
            let values = channels.compactMap { scaleHex(String($0)) }
            guard values.count == 3 else { return nil }
            return RGB(values[0], values[1], values[2])
        }
        if spec.hasPrefix("#") {
            let digits = Array(spec.dropFirst())
            guard !digits.isEmpty, digits.count % 3 == 0, digits.count <= 12 else { return nil }
            let width = digits.count / 3
            let values = (0..<3).compactMap { i -> UInt8? in
                let hex = String(digits[(i * width)..<((i + 1) * width)])
                guard let value = UInt32(hex, radix: 16) else { return nil }
                // #-forms keep the most significant bits.
                return UInt8(truncatingIfNeeded: width >= 2 ? value >> UInt32((width - 2) * 4) : value << 4)
            }
            guard values.count == 3 else { return nil }
            return RGB(values[0], values[1], values[2])
        }
        return nil
    }

    /// Scales a 1–4 digit hex channel to 8 bits.
    private static func scaleHex(_ hex: String) -> UInt8? {
        guard (1...4).contains(hex.count), let value = UInt32(hex, radix: 16) else { return nil }
        let maximum = UInt32(1 << (4 * hex.count)) - 1
        return UInt8((value * 255 + maximum / 2) / maximum)
    }
}
