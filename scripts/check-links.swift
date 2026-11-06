import Foundation

@main
struct LinkCheck {
    static func main() async {
        do {
            try await check()
            print("PASS local link parsing, editor arguments, and fake Rex split")
        } catch {
            fputs("FAIL: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    static func check() async throws {
        let cwd = "/tmp/project with spaces"
        try expect(AgentLinks.resolve("src/Main.swift:12:3", cwd: cwd), path: cwd + "/src/Main.swift", line: 12, column: 3)
        try expect(AgentLinks.resolve("README:8", cwd: cwd), path: cwd + "/README", line: 8)
        try expect(AgentLinks.resolve("./docs/My%20File.md#L3", cwd: cwd), path: cwd + "/docs/My File.md", line: 3)
        try expect(AgentLinks.resolve("../shared/file.swift", cwd: cwd), path: "/tmp/shared/file.swift")
        try expect(AgentLinks.resolve("file://localhost/tmp/a%20b.swift#L20C7", cwd: cwd), path: "/tmp/a b.swift", line: 20, column: 7)
        try expect(AgentLinks.resolve(URL(string: "file:///tmp/a%20b.swift:9:2")!, cwd: cwd), path: "/tmp/a b.swift", line: 9, column: 2)
        try expect(AgentLinks.resolve("docs/draft%23one.md#L4-L9", cwd: cwd), path: cwd + "/docs/draft#one.md", line: 4)
        try require(try AgentLinks.resolve("https://example.com/a:12#L3", cwd: cwd) == nil, "HTTPS must keep browser handling")
        try require(try AgentLinks.resolve(URL(string: "http://example.com")!, cwd: cwd) == nil, "HTTP URL must keep browser handling")
        for value in ["javascript:alert(1)", "javascript:alert(1):12", "mailto:person@example.com", "vscode://file/tmp/a:12", "file://remote-host/tmp/a", "src/a.swift:0", "src/a.swift:1:0", "bad%ZZpath", "#L12"] {
            do {
                _ = try AgentLinks.resolve(value, cwd: cwd)
                throw CheckError.failed("Expected unsupported or invalid link to fail: \(value)")
            } catch is AgentLinkError {}
        }

        let file = AgentFileLink(url: URL(fileURLWithPath: "/tmp/a b.swift"), line: 12, column: 3)
        try require(try AgentLinks.editorArguments("nvim -u NONE", file: file)
                    == ["nvim", "-u", "NONE", "+call cursor(12,3)", "--", "/tmp/a b.swift"], "nvim cursor and path arguments")
        try require(try AgentLinks.editorArguments("'/opt/My Editor/nvim' -u '/tmp/config file'", file: file)
                    == ["/opt/My Editor/nvim", "-u", "/tmp/config file", "+call cursor(12,3)", "--", "/tmp/a b.swift"], "quoted EDITOR arguments")
        try require(try AgentLinks.editorArguments("emacs -nw", file: file)
                    == ["emacs", "-nw", "/tmp/a b.swift"], "other editors receive the literal absolute path")

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rex-agent-links-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let capture = root.appendingPathComponent("argv")
        let fakeRex = root.appendingPathComponent("rex")
        let fakeShell = root.appendingPathComponent("shell")
        try """
        #!/bin/sh
        printf '%s\\000' "$@" > "$REX_AGENT_LINK_CAPTURE"
        printf '{"block_ids":["block:editor-test"]}\\n'
        """.write(to: fakeRex, atomically: true, encoding: .utf8)
        try """
        #!/bin/sh
        printf '\\036REX_AGENT_EDITOR\\037nvim -u NONE\\036'
        """.write(to: fakeShell, atomically: true, encoding: .utf8)
        for url in [fakeRex, fakeShell] { try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path) }
        let settings = ["REX_AGENT_CLI": fakeRex.path, "REX_AGENT_LINK_CAPTURE": capture.path, "SHELL": fakeShell.path, "EDITOR": "ignored-editor"]
        let previous = ProcessInfo.processInfo.environment
        defer {
            for key in settings.keys {
                if let value = previous[key] { setenv(key, value, 1) } else { unsetenv(key) }
            }
        }
        for (key, value) in settings { setenv(key, value, 1) }

        let name = "a b;$(touch injected);`echo nope`.swift"
        let target = try AgentLinks.resolve(root.appendingPathComponent(name).path + ":31:4", cwd: root.path)!
        let block: String = try await withCheckedThrowingContinuation { continuation in
            AgentLinks.open(target, cwd: root.path, sessionID: "session:test", blockID: "block:agent") {
                continuation.resume(with: $0)
            }
        }
        try require(block == "block:editor-test", "new editor pane ID")
        let arguments = try Data(contentsOf: capture).split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
        try require(arguments == ["split", "-s", "session:test", "-b", "block:agent", "--split=right", "--ratio", "40", "-c", root.path,
                                  "--json", "--", "nvim", "-u", "NONE", "+call cursor(31,4)", "--", root.appendingPathComponent(name).path],
                    "Rex must receive separate, literal argv values anchored to the agent pane")
        try require(!FileManager.default.fileExists(atPath: root.appendingPathComponent("injected").path), "link text must not execute")
    }

    static func expect(_ actual: AgentFileLink?, path: String, line: Int? = nil, column: Int? = nil) throws {
        try require(actual == AgentFileLink(url: URL(fileURLWithPath: path), line: line, column: column), "Resolved file location: \(path)")
    }
    static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw CheckError.failed(message) }
    }
    enum CheckError: LocalizedError {
        case failed(String)
        var errorDescription: String? { switch self { case .failed(let message): return message } }
    }
}
