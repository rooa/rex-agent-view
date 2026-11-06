import Foundation

struct AgentFileLink: Equatable {
    let url: URL
    let line: Int?
    let column: Int?
}

enum AgentLinkError: LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        switch self { case .invalid(let message): return message }
    }
}

enum AgentLinks {
    /// nil leaves HTTP(S) links to NSTextView's ordinary browser handling.
    static func resolve(_ link: Any, cwd: String) throws -> AgentFileLink? {
        let raw: String
        if let url = link as? URL { raw = url.absoluteString }
        else if let text = link as? String { raw = text }
        else { throw AgentLinkError.invalid("This link is not a file path or URL.") }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains("\0") else { throw AgentLinkError.invalid("The file link is empty or invalid.") }

        let scheme = captures(#"^([A-Za-z][A-Za-z0-9+.-]*):"#, text)?.first?.lowercased()
        if scheme == "http" || scheme == "https" { return nil }

        var path: String
        var fragment: String?
        if scheme == "file" {
            guard let parts = URLComponents(string: text),
                  parts.host == nil || parts.host == "" || parts.host?.lowercased() == "localhost" else {
                throw AgentLinkError.invalid("Only local file URLs can open in the editor.")
            }
            path = parts.percentEncodedPath
            fragment = parts.fragment
        } else {
            let parts = text.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
            path = String(parts[0])
            fragment = parts.count > 1 ? String(parts[1]).removingPercentEncoding : nil
        }

        var line: Int?
        var column: Int?
        if let position = captures(#"^(.+?):([0-9]+)(?::([0-9]+))?$"#, path) {
            path = position[0]
            line = try positive(position[1])
            column = position.count > 2 && !position[2].isEmpty ? try positive(position[2]) : nil
        }
        // A numeric suffix is a file position, including extensionless paths such
        // as README:12. Other URI schemes never reach a shell or NSWorkspace.
        if let scheme, scheme != "file",
           line == nil || text.lowercased().hasPrefix(scheme + "://") || captures(#"^([A-Za-z][A-Za-z0-9+.-]*):"#, path) != nil {
            throw AgentLinkError.invalid("Unsupported link scheme: \(scheme).")
        }
        if let fragment, let position = captures(#"^L([0-9]+)(?:(?:C|:)([0-9]+))?(?:-L[0-9]+)?$"#, fragment) {
            line = try positive(position[0])
            column = position.count > 1 && !position[1].isEmpty ? try positive(position[1]) : nil
        }
        guard let decoded = path.removingPercentEncoding, !decoded.isEmpty, !decoded.contains("\0") else {
            throw AgentLinkError.invalid("The file link has an invalid path.")
        }
        let expanded = (decoded as NSString).expandingTildeInPath
        let base = URL(fileURLWithPath: cwd, isDirectory: true)
        let url = expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded)
            : base.appendingPathComponent(expanded)
        return AgentFileLink(url: url.standardizedFileURL, line: line, column: column)
    }

    /// Resolves the user's editor off the main thread and sends separate argv
    /// values to Rex. Link text is never interpolated into a shell command.
    static func open(_ file: AgentFileLink, cwd: String, sessionID: String, blockID: String,
                     completion: @escaping @MainActor (Result<String, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result: Result<String, Error>
            do {
                let environment = ProcessInfo.processInfo.environment
                let editor = loginEditor(environment: environment, cwd: cwd)
                let command = try editorArguments(editor, file: file)
                let arguments = splitArguments(command: command, cwd: cwd, sessionID: sessionID, blockID: blockID)
                let executable = environment["REX_AGENT_CLI"] ?? "/opt/homebrew/bin/rex"
                let output = try run(executable, arguments: arguments, cwd: cwd)
                guard let json = try JSONSerialization.jsonObject(with: output) as? [String: Any],
                      let block = (json["block_ids"] as? [String])?.first else {
                    throw AgentLinkError.invalid("Rex opened the editor but returned no pane identifier.")
                }
                result = .success(block)
            } catch { result = .failure(error) }
            DispatchQueue.main.async { completion(result) }
        }
    }

    static func splitArguments(command: [String], cwd: String, sessionID: String, blockID: String) -> [String] {
        ["split", "-s", sessionID, "-b", blockID, "--split=right", "--ratio", "40", "-c", cwd, "--json", "--"] + command
    }

    static func editorArguments(_ setting: String, file: AgentFileLink) throws -> [String] {
        var command = try words(setting)
        if command.isEmpty { command = ["nvim"] }
        let name = URL(fileURLWithPath: command[0]).lastPathComponent.lowercased()
        if ["nvim", "vim", "vi"].contains(name) {
            if let line = file.line {
                command.append(file.column.map { "+call cursor(\(line),\($0))" } ?? "+\(line)")
            }
            command.append("--")
        }
        command.append(file.url.path)
        return command
    }

    private static func loginEditor(environment: [String: String], cwd: String) -> String {
        let fallback = environment["EDITOR"].flatMap { $0.isEmpty ? nil : $0 } ?? "nvim"
        let shell = environment["SHELL"] ?? "/bin/zsh"
        // Interactive login mode includes the user's .zshrc exports. A fixed
        // marker isolates EDITOR from harmless shell startup output.
        let script = "printf '\\036REX_AGENT_EDITOR\\037%s\\036' \"${EDITOR:-}\""
        guard let data = try? run(shell, arguments: ["-lic", script], cwd: cwd, quiet: true, timeout: 4),
              let output = String(data: data, encoding: .utf8),
              let marker = output.range(of: "\u{1e}REX_AGENT_EDITOR\u{1f}", options: .backwards),
              let end = output[marker.upperBound...].firstIndex(of: "\u{1e}") else { return fallback }
        let editor = String(output[marker.upperBound..<end])
        return editor.isEmpty ? fallback : editor
    }

    /// Shell-style quoting for EDITOR's executable and flags, without expansion.
    /// Even metacharacters are argv data; there is no eval or sh -c of this value.
    private static func words(_ text: String) throws -> [String] {
        var result: [String] = [], word = ""
        var quote: Character?, escaped = false, started = false
        for character in text {
            if escaped { word.append(character); escaped = false; started = true; continue }
            if character == "\\" && quote != "'" { escaped = true; started = true; continue }
            if let current = quote {
                if character == current { quote = nil } else { word.append(character) }
                continue
            }
            if character == "'" || character == "\"" { quote = character; started = true }
            else if character.isWhitespace {
                if started { result.append(word); word = ""; started = false }
            } else { word.append(character); started = true }
        }
        guard quote == nil, !escaped else { throw AgentLinkError.invalid("EDITOR contains an unfinished quote or escape.") }
        if started { result.append(word) }
        guard result.first != "" else { throw AgentLinkError.invalid("EDITOR has an empty executable name.") }
        return result
    }

    private static func captures(_ pattern: String, _ text: String) -> [String]? {
        let expression = try! NSRegularExpression(pattern: pattern)
        guard let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (1..<match.numberOfRanges).map { index in
            Range(match.range(at: index), in: text).map { String(text[$0]) } ?? ""
        }
    }

    private static func positive(_ text: String) throws -> Int {
        guard let value = Int(text), value > 0 else { throw AgentLinkError.invalid("File line and column numbers must be positive integers.") }
        return value
    }

    private static func run(_ executable: String, arguments: [String], cwd: String? = nil,
                            quiet: Bool = false, timeout: TimeInterval? = nil) throws -> Data {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        // Rex errors share the capture pipe. A successful Rex call emits JSON;
        // shell startup diagnostics are never surfaced to the UI.
        process.standardError = quiet ? FileHandle.nullDevice : output
        try process.run()
        let cancellation = DispatchWorkItem { if process.isRunning { process.terminate() } }
        if let timeout { DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: cancellation) }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        cancellation.cancel()
        guard process.terminationStatus == 0 else {
            let detail = quiet ? "" : String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw AgentLinkError.invalid(detail.isEmpty ? "Could not start the editor (exit \(process.terminationStatus))." : detail)
        }
        return data
    }
}
