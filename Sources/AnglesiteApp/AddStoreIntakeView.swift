// Sources/AnglesiteApp/AddStoreIntakeView.swift
import SwiftUI
import AnglesiteCore

/// Short intake for the "Add a Store" router: what the owner is selling, plus the one follow-up
/// question the plugin's `add-store` skill asks for that category. Calls `onRoute` with the
/// resolved `AddStoreRouter.Route`, then the caller dismisses this sheet and hands the route to
/// `IntegrationWizardModel.startFromRouter(_:)`.
struct AddStoreIntakeView: View {
    let onRoute: (AddStoreRouter.Route) -> Void

    @State private var category: StoreCategory = .service
    @State private var digitalPreference: DigitalPreference = .polar
    @State private var catalogSize: CatalogSize = .few
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Picker("What are you selling?", selection: $category) {
                    Text("A service or one-off").tag(StoreCategory.service)
                    Text("Donations or fundraising").tag(StoreCategory.donations)
                    Text("Digital downloads").tag(StoreCategory.digitalDownloads)
                    Text("Physical goods").tag(StoreCategory.physicalGoods)
                    Text("Software or SaaS").tag(StoreCategory.software)
                }
                if category == .digitalDownloads {
                    Picker("Which platform?", selection: $digitalPreference) {
                        Text("Polar").tag(DigitalPreference.polar)
                        Text("Lemon Squeezy").tag(DigitalPreference.lemonSqueezy)
                    }
                }
                if category == .physicalGoods {
                    Picker("How many products?", selection: $catalogSize) {
                        Text("Just a few").tag(CatalogSize.few)
                        Text("A full, growing catalog").tag(CatalogSize.catalog)
                    }
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Continue") {
                    onRoute(AddStoreRouter.route(
                        category: category,
                        digitalPreference: category == .digitalDownloads ? digitalPreference : nil,
                        catalogSize: category == .physicalGoods ? catalogSize : nil
                    ))
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .frame(minWidth: 420, idealWidth: 420, minHeight: 260, idealHeight: 300)
    }
}
