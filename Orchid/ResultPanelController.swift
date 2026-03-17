import AppKit
import SwiftUI

// MARK: - Observable OCR State
final class OCRState: ObservableObject {
    @Published var text: String = ""
    @Published var isStreaming: Bool = false
    @Published var errorMessage: String? = nil
}

// MARK: - SwiftUI Result View
struct ResultView: View {
    @ObservedObject var state: OCRState
    var onCopy: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var copied = false

    private var bgColor: Color {
        colorScheme == .dark
            ? Color(red: 0x2a/255, green: 0x27/255, blue: 0x2e/255)
            : Color(red: 0xfa/255, green: 0xf2/255, blue: 0xf5/255)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Toolbar
            HStack {
                Text("Orchid OCR")
                    .font(.headline)
                Spacer()
                if state.isStreaming {
                    ProgressView()
                        .scaleEffect(0.6)
                        .frame(width: 16, height: 16)
                }
                Button(copied ? "Copied ✅" : "Copy to Clipboard") {
                    onCopy()
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                        copied = false
                    }
                }
                .buttonStyle(.bordered)
                .disabled(state.text.isEmpty)
                .animation(.easeInOut(duration: 0.15), value: copied)
            }
            .padding(.horizontal, 8)
            .padding(.top, 8)

            Divider()

            // Text content
            ScrollViewReader { proxy in
                ScrollView {
                    Text(state.errorMessage != nil
                         ? (state.errorMessage ?? "")
                         : (state.text.isEmpty ? "Waiting for OCR…" : state.text))
                        .font(.system(.body, design: .monospaced))
                        .foregroundColor(state.errorMessage != nil ? .red : .primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)
                        .id("bottom")
                }
                .onChange(of: state.text) { _ in
                    withAnimation {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
            }
            .padding(.bottom, 8)
        }
        .frame(minWidth: 200, minHeight: 100)
        .background(bgColor)
    }
}

// MARK: - Panel Controller
final class ResultPanelController: NSObject {
    static let shared = ResultPanelController()

    private var panel: NSPanel?
    private var ocrState = OCRState()

    private override init() {}

    func show(imageURL: URL, mode: OCRMode = .markdown) {
        // Reset existing state in-place so the already-bound SwiftUI view picks up the changes
        ocrState.text = ""
        ocrState.errorMessage = nil
        ocrState.isStreaming = true

        if panel == nil {
            createPanel()
        }
        panel?.makeKeyAndOrderFront(nil)

        // Start OCR streaming
        OCRClient.recognize(
            imageURL: imageURL,
            mode: mode,
            onChunk: { [weak self] chunk in
                self?.ocrState.text += chunk
            },
            onComplete: { [weak self] error in
                self?.ocrState.isStreaming = false
                if let error = error {
                    self?.ocrState.errorMessage = "Error: \(error.localizedDescription)"
                }
            }
        )
    }

    private func createPanel() {
        guard let screen = NSScreen.main else { return }
        let visibleFrame = screen.visibleFrame

        let panelWidth = visibleFrame.width / 6
        let panelHeight = visibleFrame.height / 3
        let margin: CGFloat = 12

        let contentRect = NSRect(
            x: visibleFrame.maxX - panelWidth - margin,
            y: visibleFrame.maxY - panelHeight - margin,
            width: panelWidth,
            height: panelHeight
        )

        let p = NSPanel(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.level = .floating
        p.title = "Orchid OCR"
        p.isFloatingPanel = true
        p.becomesKeyOnlyIfNeeded = true
        p.hidesOnDeactivate = false
        p.delegate = self

        let resultView = ResultView(
            state: ocrState,
            onCopy: { [weak self] in
                guard let text = self?.ocrState.text, !text.isEmpty else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
        )

        p.contentView = NSHostingView(rootView: resultView)
        self.panel = p
    }
}

// MARK: - NSWindowDelegate
extension ResultPanelController: NSWindowDelegate {
    // Called when user clicks the red close button
    func windowWillClose(_ notification: Notification) {
        panel = nil
    }
}
