import AppKit
import ObjectiveC.runtime

// Synthetic visibility/focus lets the production attachment loop run without
// showing or activating windows, invoking Rex, or starting provider processes.
@MainActor
private final class AttachmentApplication: NSApplication {
    var fixtureWindows: [NSWindow] = []
    weak var fixtureKeyWindow: NSWindow?
    override var windows: [NSWindow] { fixtureWindows }
    override var keyWindow: NSWindow? { fixtureKeyWindow }
    override func activate(ignoringOtherApps flag: Bool) {}
}

@MainActor
private final class AttachmentWindow: NSWindow {
    var fixtureVisible = true
    var fixtureNumber = 0
    override var isVisible: Bool { fixtureVisible }
    override var windowNumber: Int { fixtureNumber }
}

@main
@MainActor
struct AttachmentCheck {
    static func main() {
        let root = CommandLine.arguments[1]
        do {
            try FileManager.default.createDirectory(atPath: root + "/build", withIntermediateDirectories: true)
            let stub = """
            #!/bin/sh
            if [ "$1" = ls ]; then
              cat "$REX_AGENT_ROOT/sessions.json"
            elif [ "$1" = client ]; then
              cat "$REX_AGENT_ROOT/clients.json"
            elif [ "$1" = session ] && [ "$3" = session:project ]; then
              printf 'inspect\\n' >> "$REX_AGENT_ROOT/calls.log"
              cat "$REX_AGENT_ROOT/state.json"
            elif [ "$1" = block ] && [ "$4" = session:project ] && [ "$6" = block:agent ]; then
              printf 'process\\n' >> "$REX_AGENT_ROOT/calls.log"
              cat "$REX_AGENT_ROOT/process.json"
            else
              exit 2
            fi
            """
            try stub.write(toFile: root + "/rex", atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root + "/rex")
            setenv("REX_AGENT_ROOT", root, 1)
            setenv("REX_AGENT_CLI", root + "/rex", 1)
            setenv("REX_AGENT_SESSION", "session:launch", 1)
            try write(["sessions": [["session_id": "session:launch", "label": "rex-agent"],
                                     ["session_id": "session:project", "label": "ceobench"]]], to: root + "/sessions.json")
            try write(["clients": [["client_id": "client:fixture", "info": ["kind": "app"],
                                    "principal": ["pid": getpid()], "connection_state": "connected"]]], to: root + "/clients.json")
            try writeState(root, closed: false)
            try write(["home": "/must-not-use-home"], to: root + "/process.json")

            let app = AttachmentApplication.shared as! AttachmentApplication
            app.setActivationPolicy(.prohibited)
            app.mainMenu = NSMenu(title: "Attachment fixture")
            guard let surfaceClass = objc_allocateClassPair(NSView.self, "GhosttyTerminal.SurfaceView", 0) else {
                throw failure("could not create fixture surface class")
            }
            objc_registerClassPair(surfaceClass)
            let surfaceType = surfaceClass as! NSView.Type
            func makeWindow(_ number: Int) -> (AttachmentWindow, NSView) {
                let window = AttachmentWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 260),
                                              styleMask: [.titled], backing: .buffered, defer: false)
                window.fixtureNumber = number
                window.title = "Terminal - ceobench"
                let host = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 260))
                window.contentView = host
                host.addSubview(surfaceType.init(frame: host.bounds))
                return (window, host)
            }
            let (first, firstHost) = makeWindow(101)
            let (second, secondHost) = makeWindow(102)
            app.fixtureWindows = [first, second]
            app.fixtureKeyWindow = first
            AgentPaneHost.shared.start()

            Task { @MainActor in
                do {
                    try await wait("cwd lookup retries") { calls(root, "process") >= 2 }
                    try require(cachedBlocks().isEmpty && mounted(firstHost) == nil && mounted(secondHost) == nil,
                                "pane mounted with a missing cwd or repository/home fallback")
                    try write(["child": ["cwd": root]], to: root + "/process.json")
                    try await wait("new-session native pane attachment") { mounted(firstHost) != nil }
                    let pane = mounted(firstHost)!
                    try require(cachedBlocks() == ["block:agent"], "agent was not cached under its actual block")
                    print("PASS non-launch session mounts only after actual cwd becomes available")

                    app.fixtureKeyWindow = nil
                    app.fixtureWindows = [second, first]
                    try await Task.sleep(nanoseconds: 1_300_000_000)
                    try require(mounted(firstHost) === pane && mounted(secondHost) == nil,
                                "same-session windows reparented the pane without a focus change")
                    try require(attachments(root) == 1, "stable host repeatedly detached and reattached its pane")
                    app.fixtureKeyWindow = second
                    try await wait("focused second window reuses the native pane") { mounted(secondHost) === pane }
                    try require(mounted(firstHost) == nil && cachedBlocks().count == 1,
                                "focus migration duplicated the view or its block cache")
                    print("PASS same-session host stays stable and focus migration reuses one view")

                    try await wait("session inspection settles") { fetchingSessions().isEmpty }
                    first.fixtureVisible = false
                    second.fixtureVisible = false
                    app.fixtureKeyWindow = nil
                    try writeState(root, closed: true)
                    let inspections = calls(root, "inspect")
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                    try require(cachedBlocks().contains("block:agent"), "hiding a session discarded its live pane immediately")
                    try await wait("hidden closed block cleanup", seconds: 12) { cachedBlocks().isEmpty }
                    try require(pane.superview == nil, "closed hidden pane remained attached")
                    try require(calls(root, "inspect") - inspections <= 2, "hidden session cleanup polls at the visible-session rate")
                    print("PASS slower hidden-session refresh removes a closed block without rapid polling")
                    exit(0)
                } catch {
                    fputs("FAIL: \(error.localizedDescription)\n", stderr)
                    fputs("Fixture windows: \(NSApp.windows.map { ($0.title, $0.isVisible) })\n", stderr)
                    fputs("Fixture surface: \(firstHost.subviews.map { (NSStringFromClass(type(of: $0)), $0.visibleRect, $0.isHiddenOrHasHiddenAncestor) })\n", stderr)
                    for name in ["calls.log", "build/native.log"] {
                        if let text = try? String(contentsOfFile: root + "/" + name, encoding: .utf8) { fputs("\(name): \(text.suffix(3000))\n", stderr) }
                    }
                    exit(1)
                }
            }
            app.run()
        } catch {
            fputs("FAIL: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func write(_ value: [String: Any], to path: String) throws {
        try JSONSerialization.data(withJSONObject: value).write(to: URL(fileURLWithPath: path), options: .atomic)
    }
    private static func writeState(_ root: String, closed: Bool) throws {
        let window: [String: Any] = ["window_id": "window:project", "layers": [["kind": "tiled",
            "layout": ["block_id": "block:agent", "rect": [0, 0, 1, 1]],
            "blocks": [["block_id": "block:agent", "label": "rex-agent:Agent"]]]]]
        try write(["label": "ceobench", "active_window_id": "window:project", "windows": closed ? [] : [window]],
                  to: root + "/state.json")
    }
    private static func mounted(_ host: NSView) -> NSView? {
        host.subviews.first { view in view.subviews.contains { ($0 as? NSTextField)?.stringValue.contains("block:agent") == true } }
    }
    private static func property(_ name: String) -> Any? {
        Mirror(reflecting: AgentPaneHost.shared).children.first { $0.label == name }?.value
    }
    private static func cachedBlocks() -> Set<String> {
        Set((property("viewsByBlock") as? [String: (sessionID: String, view: NSView)] ?? [:]).keys)
    }
    private static func fetchingSessions() -> Set<String> { property("fetching") as? Set<String> ?? [] }
    private static func calls(_ root: String, _ kind: String) -> Int {
        ((try? String(contentsOfFile: root + "/calls.log", encoding: .utf8)) ?? "").split(separator: "\n").filter { $0 == kind }.count
    }
    private static func attachments(_ root: String) -> Int {
        ((try? String(contentsOfFile: root + "/build/native.log", encoding: .utf8)) ?? "").components(separatedBy: "Attached native view").count - 1
    }
    private static func wait(_ label: String, seconds: Double = 4, until condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            try require(Date() < deadline, "timed out: \(label)")
            try await Task.sleep(nanoseconds: 30_000_000)
        }
    }
    private static func failure(_ message: String) -> NSError {
        NSError(domain: "AttachmentCheck", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
    private static func require(_ value: Bool, _ message: String) throws { if !value { throw failure(message) } }
}
