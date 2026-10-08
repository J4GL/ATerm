import AppKit
import ATermCore

/// The assistant bar over the center of a terminal: the ⌘ hint, the request field, the key field, a status line
/// and the suggested commands. `AssistantController` drives it. See SPEC/app/assistant.md.
///
/// It is laid out with frames only: constraints in the terminal view would take part in the window's sizing.
@MainActor
final class AssistantBar: NSView, NSTextFieldDelegate {
    enum Mode: Equatable {
        case hidden, hint, prompt, thinking, suggestions, key
    }

    static let width: CGFloat = 640

    private(set) var mode = Mode.hidden
    /// The request field replies to an agent.
    private(set) var isReply = false
    let hintLabel = NSTextField(labelWithString: "Release ⌘ to ask")
    let field = NSTextField()
    let keyField = NSSecureTextField()
    let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let rows = FlippedView()
    private(set) var suggestions: [CommandSuggestion] = []
    private(set) var selectedIndex = 0
    /// The request that produced the suggestions: Return runs a suggestion only while the field still holds it.
    private var suggestionsRequest = ""

    var statusText: String { statusLabel.stringValue }

    var onSubmit: ((String) -> Void)?
    /// A suggestion was chosen: run it (Return, click) or only insert it (⌥Return, ⌥click).
    var onChoose: ((Int, Bool) -> Void)?
    var onSaveKey: ((String) -> Void)?
    var onCancel: (() -> Void)?

    init() {
        super.init(frame: .zero)
        appearance = NSAppearance(named: .darkAqua)

        hintLabel.font = .systemFont(ofSize: 13, weight: .medium)
        hintLabel.textColor = .secondaryLabelColor
        for input in [field, keyField] {
            input.font = .systemFont(ofSize: 15)
            input.isBordered = false
            input.drawsBackground = false
            input.focusRingType = .none
            input.delegate = self
            input.cell?.isScrollable = true
            input.cell?.wraps = false
        }
        keyField.placeholderString = "Paste your OpenRouter API key (saved in your Keychain)"
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor
        for view in parts {
            addSubview(view)
        }
        isHidden = true
    }

    required init?(coder: NSCoder) {
        fatalError("AssistantBar is created in code")
    }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    /// Top to bottom; the status line comes last.
    private var parts: [NSView] { [hintLabel, field, keyField, rows, statusLabel] }

    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10)
        NSColor(srgbRed: 0.13, green: 0.14, blue: 0.17, alpha: 0.98).setFill()
        shape.fill()
        NSColor(white: 1, alpha: 0.18).setStroke()
        shape.lineWidth = 1
        shape.stroke()
    }

    // MARK: - Layout

    /// Adds the bar to `view`, at its center.
    func install(in view: NSView) {
        view.addSubview(self)
        layoutInSuperview()
    }

    /// Places the bar and its visible parts; called when the mode or the terminal's size changes.
    func layoutInSuperview() {
        guard let superview else { return }
        let width = min(Self.width, max(160, superview.bounds.width - 24))
        let inner = width - 24
        var y: CGFloat = 10
        for view in parts where !view.isHidden {
            let height = height(of: view, width: inner)
            view.frame = NSRect(x: 12, y: y, width: inner, height: height)
            y += height + 6
        }
        let height = y + 4
        frame = NSRect(x: ((superview.bounds.width - width) / 2).rounded(),
                       y: max(8, ((superview.bounds.height - height) / 2).rounded()), width: width, height: height)
    }

    private func height(of view: NSView, width: CGFloat) -> CGFloat {
        if view === rows {
            var y: CGFloat = 0
            for row in rows.subviews {
                row.frame = NSRect(x: 0, y: y, width: width, height: SuggestionRow.height)
                y += SuggestionRow.height + 2
            }
            return max(0, y - 2)
        }
        if view === statusLabel {
            let size = statusLabel.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: 10_000))
            return ceil(size?.height ?? 16)
        }
        return ceil((view as? NSControl)?.cell?.cellSize.height ?? 20)
    }

    // MARK: - Modes

    func showHint() {
        show(.hint, visible: [hintLabel])
    }

    func showPrompt(reply: Bool, text: String = "", status: String? = nil) {
        isReply = reply
        field.placeholderString = reply ? "Reply to the agent…" : "Ask for a command or a task…"
        field.stringValue = text
        statusLabel.stringValue = status ?? ""
        show(.prompt, visible: status == nil ? [field] : [field, statusLabel])
    }

    func showThinking() {
        statusLabel.stringValue = "Thinking…"
        show(.thinking, visible: [field, statusLabel])
    }

    func showSuggestions(_ suggestions: [CommandSuggestion], request: String) {
        self.suggestions = suggestions
        suggestionsRequest = request
        statusLabel.stringValue = "Return runs it in this tab · ⌥Return inserts it · Esc closes"
        rows.subviews.forEach { $0.removeFromSuperview() }
        for (index, suggestion) in suggestions.enumerated() {
            let row = SuggestionRow(suggestion: suggestion)
            row.onClick = { [weak self] run in self?.onChoose?(index, run) }
            rows.addSubview(row)
        }
        select(0)
        show(.suggestions, visible: [field, rows, statusLabel])
    }

    func showKey(message: String?) {
        keyField.stringValue = ""
        statusLabel.stringValue = message ?? ""
        show(.key, visible: message == nil ? [keyField] : [keyField, statusLabel])
    }

    func setStatus(_ status: String) {
        statusLabel.stringValue = status
        statusLabel.isHidden = status.isEmpty
        layoutInSuperview()
    }

    func hide() {
        mode = .hidden
        isHidden = true
    }

    private func show(_ mode: Mode, visible: [NSView]) {
        self.mode = mode
        for view in parts {
            view.isHidden = !visible.contains(view)
        }
        isHidden = false
        layoutInSuperview()
    }

    private func select(_ index: Int) {
        guard !suggestions.isEmpty else { return }
        selectedIndex = min(max(0, index), suggestions.count - 1)
        for (position, row) in rows.subviews.enumerated() {
            (row as? SuggestionRow)?.isSelected = position == selectedIndex
        }
    }

    // MARK: - Keys

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if control === keyField {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                onSaveKey?(keyField.stringValue)
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                onCancel?()
                return true
            default:
                return false
            }
        }
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            if mode == .suggestions
                && field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) == suggestionsRequest {
                onChoose?(selectedIndex, true)
            } else if mode != .thinking {
                let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { onSubmit?(text) }
            }
            return true
        case #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            if mode == .suggestions { onChoose?(selectedIndex, false) }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            onCancel?()
            return true
        case #selector(NSResponder.moveDown(_:)) where mode == .suggestions:
            select(selectedIndex + 1)
            return true
        case #selector(NSResponder.moveUp(_:)) where mode == .suggestions:
            select(selectedIndex - 1)
            return true
        default:
            return false
        }
    }
}

/// A view whose origin is its top-left corner.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// One suggested command: the command, then its explanation (and why it is risky).
@MainActor
private final class SuggestionRow: NSView {
    static let height: CGFloat = 38

    var onClick: ((Bool) -> Void)?
    var isSelected = false {
        didSet { needsDisplay = true }
    }
    private let command: NSTextField
    private let explanation: NSTextField

    init(suggestion: CommandSuggestion) {
        command = NSTextField(labelWithString: suggestion.command)
        var detail = suggestion.explanation
        if let risk = suggestion.risk { detail = "⚠ " + risk + (detail.isEmpty ? "" : " — " + detail) }
        explanation = NSTextField(labelWithString: detail)
        super.init(frame: .zero)
        command.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        command.lineBreakMode = .byTruncatingTail
        explanation.font = .systemFont(ofSize: 11)
        explanation.textColor = suggestion.risk == nil ? .secondaryLabelColor : .systemYellow
        explanation.lineBreakMode = .byTruncatingTail
        addSubview(command)
        addSubview(explanation)
    }

    required init?(coder: NSCoder) {
        fatalError("SuggestionRow is created in code")
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard isSelected else { return }
        NSColor.controlAccentColor.withAlphaComponent(0.35).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        command.frame = NSRect(x: 6, y: 3, width: newSize.width - 12, height: 17)
        explanation.frame = NSRect(x: 6, y: 20, width: newSize.width - 12, height: 15)
    }

    override func mouseDown(with event: NSEvent) {
        onClick?(!event.modifierFlags.contains(.option))
    }
}
