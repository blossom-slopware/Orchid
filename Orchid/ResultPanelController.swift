import AppKit
import SwiftUI

// MARK: - Observable OCR State
final class OCRState: ObservableObject {
    @Published var text: String = ""
    @Published var isStreaming: Bool = false
    @Published var errorMessage: String? = nil
}

// MARK: - Search State
final class SearchState: ObservableObject {
    @Published var query: String = ""
    @Published var caseSensitive: Bool = false
    @Published var isVisible: Bool = false

    // Ranges of all matches in the full text, plus which one is focused
    @Published var matches: [Range<String.Index>] = []
    @Published var focusedMatch: Int = 0

    func update(text: String) {
        guard isVisible && !query.isEmpty else {
            matches = []
            focusedMatch = 0
            return
        }
        let options: String.CompareOptions = caseSensitive ? [] : .caseInsensitive
        var found: [Range<String.Index>] = []
        var searchFrom = text.startIndex
        while searchFrom < text.endIndex,
              let r = text.range(of: query, options: options, range: searchFrom..<text.endIndex) {
            found.append(r)
            searchFrom = r.upperBound == r.lowerBound ? text.index(after: r.upperBound) : r.upperBound
        }
        let prevFocus = focusedMatch
        matches = found
        focusedMatch = found.isEmpty ? 0 : min(prevFocus, found.count - 1)
    }

    func next() { if !matches.isEmpty { focusedMatch = (focusedMatch + 1) % matches.count } }
    func prev() { if !matches.isEmpty { focusedMatch = (focusedMatch - 1 + matches.count) % matches.count } }
}

// MARK: - Highlighted Text
/// Renders OCR text with search matches highlighted via AttributedString.
struct HighlightedText: View {
    let text: String
    @ObservedObject var search: SearchState

    private var highlightColor: Color { Color(red: 0xed/255, green: 0x8e/255, blue: 0xa9/255).opacity(0.45) }
    private var focusColor: Color    { Color(red: 0xed/255, green: 0x8e/255, blue: 0xa9/255).opacity(0.9) }

    var body: some View {
        Text(attributed)
            .font(.system(.body, design: .monospaced))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var attributed: AttributedString {
        var result = AttributedString(text)
        guard search.isVisible && !search.query.isEmpty else { return result }
        for (i, range) in search.matches.enumerated() {
            if let attrRange = Range(range, in: result) {
                result[attrRange].backgroundColor = i == search.focusedMatch ? UIColorBridge.focus : UIColorBridge.highlight
            }
        }
        return result
    }
}

private enum UIColorBridge {
    static let highlight = Color(red: 0xed/255, green: 0x8e/255, blue: 0xa9/255).opacity(0.45)
    static let focus     = Color(red: 0xed/255, green: 0x8e/255, blue: 0xa9/255).opacity(0.9)
}

// MARK: - Search TextField (NSViewRepresentable)
/// Intercepts Return and Shift+Return to navigate matches.
private struct SearchTextField: NSViewRepresentable {
    @Binding var text: String
    var onNext: () -> Void
    var onPrev: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.placeholderString = "Search…"
        field.isBordered = false
        field.drawsBackground = false
        field.font = .systemFont(ofSize: 13)
        field.focusRingType = .none
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        if field.stringValue != text {
            field.stringValue = text
        }
        // Grab focus on first appearance
        if text.isEmpty {
            DispatchQueue.main.async { field.window?.makeFirstResponder(field) }
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: SearchTextField
        init(_ parent: SearchTextField) { self.parent = parent }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.insertNewline(_:)) {
                let shiftDown = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
                if shiftDown { parent.onPrev() } else { parent.onNext() }
                return true
            }
            return false
        }
    }
}

// MARK: - Search Bar
struct SearchBar: View {
    @ObservedObject var search: SearchState
    var onClose: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
                .font(.system(size: 12))

            SearchTextField(
                text: $search.query,
                onNext: { search.next() },
                onPrev: { search.prev() }
            )
            .frame(maxWidth: .infinity)

            if !search.matches.isEmpty {
                Text("\(search.focusedMatch + 1)/\(search.matches.count)")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize()
            } else if !search.query.isEmpty {
                Text("No results")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }

            // Prev / Next
            Button(action: { search.prev() }) {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.borderless)
            .disabled(search.matches.count < 2)

            Button(action: { search.next() }) {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.borderless)
            .disabled(search.matches.count < 2)

            // Aa case-sensitive toggle
            Toggle(isOn: $search.caseSensitive) {
                Text("Aa")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
            }
            .toggleStyle(.button)
            .help("Case Sensitive")

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11))
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }
}

// MARK: - SwiftUI Result View
struct ResultView: View {
    @ObservedObject var state: OCRState
    @ObservedObject var search: SearchState
    var onCopy: () -> Void
    var onStop: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var copied = false

    private var bgColor: Color {
        colorScheme == .dark
            ? Color(red: 0x2a/255, green: 0x27/255, blue: 0x2e/255)
            : Color(red: 0xfa/255, green: 0xf2/255, blue: 0xf5/255)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Toolbar
            HStack {
                Text("Orchid OCR")
                    .font(.headline)
                Spacer()
                if state.isStreaming {
                    ProgressView()
                        .scaleEffect(0.6)
                        .frame(width: 16, height: 16)
                    Button(action: onStop) {
                        Image(systemName: "stop.fill")
                            .foregroundColor(.red)
                    }
                    .buttonStyle(.borderless)
                    .help("Stop streaming")
                }
                Button(copied ? "Copied ✅" : "Copy to Clipboard") {
                    onCopy()
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { copied = false }
                }
                .buttonStyle(.bordered)
                .disabled(state.text.isEmpty)
                .animation(.easeInOut(duration: 0.15), value: copied)
            }
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .padding(.bottom, 6)

            Divider()

            // Search bar — shown between toolbar and content, never overlaps text
            if search.isVisible {
                SearchBar(search: search, onClose: {
                    search.isVisible = false
                    search.query = ""
                    search.matches = []
                })
                .background(colorScheme == .dark
                    ? Color(white: 0.18)
                    : Color(white: 0.94))
                Divider()
            }

            // Text content
            ScrollViewReader { proxy in
                ScrollView {
                    Group {
                        if let err = state.errorMessage {
                            Text(err)
                                .font(.system(.body, design: .monospaced))
                                .foregroundColor(.red)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else if state.text.isEmpty {
                            Text("Waiting for OCR…")
                                .font(.system(.body, design: .monospaced))
                                .foregroundColor(.primary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            HighlightedText(text: state.text, search: search)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .id("bottom")
                }
                .onChange(of: state.text) { newText in
                    search.update(text: newText)
                    if !search.isVisible || search.query.isEmpty {
                        withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                    }
                }
                .onChange(of: search.query) { _ in search.update(text: state.text) }
                .onChange(of: search.caseSensitive) { _ in search.update(text: state.text) }
            }
            .padding(.bottom, 8)
        }
        .frame(minWidth: 200, minHeight: 100)
        .background(bgColor)
        // Cmd+F to open search
        .background(KeyEventInterceptor(onCmdF: {
            search.isVisible = true
        }))
    }
}

// MARK: - Key Event Interceptor
/// Catches Cmd+F from within the SwiftUI view hierarchy.
private struct KeyEventInterceptor: NSViewRepresentable {
    var onCmdF: () -> Void

    func makeNSView(context: Context) -> KeyCatchView {
        let v = KeyCatchView()
        v.onCmdF = onCmdF
        return v
    }
    func updateNSView(_ v: KeyCatchView, context: Context) {
        v.onCmdF = onCmdF
    }
}

final class KeyCatchView: NSView {
    var onCmdF: (() -> Void)?

    override var acceptsFirstResponder: Bool { false }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown,
           event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers == "f" {
            onCmdF?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

// MARK: - Result Panel (NSPanel subclass)
/// Intercepts ESC: closes search first if open, only then lets the panel close.
private final class ResultPanel: NSPanel {
    var searchState: SearchState?

    override func cancelOperation(_ sender: Any?) {
        if let s = searchState, s.isVisible {
            s.isVisible = false
            s.query = ""
            s.matches = []
        } else {
            super.cancelOperation(sender)
        }
    }
}

// MARK: - Panel Controller
final class ResultPanelController: NSObject {
    static let shared = ResultPanelController()

    private var panel: ResultPanel?
    private var ocrState = OCRState()
    private var searchState = SearchState()
    private var streamingTask: Task<Void, Never>?
    private var currentGeneration: Int = 0

    private override init() {}

    func show(imageURL: URL, mode: OCRMode = .markdown) {
        streamingTask?.cancel()
        streamingTask = nil

        currentGeneration += 1
        let generation = currentGeneration

        ocrState.text = ""
        ocrState.errorMessage = nil
        ocrState.isStreaming = true
        searchState.isVisible = false
        searchState.query = ""
        searchState.matches = []
        searchState.caseSensitive = false

        if panel == nil {
            createPanel()
        }
        panel?.makeKeyAndOrderFront(nil)

        streamingTask = OCRClient.recognize(
            imageURL: imageURL,
            mode: mode,
            onChunk: { [weak self] chunk in
                guard let self, self.currentGeneration == generation else { return }
                self.ocrState.text += chunk
            },
            onComplete: { [weak self] error in
                guard let self, self.currentGeneration == generation else { return }
                self.ocrState.isStreaming = false
                self.streamingTask = nil
                if let error = error {
                    self.ocrState.errorMessage = "Error: \(error.localizedDescription)"
                }
            }
        )
    }

    private func stopStreaming() {
        streamingTask?.cancel()
        streamingTask = nil
        ocrState.isStreaming = false
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

        let p = ResultPanel(
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
        p.searchState = searchState

        let resultView = ResultView(
            state: ocrState,
            search: searchState,
            onCopy: { [weak self] in
                guard let text = self?.ocrState.text, !text.isEmpty else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            },
            onStop: { [weak self] in
                self?.stopStreaming()
            }
        )

        p.contentView = NSHostingView(rootView: resultView)
        self.panel = p
    }
}

// MARK: - NSWindowDelegate
extension ResultPanelController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        stopStreaming()
        panel = nil
    }
}
