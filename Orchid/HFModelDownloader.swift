import Foundation
import HuggingFaceWrapper

/// Downloads a HuggingFace model snapshot into Orchid's configured model
/// directory, using a local HF cache under `~/.orchid` for resume support.
final class HFModelDownloader: @unchecked Sendable {

    let repoId: String
    let finalModelDir: URL

    var onProgress: (@MainActor @Sendable (Progress) -> Void)?
    var onComplete: (@MainActor (Error?) -> Void)?

    private var downloadTask: Task<Void, Never>?

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
                self.cleanupStaging()
            } catch {
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

    private func run() async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: stagingDir, withIntermediateDirectories: true)

        let cache = HubCache(location: .fixed(directory: cacheDir))
        let client = HubClient(cache: cache)

        guard let repoID = Repo.ID(rawValue: repoId) else {
            throw DownloadError.validationFailed
        }

        _ = try await client.downloadSnapshot(
            of: repoID,
            kind: .model,
            to: stagingDir,
            revision: "main",
            progressHandler: onProgress
        )

        try Task.checkCancellation()

        guard ModelValidator.isModelDirectoryReady(at: stagingDir) else {
            throw DownloadError.validationFailed
        }

        try Task.checkCancellation()

        // Atomic-ish swap: move old dir aside, move staging into place, remove old.
        let backupDir = finalModelDir
            .deletingLastPathComponent()
            .appendingPathComponent(finalModelDir.lastPathComponent + ".old")

        if fm.fileExists(atPath: backupDir.path) {
            try fm.removeItem(at: backupDir)
        }
        if fm.fileExists(atPath: finalModelDir.path) {
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
    }

    private func cleanupStaging() {
        try? FileManager.default.removeItem(at: stagingDir)
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
