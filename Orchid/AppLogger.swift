import Foundation
import OSLog

final class AppLogger: @unchecked Sendable {
    static let shared = AppLogger()

    private let lock = NSLock()
    private let systemLogger = Logger(subsystem: "com.blossom-slopware.orchid", category: "app")
    private var fileHandle: FileHandle?
    private var isBootstrapped = false

    private init() {}

    func bootstrap() {
        lock.lock()
        defer { lock.unlock() }

        if isBootstrapped {
            return
        }

        let logDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".orchid/logs")
        try! FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)

        let logFileURL = logDir.appendingPathComponent("app.log")
        if !FileManager.default.fileExists(atPath: logFileURL.path) {
            FileManager.default.createFile(atPath: logFileURL.path, contents: nil)
        }

        let handle = try! FileHandle(forWritingTo: logFileURL)
        try! handle.seekToEnd()
        fileHandle = handle
        isBootstrapped = true
    }

    func debug(_ message: @autoclosure () -> String, category: String = "app") {
        log(level: "DEBUG", category: category, message: message())
    }

    func info(_ message: @autoclosure () -> String, category: String = "app") {
        log(level: "INFO", category: category, message: message())
    }

    func warning(_ message: @autoclosure () -> String, category: String = "app") {
        log(level: "WARN", category: category, message: message())
    }

    func error(_ message: @autoclosure () -> String, category: String = "app") {
        log(level: "ERROR", category: category, message: message())
    }

    private func log(level: String, category: String, message: String) {
        lock.lock()
        defer { lock.unlock() }

        precondition(isBootstrapped, "AppLogger.bootstrap() must be called before logging")

        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(timestamp)] [\(level)] [\(category)] \(message)\n"
        let data = line.data(using: .utf8)!
        try! fileHandle!.write(contentsOf: data)

        switch level {
        case "DEBUG":
            systemLogger.debug("\(line, privacy: .public)")
        case "INFO":
            systemLogger.info("\(line, privacy: .public)")
        case "WARN":
            systemLogger.warning("\(line, privacy: .public)")
        case "ERROR":
            systemLogger.error("\(line, privacy: .public)")
        default:
            systemLogger.log("\(line, privacy: .public)")
        }
    }
}
