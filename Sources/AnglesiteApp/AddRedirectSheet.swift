import SwiftUI
import AnglesiteCore

/// "Add Redirect?" prompt shown after a page or post delete succeeds (#530, #584) —
/// `SiteWindowModel.confirmDelete()` sets `pendingRedirectOfferRoute` to the deleted item's route
/// (a page's `route`, or a post's `postRoute(for:)`), and `SiteWindow` presents this sheet
/// pre-filled with that route as the source. Saving
/// appends to `Source/redirects.json` via the injected `onSave` closure
/// (`SiteNavigatorModel.saveRedirect(source:destination:code:)`); dismissing without saving is a
/// no-op, matching the delete's "you can always add one later in Site Settings → Redirects" framing.
struct AddRedirectSheet: View {
    let source: String
    /// Returns `nil` on success, or the underlying error message to display on failure — so a
    /// validation rejection (e.g. a duplicate source) surfaces its real reason here rather than a
    /// generic message.
    let onSave: (_ destination: String, _ code: RedirectsStore.RedirectEntry.Code) async -> String?

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
                        if let error = await onSave(trimmed, code) {
                            saveError = error
                        } else {
                            dismiss()
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
