import AppKit
import Carbon
import Combine

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    var overlayWindowController: OverlayWindowController?
    private var hotKeyRef: EventHotKeyRef?
    private var config: OrchidConfig = OrchidConfig(
        preferredPort: 14416,
        models: []
    )
    private var serverStateCancellable: AnyCancellable?
    private var activeModelCancellable: AnyCancellable?
    private var downloadWindowController: ModelDownloadWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // Load config (auto-creates ~/.orchid/config.toml if absent)
        config = OrchidConfig.load()

        // Verify the bundled server binary exists
        let serverPath = OrchidConfig.bundledServerPath
        guard FileManager.default.fileExists(atPath: serverPath) else {
            let alert = NSAlert()
            alert.messageText = "安装损坏"
            alert.informativeText = "找不到推理服务器二进制文件，请重新安装 Orchid。\n(\(serverPath))"
            alert.alertStyle = .critical
            alert.addButton(withTitle: "退出")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
            NSApp.terminate(nil)
            return
        }

        // Create status bar item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem?.button {
            button.image = OrchidIcon.image(size: 18)
            button.image?.isTemplate = false
            button.action = #selector(statusButtonClicked(_:))
            button.sendAction(on: [.leftMouseUp])
            button.target = self
        }

        // Register F4 global hotkey (keyCode 118)
        registerF4HotKey()

        // Subscribe to server state changes to refresh menu
        serverStateCancellable = ServerManager.shared.$serverState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                // Menu is rebuilt on each open; no persistent reference to update
                _ = self
            }
        activeModelCancellable = ServerManager.shared.$activeModel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                _ = self
            }

        checkModelAndStart()
    }

    // MARK: - Model check + conditional start

    private func checkModelAndStart() {
        let modelPath = config.modelPath(for: config.defaultModel)
            ?? (FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".orchid/models/GLM-OCR-bf16").path)
        let modelDir = URL(fileURLWithPath: modelPath)
        let weightsFile = modelDir.appendingPathComponent("model.safetensors")

        var needsDownload = true
        if FileManager.default.fileExists(atPath: weightsFile.path),
           let attrs = try? FileManager.default.attributesOfItem(atPath: weightsFile.path),
           let size = attrs[.size] as? Int64,
           size > 100_000_000 {
            needsDownload = false
        }

        ServerManager.shared.onStartupError = { [weak self] log in
            self?.showServerErrorAlert(log: log)
        }

        if needsDownload {
            let dlWC = ModelDownloadWindowController()
            downloadWindowController = dlWC
            dlWC.onDownloadComplete = { [weak self] in
                guard let self else { return }
                self.downloadWindowController = nil
                CGRequestScreenCaptureAccess()
                ServerManager.shared.start(model: self.config.defaultModel, config: self.config)
            }
            dlWC.presentAndStartDownload(modelDir: modelDir)
        } else {
            CGRequestScreenCaptureAccess()
            ServerManager.shared.start(model: config.defaultModel, config: config)
        }
    }

    private func showServerErrorAlert(log: String) {
        let alert = NSAlert()
        alert.messageText = "服务器启动失败"
        alert.informativeText = log
            + "\n\n如果问题持续存在，请前往 GitHub 反馈：\nhttps://github.com/blossom-slopware/orchid/issues"
        alert.alertStyle = .critical
        alert.addButton(withTitle: "复制错误信息")
        alert.addButton(withTitle: "关闭")
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(log, forType: .string)
        }
        NSApp.terminate(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
        }
        ServerManager.shared.stop()
    }

    // MARK: - Status Button (left = menu)

    @objc func statusButtonClicked(_ sender: NSStatusBarButton) {
        showContextMenu()
    }

    private func showContextMenu() {
        let menu = NSMenu()
        let serverManager = ServerManager.shared

        // 截图识别
        let ocrItem = NSMenuItem(title: "截图识别", action: #selector(showOverlay), keyEquivalent: "")
        ocrItem.keyEquivalent = String(UnicodeScalar(NSF4FunctionKey)!)
        ocrItem.keyEquivalentModifierMask = []
        menu.addItem(ocrItem)
        menu.addItem(.separator())

        // Model submenu
        let modelMenuItem = NSMenuItem(title: "模型", action: nil, keyEquivalent: "")
        let modelSubmenu = NSMenu(title: "模型")
        let modelsDisabled = serverManager.serverState == .starting || serverManager.serverState == .stopping

        for modelEntry in config.models {
            let displayName = config.displayName(for: modelEntry.key)
            let item = NSMenuItem(
                title: displayName,
                action: modelsDisabled ? nil : #selector(switchModel(_:)),
                keyEquivalent: ""
            )
            item.representedObject = modelEntry.key
            item.target = self
            item.isEnabled = !modelsDisabled
            if modelEntry.key == serverManager.activeModel {
                item.state = .on
            }
            modelSubmenu.addItem(item)
        }
        modelMenuItem.submenu = modelSubmenu
        menu.addItem(modelMenuItem)
        menu.addItem(.separator())

        // Server status (disabled, informational)
        let statusTitle: String
        switch serverManager.serverState {
        case .stopped:
            statusTitle = "服务器：已停止"
        case .starting:
            statusTitle = "服务器：启动中…"
        case .running:
            statusTitle = "服务器：运行中 :\(serverManager.activePort)"
        case .stopping:
            statusTitle = "服务器：停止中…"
        }
        let statusItem = NSMenuItem(title: statusTitle, action: nil, keyEquivalent: "")
        statusItem.isEnabled = false
        menu.addItem(statusItem)
        menu.addItem(.separator())

        menu.addItem(NSMenuItem(title: "清空图片缓存", action: #selector(clearCache), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出 Orchid", action: #selector(quitApp), keyEquivalent: "q"))

        self.statusItem?.menu = menu
        self.statusItem?.button?.performClick(nil)
        // Remove menu so next left-click triggers action directly
        DispatchQueue.main.async { self.statusItem?.menu = nil }
    }

    @objc func showOverlay() {
        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
            // If still denied after requesting, system won't prompt again — guide user to Settings.
            if !CGPreflightScreenCaptureAccess() {
                let alert = NSAlert()
                alert.messageText = "需要屏幕录制权限"
                alert.informativeText = "请前往：系统设置 → 隐私与安全性 → 屏幕录制，勾选 Orchid 后重新启动应用。"
                alert.alertStyle = .warning
                alert.addButton(withTitle: "打开系统设置")
                alert.addButton(withTitle: "稍后")
                NSApp.activate(ignoringOtherApps: true)
                if alert.runModal() == .alertFirstButtonReturn {
                    NSWorkspace.shared.open(
                        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
                    )
                }
            }
            return
        }

        guard ServerManager.shared.serverState == .running else {
            let alert = NSAlert()
            alert.messageText = "服务器尚未就绪"
            alert.informativeText = "推理服务器正在启动中，请稍候再试。"
            alert.alertStyle = .informational
            alert.addButton(withTitle: "好")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
            return
        }

        if overlayWindowController == nil {
            overlayWindowController = OverlayWindowController()
        }
        overlayWindowController?.showOverlay()
    }

    @objc func switchModel(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        ServerManager.shared.switchModel(to: key, config: config)
    }

    @objc func quitApp() {
        NSApp.terminate(nil)
    }

    @objc func clearCache() {
        CacheManagerController.shared.clearCache()
    }

    // MARK: - F4 Global Hotkey

    private func registerF4HotKey() {
        var hotKeyID = EventHotKeyID()
        hotKeyID.signature = OSType(0x4F524344) // 'ORCD'
        hotKeyID.id = 1

        let status = RegisterEventHotKey(
            118, // F4
            0,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        if status != noErr {
            print("Orchid: failed to register F4 hotkey, status=\(status)")
            return
        }

        var eventSpec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetApplicationEventTarget(),
            { (_, _, userData) -> OSStatus in
                guard let userData = userData else { return noErr }
                let delegate = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
                DispatchQueue.main.async { delegate.showOverlay() }
                return noErr
            },
            1,
            &eventSpec,
            Unmanaged.passUnretained(self).toOpaque(),
            nil
        )
    }
}
