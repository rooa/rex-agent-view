import AppKit
import Darwin

/// One bridge process owns one provider conversation, including its approvals.
@MainActor
final class AgentBridge {
    var onEvent: (([String: Any]) -> Void)?
    private var process: Process?
    private var input: FileHandle?
    private var output = Data()
    private var diagnostics = ""
    private var closing = false
    private let historyRequestTimeout: TimeInterval
    private var pendingHistory: [String: (token: UUID, timeout: DispatchWorkItem)] = [:]

    init(historyRequestTimeout: TimeInterval = 30) {
        self.historyRequestTimeout = historyRequestTimeout
    }

    func start(projectRoot: String, provider: String, cwd: String, paneKey: String? = nil) {
        let task = Process()
        let incoming = Pipe(), outgoing = Pipe(), errors = Pipe()
        task.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["REX_AGENT_NODE"] ?? "/opt/homebrew/bin/node")
        task.arguments = [projectRoot + "/bridge/main.mjs", "--provider", provider, "--cwd", cwd]
        if let paneKey { task.arguments?.append(contentsOf: ["--pane", paneKey]) }
        task.currentDirectoryURL = URL(fileURLWithPath: cwd)
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = [environment["PATH"] ?? "", "/opt/homebrew/bin", "/usr/local/bin", NSHomeDirectory() + "/.local/bin", "/usr/bin", "/bin"].joined(separator: ":")
        task.environment = environment
        task.standardInput = incoming
        task.standardOutput = outgoing
        task.standardError = errors
        input = incoming.fileHandleForWriting
        // A provider can exit between isRunning and write. Keep EPIPE local to
        // this descriptor instead of letting SIGPIPE terminate the Rex app.
        _ = fcntl(incoming.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        outgoing.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let bytes = handle.availableData
            if bytes.isEmpty { handle.readabilityHandler = nil; return }
            DispatchQueue.main.async { self?.consume(bytes) }
        }
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let bytes = handle.availableData
            if bytes.isEmpty { handle.readabilityHandler = nil; return }
            DispatchQueue.main.async {
                guard let self else { return }
                self.diagnostics = String((self.diagnostics + String(decoding: bytes, as: UTF8.self)).suffix(3000))
            }
        }
        task.terminationHandler = { [weak self] task in
            DispatchQueue.main.async {
                guard let self, !self.closing else { return }
                self.failPendingHistory("The agent connection closed while loading history. Start a new conversation to reconnect, then retry.")
                self.onEvent?(["type": "disconnected", "message": task.terminationStatus == 0 ? "Agent connection closed. Start a new conversation to reconnect." : "Agent connection exited (\(task.terminationStatus)). \(self.diagnostics)"])
            }
        }
        process = task
        do { try task.run() }
        catch { onEvent?(["type": "disconnected", "message": "Could not start the agent: \(error.localizedDescription)"]) }
    }

    func send(_ message: [String: Any]) {
        guard !closing, process?.isRunning == true, let input else {
            reportSendError("The agent connection is unavailable. Start a new conversation to reconnect, then retry.", message: message)
            return
        }
        do {
            var data = try JSONSerialization.data(withJSONObject: message)
            data.append(10)
            if message["type"] as? String == "sessions", let id = message["requestId"] as? String {
                watchHistory(id)
            }
            try input.write(contentsOf: data)
        } catch {
            if let id = message["requestId"] as? String { finishHistory(id) }
            reportSendError("Could not send to the agent: \(error.localizedDescription)", message: message)
        }
    }

    private func reportSendError(_ detail: String, message: [String: Any]) {
        var event: [String: Any] = ["type": "error", "message": detail]
        event["operation"] = message["type"]
        event["requestId"] = message["requestId"]
        onEvent?(event)
    }

    private func watchHistory(_ id: String) {
        finishHistory(id)
        let token = UUID()
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.pendingHistory[id]?.token == token else { return }
            self.finishHistory(id)
            self.onEvent?(["type": "error", "operation": "sessions", "requestId": id,
                           "message": "Loading conversations took too long. Retry to read the native history again."])
        }
        pendingHistory[id] = (token, timeout)
        DispatchQueue.main.asyncAfter(deadline: .now() + historyRequestTimeout, execute: timeout)
    }

    private func finishHistory(_ id: String) {
        pendingHistory.removeValue(forKey: id)?.timeout.cancel()
    }

    private func failPendingHistory(_ detail: String) {
        for id in Array(pendingHistory.keys) {
            finishHistory(id)
            onEvent?(["type": "error", "operation": "sessions", "requestId": id, "message": detail])
        }
    }

    private func consume(_ data: Data) {
        output.append(data)
        while let newline = output.firstIndex(of: 10) {
            let line = output[..<newline]
            output.removeSubrange(...newline)
            guard !line.isEmpty else { continue }
            do {
                if let event = try JSONSerialization.jsonObject(with: line) as? [String: Any] {
                    if let id = event["requestId"] as? String,
                       ["sessions", "error"].contains(event["type"] as? String ?? "") { finishHistory(id) }
                    onEvent?(event)
                }
            } catch {
                failPendingHistory("The agent returned an unreadable history response. Retry to load conversations again.")
                onEvent?(["type": "error", "message": "The agent returned an unreadable event."])
            }
        }
    }

    func close() {
        guard !closing else { return }
        if process?.isRunning == true { send(["type": "close"]) }
        closing = true
        for id in Array(pendingHistory.keys) { finishHistory(id) }
        try? input?.close()
        let task = process
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            if task?.isRunning == true { task?.terminate() }
        }
    }

    deinit { if process?.isRunning == true { process?.terminate() } }
}
