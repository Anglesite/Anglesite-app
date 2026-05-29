import SwiftUI
import AnglesiteCore

/// The New Site wizard sheet. Presented from SitesLauncherView; calls `onComplete(siteID)`
/// when the site is scaffolded and registered.
struct NewSiteWizard: View {
    @Bindable var model: NewSiteWizardModel
    let scaffolder: SiteScaffolder
    let onComplete: (String) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            content
            Divider()
            footer
        }
        .frame(width: 520, height: 460)
    }

    @ViewBuilder private var content: some View {
        switch model.step {
        case .type:     typeStep
        case .details:  detailsStep
        case .look:     lookStep
        case .content:  contentStep
        case .building: buildingStep
        }
    }

    private var typeStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("What kind of site?").font(.title2.bold())
            ForEach(SiteType.allCases, id: \.self) { type in
                Button { model.choose(type: type) } label: {
                    HStack {
                        Image(systemName: type.symbol).frame(width: 24)
                        Text(type.label)
                        Spacer()
                        if model.draft.siteType == type { Image(systemName: "checkmark") }
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain).padding(.vertical, 4)
            }
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var detailsStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Name your site").font(.title2.bold())
            TextField("Site name", text: $model.draft.name)
            Text("Folder: ~/Sites/\(model.slugPreview)").font(.caption).foregroundStyle(.secondary)
            if let err = model.detailsError { Text(err).font(.caption).foregroundStyle(.red) }
            Text("Tagline (optional)").font(.headline).padding(.top, 8)
            TextField("A short line about your site", text: $model.draft.tagline)
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var lookStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Pick a look").font(.title2.bold())
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150))], spacing: 12) {
                    ForEach(model.catalog.themes) { theme in
                        Button { model.draft.themeID = theme.id } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 0) {
                                    ForEach(theme.swatch, id: \.self) { hex in
                                        Color(hex: hex).frame(height: 28)
                                    }
                                }.clipShape(RoundedRectangle(cornerRadius: 6))
                                Text(theme.name).font(.subheadline.bold())
                                Text(theme.blurb).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                            }
                            .padding(8)
                            .overlay(RoundedRectangle(cornerRadius: 8)
                                .stroke(model.draft.themeID == theme.id ? Color.accentColor : Color.clear, lineWidth: 2))
                        }.buttonStyle(.plain)
                    }
                }
            }
        }.padding(24)
    }

    private var contentStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("First words").font(.title2.bold())
            Text("Homepage headline").font(.headline)
            TextField("Welcome to \u{2026}", text: $model.draft.headline)
            Text("One line about you (optional)").font(.headline).padding(.top, 8)
            TextField("What you do, in a sentence", text: $model.draft.blurb)
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var buildingStep: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Building your site\u{2026}").font(.title2.bold())
            ForEach(Array(model.progress.enumerated()), id: \.offset) { _, s in
                Text(label(for: s)).font(.callout)
            }
            if case .failed(_, let msg) = model.fatal {
                Text(msg).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func label(for step: SiteScaffolder.ScaffoldStep) -> String {
        switch step {
        case .creatingFolder: return "\u{2705} Created the site folder"
        case .copyingTemplate: return "\u{2705} Copied the template"
        case .applyingTheme: return "\u{2705} Applied your theme"
        case .writingContent: return "\u{2705} Wrote your words"
        case .installing: return "\u{23F3} Installing\u{2026}"
        case .registering: return "\u{2705} Registering"
        case .warning(_, let m): return "\u{26A0}\u{FE0F} \(m)"
        case .failed(_, let m): return "\u{274C} \(m)"
        case .done: return "\u{2705} Done"
        }
    }

    @ViewBuilder private var footer: some View {
        HStack {
            if model.step != .type && model.step != .building {
                Button("Back") { model.back() }
            }
            Spacer()
            Button("Cancel") { onCancel() }
            if model.step == .content {
                Button("Create Site") {
                    Task { if let id = await model.build(using: scaffolder) { onComplete(id) } }
                }.keyboardShortcut(.defaultAction).disabled(!model.canContinue)
            } else if model.step != .building {
                Button("Continue") { model.advance() }
                    .keyboardShortcut(.defaultAction).disabled(!model.canContinue)
            } else if model.completedSiteID == nil && model.fatal != nil {
                Button("Close") { onCancel() }
            }
        }.padding(.horizontal, 16).padding(.vertical, 10)
    }
}

/// Minimal hex -> Color for theme swatches (#rrggbb).
extension Color {
    init(hex: String) {
        let h = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var rgb: UInt64 = 0
        Scanner(string: h).scanHexInt64(&rgb)
        self = Color(.sRGB,
                     red: Double((rgb >> 16) & 0xFF) / 255,
                     green: Double((rgb >> 8) & 0xFF) / 255,
                     blue: Double(rgb & 0xFF) / 255)
    }
}
