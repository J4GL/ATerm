/// Receives the actions produced by `VTParser`. See SPEC/parser/contract.md.
public protocol VTParserHandler: AnyObject {
    func print(_ scalar: Unicode.Scalar)
    /// A run of printable ASCII bytes (0x20–0x7E); equivalent to one `print` per byte.
    func printASCII(_ bytes: UnsafeBufferPointer<UInt8>)
    func execute(_ byte: UInt8)
    func csiDispatch(_ sequence: CSISequence)
    func escDispatch(intermediates: [UInt8], final: UInt8)
    func oscDispatch(_ payload: [UInt8], terminator: StringTerminator)
    func dcsDispatch(_ sequence: DCSSequence)
}

public enum StringTerminator: Sendable, Equatable {
    case bel
    case st
}

public struct CSISequence: Equatable, Sendable, CustomStringConvertible {
    /// Every parameter value in order. See SPEC/parser/contract.md.
    public var values: [Int]
    /// Index in `values` where each `;`-separated parameter starts.
    public var groupStarts: [Int]
    public var privateMarker: UInt8?
    public var intermediates: [UInt8]
    public var final: UInt8

    public init(params: [[Int]], privateMarker: UInt8?, intermediates: [UInt8], final: UInt8) {
        var values: [Int] = []
        var starts: [Int] = []
        for group in params {
            starts.append(values.count)
            values.append(contentsOf: group.isEmpty ? [0] : group)
        }
        self.init(values: values, groupStarts: starts, privateMarker: privateMarker, intermediates: intermediates,
                  final: final)
    }

    init(values: [Int], groupStarts: [Int], privateMarker: UInt8?, intermediates: [UInt8], final: UInt8) {
        self.values = values
        self.groupStarts = groupStarts
        self.privateMarker = privateMarker
        self.intermediates = intermediates
        self.final = final
    }

    /// Each parameter with its sub-parameters.
    public var params: [[Int]] {
        (0..<count).map { Array(group($0)) }
    }

    /// Number of parameters.
    public var count: Int { groupStarts.count }

    /// Parameter `index` with its sub-parameters.
    public func group(_ index: Int) -> ArraySlice<Int> {
        let start = groupStarts[index]
        let end = index + 1 < groupStarts.count ? groupStarts[index + 1] : values.count
        return values[start..<end]
    }

    /// First value of parameter `index`, or `defaultValue` when it is missing or 0.
    public func param(_ index: Int, default defaultValue: Int) -> Int {
        guard index < groupStarts.count else { return defaultValue }
        let value = values[groupStarts[index]]
        return value == 0 ? defaultValue : value
    }

    /// First value of parameter `index`, or `defaultValue` only when it is missing.
    public func rawParam(_ index: Int, default defaultValue: Int) -> Int {
        guard index < groupStarts.count else { return defaultValue }
        return values[groupStarts[index]]
    }

    public var description: String {
        let marker = privateMarker.map { String(UnicodeScalar($0)) } ?? ""
        let inter = String(decoding: intermediates, as: UTF8.self)
        return "CSI \(marker)\(params)\(inter)\(String(UnicodeScalar(final)))"
    }
}

public struct DCSSequence: Equatable, Sendable, CustomStringConvertible {
    public var params: [[Int]]
    public var privateMarker: UInt8?
    public var intermediates: [UInt8]
    public var final: UInt8
    public var data: [UInt8]

    public init(params: [[Int]], privateMarker: UInt8?, intermediates: [UInt8], final: UInt8, data: [UInt8]) {
        self.params = params
        self.privateMarker = privateMarker
        self.intermediates = intermediates
        self.final = final
        self.data = data
    }

    public var description: String {
        let inter = String(decoding: intermediates, as: UTF8.self)
        return "DCS \(params)\(inter)\(String(UnicodeScalar(final))) \(String(decoding: data, as: UTF8.self).debugDescription)"
    }
}

/// Byte-level VT500-style state machine with UTF-8 decoding. See SPEC/parser.
public struct VTParser {
    static let maxParams = 32
    static let maxSubParams = 16
    static let maxParamValue = 65_535
    static let maxStringLength = 65_536

    private enum State {
        case ground
        case escape
        case escapeIntermediate
        case csiEntry
        case csiParam
        case csiIntermediate
        case csiIgnore
        case oscString
        case dcsEntry
        case dcsParam
        case dcsIntermediate
        case dcsPassthrough
        case dcsIgnore
        case ignoredString  // SOS, PM, APC
    }

    private var state: State = .ground

    // UTF-8 decoder (ground state only).
    private var utf8Scalar: UInt32 = 0
    private var utf8Remaining = 0
    private var utf8Lower: UInt8 = 0x80
    private var utf8Upper: UInt8 = 0xBF

    // Sequence being collected; buffers are reused from one sequence to the next.
    private var intermediates: [UInt8] = []
    private var privateMarker: UInt8?
    private var values: [Int] = []
    private var groupStarts: [Int] = []
    private var valuesInGroup = 0
    private var droppingGroup = false
    private var currentValue = 0
    private var hasParams = false
    private var stringData: [UInt8] = []
    private var stringOverflow = false
    private var dcsFinal: UInt8 = 0

    public init() {}

    public mutating func feed<Handler: VTParserHandler>(_ bytes: [UInt8], handler: Handler) {
        bytes.withUnsafeBufferPointer { feed($0, handler: handler) }
    }

    public mutating func feed<Handler: VTParserHandler>(_ bytes: UnsafeBufferPointer<UInt8>, handler: Handler) {
        let count = bytes.count
        var index = 0
        while index < count {
            let byte = bytes[index]
            // Fast path: runs of printable ASCII in ground state.
            if state == .ground, utf8Remaining == 0, byte >= 0x20, byte < 0x7F {
                var end = index + 1
                while end < count {
                    let next = bytes[end]
                    if next < 0x20 || next >= 0x7F { break }
                    end += 1
                }
                handler.printASCII(UnsafeBufferPointer(rebasing: bytes[index..<end]))
                index = end
                continue
            }
            advance(byte, handler: handler)
            index += 1
        }
    }

    // MARK: - State machine

    private mutating func advance<Handler: VTParserHandler>(_ byte: UInt8, handler: Handler) {
        if utf8Remaining > 0 {
            if byte >= utf8Lower && byte <= utf8Upper {
                utf8Scalar = (utf8Scalar << 6) | UInt32(byte & 0x3F)
                utf8Remaining -= 1
                utf8Lower = 0x80
                utf8Upper = 0xBF
                if utf8Remaining == 0 {
                    handler.print(Unicode.Scalar(utf8Scalar) ?? "\u{FFFD}")
                }
                return
            }
            // Malformed: replace the incomplete sequence, then reprocess this byte.
            utf8Remaining = 0
            utf8Lower = 0x80
            utf8Upper = 0xBF
            handler.print("\u{FFFD}")
        }

        // Transitions valid from any state.
        switch byte {
        case 0x18, 0x1A:  // CAN, SUB
            let inString = isInString
            state = .ground
            if !inString { handler.execute(byte) }
            return
        case 0x1B:  // ESC
            if state == .oscString {
                dispatchOSC(terminator: .st, handler: handler)
            } else if state == .dcsPassthrough {
                dispatchDCS(handler: handler)
            }
            enterEscape()
            return
        default:
            break
        }

        switch state {
        case .ground:
            ground(byte, handler: handler)
        case .escape:
            escape(byte, handler: handler)
        case .escapeIntermediate:
            escapeIntermediate(byte, handler: handler)
        case .csiEntry, .csiParam, .csiIntermediate, .csiIgnore:
            csi(byte, handler: handler)
        case .oscString:
            osc(byte, handler: handler)
        case .dcsEntry, .dcsParam, .dcsIntermediate, .dcsIgnore:
            dcsHeader(byte, handler: handler)
        case .dcsPassthrough:
            collectString(byte)
        case .ignoredString:
            break
        }
    }

    private var isInString: Bool {
        switch state {
        case .oscString, .dcsPassthrough, .dcsIgnore, .ignoredString, .dcsEntry, .dcsParam, .dcsIntermediate:
            return true
        default:
            return false
        }
    }

    private mutating func ground<Handler: VTParserHandler>(_ byte: UInt8, handler: Handler) {
        switch byte {
        case 0x00..<0x20:
            handler.execute(byte)
        case 0x20..<0x7F:
            handler.print(Unicode.Scalar(byte))
        case 0x7F:
            break
        case 0xC2...0xDF:
            beginUTF8(scalar: UInt32(byte & 0x1F), remaining: 1)
        case 0xE0:
            beginUTF8(scalar: UInt32(byte & 0x0F), remaining: 2, lower: 0xA0)
        case 0xED:
            beginUTF8(scalar: UInt32(byte & 0x0F), remaining: 2, upper: 0x9F)
        case 0xE1...0xEF:
            beginUTF8(scalar: UInt32(byte & 0x0F), remaining: 2)
        case 0xF0:
            beginUTF8(scalar: UInt32(byte & 0x07), remaining: 3, lower: 0x90)
        case 0xF4:
            beginUTF8(scalar: UInt32(byte & 0x07), remaining: 3, upper: 0x8F)
        case 0xF1...0xF3:
            beginUTF8(scalar: UInt32(byte & 0x07), remaining: 3)
        default:  // 0x80–0xC1, 0xF5–0xFF
            handler.print("\u{FFFD}")
        }
    }

    private mutating func beginUTF8(scalar: UInt32, remaining: Int, lower: UInt8 = 0x80, upper: UInt8 = 0xBF) {
        utf8Scalar = scalar
        utf8Remaining = remaining
        utf8Lower = lower
        utf8Upper = upper
    }

    private mutating func enterEscape() {
        state = .escape
        intermediates.removeAll(keepingCapacity: true)
    }

    private mutating func escape<Handler: VTParserHandler>(_ byte: UInt8, handler: Handler) {
        switch byte {
        case 0x00..<0x20:
            handler.execute(byte)
        case 0x20...0x2F:
            intermediates.append(byte)
            state = .escapeIntermediate
        case UInt8(ascii: "["):
            enterCSI()
            state = .csiEntry
        case UInt8(ascii: "]"):
            stringData.removeAll(keepingCapacity: true)
            stringOverflow = false
            state = .oscString
        case UInt8(ascii: "P"):
            enterCSI()
            stringData.removeAll(keepingCapacity: true)
            stringOverflow = false
            state = .dcsEntry
        case UInt8(ascii: "X"), UInt8(ascii: "^"), UInt8(ascii: "_"):
            state = .ignoredString
        case UInt8(ascii: "\\"):
            state = .ground  // ST outside a string: nothing to terminate.
        case 0x30...0x7E:
            handler.escDispatch(intermediates: intermediates, final: byte)
            state = .ground
        default:
            break  // DEL and 8-bit bytes are ignored.
        }
    }

    private mutating func escapeIntermediate<Handler: VTParserHandler>(_ byte: UInt8, handler: Handler) {
        switch byte {
        case 0x00..<0x20:
            handler.execute(byte)
        case 0x20...0x2F:
            intermediates.append(byte)
        case 0x30...0x7E:
            handler.escDispatch(intermediates: intermediates, final: byte)
            state = .ground
        default:
            break
        }
    }

    // MARK: CSI

    private mutating func enterCSI() {
        intermediates.removeAll(keepingCapacity: true)
        privateMarker = nil
        values.removeAll(keepingCapacity: true)
        groupStarts.removeAll(keepingCapacity: true)
        valuesInGroup = 0
        droppingGroup = false
        currentValue = 0
        hasParams = false
    }

    private mutating func csi<Handler: VTParserHandler>(_ byte: UInt8, handler: Handler) {
        switch byte {
        case 0x00..<0x20:
            handler.execute(byte)
        case 0x30...0x3B:  // digits, ':' and ';'
            switch state {
            case .csiEntry, .csiParam:
                collectParam(byte)
                state = .csiParam
            case .csiIntermediate:
                state = .csiIgnore
            default:
                break
            }
        case 0x3C...0x3F:  // private markers
            if state == .csiEntry {
                privateMarker = byte
                state = .csiParam
            } else {
                state = .csiIgnore
            }
        case 0x20...0x2F:
            if state == .csiIgnore { break }
            intermediates.append(byte)
            state = .csiIntermediate
        case 0x40...0x7E:
            if state != .csiIgnore {
                finishParams()
                handler.csiDispatch(CSISequence(values: values, groupStarts: groupStarts, privateMarker: privateMarker,
                                                intermediates: intermediates, final: byte))
            }
            state = .ground
        default:
            break  // DEL and 8-bit bytes are ignored.
        }
    }

    private mutating func collectParam(_ byte: UInt8) {
        hasParams = true
        switch byte {
        case UInt8(ascii: ";"):
            closeValue()
            closeGroup()
        case UInt8(ascii: ":"):
            closeValue()
        default:
            currentValue = min(currentValue * 10 + Int(byte - 0x30), Self.maxParamValue)
        }
    }

    private mutating func closeValue() {
        if valuesInGroup == 0 {
            if groupStarts.count < Self.maxParams {
                groupStarts.append(values.count)
            } else {
                droppingGroup = true
            }
        }
        if !droppingGroup && valuesInGroup < Self.maxSubParams {
            values.append(currentValue)
        }
        valuesInGroup += 1
        currentValue = 0
    }

    private mutating func closeGroup() {
        valuesInGroup = 0
        droppingGroup = false
    }

    private mutating func finishParams() {
        guard hasParams else { return }
        closeValue()
        closeGroup()
        hasParams = false
    }

    /// The collected parameters as nested arrays (for DCS).
    private var collectedParams: [[Int]] {
        CSISequence(values: values, groupStarts: groupStarts, privateMarker: nil, intermediates: [], final: 0).params
    }

    // MARK: Strings

    private mutating func collectString(_ byte: UInt8) {
        guard !stringOverflow else { return }
        if stringData.count >= Self.maxStringLength {
            stringOverflow = true
            stringData.removeAll()
            return
        }
        stringData.append(byte)
    }

    private mutating func osc<Handler: VTParserHandler>(_ byte: UInt8, handler: Handler) {
        switch byte {
        case 0x07:
            dispatchOSC(terminator: .bel, handler: handler)
            state = .ground
        case 0x00..<0x20:
            break
        default:
            collectString(byte)
        }
    }

    private mutating func dispatchOSC<Handler: VTParserHandler>(terminator: StringTerminator, handler: Handler) {
        if !stringOverflow {
            handler.oscDispatch(stringData, terminator: terminator)
        }
        stringData.removeAll(keepingCapacity: true)
        stringOverflow = false
    }

    private mutating func dcsHeader<Handler: VTParserHandler>(_ byte: UInt8, handler: Handler) {
        switch byte {
        case 0x00..<0x20:
            break  // C0 inside a DCS header is ignored.
        case 0x30...0x3B:
            switch state {
            case .dcsEntry, .dcsParam:
                collectParam(byte)
                state = .dcsParam
            case .dcsIntermediate:
                state = .dcsIgnore
            default:
                break
            }
        case 0x3C...0x3F:
            if state == .dcsEntry {
                privateMarker = byte
                state = .dcsParam
            } else if state != .dcsIgnore {
                state = .dcsIgnore
            }
        case 0x20...0x2F:
            if state == .dcsIgnore { break }
            intermediates.append(byte)
            state = .dcsIntermediate
        case 0x40...0x7E:
            if state == .dcsIgnore { break }
            finishParams()
            dcsFinal = byte
            state = .dcsPassthrough
        default:
            break
        }
    }

    private mutating func dispatchDCS<Handler: VTParserHandler>(handler: Handler) {
        if !stringOverflow {
            handler.dcsDispatch(DCSSequence(params: collectedParams, privateMarker: privateMarker,
                                            intermediates: intermediates, final: dcsFinal, data: stringData))
        }
        stringData.removeAll(keepingCapacity: true)
        stringOverflow = false
    }
}
