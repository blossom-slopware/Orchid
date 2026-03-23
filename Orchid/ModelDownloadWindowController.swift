import AppKit

final class ModelDownloadWindowController: NSWindowController {

    // MARK: - State

    enum State {
        case idle
        case downloading
        case done
        case failed(Error)
    }

    private var state: State = .idle {
        didSet { updateUI() }
    }

    var onDownloadComplete: (() -> Void)?

    // MARK: - UI references

    private let titleLabel     = NSTextField(labelWithString: "")
    private let fileLabel      = NSTextField(labelWithString: "")
    private let progressBar    = NSProgressIndicator()
    private let speedLabel     = NSTextField(labelWithString: "")
    private let cancelButton   = NSButton(title: "取消", target: nil, action: nil)
    private let doneButton     = NSButton(title: "开始使用", target: nil, action: nil)

    private var logScrollView: NSScrollView!
    private var logTextView: NSTextView!

    /// 防止日志文本无限增长拖慢 UI。
    private static let logTextViewMaxUTF16Length = 50_000

    // MARK: - Downloader

    private var downloader: HFModelDownloader?

    // MARK: - Init

    convenience init() {
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        w.title = "Orchid — 下载模型"
        w.isReleasedWhenClosed = false
        w.center()
        self.init(window: w)
        buildUI()
        updateUI()
    }

    // MARK: - Public

    func presentAndStartDownload(modelDir: URL) {
        guard let window else { return }

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)

        state = .downloading

        logTextView.textStorage?.setAttributedString(NSAttributedString(string: ""))

        let repoId = GLMOCRRepositoryFileList.repoId
        let dl = HFModelDownloader(repoId: repoId, finalModelDir: modelDir)
        downloader = dl

        dl.onLogLine = { @MainActor [weak self] line in
            self?.appendLogLineForDisplay(line)
        }

        dl.onProgress = { @MainActor [weak self] _ in
            guard let self else { return }
            self.fileLabel.stringValue = "正在下载 GLM-OCR 模型…"
            self.progressBar.isIndeterminate = true
            self.progressBar.startAnimation(nil)
            self.speedLabel.stringValue = ""
        }

        dl.onComplete = { [weak self] error in
            guard let self else { return }
            if let error {
                self.state = .failed(error)
            } else {
                self.state = .done
            }
        }

        dl.start()
    }

    // MARK: - Build UI

    private func buildUI() {
        guard let contentView = window?.contentView else { return }

        titleLabel.font = NSFont.systemFont(ofSize: 14, weight: .semibold)
        titleLabel.stringValue = "首次使用需要下载 GLM-OCR 模型（约 2 GB）"
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let descLabel = NSTextField(labelWithString: "模型将保存到 ~/.orchid/models/，下载完成后即可使用。")
        descLabel.textColor = .secondaryLabelColor
        descLabel.font = NSFont.systemFont(ofSize: 12)
        descLabel.translatesAutoresizingMaskIntoConstraints = false

        fileLabel.translatesAutoresizingMaskIntoConstraints = false
        fileLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        fileLabel.textColor = .secondaryLabelColor

        progressBar.style = .bar
        progressBar.minValue = 0
        progressBar.maxValue = 100
        progressBar.isIndeterminate = true
        progressBar.translatesAutoresizingMaskIntoConstraints = false

        speedLabel.translatesAutoresizingMaskIntoConstraints = false
        speedLabel.font = NSFont.systemFont(ofSize: 11)
        speedLabel.textColor = .secondaryLabelColor
        speedLabel.alignment = .right

        let logCaption = NSTextField(labelWithString: "详细日志（与 ~/.orchid/logs/download.log 同步）")
        logCaption.textColor = .secondaryLabelColor
        logCaption.font = NSFont.systemFont(ofSize: 11)
        logCaption.translatesAutoresizingMaskIntoConstraints = false

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        scroll.drawsBackground = true

        let tv = NSTextView()
        tv.isEditable = false
        tv.isSelectable = true
        tv.isRichText = false
        tv.importsGraphics = false
        tv.drawsBackground = true
        tv.backgroundColor = .textBackgroundColor
        tv.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        tv.textContainerInset = NSSize(width: 6, height: 6)
        tv.minSize = NSSize(width: 0, height: 80)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)

        scroll.documentView = tv
        logScrollView = scroll
        logTextView = tv

        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        cancelButton.target = self
        cancelButton.action = #selector(cancelTapped)

        doneButton.translatesAutoresizingMaskIntoConstraints = false
        doneButton.bezelStyle = .rounded
        doneButton.keyEquivalent = "\r"
        doneButton.target = self
        doneButton.action = #selector(doneTapped)

        let buttonStack = NSStackView(views: [cancelButton, doneButton])
        buttonStack.orientation = .horizontal
        buttonStack.spacing = 8
        buttonStack.translatesAutoresizingMaskIntoConstraints = false

        for view in [titleLabel, descLabel, fileLabel, progressBar, speedLabel, logCaption, scroll, buttonStack] {
            contentView.addSubview(view)
        }

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 24),
            titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            titleLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),

            descLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 6),
            descLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            descLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),

            fileLabel.topAnchor.constraint(equalTo: descLabel.bottomAnchor, constant: 16),
            fileLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            fileLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),

            progressBar.topAnchor.constraint(equalTo: fileLabel.bottomAnchor, constant: 8),
            progressBar.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            progressBar.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),

            speedLabel.topAnchor.constraint(equalTo: progressBar.bottomAnchor, constant: 4),
            speedLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),

            logCaption.topAnchor.constraint(equalTo: speedLabel.bottomAnchor, constant: 12),
            logCaption.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            logCaption.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),

            scroll.topAnchor.constraint(equalTo: logCaption.bottomAnchor, constant: 4),
            scroll.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            scroll.heightAnchor.constraint(equalToConstant: 160),

            buttonStack.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 12),
            buttonStack.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            buttonStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -20),
        ])
    }

    private func appendLogLineForDisplay(_ line: String) {
        guard let storage = logTextView.textStorage else { return }
        let attr: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular),
            .foregroundColor: NSColor.textColor,
        ]
        let piece = line.hasSuffix("\n") ? line : (line + "\n")
        storage.append(NSAttributedString(string: piece, attributes: attr))

        let maxLen = Self.logTextViewMaxUTF16Length
        if storage.length > maxLen {
            storage.deleteCharacters(in: NSRange(location: 0, length: storage.length - maxLen))
        }

        logTextView.scrollToEndOfDocument(nil)
    }

    // MARK: - Update UI from state

    private func updateUI() {
        switch state {
        case .idle:
            fileLabel.stringValue = ""
            speedLabel.stringValue = ""
            progressBar.isIndeterminate = false
            progressBar.doubleValue = 0
            doneButton.isEnabled = false
            cancelButton.isEnabled = true

        case .downloading:
            progressBar.isIndeterminate = true
            progressBar.startAnimation(nil)
            doneButton.isEnabled = false
            cancelButton.isEnabled = true

        case .done:
            progressBar.isIndeterminate = false
            progressBar.doubleValue = 100
            fileLabel.stringValue = "下载完成"
            speedLabel.stringValue = ""
            doneButton.isEnabled = true
            cancelButton.isEnabled = false

        case .failed(let error):
            progressBar.isIndeterminate = false
            fileLabel.stringValue = "下载失败：\(error.localizedDescription)"
            speedLabel.stringValue = ""
            doneButton.isEnabled = false
            cancelButton.title = "退出"
            cancelButton.isEnabled = true
        }
    }

    // MARK: - Actions

    @objc private func cancelTapped() {
        downloader?.cancel()
        NSApp.terminate(nil)
    }

    @objc private func doneTapped() {
        window?.close()
        onDownloadComplete?()
    }
}
