import SwiftUI
import AppKit
import AnglesiteCore

/// Slide-up drawer that hosts a deploy in progress and its terminal result.
///
/// Three states drive the body:
///   - `.running`  → spinner + streaming log
///   - `.succeeded` → deployed URL with Copy / Open buttons + log
///   - `.failed`   → reason banner + log + Copy-log
///
/// The `.blocked` phase is rendered by `BlockedDeploySheetView` (modal), not here — by the time
/// this drawer is on screen, the deploy has either reached wrangler or failed in a way the user
/// might want to read about.
struct DeployDrawerView: View {
    @Bindable var model: DeployModel
    let siteName: String

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            logScroller
            Divider()
            footer
        }
        .frame(maxWidth: .infinity)
        .frame(height: 320)
        .background(.regularMaterial)
    }

    // MARK: Sections

    private var header: some View {
        HStack(spacing: 10) {
            statusIcon
            VStack(alignment: .leading, spacing: 1) {
                Text(headerTitle).font(.headline)
                if let subtitle = headerSubtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if case .succeeded(let url, _) = model.phase {
                Button("Copy URL") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url.absoluteString, forType: .string)
                }
                Button("Open in browser") {
                    NSWorkspace.shared.open(url)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch model.phase {
        case .running:
            ProgressView().controlSize(.small)
        case .succeeded:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green).font(.title3)
        case .failed:
            Image(systemName: "exclamationmark.octagon.fill")
                .foregroundStyle(.red).font(.title3)
        case .idle, .blocked:
            Image(systemName: "shippingbox").font(.title3)
        }
    }

    private var headerTitle: String {
        switch model.phase {
        case .running: return "Deploying \(siteName)…"
        case .succeeded(let url, _): return url.absoluteString
        case .failed: return "Deploy failed"
        case .idle, .blocked: return siteName
        }
    }

    private var headerSubtitle: String? {
        switch model.phase {
        case .succeeded(_, let duration):
            return String(format: "deployed in %.1f s", duration)
        case .failed(let reason, let exit):
            return exit.map { "\(reason) (exit \($0))" } ?? reason
        default:
            return nil
        }
    }

    private var logScroller: some View {
        // Auto-scroll to the latest line as the log streams in. ScrollViewReader anchors on the
        // last line's id; on each append we scroll to it.
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(model.logLines) { line in
                        Text(line.text)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(line.stream == .stderr ? Color.red : Color.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(line.id)
                    }
                    if model.logLines.isEmpty {
                        Text("Waiting for output…")
                            .font(.caption).foregroundStyle(.tertiary)
                            .padding(.top, 4)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .background(Color(NSColor.textBackgroundColor))
            .onChange(of: model.logLines.count) { _, _ in
                if let last = model.logLines.last {
                    withAnimation(.linear(duration: 0.1)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            if case .failed = model.phase {
                Button("Copy log") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.logText, forType: .string)
                }
            }
            Spacer()
            Button(model.isRunning ? "Hide" : "Dismiss") {
                model.dismissDrawer()
            }
            .keyboardShortcut(.cancelAction)
            .disabled(false)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}
