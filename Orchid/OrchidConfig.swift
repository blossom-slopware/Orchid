import Foundation
import TOMLKit

struct OrchidConfig {
    /// Model keys that the current OCR backend (glm-ocr-rs) supports.
    /// Config entries with keys not in this set are ignored.
    static let supportedModelKeys: Set<String> = ["glm-ocr"]

    var preferredPort: Int
    var models: [(key: String, path: String)]

    var defaultModel: String { models.first?.key ?? "glm-ocr" }

    /// Path to the glm-ocr-server binary embedded inside the app bundle.
    static var bundledServerPath: String {
        Bundle.main.url(forResource: "glm-ocr-server", withExtension: nil, subdirectory: "bin")!.path
    }

    static func load() -> OrchidConfig {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".orchid")
        let file = dir.appendingPathComponent("config.toml")

        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        applyDefaults(to: file)

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let contents = try! String(contentsOf: file, encoding: .utf8)
        let table = try! TOMLTable(string: contents)

        let preferredPort = table["port"]?.int ?? 14416

        var models: [(key: String, path: String)] = []
        if let modelTable = table["model-path"]?.table {
            for (key, value) in modelTable {
                if let path = value.string, supportedModelKeys.contains(key) {
                    models.append((key: key, path: path))
                }
            }
        }

        if models.isEmpty {
            models = [
                (key: "glm-ocr", path: "\(home)/.orchid/models/GLM-OCR-bf16"),
            ]
        }

        return OrchidConfig(preferredPort: preferredPort, models: models)
    }

    static func applyDefaults(to url: URL) {
        let home = FileManager.default.homeDirectoryForCurrentUser.path

        var existingPort: Int? = nil
        var existingModels: [String: String] = [:]
        let fileExists = FileManager.default.fileExists(atPath: url.path)

        if fileExists {
            let contents = try! String(contentsOf: url, encoding: .utf8)
            let table = try! TOMLTable(string: contents)
            existingPort = table["port"]?.int
            if let mt = table["model-path"]?.table {
                for (k, v) in mt {
                    if let s = v.string { existingModels[k] = s }
                }
            }
        }

        let needsGlm = existingModels["glm-ocr"] == nil
        let needsWrite = !fileExists || existingPort == nil || needsGlm

        guard needsWrite else { return }

        let finalPort = existingPort ?? 14416
        if needsGlm { existingModels["glm-ocr"] = "\(home)/.orchid/models/GLM-OCR-bf16" }

        var toml = "port = \(finalPort)\n\n[model-path]\n"
        for (key, path) in existingModels.sorted(by: { $0.key < $1.key }) {
            toml += "\(key) = \"\(path)\"\n"
        }

        try! toml.write(to: url, atomically: true, encoding: .utf8)
    }

    func modelPath(for key: String) -> String? {
        models.first(where: { $0.key == key })?.path
    }

    func displayName(for key: String) -> String {
        switch key {
        case "glm-ocr": return "GLM-OCR"
        default: return key
        }
    }
}
