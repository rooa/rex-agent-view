import AppKit

struct AgentFontSettings: Equatable {
    var textFamily: String? = nil
    var textSize: CGFloat = 15
    var codeFamily: String? = nil
    var codeSize: CGFloat = 12.5

    @MainActor
    func textFont(size: CGFloat? = nil, weight: NSFont.Weight = .regular, italic: Bool = false) -> NSFont {
        font(family: textFamily, size: size ?? normalized.textSize, weight: weight, italic: italic, monospaced: false)
    }

    @MainActor
    func codeFont(size: CGFloat? = nil, weight: NSFont.Weight = .regular, italic: Bool = false) -> NSFont {
        font(family: codeFamily, size: size ?? normalized.codeSize, weight: weight, italic: italic, monospaced: true)
    }

    fileprivate var normalized: AgentFontSettings {
        func family(_ value: String?) -> String? {
            let name = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return name.isEmpty ? nil : name
        }
        func size(_ value: CGFloat, fallback: CGFloat) -> CGFloat { value.isFinite ? min(48, max(8, value)) : fallback }
        return AgentFontSettings(textFamily: family(textFamily), textSize: size(textSize, fallback: 15),
                                 codeFamily: family(codeFamily), codeSize: size(codeSize, fallback: 12.5))
    }

    @MainActor
    private func font(family: String?, size: CGFloat, weight: NSFont.Weight, italic: Bool, monospaced: Bool) -> NSFont {
        let size = size.isFinite ? max(8, size) : (monospaced ? 12.5 : 15)
        var result = monospaced ? NSFont.monospacedSystemFont(ofSize: size, weight: weight) : NSFont.systemFont(ofSize: size, weight: weight)
        if let family, NSFontManager.shared.availableFontFamilies.contains(family) {
            let descriptor = NSFontDescriptor(fontAttributes: [.family: family, .traits: [NSFontDescriptor.TraitKey.weight: weight.rawValue]])
            result = NSFont(descriptor: descriptor, size: size) ?? result
        }
        return italic ? NSFontManager.shared.convert(result, toHaveTrait: .italicFontMask) : result
    }
}

@MainActor
final class AgentAppearance: NSObject {
    static let shared = AgentAppearance()
    static let didChangeNotification = Notification.Name("RexAgentAppearanceDidChange")
    private static let defaultsKey = "RexAgent.Appearance.Fonts"
    private let defaults: UserDefaults
    private var preferencesWindow: NSWindowController?
    private(set) var settings: AgentFontSettings

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.dictionary(forKey: Self.defaultsKey) ?? [:]
        settings = AgentFontSettings(textFamily: stored["textFamily"] as? String,
                                     textSize: CGFloat((stored["textSize"] as? NSNumber)?.doubleValue ?? 15),
                                     codeFamily: stored["codeFamily"] as? String,
                                     codeSize: CGFloat((stored["codeSize"] as? NSNumber)?.doubleValue ?? 12.5)).normalized
        super.init()
    }

    func update(_ value: AgentFontSettings) {
        let value = value.normalized
        guard value != settings else { return }
        settings = value
        var stored: [String: Any] = ["textSize": Double(value.textSize), "codeSize": Double(value.codeSize)]
        stored["textFamily"] = value.textFamily
        stored["codeFamily"] = value.codeFamily
        defaults.set(stored, forKey: Self.defaultsKey)
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }

    func reset() {
        defaults.removeObject(forKey: Self.defaultsKey)
        guard settings != AgentFontSettings() else { return }
        settings = AgentFontSettings()
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }

    func showPreferences() {
        if preferencesWindow == nil {
            let controller = AgentAppearanceViewController(appearance: self)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 430),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Agent Appearance"
            window.contentViewController = controller
            window.isReleasedWhenClosed = false
            window.center()
            preferencesWindow = NSWindowController(window: window)
        }
        preferencesWindow?.showWindow(nil)
        preferencesWindow?.window?.makeKeyAndOrderFront(nil)
    }
}

@MainActor
final class AgentAppearanceViewController: NSViewController, NSTextFieldDelegate {
    private let appearance: AgentAppearance
    private let textFamily = NSPopUpButton(frame: .zero, pullsDown: false)
    private let codeFamily = NSPopUpButton(frame: .zero, pullsDown: false)
    private let textSize = NSTextField()
    private let codeSize = NSTextField()
    private let textStepper = NSStepper()
    private let codeStepper = NSStepper()
    private let preview = NSTextView()
    private var observer: NSObjectProtocol?

    init(appearance: AgentAppearance) {
        self.appearance = appearance
        super.init(nibName: nil, bundle: nil)
        observer = NotificationCenter.default.addObserver(forName: AgentAppearance.didChangeNotification, object: appearance, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if self?.isViewLoaded == true { self?.refresh() } }
        }
    }
    required init?(coder: NSCoder) { nil }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 430))
        preferredContentSize = view.bounds.size
        let title = NSTextField(labelWithString: "Agent Appearance")
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        let explanation = NSTextField(labelWithString: "Applies to all Agent panes in this copy of Rex.")
        explanation.font = .systemFont(ofSize: 11)
        explanation.textColor = .secondaryLabelColor
        let text = section("Conversation and composer", family: textFamily, size: textSize, stepper: textStepper, tag: 0)
        let code = section("Code and tool output", family: codeFamily, size: codeSize, stepper: codeStepper, tag: 1)
        let previewLabel = NSTextField(labelWithString: "Preview")
        previewLabel.font = .systemFont(ofSize: 12, weight: .medium)
        preview.isEditable = false
        preview.isSelectable = true
        preview.isVerticallyResizable = true
        preview.isHorizontallyResizable = false
        preview.autoresizingMask = .width
        preview.textContainer?.widthTracksTextView = true
        preview.textContainerInset = NSSize(width: 12, height: 12)
        preview.backgroundColor = .textBackgroundColor
        preview.setAccessibilityIdentifier("rex-agent.appearance.preview")
        let scroll = NSScrollView()
        scroll.borderType = .bezelBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = preview
        let reset = NSButton(title: "Reset to Defaults", target: self, action: #selector(resetFonts))
        reset.bezelStyle = .rounded
        reset.setAccessibilityIdentifier("rex-agent.appearance.reset")
        let saved = NSTextField(labelWithString: "Changes are saved automatically")
        saved.font = .systemFont(ofSize: 11)
        saved.textColor = .secondaryLabelColor
        let footer = NSStackView(views: [reset, NSView(), saved])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        let stack = NSStackView(views: [title, explanation, text, code, previewLabel, scroll, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 140),
        ])
        [text, code, scroll, footer].forEach { $0.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        refresh()
    }

    private func section(_ title: String, family: NSPopUpButton, size: NSTextField, stepper: NSStepper, tag: Int) -> NSStackView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        family.addItem(withTitle: tag == 0 ? "System Font" : "System Monospaced")
        for name in NSFontManager.shared.availableFontFamilies.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) {
            family.addItem(withTitle: name)
            family.lastItem?.representedObject = name
        }
        family.tag = tag
        family.target = self
        family.action = #selector(familyChanged(_:))
        family.cell?.lineBreakMode = .byTruncatingTail
        family.setContentHuggingPriority(.defaultLow, for: .horizontal)
        family.setAccessibilityIdentifier("rex-agent.appearance." + (tag == 0 ? "text-family" : "code-family"))
        family.setAccessibilityLabel(title + " font")
        let format = NumberFormatter()
        format.minimum = 8
        format.maximum = 48
        format.allowsFloats = true
        format.maximumFractionDigits = 1
        size.formatter = format
        size.alignment = .right
        size.tag = tag
        size.target = self
        size.action = #selector(sizeChanged(_:))
        size.delegate = self
        size.setAccessibilityIdentifier("rex-agent.appearance." + (tag == 0 ? "text-size" : "code-size"))
        size.setAccessibilityLabel(title + " size in points")
        size.translatesAutoresizingMaskIntoConstraints = false
        size.widthAnchor.constraint(equalToConstant: 50).isActive = true
        stepper.minValue = 8
        stepper.maxValue = 48
        stepper.increment = 0.5
        stepper.tag = tag
        stepper.target = self
        stepper.action = #selector(stepperChanged(_:))
        stepper.setAccessibilityLabel(title + " font size")
        let unit = NSTextField(labelWithString: "pt")
        unit.textColor = .secondaryLabelColor
        let row = NSStackView(views: [family, size, stepper, unit])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .fill
        row.spacing = 6
        let section = NSStackView(views: [label, row])
        section.orientation = .vertical
        section.alignment = .leading
        section.spacing = 6
        row.widthAnchor.constraint(equalTo: section.widthAnchor).isActive = true
        return section
    }

    @objc private func familyChanged(_ sender: NSPopUpButton) {
        var settings = appearance.settings
        if sender.tag == 0 { settings.textFamily = sender.selectedItem?.representedObject as? String }
        else { settings.codeFamily = sender.selectedItem?.representedObject as? String }
        appearance.update(settings)
    }

    @objc private func sizeChanged(_ sender: NSTextField) {
        guard let value = sender.objectValue as? NSNumber else { refresh(); return }
        setSize(CGFloat(value.doubleValue), tag: sender.tag)
    }

    @objc private func stepperChanged(_ sender: NSStepper) { setSize(CGFloat(sender.doubleValue), tag: sender.tag) }

    private func setSize(_ value: CGFloat, tag: Int) {
        var settings = appearance.settings
        if tag == 0 { settings.textSize = value } else { settings.codeSize = value }
        appearance.update(settings)
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        if let field = notification.object as? NSTextField { sizeChanged(field) }
    }

    @objc private func resetFonts() { appearance.reset() }

    private func refresh() {
        let settings = appearance.settings
        for (popup, selected) in [(textFamily, settings.textFamily), (codeFamily, settings.codeFamily)] {
            if let selected {
                if let item = popup.itemArray.first(where: { $0.representedObject as? String == selected }) { popup.select(item) }
                else {
                    popup.addItem(withTitle: selected + " (unavailable)")
                    popup.lastItem?.representedObject = selected
                    popup.selectItem(at: popup.numberOfItems - 1)
                }
            } else { popup.selectItem(at: 0) }
        }
        textSize.doubleValue = Double(settings.textSize)
        codeSize.doubleValue = Double(settings.codeSize)
        textStepper.doubleValue = Double(settings.textSize)
        codeStepper.doubleValue = Double(settings.codeSize)
        let sample = NSMutableAttributedString(string: "Explain the change and show the result.\n", attributes: [.font: settings.textFont(), .foregroundColor: NSColor.labelColor])
        sample.append(NSAttributedString(string: "Selected text font", attributes: [.font: settings.textFont(weight: .semibold), .foregroundColor: NSColor.labelColor]))
        sample.append(NSAttributedString(string: " with emphasis.\n\n", attributes: [.font: settings.textFont(italic: true), .foregroundColor: NSColor.labelColor]))
        sample.append(NSAttributedString(string: "let result = await agent.run(prompt)", attributes: [.font: settings.codeFont(), .foregroundColor: NSColor.labelColor]))
        preview.textStorage?.setAttributedString(sample)
    }
}
