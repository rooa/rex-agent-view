import AppKit

private enum AgentMarkdownBlock {
    case prose(NSAttributedString)
    case code(String, String, CGFloat, String?)
    case table([[NSAttributedString]], [NSTextAlignment])
}

@MainActor
final class AgentMarkdownView: NSStackView {
    var onLink: ((Any) -> Bool)?
    var preserveSoftBreaks = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        orientation = .vertical
        alignment = .leading
        spacing = 14
    }
    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { nil }

    func update(_ source: String, palette: AgentPalette) {
        let blocks = AgentMarkdown.blocks(source, palette: palette, preserveSoftBreaks: preserveSoftBreaks)
        for (index, block) in blocks.enumerated() {
            let existing = arrangedSubviews.indices.contains(index) ? arrangedSubviews[index] : nil
            let view: NSView
            switch block {
            case .prose(let text):
                let prose = existing as? GrowingTextView ?? GrowingTextView()
                prose.onLink = { [weak self] in self?.onLink?($0) ?? false }
                prose.selectedTextAttributes = [.backgroundColor: palette.selection, .foregroundColor: palette.selectedText]
                prose.linkTextAttributes = [.foregroundColor: palette.accent]
                prose.setContent(text)
                view = prose
            case .code(let text, let language, let indent, let marker):
                let code = existing as? AgentCodeBlockView ?? AgentCodeBlockView()
                code.update(text: text, language: language, palette: palette, indent: indent, marker: marker)
                view = code
            case .table(let rows, let alignments):
                let table = existing as? AgentTableView ?? AgentTableView()
                table.onLink = { [weak self] in self?.onLink?($0) ?? false }
                table.update(rows: rows, alignments: alignments, palette: palette)
                view = table
            }
            if view !== existing {
                if let existing { removeArrangedSubview(existing); existing.removeFromSuperview() }
                view.translatesAutoresizingMaskIntoConstraints = false
                insertArrangedSubview(view, at: index)
                view.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
            }
        }
        while arrangedSubviews.count > blocks.count {
            let view = arrangedSubviews.last!
            removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        isHidden = blocks.isEmpty
    }
}

@MainActor
private enum AgentMarkdown {
    static func blocks(_ source: String, palette: AgentPalette, preserveSoftBreaks: Bool) -> [AgentMarkdownBlock] {
        guard !source.isEmpty else { return [] }
        let fonts = AgentAppearance.shared.settings
        guard let parsed = try? AttributedString(markdown: source) else {
            return [.prose(NSAttributedString(string: source, attributes: [.font: fonts.textFont(), .foregroundColor: palette.text]))]
        }
        var blocks: [AgentMarkdownBlock] = []
        var prose = NSMutableAttributedString(string: "")
        var paragraph = NSMutableAttributedString(string: "")
        var identity: Int?
        var code = false
        var language = ""
        var codeIndent: CGFloat = 0
        var codeMarker: String?
        var seenListItems: Set<Int> = []
        var listContinuation = false
        var tableIdentity: Int?
        var tableAlignments: [NSTextAlignment] = []
        var tableRows: [Int: [Int: NSMutableAttributedString]] = [:]

        func inlineAttributes(_ intent: InlinePresentationIntent?, link: URL?, base: [NSAttributedString.Key: Any]) -> [NSAttributedString.Key: Any] {
            var attributes = base
            var font = attributes[.font] as! NSFont
            if let intent {
                if intent.contains(.code) {
                    attributes[.font] = fonts.codeFont()
                    attributes[AgentTextLayoutManager.inlineCodeBackground] = palette.surface.blended(withFraction: 0.2, of: palette.background) ?? palette.surface
                } else {
                    if intent.contains(.stronglyEmphasized) { font = fonts.textFont(size: font.pointSize, weight: .semibold) }
                    if intent.contains(.emphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
                    attributes[.font] = font
                }
                if intent.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            }
            if let link { attributes[.link] = link; attributes[.foregroundColor] = palette.accent }
            return attributes
        }

        func finishProse() {
            guard prose.length > 0 else { return }
            if prose.string.hasSuffix("\n") { prose.deleteCharacters(in: NSRange(location: prose.length - 1, length: 1)) }
            blocks.append(.prose(prose.copy() as! NSAttributedString))
            prose = NSMutableAttributedString(string: "")
        }
        func finishParagraph() {
            guard paragraph.length > 0 else { return }
            if code {
                finishProse()
                blocks.append(.code(paragraph.string, language, codeIndent, codeMarker))
            } else {
                prose.append(paragraph)
                var separator = paragraph.attributes(at: paragraph.length - 1, effectiveRange: nil)
                separator.removeValue(forKey: AgentTextLayoutManager.inlineCodeBackground)
                separator.removeValue(forKey: .link)
                separator.removeValue(forKey: .strikethroughStyle)
                prose.append(NSAttributedString(string: "\n", attributes: separator))
            }
            paragraph = NSMutableAttributedString(string: "")
        }
        func finishTable() {
            guard tableIdentity != nil else { return }
            let rows = (0...(tableRows.keys.max() ?? 0)).map { row in
                tableAlignments.indices.map { column -> NSAttributedString in
                    tableRows[row]?[column]?.copy() as? NSAttributedString ?? NSAttributedString(string: "")
                }
            }
            blocks.append(.table(rows, tableAlignments))
            tableIdentity = nil
            tableRows.removeAll()
        }

        for run in parsed.runs {
            let components = run.presentationIntent?.components ?? []
            var tableID: Int?, rowIndex: Int?, columnIndex: Int?
            var alignments: [NSTextAlignment] = []
            for component in components {
                switch component.kind {
                case .table(let columns):
                    tableID = component.identity
                    alignments = columns.map { column in
                        switch column.alignment {
                        case .center: return .center
                        case .right: return .right
                        default: return .left
                        }
                    }
                case .tableHeaderRow: rowIndex = 0
                case .tableRow(let row): rowIndex = row
                case .tableCell(let column): columnIndex = column
                default: break
                }
            }
            if let tableID, let rowIndex, let columnIndex {
                if tableIdentity != tableID {
                    finishParagraph(); finishProse(); finishTable()
                    tableIdentity = tableID
                    tableAlignments = alignments
                    identity = nil
                }
                let style = NSMutableParagraphStyle()
                style.lineHeightMultiple = 1.1
                style.alignment = tableAlignments[columnIndex]
                let attributes = inlineAttributes(run.inlinePresentationIntent, link: run.link, base: [
                    .font: fonts.textFont(weight: rowIndex == 0 ? .semibold : .regular),
                    .foregroundColor: palette.text, .paragraphStyle: style,
                ])
                let cell = tableRows[rowIndex]?[columnIndex] ?? NSMutableAttributedString(string: "")
                cell.append(NSAttributedString(string: String(parsed[run.range].characters), attributes: attributes))
                tableRows[rowIndex, default: [:]][columnIndex] = cell
                continue
            }
            finishTable()
            let nextIdentity = components.first?.identity ?? 0
            let starting = identity != nextIdentity
            if starting { finishParagraph(); identity = nextIdentity }
            var heading: Int?
            var depth = 0
            var ordinal: Int?
            var listItem: Int?
            var ordered = false
            var quoted = false
            code = false
            for component in components {
                switch component.kind {
                case .header(let level): heading = level
                case .codeBlock(let hint): code = true; language = hint ?? ""
                case .listItem(let number): if ordinal == nil { ordinal = number; listItem = component.identity }
                case .orderedList: if depth == 0 { ordered = true }; depth += 1
                case .unorderedList: depth += 1
                case .blockQuote: quoted = true
                default: break
                }
            }
            if code {
                if starting {
                    codeIndent = CGFloat(max(0, depth - 1)) * 20 + (quoted ? 14 : 0) + (depth > 0 ? ordered ? 26 : 18 : 0)
                    codeMarker = nil
                    if let listItem, !seenListItems.contains(listItem) {
                        codeMarker = ordered ? "\(ordinal ?? 1)." : "•"
                        seenListItems.insert(listItem)
                    }
                }
                paragraph.append(NSAttributedString(string: String(parsed[run.range].characters)))
                continue
            }
            if starting { listContinuation = listItem.map { seenListItems.contains($0) } ?? false }
            let style = NSMutableParagraphStyle()
            style.lineHeightMultiple = 1.1
            style.paragraphSpacing = depth > 0 ? 5 : 11
            var font = fonts.textFont()
            if let heading {
                font = fonts.textFont(size: fonts.textSize + (heading == 1 ? 7 : heading == 2 ? 4 : 2), weight: .semibold)
                style.paragraphSpacingBefore = prose.length > 0 ? 15 : 0
                style.paragraphSpacing = 9
            }
            let inset = CGFloat(max(0, depth - 1)) * 20 + (quoted ? 14 : 0)
            style.firstLineHeadIndent = inset
            style.headIndent = inset
            if depth > 0 {
                style.headIndent += ordered ? 26 : 18
                style.tabStops = [NSTextTab(textAlignment: .left, location: style.headIndent)]
                if listContinuation { style.firstLineHeadIndent = style.headIndent }
            }
            var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: quoted ? palette.secondary : palette.text, .paragraphStyle: style]
            if starting, depth > 0, let listItem, !seenListItems.contains(listItem) {
                paragraph.append(NSAttributedString(string: ordered ? "\(ordinal ?? 1).\t" : "•\t", attributes: attributes))
                seenListItems.insert(listItem)
            }
            attributes = inlineAttributes(run.inlinePresentationIntent, link: run.link, base: attributes)
            let content = preserveSoftBreaks && run.inlinePresentationIntent?.contains(.softBreak) == true ? "\n" : String(parsed[run.range].characters)
            paragraph.append(NSAttributedString(string: content, attributes: attributes))
        }
        finishParagraph()
        finishProse()
        finishTable()
        return blocks
    }
}

@MainActor
final class AgentCodeBlockView: NSView {
    private let surface = NSView()
    private let marker = NSTextField(labelWithString: "")
    private let language = NSTextField(labelWithString: "Code")
    private let copyButton = NSButton(title: "Copy", target: nil, action: nil)
    private let scroll = NSScrollView()
    private let text = NSTextView()
    private var height: NSLayoutConstraint!
    private var surfaceLeading: NSLayoutConstraint!
    private var markerLeading: NSLayoutConstraint!
    private var source = ""
    private var naturalSize = NSSize.zero
    private var copyFeedback: DispatchWorkItem?

    override init(frame: NSRect) {
        super.init(frame: frame)
        surface.wantsLayer = true
        surface.layer?.cornerRadius = 9
        setAccessibilityIdentifier("rex-agent.code-block")
        language.font = .systemFont(ofSize: 11, weight: .medium)
        language.lineBreakMode = .byTruncatingTail
        copyButton.isBordered = false
        copyButton.font = .systemFont(ofSize: 11)
        copyButton.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy code")
        copyButton.imagePosition = .imageLeading
        copyButton.target = self
        copyButton.action = #selector(copyClicked)
        copyButton.toolTip = "Copy code"
        copyButton.setAccessibilityIdentifier("rex-agent.code-copy")
        copyButton.setAccessibilityLabel("Copy code")
        copyButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        let header = NSStackView(views: [language, NSView(), copyButton])
        header.spacing = 8
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = false
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        text.isEditable = false
        text.isSelectable = true
        text.drawsBackground = false
        text.textContainerInset = .zero
        text.textContainer?.lineFragmentPadding = 0
        text.isHorizontallyResizable = true
        text.isVerticallyResizable = true
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.textContainer?.widthTracksTextView = false
        text.textContainer?.containerSize = text.maxSize
        text.setAccessibilityIdentifier("rex-agent.code-text")
        scroll.documentView = text
        for view in [surface, marker] { view.translatesAutoresizingMaskIntoConstraints = false; addSubview(view) }
        for view in [header, scroll] { view.translatesAutoresizingMaskIntoConstraints = false; surface.addSubview(view) }
        height = scroll.heightAnchor.constraint(equalToConstant: 20)
        surfaceLeading = surface.leadingAnchor.constraint(equalTo: leadingAnchor)
        markerLeading = marker.leadingAnchor.constraint(equalTo: leadingAnchor)
        NSLayoutConstraint.activate([
            surface.topAnchor.constraint(equalTo: topAnchor),
            surface.bottomAnchor.constraint(equalTo: bottomAnchor),
            surface.trailingAnchor.constraint(equalTo: trailingAnchor),
            surfaceLeading, markerLeading,
            marker.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            header.topAnchor.constraint(equalTo: surface.topAnchor, constant: 7),
            header.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: 13),
            header.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -9),
            copyButton.widthAnchor.constraint(equalToConstant: 66),
            copyButton.heightAnchor.constraint(equalToConstant: 26),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 5),
            scroll.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: 13),
            scroll.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -13),
            scroll.bottomAnchor.constraint(equalTo: surface.bottomAnchor, constant: -13),
            height,
        ])
    }
    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { nil }

    func update(text value: String, language hint: String, palette: AgentPalette, indent: CGFloat = 0, marker listMarker: String? = nil) {
        source = value
        surfaceLeading.constant = indent
        markerLeading.constant = max(0, indent - (listMarker == "•" ? 18 : 26))
        marker.stringValue = listMarker ?? ""
        marker.isHidden = listMarker == nil
        marker.font = AgentAppearance.shared.settings.textFont()
        marker.textColor = palette.text
        language.stringValue = hint.isEmpty ? "Code" : hint
        language.textColor = palette.secondary
        copyButton.contentTintColor = palette.secondary
        surface.layer?.backgroundColor = palette.surface.cgColor
        text.selectedTextAttributes = [.backgroundColor: palette.selection, .foregroundColor: palette.selectedText]
        let font = AgentAppearance.shared.settings.codeFont()
        let display = value.hasSuffix("\n") ? String(value.dropLast()) : value
        let content = NSAttributedString(string: display, attributes: [.font: font, .foregroundColor: palette.text])
        if text.textStorage?.isEqual(to: content) != true {
            let selection = text.selectedRange()
            text.textStorage?.setAttributedString(content)
            if NSMaxRange(selection) <= content.length { text.setSelectedRange(selection) }
            if let container = text.textContainer, let manager = text.layoutManager {
                manager.ensureLayout(for: container)
                naturalSize = manager.usedRect(for: container).size
            }
            height.constant = max(ceil(font.ascender - font.descender), ceil(naturalSize.height)) + 4
            needsLayout = true
        }
    }

    override func layout() {
        super.layout()
        text.setFrameSize(NSSize(width: max(scroll.contentSize.width, ceil(naturalSize.width) + 1), height: height.constant))
    }

    func copyCode(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        pasteboard.setString(source, forType: .string)
    }

    @objc private func copyClicked() {
        copyCode(to: .general)
        copyFeedback?.cancel()
        copyButton.title = "Copied"
        copyButton.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: "Copied")
        let feedback = DispatchWorkItem { [weak self] in
            self?.copyButton.title = "Copy"
            self?.copyButton.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy code")
        }
        copyFeedback = feedback
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: feedback)
    }
}
