import Foundation

/// Downloads a HuggingFace model repository snapshot using hf-mirror.com.
/// Reproduces the behavior of huggingface_hub.snapshot_download in pure Swift.
final class HuggingFaceDownloader: NSObject {

    struct FileEntry {
        let rfilename: String
        let size: Int64?
    }

    enum DownloadError: Error {
        case badResponse(Int)
        case missingData
        case invalidJSON
    }

    // MARK: - Configuration

    private let endpoint = "https://hf-mirror.com"
    private let repoId: String
    private let localDir: URL

    // MARK: - Progress state (main-actor access expected by caller)

    var onProgress: ((_ file: String, _ fileIndex: Int, _ fileCount: Int,
                      _ bytesReceived: Int64, _ bytesExpected: Int64,
                      _ bytesPerSecond: Double) -> Void)?
    var onComplete: ((Error?) -> Void)?

    private var currentTask: URLSessionDataTask?
    private var cancelled = false
    private var session: URLSession!

    // MARK: - Init

    init(repoId: String, localDir: URL) {
        self.repoId = repoId
        self.localDir = localDir
        super.init()
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 60
        cfg.timeoutIntervalForResource = 3600 * 6
        self.session = URLSession(configuration: cfg, delegate: nil, delegateQueue: nil)
    }

    // MARK: - Public API

    func start() {
        Task.detached { [weak self] in
            guard let self else { return }
            do {
                try await self.run()
                await MainActor.run { self.onComplete?(nil) }
            } catch {
                await MainActor.run { self.onComplete?(error) }
            }
        }
    }

    func cancel() {
        cancelled = true
        currentTask?.cancel()
    }

    // MARK: - Core download logic

    private func run() async throws {
        try FileManager.default.createDirectory(at: localDir, withIntermediateDirectories: true)

        let files = try await fetchFileList()
        let total = files.count

        for (index, entry) in files.enumerated() {
            if cancelled { return }
            try await downloadFile(entry: entry, index: index, total: total)
        }
    }

    // MARK: - Step 1: fetch file list

    private func fetchFileList() async throws -> [FileEntry] {
        let url = URL(string: "\(endpoint)/api/models/\(repoId)")!
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw DownloadError.missingData }
        guard (200..<300).contains(http.statusCode) else { throw DownloadError.badResponse(http.statusCode) }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let siblings = json["siblings"] as? [[String: Any]] else {
            throw DownloadError.invalidJSON
        }

        return siblings.compactMap { sibling -> FileEntry? in
            guard let name = sibling["rfilename"] as? String else { return nil }
            let size = sibling["size"] as? Int64
            return FileEntry(rfilename: name, size: size)
        }
    }

    // MARK: - Step 2: download individual file with resume support

    private func downloadFile(entry: FileEntry, index: Int, total: Int) async throws {
        let destURL = localDir.appendingPathComponent(entry.rfilename)
        let partURL = localDir.appendingPathComponent(entry.rfilename + ".part")

        // Create parent directories if the filename contains subdirectories
        let parentDir = partURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)

        // Check if already fully downloaded
        if FileManager.default.fileExists(atPath: destURL.path) {
            let existingSize = (try? FileManager.default.attributesOfItem(atPath: destURL.path)[.size] as? Int64) ?? 0
            if let expected = entry.size, existingSize >= expected {
                return
            }
        }

        // Resume from .part if it exists
        var resumeOffset: Int64 = 0
        if FileManager.default.fileExists(atPath: partURL.path) {
            resumeOffset = (try? FileManager.default.attributesOfItem(atPath: partURL.path)[.size] as? Int64) ?? 0
        }

        let fileURL = URL(string: "\(endpoint)/\(repoId)/resolve/main/\(entry.rfilename)")!
        var request = URLRequest(url: fileURL)
        if resumeOffset > 0 {
            request.setValue("bytes=\(resumeOffset)-", forHTTPHeaderField: "Range")
        }

        // Open file handle for writing
        if !FileManager.default.fileExists(atPath: partURL.path) {
            FileManager.default.createFile(atPath: partURL.path, contents: nil)
        }
        let fileHandle = try FileHandle(forWritingTo: partURL)
        if resumeOffset > 0 {
            fileHandle.seekToEndOfFile()
        }
        defer { try? fileHandle.close() }

        var bytesReceived: Int64 = resumeOffset
        let bytesExpected: Int64 = entry.size ?? -1
        var speedStartTime = Date()
        var speedStartBytes: Int64 = resumeOffset

        let (asyncBytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw DownloadError.missingData }
        // 200 = full content, 206 = partial content (resume)
        guard http.statusCode == 200 || http.statusCode == 206 else {
            throw DownloadError.badResponse(http.statusCode)
        }

        let bufferSize = 1024 * 256 // 256 KB write buffer
        var buffer = Data()
        buffer.reserveCapacity(bufferSize)

        for try await byte in asyncBytes {
            if cancelled {
                try? fileHandle.close()
                return
            }
            buffer.append(byte)
            bytesReceived += 1

            if buffer.count >= bufferSize {
                fileHandle.write(buffer)
                buffer.removeAll(keepingCapacity: true)

                let now = Date()
                let elapsed = now.timeIntervalSince(speedStartTime)
                var bps: Double = 0
                if elapsed >= 0.5 {
                    bps = Double(bytesReceived - speedStartBytes) / elapsed
                    speedStartTime = now
                    speedStartBytes = bytesReceived
                }

                let captured = (bytesReceived, bps)
                await MainActor.run { [weak self] in
                    self?.onProgress?(entry.rfilename, index, total,
                                      captured.0, bytesExpected, captured.1)
                }
            }
        }

        if !buffer.isEmpty {
            fileHandle.write(buffer)
        }

        try fileHandle.close()

        // Rename .part -> final
        if FileManager.default.fileExists(atPath: destURL.path) {
            try FileManager.default.removeItem(at: destURL)
        }
        try FileManager.default.moveItem(at: partURL, to: destURL)

        await MainActor.run { [weak self] in
            self?.onProgress?(entry.rfilename, index + 1, total,
                              bytesReceived, bytesExpected, 0)
        }
    }
}
