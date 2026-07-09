import SwiftUI
import AnglesiteCore

/// "Add Redirect?" prompt shown after a page delete succeeds (#530) — `SiteWindowModel.confirmDelete()`
/// sets `pendingRedirectOfferRoute` to the deleted page's route (never for posts, which carry no
/// route), and `SiteWindow` presents this sheet pre-filled with that route as the source. Saving
/// appends to `Source/redirects.json` via the injected `onSave` closure
/// (`SiteNavigatorModel.saveRedirect(source:destination:code:)`); dismissing without saving is a
/// no-op, matching the delete's "you can always add one later in Site Settings → Redirects" framing.
struct AddRedirectSheet: View {
    let source: String
    let onSave: (_ destination: String, _ code: RedirectsStore.RedirectEntry.Code) async -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var destination: String = ""
    @State private var code: RedirectsStore.RedirectEntry.Code = .permanent
    @State private var saveError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add Redirect").font(.headline)
            Text("From \(source)")
                .foregroundStyle(.secondary)
            TextField("Destination path (e.g. /new-page)", text: $destination)
                .textFieldStyle(.roundedBorder)
            Picker("Type", selection: $code) {
                Text("Permanent (301)").tag(RedirectsStore.RedirectEntry.Code.permanent)
                Text("Temporary (302)").tag(RedirectsStore.RedirectEntry.Code.temporary)
            }
            .pickerStyle(.segmented)
            if let saveError {
                Label(saveError, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.callout)
            }
            HStack {
                Spacer()
                Button("Skip") { dismiss() }
                Button("Save") {
                    Task {
                        let trimmed = destination.trimmingCharacters(in: .whitespacesAndNewlines)
                        if await onSave(trimmed, code) {
                            dismiss()
                        } else {
                            saveError = "Couldn't save the redirect. Check the destination and try again."
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(destination.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding()
        .frame(minWidth: 360)
    }
}

struct IdentifiableRoute: Identifiable {
    let value: String
    var id: String { value }
    init(_ value: String) { self.value = value }
}
