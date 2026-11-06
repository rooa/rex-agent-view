import AppKit
import UniformTypeIdentifiers

@MainActor
final class AgentPaneView: NSView {
    private let projectRoot: String
    private let sessionID: String
    private let blockID: String
    private var cwd: String
    private var bridge: AgentBridge?
    private var ready = false
    private var running = false
    private var response: MessageView?
    private var responseText = ""
    private var responseHasActivity = false
    private var renderTimer: Timer?
    private var tools: [String: ToolActivityView] = [:]
    private var activityRecordIndices: [String: Int] = [:]
    private var pendingApprovals: [ApprovalView] = []
    private var records: [AgentMessageRecord] = []
    private var responseIndex: Int?
    private var activeProvider = "codex"
    private var nativeSessionID: String?
    private var resumeCommand: String?
    private var selectedModel: String?
    private var selectedEffort: String?
    private var resolvedModel: String?
    private var resolvedEffort: String?
    private var models: [AgentModelOption] = []
    private var skills: [AgentSkillOption] = []
    private var operation: String?
    private var statusText = "Starting Codex…"
    private var startedAt: Date?
    private var elapsedTimer: Timer?
    private var stopRequested = false
    private var waitingForApproval = false
    private var completionRange: NSRange?
    private var attachments: [URL] = []
    /// The earlier user message being edited: its position among user messages and its original text.
    private var editing: (index: Int, original: String)?
    private var pendingEditPrompt: String?
    private var editPreviewRequest: String?
    private let attachmentRow = NSStackView()
    private var historyRequest: (id: String, append: Bool)?
    private var historyController: AgentHistoryController?
    private var historyPopover: NSPopover?
    private var palette: AgentPalette?
    private var themeObserver: Any?
    private var appearanceObserver: NSObjectProtocol?
    private var latestUsage: [String: Any] = [:]
    private var newAfterReconnect: String?
    private let titleLabel = NSTextField(labelWithString: "New conversation")
    private let directory = NSTextField(labelWithString: "")
    private let composer = NSView()
    private let inputScroll = NSScrollView()
    private let footer = NSStackView()
    private let composerFooter = NSStackView()
    private let composerSelectors = NSStackView()
    private let composerActions = NSStackView()
    private var inputHeight: NSLayoutConstraint!
    private var readingMaximumWidth: NSLayoutConstraint!
    private var readingDesiredWidth: NSLayoutConstraint!
    private var readingLeading: NSLayoutConstraint!
    private var readingTrailing: NSLayoutConstraint!
    private var composerMaximumWidth: NSLayoutConstraint!
    private var composerDesiredWidth: NSLayoutConstraint!
    private var compactComposerConstraints: [NSLayoutConstraint] = []
    private var composerIsCompact = false
    private var updatingComposer = false
    private var composerFocused = false
    private let rule = NSView()
    private let usage = NSTextField(labelWithString: "")
    private let progress = NSProgressIndicator()
    private let modelControls = AgentModelControls()
    private let completion = AgentCompletionList()
    private let provider = NSPopUpButton(frame: .zero, pullsDown: false)
    private let status = NSTextField(labelWithString: "Starting Codex…")
    private let scroll = NSScrollView()
    private let document = FlippedView()
    private let messages = NSStackView()
    private let prompt = ComposerTextView()
    private let send = NSButton(title: "Send", target: nil, action: nil)
    private let stop = NSButton(title: "Stop", target: nil, action: nil)
    private let newChat = NSButton(title: "New conversation", target: nil, action: nil)
    private let terminal = NSButton(title: "Terminal", target: nil, action: nil)
    private let history = NSButton(title: "History", target: nil, action: nil)
    private let more = NSButton(title: "", target: nil, action: nil)
    private var empty: NSView?
    private var resumeEmpty: NSButton?

    init(projectRoot: String, sessionID: String, blockID: String, cwd: String) {
        self.projectRoot = projectRoot
        self.sessionID = sessionID
        self.blockID = blockID
        self.cwd = cwd
        super.init(frame: .zero)
        identifier = NSUserInterfaceItemIdentifier("rex-agent.pane")
        setAccessibilityIdentifier("rex-agent.pane")
        wantsLayer = true
        buildUI()
        showEmptyState()
        applyTheme(force: true)
        themeObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.applyTheme() }
        }
        appearanceObserver = NotificationCenter.default.addObserver(forName: AgentAppearance.didChangeNotification, object: AgentAppearance.shared, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let follow = self.nearEnd
                self.applyTheme(force: true)
                if follow { self.scrollToEnd() }
            }
        }
        startBridge()
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTheme()
    }

    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); applyTheme() }

    override func layout() {
        let compact = bounds.width < 660
        let terminalTitle = compact ? "" : "Terminal"
        if terminal.title != terminalTitle { terminal.title = terminalTitle; terminal.imagePosition = compact ? .imageOnly : .imageLeading }
        let historyTitle = compact ? "" : "History"
        if history.title != historyTitle { history.title = historyTitle; history.imagePosition = compact ? .imageOnly : .imageLeading }
        updateReadingWidth()
        let narrowComposer = bounds.width < 600
        if composerIsCompact != narrowComposer {
            composerIsCompact = narrowComposer
            composerFooter.orientation = narrowComposer ? .vertical : .horizontal
            composerFooter.alignment = narrowComposer ? .leading : .centerY
            compactComposerConstraints.forEach { $0.isActive = narrowComposer }
        }
        super.layout()
        updateComposerHeight()
    }

    private static let providerIDs = ["codex", "claude", "pi"]
    private var providerID: String { Self.providerIDs[max(0, provider.indexOfSelectedItem)] }
    private var providerName: String { AgentProviders.name(providerID) }
    private func selectProvider(_ id: String) { provider.selectItem(at: Self.providerIDs.firstIndex(of: id) ?? 0) }

    private func buildUI() {
        let header = NSStackView()
        header.orientation = .horizontal
        header.distribution = .fill
        header.spacing = 8
        header.alignment = .centerY
        header.edgeInsets = NSEdgeInsets(top: 9, left: 14, bottom: 9, right: 14)
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.setAccessibilityIdentifier("rex-agent.conversation-title")
        provider.addItems(withTitles: Self.providerIDs.map(AgentProviders.name))
        provider.controlSize = .small
        provider.isBordered = false
        provider.font = .systemFont(ofSize: 11)
        provider.target = self
        provider.action = #selector(changeProvider)
        provider.toolTip = "Changing the agent starts a new conversation. Previous conversations stay in History."
        provider.setAccessibilityIdentifier("rex-agent.provider")
        provider.setAccessibilityLabel("Agent provider")
        newChat.target = self
        newChat.action = #selector(resetConversation)
        newChat.bezelStyle = .rounded
        newChat.controlSize = .small
        newChat.image = NSImage(systemSymbolName: "square.and.pencil", accessibilityDescription: "New conversation")
        newChat.title = ""
        newChat.imagePosition = .imageOnly
        newChat.toolTip = "New conversation"
        newChat.setAccessibilityIdentifier("rex-agent.new-conversation")
        newChat.setAccessibilityLabel("New conversation")
        terminal.target = self
        terminal.action = #selector(openTerminal)
        terminal.image = NSImage(systemSymbolName: "terminal", accessibilityDescription: "Open terminal")
        terminal.imagePosition = .imageLeading
        terminal.bezelStyle = .rounded
        terminal.controlSize = .small
        terminal.toolTip = "Open a native Rex terminal beside this conversation"
        terminal.setAccessibilityIdentifier("rex-agent.new-terminal")
        terminal.setAccessibilityLabel("New terminal")
        history.target = self
        history.action = #selector(showHistory)
        history.image = NSImage(systemSymbolName: "clock.arrow.circlepath", accessibilityDescription: "Conversation history")
        history.imagePosition = .imageLeading
        history.bezelStyle = .rounded
        history.controlSize = .small
        history.toolTip = "Browse and resume Claude, Codex, and Pi conversations"
        history.setAccessibilityIdentifier("rex-agent.history")
        more.target = self
        more.action = #selector(showConversationMenu)
        more.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "Conversation actions")
        more.bezelStyle = .rounded
        more.controlSize = .small
        more.toolTip = "Conversation actions and Agent appearance"
        more.setAccessibilityIdentifier("rex-agent.actions")
        for button in [history, newChat, terminal, more] {
            button.isBordered = false
            button.setContentHuggingPriority(.defaultHigh, for: .horizontal)
            button.font = .systemFont(ofSize: 12)
            button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
            button.heightAnchor.constraint(equalToConstant: 28).isActive = true
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 28).isActive = true
        }
        directory.font = .systemFont(ofSize: 11)
        directory.textColor = .secondaryLabelColor
        directory.lineBreakMode = .byTruncatingMiddle
        directory.toolTip = cwd
        directory.setAccessibilityLabel("Working directory")
        directory.setAccessibilityIdentifier("rex-agent.working-directory")
        directory.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let context = NSStackView(views: [titleLabel, directory])
        context.orientation = .vertical
        context.alignment = .leading
        context.spacing = 3
        context.setHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        context.setContentHuggingPriority(.defaultLow, for: .horizontal)
        context.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for label in [titleLabel, directory] {
            label.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
            label.translatesAutoresizingMaskIntoConstraints = false
            label.widthAnchor.constraint(equalTo: context.widthAnchor).isActive = true
        }
        context.widthAnchor.constraint(greaterThanOrEqualToConstant: 40).isActive = true
        [context, history, newChat, terminal, more].forEach { header.addArrangedSubview($0) }
        updateHeader()
        rule.wantsLayer = true

        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.documentView = document
        document.translatesAutoresizingMaskIntoConstraints = false
        messages.orientation = .vertical
        messages.alignment = .leading
        messages.spacing = 24
        messages.translatesAutoresizingMaskIntoConstraints = false
        messages.setAccessibilityIdentifier("rex-agent.transcript")
        document.addSubview(messages)
        readingLeading = messages.leadingAnchor.constraint(greaterThanOrEqualTo: document.leadingAnchor, constant: 24)
        readingTrailing = messages.trailingAnchor.constraint(lessThanOrEqualTo: document.trailingAnchor, constant: -24)
        readingMaximumWidth = messages.widthAnchor.constraint(lessThanOrEqualToConstant: 760)
        NSLayoutConstraint.activate([
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            messages.topAnchor.constraint(equalTo: document.topAnchor, constant: 26),
            messages.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -28),
            messages.centerXAnchor.constraint(equalTo: document.centerXAnchor),
            readingLeading, readingTrailing, readingMaximumWidth,
        ])
        readingDesiredWidth = messages.widthAnchor.constraint(equalTo: document.widthAnchor, constant: -48)
        readingDesiredWidth.priority = .defaultLow
        readingDesiredWidth.isActive = true

        composer.wantsLayer = true
        composer.layer?.cornerRadius = 12
        composer.layer?.borderWidth = 1
        composer.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.6).cgColor
        composer.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        composer.setAccessibilityIdentifier("rex-agent.composer")
        composer.toolTip = "Return to send · Shift+Return for a new line · / commands · $ skills · @ files · ⌃V or ⌘V pastes images"
        inputScroll.hasVerticalScroller = false
        inputScroll.autohidesScrollers = true
        inputScroll.drawsBackground = false
        inputScroll.borderType = .noBorder
        prompt.font = AgentAppearance.shared.settings.textFont()
        prompt.textColor = .labelColor
        prompt.insertionPointColor = .controlAccentColor
        prompt.drawsBackground = false
        prompt.isRichText = false
        prompt.isAutomaticQuoteSubstitutionEnabled = false
        prompt.isAutomaticDashSubstitutionEnabled = false
        prompt.isAutomaticSpellingCorrectionEnabled = false
        prompt.textContainerInset = NSSize(width: 0, height: 6)
        prompt.minSize = .zero
        prompt.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        prompt.isVerticallyResizable = true
        prompt.isHorizontallyResizable = false
        prompt.autoresizingMask = [.width]
        prompt.textContainer?.widthTracksTextView = true
        prompt.setAccessibilityIdentifier("rex-agent.prompt")
        prompt.setAccessibilityLabel("Message")
        prompt.onSend = { [weak self] in self?.sendPrompt() }
        prompt.onChange = { [weak self] in self?.composerChanged() }
        prompt.onMetricsChange = { [weak self] in self?.updateComposerHeight() }
        prompt.onFocusChange = { [weak self] focused in
            self?.composerFocused = focused
            self?.updateComposerFocus()
        }
        prompt.onKey = { [weak self] event in
            guard let self else { return false }
            if self.completion.handle(event) { return true }
            if event.keyCode == 53, self.editing != nil { self.cancelEdit(); return true }
            if event.keyCode == 126, self.prompt.string.isEmpty, self.attachments.isEmpty { return self.editLastMessage() }
            return false
        }
        prompt.onPasteImage = { [weak self] in self?.pasteImages() ?? false }
        completion.onChoose = { [weak self] entry in self?.insertCompletion(entry) }
        inputScroll.documentView = prompt
        inputScroll.translatesAutoresizingMaskIntoConstraints = false
        composer.addSubview(inputScroll)

        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        status.setAccessibilityIdentifier("rex-agent.status")
        send.target = self
        send.action = #selector(sendPrompt)
        send.bezelStyle = .rounded
        send.isBordered = false
        send.wantsLayer = true
        send.layer?.cornerRadius = 8
        send.image = NSImage(systemSymbolName: "arrow.up", accessibilityDescription: "Send message")
        send.imagePosition = .imageOnly
        send.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        send.toolTip = "Send message (Return)"
        send.setAccessibilityIdentifier("rex-agent.send")
        send.setAccessibilityLabel("Send message")
        stop.target = self
        stop.action = #selector(stopTurn)
        stop.bezelStyle = .rounded
        stop.image = NSImage(systemSymbolName: "stop.fill", accessibilityDescription: "Stop agent")
        stop.imagePosition = .imageLeading
        stop.setAccessibilityIdentifier("rex-agent.stop")
        stop.isHidden = true
        usage.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        usage.isHidden = true
        usage.lineBreakMode = .byTruncatingTail
        usage.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        usage.setAccessibilityIdentifier("rex-agent.usage")
        progress.style = .spinning
        progress.controlSize = .small
        progress.isDisplayedWhenStopped = false
        progress.translatesAutoresizingMaskIntoConstraints = false
        progress.widthAnchor.constraint(equalToConstant: 12).isActive = true
        progress.heightAnchor.constraint(equalToConstant: 12).isActive = true
        modelControls.onChange = { [weak self] model, effort in
            self?.bridge?.send(["type": "configure", "model": model as Any? ?? NSNull(), "effort": effort as Any? ?? NSNull()])
        }
        provider.widthAnchor.constraint(equalToConstant: 72).isActive = true
        composerSelectors.orientation = .horizontal
        composerSelectors.alignment = .centerY
        composerSelectors.spacing = 6
        [provider, modelControls].forEach { composerSelectors.addArrangedSubview($0) }
        composerSelectors.setContentHuggingPriority(.defaultLow, for: .horizontal)
        composerActions.orientation = .horizontal
        composerActions.alignment = .centerY
        composerActions.spacing = 7
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        [progress, status, NSView(), usage, stop, send].forEach { composerActions.addArrangedSubview($0) }
        composerFooter.orientation = .horizontal
        composerFooter.alignment = .centerY
        composerFooter.spacing = 9
        [composerSelectors, composerActions].forEach { composerFooter.addArrangedSubview($0) }
        composerFooter.translatesAutoresizingMaskIntoConstraints = false
        composer.addSubview(composerFooter)
        attachmentRow.spacing = 6
        attachmentRow.isHidden = true
        [completion, attachmentRow, composer].forEach { footer.addArrangedSubview($0) }
        footer.orientation = .vertical
        footer.alignment = .centerX
        footer.spacing = 7
        footer.edgeInsets = NSEdgeInsets(top: 10, left: 18, bottom: 12, right: 18)
        [header, rule, scroll, footer].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }
        composer.translatesAutoresizingMaskIntoConstraints = false
        completion.translatesAutoresizingMaskIntoConstraints = false
        modelControls.translatesAutoresizingMaskIntoConstraints = false
        inputHeight = inputScroll.heightAnchor.constraint(equalToConstant: 50)
        composerMaximumWidth = composer.widthAnchor.constraint(lessThanOrEqualToConstant: 760)
        composerDesiredWidth = composer.widthAnchor.constraint(equalTo: footer.widthAnchor, constant: -36)
        composerDesiredWidth.priority = .defaultLow
        compactComposerConstraints = [
            composerSelectors.widthAnchor.constraint(equalTo: composerFooter.widthAnchor),
            composerActions.widthAnchor.constraint(equalTo: composerFooter.widthAnchor),
        ]
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            rule.topAnchor.constraint(equalTo: header.bottomAnchor),
            rule.leadingAnchor.constraint(equalTo: leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: trailingAnchor),
            rule.heightAnchor.constraint(equalToConstant: 1),
            scroll.topAnchor.constraint(equalTo: rule.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: footer.topAnchor),
            footer.leadingAnchor.constraint(equalTo: leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: bottomAnchor),
            composerMaximumWidth, composerDesiredWidth,
            completion.widthAnchor.constraint(equalTo: composer.widthAnchor),
            inputScroll.topAnchor.constraint(equalTo: composer.topAnchor, constant: 8),
            inputScroll.leadingAnchor.constraint(equalTo: composer.leadingAnchor, constant: 10),
            inputScroll.trailingAnchor.constraint(equalTo: composer.trailingAnchor, constant: -10),
            inputHeight,
            composerFooter.topAnchor.constraint(equalTo: inputScroll.bottomAnchor, constant: 8),
            composerFooter.leadingAnchor.constraint(equalTo: composer.leadingAnchor, constant: 10),
            composerFooter.trailingAnchor.constraint(equalTo: composer.trailingAnchor, constant: -10),
            composerFooter.bottomAnchor.constraint(equalTo: composer.bottomAnchor, constant: -10),
            send.widthAnchor.constraint(equalToConstant: 36),
            send.heightAnchor.constraint(equalToConstant: 30),
        ])
        updateControls()
    }

    private func updateHeader() {
        let firstPrompt = records.first { $0.role == "user" && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }?.text
        let title = firstPrompt?.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            ?? (records.isEmpty ? "New conversation" : "\(providerName) conversation")
        titleLabel.stringValue = String(title.prefix(120))
        titleLabel.toolTip = title
        let project = (cwd as NSString).lastPathComponent
        directory.stringValue = cwd == NSHomeDirectory() ? "Home" : project.isEmpty ? cwd : project
        directory.toolTip = cwd
    }

    private func updateReadingWidth() {
        guard readingMaximumWidth != nil else { return }
        let font = AgentAppearance.shared.settings.textFont()
        let sample = "The agent reads the project, makes a focused change, and explains the result."
        let average = (sample as NSString).size(withAttributes: [.font: font]).width / CGFloat(sample.count)
        // The transcript column is never narrower than the composer's maximum width.
        let width = max(760, ceil(average * 74) + 40)
        let margin: CGFloat = bounds.width < 400 ? 12 : 18
        readingMaximumWidth.constant = width
        readingLeading.constant = margin
        readingTrailing.constant = -margin
        readingDesiredWidth.constant = -margin * 2
        composerMaximumWidth.constant = width
        composerDesiredWidth.constant = -margin * 2
        footer.edgeInsets = NSEdgeInsets(top: 10, left: margin, bottom: 12, right: margin)
    }

    private func composerChanged() {
        let follow = nearEnd
        let origin = scroll.contentView.bounds.origin
        let resized = updateComposerHeight()
        updateControls()
        updateCompletions()
        if resized && follow {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.scroll.contentView.bounds.origin == origin else { return }
                self.scrollToEnd()
            }
        }
    }

    @discardableResult
    private func updateComposerHeight() -> Bool {
        guard !updatingComposer, inputHeight != nil, inputScroll.contentSize.width > 0,
              let manager = prompt.layoutManager, let container = prompt.textContainer, let font = prompt.font else { return false }
        updatingComposer = true
        defer { updatingComposer = false }
        let width = inputScroll.contentSize.width
        if abs(prompt.frame.width - width) > 0.5 { prompt.setFrameSize(NSSize(width: width, height: prompt.frame.height)) }
        container.containerSize = NSSize(width: max(1, width - prompt.textContainerInset.width * 2), height: CGFloat.greatestFiniteMagnitude)
        manager.ensureLayout(for: container)
        let minimum = ceil(manager.defaultLineHeight(for: font) * 2 + prompt.textContainerInset.height * 2)
        let natural = max(minimum, ceil(max(manager.usedRect(for: container).maxY, manager.extraLineFragmentRect.maxY) + prompt.textContainerInset.height * 2))
        let maximum = max(minimum, min(220, bounds.height * 0.3))
        let height = min(natural, maximum)
        let changed = abs(inputHeight.constant - height) > 0.5
        if changed { inputHeight.constant = height; needsLayout = true }
        prompt.minSize = NSSize(width: 0, height: minimum)
        if abs(prompt.frame.height - natural) > 0.5 { prompt.setFrameSize(NSSize(width: width, height: natural)) }
        inputScroll.hasVerticalScroller = natural > maximum + 0.5
        if natural <= height + 0.5 { inputScroll.contentView.scroll(to: .zero) }
        inputScroll.reflectScrolledClipView(inputScroll.contentView)
        return changed
    }

    private func updateComposerFocus() {
        composer.layer?.borderColor = (composerFocused ? currentPalette.accent : currentPalette.border).cgColor
        composer.layer?.borderWidth = composerFocused ? 1.5 : 1
    }

    private func updateSendAppearance() {
        let palette = currentPalette
        send.layer?.backgroundColor = (send.isEnabled ? palette.accent : palette.text.withAlphaComponent(0.08)).cgColor
        let accent = palette.accent.usingColorSpace(.sRGB) ?? palette.accent
        let brightness = accent.redComponent * 0.2126 + accent.greenComponent * 0.7152 + accent.blueComponent * 0.0722
        send.contentTintColor = send.isEnabled ? (brightness > 0.6 ? .black : .white) : palette.tertiary
    }

    private func showEmptyState() {
        let title = NSTextField(labelWithString: "What are we working on?")
        let fonts = AgentAppearance.shared.settings
        title.font = fonts.textFont(size: fonts.textSize + 8, weight: .semibold)
        title.identifier = NSUserInterfaceItemIdentifier("rex-agent.empty-title")
        let description = NSTextField(wrappingLabelWithString: "Ask your agent to explore this project, make a change, or work through an idea. Open a terminal whenever you need one.")
        description.font = fonts.textFont(size: fonts.textSize - 1)
        description.textColor = .secondaryLabelColor
        description.identifier = NSUserInterfaceItemIdentifier("rex-agent.secondary")
        let example = ActionButton(title: "Explore this project") { [weak self] in
            self?.prompt.string = "Explore this project and explain how it is organized. Do not make changes yet."
            self?.window?.makeFirstResponder(self?.prompt)
        }
        example.bezelStyle = .rounded
        let resume = ActionButton(title: "Resume a conversation") { [weak self] in self?.showHistory() }
        resume.bezelStyle = .rounded
        resume.isEnabled = ready
        resumeEmpty = resume
        let choices = NSStackView(views: [example, resume])
        choices.spacing = 8
        let stack = NSStackView(views: [title, description, choices])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 13
        stack.edgeInsets = NSEdgeInsets(top: 26, left: 0, bottom: 22, right: 0)
        addMessageView(stack)
        description.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        empty = stack
    }

    private func startBridge() {
        ready = false
        operation = "startup"
        setStatus("Starting \(providerName)…")
        let connection = AgentBridge()
        connection.onEvent = { [weak self] event in self?.receive(event) }
        bridge = connection
        updateControls()
        connection.start(projectRoot: projectRoot, provider: providerID, cwd: cwd, paneKey: sessionID + "/" + blockID)
    }

    private func addMessageView(_ view: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        messages.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: messages.widthAnchor).isActive = true
    }

    @objc private func sendPrompt() {
        let text = prompt.string.trimmingCharacters(in: .whitespacesAndNewlines)
        if editing != nil { submitEdit(text); return }
        if handleLocalCommand(text) { prompt.string = ""; completion.dismiss(); return }
        guard ready, !running, !text.isEmpty || !attachments.isEmpty else { return }
        let images = attachments.map(\.path)
        let shown = ([text] + attachments.map { "[Image: \($0.lastPathComponent)]" }).filter { !$0.isEmpty }.joined(separator: "\n")
        setAttachments([])
        completion.dismiss()
        if let empty { messages.removeArrangedSubview(empty); empty.removeFromSuperview(); self.empty = nil }
        records.append(AgentMessageRecord(role: "user", text: shown))
        updateHeader()
        let question = MessageView(speaker: "You", text: shown, onLink: { [weak self] in self?.openLink($0) ?? true })
        attachEdit(question, index: records.filter { $0.role == "user" }.count - 1)
        question.applyTheme(currentPalette)
        addMessageView(question)
        beginResponseSegment()
        tools.removeAll()
        activityRecordIndices.removeAll()
        pendingApprovals.removeAll()
        prompt.string = ""
        running = true
        stopRequested = false
        waitingForApproval = false
        startedAt = Date()
        elapsedTimer?.invalidate()
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshStatus() }
        }
        setStatus("Working…")
        updateControls()
        bridge?.send(["type": "prompt", "text": text, "images": images])
        scrollToEnd()
    }

    private func beginResponseSegment() {
        let answer = MessageView(speaker: providerName, text: "", onLink: { [weak self] in self?.openLink($0) ?? true })
        answer.applyTheme(currentPalette)
        addMessageView(answer)
        records.append(AgentMessageRecord(role: "assistant", text: ""))
        responseIndex = records.count - 1
        response = answer
        responseText = ""
        responseHasActivity = false
    }

    @objc private func stopTurn() {
        guard running, !stopRequested else { return }
        stopRequested = true
        bridge?.send(["type": "stop"])
        setStatus("Stopping…")
        updateControls()
    }

    @objc private func changeProvider() { resetConversation() }

    @objc private func resetConversation() {
        guard !running, operation == nil else { return }
        completion.dismiss()
        if !ready {
            newAfterReconnect = providerID
            bridge?.onEvent = nil
            bridge?.close()
            startBridge()
            return
        }
        operation = "new"
        ready = false
        setStatus("Starting a new conversation…")
        updateControls()
        bridge?.send(["type": "new", "provider": providerID])
    }

    private func clearTranscript() {
        renderTimer?.invalidate()
        renderTimer = nil
        running = false
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        response = nil
        responseIndex = nil
        responseText = ""
        responseHasActivity = false
        records.removeAll()
        tools.removeAll()
        activityRecordIndices.removeAll()
        pendingApprovals.removeAll()
        latestUsage.removeAll()
        usage.stringValue = ""
        for view in messages.arrangedSubviews { messages.removeArrangedSubview(view); view.removeFromSuperview() }
        empty = nil
        resumeEmpty = nil
    }

    private func loadConversation(_ event: [String: Any]) {
        clearTranscript()
        activeProvider = event["provider"] as? String ?? activeProvider
        selectProvider(activeProvider)
        cwd = event["cwd"] as? String ?? cwd
        nativeSessionID = event["sessionId"] as? String
        resumeCommand = event["resumeCommand"] as? String
        selectedModel = event["model"] as? String
        selectedEffort = event["effort"] as? String
        resolvedModel = event["resolvedModel"] as? String
        resolvedEffort = event["resolvedEffort"] as? String
        records = (event["messages"] as? [[String: Any]] ?? []).compactMap(AgentMessageRecord.init)
        updateHeader()
        var userIndex = 0
        for record in records {
            if let command = record.command {
                let view = AgentCommandView(command: command, onLink: { [weak self] in self?.openLink($0) ?? true })
                view.applyTheme(currentPalette)
                addMessageView(view)
                continue
            }
            let speaker = record.role == "user" ? "You" : record.role == "command" ? "Local command" : providerName
            let message = MessageView(speaker: speaker, text: record.text, onLink: { [weak self] in self?.openLink($0) ?? true })
            if record.role == "user" { attachEdit(message, index: userIndex); userIndex += 1 }
            message.applyTheme(currentPalette)
            for record in record.activities {
                let activity = ToolActivityView()
                activity.applyTheme(currentPalette)
                activity.update(title: record.title, detail: record.detail, status: record.status)
                message.addActivity(activity)
            }
            addMessageView(message)
        }
        if records.isEmpty { showEmptyState(); applyTheme(force: true) }
        prompt.string = ""
        setAttachments([])
        completion.dismiss()
        updateModels()
        scrollToEnd()
    }

    private func receive(_ event: [String: Any]) {
        switch event["type"] as? String {
        case "conversation": loadConversation(event)
        case "session":
            nativeSessionID = event["sessionId"] as? String ?? nativeSessionID
            resumeCommand = event["resumeCommand"] as? String ?? resumeCommand
        case "catalog":
            models = (event["models"] as? [[String: Any]] ?? []).compactMap(AgentModelOption.init)
            skills = (event["skills"] as? [[String: Any]] ?? []).compactMap(AgentSkillOption.init)
            updateModels()
            updateCompletions()
        case "configured":
            let model = event["model"] as? String
            let effort = event["effort"] as? String
            if model != selectedModel { resolvedModel = nil; resolvedEffort = nil }
            else if effort != selectedEffort { resolvedEffort = nil }
            selectedModel = model
            selectedEffort = effort
            updateModels()
        case "ready":
            ready = true
            operation = nil
            activeProvider = event["provider"] as? String ?? activeProvider
            selectProvider(activeProvider)
            if let value = event["cwd"] as? String { cwd = value }
            updateHeader()
            setStatus("Ready")
            if let text = pendingEditPrompt {
                pendingEditPrompt = nil
                prompt.string = text
                sendPrompt()
            }
            if let nextProvider = newAfterReconnect {
                newAfterReconnect = nil
                selectProvider(nextProvider)
                resetConversation()
            }
        case "editPreview":
            guard let request = editPreviewRequest, event["requestId"] as? String == request else { break }
            editPreviewRequest = nil
            confirmEdit(files: event["files"] as? [String] ?? [])
        case "sessions":
            guard let request = historyRequest, event["requestId"] as? String == request.id else { break }
            let sessions = (event["sessions"] as? [[String: Any]] ?? []).compactMap(AgentHistorySession.init)
            historyController?.update(sessions, nextCursor: event["nextCursor"] as? String, append: request.append, warnings: event["warnings"] as? [String] ?? [], source: event["source"] as? String)
            historyRequest = nil
        case "status":
            if let model = event["model"] as? String { resolvedModel = model }
            if let effort = event["effort"] as? String { resolvedEffort = effort }
            updateModels()
            if running && !stopRequested && !waitingForApproval {
                let state = event["state"] as? String ?? "working"
                setStatus(["thinking": "Thinking…", "working": "Working…", "running": "Working…", "responding": "Responding…", "waiting": "Waiting…"][state] ?? state.replacingOccurrences(of: "_", with: " ").capitalized)
            }
        case "usage": latestUsage = event; updateUsage()
        case "notice":
            if let text = event["text"] as? String, !text.isEmpty, !waitingForApproval { setStatus(text) }
        case "delta":
            if responseHasActivity {
                let follow = nearEnd
                renderResponse()
                beginResponseSegment()
                if follow { scrollToEnd() }
            }
            responseText += event["text"] as? String ?? ""
            if let index = responseIndex, records.indices.contains(index) { records[index].text = responseText }
            if !stopRequested && !waitingForApproval { setStatus("Responding…") }
            if renderTimer == nil {
                let timer = Timer(timeInterval: 0.05, repeats: false) { [weak self] _ in
                    MainActor.assumeIsolated { self?.renderResponse() }
                }
                renderTimer = timer
                RunLoop.main.add(timer, forMode: .common)
            }
        case "activity":
            guard let response, let id = event["id"] as? String else { break }
            let follow = nearEnd
            let activity = tools[id] ?? ToolActivityView()
            if tools[id] == nil {
                renderResponse()
                tools[id] = activity
                activityRecordIndices[id] = responseIndex
                activity.applyTheme(currentPalette)
                response.addActivity(activity)
                responseHasActivity = true
            }
            let record = AgentActivityRecord(event)
            activity.update(title: record.title, detail: record.detail, status: record.status)
            if let index = activityRecordIndices[id], records.indices.contains(index) {
                if let existing = records[index].activities.firstIndex(where: { $0.id == id }) { records[index].activities[existing] = record }
                else { records[index].activities.append(record) }
            }
            if !stopRequested && !waitingForApproval { setStatus(record.status == "running" ? record.title : "Working…") }
            if follow { scrollToEnd() }
        case "approval":
            guard let response, let requestID = event["requestId"] else { break }
            let follow = nearEnd
            renderResponse()
            let options = event["options"] as? [String]
            let approval = ApprovalView(title: event["title"] as? String ?? "Approval needed", detail: event["detail"] as? String ?? "", options: options) { [weak self] decision, value in
                var message: [String: Any] = ["type": "approval", "requestId": requestID, "decision": decision]
                if let value { message["value"] = value }
                self?.bridge?.send(message)
                guard let self else { return }
                self.waitingForApproval = self.pendingApprovals.contains(where: { $0.isPending })
                self.setStatus(self.waitingForApproval ? "Waiting for approval" : "Working…")
            }
            approval.applyTheme(currentPalette)
            pendingApprovals.append(approval)
            response.addActivity(approval)
            responseHasActivity = true
            waitingForApproval = true
            setStatus("Waiting for approval")
            if follow { scrollToEnd() }
        case "done":
            renderResponse()
            running = false
            stopRequested = false
            waitingForApproval = false
            elapsedTimer?.invalidate()
            elapsedTimer = nil
            pendingApprovals.forEach { $0.expire() }
            let completion = event["status"] as? String ?? "completed"
            setStatus(completion == "interrupted" ? "Stopped" : completion == "failed" ? "Turn failed" : "Ready")
        case "error", "disconnected":
            let detail = event["message"] as? String ?? "The agent reported an error."
            let errorOperation = event["operation"] as? String
            if errorOperation == "sessions" {
                guard let request = historyRequest, event["requestId"] as? String == request.id else { break }
                historyController?.showError(detail)
                historyRequest = nil
                break
            }
            if event["type"] as? String == "disconnected", historyRequest != nil {
                historyController?.showError(detail)
                historyRequest = nil
            }
            if errorOperation == "configure" { updateModels() }
            if errorOperation == "editPreview" || errorOperation == "edit" {
                editPreviewRequest = nil
                if let text = pendingEditPrompt { pendingEditPrompt = nil; prompt.string = text }
            }
            if operation == "new" || operation == "resume" || operation == "edit" {
                operation = nil
                ready = true
                selectProvider(activeProvider)
            }
            let error = NSTextField(wrappingLabelWithString: detail)
            error.font = AgentAppearance.shared.settings.textFont(size: AgentAppearance.shared.settings.textSize - 3)
            error.textColor = currentPalette.danger
            error.identifier = NSUserInterfaceItemIdentifier("rex-agent.error")
            error.isSelectable = true
            if let response { response.addActivity(error) } else { addMessageView(error) }
            setStatus(event["type"] as? String == "disconnected" ? "Disconnected · start a new conversation" : "Agent reported an error")
            if event["type"] as? String == "disconnected" { ready = false; running = false; operation = nil; elapsedTimer?.invalidate(); elapsedTimer = nil }
        default: break
        }
        updateControls()
    }

    private func renderResponse() {
        renderTimer?.invalidate()
        renderTimer = nil
        let follow = nearEnd
        response?.setText(responseText)
        if follow { scrollToEnd() }
    }

    private var nearEnd: Bool {
        document.bounds.height - scroll.contentView.bounds.maxY < 70
    }

    private func scrollToEnd() {
        layoutSubtreeIfNeeded()
        scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, document.bounds.height - scroll.contentView.bounds.height)))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    private func updateControls() {
        send.isEnabled = ready && !running && operation == nil && (!prompt.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty)
        send.isHidden = running
        stop.isHidden = !running
        stop.isEnabled = running && !stopRequested
        provider.isEnabled = !running && operation == nil
        newChat.isEnabled = !running && operation == nil
        history.isEnabled = ready && !running && operation == nil
        resumeEmpty?.isEnabled = history.isEnabled
        modelControls.setEnabled(ready && !running && operation == nil)
        progress.isHidden = !running && operation == nil
        if running || operation != nil { progress.startAnimation(nil) } else { progress.stopAnimation(nil) }
        prompt.placeholder = "Message \(providerName)…"
        prompt.setAccessibilityHelp("Message \(providerName). Return sends; Shift+Return adds a new line.")
        updateSendAppearance()
    }

    private func updateModels() {
        modelControls.update(options: models, selectedModel: selectedModel, selectedEffort: selectedEffort, resolvedModel: resolvedModel, resolvedEffort: resolvedEffort)
        modelControls.setEnabled(ready && !running && operation == nil)
        refreshStatus()
    }

    private func setStatus(_ text: String) { statusText = text; refreshStatus() }

    private func refreshStatus() {
        let seconds = running ? max(0, Int(Date().timeIntervalSince(startedAt ?? Date()))) : 0
        let elapsed = seconds >= 60 ? String(format: "%d:%02d", seconds / 60, seconds % 60) : "\(seconds)s"
        status.stringValue = running ? "\(statusText) · \(elapsed)" : statusText
        status.toolTip = [statusText, resolvedModel.map { "Model: \($0)" }, (selectedEffort ?? resolvedEffort).map { "Effort: \($0)" }, usage.toolTip].compactMap { $0 }.joined(separator: "\n")
        status.textColor = waitingForApproval ? currentPalette.warning : currentPalette.secondary
    }

    private func updateUsage() {
        func number(_ name: String) -> Double? { (latestUsage[name] as? NSNumber)?.doubleValue }
        func compact(_ value: Double) -> String {
            if value >= 1_000_000 { return String(format: "%.1fm", value / 1_000_000) }
            if value >= 1_000 { return String(format: "%.1fk", value / 1_000) }
            return String(Int(value))
        }
        let input = number("inputTokens"), output = number("outputTokens")
        if let tokens = number("contextTokens"), let window = number("contextWindow"), window > 0 {
            usage.stringValue = "\(Int(tokens / window * 100))% context"
        } else if input != nil || output != nil { usage.stringValue = "\(compact((input ?? 0) + (output ?? 0))) tokens" }
        else { usage.stringValue = "" }
        usage.isHidden = usage.stringValue.isEmpty
        var details: [String] = []
        if let input { details.append("Input: \(Int(input)) tokens") }
        if let output { details.append("Output: \(Int(output)) tokens") }
        if let cached = number("cachedInputTokens") { details.append("Cached input: \(Int(cached)) tokens") }
        if let context = number("contextTokens") { details.append("Context: \(Int(context)) tokens") }
        if let window = number("contextWindow") { details.append("Context window: \(Int(window)) tokens") }
        if let cost = number("costUSD") { details.append(String(format: "Reported cost: $%.4f", cost)) }
        if let scope = latestUsage["scope"] as? String { details.append("Scope: \(scope)") }
        usage.toolTip = details.joined(separator: "\n")
        refreshStatus()
    }

    @objc private func showHistory() {
        guard ready, !running, operation == nil else { return }
        if historyPopover?.isShown == true { historyPopover?.close(); return }
        let controller = AgentHistoryController()
        controller.onRequest = { [weak self] scope, cursor, repair in
            guard let self else { return }
            let id = UUID().uuidString
            self.historyRequest = (id, cursor != nil)
            var request: [String: Any] = ["type": "sessions", "requestId": id, "scope": scope]
            if let cursor { request["cursor"] = cursor }
            if repair { request["repair"] = true }
            self.bridge?.send(request)
        }
        controller.onResume = { [weak self] session in
            guard let self, !self.running else { return }
            self.historyPopover?.close()
            self.operation = "resume"
            self.ready = false
            self.setStatus("Loading conversation…")
            self.updateControls()
            self.bridge?.send(["type": "resume", "provider": session.provider, "sessionId": session.id])
        }
        controller.apply(currentPalette)
        controller.view.appearance = effectiveAppearance
        historyController = controller
        let popover = NSPopover()
        popover.behavior = .transient
        popover.appearance = effectiveAppearance
        popover.contentViewController = controller
        popover.contentSize = NSSize(width: min(360, max(300, bounds.width - 24)), height: 418)
        historyPopover = popover
        popover.show(relativeTo: history.bounds, of: history, preferredEdge: .minY)
        controller.request()
    }

    private var localCompletions: [AgentCompletion] {
        var values = [
            AgentCompletion(title: "/history", description: "Browse and resume Claude, Codex, or Pi conversations", insertText: "/history"),
            AgentCompletion(title: "/resume", description: "Continue a saved conversation in this pane", insertText: "/resume"),
            AgentCompletion(title: "/new", description: "Start a new conversation", insertText: "/new"),
            AgentCompletion(title: "/model", description: "Choose the model for your next turn", insertText: "/model"),
            AgentCompletion(title: "/effort", description: "Choose reasoning effort", insertText: "/effort"),
            AgentCompletion(title: "/export", description: "Save this conversation as Markdown", insertText: "/export"),
            AgentCompletion(title: "/help", description: "Show available pane commands", insertText: "/help"),
        ]
        if running { values = values.filter { ["/export", "/help"].contains($0.insertText) }; values.insert(AgentCompletion(title: "/stop", description: "Stop the current turn", insertText: "/stop"), at: 0) }
        return values
    }

    private func updateCompletions() {
        guard ready, operation == nil, prompt.selectedRange().length == 0 else { completion.dismiss(); return }
        let text = prompt.string as NSString
        let cursor = min(text.length, prompt.selectedRange().location)
        let before = text.substring(to: cursor) as NSString
        let whitespace = before.rangeOfCharacter(from: .whitespacesAndNewlines, options: .backwards)
        let start = whitespace.location == NSNotFound ? 0 : NSMaxRange(whitespace)
        let token = before.substring(from: start)
        guard let trigger = token.first, trigger == "/" || trigger == "$" || trigger == "@" else { completion.dismiss(); return }
        if trigger == "@" {
            completionRange = NSRange(location: start, length: cursor - start)
            let follow = nearEnd
            completion.show(pathCompletions(String(token.dropFirst())))
            if follow { scrollToEnd() }
            return
        }
        if (trigger == "/" || activeProvider != "codex") && !before.substring(to: start).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { completion.dismiss(); return }
        let query = token.dropFirst().lowercased()
        var candidates: [AgentCompletion] = trigger == "/" ? localCompletions : []
        candidates += skills.map {
            AgentCompletion(title: $0.insertText + ($0.argumentHint.map { " " + $0 } ?? ""), description: $0.description, insertText: $0.insertText)
        }
        candidates = candidates.filter {
            let name = $0.insertText.drop(while: { $0 == "/" || $0 == "$" }).lowercased()
            return query.isEmpty || name.hasPrefix(query)
        }
        completionRange = NSRange(location: start, length: cursor - start)
        let follow = nearEnd
        completion.show(candidates)
        if follow { scrollToEnd() }
    }

    /// Lists one directory level for an `@` reference, relative to the conversation's directory.
    private func pathCompletions(_ query: String) -> [AgentCompletion] {
        let slash = query.lastIndex(of: "/")
        let folder = slash.map { String(query[...$0]) } ?? ""
        let prefix = (slash.map { String(query[query.index(after: $0)...]) } ?? query).lowercased()
        let expanded = (folder as NSString).expandingTildeInPath
        let base = expanded.hasPrefix("/") ? expanded : (cwd as NSString).appendingPathComponent(expanded)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: base) else { return [] }
        return names.filter { (prefix.hasPrefix(".") || !$0.hasPrefix(".")) && (prefix.isEmpty || $0.lowercased().hasPrefix(prefix)) }
            .map { name -> (String, Bool) in
                var isDirectory: ObjCBool = false
                FileManager.default.fileExists(atPath: (base as NSString).appendingPathComponent(name), isDirectory: &isDirectory)
                return (name, isDirectory.boolValue)
            }
            .sorted { $0.1 != $1.1 ? $0.1 : $0.0.localizedStandardCompare($1.0) == .orderedAscending }
            .prefix(50)
            .map { name, isDirectory in
                let path = folder + name + (isDirectory ? "/" : "")
                return AgentCompletion(title: "@" + path, description: isDirectory ? "Folder" : "File", insertText: "@" + path)
            }
    }

    private func insertCompletion(_ entry: AgentCompletion) {
        guard let range = completionRange, NSMaxRange(range) <= (prompt.string as NSString).length else { return }
        let trimmed = entry.insertText.trimmingCharacters(in: .whitespacesAndNewlines)
        // Keep folders open so completion continues into them.
        let value = trimmed.hasPrefix("@") && trimmed.hasSuffix("/") ? trimmed : trimmed + " "
        if prompt.shouldChangeText(in: range, replacementString: value) {
            prompt.textStorage?.replaceCharacters(in: range, with: value)
            prompt.setSelectedRange(NSRange(location: range.location + (value as NSString).length, length: 0))
            prompt.didChangeText()
        }
        window?.makeFirstResponder(prompt)
    }

    private var canEdit: Bool { ready && !running && operation == nil && nativeSessionID != nil }

    private func attachEdit(_ view: MessageView, index: Int) {
        view.onEdit = { [weak self, weak view] in
            guard let self, let view, self.canEdit else { NSSound.beep(); return }
            self.beginEdit(index: index, text: view.plainText)
        }
    }

    private func beginEdit(index: Int, text: String) {
        let original = text
        // Image placeholders can't be re-sent; keep only the typed text.
        let editable = text.components(separatedBy: "\n").filter { !$0.hasPrefix("[Image: ") && $0 != "[Image attachment]" }.joined(separator: "\n")
        editing = (index, original)
        setAttachments([])
        prompt.string = editable
        prompt.setSelectedRange(NSRange(location: (editable as NSString).length, length: 0))
        window?.makeFirstResponder(prompt)
        setStatus("Editing message · Return forks from here · Esc cancels")
    }

    private func editLastMessage() -> Bool {
        guard canEdit, let last = records.lastIndex(where: { $0.role == "user" }) else { return false }
        beginEdit(index: records[...last].filter { $0.role == "user" }.count - 1, text: records[last].text)
        return true
    }

    private func cancelEdit() {
        editing = nil
        prompt.string = ""
        setStatus("Ready")
    }

    private func submitEdit(_ text: String) {
        guard let edit = editing, canEdit, !text.isEmpty else { return }
        completion.dismiss()
        if activeProvider == "claude" {
            let id = UUID().uuidString
            editPreviewRequest = id
            setStatus("Checking file changes…")
            bridge?.send(["type": "editPreview", "requestId": id, "index": edit.index, "original": edit.original])
        } else {
            performEdit(restoreFiles: false)
        }
    }

    private func confirmEdit(files: [String]) {
        guard !files.isEmpty, let window else { performEdit(restoreFiles: false); return }
        let alert = NSAlert()
        alert.messageText = "Restore files too?"
        let shown = files.prefix(8).map { ($0 as NSString).lastPathComponent }.joined(separator: "\n")
        alert.informativeText = "Claude changed \(files.count) file\(files.count == 1 ? "" : "s") after this message:\n\(shown)\(files.count > 8 ? "\n…" : "")\n\nThe original conversation stays in History either way."
        alert.addButton(withTitle: "Restore Files and Fork")
        alert.addButton(withTitle: "Keep Files and Fork")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            switch response {
            case .alertFirstButtonReturn: self?.performEdit(restoreFiles: true)
            case .alertSecondButtonReturn: self?.performEdit(restoreFiles: false)
            default: self?.setStatus("Editing message · Return forks from here · Esc cancels")
            }
        }
    }

    private func performEdit(restoreFiles: Bool) {
        guard let edit = editing else { return }
        editing = nil
        pendingEditPrompt = prompt.string.trimmingCharacters(in: .whitespacesAndNewlines)
        prompt.string = ""
        operation = "edit"
        ready = false
        setStatus(restoreFiles ? "Restoring files and forking…" : "Forking conversation…")
        updateControls()
        bridge?.send(["type": "edit", "index": edit.index, "original": edit.original, "restoreFiles": restoreFiles])
    }

    /// Attaches pasted image files, or saves raw pasted image data to a temporary PNG.
    private func pasteImages() -> Bool {
        let board = NSPasteboard.general
        let imageTypes = Set(["png", "jpg", "jpeg", "gif", "webp"])
        let files = (board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? [])
            .filter { imageTypes.contains($0.pathExtension.lowercased()) }
        if !files.isEmpty { setAttachments(attachments + files); return true }
        guard board.canReadItem(withDataConformingToTypes: [UTType.image.identifier]),
              let image = NSImage(pasteboard: board), let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return false }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("rex-agent-images", isDirectory: true)
        let file = folder.appendingPathComponent("pasted-\(UUID().uuidString.prefix(8)).png")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try png.write(to: file)
        } catch { NSSound.beep(); return true }
        setAttachments(attachments + [file])
        return true
    }

    private func setAttachments(_ urls: [URL]) {
        attachments = urls
        for view in attachmentRow.arrangedSubviews { attachmentRow.removeArrangedSubview(view); view.removeFromSuperview() }
        for url in urls {
            let chip = ActionButton(title: "\(url.lastPathComponent)  ✕") { [weak self] in
                guard let self else { return }
                self.setAttachments(self.attachments.filter { $0 != url })
            }
            chip.bezelStyle = .rounded
            chip.controlSize = .small
            chip.image = NSImage(systemSymbolName: "photo", accessibilityDescription: nil)
            chip.imagePosition = .imageLeading
            chip.toolTip = "\(url.path)\nClick to remove"
            attachmentRow.addArrangedSubview(chip)
        }
        attachmentRow.isHidden = urls.isEmpty
        updateControls()
    }

    private func handleLocalCommand(_ text: String) -> Bool {
        switch text {
        case "/new": guard !running, operation == nil else { return false }; resetConversation()
        case "/history", "/resume": guard ready, !running else { return false }; showHistory()
        case "/model": guard ready, !running else { return false }; modelControls.showModelMenu()
        case "/effort": guard ready, !running else { return false }; modelControls.showEffortMenu()
        case "/export": exportMarkdown()
        case "/stop": guard running else { return false }; stopTurn()
        case "/help":
            let alert = NSAlert()
            alert.messageText = "Agent pane commands"
            alert.informativeText = "/history — Browse native Claude, Codex, and Pi sessions\n/new — Start a conversation\n/model — Choose a model\n/effort — Choose reasoning effort\n/export — Save Markdown\n/stop — Stop the current turn\n\nHover a message and click the pencil, or press ↑ in an empty box, to edit and fork. Type / or $ to find skills, @ for files. Tab or Return inserts a suggestion. Shift+Enter adds a new line."
            if let window { alert.beginSheetModal(for: window) }
        default: return false
        }
        return true
    }

    @objc private func showConversationMenu() {
        let menu = NSMenu()
        let resume = NSMenuItem(title: "Resume Conversation…", action: #selector(showHistory), keyEquivalent: "")
        resume.target = self
        resume.isEnabled = ready && !running && operation == nil
        let export = NSMenuItem(title: "Export Markdown…", action: #selector(exportMarkdown), keyEquivalent: "")
        export.target = self
        export.isEnabled = !records.isEmpty
        let copy = NSMenuItem(title: "Copy CLI Resume Command", action: #selector(copyResumeCommand), keyEquivalent: "")
        copy.target = self
        copy.isEnabled = resumeCommand != nil
        menu.autoenablesItems = false
        menu.addItem(resume)
        menu.addItem(.separator())
        menu.addItem(export)
        menu.addItem(copy)
        menu.addItem(.separator())
        let appearance = NSMenuItem(title: "Appearance…", action: #selector(showAppearance), keyEquivalent: "")
        appearance.target = self
        menu.addItem(appearance)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: more.bounds.minY), in: more)
    }

    @objc private func showAppearance() { AgentAppearance.shared.showPreferences() }

    @objc private func copyResumeCommand() {
        guard let resumeCommand else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(resumeCommand, forType: .string)
        setStatus("CLI resume command copied")
    }

    @objc private func exportMarkdown() {
        guard !records.isEmpty, let window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.canCreateDirectories = true
        let title = records.first(where: { $0.role == "user" })?.text.components(separatedBy: .newlines).first ?? "Conversation"
        let filename = String(title.prefix(60)).replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        panel.nameFieldStringValue = (filename.isEmpty ? "Conversation" : filename) + ".md"
        var markdown = "# \(providerName) conversation\n\nWorking directory: `\(cwd)`\n"
        if let nativeSessionID { markdown += "\nSession: `\(nativeSessionID)`\n" }
        for record in records {
            let speaker = record.role == "user" ? "You" : record.role == "command" ? "Local command" : providerName
            markdown += "\n## \(speaker)\n\n\(record.text)\n"
            for activity in record.activities {
                let longestRun = activity.detail.split(whereSeparator: { $0 != "~" }).map(\.count).max() ?? 0
                let fence = String(repeating: "~", count: max(3, longestRun + 1))
                markdown += "\n### Tool: \(activity.title)\n\n\(fence)text\n\(activity.detail)\n\(fence)\n"
            }
        }
        panel.beginSheetModal(for: window) { [weak self] result in
            guard result == .OK, let url = panel.url else { return }
            do { try markdown.write(to: url, atomically: true, encoding: .utf8); self?.setStatus("Conversation exported") }
            catch { self?.setStatus("Export failed: \(error.localizedDescription)") }
        }
    }

    private var currentPalette: AgentPalette { palette ?? AgentTheme.palette(for: self) }

    private func applyTheme(force: Bool = false) {
        let value = AgentTheme.palette(for: self)
        guard force || palette != value else { return }
        palette = value
        let fonts = AgentAppearance.shared.settings
        layer?.backgroundColor = value.background.cgColor
        composer.layer?.backgroundColor = value.surface.cgColor
        updateComposerFocus()
        rule.layer?.backgroundColor = value.border.cgColor
        titleLabel.textColor = value.text
        directory.textColor = value.secondary
        usage.textColor = value.secondary
        status.textColor = waitingForApproval ? value.warning : value.secondary
        prompt.textColor = value.text
        prompt.font = fonts.textFont()
        prompt.placeholderColor = value.tertiary
        prompt.insertionPointColor = value.accent
        prompt.selectedTextAttributes = [.backgroundColor: value.selection, .foregroundColor: value.selectedText]
        provider.contentTintColor = value.text
        updateSendAppearance()
        stop.contentTintColor = value.text
        [history, newChat, terminal, more].forEach { $0.contentTintColor = value.secondary }
        modelControls.apply(value)
        completion.apply(value)
        historyController?.apply(value)
        historyController?.view.appearance = effectiveAppearance
        historyPopover?.appearance = effectiveAppearance
        func colorLabels(_ view: NSView) {
            if let text = view as? NSTextField {
                text.textColor = view.identifier?.rawValue == "rex-agent.error" ? value.danger : view.identifier?.rawValue == "rex-agent.secondary" ? value.secondary : value.text
                switch view.identifier?.rawValue {
                case "rex-agent.empty-title": text.font = fonts.textFont(size: fonts.textSize + 8, weight: .semibold)
                case "rex-agent.secondary": text.font = fonts.textFont(size: fonts.textSize - 1)
                case "rex-agent.error": text.font = fonts.textFont(size: fonts.textSize - 3)
                default: break
                }
            }
            view.subviews.forEach(colorLabels)
        }
        for view in messages.arrangedSubviews {
            if let message = view as? MessageView { message.applyTheme(value) }
            if let command = view as? AgentCommandView { command.applyTheme(value) }
            else { colorLabels(view) }
        }
        updateReadingWidth()
        updateComposerHeight()
    }

    @objc private func openTerminal() {
        setStatus("Opening terminal…")
        let task = Process()
        let output = Pipe(), errors = Pipe()
        let executable = ProcessInfo.processInfo.environment["REX_AGENT_CLI"] ?? "/opt/homebrew/bin/rex"
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = ["split", "-s", sessionID, "-b", blockID, "--split=right", "--ratio", "40", "-c", cwd, "--json"]
        task.standardOutput = output
        task.standardError = errors
        task.terminationHandler = { [weak self] task in
            let data = errors.fileHandleForReading.readDataToEndOfFile()
            DispatchQueue.main.async {
                self?.setStatus(task.terminationStatus == 0 ? "Terminal opened" : "Could not open terminal: \(String(decoding: data, as: UTF8.self))")
            }
        }
        do { try task.run() }
        catch { setStatus("Could not open terminal: \(error.localizedDescription)") }
    }

    private func openLink(_ link: Any) -> Bool {
        do {
            guard let file = try AgentLinks.resolve(link, cwd: cwd) else { return false }
            setStatus("Opening \(file.url.lastPathComponent) in editor…")
            AgentLinks.open(file, cwd: cwd, sessionID: sessionID, blockID: blockID) { [weak self] result in
                switch result {
                case .success: self?.setStatus("Opened \(file.url.lastPathComponent) in editor")
                case .failure(let error): self?.setStatus("Could not open file: \(error.localizedDescription)")
                }
            }
        } catch { setStatus("Could not open link: \(error.localizedDescription)") }
        return true
    }

    deinit {
        if let themeObserver { NotificationCenter.default.removeObserver(themeObserver) }
        if let appearanceObserver { NotificationCenter.default.removeObserver(appearanceObserver) }
        renderTimer?.invalidate()
        elapsedTimer?.invalidate()
    }
}

@MainActor
private final class FlippedView: NSView { override var isFlipped: Bool { true } }

@MainActor
private final class ComposerTextView: NSTextView {
    var onSend: (() -> Void)?
    var onChange: (() -> Void)?
    var onMetricsChange: (() -> Void)?
    var onFocusChange: ((Bool) -> Void)?
    var onKey: ((NSEvent) -> Bool)?
    var onPasteImage: (() -> Bool)?
    var placeholder = "" { didSet { needsDisplay = true } }
    var placeholderColor: NSColor = .placeholderTextColor { didSet { needsDisplay = true } }
    override var string: String { didSet { needsDisplay = true; onChange?() } }
    override var font: NSFont? { didSet { needsDisplay = true; onMetricsChange?() } }
    override func didChangeText() { super.didChangeText(); needsDisplay = true; onChange?() }
    override func setFrameSize(_ newSize: NSSize) {
        let changed = abs(newSize.width - frame.width) > 0.5
        super.setFrameSize(newSize)
        if changed { onMetricsChange?() }
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if string.isEmpty && !hasMarkedText() {
            let inset = textContainerInset
            (placeholder as NSString).draw(at: NSPoint(x: inset.width + (textContainer?.lineFragmentPadding ?? 0), y: inset.height),
                                          withAttributes: [.font: font ?? NSFont.systemFont(ofSize: 15), .foregroundColor: placeholderColor])
        }
    }
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocusChange?(true) }
        return accepted
    }
    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { onFocusChange?(false) }
        return accepted
    }
    override func mouseUp(with event: NSEvent) { super.mouseUp(with: event); onChange?() }
    override func paste(_ sender: Any?) { if onPasteImage?() != true { super.paste(sender) } }
    override func keyDown(with event: NSEvent) {
        if hasMarkedText() { super.keyDown(with: event); return }
        if onKey?(event) == true { return }
        // Ctrl+V pastes images like terminal agent CLIs; text paste stays on ⌘V.
        if event.keyCode == 9, event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .control, onPasteImage?() == true { return }
        if event.keyCode == 36 && !event.modifierFlags.contains(.shift) { onSend?() }
        else {
            super.keyDown(with: event)
            if [123, 124, 115, 119].contains(event.keyCode) { onChange?() }
        }
    }
}

@MainActor
private final class ActionButton: NSButton {
    private var handler: () -> Void
    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(frame: .zero)
        self.title = title
        target = self
        action = #selector(invoke)
    }
    required init?(coder: NSCoder) { nil }
    @objc private func invoke() { handler() }
}

@MainActor
private final class MessageView: NSStackView {
    private let text = AgentMarkdownView()
    private let heading = NSTextField(labelWithString: "")
    private let edit = NSButton()
    private var source = ""
    private var palette: AgentPalette?
    var plainText: String { source }
    var onEdit: (() -> Void)? { didSet { edit.isHidden = true; updateTrackingAreas() } }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        if onEdit != nil { addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)) }
    }
    override func mouseEntered(with event: NSEvent) { edit.isHidden = onEdit == nil }
    override func mouseExited(with event: NSEvent) { edit.isHidden = true }
    @objc private func editMessage() { onEdit?() }
    init(speaker: String, text: String, onLink: ((Any) -> Bool)? = nil) {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 9
        heading.stringValue = speaker
        heading.font = .systemFont(ofSize: 12, weight: .semibold)
        heading.textColor = .secondaryLabelColor
        edit.image = NSImage(systemSymbolName: "pencil", accessibilityDescription: "Edit message")
        edit.isBordered = false
        edit.isHidden = true
        edit.toolTip = "Edit and fork from this message (↑ edits the last one)"
        edit.target = self
        edit.action = #selector(editMessage)
        let headingRow = NSStackView(views: [heading, edit])
        headingRow.spacing = 6
        addArrangedSubview(headingRow)
        addArrangedSubview(self.text)
        self.text.translatesAutoresizingMaskIntoConstraints = false
        self.text.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        self.text.onLink = onLink
        self.text.preserveSoftBreaks = speaker == "You"
        setText(text)
    }
    required init?(coder: NSCoder) { nil }
    func setText(_ value: String) {
        source = value
        text.update(value, palette: palette ?? AgentTheme.palette(for: self))
    }
    func applyTheme(_ palette: AgentPalette) {
        self.palette = palette
        heading.textColor = palette.secondary
        edit.contentTintColor = palette.secondary
        setText(source)
        for view in arrangedSubviews {
            if let activity = view as? ToolActivityView { activity.applyTheme(palette) }
            if let approval = view as? ApprovalView { approval.applyTheme(palette) }
            if view.identifier?.rawValue == "rex-agent.error", let error = view as? NSTextField {
                error.textColor = palette.danger
                let fonts = AgentAppearance.shared.settings
                error.font = fonts.textFont(size: fonts.textSize - 3)
            }
        }
    }
    func addActivity(_ view: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
    }
}

@MainActor
private final class AgentCommandView: NSView {
    private let command: AgentCommandRecord
    private let icon = NSImageView()
    private let invocation = GrowingTextView()
    private let output = AgentMarkdownView()

    init(command: AgentCommandRecord, onLink: ((Any) -> Bool)?) {
        self.command = command
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 9
        setAccessibilityIdentifier("rex-agent.local-command")
        setAccessibilityLabel("Local command")
        icon.image = NSImage(systemSymbolName: "terminal", accessibilityDescription: "Local command")
        invocation.setAccessibilityIdentifier("rex-agent.command-invocation")
        output.setAccessibilityIdentifier("rex-agent.command-output")
        output.onLink = onLink
        output.preserveSoftBreaks = true
        let header = NSStackView(views: [icon, invocation])
        header.alignment = .top
        header.spacing = 9
        let content = NSStackView(views: [header, output])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 10
        content.translatesAutoresizingMaskIntoConstraints = false
        header.translatesAutoresizingMaskIntoConstraints = false
        output.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            content.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            header.widthAnchor.constraint(equalTo: content.widthAnchor),
            output.widthAnchor.constraint(equalTo: content.widthAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 18),
        ])
    }
    required init?(coder: NSCoder) { nil }

    func applyTheme(_ palette: AgentPalette) {
        let fonts = AgentAppearance.shared.settings
        layer?.backgroundColor = palette.surface.cgColor
        icon.contentTintColor = palette.secondary
        let title = NSMutableAttributedString(string: command.name.isEmpty ? "Command output" : command.name,
            attributes: [.font: command.name.isEmpty ? fonts.textFont(weight: .medium) : fonts.codeFont(), .foregroundColor: palette.text])
        if !command.args.isEmpty {
            title.append(NSAttributedString(string: " " + command.args, attributes: [.font: fonts.codeFont(), .foregroundColor: palette.secondary]))
        }
        invocation.selectedTextAttributes = [.backgroundColor: palette.selection, .foregroundColor: palette.selectedText]
        invocation.setContent(title)
        output.update(command.output, palette: palette)
    }
}

@MainActor
final class AgentTextLayoutManager: NSLayoutManager {
    static let inlineCodeBackground = NSAttributedString.Key("RexAgent.inlineCodeBackground")

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        if let textStorage {
            let characters = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
            textStorage.enumerateAttribute(Self.inlineCodeBackground, in: characters) { value, range, _ in
                guard let color = value as? NSColor,
                      let font = textStorage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont else { return }
                let glyphs = self.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
                self.enumerateLineFragments(forGlyphRange: glyphs) { line, _, container, lineGlyphs, _ in
                    let segment = NSIntersectionRange(glyphs, lineGlyphs)
                    let baseline = line.minY + self.location(forGlyphAt: segment.location).y
                    self.enumerateEnclosingRects(forGlyphRange: segment, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: container) { rect, _ in
                        // AppKit's ordinary background includes the whole prose line height.
                        // Keep inline code close to its font, even inside a larger heading.
                        let background = NSRect(x: rect.minX + origin.x, y: baseline - font.ascender - 1 + origin.y,
                                                width: rect.width, height: font.ascender - font.descender + 2)
                        color.setFill()
                        background.fill()
                    }
                }
            }
        }
        // Native selection and marked-text backgrounds must remain above the code tint.
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
    }
}

@MainActor
final class GrowingTextView: NSTextView, NSTextViewDelegate {
    private let storageOwner: NSTextStorage
    var onLink: ((Any) -> Bool)?
    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        let container = container ?? NSTextContainer(size: NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude))
        storageOwner = container.layoutManager?.textStorage ?? NSTextStorage()
        let manager = container.layoutManager ?? AgentTextLayoutManager()
        if manager.textStorage == nil { storageOwner.addLayoutManager(manager) }
        if container.layoutManager == nil { manager.addTextContainer(container) }
        super.init(frame: frameRect, textContainer: container)
        isEditable = false
        isSelectable = true
        delegate = self
        drawsBackground = false
        textContainerInset = .zero
        textContainer?.lineFragmentPadding = 0
        textContainer?.widthTracksTextView = true
        isHorizontallyResizable = false
        isVerticallyResizable = true
        setContentHuggingPriority(.defaultHigh, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .vertical)
    }
    convenience init() { self.init(frame: .zero, textContainer: nil) }
    required init?(coder: NSCoder) { nil }
    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        onLink?(link) ?? false
    }
    func setContent(_ value: NSAttributedString) {
        guard let textStorage, !textStorage.isEqual(to: value) else { return }
        let selection = selectedRanges.filter { NSMaxRange($0.rangeValue) <= value.length }
        textStorage.setAttributedString(value)
        if !selection.isEmpty { selectedRanges = selection }
        invalidateIntrinsicContentSize()
    }
    override func setFrameSize(_ newSize: NSSize) {
        let changed = abs(frame.width - newSize.width) > 0.5
        super.setFrameSize(newSize)
        if changed { invalidateIntrinsicContentSize() }
    }
    override var intrinsicContentSize: NSSize {
        guard let textContainer, let layoutManager else { return NSSize(width: NSView.noIntrinsicMetric, height: 20) }
        textContainer.containerSize = NSSize(width: max(1, bounds.width), height: CGFloat.greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: textContainer)
        return NSSize(width: NSView.noIntrinsicMetric, height: max(20, ceil(layoutManager.usedRect(for: textContainer).height)))
    }
}

@MainActor
private final class ToolActivityView: NSStackView {
    private let disclosure = NSButton()
    private let heading = NSTextField(wrappingLabelWithString: "")
    private let state = NSTextField(labelWithString: "")
    private let detail = GrowingTextView()
    private var expanded = false
    private var palette: AgentPalette?
    private var activityTitle = ""
    private var activityDetail = ""
    private var activityStatus = "completed"
    override init(frame: NSRect) {
        super.init(frame: frame)
        orientation = .vertical
        alignment = .leading
        spacing = 7
        disclosure.setButtonType(.onOff)
        disclosure.bezelStyle = .disclosure
        disclosure.title = ""
        disclosure.target = self
        disclosure.action = #selector(toggle)
        disclosure.setAccessibilityLabel("Show tool details")
        heading.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        heading.textColor = .secondaryLabelColor
        heading.maximumNumberOfLines = 2
        heading.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        state.font = .systemFont(ofSize: 10, weight: .medium)
        state.setContentCompressionResistancePriority(.required, for: .horizontal)
        let row = NSStackView(views: [disclosure, heading, NSView(), state])
        row.orientation = .horizontal
        row.spacing = 5
        addArrangedSubview(row)
        addArrangedSubview(detail)
        detail.isHidden = true
        [row, detail].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; $0.widthAnchor.constraint(equalTo: widthAnchor).isActive = true }
    }
    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { nil }
    func update(title: String, detail: String, status: String) {
        activityTitle = title
        activityDetail = detail
        activityStatus = status
        let colors = palette ?? AgentTheme.palette(for: self)
        let fonts = AgentAppearance.shared.settings
        heading.font = fonts.codeFont(size: fonts.codeSize - 1)
        heading.stringValue = "\(status == "completed" ? "✓" : status == "failed" ? "!" : "↳") \(title)"
        heading.textColor = status == "failed" ? colors.danger : colors.secondary
        heading.toolTip = title
        state.stringValue = status == "running" ? "Running" : status == "failed" ? "Failed" : "Done"
        state.textColor = status == "failed" ? colors.danger : status == "running" ? colors.accent : colors.tertiary
        let visible = detail.count > 18000 ? String(detail.prefix(18000)) + "\n[Output shortened for display]" : detail
        self.detail.setContent(NSAttributedString(string: visible, attributes: [.font: fonts.codeFont(size: fonts.codeSize - 1.5), .foregroundColor: colors.text, .backgroundColor: colors.surface]))
    }
    func applyTheme(_ palette: AgentPalette) {
        self.palette = palette
        disclosure.contentTintColor = palette.secondary
        detail.selectedTextAttributes = [.backgroundColor: palette.selection, .foregroundColor: palette.selectedText]
        update(title: activityTitle, detail: activityDetail, status: activityStatus)
    }
    @objc private func toggle() { expanded.toggle(); detail.isHidden = !expanded }
}

@MainActor
private final class ApprovalView: NSStackView {
    private var buttons: [NSButton] = []
    private let isChoice: Bool
    private let state = NSTextField(labelWithString: "Approval needed")
    private let descriptionLabel = NSTextField(wrappingLabelWithString: "")
    private var palette: AgentPalette?
    var isPending: Bool { buttons.contains(where: { $0.isEnabled }) }
    init(title: String, detail: String, options: [String]? = nil, decide: @escaping (String, String?) -> Void) {
        isChoice = options != nil
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 8
        state.font = .systemFont(ofSize: 12, weight: .semibold)
        state.textColor = .systemOrange
        descriptionLabel.stringValue = [title, detail].filter { !$0.isEmpty }.joined(separator: "\n")
        descriptionLabel.font = .systemFont(ofSize: 12)
        descriptionLabel.isSelectable = true
        let row = NSStackView()
        row.spacing = 8
        if let options {
            state.stringValue = "Choice needed"
            buttons = options.map { option in ActionButton(title: option) { [weak self] in self?.resolve("select", value: option, decide: decide) } }
            buttons.append(ActionButton(title: "Cancel") { [weak self] in self?.resolve("decline", decide: decide) })
            // Long option lists read better stacked than in one row.
            if options.count > 3 || options.contains(where: { $0.count > 24 }) { row.orientation = .vertical; row.alignment = .leading }
        } else {
            let allow = ActionButton(title: "Allow") { [weak self] in self?.resolve("accept", decide: decide) }
            let deny = ActionButton(title: "Deny") { [weak self] in self?.resolve("decline", decide: decide) }
            allow.setAccessibilityIdentifier("rex-agent.approve")
            deny.setAccessibilityIdentifier("rex-agent.deny")
            buttons = [allow, deny]
        }
        for button in buttons { button.bezelStyle = .rounded; row.addArrangedSubview(button) }
        [state, descriptionLabel, row].forEach { addArrangedSubview($0) }
        descriptionLabel.translatesAutoresizingMaskIntoConstraints = false
        descriptionLabel.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
    }
    required init?(coder: NSCoder) { nil }
    private func resolve(_ decision: String, value: String? = nil, decide: (String, String?) -> Void) {
        guard buttons.contains(where: { $0.isEnabled }) else { return }
        buttons.forEach { $0.isEnabled = false }
        state.stringValue = value.map { "Chose \($0)" } ?? (decision == "accept" ? "Allowed" : isChoice ? "Cancelled" : "Denied")
        state.textColor = palette?.secondary ?? .secondaryLabelColor
        decide(decision, value)
    }
    func expire() {
        if buttons.contains(where: { $0.isEnabled }) { state.stringValue = isChoice ? "Choice no longer pending" : "Approval no longer pending" }
        buttons.forEach { $0.isEnabled = false }
        state.textColor = palette?.secondary ?? .secondaryLabelColor
    }
    func applyTheme(_ palette: AgentPalette) {
        self.palette = palette
        state.textColor = buttons.contains(where: { $0.isEnabled }) ? palette.warning : palette.secondary
        descriptionLabel.textColor = palette.text
        let fonts = AgentAppearance.shared.settings
        descriptionLabel.font = fonts.textFont(size: fonts.textSize - 3)
        buttons.forEach { $0.contentTintColor = palette.accent }
    }
}
