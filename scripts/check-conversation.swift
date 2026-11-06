import AppKit

@MainActor
final class AgentBridge {
    static var current: AgentBridge!
    var onEvent: (([String: Any]) -> Void)?
    func start(projectRoot: String, provider: String, cwd: String, paneKey: String? = nil) {
        Self.current = self
        onEvent?(["type": "conversation", "provider": provider, "cwd": cwd, "messages": []])
        onEvent?(["type": "ready", "provider": provider])
    }
    func send(_ message: [String: Any]) {}
    func close() {}
}

@main
@MainActor
struct ConversationCheck {
    static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let pane = AgentPaneView(projectRoot: FileManager.default.currentDirectoryPath, sessionID: "session:test", blockID: "block:test", cwd: "/tmp")
        pane.frame = NSRect(x: 0, y: 0, width: 700, height: 900)
        do {
            let prompt = descendants(pane).compactMap { $0 as? NSTextView }.first { $0.isEditable }!
            let send = descendants(pane).compactMap { $0 as? NSButton }.first { $0.title == "Send" }!
            prompt.string = "Run a command, then explain its output."
            send.performClick(nil)
            let bridge = AgentBridge.current!
            bridge.onEvent?(["type": "delta", "text": "Before the command."])
            bridge.onEvent?(["type": "activity", "id": "tool:1", "title": "printf result", "detail": "printf result", "status": "running"])
            flush(pane)
            try require(descendants(pane).compactMap { $0 as? NSTextField }.contains { $0.stringValue.contains("printf result") }, "running command is missing before the turn completes")
            bridge.onEvent?(["type": "delta", "text": "After the command."])
            bridge.onEvent?(["type": "activity", "id": "tool:1", "title": "printf result", "detail": "result", "status": "completed"])
            bridge.onEvent?(["type": "done", "status": "completed"])
            flush(pane)
            let visible = descendants(pane).compactMap { view -> String? in
                if let text = view as? NSTextView, !text.isEditable { return text.string }
                if let label = view as? NSTextField { return label.stringValue }
                return nil
            }
            guard let before = visible.firstIndex(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines) == "Before the command." }),
                  let command = visible.firstIndex(where: { $0.contains("printf result") }),
                  let after = visible.firstIndex(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines) == "After the command." }) else {
                throw NSError(domain: "ConversationCheck", code: 1, userInfo: [NSLocalizedDescriptionKey: "assistant text was merged across tool activity"])
            }
            try require(before < command && command < after, "command is not between the preceding and following prose")
            try require(visible.filter { $0.contains("printf result") }.count == 1, "tool completion duplicated or moved the command")
            print("PASS running command appears immediately; text and tools remain chronological; completion updates in place")

            let root = CommandLine.arguments[1]
            let rex = root + "/rex", shell = root + "/shell", capture = root + "/argv"
            try "#!/bin/sh\nprintf '%s\\000' \"$@\" > \"$REX_AGENT_LINK_CAPTURE\"\nprintf '{\"block_ids\":[\"block:editor\"]}\\n'\n".write(toFile: rex, atomically: true, encoding: .utf8)
            try "#!/bin/sh\nprintf '\\036REX_AGENT_EDITOR\\037nvim -u NONE\\036'\n".write(toFile: shell, atomically: true, encoding: .utf8)
            for path in [rex, shell] { try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path) }
            setenv("REX_AGENT_CLI", rex, 1)
            setenv("REX_AGENT_LINK_CAPTURE", capture, 1)
            setenv("SHELL", shell, 1)
            bridge.onEvent?(["type": "conversation", "provider": "codex", "cwd": "/tmp", "messages": [["role": "assistant", "text": "Open [source](native/AgentPane.swift#L12)."]]])
            flush(pane)
            let linkedText = descendants(pane).compactMap { $0 as? NSTextView }.first { $0.string.contains("Open source") }!
            var fileLink: Any?
            linkedText.textStorage?.enumerateAttribute(.link, in: NSRange(location: 0, length: linkedText.textStorage!.length)) { value, _, _ in
                if let value { fileLink = value }
            }
            try require(fileLink != nil, "Markdown file link was not rendered")
            try require(linkedText.delegate?.textView?(linkedText, clickedOnLink: fileLink!, at: 5) == true, "file link was not intercepted by the native pane")
            let deadline = Date().addingTimeInterval(3)
            while !FileManager.default.fileExists(atPath: capture) && Date() < deadline { flush(pane) }
            let arguments = try Data(contentsOf: URL(fileURLWithPath: capture)).split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
            try require(arguments.contains("block:test") && arguments.suffix(6) == ["nvim", "-u", "NONE", "+12", "--", "/tmp/native/AgentPane.swift"], "file click did not open the selected line beside its agent pane")
            try require(linkedText.delegate?.textView?(linkedText, clickedOnLink: URL(string: "https://example.com")!, at: 0) == false, "web links lost ordinary browser handling")
            print("PASS rendered file link opens the editor beside its agent pane; web links retain browser handling")
            let appearance = AgentAppearance.shared
            let original = appearance.settings
            func restoreFonts() {
                if original == AgentFontSettings() { appearance.reset() }
                else { appearance.update(original) }
            }
            defer { restoreFonts() }
            bridge.onEvent?(["type": "conversation", "provider": "codex", "cwd": "/tmp", "messages": [["role": "assistant", "text": "Font sample with **bold** and `inline_code`.\n```swift\nlet code_sample = true\n```"]]])
            var fonts = original
            fonts.textFamily = "Georgia"
            fonts.textSize = 19
            fonts.codeFamily = "Menlo"
            fonts.codeSize = 17
            appearance.update(fonts)
            flush(pane)
            try require(prompt.font?.pointSize == 19 && prompt.font?.familyName == "Georgia", "composer did not adopt the selected conversation font")
            let rendered = descendants(pane).compactMap { $0 as? NSTextView }.first { $0.string.contains("Font sample") }!
            let bodyFont = rendered.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
            let codeText = descendants(pane).compactMap { $0 as? NSTextView }.first { $0.string.contains("code_sample") }!
            let codeFont = codeText.textStorage?.attribute(.font, at: (codeText.string as NSString).range(of: "code_sample").location, effectiveRange: nil) as? NSFont
            try require(bodyFont?.pointSize == 19 && bodyFont?.familyName == "Georgia", "existing prose did not update its font")
            try require(codeFont?.pointSize == 17 && codeFont?.familyName == "Menlo", "existing code did not use the separate code font")
            restoreFonts()
            print("PASS existing conversation, composer, and code update their separate fonts immediately")
            bridge.onEvent?(["type": "conversation", "provider": "codex", "cwd": "/tmp", "messages": [["role": "assistant", "text": "## Layout\n\nA paragraph\ncontinued on a soft break.\n\n- Parent item\n  - Nested item with enough text to wrap cleanly.\n\n1. Ordered item\n\n```swift\nlet sample = true\n```"]]])
            flush(pane)
            let prose = descendants(pane).compactMap { $0 as? NSTextView }.first { $0.string.contains("Layout") }!
            try require(!prose.string.contains("\n\n"), "Markdown blank lines still create empty font-height paragraphs")
            try require(prose.string.contains("A paragraph continued on a soft break."), "Markdown soft breaks were not joined into a paragraph")
            let proseString = prose.string as NSString
            let parentIndent = (prose.textStorage?.attribute(.paragraphStyle, at: proseString.range(of: "Parent item").location, effectiveRange: nil) as? NSParagraphStyle)?.headIndent ?? 0
            let childIndent = (prose.textStorage?.attribute(.paragraphStyle, at: proseString.range(of: "Nested item").location, effectiveRange: nil) as? NSParagraphStyle)?.headIndent ?? 0
            try require(childIndent > parentIndent, "nested list items have no hanging indent")
            try require(descendants(pane).contains { $0.accessibilityIdentifier() == "rex-agent.code-copy" }, "fenced code has no native Copy control")
            print("PASS Markdown paragraph rhythm, soft breaks, nested lists, and code block controls")
            let longCode = "let message = \"" + String(repeating: "a long unwrapped value ", count: 12) + "\"\n"
            bridge.onEvent?(["type": "conversation", "provider": "codex", "cwd": "/tmp", "messages": [["role": "user", "text": "First line\nSecond line"], ["role": "assistant", "text": "- First item\n\n  Continued with **emphasis**.\n\n```swift\n" + longCode + "```\n\n1. ```sh\n   echo listed\n   ```\n\n   Following the listed code."]]])
            flush(pane)
            let userText = descendants(pane).compactMap { $0 as? NSTextView }.first { $0.string.contains("First line") }!
            try require(userText.string.contains("First line\nSecond line"), "user-entered line breaks were lost")
            let listText = descendants(pane).compactMap { $0 as? NSTextView }.first { $0.string.contains("Continued with") }!
            try require(listText.string.filter { $0 == "•" }.count == 1, "loose list continuation received another bullet")
            let codeBlock = descendants(pane).compactMap { $0 as? AgentCodeBlockView }.first!
            let codeView = descendants(codeBlock).compactMap { $0 as? NSTextView }.first!
            try require(codeView.bounds.width > codeView.enclosingScrollView!.contentSize.width + 100, "long code wraps instead of scrolling horizontally")
            let clipboard = NSPasteboard.withUniqueName()
            defer { clipboard.releaseGlobally() }
            codeBlock.copyCode(to: clipboard)
            try require(clipboard.string(forType: .string) == longCode, "code Copy did not preserve raw fenced content")
            let listedCode = descendants(pane).compactMap { $0 as? AgentCodeBlockView }.last!
            try require(descendants(listedCode).compactMap { $0 as? NSTextField }.contains { $0.stringValue == "1." }, "a list item starting with code lost its marker")
            let continuation = descendants(pane).compactMap { $0 as? NSTextView }.first { $0.string.contains("Following the listed code") }!
            try require(!continuation.string.contains("1."), "a list marker moved from code to its continuation")
            print("PASS user line breaks, loose lists, unwrapped code, and exact code Copy")
            bridge.onEvent?(["type": "conversation", "provider": "codex", "cwd": "/tmp", "messages": [["role": "assistant", "text": "Before the table.\n\n| Name | Count | Detail |\n| :--- | ---: | :---: |\n| **alpha** | 1 | [Open](file:///tmp/table.swift) |\n| beta | 2 | `x\\|y` |\n| | 3 | |\n\nAfter the table."]]])
            flush(pane)
            let tables = descendants(pane).compactMap { $0 as? AgentTableView }
            try require(tables.count == 1 && !descendants(pane).contains { $0 is AgentCodeBlockView }, "Markdown table still renders as code")
            let cells = descendants(tables[0]).compactMap { $0 as? NSTextView }
            try require(cells.count == 12 && cells.filter { $0.string.isEmpty }.count == 2, "table lost empty cells or row boundaries")
            let alpha = cells.first { $0.string == "alpha" }!
            let number = cells.first { $0.string == "1" }!
            let link = cells.first { $0.string == "Open" }!
            let inline = cells.first { $0.string == "x|y" }!
            try require((alpha.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont).map { NSFontManager.shared.traits(of: $0).contains(.boldFontMask) } == true, "table lost bold text")
            try require((number.textStorage?.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)?.alignment == .right, "table lost numeric column alignment")
            try require((link.textStorage?.attribute(.link, at: 0, effectiveRange: nil) as? URL)?.path == "/tmp/table.swift", "table lost a file link")
            try require(inline.textStorage?.attribute(AgentTextLayoutManager.inlineCodeBackground, at: 0, effectiveRange: nil) != nil, "table lost inline-code styling")
            let paragraphs = descendants(pane).compactMap { $0 as? NSTextView }.map(\.string)
            try require(paragraphs.contains("Before the table.") && paragraphs.contains("After the table."), "table displaced neighboring paragraphs")
            print("PASS native Markdown tables preserve rich cells, alignment, empty cells, and surrounding prose")

            let commandOutput = "Set effort level to xhigh (saved as your default for new sessions): Deeper reasoning than high, just below maximum (on supported models)"
            let localCommand: [String: Any] = ["role": "command", "text": "/effort xhigh\n\n" + commandOutput,
                "command": ["name": "/effort", "args": "xhigh", "output": commandOutput]]
            bridge.onEvent?(["type": "conversation", "provider": "claude", "cwd": "/tmp", "messages": [localCommand,
                ["role": "user", "text": "Compare the available settings."],
                ["role": "assistant", "text": "| Setting | Meaning |\n| --- | --- |\n| `high` | More reasoning for difficult tasks. |\n| **xhigh** | Deeper reasoning than high, just below maximum. |"]]])
            flush(pane)
            let commands = descendants(pane).filter { $0.accessibilityIdentifier() == "rex-agent.local-command" }
            try require(commands.count == 1, "history did not create a local command card")
            let invocation = descendants(commands[0]).compactMap { $0 as? NSTextView }.first { $0.accessibilityIdentifier() == "rex-agent.command-invocation" }!
            try require(invocation.string == "/effort xhigh", "command card lost its invocation")
            try require(descendants(commands[0]).compactMap { $0 as? NSTextView }.contains { $0.string == commandOutput }, "command card lost its output")
            for width: CGFloat in [340, 700] {
                pane.setFrameSize(NSSize(width: width, height: 1100))
                for appearanceName in [NSAppearance.Name.darkAqua, .aqua] {
                    pane.appearance = NSAppearance(named: appearanceName)
                    NotificationCenter.default.post(name: AgentAppearance.didChangeNotification, object: AgentAppearance.shared)
                    flush(pane)
                    try require(commands[0].bounds.height > 60 && commands[0].bounds.width <= pane.bounds.width, "command card does not fit the pane")
                    if let directory = ProcessInfo.processInfo.environment["REX_AGENT_RICH_PREVIEW_DIR"] {
                        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
                        if let bitmap = pane.bitmapImageRepForCachingDisplay(in: pane.bounds) {
                            pane.cacheDisplay(in: pane.bounds, to: bitmap)
                            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(directory)/\(appearanceName.rawValue)-\(Int(width)).png"))
                        }
                    }
                }
            }
            pane.setFrameSize(NSSize(width: 700, height: 900))
            print("PASS native local-command history cards, output, and narrow/light/dark layouts")

            let previous = Array(repeating: "An earlier paragraph that remains available while the agent works.", count: 60).joined(separator: "\n\n")
            bridge.onEvent?(["type": "conversation", "provider": "codex", "cwd": "/tmp", "messages": [["role": "assistant", "text": previous]]])
            prompt.string = "Continue."
            send.performClick(nil)
            bridge.onEvent?(["type": "delta", "text": "Current response."])
            flush(pane)
            let currentText = descendants(pane).compactMap { $0 as? NSTextView }.first { $0.string == "Current response." }!
            currentText.setSelectedRange(NSRange(location: 0, length: 7))
            bridge.onEvent?(["type": "delta", "text": " More detail."])
            flush(pane)
            try require(currentText.selectedRange() == NSRange(location: 0, length: 7), "streaming replaced the native text selection")
            bridge.onEvent?(["type": "activity", "id": "scroll:tool", "title": "Read files", "detail": "Reading", "status": "running"])
            bridge.onEvent?(["type": "delta", "text": "After reading the files."])
            flush(pane)
            let transcript = descendants(pane).first { $0.accessibilityIdentifier() == "rex-agent.transcript" }!
            let transcriptScroll = transcript.enclosingScrollView!
            let clip = transcriptScroll.contentView
            try require(transcriptScroll.documentView!.bounds.height - clip.bounds.maxY < 3, "following the stream stopped at a tool-to-text transition")
            clip.scroll(to: NSPoint(x: 0, y: 40))
            transcriptScroll.reflectScrolledClipView(clip)
            bridge.onEvent?(["type": "delta", "text": " More streamed text."])
            bridge.onEvent?(["type": "approval", "requestId": "scroll:approval", "title": "Run check", "detail": "A fixture approval"])
            flush(pane)
            try require(abs(clip.bounds.minY - 40) < 2, "streaming or approval pulled the reader away from earlier content")
            bridge.onEvent?(["type": "done", "status": "completed"])
            print("PASS native selection and reading position survive streaming, tools, and approvals")
            for settings in [AgentFontSettings(), AgentFontSettings(textFamily: "Open Sans", textSize: 14, codeFamily: "IoskeleyMonoNL Nerd Font Mono", codeSize: 12.5)] {
                appearance.update(settings)
                bridge.onEvent?(["type": "conversation", "provider": "codex", "cwd": "/tmp", "messages": [["role": "assistant", "text": "## `native/`: the Swift/AppKit side\n\n`scripts/`\n\n- `Loader.m`: Constructor.\n- `Injection.swift`: Host.\n\nWrapped `alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu nu xi omicron pi rho sigma tau` stays readable.\n\n```swift\nlet code_sample = true\n```"]]])
                flush(pane)
                let codeText = descendants(pane).compactMap { $0 as? NSTextView }.first { $0.string.contains("native/") }!
                try checkInlineCodeBackground(codeText)
            }
            print("PASS inline-code backgrounds fit the code font in headings, lists, and wrapped text, including custom fonts")
            return
        } catch {
            fputs("FAIL: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
    static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    static func checkInlineCodeBackground(_ view: NSTextView) throws {
        let manager = view.layoutManager!, container = view.textContainer!, storage = view.textStorage!
        view.setFrameSize(NSSize(width: 450, height: 600))
        container.containerSize = NSSize(width: 450, height: CGFloat.greatestFiniteMagnitude)
        manager.ensureLayout(for: container)
        let size = NSSize(width: 450, height: ceil(manager.usedRect(for: container).height))
        let image = NSImage(size: size, flipped: true) { _ in
            manager.drawBackground(forGlyphRange: manager.glyphRange(for: container), at: .zero)
            return true
        }
        let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
        let scaleX = CGFloat(bitmap.pixelsWide) / size.width, scaleY = CGFloat(bitmap.pixelsHigh) / size.height
        if let path = ProcessInfo.processInfo.environment["REX_AGENT_CONVERSATION_PREVIEW"] {
            let preview = NSImage(size: size, flipped: true) { rect in
                AgentTheme.palette(for: view).background.setFill()
                rect.fill()
                manager.drawBackground(forGlyphRange: manager.glyphRange(for: container), at: .zero)
                manager.drawGlyphs(forGlyphRange: manager.glyphRange(for: container), at: .zero)
                return true
            }
            let png = NSBitmapImageRep(data: preview.tiffRepresentation!)!.representation(using: .png, properties: [:])!
            try png.write(to: URL(fileURLWithPath: path))
        }
        for token in ["native/", "scripts/", "Loader.m", "Injection.swift", "alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu nu xi omicron pi rho sigma tau"] {
            let characters = (storage.string as NSString).range(of: token)
            let glyphs = manager.glyphRange(forCharacterRange: characters, actualCharacterRange: nil)
            let font = storage.attribute(.font, at: characters.location, effectiveRange: nil) as! NSFont
            var lines: [(NSRect, NSRange)] = []
            manager.enumerateLineFragments(forGlyphRange: glyphs) { line, _, _, range, _ in lines.append((line, NSIntersectionRange(glyphs, range))) }
            if token.hasPrefix("alpha") { try require(lines.count > 1, "inline-code fixture did not wrap") }
            for (line, segment) in lines {
                let bounds = manager.boundingRect(forGlyphRange: segment, in: container)
                let baseline = line.minY + manager.location(forGlyphAt: segment.location).y
                let x = min(bitmap.pixelsWide - 1, Int(bounds.midX * scaleX))
                func painted(_ y: Int) -> Bool { (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 }
                var first = Int((baseline - font.xHeight / 2) * scaleY), last = first
                try require(first >= 0 && first < bitmap.pixelsHigh && painted(first), "inline code lost its background")
                while first > 0 && painted(first - 1) { first -= 1 }
                while last + 1 < bitmap.pixelsHigh && painted(last + 1) { last += 1 }
                let height = CGFloat(last - first + 1) / scaleY
                try require(height <= ceil(font.ascender - font.descender) + 3, "inline-code background includes paragraph spacing: \(height)pt for \(token)")
                try require(abs(CGFloat(first) / scaleY - (baseline - font.ascender - 1)) < 1.5, "inline-code background is not aligned to its text baseline for \(token)")
                if token == "scripts/" {
                    let afterCode = Int((bounds.maxX + 8) * scaleX)
                    let centerY = Int((baseline - font.xHeight / 2) * scaleY)
                    try require((bitmap.colorAt(x: afterCode, y: centerY)?.alphaComponent ?? 0) < 0.1, "standalone inline-code highlight extends through the paragraph separator")
                }
            }
        }
    }
    static func flush(_ pane: NSView) {
        RunLoop.main.run(until: Date().addingTimeInterval(0.08))
        pane.layoutSubtreeIfNeeded()
    }
    static func require(_ value: Bool, _ message: String) throws {
        if !value { throw NSError(domain: "ConversationCheck", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
}
