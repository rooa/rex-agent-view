import AppKit

@MainActor
final class AgentBridge {
    var onEvent: (([String: Any]) -> Void)?
    func start(projectRoot: String, provider: String, cwd: String, paneKey: String? = nil) {}
    func send(_ message: [String: Any]) {}
    func close() {}
}

@main
@MainActor
struct TableCheck {
    static func main() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let table = AgentTableView()
        table.appearance = NSAppearance(named: .darkAqua)
        let palette = AgentTheme.palette(for: table)
        func content(_ text: String, header: Bool = false, size: CGFloat = 15) -> NSAttributedString {
            NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: size, weight: header ? .semibold : .regular), .foregroundColor: palette.text])
        }
        let link = NSMutableAttributedString(attributedString: content("Open source"))
        link.addAttribute(.link, value: URL(string: "file:///tmp/README.md")!, range: NSRange(location: 0, length: link.length))
        let rows = [
            [content("Setting", header: true), content("Description", header: true), content("Value", header: true)],
            [content("Effort"), content("More reasoning for difficult questions, while keeping every line readable in a narrow pane."), content("xhigh")],
            [content("Repository"), link, content("14")],
        ]
        table.update(rows: rows, alignments: [.left, .left, .right], palette: palette)
        func layout(_ width: CGFloat) {
            table.setFrameSize(NSSize(width: width, height: 1))
            table.setFrameSize(NSSize(width: width, height: table.intrinsicContentSize.height))
            table.layoutSubtreeIfNeeded()
        }
        layout(700)
        let wideHeight = table.bounds.height
        let scroll = table.subviews.first as! NSScrollView
        let cells = scroll.documentView!.subviews.compactMap { $0 as? GrowingTextView }
        require(cells.count == 9, "missing cells")
        require(cells[0].frame.minY == cells[2].frame.minY && cells[3].frame.minY == cells[5].frame.minY, "cells do not share row positions")
        require(cells[0].frame.width == cells[3].frame.width && cells[3].frame.width == cells[6].frame.width, "column widths differ across rows")
        require(cells[7].textStorage?.attribute(.link, at: 0, effectiveRange: nil) != nil, "cell links were removed")
        require((cells[5].textStorage?.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)?.alignment == .right, "column alignment was not applied")
        require(scroll.documentView!.bounds.width <= scroll.contentSize.width + 1, "normal-width table unnecessarily overflows")
        cells[4].setSelectedRange(NSRange(location: 0, length: 4))
        table.update(rows: rows, alignments: [.left, .left, .right], palette: palette)
        require(scroll.documentView!.subviews[4] === cells[4] && cells[4].selectedRange().length == 4, "updating the table replaced cells or selection")
        var clicked: Any?
        table.onLink = { clicked = $0; return true }
        _ = cells[7].textView(cells[7], clickedOnLink: URL(string: "file:///tmp/README.md")!, at: 0)
        require(clicked != nil, "cell links do not reach the table callback")
        layout(340)
        require(table.bounds.height > wideHeight, "narrower columns did not wrap")
        require(scroll.documentView!.bounds.width <= scroll.contentSize.width + 1, "three ordinary columns should fit a narrow pane")
        print("PASS aligned selectable cells, wrapping, links, and stable updates")

        let many = (0..<6).map { content("Column \($0)", header: true) }
        table.update(rows: [many, many], alignments: [], palette: palette)
        layout(340)
        require(scroll.documentView!.bounds.width > scroll.contentSize.width + 100, "wide table should scroll horizontally")
        require(scroll.hasHorizontalScroller && !scroll.hasVerticalScroller, "table scroll axes are incorrect")
        print("PASS horizontal overflow for wide tables")

        table.appearance = NSAppearance(named: .aqua)
        let light = AgentTheme.palette(for: table)
        let larger = rows.map { $0.map { content($0.string, size: 28) } }
        table.update(rows: larger, alignments: [], palette: light)
        layout(700)
        require(table.bounds.height > wideHeight, "larger fonts did not increase row height")
        require(table.layer?.borderColor == light.border.cgColor, "theme update did not recolor the table")
        print("PASS updated fonts and light theme")
    }

    static func require(_ passed: Bool, _ message: String) {
        if !passed { fputs("FAIL: \(message)\n", stderr); exit(1) }
    }

}
