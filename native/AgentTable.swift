import AppKit

@MainActor
final class AgentTableView: NSView {
    var onLink: ((Any) -> Bool)?
    private let scroll = NSScrollView()
    private let canvas = AgentTableCanvas()
    private var cells: [[GrowingTextView]] = []
    private var preferredWidths: [CGFloat] = []
    private var minimumWidths: [CGFloat] = []
    private let horizontalPadding: CGFloat = 12
    private let verticalPadding: CGFloat = 9

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityIdentifier("rex-agent.table")
        setAccessibilityLabel("Table")
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        layer?.masksToBounds = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = false
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.horizontalScrollElasticity = .none
        scroll.verticalScrollElasticity = .none
        scroll.documentView = canvas
        addSubview(scroll)
        setContentHuggingPriority(.defaultHigh, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .vertical)
    }
    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { nil }

    func update(rows: [[NSAttributedString]], alignments: [NSTextAlignment], palette: AgentPalette) {
        let columns = max(rows.map(\.count).max() ?? 0, alignments.count)
        while cells.count > rows.count { cells.removeLast().forEach { $0.removeFromSuperview() } }
        while cells.count < rows.count { cells.append([]) }
        let minimumWidth = max(72, AgentAppearance.shared.settings.textSize * 4.5) + horizontalPadding * 2
        minimumWidths = Array(repeating: minimumWidth, count: columns)
        preferredWidths = Array(repeating: minimumWidth, count: columns)
        for row in rows.indices {
            while cells[row].count > columns { cells[row].removeLast().removeFromSuperview() }
            while cells[row].count < columns {
                let cell = GrowingTextView()
                cell.setAccessibilityIdentifier("rex-agent.table-cell")
                cell.onLink = { [weak self] in self?.onLink?($0) ?? false }
                canvas.addSubview(cell)
                cells[row].append(cell)
            }
            for column in 0..<columns {
                let content = NSMutableAttributedString(attributedString: rows[row].indices.contains(column) ? rows[row][column] : NSAttributedString(string: ""))
                let range = NSRange(location: 0, length: content.length)
                content.enumerateAttribute(.paragraphStyle, in: range) { value, span, _ in
                    let style = (value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
                    style.alignment = alignments.indices.contains(column) ? alignments[column] : .left
                    style.paragraphSpacing = 0
                    style.paragraphSpacingBefore = 0
                    content.addAttribute(.paragraphStyle, value: style, range: span)
                }
                let cell = cells[row][column]
                cell.setContent(content)
                cell.selectedTextAttributes = [.backgroundColor: palette.selection, .foregroundColor: palette.selectedText]
                cell.linkTextAttributes = [.foregroundColor: palette.accent]
                cell.setAccessibilityLabel("\(row == 0 ? "Header" : "Row \(row)"), column \(column + 1)")
                let width = content.boundingRect(with: NSSize(width: 10_000, height: CGFloat.greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading]).width
                preferredWidths[column] = max(preferredWidths[column], min(360, ceil(width) + horizontalPadding * 2))
                let string = content.string
                string.enumerateSubstrings(in: string.startIndex..<string.endIndex, options: .byWords) { [self] _, range, _, _ in
                    let word = content.attributedSubstring(from: NSRange(range, in: string))
                    minimumWidths[column] = max(minimumWidths[column], min(144, ceil(word.size().width) + horizontalPadding * 2))
                }
                preferredWidths[column] = max(preferredWidths[column], minimumWidths[column])
            }
        }
        canvas.palette = palette
        layer?.backgroundColor = palette.background.cgColor
        layer?.borderColor = palette.border.cgColor
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    private func widths(for available: CGFloat) -> [CGFloat] {
        let minimum = minimumWidths.reduce(0, +)
        let desired = preferredWidths.reduce(0, +)
        let total = max(available, minimum)
        if total >= desired {
            return preferredWidths.map { $0 + (total - desired) / CGFloat(max(1, preferredWidths.count)) }
        }
        let proportion = (total - minimum) / max(1, desired - minimum)
        return preferredWidths.enumerated().map { minimumWidths[$0.offset] + ($0.element - minimumWidths[$0.offset]) * proportion }
    }

    @discardableResult
    private func arrangeCells(width: CGFloat) -> CGFloat {
        guard !cells.isEmpty, !preferredWidths.isEmpty else { return 0 }
        let widths = widths(for: max(1, width))
        var top: CGFloat = 0
        var edges: [CGFloat] = []
        for (index, row) in cells.enumerated() {
            var rowHeight: CGFloat = 20
            for (column, cell) in row.enumerated() {
                cell.setFrameSize(NSSize(width: max(1, widths[column] - horizontalPadding * 2), height: cell.frame.height))
                rowHeight = max(rowHeight, cell.intrinsicContentSize.height)
            }
            rowHeight += verticalPadding * 2
            var left: CGFloat = 0
            for (column, cell) in row.enumerated() {
                cell.frame = NSRect(x: left + horizontalPadding, y: top + verticalPadding,
                                    width: max(1, widths[column] - horizontalPadding * 2), height: rowHeight - verticalPadding * 2)
                left += widths[column]
            }
            top += rowHeight
            edges.append(top)
            if index == 0 { canvas.headerHeight = rowHeight }
        }
        let documentWidth = widths.reduce(0, +)
        // Leave room below the last row for the overlay scroller when overflowing.
        let height = ceil(top + (documentWidth > width + 0.5 ? 8 : 0))
        canvas.rowEdges = Array(edges.dropLast())
        canvas.columnEdges = widths.dropLast().reduce(into: [CGFloat]()) { $0.append(($0.last ?? 0) + $1) }
        canvas.setFrameSize(NSSize(width: documentWidth, height: height))
        canvas.needsDisplay = true
        return height
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: arrangeCells(width: bounds.width > 0 ? bounds.width : 600))
    }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = abs(bounds.width - newSize.width) > 0.5
        super.setFrameSize(newSize)
        if changed { invalidateIntrinsicContentSize(); needsLayout = true }
    }

    override func layout() {
        super.layout()
        scroll.frame = bounds
        arrangeCells(width: scroll.contentSize.width)
    }
}

@MainActor
private final class AgentTableCanvas: NSView {
    override var isFlipped: Bool { true }
    var palette: AgentPalette?
    var headerHeight: CGFloat = 0
    var rowEdges: [CGFloat] = []
    var columnEdges: [CGFloat] = []

    override func draw(_ dirtyRect: NSRect) {
        guard let palette else { return }
        palette.background.setFill()
        bounds.fill()
        palette.surface.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: headerHeight).fill()
        palette.border.setStroke()
        let rules = NSBezierPath()
        rules.lineWidth = 0.5
        for y in rowEdges { rules.move(to: NSPoint(x: 0, y: y)); rules.line(to: NSPoint(x: bounds.width, y: y)) }
        for x in columnEdges { rules.move(to: NSPoint(x: x, y: 0)); rules.line(to: NSPoint(x: x, y: bounds.height)) }
        rules.stroke()
    }
}
