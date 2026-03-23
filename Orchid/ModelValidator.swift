import Foundation

struct ModelValidator {
    /// Files the glm-ocr-server unconditionally requires at startup.
    private static let requiredFiles = [
        "config.json",
        "tokenizer.json",
        "chat_template.jinja",
        "preprocessor_config.json",
    ]

    /// Returns `true` when `modelDir` contains every file the Rust inference
    /// server needs to start: configuration JSONs, tokenizer, chat template,
    /// and either a single `model.safetensors` or a sharded weight set
    /// described by `model.safetensors.index.json`.
    static func isModelDirectoryReady(at modelDir: URL) -> Bool {
        let fm = FileManager.default

        for file in requiredFiles {
            guard fm.fileExists(atPath: modelDir.appendingPathComponent(file).path) else {
                return false
            }
        }

        let indexPath = modelDir.appendingPathComponent("model.safetensors.index.json")
        let singleWeightsPath = modelDir.appendingPathComponent("model.safetensors")

        if fm.fileExists(atPath: indexPath.path) {
            return areShardsPresentForIndex(at: indexPath, modelDir: modelDir)
        }

        return fm.fileExists(atPath: singleWeightsPath.path)
    }

    private static func areShardsPresentForIndex(at indexPath: URL, modelDir: URL) -> Bool {
        guard let data = try? Data(contentsOf: indexPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let weightMap = json["weight_map"] as? [String: String]
        else {
            return false
        }

        let fm = FileManager.default
        let shardFiles = Set(weightMap.values)
        for shard in shardFiles {
            guard fm.fileExists(atPath: modelDir.appendingPathComponent(shard).path) else {
                return false
            }
        }
        return true
    }
}
