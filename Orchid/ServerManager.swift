import Foundation
import Darwin
import Combine

final class ServerManager: ObservableObject {
    static let shared = ServerManager()

    enum State { case stopped, starting, running, stopping }

    @Published var serverState: State = .stopped
    @Published var activeModel: String = ""     // config key, e.g. "glm-ocr"
    private(set) var activeModelPath: String = "" // actual path sent to server
    private(set) var activePort: Int = 14416

    private var process: Process?
    private var pollTask: Task<Void, Never>?
    private var logHandle: FileHandle?

    private init() {}

    // MARK: - Public API

    func start(model: String, config: OrchidConfig) {
        guard let modelPath = config.modelPath(for: model) else {
            print("ServerManager: unknown model key '\(model)'")
            return
        }

        let port = findAvailablePort(starting: config.preferredPort)
        activePort = port

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: OrchidConfig.bundledServerPath)
        proc.arguments = [
            "--model-dir", modelPath,
            "--host", "127.0.0.1",
            "--port", "\(port)",
        ]

        var env = ProcessInfo.processInfo.environment
        env["RUST_LOG"] = "info"
        proc.environment = env

        let orchidDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".orchid").path
        proc.currentDirectoryURL = URL(fileURLWithPath: orchidDir)

        // Redirect subprocess output to a log file instead of inheriting the
        // parent's file descriptors, which can trigger extra TCC prompts.
        let logDir = orchidDir + "/logs"
        try? FileManager.default.createDirectory(atPath: logDir,
            withIntermediateDirectories: true)
        let logPath = logDir + "/server.log"
        FileManager.default.createFile(atPath: logPath, contents: nil)
        if let handle = FileHandle(forWritingAtPath: logPath) {
            logHandle = handle
            proc.standardOutput = handle
            proc.standardError = handle
        }

        proc.terminationHandler = { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.serverState != .stopping {
                    self.serverState = .stopped
                }
            }
        }

        process = proc
        try! proc.run()

        DispatchQueue.main.async {
            self.activeModel = model
            self.activeModelPath = modelPath
            self.serverState = .starting
        }

        pollTask = Task {
            await pollUntilReady(port: port)
        }
    }

    func switchModel(to model: String, config: OrchidConfig) {
        guard model != activeModel else { return }
        DispatchQueue.main.async { self.serverState = .stopping }

        pollTask?.cancel()
        pollTask = nil

        let deadlineProc = process
        process = nil

        Task.detached { [weak self] in
            guard let self else { return }
            if let p = deadlineProc, p.isRunning {
                p.terminate()
                // Wait up to 5s for graceful exit
                let deadline = Date().addingTimeInterval(5)
                while p.isRunning && Date() < deadline {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                if p.isRunning {
                    p.interrupt()   // SIGKILL equivalent via Process
                    kill(p.processIdentifier, SIGKILL)
                }
            }
            await MainActor.run {
                self.serverState = .stopped
            }
            self.start(model: model, config: config)
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        if let p = process, p.isRunning {
            p.terminate()
            let deadline = Date().addingTimeInterval(5)
            while p.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.1)
            }
            if p.isRunning {
                kill(p.processIdentifier, SIGKILL)
            }
        }
        process = nil
        DispatchQueue.main.async { self.serverState = .stopped }
    }

    // MARK: - Private helpers

    private struct HealthResponse: Decodable {
        var status: String
    }

    private func pollUntilReady(port: Int) async {
        let url = URL(string: "http://127.0.0.1:\(port)/health")!
        let session = URLSession(configuration: .ephemeral)
        let deadline = Date().addingTimeInterval(60)
        while !Task.isCancelled && Date() < deadline {
            do {
                let (data, response) = try await session.data(from: url)
                if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                   let health = try? JSONDecoder().decode(HealthResponse.self, from: data),
                   health.status == "ok" {
                    await MainActor.run { self.serverState = .running }
                    return
                }
            } catch {
                // not ready yet
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        // timed out or cancelled – leave state as-is
    }

    private func findAvailablePort(starting port: Int) -> Int {
        for candidate in port...(port + 20) {
            if isPortFree(candidate) { return candidate }
        }
        return port
    }

    private func isPortFree(_ port: Int) -> Bool {
        let sock = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { return false }
        defer { Darwin.close(sock) }

        var reuse: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }
}
