import SwiftUI
import AnglesiteCore

/// Onion Routing zone settings UI. Presents a single toggle for opportunistic_onion,
/// reads the current status from Cloudflare, and applies changes with the user's API token.
/// Follows the same pattern as HardenModel/HardenSheetView but focuses on a single setting.
@MainActor
@Observable
final class OnionRoutingModel {
    enum Phase: Equatable {
        case idle
        case loading
        case configured(enabled: Bool)
        case saving
        case error(message: String)
     }

    private(set) var phase: Phase = .idle
    internal let reader: any CloudflareReading
    private let writer: any CloudflareWriting
    internal let keychain: KeychainStore
    internal let domain: String
    private var inFlight: Task<Void, Never>?

    init(
        domain: String,
        reader: any CloudflareReading = HTTPCloudflareClient(),
        writer: any CloudflareWriting = HTTPCloudflareClient(),
        keychain: KeychainStore = KeychainStore()
     ) {
        self.domain = domain
        self.reader = reader
        self.writer = writer
        self.keychain = keychain
     }

    var isRunning: Bool {
        switch phase {
        case .loading, .saving: return true
        default: return false
        }
    }

    func load() {
        guard !isRunning else { return }
        inFlight?.cancel()
        inFlight = Task { @MainActor [weak self] in
            await self?.loadOnionRouting()
        }
    }

    func toggle() {
        guard case .configured(let enabled) = phase else { return }
        guard !isRunning else { return }

        inFlight?.cancel()
        inFlight = Task { @MainActor [weak self] in
            await self?.saveOnionRouting(enabled: !enabled)
        }
    }

    func dismiss() {
        inFlight?.cancel()
        inFlight = nil
        phase = .idle
    }
// MARK: - Private

private func apiToken() -> String? {
  if let env = ProcessInfo.processInfo.environment["CLOUDFLARE_API_TOKEN"], !env.isEmpty {
      return env
    }
  return try? keychain.readCloudflareToken()
}

/// Find the zone matching this site's domain, or fail with a clear error.
private func resolveZoneID(apiToken: String) async throws -> String {
    let zones = try await reader.zones(apiToken: apiToken)
    let normalized = domain.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    if let zone = zones.first(where: { $0.lowercased() == normalized }) {
        return zone
     }
    throw CloudflareError.api(message: "Zone '\(domain)' not found in account. Check your domain and API token permissions.")
}

private func loadOnionRouting() async {
    guard let token = apiToken() else {
        phase = .error(message: "No Cloudflare API token found. Add one in Settings → Credentials.")
        return
     }

    phase = .loading

    do {
        let zoneID = try await resolveZoneID(apiToken: token)
        let zonesState = try await reader.zoneState(zoneID: zoneID, domain: domain, apiToken: token)
        phase = .configured(enabled: zonesState.onionRouting)
     } catch let error as CloudflareError {
        phase = .error(message: cloudflareErrorMessage(error))
     } catch {
        phase = .error(message: "Failed to load zone settings: \(error.localizedDescription)")
     }
  }

  private func saveOnionRouting(enabled: Bool) async {
      guard let token = apiToken() else {
          phase = .error(message: "No Cloudflare API token found.")
          return
        }

      phase = .saving

      do {
          let zoneID = try await resolveZoneID(apiToken: token)
          try await writer.enableOnionRouting(zoneID: zoneID, enabled: enabled, apiToken: token)
          phase = .configured(enabled: enabled)
       } catch let error as CloudflareError {
          phase = .error(message: cloudflareErrorMessage(error))
       } catch {
          phase = .error(message: "Failed to save zone settings: \(error.localizedDescription)")
       }
    }

  private func cloudflareErrorMessage(_ error: CloudflareError) -> String {
      switch error {
      case .unauthorized:
          return "API token is unauthorized. Check that it has Zone Settings Edit permission."
      case .http(let status):
          return "Cloudflare API returned HTTP \(status)."
      case .api(let message):
          return "Cloudflare API error: \(message)"
      case .malformedResponse:
          return "Unexpected response from Cloudflare API."
       }
     }
 }

// MARK: - UI

/// Onion Routing zone settings UI. Presents a single toggle for opportunistic_onion,
/// reads the current status from Cloudflare, and applies changes with the user's API token.
/// Follows the same pattern as HardenModel/HardenSheetView but focuses on a single setting.
struct OnionRoutingSheetView: View {
@Bindable var model: OnionRoutingModel

var body: some View {
  VStack(spacing: 0) {
      header
      Divider()
      content
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      Divider()
      footer
   }
    .frame(minWidth: 520, idealWidth: 580, minHeight: 260, idealHeight: 300)
}

// MARK: - Header

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
   }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
}

@ViewBuilder
private var statusIcon: some View {
    switch model.phase {
    case .idle:
        Image(systemName: "network").font(.title3)
    case .loading, .saving:
        ProgressView().controlSize(.small)
    case .configured:
        Image(systemName: "checkmark.network").font(.title3)
             .foregroundStyle(.blue)
    case .error:
        Image(systemName: "exclamationmark.network").font(.title3)
             .foregroundStyle(.red)
     }
 }

 private var headerTitle: String {
     switch model.phase {
     case .idle:
         return "Onion Routing"
     case .loading:
         return "Loading zone settings…"
     case .configured:
         return "Onion Routing"
     case .saving:
         return "Saving settings…"
     case .error:
         return "Error"
      }
  }

  private var headerSubtitle: String? {
      switch model.phase {
      case .configured(let enabled):
          return enabled
               ? "Onion Routing is enabled"
               : "Onion Routing is disabled"
      case .loading:
          return "Reading \(model.domain) zone settings from Cloudflare"
      case .saving:
          return "Updating \(model.domain) zone settings in Cloudflare"
      case .error:
          return nil
      default:
          return nil
       }
   }

   // MARK: - Content

   private var content: some View {
       Group {
           switch model.phase {
           case .idle:
               infoView
           case .loading:
               loadingView
           case .configured:
               toggleView
           case .saving:
               savingView
           case .error:
               errorView
            }
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity)
       }

   private var infoView: some View {
       VStack(spacing: 16) {
           Spacer()
           Image(systemName: "network").font(.system(size: 40)).foregroundStyle(.secondary)
           Text("Onion Routing")
                .font(.headline)
           Text("Cloudflare's Onion Routing lets Tor Browser users reach your site over the Tor network without exiting through a third-party relay. No changes to your site or URLs.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
           Button("Load Settings") {
               model.load()
            }
             .buttonStyle(.borderedProminent)
           Spacer()
        }
         .padding(16)
       }

   private var toggleView: some View {
       VStack(spacing: 24) {
           Spacer()
           Image(systemName: "network").font(.system(size: 40)).foregroundStyle(.primary)
           Text("Onion Routing")
                .font(.headline)
           Text("Lets Tor Browser users reach your site over the Tor network without exiting through a third-party relay. No changes to your site or URLs.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
           Toggle(isOn: Binding(
               get: { model.phase == .configured(enabled: true) },
               set: { _ in model.toggle() }
            )) {
               Text("Enable Onion Routing")
                    .font(.subheadline)
            }
             .toggleStyle(.switch)
             .disabled(model.isRunning)
           Spacer()
        }
         .padding(16)
       }

   private var loadingView: some View {
       VStack(spacing: 12) {
           Spacer()
           ProgressView().controlSize(.large)
           Text("Reading \(model.domain) zone settings from Cloudflare…")
                .font(.callout)
                .foregroundStyle(.secondary)
           Spacer()
        }
         .padding(16)
       }

   private var savingView: some View {
       VStack(spacing: 12) {
           Spacer()
           ProgressView().controlSize(.large)
           Text("Updating \(model.domain) zone settings in Cloudflare…")
                .font(.callout)
                .foregroundStyle(.secondary)
           Spacer()
        }
         .padding(16)
       }

   private var errorView: some View {
       VStack(spacing: 12) {
           Spacer()
           Image(systemName: "exclamationmark.network").font(.system(size: 40)).foregroundStyle(.red)
           Text("Failed to load zone settings")
                .font(.headline)
           Spacer()
        }
         .padding(16)
       }

   // MARK: - Footer

   private var footer: some View {
       HStack {
           switch model.phase {
           case .idle:
               Button("Load") {
                   model.load()
                 }
                 .buttonStyle(.borderedProminent)
           case .loading:
               EmptyView()
           case .configured:
               Button(model.phase == .configured(enabled: true) ? "Disable" : "Enable") {
                   model.toggle()
                 }
                 .buttonStyle(.borderedProminent)
                 .disabled(model.isRunning)
           case .saving:
               EmptyView()
           case .error:
               Button("Try Again") {
                   model.load()
                 }
                 .buttonStyle(.borderedProminent)
             @unknown default:
               EmptyView()
            }

           Spacer()

           Button("Close") {
               model.dismiss()
             }
             .keyboardShortcut(.cancelAction)
         }
         .padding(.horizontal, 16)
         .padding(.vertical, 12)
       }
   }
