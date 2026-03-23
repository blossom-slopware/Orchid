import AppKit

final class CacheManagerController: @unchecked Sendable {
    nonisolated(unsafe) static let shared = CacheManagerController()
    private init() {}

    private let storageDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".orchid/storage")

    func clearCache() {
        let count = cachedFileCount()

        // No cache — just inform, no confirm needed
        if count == 0 {
            let alert = NSAlert()
            alert.messageText = "没有缓存图片"
            alert.informativeText = "当前没有已保存的截图。"
            alert.alertStyle = .informational
            alert.addButton(withTitle: "好")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
            return
        }

        // MARK: Step 1 — Confirm dialog
        let confirm = NSAlert()
        confirm.messageText = "清空图片缓存"
        confirm.informativeText = "将删除所有已保存的截图（\(count) 张）。此操作不可撤销。"
        confirm.alertStyle = .warning
        confirm.addButton(withTitle: "清空")
        confirm.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        guard confirm.runModal() == .alertFirstButtonReturn else { return }

        // MARK: Step 2 — Delete
        var deletedCount = 0
        var errorOccurred = false
        do {
            let fm = FileManager.default
            let files = try fm.contentsOfDirectory(
                at: storageDir,
                includingPropertiesForKeys: nil
            ).filter { $0.pathExtension.lowercased() == "png" }
            for file in files {
                do {
                    try fm.removeItem(at: file)
                    deletedCount += 1
                } catch {
                    print("Orchid: failed to delete \(file.lastPathComponent): \(error)")
                    errorOccurred = true
                }
            }
        } catch {
            print("Orchid: cache dir not found or unreadable: \(error)")
        }

        // MARK: Step 3 — Update the same confirm alert in-place
        confirm.messageText = errorOccurred ? "⚠️ 清空时出现错误" : "✅ 已清空图片缓存"
        confirm.informativeText = errorOccurred
            ? "部分文件删除失败，已删除 \(deletedCount) 张。"
            : "已删除 \(deletedCount) 张截图。"
        confirm.alertStyle = errorOccurred ? .warning : .informational
        confirm.buttons[0].title = "好"
        confirm.buttons[0].keyEquivalent = "\r"
        confirm.buttons[1].isHidden = true
        confirm.runModal()
    }

    // MARK: - Helpers

    private func cachedFileCount() -> Int {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: storageDir,
            includingPropertiesForKeys: nil
        ) else { return 0 }
        return files.filter { $0.pathExtension.lowercased() == "png" }.count
    }
}
