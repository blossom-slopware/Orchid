import AppKit
import Foundation

class SelectionView: NSView {
    // MARK: - Properties
    var onConfirm: (() -> Void)?
    /// Frozen full-screen screenshot captured before the overlay appeared.
    var frozenScreenshot: CGImage?

    private var selectionRect: CGRect = .zero
    private var dragStart: CGPoint = .zero
    private var isDragging: Bool = false
    private var activeHandle: HandleIndex? = nil
    private var isMovingSelection: Bool = false
    private var moveOffset: CGPoint = .zero

    private let accentColor = NSColor(red: 0xed/255, green: 0x8e/255, blue: 0xa9/255, alpha: 1)
    private let handleSize: CGFloat = 10.0
    private let handleRadius: CGFloat = 5.0

    private var recognizeButton: NSButton?
    private var recognizePlainButton: NSButton?

    // Custom tooltip (NSTooltipManager doesn't work in .screenSaver level windows)
    private var tooltipLabel: NSTextField?
    private var tooltipTrackingArea: NSTrackingArea?

    // MARK: - Handle Enumeration
    enum HandleIndex: Int {
        case topLeft = 0, topCenter, topRight
        case middleLeft, middleRight
        case bottomLeft, bottomCenter, bottomRight
    }

    // MARK: - Init
    override init(frame: NSRect) {
        super.init(frame: frame)
        setupRecognizeButton()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupRecognizeButton()
    }

    override var acceptsFirstResponder: Bool { true }

    // MARK: - Setup
    private func setupRecognizeButton() {
        let button = NSButton(title: "Recognize", target: self, action: #selector(confirmMarkdown))
        button.bezelStyle = .rounded
        button.isHidden = true
        button.keyEquivalent = ""
        addSubview(button)
        recognizeButton = button

        let plainButton = NSButton(title: "Plain Text", target: self, action: #selector(confirmPlainText))
        plainButton.bezelStyle = .rounded
        plainButton.isHidden = true
        plainButton.keyEquivalent = ""
        plainButton.toolTip = "Model may still output Markdown — plain text output is best-effort only."
        addSubview(plainButton)
        recognizePlainButton = plainButton

        // Custom tooltip label (system tooltips don't work in .screenSaver level windows)
        let label = NSTextField(labelWithString: "Output may still contain Markdown — best-effort only")
        label.font = .systemFont(ofSize: 11)
        label.textColor = NSColor(white: 0.95, alpha: 1)
        label.backgroundColor = NSColor(white: 0.15, alpha: 0.9)
        label.isBezeled = false
        label.drawsBackground = true
        label.isHidden = true
        label.wantsLayer = true
        label.layer?.cornerRadius = 4
        label.layer?.masksToBounds = true
        addSubview(label)
        tooltipLabel = label
    }

    // MARK: - Drawing
    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        // 1. Draw frozen screenshot as background (covers entire view)
        if let img = frozenScreenshot {
            ctx.draw(img, in: bounds)
        }

        // 2. Draw dim overlay over everything
        ctx.setFillColor(NSColor(white: 0, alpha: 0.45).cgColor)
        ctx.fill(bounds)

        guard selectionRect.width > 2 && selectionRect.height > 2 else { return }

        // 3. Re-draw the frozen screenshot in the selection rect (undimmed)
        if let img = frozenScreenshot {
            ctx.saveGState()
            ctx.clip(to: selectionRect)
            ctx.draw(img, in: bounds)
            ctx.restoreGState()
        }

        // 4. Draw selection border
        accentColor.setStroke()
        let borderPath = NSBezierPath(rect: selectionRect)
        borderPath.lineWidth = 1.5
        borderPath.stroke()

        // 5. Draw 8 resize handles
        accentColor.setFill()
        for handle in allHandles() {
            let handleRect = CGRect(
                x: handle.x - handleRadius,
                y: handle.y - handleRadius,
                width: handleSize,
                height: handleSize
            )
            NSBezierPath(ovalIn: handleRect).fill()
        }
    }

    // MARK: - Handle Positions
    private func allHandles() -> [CGPoint] {
        let r = selectionRect
        return [
            CGPoint(x: r.minX, y: r.maxY),       // topLeft
            CGPoint(x: r.midX, y: r.maxY),       // topCenter
            CGPoint(x: r.maxX, y: r.maxY),       // topRight
            CGPoint(x: r.minX, y: r.midY),       // middleLeft
            CGPoint(x: r.maxX, y: r.midY),       // middleRight
            CGPoint(x: r.minX, y: r.minY),       // bottomLeft
            CGPoint(x: r.midX, y: r.minY),       // bottomCenter
            CGPoint(x: r.maxX, y: r.minY),       // bottomRight
        ]
    }

    private func handleAt(point: CGPoint) -> HandleIndex? {
        let handles = allHandles()
        for (i, hp) in handles.enumerated() {
            let dist = hypot(point.x - hp.x, point.y - hp.y)
            if dist <= handleRadius + 4 {
                return HandleIndex(rawValue: i)
            }
        }
        return nil
    }

    // MARK: - Mouse Events
    override func mouseDown(with event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)

        if !selectionRect.isEmpty, let handle = handleAt(point: loc) {
            activeHandle = handle
            isDragging = false
            isMovingSelection = false
        } else if selectionRect.contains(loc) {
            isMovingSelection = true
            moveOffset = CGPoint(x: loc.x - selectionRect.origin.x,
                                 y: loc.y - selectionRect.origin.y)
            activeHandle = nil
            isDragging = false
        } else {
            // Start new rubber band
            isDragging = true
            dragStart = loc
            selectionRect = .zero
            activeHandle = nil
            isMovingSelection = false
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)

        if isDragging {
            // New rubber band
            let x = min(loc.x, dragStart.x)
            let y = min(loc.y, dragStart.y)
            let w = abs(loc.x - dragStart.x)
            let h = abs(loc.y - dragStart.y)
            selectionRect = CGRect(x: x, y: y, width: w, height: h)
        } else if let handle = activeHandle {
            resizeSelection(handle: handle, to: loc)
        } else if isMovingSelection {
            selectionRect.origin = CGPoint(
                x: loc.x - moveOffset.x,
                y: loc.y - moveOffset.y
            )
        }

        updateRecognizeButton()
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        isDragging = false
        activeHandle = nil
        isMovingSelection = false
        updateRecognizeButton()
        needsDisplay = true
    }

    // MARK: - Resize Logic
    private func resizeSelection(handle: HandleIndex, to loc: CGPoint) {
        var r = selectionRect
        switch handle {
        case .topLeft:
            r = CGRect(x: loc.x, y: r.minY, width: r.maxX - loc.x, height: loc.y - r.minY)
        case .topCenter:
            r = CGRect(x: r.minX, y: r.minY, width: r.width, height: loc.y - r.minY)
        case .topRight:
            r = CGRect(x: r.minX, y: r.minY, width: loc.x - r.minX, height: loc.y - r.minY)
        case .middleLeft:
            r = CGRect(x: loc.x, y: r.minY, width: r.maxX - loc.x, height: r.height)
        case .middleRight:
            r = CGRect(x: r.minX, y: r.minY, width: loc.x - r.minX, height: r.height)
        case .bottomLeft:
            r = CGRect(x: loc.x, y: loc.y, width: r.maxX - loc.x, height: r.maxY - loc.y)
        case .bottomCenter:
            r = CGRect(x: r.minX, y: loc.y, width: r.width, height: r.maxY - loc.y)
        case .bottomRight:
            r = CGRect(x: r.minX, y: loc.y, width: loc.x - r.minX, height: r.maxY - loc.y)
        }

        // Normalize (prevent negative sizes from flipping)
        selectionRect = r.standardized
    }

    // MARK: - Recognize Button
    private func updateRecognizeButton() {
        guard let btn = recognizeButton, let plainBtn = recognizePlainButton else { return }
        if selectionRect.width > 20 && selectionRect.height > 20 {
            let btnSize = btn.fittingSize
            let plainSize = plainBtn.fittingSize
            let gap: CGFloat = 6
            let totalWidth = btnSize.width + gap + plainSize.width
            let bottomY = selectionRect.minY - btnSize.height - 4

            // Right-align the pair to the right edge of the selection
            let rightEdge = selectionRect.maxX
            btn.frame = CGRect(
                x: rightEdge - totalWidth,
                y: bottomY,
                width: btnSize.width,
                height: btnSize.height
            )
            plainBtn.frame = CGRect(
                x: rightEdge - plainSize.width,
                y: bottomY,
                width: plainSize.width,
                height: plainSize.height
            )
            btn.isHidden = false
            plainBtn.isHidden = false

            // Update tracking area for custom tooltip
            if let old = tooltipTrackingArea { removeTrackingArea(old) }
            let ta = NSTrackingArea(
                rect: plainBtn.frame,
                options: [.mouseEnteredAndExited, .activeAlways],
                owner: self,
                userInfo: nil
            )
            addTrackingArea(ta)
            tooltipTrackingArea = ta
        } else {
            btn.isHidden = true
            plainBtn.isHidden = true
            tooltipLabel?.isHidden = true
            if let old = tooltipTrackingArea { removeTrackingArea(old); tooltipTrackingArea = nil }
        }
    }

    override func mouseEntered(with event: NSEvent) {
        guard let plainBtn = recognizePlainButton, let label = tooltipLabel else { return }
        label.sizeToFit()
        var f = label.frame
        f.size.width += 8
        // Position above the Plain Text button
        f.origin = CGPoint(x: plainBtn.frame.minX, y: plainBtn.frame.maxY + 4)
        // Keep within view bounds
        if f.maxX > bounds.maxX { f.origin.x = bounds.maxX - f.width }
        label.frame = f
        label.isHidden = false
    }

    override func mouseExited(with event: NSEvent) {
        tooltipLabel?.isHidden = true
    }

    // MARK: - Keyboard
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 49, 36: // Space, Return → confirm (markdown, default)
            confirmSelection(mode: .markdown)
        case 53:     // Escape → cancel (fallback, normally routed via cancelOperation)
            cancelCapture()
        default:
            super.keyDown(with: event)
        }
    }

    // AppKit 将 ESC 路由到 cancelOperation，必须在此处理
    override func cancelOperation(_ sender: Any?) {
        cancelCapture()
    }

    private func cancelCapture() {
        window?.orderOut(nil)
        onConfirm?()
    }

    // MARK: - Confirm
    @objc func confirmMarkdown() { confirmSelection(mode: .markdown) }
    @objc func confirmPlainText() { confirmSelection(mode: .plainText) }

    func confirmSelection(mode: OCRMode) {
        guard selectionRect.width > 2 && selectionRect.height > 2 else { return }

        let captureRect = selectionRect

        // Hide overlay first, then capture
        window?.orderOut(nil)
        onConfirm?()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            self.performCapture(rect: captureRect, mode: mode)
        }
    }

    private func performCapture(rect: CGRect, mode: OCRMode) {
        guard let screen = NSScreen.main else { return }
        let screenHeight = screen.frame.height
        let scale = screen.backingScaleFactor

        // Crop from the frozen screenshot (already captured before overlay appeared)
        // NSView coords have origin bottom-left; CGImage origin also bottom-left when drawn via ctx.draw(_:in:bounds)
        // so we need to flip Y for the crop rect
        let cropRect = CGRect(
            x: rect.origin.x * scale,
            y: (screenHeight - rect.maxY) * scale,
            width: rect.width * scale,
            height: rect.height * scale
        )

        let image: CGImage?
        if let frozen = frozenScreenshot, let cropped = frozen.cropping(to: cropRect) {
            image = cropped
        } else {
            // Fallback: live capture (overlay is already hidden at this point)
            image = ScreenCapture.capture(rect: CGRect(
                x: rect.origin.x,
                y: screenHeight - rect.maxY,
                width: rect.width,
                height: rect.height
            ))
        }

        guard let image else {
            print("Orchid: screen capture failed")
            return
        }

        // Save to ~/.orchid/storage/<timestamp>.png
        let storageDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".orchid/storage")
        do {
            try FileManager.default.createDirectory(at: storageDir, withIntermediateDirectories: true)
        } catch {
            print("Orchid: failed to create storage dir: \(error)")
            return
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let timestamp = formatter.string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let fileURL = storageDir.appendingPathComponent("\(timestamp).png")

        guard ScreenCapture.save(image: image, to: fileURL) else {
            print("Orchid: failed to save PNG")
            return
        }

        print("Orchid: saved capture to \(fileURL.path)")

        DispatchQueue.main.async {
            ResultPanelController.shared.show(imageURL: fileURL, mode: mode)
        }
    }
}
