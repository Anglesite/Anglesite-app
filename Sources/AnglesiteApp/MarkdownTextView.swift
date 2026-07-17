import SwiftUI
import AppKit
import MarkdownEngine

/// SwiftUI seam over swift-markdown-engine's live-styled Markdown editor (#797; spec §A.3,
/// substrate decided by the #796 survey addendum). The ONLY file in the app that imports
/// MarkdownEngine — call sites (editor routing, menu commands, find bar) speak
/// `MarkdownEditorController`, so the substrate stays swappable.
struct MarkdownTextView: View {
    @Binding var text: String
    let controller: MarkdownEditorController
    var documentId: String
    /// `true` for form embedding (typed-entry body): the editor grows to fit and the enclosing
    /// Form scrolls. `false` (default) scrolls internally — the main-pane file editor.
    var fitsContent = false

    var body: some View {
        VStack(spacing: 0) {
            if controller.isFindBarVisible {
                MarkdownFindBar(controller: controller)
                Divider()
            }
            EngineHost(text: $text, controller: controller, documentId: documentId, fitsContent: fitsContent)
        }
    }
}

/// Bridges the engine's own `NSViewRepresentable` through an `NSHostingView` inside a
/// first-responder-tracking container so `MarkdownEditorFocusRegistry` always knows which
/// editor is focused (two can share a window: main pane + inspector).
private struct EngineHost: NSViewRepresentable {
    @Binding var text: String
    let controller: MarkdownEditorController
    var documentId: String
    var fitsContent: Bool

    func makeNSView(context: Context) -> FocusTrackingContainerView {
        let container = FocusTrackingContainerView(hosting: NSHostingView(rootView: engineView))
        container.onFocusChange = { [weak controller] focused in
            guard let controller else { return }
            if focused {
                MarkdownEditorFocusRegistry.shared.activate(controller)
            } else {
                MarkdownEditorFocusRegistry.shared.resign(controller)
            }
        }
        controller.focusEditor = { [weak container] in
            container?.focusTextView()
        }
        return container
    }

    func updateNSView(_ nsView: FocusTrackingContainerView, context: Context) {
        nsView.hostingView.rootView = engineView
    }

    static func dismantleNSView(_ nsView: FocusTrackingContainerView, coordinator: ()) {
        nsView.prepareForRemoval()
    }

    private var engineView: NativeTextViewWrapper {
        NativeTextViewWrapper(
            text: $text,
            configuration: Self.configuration(for: controller, fitsContent: fitsContent),
            documentId: documentId
        )
    }

    private static func configuration(
        for controller: MarkdownEditorController, fitsContent: Bool
    ) -> MarkdownEditorConfiguration {
        let names = controller.busNames
        let bus = MarkdownEditorBus(
            applyBoldRequest: names.applyBold,
            applyItalicRequest: names.applyItalic,
            applyHeadingRequest: names.applyHeading,
            applyStrikethroughRequest: names.applyStrikethrough,
            applyInlineCodeRequest: names.applyInlineCode,
            applyLinkRequest: names.applyLink,
            findClearHighlights: names.findClearHighlights,
            findQuery: names.findQuery,
            findResults: names.findResults,
            replaceCurrent: names.replaceCurrent,
            replaceAll: names.replaceAll
        )
        return MarkdownEditorConfiguration(
            services: MarkdownEditorServices(bus: bus),
            // Fork-added toggle (Anglesite/swift-markdown-engine): Markdown sources need straight
            // quotes — smart quotes would corrupt frontmatter and code samples (addendum §2).
            spellChecking: SpellCheckingPolicy(automaticQuoteSubstitution: false),
            heightBehavior: fitsContent ? .fitsContent : .scrolls,
            // GFM strikethrough is in the v1 construct set (spec §A.2); it's an opt-in
            // engine extension.
            extensions: [StrikethroughExtension()]
        )
    }
}

/// Container that hosts the engine's view hierarchy and reports whether the window's first
/// responder lives inside it. Field-editor responders (find bar / inspector text fields) are
/// attributed to their owning control, so focus in a text field correctly reads as "outside".
final class FocusTrackingContainerView: NSView {
    let hostingView: NSHostingView<NativeTextViewWrapper>
    var onFocusChange: ((Bool) -> Void)?
    private var observation: NSKeyValueObservation?
    private var isFocused = false

    init(hosting: NSHostingView<NativeTextViewWrapper>) {
        self.hostingView = hosting
        super.init(frame: .zero)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: trailingAnchor),
            hosting.topAnchor.constraint(equalTo: topAnchor),
            hosting.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observation?.invalidate()
        observation = nil
        guard let window else {
            update(focused: false)
            return
        }
        observation = window.observe(\.firstResponder, options: [.initial, .new]) { [weak self] _, _ in
            // NSWindow mutates firstResponder on the main thread; the hop is for the compiler.
            MainActor.assumeIsolated { self?.refreshFocus() }
        }
    }

    /// Restores keyboard focus to the engine's text view (find-bar dismissal).
    func focusTextView() {
        if let textView = Self.firstDescendantTextView(of: self) {
            window?.makeFirstResponder(textView)
        }
    }

    func prepareForRemoval() {
        update(focused: false)
        onFocusChange = nil
        observation?.invalidate()
        observation = nil
    }

    private func refreshFocus() {
        guard let window else {
            update(focused: false)
            return
        }
        var responderView = window.firstResponder as? NSView
        if let text = window.firstResponder as? NSText, text.isFieldEditor {
            responderView = text.delegate as? NSView
        }
        update(focused: responderView?.isDescendant(of: self) ?? false)
    }

    private func update(focused: Bool) {
        guard focused != isFocused else { return }
        isFocused = focused
        onFocusChange?(focused)
    }

    private static func firstDescendantTextView(of view: NSView) -> NSTextView? {
        for sub in view.subviews {
            if let textView = sub as? NSTextView { return textView }
            if let found = firstDescendantTextView(of: sub) { return found }
        }
        return nil
    }
}
