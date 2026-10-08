import Foundation
import ATermCore

/// Parser handler that records actions, merging consecutive prints into one
/// `print(text)` action so tests can compare whole strings.
final class RecordingHandler: VTParserHandler {
    enum Action: Equatable, CustomStringConvertible {
        case print(String)
        case execute(UInt8)
        case csi(CSISequence)
        case esc(intermediates: String, final: Character)
        case osc(String, StringTerminator)
        case dcs(DCSSequence)

        var description: String {
            switch self {
            case .print(let text): "print(\(text.debugDescription))"
            case .execute(let byte): "execute(\(String(byte, radix: 16)))"
            case .csi(let csi): "csi(\(csi))"
            case .esc(let intermediates, let final): "esc(\(intermediates.debugDescription), \(final))"
            case .osc(let text, let terminator): "osc(\(text.debugDescription), \(terminator))"
            case .dcs(let dcs): "dcs(\(dcs))"
            }
        }
    }

    private(set) var actions: [Action] = []

    func print(_ scalar: Unicode.Scalar) {
        appendText(String(scalar))
    }

    func printASCII(_ bytes: UnsafeBufferPointer<UInt8>) {
        appendText(String(decoding: bytes, as: UTF8.self))
    }

    func execute(_ byte: UInt8) {
        actions.append(.execute(byte))
    }

    func csiDispatch(_ sequence: CSISequence) {
        actions.append(.csi(sequence))
    }

    func escDispatch(intermediates: [UInt8], final: UInt8) {
        actions.append(.esc(intermediates: String(decoding: intermediates, as: UTF8.self),
                            final: Character(Unicode.Scalar(final))))
    }

    func oscDispatch(_ payload: [UInt8], terminator: StringTerminator) {
        actions.append(.osc(String(decoding: payload, as: UTF8.self), terminator))
    }

    func dcsDispatch(_ sequence: DCSSequence) {
        actions.append(.dcs(sequence))
    }

    private func appendText(_ text: String) {
        if case .print(let previous)? = actions.last {
            actions[actions.count - 1] = .print(previous + text)
        } else {
            actions.append(.print(text))
        }
    }
}

extension CSISequence {
    /// Test shorthand: `CSISequence([[1], [2]], "H", private: "?", intermediates: " ")`.
    init(_ params: [[Int]], _ final: Unicode.Scalar, private marker: Unicode.Scalar? = nil, intermediates: String = "") {
        self.init(params: params,
                  privateMarker: marker.map { UInt8($0.value) },
                  intermediates: Array(intermediates.utf8),
                  final: UInt8(final.value))
    }
}

extension DCSSequence {
    init(_ params: [[Int]], _ final: Unicode.Scalar, intermediates: String = "", data: String) {
        self.init(params: params,
                  privateMarker: nil,
                  intermediates: Array(intermediates.utf8),
                  final: UInt8(final.value),
                  data: Array(data.utf8))
    }
}

/// Bytes of a string where `⎋` stands for ESC, to keep test inputs readable.
func bytes(_ text: String) -> [UInt8] {
    Array(text.replacingOccurrences(of: "⎋", with: "\u{1B}").utf8)
}
