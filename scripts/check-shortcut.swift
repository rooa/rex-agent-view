import AppKit

// Keep the event's key-window context stable while the user works in other apps.
// AppKit still dispatches the posted events through the production local monitor.
@MainActor
private final class ShortcutApplication: NSApplication {
    weak var checkWindow: NSWindow?
    override var keyWindow: NSWindow? { checkWindow }
}

@main
@MainActor
struct ShortcutCheck {
    static func main() {
        let root = CommandLine.arguments[1]
        do {
            try FileManager.default.createDirectory(atPath: root + "/build", withIntermediateDirectories: true)
            let stub = """
            #!/bin/sh
            if [ -n "$REX_SESSION" ] || [ -n "$REX_BLOCK" ]; then exit 3; fi
            if [ "$1" = ls ]; then
              cat "$REX_AGENT_ROOT/sessions.json"
            elif [ "$1" = client ]; then
              cat "$REX_AGENT_ROOT/clients.json"
            elif [ "$1" = session ]; then
              if [ "$3" = session:second ]; then cat "$REX_AGENT_ROOT/second.json"; else cat "$REX_AGENT_ROOT/state.json"; fi
            elif [ "$1" = split ] || [ "$1" = -C ]; then
              printf '%s\\n' "$*" >> "$REX_AGENT_ROOT/splits.log"
              printf '{"block_ids":["block:new"]}\\n'
            elif [ "$1" = block ]; then
              printf '{"child":{"cwd":"/Projects/ceobench"}}\\n'
            else
              exit 2
            fi
            """
            try stub.write(toFile: root + "/rex", atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root + "/rex")
            setenv("REX_AGENT_ROOT", root, 1)
            setenv("REX_AGENT_CLI", root + "/rex", 1)
            setenv("REX_AGENT_SESSION", "session:test", 1)
            setenv("REX_AGENT_WINDOW", "window:initial", 1)
            setenv("REX_SESSION", "session:stale-parent", 1)
            setenv("REX_BLOCK", "block:stale-parent", 1)
            try "{\"sessions\":[{\"session_id\":\"session:test\",\"label\":\"rex-agent\"},{\"session_id\":\"session:second\",\"label\":\"ceobench\"}]}".write(toFile: root + "/sessions.json", atomically: true, encoding: .utf8)
            let clients: [[String: Any]] = [
                ["client_id": "client:stale-app", "info": ["kind": "app", "name": "Rex Agent View"], "principal": ["pid": Int(getpid())], "connection_state": "disconnected"],
                ["client_id": "client:own-app", "info": ["kind": "app", "name": "Rex Agent View"], "principal": ["pid": Int(getpid())], "connection_state": "connected"],
            ]
            try JSONSerialization.data(withJSONObject: ["clients": clients]).write(to: URL(fileURLWithPath: root + "/clients.json"))
            try writeState(root: root, includeInitial: false, second: true)

            let app = ShortcutApplication.shared as! ShortcutApplication
            app.setActivationPolicy(.accessory)
            app.mainMenu = NSMenu(title: "Shortcut test")
            let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 420, height: 180),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.title = "Ordinary terminal - rex-agent"
            window.contentView = NSView(frame: window.contentLayoutRect)
            app.checkWindow = window
            window.makeKeyAndOrderFront(nil)
            try writeState(root: root, includeInitial: true)
            AgentPaneHost.shared.start()

            Task { @MainActor in
                do {
                    try await wait("menu and key window") { agentMenu() != nil && app.keyWindow === window }
                    key(window)
                    try await wait("shortcut in an ordinary tab before any agent view mounted") { splitCount(root) == 1 }
                    let split = try String(contentsOfFile: root + "/splits.log", encoding: .utf8)
                    try require(!split.split(separator: " ").contains("-b"), "shortcut pinned a stale focused block")
                    key(window, repeat: true)
                    try await Task.sleep(nanoseconds: 450_000_000)
                    try require(splitCount(root) == 1, "Cmd+Shift+A dispatched more than once")
                    print("PASS ordinary tab; one shortcut dispatch; key repeat ignored")

                    window.title = "zsh /Projects/ceobench - ceobench"
                    try await Task.sleep(nanoseconds: 650_000_000)
                    key(window)
                    try await wait("shortcut in another existing session") { splitCount(root) == 2 }
                    let routed = try String(contentsOfFile: root + "/splits.log", encoding: .utf8)
                    try require(routed.split(separator: "\n").last == "-C client:own-app do rex_agent_new_pane -s session:second app_client_id=client:own-app", "shortcut did not dispatch the context-aware action through its own app client")
                    print("PASS another session routes through the same app's registered action")

                    window.title = "Ordinary terminal - rex-agent"
                    try writeState(root: root, includeInitial: false)
                    try await Task.sleep(nanoseconds: 500_000_000)
                    key(window)
                    try await wait("shortcut after the initial workspace was deleted") { splitCount(root) == 3 }
                    print("PASS deleted initial workspace")

                    window.title = "Terminal - unrelated-session"
                    key(window)
                    try await Task.sleep(nanoseconds: 500_000_000)
                    try require(splitCount(root) == 3, "shortcut mutated an unresolved window")
                    print("PASS unresolved window rejected")
                    guard let submenu = agentMenu()?.submenu,
                          let appearance = submenu.items.first(where: { $0.title == "Appearance…" }) else {
                        throw NSError(domain: "ShortcutCheck", code: 1, userInfo: [NSLocalizedDescriptionKey: "Agent Appearance menu is missing"])
                    }
                    submenu.update()
                    try require(appearance.isEnabled, "Appearance was disabled in another session")
                    app.checkWindow = nil
                    submenu.update()
                    try require(appearance.isEnabled, "Appearance was disabled without a key window")
                    app.checkWindow = window
                    print("PASS Appearance available outside the agent session and without a key window")

                    window.title = "Ordinary terminal - rex-agent"
                    app.mainMenu = NSMenu(title: "Replaced by SwiftUI")
                    try await wait("Agent menu reinstalled after main menu replacement") { agentMenu() != nil }
                    try require(agentMenu()?.submenu?.items.contains(where: { $0.title == "Appearance…" }) == true, "Appearance was lost after menu replacement")
                    key(window)
                    try await wait("shortcut after menu replacement") { splitCount(root) == 4 }
                    try await Task.sleep(nanoseconds: 450_000_000)
                    try require(splitCount(root) == 4, "replacement menu duplicated shortcut dispatch")
                    print("PASS main menu replacement; one shortcut dispatch")
                    agentMenu()?.submenu?.performActionForItem(at: 0)
                    try await wait("New Agent Pane menu action") { splitCount(root) == 5 }
                    print("PASS menu action")
                    window.close()
                    exit(0)
                } catch {
                    fputs("FAIL: \(error)\n", stderr)
                    window.close()
                    exit(1)
                }
            }
            app.run()
        } catch {
            fputs("FAIL: \(error)\n", stderr)
            exit(1)
        }
    }

    private static func agentMenu() -> NSMenuItem? {
        NSApp.mainMenu?.items.first(where: { $0.title == "Agent" })
    }

    private static func key(_ window: NSWindow, repeat repeating: Bool = false) {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .shift],
                                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                    context: nil, characters: "A", charactersIgnoringModifiers: "A",
                                    isARepeat: repeating, keyCode: 0)!
        NSApp.postEvent(event, atStart: false)
    }

    private static func splitCount(_ root: String) -> Int {
        ((try? String(contentsOfFile: root + "/splits.log", encoding: .utf8)) ?? "").split(separator: "\n").count
    }

    private static func writeState(root: String, includeInitial: Bool, second: Bool = false) throws {
        func window(_ id: String) -> [String: Any] {
            let block = id == "window:initial" ? "block:initial" : "block:shell"
            return ["window_id": id, "label": "Terminal", "focused_block_id": block,
                    "layers": [["kind": "tiled", "layout": ["block_id": block, "rect": [0, 0, 1, 1]],
                                "blocks": [["block_id": block, "label": "shell"]]]]]
        }
        var windows = [window("window:ordinary")]
        if includeInitial { windows.append(window("window:initial")) }
        let data = try JSONSerialization.data(withJSONObject: ["label": second ? "ceobench" : "rex-agent", "active_window_id": "window:ordinary", "windows": windows])
        try data.write(to: URL(fileURLWithPath: root + (second ? "/second.json" : "/state.json")), options: .atomic)
    }

    private static func wait(_ label: String, until condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !condition() {
            try require(Date() < deadline, "timed out: \(label)")
            try await Task.sleep(nanoseconds: 30_000_000)
        }
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw NSError(domain: "ShortcutCheck", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
}
