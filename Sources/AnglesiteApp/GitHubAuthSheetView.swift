// Developer ID build only — drives the `gh auth login` device-code flow, which the sandboxed
// MAS build omits (no bundled `gh`). See SettingsView's GitHubAuthRow.
#if !ANGLESITE_MAS
import SwiftUI
import AppKit
import AnglesiteCore

/// Sheet UI for the `gh auth login` device-code flow. Owns its own `GitHubAuthFlow` and
/// observes the event stream; the parent only binds the `isPresented` flag and (optionally)
/// reacts to completion via `onResult`.
///
/// We do not store any GitHub credentials on the app side — that's gh's job. This view's
/// responsibility is purely to surface the verification URL + one-time code so the user can
/// finish the flow in a browser, then dismiss once gh reports completion.
struct GitHubAuthSheetView: View {
    /// Called once gh has reported either success or failure. The parent typically dismisses
    /// the sheet on success and surfaces the error on failure (the sheet keeps the error
    /// visible until the user clicks Close).
    let onResult: (Result) -> Void

    enum Result: Equatable {
        case authenticated
        case failed(reason: String)
        case cancelled
    }

    @State private var phase: Phase = .starting
    @State private var task: Task<Void, Never>?

    private enum Phase: Equatable {
        case starting
        case prompting(verificationURL: URL, userCode: String)
        case waiting(verificationURL: URL, userCode: String)
        case finished(Result)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            body(for: phase)
            Divider()
            footer
        }
        .padding(20)
        .frame(width: 460)
        .task { startFlow() }
        .onDisappear { task?.cancel() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Sign in to GitHub")
                .font(.headline)
            Text("Anglesite is launching `gh auth login`. GitHub will display a one-time code page in your browser — paste the code below.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func body(for phase: Phase) -> some View {
        switch phase {
        case .starting:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Starting `gh auth login`…").font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

        case .prompting(let url, let code), .waiting(let url, let code):
            VStack(alignment: .leading, spacing: 12) {
                codeRow(code: code)
                urlRow(url: url)
                if case .waiting = phase {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Waiting for authentication…").font(.callout).foregroundStyle(.secondary)
                    }
                }
            }

        case .finished(.authenticated):
            Label("Signed in to GitHub.", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.callout)

        case .finished(.failed(let reason)):
            VStack(alignment: .leading, spacing: 6) {
                Label("Sign-in failed", systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
                    .font(.callout)
                Text(reason)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

        case .finished(.cancelled):
            Label("Cancelled.", systemImage: "xmark.circle")
                .foregroundStyle(.secondary)
                .font(.callout)
        }
    }

    private func codeRow(code: String) -> some View {
        HStack(spacing: 8) {
            Text("One-time code")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            Text(code)
                .font(.system(.title3, design: .monospaced).weight(.semibold))
                .textSelection(.enabled)
            Button("Copy") {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(code, forType: .string)
            }
            .controlSize(.small)
        }
    }

    private func urlRow(url: URL) -> some View {
        HStack(spacing: 8) {
            Text("Verification URL")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            Link(url.absoluteString, destination: url)
                .font(.system(.callout, design: .monospaced))
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            switch phase {
            case .finished:
                Button("Close") { handleClose() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            default:
                Button("Cancel") { handleCancel() }
                    .keyboardShortcut(.cancelAction)
            }
        }
    }

    // MARK: Flow plumbing

    private func startFlow() {
        guard task == nil else { return }
        let flow = GitHubAuthFlow()
        task = Task { @MainActor in
            for await event in await flow.run() {
                switch event {
                case .devicePrompt(let url, let code):
                    NSWorkspace.shared.open(url)
                    phase = .waiting(verificationURL: url, userCode: code)
                case .authenticated:
                    phase = .finished(.authenticated)
                case .failed(let reason):
                    phase = .finished(.failed(reason: reason))
                }
            }
        }
    }

    private func handleClose() {
        if case .finished(let result) = phase {
            onResult(result)
        } else {
            onResult(.cancelled)
        }
    }

    private func handleCancel() {
        task?.cancel()
        task = nil
        onResult(.cancelled)
    }
}

#Preview {
    GitHubAuthSheetView { _ in }
}
#endif
