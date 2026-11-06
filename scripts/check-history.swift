import AppKit

@main
@MainActor
struct HistoryCheck {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let root = CommandLine.arguments[1]
        Task { @MainActor in
            do {
                try await checkTransport(root)
                print("PASS history transport failure reports request ID")
                try await checkTimeout(root)
                print("PASS unanswered history times out; completed and replacement requests stay settled")
                try checkControls()
                print("PASS native history selection, Resume in this pane, Retry and empty project state")
                exit(0)
            } catch {
                fputs("FAIL: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
        }
        app.run()
    }

    private static func checkTransport(_ root: String) async throws {
        try FileManager.default.createDirectory(atPath: root + "/bridge", withIntermediateDirectories: true)
        let fixture = """
        import { createInterface } from 'node:readline';
        const lines = createInterface({input: process.stdin});
        const emit = value => process.stdout.write(JSON.stringify(value) + '\\n');
        const counts = new Map();
        lines.on('line', text => {
          const message = JSON.parse(text);
          if (message.type === 'sessions') {
            if (message.requestId === 'interrupted-history') process.exit(1);
            if (message.requestId === 'silent') return;
            const count = (counts.get(message.requestId) || 0) + 1;
            counts.set(message.requestId, count);
            if (message.requestId === 'reused' && count === 1) return;
            setTimeout(() => emit({type: 'sessions', requestId: message.requestId, sessions: []}), 35);
          }
          if (message.type === 'close') process.exit(0);
        });
        emit({type: 'ready', provider: 'codex'});
        """
        try fixture.write(toFile: root + "/bridge/main.mjs", atomically: true, encoding: .utf8)
        let bridge = AgentBridge()
        var events: [[String: Any]] = []
        bridge.onEvent = { events.append($0) }
        bridge.start(projectRoot: root, provider: "codex", cwd: root)
        try await wait("fixture ready") { events.contains { $0["type"] as? String == "ready" } }
        bridge.send(["type": "sessions", "requestId": "interrupted-history", "scope": "project"])
        try await wait("bridge disconnect") { events.contains { $0["type"] as? String == "disconnected" } }
        try require(events.contains {
            $0["type"] as? String == "error" && $0["operation"] as? String == "sessions"
                && $0["requestId"] as? String == "interrupted-history"
        }, "a disconnect left History loading: no correlated sessions error")
        bridge.close()
        bridge.send(["type": "sessions", "requestId": "closed-history"])
        try require(events.contains { $0["requestId"] as? String == "closed-history" && $0["operation"] as? String == "sessions" }, "sending to a closed bridge silently dropped history")
    }

    private static func checkTimeout(_ root: String) async throws {
        let bridge = AgentBridge(historyRequestTimeout: 0.15)
        var events: [[String: Any]] = []
        bridge.onEvent = { events.append($0) }
        bridge.start(projectRoot: root, provider: "codex", cwd: root)
        defer { bridge.close() }
        try await wait("fixture ready") { events.contains { $0["type"] as? String == "ready" } }
        bridge.send(["type": "sessions", "requestId": "silent"])
        try await wait("correlated timeout") { events.contains { $0["type"] as? String == "error" && $0["requestId"] as? String == "silent" } }
        bridge.send(["type": "sessions", "requestId": "reused"])
        try await Task.sleep(nanoseconds: 125_000_000)
        bridge.send(["type": "sessions", "requestId": "reused"])
        try await wait("replacement request response") { events.contains { $0["type"] as? String == "sessions" && $0["requestId"] as? String == "reused" } }
        try await Task.sleep(nanoseconds: 170_000_000)
        try require(!events.contains { $0["type"] as? String == "error" && $0["requestId"] as? String == "reused" }, "a stale timeout rejected a replacement or completed request")
    }

    private static func checkControls() throws {
        let controller = AgentHistoryController()
        controller.view.frame = NSRect(x: 0, y: 0, width: 360, height: 418)
        func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
        func named(_ id: String) -> NSView? { views(controller.view).first { $0.accessibilityIdentifier() == id } }
        let table = named("rex-agent.history-list") as! NSTableView
        let resume = named("rex-agent.resume") as! NSButton
        let refresh = named("rex-agent.history-refresh") as! NSButton
        try require(named("rex-agent.history-recover") is NSButton, "explicit older-session recovery action is missing")
        var selected: AgentHistorySession?
        var requests = 0
        controller.onResume = { selected = $0 }
        var repairRequested = false
        controller.onRequest = { _, _, repair in requests += 1; repairRequested = repair }
        controller.request()
        try require(!resume.isEnabled && !refresh.isEnabled, "loading controls did not disable unavailable actions")
        controller.showError("Fixture connection failed")
        try require(refresh.isEnabled && refresh.title == "Retry", "history failure has no visible Retry")
        refresh.performClick(nil)
        try require(requests == 2, "Retry did not request history again")
        try require(!repairRequested, "normal Refresh requested an expensive recovery scan")
        let session = AgentHistorySession(["id": "saved-session", "provider": "claude", "title": "Saved fixture conversation", "cwd": "/fixture", "updatedAt": 1_700_000_000_000.0])!
        controller.update([session], nextCursor: nil, append: false)
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        try require(resume.isEnabled && resume.title == "Resume in this pane", "native Resume is not discoverable/enabled after selection")
        resume.performClick(nil)
        try require(selected?.id == session.id && selected?.provider == session.provider, "Resume selected the wrong native session")
        controller.update([], nextCursor: nil, append: false)
        try require(!resume.isEnabled, "empty history left Resume enabled")
        try require((named("rex-agent.history-status") as! NSTextField).stringValue.contains("All projects"), "empty project history did not explain how to find other conversations")
        (named("rex-agent.history-recover") as! NSButton).performClick(nil)
        try require(repairRequested, "explicit recovery did not request the older-session scan")
    }

    private static func wait(_ label: String, seconds: TimeInterval = 4, until condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            try require(Date() < deadline, "timed out: \(label)")
            try await Task.sleep(nanoseconds: 25_000_000)
        }
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw NSError(domain: "HistoryCheck", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
}
