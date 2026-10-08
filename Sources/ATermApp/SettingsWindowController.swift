import AppKit
import ATermCore

/// ATerm ▸ Settings… (⌘,): the assistant's endpoint, API key and model, with a key test and model completion, its
/// reasoning level and the model's completions at the zsh prompt. See SPEC/app/settings.md.
@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate,
                                      NSTableViewDataSource, NSTableViewDelegate {
    let endpointField = NSTextField()
    let keyField = NSSecureTextField()
    let modelField = NSTextField()
    let statusField = NSTextField(wrappingLabelWithString: "")
    let testButton = NSButton(title: "Test", target: nil, action: nil)
    let saveButton = NSButton(title: "Save", target: nil, action: nil)
    let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    /// `Default`, then the reasoning levels of the model in the model field.
    let reasoningPopUp = NSPopUpButton()
    /// The model's completions at the zsh prompt (SPEC/app/suggestions.md).
    let suggestionsBox = NSButton(checkboxWithTitle: "Complete commands with the model", target: nil, action: nil)
    /// The Endpoint, API Key, Model, Reasoning and Suggestions labels.
    private(set) var labels: [NSTextField] = []
    /// Called once the window has closed.
    var onClose: (() -> Void)?
    private(set) var isLoadingModels = false

    private let services: AssistantServices
    private let defaults: UserDefaults
    /// Ends the window's modal run.
    private let stopModal: @MainActor (NSWindow) -> Void
    private var loadTask: Task<Void, Never>?
    private static let fieldWidth: CGFloat = 400

    // Model completion: a list in a child panel under the model field.
    private let completionTable = NSTableView()
    private let completionPanel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                          backing: .buffered, defer: true)
    private var completions: [ModelInfo] = []
    private(set) var isCompletionShown = false
    private static let completionRowHeight: CGFloat = 20
    private static let completionVisibleRows = 8

    init(services: AssistantServices, defaults: UserDefaults, stopModal: @escaping @MainActor (NSWindow) -> Void) {
        self.services = services
        self.defaults = defaults
        self.stopModal = stopModal
        let window = SettingsWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 200),
                                    styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Settings"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.isCompletionShown = { [weak self] in self?.isCompletionShown ?? false }
        buildContent(in: window)
        buildCompletion()
        endpointField.stringValue = services.endpoint.absoluteString
        keyField.placeholderString = services.apiKey() == nil ? "Paste your API key" : "Saved in Keychain"
        modelField.stringValue = services.model
        updateReasoningLevels(selecting: services.reasoningEffort)
        suggestionsBox.state = services.commandCompletions ? .on : .off
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Loads the model list when a key is known and no list is cached, before the window is run modally.
    func prepareToShow() {
        if services.models == nil && !isLoadingModels, let key = services.apiKey() {
            loadModels(endpoint: services.endpoint, key: key, reportsResult: false)
        }
    }

    // MARK: - Layout

    private func buildContent(in window: NSWindow) {
        endpointField.placeholderString = OpenRouterClient.defaultEndpoint.absoluteString
        modelField.placeholderString = OpenRouterClient.defaultModel
        modelField.delegate = self
        for field in [endpointField, keyField, modelField] as [NSTextField] {
            field.translatesAutoresizingMaskIntoConstraints = false
            field.widthAnchor.constraint(equalToConstant: Self.fieldWidth).isActive = true
            field.lineBreakMode = .byTruncatingTail
            field.usesSingleLineMode = true
        }
        // The status line wraps beside Test, up to 3 lines; the full text is its tooltip.
        let statusWidth = Self.fieldWidth - testButton.fittingSize.width - 8
        statusField.textColor = .secondaryLabelColor
        statusField.maximumNumberOfLines = 3
        statusField.lineBreakMode = .byWordWrapping
        statusField.cell?.truncatesLastVisibleLine = true
        statusField.preferredMaxLayoutWidth = statusWidth
        statusField.translatesAutoresizingMaskIntoConstraints = false
        statusField.widthAnchor.constraint(equalToConstant: statusWidth).isActive = true
        testButton.target = self
        testButton.action = #selector(testKey(_:))
        saveButton.target = self
        saveButton.action = #selector(save(_:))
        saveButton.keyEquivalent = "\r"
        cancelButton.target = self
        cancelButton.action = #selector(cancel(_:))
        cancelButton.keyEquivalent = "\u{1B}"

        let test = NSStackView(views: [testButton, statusField])
        test.alignment = .firstBaseline
        test.spacing = 8
        labels = [label("Endpoint:"), label("API Key:"), label("Model:"), label("Reasoning:"), label("Suggestions:")]
        let grid = NSGridView(views: [
            [labels[0], endpointField],
            [labels[1], keyField],
            [NSGridCell.emptyContentView, test],
            [labels[2], modelField],
            [labels[3], reasoningPopUp],
            [labels[4], suggestionsBox],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.row(at: 2).yPlacement = .top
        grid.row(at: 2).rowAlignment = .none
        grid.rowSpacing = 10
        grid.columnSpacing = 8
        let buttons = NSStackView(views: [cancelButton, saveButton])
        let content = NSView()
        for view in [grid, buttons] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            grid.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            buttons.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: 20),
            buttons.leadingAnchor.constraint(greaterThanOrEqualTo: content.leadingAnchor, constant: 20),
            buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
        ])
        window.contentView = content
        fitWindow()
    }

    /// Sizes the window to its content, keeping its top left corner.
    private func fitWindow() {
        guard let window, let content = window.contentView else { return }
        content.layoutSubtreeIfNeeded()
        let old = window.frame
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: content.fittingSize))
        frame.origin = NSPoint(x: old.minX, y: old.maxY - frame.height)
        window.setFrame(frame, display: window.isVisible)
        content.layoutSubtreeIfNeeded()
    }

    private func setStatus(_ text: String) {
        statusField.stringValue = text
        statusField.toolTip = text.isEmpty ? nil : text
        fitWindow()
    }

    private func label(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.alignment = .right
        return label
    }

    private func buildCompletion() {
        for (identifier, width) in [("id", 280.0), ("price", 260.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
            column.width = width
            completionTable.addTableColumn(column)
        }
        completionTable.headerView = nil
        completionTable.rowHeight = Self.completionRowHeight
        completionTable.intercellSpacing = NSSize(width: 6, height: 0)
        completionTable.style = .plain
        completionTable.dataSource = self
        completionTable.delegate = self
        completionTable.target = self
        completionTable.action = #selector(completionClicked(_:))
        let scroll = NSScrollView()
        scroll.documentView = completionTable
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        completionPanel.contentView = scroll
        completionPanel.hasShadow = true
        completionPanel.isReleasedWhenClosed = false
        completionPanel.worksWhenModal = true
    }

    // MARK: - Actions

    /// Test: fetches the model list from the endpoint and with the key being edited.
    @objc func testKey(_ sender: Any?) {
        let typed = keyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let key = typed.isEmpty ? services.apiKey() : typed else {
            setStatus("Enter an API key to test.")
            return
        }
        let endpoint: URL?
        switch editedEndpoint() {
        case .standard: endpoint = nil
        case .url(let url): endpoint = url
        case .invalid(let message):
            setStatus("✗ " + message)
            return
        }
        setStatus("Testing…")
        loadModels(endpoint: endpoint ?? OpenRouterClient.defaultEndpoint, key: key, reportsResult: true)
    }

    @objc func save(_ sender: Any?) {
        let endpoint: URL?
        switch editedEndpoint() {
        case .standard: endpoint = nil
        case .url(let url): endpoint = url
        case .invalid(let message):
            setStatus(message)
            return
        }
        let key = keyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty {
            do {
                try services.configuration.keyStore.save(key)
            } catch {
                setStatus("The key could not be saved in the Keychain (\(error)).")
                return
            }
        }
        let model = modelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if let endpoint {
            defaults.set(endpoint.absoluteString, forKey: "AssistantEndpoint")
        } else {
            defaults.removeObject(forKey: "AssistantEndpoint")
        }
        if model.isEmpty {
            defaults.removeObject(forKey: "AssistantModel")
        } else {
            defaults.set(model, forKey: "AssistantModel")
        }
        let effort = selectedReasoningLevel
        if let effort {
            defaults.set(effort, forKey: "AssistantReasoningEffort")
        } else {
            defaults.removeObject(forKey: "AssistantReasoningEffort")
        }
        let completions = suggestionsBox.state == .on
        if completions {
            defaults.removeObject(forKey: "AssistantSuggestions")
        } else {
            defaults.set(false, forKey: "AssistantSuggestions")
        }
        if (endpoint ?? OpenRouterClient.defaultEndpoint) != services.endpoint { services.models = nil }
        services.setEndpoint(endpoint)
        services.setModel(model.isEmpty ? nil : model)
        services.setReasoningEffort(effort)
        services.setCommandCompletions(completions)
        window?.close()
    }

    @objc func cancel(_ sender: Any?) {
        window?.close()
    }

    private enum EndpointInput {
        /// Empty: the default endpoint.
        case standard
        case url(URL)
        case invalid(String)
    }

    /// The endpoint field: an http(s) URL with a host, the API's base URL (not its chat completions URL).
    private func editedEndpoint() -> EndpointInput {
        let text = endpointField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return .standard }
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host, !host.isEmpty
        else { return .invalid("Invalid endpoint URL.") }
        var path = url.path
        while path.hasSuffix("/") { path.removeLast() }
        if path.lowercased().hasSuffix("/chat/completions") {
            return .invalid("Use the API base URL, without /chat/completions.")
        }
        return .url(url)
    }

    private func loadModels(endpoint: URL, key: String, reportsResult: Bool) {
        loadTask?.cancel()
        isLoadingModels = true
        let services = services
        loadTask = Task { [weak self] in
            let result: Result<ModelList, Error>
            do {
                result = .success(try await services.fetchModels(endpoint: endpoint, key: key))
            } catch {
                result = .failure(error)
            }
            guard let self, !Task.isCancelled else { return }
            self.isLoadingModels = false
            switch result {
            case .success(let list):
                services.models = list.models
                if reportsResult {
                    let count = "\(list.models.count) model\(list.models.count == 1 ? "" : "s")"
                    self.setStatus(list.checksKey ? "✓ Key valid — \(count)" : "✓ \(count) (this endpoint does not check the key)")
                }
                if self.isCompletionShown { self.updateCompletion() }
                self.updateReasoningLevels(selecting: self.selectedReasoningLevel ?? services.reasoningEffort)
            case .failure(let error):
                guard reportsResult, !(error is CancellationError) else { return }
                self.setStatus("✗ " + ((error as? AssistantError)?.message ?? "\(error)"))
            }
        }
    }

    // MARK: - Window

    func windowWillClose(_ notification: Notification) {
        hideCompletion()
        loadTask?.cancel()
        loadTask = nil
        isLoadingModels = false
        if let window { stopModal(window) }
        onClose?()
        onClose = nil
    }

    // MARK: - Model completion

    /// The rows of the completion list as drawn: the model id and its prices.
    var completionRows: [(id: String, price: String)] {
        (0..<completionTable.numberOfRows).map { row in
            (text(column: 0, row: row), text(column: 1, row: row))
        }
    }

    var selectedCompletionRow: Int? {
        completionTable.selectedRow >= 0 ? completionTable.selectedRow : nil
    }

    private func text(column: Int, row: Int) -> String {
        (completionTable.view(atColumn: column, row: row, makeIfNecessary: true) as? NSTextField)?.stringValue ?? ""
    }

    func controlTextDidChange(_ notification: Notification) {
        guard notification.object as? NSTextField === modelField else { return }
        updateCompletion()
        updateReasoningLevels(selecting: selectedReasoningLevel)
    }

    // MARK: - Reasoning level

    /// The level chosen in the pop-up; nil for `Default`.
    private var selectedReasoningLevel: String? {
        reasoningPopUp.indexOfSelectedItem > 0 ? reasoningPopUp.titleOfSelectedItem : nil
    }

    /// Offers `Default` and the levels of the model named in the model field, keeping `level` when offered.
    private func updateReasoningLevels(selecting level: String?) {
        let model = modelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let levels = services.models?.first { $0.id == model }?.reasoningEfforts ?? []
        if reasoningPopUp.itemTitles != ["Default"] + levels {
            reasoningPopUp.removeAllItems()
            reasoningPopUp.addItems(withTitles: ["Default"] + levels)
        }
        if let level, levels.contains(level) {
            reasoningPopUp.selectItem(withTitle: level)
        } else {
            reasoningPopUp.selectItem(at: 0)
        }
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard notification.object as? NSTextField === modelField else { return }
        hideCompletion()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard control === modelField, isCompletionShown else { return false }
        switch selector {
        case #selector(NSResponder.moveDown(_:)):
            moveSelection(by: 1)
        case #selector(NSResponder.moveUp(_:)):
            moveSelection(by: -1)
        case #selector(NSResponder.insertNewline(_:)):
            if let row = selectedCompletionRow { choose(row) } else { hideCompletion() }
        case #selector(NSResponder.cancelOperation(_:)):
            hideCompletion()
        default:
            return false
        }
        return true
    }

    /// Lists the models whose id or name contains the model field's text, ignoring case.
    private func updateCompletion() {
        let text = modelField.stringValue.trimmingCharacters(in: .whitespaces)
        let models = services.models ?? []
        completions = text.isEmpty ? [] : models.filter {
            $0.id.range(of: text, options: .caseInsensitive) != nil
                || $0.name.range(of: text, options: .caseInsensitive) != nil
        }
        guard !completions.isEmpty else {
            hideCompletion()
            return
        }
        completionTable.reloadData()
        completionTable.deselectAll(nil)
        showCompletion()
    }

    private func showCompletion() {
        isCompletionShown = true
        guard let window, window.isVisible else { return }
        let rows = min(completions.count, Self.completionVisibleRows)
        let size = NSSize(width: max(modelField.frame.width, 560), height: CGFloat(rows) * Self.completionRowHeight + 4)
        let fieldFrame = window.convertToScreen(modelField.convert(modelField.bounds, to: nil))
        completionPanel.setFrame(NSRect(x: fieldFrame.minX, y: fieldFrame.minY - size.height - 2,
                                        width: size.width, height: size.height), display: true)
        if completionPanel.parent == nil { window.addChildWindow(completionPanel, ordered: .above) }
        completionPanel.orderFront(nil)
    }

    private func hideCompletion() {
        isCompletionShown = false
        completionPanel.parent?.removeChildWindow(completionPanel)
        completionPanel.orderOut(nil)
    }

    private func moveSelection(by delta: Int) {
        let count = completionTable.numberOfRows
        guard count > 0 else { return }
        let row = selectedCompletionRow.map { min(max($0 + delta, 0), count - 1) } ?? (delta > 0 ? 0 : count - 1)
        completionTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        completionTable.scrollRowToVisible(row)
    }

    private func choose(_ row: Int) {
        guard row >= 0, row < completions.count else { return }
        let id = completions[row].id
        modelField.stringValue = id
        if let editor = modelField.currentEditor() {
            editor.string = id
            editor.selectedRange = NSRange(location: id.utf16.count, length: 0)
        }
        hideCompletion()
        updateReasoningLevels(selecting: selectedReasoningLevel)
    }

    @objc private func completionClicked(_ sender: Any?) {
        choose(completionTable.clickedRow)
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        completions.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let identifier = tableColumn?.identifier else { return nil }
        let label = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTextField
            ?? NSTextField(labelWithString: "")
        label.identifier = identifier
        label.lineBreakMode = .byTruncatingTail
        let model = completions[row]
        if identifier.rawValue == "id" {
            label.stringValue = model.id
            label.textColor = .labelColor
        } else {
            label.stringValue = model.priceSummary
            label.textColor = .secondaryLabelColor
        }
        return label
    }
}

/// Lets Return and Esc reach the model completion instead of the Save and Cancel buttons while it is shown.
private final class SettingsWindow: NSWindow {
    var isCompletionShown: () -> Bool = { false }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if isCompletionShown(), event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty,
           [36, 76, 53].contains(event.keyCode) {
            return false
        }
        return super.performKeyEquivalent(with: event)
    }
}
