import Foundation

struct ModelValidator {
    /// Returns `true` when the local directory's file-name set matches the
    /// hardcoded repository manifest exactly, without hitting the network.
    static func isModelDirectoryReady(at modelDir: URL) -> Bool {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: modelDir.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return false
        }

        guard let enumerator = fm.enumerator(
            at: modelDir,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: []
        ) else {
            return false
        }

        var localFiles = Set<String>()
        while let fileURL = enumerator.nextObject() as? URL {
            let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values?.isRegularFile == true || values?.isSymbolicLink == true else {
                continue
            }
            localFiles.insert(relativePath(for: fileURL, under: modelDir))
        }

        return localFiles == GLMOCRRepositoryFileList.files
    }

    private static func relativePath(for fileURL: URL, under root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let filePath = fileURL.standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        return String(filePath.dropFirst(prefix.count))
    }
}
