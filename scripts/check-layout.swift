import AppKit

@MainActor
final class AgentBridge {
    static var current: AgentBridge!
    var onEvent: (([String: Any]) -> Void)?
    var sent: [[String: Any]] = []
    private var provider = "codex"
    func start(projectRoot: String, provider: String, cwd: String, paneKey: String? = nil) {
        Self.current = self
        activate(provider)
    }
    private func activate(_ value: String) {
        provider = value
        onEvent?(["type": "conversation", "provider": provider, "cwd": "/Projects/rex-agent-view", "resolvedModel": "gpt-6.1-sol", "resolvedEffort": "medium", "messages": []])
        onEvent?(["type": "catalog", "models": [["id": "gpt-6.1-sol", "label": "GPT-6.1 Sol", "isDefault": true, "efforts": ["low", "medium", "high"], "defaultEffort": "medium"]], "skills": [["name": "review", "description": "Review the current changes", "insertText": provider == "codex" ? "$review " : "/review "]]])
        onEvent?(["type": "ready", "provider": provider])
    }
    func send(_ message: [String: Any]) {
        sent.append(message)
        if message["type"] as? String == "new" { activate(message["provider"] as? String ?? provider) }
        if message["type"] as? String == "configure" { onEvent?(message.merging(["type": "configured"]) { _, new in new }) }
    }
    func close() {}
}

@main
@MainActor
struct LayoutCheck {
    static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let defaults = UserDefaults.standard
        let oldFonts = defaults.object(forKey: "RexAgent.Appearance.Fonts")
        defer {
            if let oldFonts { defaults.set(oldFonts, forKey: "RexAgent.Appearance.Fonts") }
            else { defaults.removeObject(forKey: "RexAgent.Appearance.Fonts") }
        }
        let families = NSFontManager.shared.availableFontFamilies
        let fonts = AgentFontSettings(textFamily: families.contains("Open Sans") ? "Open Sans" : nil, textSize: 14,
                                      codeFamily: families.contains("IoskeleyMonoNL Nerd Font Mono") ? "IoskeleyMonoNL Nerd Font Mono" : nil, codeSize: 12.5)
        func color(_ r: Double, _ g: Double, _ b: Double) -> [String: Double] { ["red": r, "green": g, "blue": b, "alpha": 1] }
        let themes: [[String: Any]] = [
            ["id": "layout-dark", "palette": ["background": color(0.12, 0.115, 0.105), "foreground": color(0.91, 0.895, 0.86), "cursor": color(0.88, 0.68, 0.45)]],
            ["id": "layout-light", "palette": ["background": color(0.97, 0.96, 0.94), "foreground": color(0.18, 0.17, 0.15), "cursor": color(0.36, 0.45, 0.30)]],
        ]
        defaults.setVolatileDomain(["Workspace.darkThemeID": "layout-dark", "Workspace.lightThemeID": "layout-light", "Workspace.customThemes": try! JSONSerialization.data(withJSONObject: themes)], forName: UserDefaults.argumentDomain)
        AgentAppearance.shared.update(fonts)
        let pane = AgentPaneView(projectRoot: FileManager.default.currentDirectoryPath, sessionID: "layout:test", blockID: "layout:test", cwd: "/Projects/rex-agent-view")
        let window = NSWindow(contentRect: NSRect(x: 30, y: 30, width: 700, height: 820), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.title = "Rex Agent Layout Preview"
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 700, height: 820))
        window.contentView = host
        pane.frame = host.bounds
        pane.autoresizingMask = [.width, .height]
        host.addSubview(pane)
        window.orderFront(nil)
        defer { window.close() }
        let prompt = named("rex-agent.prompt", in: pane) as! NSTextView
        let send = named("rex-agent.send", in: pane) as! NSButton
        let provider = named("rex-agent.provider", in: pane) as! NSPopUpButton
        let input = prompt.enclosingScrollView!
        let surface = input.superview!
        var failures: [String] = []
        func check(_ condition: Bool, _ message: String) { if !condition { failures.append(message) } }
        flush(pane)
        let initialHeight = input.bounds.height
        let lineHeight = prompt.layoutManager!.defaultLineHeight(for: prompt.font!)
        check(initialHeight <= lineHeight * 2 + prompt.textContainerInset.height * 2 + 4, "empty input is taller than two lines")
        check(!send.isEnabled, "empty prompt leaves Send enabled")
        check(provider.isDescendant(of: surface), "provider remains outside the composer")
        check((named("rex-agent.model", in: pane)!).isDescendant(of: surface), "model remains outside the composer")
        check(send.isDescendant(of: surface), "Send remains outside the composer")
        check(send.image != nil, "Send has no native symbol")
        check((property("placeholder", of: prompt) as? String)?.contains("Codex") == true, "composer has no provider-aware placeholder")
        check((named("rex-agent.conversation-title", in: pane) as? NSTextField)?.stringValue == "New conversation", "empty conversation title is not shown")
        window.makeFirstResponder(nil)
        let unfocused = surface.layer?.borderColor
        window.makeFirstResponder(prompt)
        check(surface.layer?.borderColor != unfocused, "composer border does not reflect input focus")
        prompt.string = "First line\nSecond line\nThird line\nFourth line\nFifth line\nSixth line"
        check(send.isEnabled, "programmatic input does not enable Send immediately")
        flush(pane)
        check(input.bounds.height > initialHeight + lineHeight * 2, "multiline input does not grow")
        prompt.string = Array(repeating: "A longer line that should wrap and remain editable.", count: 40).joined(separator: "\n")
        flush(pane)
        check(input.bounds.height <= 225 && prompt.bounds.height > input.bounds.height + 100, "long input is not bounded and scrollable")
        prompt.string = ""
        flush(pane)
        check(abs(input.bounds.height - initialHeight) < 2 && !send.isEnabled, "clearing input does not shrink and disable Send")
        prompt.string = "Run the focused check."
        send.performClick(nil)
        check(AgentBridge.current.sent.last?["type"] as? String == "prompt", "programmatic input + Send stopped dispatching")
        flush(pane)
        check(prompt.string.isEmpty && abs(input.bounds.height - initialHeight) < 2, "sending does not reset input height")
        AgentBridge.current.onEvent?(["type": "done", "status": "completed"])
        func key(_ flags: NSEvent.ModifierFlags = []) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
        }
        prompt.string = "Keyboard input"
        prompt.setSelectedRange(NSRange(location: prompt.string.utf16.count, length: 0))
        let beforeKey = AgentBridge.current.sent.count
        prompt.keyDown(with: key(.shift))
        check(prompt.string.contains("\n") && AgentBridge.current.sent.count == beforeKey, "Shift+Return sends instead of adding a line")
        prompt.keyDown(with: key())
        check(AgentBridge.current.sent.last?["text"] as? String == "Keyboard input", "Return does not send the composed prompt")
        check((named("rex-agent.conversation-title", in: pane) as? NSTextField)?.stringValue == "Run the focused check.", "header does not retain the first prompt")
        AgentBridge.current.onEvent?(["type": "done", "status": "completed"])
        prompt.string = "$rev"
        prompt.setSelectedRange(NSRange(location: 4, length: 0))
        prompt.didChangeText()
        prompt.keyDown(with: key())
        check(prompt.string == "$review ", "Return does not choose the visible skill completion")
        prompt.string = ""
        provider.selectItem(at: 1)
        NSApp.sendAction(provider.action!, to: provider.target, from: provider)
        check((property("placeholder", of: prompt) as? String)?.contains("Claude") == true, "provider switch does not update placeholder")
        var larger = fonts
        larger.textSize = 20
        AgentAppearance.shared.update(larger)
        flush(pane)
        check(input.bounds.height > initialHeight + 8, "font changes do not resize the two-line input")
        AgentAppearance.shared.update(fonts)
        provider.selectItem(at: 0)
        NSApp.sendAction(provider.action!, to: provider.target, from: provider)
        let transcript = """
        ## A focused native workspace
        The agent reads the project, makes a focused change, and explains the result. Proportional text makes longer answers easier to scan while code keeps its own font.

        - Start a conversation with the selected agent.
        - Open a real terminal beside it whenever you need one.
        - Keep changes small and verify the behavior that matters.

        ```swift
        let pane = AgentPaneView(projectRoot: project)
        pane.startConversation()
        ```

        The composer stays ready for a follow-up while the conversation remains readable.
        """
        AgentBridge.current.onEvent?(["type": "conversation", "provider": "codex", "cwd": "/Projects/rex-agent-view", "resolvedModel": "gpt-6.1-sol", "resolvedEffort": "medium", "messages": [["role": "user", "text": "Make this agent workspace easier to read."], ["role": "assistant", "text": transcript]]])
        AgentBridge.current.onEvent?(["type": "ready", "provider": "codex"])
        check((named("rex-agent.conversation-title", in: pane) as? NSTextField)?.stringValue == "Make this agent workspace easier to read.", "resumed conversation title was not restored")
        let directory = named("rex-agent.working-directory", in: pane) as! NSTextField
        check(directory.stringValue == "rex-agent-view" && directory.toolTip == "/Projects/rex-agent-view", "header does not show the project with its full-path tooltip")
        AgentBridge.current.onEvent?(["type": "usage", "contextTokens": 18000, "contextWindow": 128000, "inputTokens": 2000, "outputTokens": 500])
        let messages = property("messages", of: pane) as! NSStackView
        for appearance in [NSAppearance.Name.darkAqua, .aqua] {
            pane.appearance = NSAppearance(named: appearance)
            for width in [340, 700, 1100] {
                window.setContentSize(NSSize(width: width, height: 820))
                flush(pane)
                check(abs(pane.bounds.width - CGFloat(width)) < 1, "pane changed requested \(width)pt width")
                if width >= 700 {
                    check(messages.bounds.width + 1 >= surface.bounds.width, "\(width)pt transcript is narrower than the composer")
                    check(named("rex-agent.conversation-title", in: pane)!.bounds.width > 250, "wide header unnecessarily truncates the conversation title")
                }
                let actions = named("rex-agent.actions", in: pane)!
                check(pane.bounds.width - actions.convert(actions.bounds, to: pane).maxX < 20, "header actions are not aligned to the trailing edge")
                check(surface.bounds.width >= min(CGFloat(width) - 40, 740), "\(width)pt composer is too narrow")
                for control in [provider, send, named("rex-agent.model", in: pane)!, named("rex-agent.effort", in: pane)!, named("rex-agent.conversation-title", in: pane)!, named("rex-agent.actions", in: pane)!] {
                    let box = control.convert(control.bounds, to: pane)
                    check(box.minX >= 0 && box.maxX <= pane.bounds.width + 1, "\(width)pt composer control overflows the pane")
                }
                if let folder = ProcessInfo.processInfo.environment["REX_AGENT_LAYOUT_PREVIEW_DIR"] {
                    try! FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
                    snapshot(pane, to: folder + "/pane-\(appearance == .darkAqua ? "dark" : "light")-\(width).png")
                }
            }
        }
        window.setContentSize(NSSize(width: 700, height: 820))
        pane.appearance = NSAppearance(named: .darkAqua)
        prompt.string = "Explain how this change affects existing sessions."
        flush(pane)
        if let folder = ProcessInfo.processInfo.environment["REX_AGENT_LAYOUT_PREVIEW_DIR"] { snapshot(pane, to: folder + "/pane-dark-700-draft.png") }
        let readingText = Array(repeating: "Keep this paragraph in view while editing a longer follow-up in the composer.", count: 45).joined(separator: "\n\n")
        AgentBridge.current.onEvent?(["type": "conversation", "provider": "codex", "cwd": "/Projects/rex-agent-view", "messages": [["role": "assistant", "text": readingText]]])
        flush(pane)
        let transcriptScroll = property("scroll", of: pane) as! NSScrollView
        transcriptScroll.contentView.scroll(to: NSPoint(x: 0, y: 200))
        let readingPosition = transcriptScroll.contentView.bounds.origin.y
        prompt.string = "First line\nSecond line\nThird line\nFourth line\nFifth line\nSixth line"
        flush(pane)
        check(abs(transcriptScroll.contentView.bounds.origin.y - readingPosition) < 1, "growing the composer moves the user's reading position")
        if failures.isEmpty { print("PASS composer growth/reset/send/font behavior; readable transcript and contained controls at340/700/1100 in dark/light") }
        else { failures.forEach { fputs("FAIL: \($0)\n", stderr) }; exit(1) }
    }
    private static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    private static func named(_ id: String, in view: NSView) -> NSView? { descendants(view).first { $0.accessibilityIdentifier() == id } }
    private static func property(_ name: String, of object: Any) -> Any? { Mirror(reflecting: object).children.first { $0.label == name }?.value }
    private static func flush(_ pane: NSView) { for _ in 0..<3 { pane.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.025)) } }
    private static func snapshot(_ pane: NSView, to path: String) {
        guard let bitmap = pane.bitmapImageRepForCachingDisplay(in: pane.bounds) else { return }
        pane.cacheDisplay(in: pane.bounds, to: bitmap)
        let image = NSImage(size: pane.bounds.size, flipped: false) { rect in
            AgentTheme.palette(for: pane).background.setFill(); rect.fill()
            bitmap.draw(in: rect)
            return true
        }
        try! NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
    }
}
