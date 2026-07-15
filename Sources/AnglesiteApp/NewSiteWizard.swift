import SwiftUI
import AppKit
import UniformTypeIdentifiers
import AnglesiteCore
#if canImport(ImagePlayground)
import ImagePlayground
#endif

/// The New Site wizard sheet. Presented from SitesLauncherView; calls `onComplete(siteID)`
/// when the site is scaffolded and registered.
struct NewSiteWizard: View {
    private static let cloudflareDomainsURL = URL(string: "https://www.cloudflare.com/products/registrar/")!

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
        .modifier(ImagePlaygroundPresenter(model: model))
    }

    @ViewBuilder private var content: some View {
        switch model.step {
        case .details:  detailsStep
        case .type:     typeStep
        case .look:     lookStep
        case .content:  contentStep
        case .save:     saveStep
        case .building: buildingStep
        }
    }

    private var typeStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("What kind of website are you creating?").font(.title2.bold())
            ForEach(SiteType.allCases, id: \.self) { type in
                Button { model.choose(type: type) } label: {
                    HStack {
                        Image(systemName: type.symbol).frame(width: 24)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(type.label)
                            Text(type.description)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if model.draft.siteType == type {
                            Image(systemName: "checkmark").accessibilityHidden(true)
                        }
                    }.contentShape(Rectangle())
                }
                .buttonStyle(.plain).padding(.vertical, 4)
                .accessibilityLabel("\(type.label). \(type.description)")
                .accessibilityValue(model.draft.siteType == type ? "Selected" : "")
            }
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var detailsStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Create a website").font(.title2.bold())
            Text("Website name").font(.headline)
            TextField("My Website", text: $model.draft.name)
            if let err = model.detailsError {
                Text(err).font(.caption).foregroundStyle(.red)
                    .accessibilityLabel("Error")
                    .accessibilityValue(err)
            }
            Text("Domain").font(.headline).padding(.top, 8)
            Picker("Domain", selection: $model.draft.domainChoice) {
                Text("Buy a domain").tag(NewSiteDomainChoice.buy)
                Text("Transfer an existing domain").tag(NewSiteDomainChoice.transfer)
                Text("Set this up later").tag(NewSiteDomainChoice.later)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            domainChoiceDetails
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder private var domainChoiceDetails: some View {
        switch model.draft.domainChoice {
        case .buy:
            Link("Open Cloudflare Domains", destination: Self.cloudflareDomainsURL)
                .font(.caption)
        case .transfer:
            TextField("example.com", text: $model.draft.domain)
                .textFieldStyle(.roundedBorder)
            Text("Enter the domain you already own.")
                .font(.caption).foregroundStyle(.secondary)
        case .later:
            Text("Use a temporary Cloudflare Workers domain later, such as \(model.cloudflareDevPreview).")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var lookStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Pick a color scheme").font(.title2.bold())
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    customColorScheme
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150))], spacing: 12) {
                        ForEach(model.catalog.themes) { theme in
                            Button { model.draft.themeID = theme.id } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack(spacing: 0) {
                                        ForEach(theme.swatch, id: \.self) { hex in
                                            Color(hex: hex).frame(height: 28)
                                        }
                                    }.clipShape(RoundedRectangle(cornerRadius: 6))
                                    .accessibilityHidden(true)
                                    Text(theme.name).font(.subheadline.bold())
                                    Text(theme.blurb).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                                }
                                .padding(8)
                                .overlay(RoundedRectangle(cornerRadius: 8)
                                    .stroke(model.draft.themeID == theme.id ? Color.accentColor : Color.clear, lineWidth: 2))
                            }
                            .buttonStyle(.plain)
                            .accessibilityElement(children: .combine)
                            .accessibilityValue(model.draft.themeID == theme.id ? "Selected" : "")
                        }
                    }
                }
            }
        }.padding(24)
    }

    private var customColorScheme: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { model.draft.themeID = CustomTheme.id } label: {
                HStack(alignment: .top, spacing: 10) {
                    HStack(spacing: 0) {
                        Color(hex: model.draft.customPrimaryColor)
                        Color(hex: model.draft.customAccentColor)
                    }
                    .frame(width: 64, height: 32)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Custom").font(.subheadline.bold())
                        Text("Choose your own colors and add a logo.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if model.draft.themeID == CustomTheme.id {
                        Image(systemName: "checkmark").accessibilityHidden(true)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(8)
            .overlay(RoundedRectangle(cornerRadius: 8)
                .stroke(model.draft.themeID == CustomTheme.id ? Color.accentColor : Color.clear, lineWidth: 2))
            .accessibilityLabel("Custom. Choose your own colors and add a logo.")
            .accessibilityValue(model.draft.themeID == CustomTheme.id ? "Selected" : "")

            if model.draft.themeID == CustomTheme.id {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        ColorPicker("Primary color", selection: colorBinding(\.customPrimaryColor), supportsOpacity: false)
                        ColorPicker("Accent color", selection: colorBinding(\.customAccentColor), supportsOpacity: false)
                    }
                    HStack {
                        Button {
                            chooseLogo()
                        } label: {
                            Label(model.draft.logoURL == nil ? "Upload Logo\u{2026}" : "Change Logo\u{2026}",
                                  systemImage: "photo.badge.plus")
                        }
                        if let logoURL = model.draft.logoURL {
                            Text(logoURL.lastPathComponent)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Button("Remove") { model.draft.logoURL = nil }
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 4)
            }
        }
    }

    private var contentStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("First words").font(.title2.bold())
            Text("Homepage headline").font(.headline)
            TextField("Welcome to \u{2026}", text: $model.draft.headline)
            Text("Short description (optional)").font(.headline).padding(.top, 8)
            TextField("What this website is about, in a sentence", text: $model.draft.blurb)
            heroImageSection
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var saveStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Save your website").font(.title2.bold())
            Text("Choose where to save the local .anglesite file.")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// Optional Image Playground hero image (#92). Hidden entirely when Apple Intelligence /
    /// Image Playground isn't available on this device — sites work fine without it.
    @ViewBuilder private var heroImageSection: some View {
        if isImagePlaygroundAvailable {
            Divider().padding(.vertical, 4)
            Text("Hero image (optional)").font(.headline)
            TextField("Abstract shapes in my brand colors, no text", text: $model.draft.heroImagePrompt)
            if model.hasHeroImage {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        .accessibilityHidden(true)
                    Text("Hero image ready").font(.callout)
                    Spacer()
                    Button("Regenerate\u{2026}") { model.showingImagePlayground = true }
                    Button("Remove") { model.setHeroImage(nil) }
                }
            } else {
                Button {
                    model.showingImagePlayground = true
                } label: {
                    Label("Generate hero image\u{2026}", systemImage: "wand.and.stars")
                }
                Text("Uses Apple Intelligence on your device. No content leaves your Mac without your say-so.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// True only when the Image Playground sheet can actually present (Apple Intelligence enabled,
    /// OS new enough). Compiled-out / false on platforms without the framework.
    private var isImagePlaygroundAvailable: Bool {
        #if canImport(ImagePlayground)
        if #available(macOS 26.0, *) {
            return ImagePlaygroundViewController.isAvailable
        }
        #endif
        return false
    }

    private var buildingStep: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Building your website\u{2026}").font(.title2.bold())
            ForEach(Array(model.progress.enumerated()), id: \.offset) { _, s in
                Text(label(for: s)).font(.callout)
                    // The visible label leads with an emoji status glyph; give VoiceOver clean text.
                    .accessibilityLabel(accessibilityLabel(for: s))
            }
            if case .failed(_, let msg) = model.fatal {
                Text(msg).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                    .accessibilityLabel("Build failed")
                    .accessibilityValue(msg)
            }
            if model.completedSiteID != nil && model.hasWarnings {
                Text("Your website was created, but something above needs attention before it can preview. You can open it anyway and fix it from the website window.")
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    .accessibilityLabel("Your website was created with warnings. You can open it anyway and fix it from the website window.")
            }
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func label(for step: SiteScaffolder.ScaffoldStep) -> String {
        switch step {
        case .creatingFolder: return "\u{2705} Created the website file"
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

    /// Emoji-free version of `label(for:)` for VoiceOver, which would otherwise read the status
    /// glyph as "check mark", "hourglass", etc. before the actual message.
    private func accessibilityLabel(for step: SiteScaffolder.ScaffoldStep) -> String {
        switch step {
        case .creatingFolder:    return "Created the website file"
        case .copyingTemplate:   return "Copied the template"
        case .applyingTheme:     return "Applied your theme"
        case .writingContent:    return "Wrote your words"
        case .installing:        return "Installing…"
        case .registering:       return "Registering"
        case .warning(_, let m): return "Warning: \(m)"
        case .failed(_, let m):  return "Failed: \(m)"
        case .done:              return "Done"
        }
    }

    @ViewBuilder private var footer: some View {
        HStack {
            if model.step != .details && model.step != .building {
                Button("Back") { model.back() }
            }
            Spacer()
            // No Cancel once building starts: the scaffold pipeline isn't cancellable and
            // always reaches .done or .failed (failure shows Close below), so cancelling
            // mid-build would leak the in-flight work and the MAS security scope.
            if model.step != .building {
                Button("Cancel") { onCancel() }
            }
            if model.step == .save {
                Button("Save Website\u{2026}") {
                    saveWebsite()
                }.keyboardShortcut(.defaultAction).disabled(!model.canContinue)
            } else if model.step != .building {
                Button("Continue") { model.advance() }
                    .keyboardShortcut(.defaultAction).disabled(!model.canContinue)
            } else if let id = model.completedSiteID, model.hasWarnings {
                Button("Open Website Anyway") { onComplete(id) }.keyboardShortcut(.defaultAction)
            } else if model.completedSiteID == nil && model.fatal != nil {
                Button("Close") { onCancel() }
            }
        }.padding(.horizontal, 16).padding(.vertical, 10)
    }

    @MainActor private func saveWebsite() {
        let panel = NSSavePanel()
        panel.title = String(localized: "Save Your Website")
        panel.prompt = String(localized: "Save")
        panel.allowedContentTypes = [.anglesiteSite]
        panel.canCreateDirectories = true
        panel.directoryURL = model.draft.saveDirectory ?? model.defaultSaveDirectory
        panel.nameFieldStringValue = model.draft.saveFileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? model.defaultSaveFileName
            : model.draft.saveFileName
        if panel.runModal() == .OK {
            guard let url = panel.url else { return }
            model.draft.saveDirectory = url.deletingLastPathComponent()
            model.draft.saveFileName = url.lastPathComponent
            // Auto-open only on a clean build; with warnings, stay put so the owner sees them (#229).
            Task {
                _ = await model.build(using: scaffolder)
                if model.didCompleteCleanly, let id = model.completedSiteID { onComplete(id) }
            }
        }
    }

    @MainActor private func chooseLogo() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Choose Logo")
        panel.prompt = String(localized: "Choose")
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        if panel.runModal() == .OK {
            model.draft.logoURL = panel.url
            model.draft.themeID = CustomTheme.id
        }
    }

    private func colorBinding(_ keyPath: WritableKeyPath<NewSiteDraft, String>) -> Binding<Color> {
        Binding {
            Color(hex: model.draft[keyPath: keyPath])
        } set: { newColor in
            model.draft[keyPath: keyPath] = newColor.hexString ?? model.draft[keyPath: keyPath]
            model.draft.themeID = CustomTheme.id
        }
    }
}

/// Presents the Image Playground sheet for the wizard's hero-image action (#92).
///
/// Isolated in a `ViewModifier` so the availability `#if`/`#available` gating lives in one place
/// and `NewSiteWizard.body` stays clean. On platforms without the framework (or older OSes), this
/// is an inert pass-through and the button that drives `showingImagePlayground` is never shown.
private struct ImagePlaygroundPresenter: ViewModifier {
    @Bindable var model: NewSiteWizardModel

    func body(content: Content) -> some View {
        #if canImport(ImagePlayground)
        if #available(macOS 26.0, *) {
            content.imagePlaygroundSheet(
                isPresented: $model.showingImagePlayground,
                concepts: model.heroImageConcepts.map { ImagePlaygroundConcept.text($0) }
            ) { url in
                // Image Playground hands back a URL to the generated image in a temporary
                // location; stash it on the draft so the scaffolder copies it into the site.
                model.setHeroImage(url)
            }
        } else {
            content
        }
        #else
        content
        #endif
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

    var hexString: String? {
        guard let color = NSColor(self).usingColorSpace(.sRGB) ?? NSColor(self).usingColorSpace(.deviceRGB) else { return nil }
        let red = Self.clampedByte(color.redComponent)
        let green = Self.clampedByte(color.greenComponent)
        let blue = Self.clampedByte(color.blueComponent)
        return String(format: "#%02x%02x%02x", red, green, blue)
    }

    private static func clampedByte(_ component: CGFloat) -> Int {
        min(255, max(0, Int(round(component * 255))))
    }
}
