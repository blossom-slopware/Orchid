import Foundation
import HuggingFace

/// Downloads a HuggingFace model snapshot into Orchid's configured model
/// directory, using a local HF cache under `~/.orchid` for resume support.
final class HFModelDownloader: @unchecked Sendable {

    let repoId: String
    let finalModelDir: URL

    var onProgress: (@MainActor @Sendable (Progress) -> Void)?
    var onComplete: (@MainActor (Error?) -> Void)?

    private var downloadTask: Task<Void, Never>?
    private var logHandle: FileHandle?
    private var lastLoggedProgressPercent = -1

    init(repoId: String, finalModelDir: URL) {
        self.repoId = repoId
        self.finalModelDir = finalModelDir
    }

    func start() {
        downloadTask = Task.detached { [self] in
            do {
                try await self.run()
                await MainActor.run { self.onComplete?(nil) }
            } catch is CancellationError {
                self.log("download cancelled")
                self.cleanupStaging()
            } catch {
                self.log("download failed: \(error.localizedDescription)")
                self.cleanupStaging()
                await MainActor.run { self.onComplete?(error) }
            }
        }
    }

    func cancel() {
        downloadTask?.cancel()
    }

    // MARK: - Internal

    private var stagingDir: URL {
        finalModelDir
            .deletingLastPathComponent()
            .appendingPathComponent(finalModelDir.lastPathComponent + ".downloading")
    }

    private var cacheDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".orchid/hf-cache")
    }

    private var logFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".orchid/logs/download.log")
    }

    private func run() async throws {
        let fm = FileManager.default
        try prepareLogFile()
        defer { closeLogFile() }

        log("===== begin model download =====")
        log("repo=\(repoId)")
        log("staging_dir=\(stagingDir.path)")
        log("final_dir=\(finalModelDir.path)")
        log("cache_dir=\(cacheDir.path)")

        try fm.createDirectory(at: stagingDir, withIntermediateDirectories: true)

        let cache = HubCache(location: .fixed(directory: cacheDir))
        let client = HubClient(cache: cache)

        guard let repoID = Repo.ID(rawValue: repoId) else {
            log("invalid repo id: \(repoId)")
            throw DownloadError.validationFailed
        }

        _ = try await client.downloadSnapshot(
            of: repoID,
            kind: .model,
            to: stagingDir,
            revision: "main",
            progressHandler: { [self] progress in
                logProgress(progress)
                if let onProgress {
                    Task { @MainActor in
                        onProgress(progress)
                    }
                }
            }
        )

        try Task.checkCancellation()

        guard ModelValidator.isModelDirectoryReady(at: stagingDir) else {
            log("model validation failed after download")
            throw DownloadError.validationFailed
        }
        log("model validation passed")

        try Task.checkCancellation()

        // Atomic-ish swap: move old dir aside, move staging into place, remove old.
        let backupDir = finalModelDir
            .deletingLastPathComponent()
            .appendingPathComponent(finalModelDir.lastPathComponent + ".old")

        if fm.fileExists(atPath: backupDir.path) {
            try fm.removeItem(at: backupDir)
        }
        if fm.fileExists(atPath: finalModelDir.path) {
            log("moving existing model dir to backup: \(backupDir.path)")
            try fm.moveItem(at: finalModelDir, to: backupDir)
        }
        do {
            try fm.moveItem(at: stagingDir, to: finalModelDir)
        } catch {
            // Roll back: restore old directory if the move failed.
            if fm.fileExists(atPath: backupDir.path), !fm.fileExists(atPath: finalModelDir.path) {
                try? fm.moveItem(at: backupDir, to: finalModelDir)
            }
            throw error
        }
        try? fm.removeItem(at: backupDir)
        log("download finished successfully")
    }

    private func cleanupStaging() {
        log("cleaning staging dir: \(stagingDir.path)")
        try? FileManager.default.removeItem(at: stagingDir)
    }

    private func prepareLogFile() throws {
        let fm = FileManager.default
        let logDir = logFileURL.deletingLastPathComponent()
        try fm.createDirectory(at: logDir, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: logFileURL.path) {
            fm.createFile(atPath: logFileURL.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: logFileURL)
        try handle.seekToEnd()
        logHandle = handle
    }

    private func closeLogFile() {
        try? logHandle?.close()
        logHandle = nil
    }

    private func logProgress(_ progress: Progress) {
        guard progress.totalUnitCount > 0 else {
            if lastLoggedProgressPercent < 0 {
                lastLoggedProgressPercent = 0
                log("progress started: total size unknown")
            }
            return
        }

        let percent = Int(progress.fractionCompleted * 100)
        guard percent >= lastLoggedProgressPercent + 5 || percent == 100 else {
            return
        }

        lastLoggedProgressPercent = percent
        log("progress \(percent)% (\(progress.completedUnitCount)/\(progress.totalUnitCount) bytes)")
    }

    private func log(_ message: String) {
        guard let logHandle else { return }
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(timestamp)] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        try? logHandle.write(contentsOf: data)
    }

    enum DownloadError: LocalizedError {
        case validationFailed

        var errorDescription: String? {
            switch self {
            case .validationFailed:
                return "下载的模型文件不完整，请检查网络连接后重试。"
            }
        }
    }
}
