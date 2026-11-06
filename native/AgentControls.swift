import AppKit

struct AgentActivityRecord {
    let id: String
    var title: String
    var detail: String
    var status: String

    init(_ value: [String: Any]) {
        id = value["id"] as? String ?? UUID().uuidString
        title = value["title"] as? String ?? "Tool"
        detail = value["detail"] as? String ?? ""
        status = value["status"] as? String ?? "completed"
    }
}

struct AgentCommandRecord {
    let name: String
    let args: String
    let output: String

    init(_ value: [String: Any]) {
        name = value["name"] as? String ?? ""
        args = value["args"] as? String ?? ""
        output = value["output"] as? String ?? ""
    }
}

struct AgentMessageRecord {
    var role: String
    var text: String
    var activities: [AgentActivityRecord] = []
    var command: AgentCommandRecord?

    init(role: String, text: String) { self.role = role; self.text = text }
    init?(_ value: [String: Any]) {
        guard let role = value["role"] as? String, ["user", "assistant", "command"].contains(role) else { return nil }
        self.role = role
        text = value["text"] as? String ?? ""
        activities = (value["activities"] as? [[String: Any]] ?? []).map(AgentActivityRecord.init)
        if role == "command", let value = value["command"] as? [String: Any] { command = AgentCommandRecord(value) }
    }
}

enum AgentProviders {
    static func name(_ id: String) -> String { ["claude": "Claude", "pi": "Pi"][id] ?? "Codex" }
}

struct AgentHistorySession {
    let id: String
    let provider: String
    let title: String
    let cwd: String
    let updatedAt: Date

    init?(_ value: [String: Any]) {
        guard let id = value["id"] as? String, let provider = value["provider"] as? String else { return nil }
        self.id = id
        self.provider = provider
        title = value["title"] as? String ?? "Untitled conversation"
        cwd = value["cwd"] as? String ?? ""
        updatedAt = Date(timeIntervalSince1970: (value["updatedAt"] as? Double ?? 0) / 1000)
    }
}

struct AgentModelOption {
    let id: String
    let label: String
    let resolvedModel: String?
    let efforts: [String]
    let defaultEffort: String?
    let isDefault: Bool

    init?(_ value: [String: Any]) {
        guard let id = value["id"] as? String else { return nil }
        self.id = id
        label = value["label"] as? String ?? id
        resolvedModel = value["resolvedModel"] as? String
        efforts = value["efforts"] as? [String] ?? []
        defaultEffort = value["defaultEffort"] as? String
        isDefault = value["isDefault"] as? Bool ?? false
    }
}

struct AgentSkillOption {
    let name: String
    let description: String
    let insertText: String
    let argumentHint: String?

    init?(_ value: [String: Any]) {
        guard let name = value["name"] as? String, let insertText = value["insertText"] as? String else { return nil }
        self.name = name
        self.description = value["description"] as? String ?? ""
        self.insertText = insertText
        argumentHint = value["argumentHint"] as? String
    }
}

struct AgentCompletion {
    let title: String
    let description: String
    let insertText: String
}

@MainActor
final class AgentModelControls: NSStackView, NSMenuDelegate {
    var onChange: ((String?, String?) -> Void)?
    private let model = NSPopUpButton(frame: .zero, pullsDown: false)
    private let effort = NSPopUpButton(frame: .zero, pullsDown: false)
    private var options: [AgentModelOption] = []
    private var resolvedModel: String?
    private var resolvedEffort: String?
    private var effortOptions: [String] = []
    private var defaultModelTitle = "Default model"
    private var defaultEffortTitle = "Default effort"

    override init(frame: NSRect) {
        super.init(frame: frame)
        orientation = .horizontal
        alignment = .centerY
        spacing = 4
        model.controlSize = .small
        effort.controlSize = .small
        model.cell?.lineBreakMode = .byTruncatingTail
        effort.cell?.lineBreakMode = .byTruncatingTail
        model.target = self
        model.action = #selector(modelChanged)
        effort.target = self
        effort.action = #selector(effortChanged)
        model.setAccessibilityIdentifier("rex-agent.model")
        model.setAccessibilityLabel("Model")
        effort.setAccessibilityIdentifier("rex-agent.effort")
        effort.setAccessibilityLabel("Reasoning effort")
        model.toolTip = "Model for the next turn. Default uses your agent configuration."
        effort.toolTip = "Reasoning effort for the next turn. Default uses your agent configuration."
        model.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        effort.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        [model, effort].forEach { addArrangedSubview($0); $0.isBordered = false; $0.font = .systemFont(ofSize: 11) }
        model.translatesAutoresizingMaskIntoConstraints = false
        effort.translatesAutoresizingMaskIntoConstraints = false
        model.widthAnchor.constraint(greaterThanOrEqualToConstant: 60).isActive = true
        model.widthAnchor.constraint(lessThanOrEqualToConstant: 220).isActive = true
        effort.widthAnchor.constraint(greaterThanOrEqualToConstant: 60).isActive = true
        effort.widthAnchor.constraint(lessThanOrEqualToConstant: 120).isActive = true
        update(options: [], selectedModel: nil, selectedEffort: nil, resolvedModel: nil)
    }

    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { nil }

    var selectedModel: String? { model.selectedItem?.representedObject as? String }
    var selectedEffort: String? { effort.selectedItem?.representedObject as? String }

    func update(options: [AgentModelOption], selectedModel: String?, selectedEffort: String?, resolvedModel: String?, resolvedEffort: String? = nil) {
        self.options = options
        self.resolvedModel = resolvedModel
        self.resolvedEffort = resolvedEffort
        model.removeAllItems()
        let resolvedOption = options.first { $0.id == resolvedModel || (resolvedModel != nil && $0.resolvedModel == resolvedModel) }
        defaultModelTitle = selectedModel == nil ? resolvedOption?.label ?? resolvedModel ?? "Default model" : "Default model"
        model.addItem(withTitle: defaultModelTitle)
        for option in options {
            let item = NSMenuItem(title: option.label, action: nil, keyEquivalent: "")
            item.representedObject = option.id
            model.menu?.addItem(item)
        }
        if let selectedModel, !options.contains(where: { $0.id == selectedModel }) {
            model.addItem(withTitle: selectedModel)
            model.lastItem?.representedObject = selectedModel
        }
        if let selectedModel, let item = model.itemArray.first(where: { $0.representedObject as? String == selectedModel }) { model.select(item) }
        else { model.selectItem(at: 0) }
        model.menu?.delegate = self
        model.toolTip = ["Model for the next turn. Use agent default clears the override.", resolvedModel].compactMap { $0 }.joined(separator: "\n")
        updateEfforts(selected: selectedEffort)
    }

    private func updateEfforts(selected: String?) {
        let option = options.first(where: { $0.id == selectedModel })
            ?? options.first(where: { resolvedModel != nil && ($0.id == resolvedModel || $0.resolvedModel == resolvedModel) })
        effortOptions = option?.efforts ?? []
        effort.removeAllItems()
        let inheritedEffort = resolvedEffort ?? option?.defaultEffort
        defaultEffortTitle = selected == nil ? inheritedEffort?.capitalized ?? "Default effort" : "Default effort"
        effort.addItem(withTitle: defaultEffortTitle)
        for value in effortOptions {
            let item = NSMenuItem(title: value.capitalized, action: nil, keyEquivalent: "")
            item.representedObject = value
            effort.menu?.addItem(item)
        }
        if let selected, !effortOptions.contains(selected) {
            effort.addItem(withTitle: selected.capitalized)
            effort.lastItem?.representedObject = selected
        }
        if let selected, let item = effort.itemArray.first(where: { $0.representedObject as? String == selected }) { effort.select(item) }
        else { effort.selectItem(at: 0) }
        effort.menu?.delegate = self
        effort.toolTip = effortOptions.isEmpty ? "Choose a model to see its supported reasoning effort options." : "Reasoning effort for the next turn. Default uses your agent configuration."
    }

    func setEnabled(_ value: Bool) {
        model.isEnabled = value
        effort.isEnabled = value && (!effortOptions.isEmpty || selectedEffort != nil)
    }

    func showModelMenu() { if model.isEnabled { model.performClick(nil) } }
    func showEffortMenu() { if effort.isEnabled { effort.performClick(nil) } }

    func apply(_ palette: AgentPalette) {
        model.contentTintColor = palette.text
        effort.contentTintColor = palette.secondary
    }

    @objc private func modelChanged() {
        let selected = selectedModel
        resolvedModel = nil
        resolvedEffort = nil
        update(options: options, selectedModel: selected, selectedEffort: nil, resolvedModel: nil)
        effort.isEnabled = !effortOptions.isEmpty
        onChange?(selected, nil)
    }
    @objc private func effortChanged() { onChange?(selectedModel, selectedEffort) }

    func menuWillOpen(_ menu: NSMenu) { menu.item(at: 0)?.title = "Use agent default" }
    func menuDidClose(_ menu: NSMenu) {
        menu.item(at: 0)?.title = menu === model.menu ? defaultModelTitle : defaultEffortTitle
    }
}

@MainActor
final class AgentCompletionList: NSView, NSTableViewDataSource, NSTableViewDelegate {
    var onChoose: ((AgentCompletion) -> Void)?
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private var entries: [AgentCompletion] = []
    private var height: NSLayoutConstraint!
    private var palette: AgentPalette?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("completion")))
        table.headerView = nil
        table.rowHeight = 38
        table.intercellSpacing = .zero
        table.style = .plain
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(chooseClicked)
        table.setAccessibilityIdentifier("rex-agent.completions")
        table.setAccessibilityLabel("Command and skill suggestions")
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
        height = heightAnchor.constraint(equalToConstant: 46)
        height.isActive = true
        isHidden = true
    }
    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { nil }

    func show(_ entries: [AgentCompletion]) {
        self.entries = entries
        isHidden = entries.isEmpty
        height.constant = CGFloat(min(6, max(1, entries.count))) * 38 + 8
        table.reloadData()
        if !entries.isEmpty { table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
    }
    func dismiss() { isHidden = true; entries = [] }
    func handle(_ event: NSEvent) -> Bool {
        guard !isHidden, !entries.isEmpty else { return false }
        switch event.keyCode {
        case 125, 126:
            let direction = event.keyCode == 125 ? 1 : -1
            let index = max(0, min(entries.count - 1, table.selectedRow + direction))
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            table.scrollRowToVisible(index)
            return true
        case 36, 48:
            if event.modifierFlags.contains(.shift) { return false }
            chooseSelected()
            return true
        case 53: dismiss(); return true
        default: return false
        }
    }
    private func chooseSelected() {
        let index = table.selectedRow
        guard entries.indices.contains(index) else { return }
        let entry = entries[index]
        dismiss()
        onChoose?(entry)
    }
    @objc private func chooseClicked() { chooseSelected() }
    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let entry = entries[row]
        let cell = AgentTwoLineCell()
        cell.set(title: entry.title, subtitle: entry.description)
        if let palette { cell.apply(palette, selected: row == table.selectedRow) }
        return cell
    }
    func tableViewSelectionDidChange(_ notification: Notification) { recolorRows() }
    func apply(_ palette: AgentPalette) {
        self.palette = palette
        layer?.backgroundColor = palette.surface.cgColor
        layer?.borderColor = palette.border.cgColor
        table.backgroundColor = palette.surface
        recolorRows()
    }
    private func recolorRows() {
        guard let palette else { return }
        for row in 0..<table.numberOfRows {
            (table.view(atColumn: 0, row: row, makeIfNecessary: false) as? AgentTwoLineCell)?.apply(palette, selected: row == table.selectedRow)
        }
    }
}

@MainActor
final class AgentHistoryController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    var onRequest: ((String, String?, Bool) -> Void)?
    var onResume: ((AgentHistorySession) -> Void)?
    private let heading = NSTextField(labelWithString: "Resume conversation")
    private let instructions = NSTextField(wrappingLabelWithString: "Select a conversation to continue in this pane.")
    private let search = NSSearchField()
    private let scope = NSSegmentedControl(labels: ["This project", "All projects"], trackingMode: .selectOne, target: nil, action: nil)
    private let table = NSTableView()
    private let footer = NSTextField(wrappingLabelWithString: "Loading conversations…")
    private let progress = NSProgressIndicator()
    private let more = NSButton(title: "Load more", target: nil, action: nil)
    private let resume = NSButton(title: "Resume in this pane", target: nil, action: nil)
    private let refresh = NSButton()
    private let recover = NSButton(title: "Find older sessions", target: nil, action: nil)
    private var sessions: [AgentHistorySession] = []
    private var filtered: [AgentHistorySession] = []
    private var nextCursor: String?
    private var palette: AgentPalette?
    private var loading = false
    private var warnings: [String] = []
    private var errorMessage: String?
    private var recoveryComplete = false

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        view = root
        preferredContentSize = NSSize(width: 360, height: 418)
        heading.font = .systemFont(ofSize: 13, weight: .semibold)
        instructions.font = .systemFont(ofSize: 11)
        search.placeholderString = "Search conversations"
        search.delegate = self
        search.setAccessibilityIdentifier("rex-agent.history-search")
        scope.selectedSegment = 0
        scope.controlSize = .small
        scope.target = self
        scope.action = #selector(changeScope)
        scope.setAccessibilityLabel("Conversation scope")
        scope.setAccessibilityIdentifier("rex-agent.history-scope")
        refresh.title = "Refresh"
        refresh.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Refresh conversations")
        refresh.imagePosition = .imageLeading
        refresh.bezelStyle = .rounded
        refresh.controlSize = .small
        refresh.target = self
        refresh.action = #selector(reload)
        refresh.toolTip = "Refresh conversations"
        refresh.setAccessibilityIdentifier("rex-agent.history-refresh")
        recover.bezelStyle = .inline
        recover.controlSize = .small
        recover.target = self
        recover.action = #selector(findOlderSessions)
        recover.toolTip = "Scan older CLI session files for conversations missing from History. This is slower than Refresh."
        recover.setAccessibilityIdentifier("rex-agent.history-recover")
        let scopeRow = NSStackView(views: [scope, NSView(), refresh])
        scopeRow.orientation = .horizontal
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("session")))
        table.headerView = nil
        table.rowHeight = 48
        table.style = .plain
        table.intercellSpacing = .zero
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(resumeSelected)
        table.setAccessibilityIdentifier("rex-agent.history-list")
        table.setAccessibilityLabel("Conversations")
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        footer.font = .systemFont(ofSize: 11)
        footer.lineBreakMode = .byTruncatingTail
        footer.maximumNumberOfLines = 2
        footer.setAccessibilityIdentifier("rex-agent.history-status")
        progress.style = .spinning
        progress.controlSize = .small
        progress.isDisplayedWhenStopped = false
        progress.translatesAutoresizingMaskIntoConstraints = false
        progress.widthAnchor.constraint(equalToConstant: 14).isActive = true
        progress.heightAnchor.constraint(equalToConstant: 14).isActive = true
        let statusRow = NSStackView(views: [progress, footer])
        statusRow.orientation = .horizontal
        statusRow.alignment = .centerY
        statusRow.spacing = 6
        more.bezelStyle = .rounded
        more.controlSize = .small
        more.target = self
        more.action = #selector(loadMore)
        more.isHidden = true
        resume.bezelStyle = .rounded
        resume.controlSize = .small
        resume.target = self
        resume.action = #selector(resumeSelected)
        resume.isEnabled = false
        resume.toolTip = "Load this conversation here and continue with its saved context"
        resume.setAccessibilityIdentifier("rex-agent.resume")
        let actions = NSStackView(views: [more, NSView(), resume])
        actions.orientation = .horizontal
        let stack = NSStackView(views: [heading, instructions, search, scopeRow, scroll, statusRow, recover, actions])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 14),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 176),
        ])
        [heading, instructions, search, scopeRow, scroll, statusRow, actions].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            $0.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        if let palette { apply(palette) }
    }

    var selectedScope: String { scope.selectedSegment == 0 ? "project" : "all" }
    func request(repair: Bool = false) { _ = view; setLoading(repair: repair); onRequest?(selectedScope, nil, repair) }
    private func setLoading(repair: Bool = false) {
        loading = true
        errorMessage = nil
        footer.stringValue = repair ? "Finding older CLI sessions…" : "Loading conversations…"
        footer.toolTip = repair ? "Scanning older session files can take several seconds. Normal History and Refresh use the fast native index." : nil
        progress.startAnimation(nil)
        resume.isEnabled = false
        more.isEnabled = false
        refresh.isEnabled = false
        recover.isEnabled = false
        refresh.title = "Refresh"
    }
    func update(_ values: [AgentHistorySession], nextCursor: String?, append: Bool, warnings: [String] = [], source: String? = nil) {
        _ = view
        loading = false
        errorMessage = nil
        recoveryComplete = source == "native-repair"
        progress.stopAnimation(nil)
        if append {
            let existing = Set(sessions.map { $0.provider + ":" + $0.id })
            sessions.append(contentsOf: values.filter { !existing.contains($0.provider + ":" + $0.id) })
        } else { sessions = values }
        sessions.sort { $0.updatedAt > $1.updatedAt }
        self.warnings = append ? Array(Set(self.warnings + warnings)).sorted() : warnings
        self.nextCursor = nextCursor
        more.isHidden = nextCursor == nil
        more.isEnabled = nextCursor != nil
        refresh.isEnabled = true
        recover.isEnabled = true
        refresh.title = "Refresh"
        filter()
    }
    func showError(_ text: String) {
        _ = view
        loading = false
        errorMessage = text
        progress.stopAnimation(nil)
        footer.stringValue = text
        footer.toolTip = text
        refresh.isEnabled = true
        recover.isEnabled = true
        refresh.title = "Retry"
        more.isEnabled = nextCursor != nil
        resume.isEnabled = table.selectedRow >= 0
    }
    @objc private func reload() { request() }
    @objc private func findOlderSessions() { request(repair: true) }
    @objc private func changeScope() { sessions = []; nextCursor = nil; more.isHidden = true; filter(); request() }
    @objc private func loadMore() {
        guard let nextCursor else { return }
        setLoading(repair: recoveryComplete)
        onRequest?(selectedScope, nextCursor, false)
    }
    @objc private func resumeSelected() {
        guard !loading, filtered.indices.contains(table.selectedRow) else { return }
        onResume?(filtered[table.selectedRow])
    }
    func controlTextDidChange(_ obj: Notification) { filter() }
    private func filter() {
        let selected = filtered.indices.contains(table.selectedRow) ? filtered[table.selectedRow].provider + ":" + filtered[table.selectedRow].id : nil
        let query = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        filtered = sessions.filter { query.isEmpty || [$0.title, $0.cwd, $0.provider].joined(separator: " ").lowercased().contains(query) }
        table.reloadData()
        if let selected, let row = filtered.firstIndex(where: { $0.provider + ":" + $0.id == selected }) { table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        else { table.deselectAll(nil) }
        resume.isEnabled = !loading && table.selectedRow >= 0
        if !loading && errorMessage == nil {
            let count: String
            if filtered.isEmpty {
                count = sessions.isEmpty && selectedScope == "project" ? "No conversations in this project. Try All projects." : "No matching conversations"
            } else { count = "\(filtered.count) conversation\(filtered.count == 1 ? "" : "s") · Select to resume" }
            footer.stringValue = warnings.isEmpty ? count + (recoveryComplete ? " · Older sessions included" : "") : "\(count) · Some history unavailable"
            footer.toolTip = warnings.isEmpty ? nil : warnings.joined(separator: "\n")
        }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { filtered.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let session = filtered[row]
        let date = DateFormatter.localizedString(from: session.updatedAt, dateStyle: .short, timeStyle: .short)
        let folder = URL(fileURLWithPath: session.cwd).lastPathComponent
        let cell = AgentTwoLineCell()
        cell.set(title: session.title, subtitle: [AgentProviders.name(session.provider), folder, date].filter { !$0.isEmpty }.joined(separator: " · "))
        cell.toolTip = session.cwd
        if let palette { cell.apply(palette, selected: row == table.selectedRow) }
        return cell
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        resume.isEnabled = !loading && filtered.indices.contains(table.selectedRow)
        recolorRows()
    }
    func apply(_ palette: AgentPalette) {
        self.palette = palette
        guard isViewLoaded else { return }
        view.layer?.backgroundColor = palette.surface.cgColor
        table.backgroundColor = palette.surface
        heading.textColor = palette.text
        instructions.textColor = palette.secondary
        footer.textColor = palette.secondary
        search.textColor = palette.text
        refresh.contentTintColor = palette.text
        recover.contentTintColor = palette.secondary
        recolorRows()
    }
    private func recolorRows() {
        guard let palette else { return }
        for row in 0..<table.numberOfRows {
            (table.view(atColumn: 0, row: row, makeIfNecessary: false) as? AgentTwoLineCell)?.apply(palette, selected: row == table.selectedRow)
        }
    }
}

@MainActor
private final class AgentTwoLineCell: NSTableCellView {
    private let title = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(labelWithString: "")
    override init(frame: NSRect) {
        super.init(frame: frame)
        title.font = .systemFont(ofSize: 12, weight: .medium)
        subtitle.font = .systemFont(ofSize: 10)
        title.lineBreakMode = .byTruncatingTail
        subtitle.lineBreakMode = .byTruncatingTail
        let stack = NSStackView(views: [title, subtitle])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            title.widthAnchor.constraint(equalTo: stack.widthAnchor),
            subtitle.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }
    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { nil }
    func set(title: String, subtitle: String) { self.title.stringValue = title; self.subtitle.stringValue = subtitle }
    func apply(_ palette: AgentPalette, selected: Bool) {
        title.textColor = selected ? .selectedMenuItemTextColor : palette.text
        subtitle.textColor = selected ? .selectedMenuItemTextColor : palette.secondary
    }
}
