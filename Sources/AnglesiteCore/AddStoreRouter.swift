// Sources/AnglesiteCore/AddStoreRouter.swift

/// What the owner is selling — mirrors the plugin's `add-store` skill intake question.
public enum StoreCategory: String, CaseIterable, Sendable {
    case service, donations, digitalDownloads, physicalGoods, software
}

/// Digital-download platform preference — only relevant when `category == .digitalDownloads`.
public enum DigitalPreference: String, CaseIterable, Sendable {
    case polar, lemonSqueezy
}

/// Physical-goods catalog size — only relevant when `category == .physicalGoods`.
public enum CatalogSize: String, CaseIterable, Sendable {
    case few, catalog
}

/// Deterministic routing for the "Add a Store" wizard entry point: given what the owner is
/// selling (and, where relevant, one follow-up answer), decides which existing
/// `IntegrationDescriptor` to open and with which provider preset. Mirrors the plugin's
/// `add-store` skill routing table, minus the revenue-tracking webhook step (deferred — see
/// docs/superpowers/specs/2026-07-05-add-store-wizard-router-design.md).
public enum AddStoreRouter {
    public struct Route: Sendable, Equatable {
        public let integrationID: IntegrationID
        public let presetProvider: String?
        public init(integrationID: IntegrationID, presetProvider: String?) {
            self.integrationID = integrationID
            self.presetProvider = presetProvider
        }
    }

    public static func route(
        category: StoreCategory,
        digitalPreference: DigitalPreference? = nil,
        catalogSize: CatalogSize? = nil
    ) -> Route {
        switch category {
        case .service:
            return Route(integrationID: .buyButton, presetProvider: "stripe")
        case .donations:
            return Route(integrationID: .donations, presetProvider: nil)
        case .digitalDownloads:
            switch digitalPreference {
            case .lemonSqueezy:
                return Route(integrationID: .lemonSqueezy, presetProvider: nil)
            case .polar, .none:
                return Route(integrationID: .buyButton, presetProvider: "polar")
            }
        case .physicalGoods:
            switch catalogSize {
            case .catalog:
                return Route(integrationID: .shopifyBuyButton, presetProvider: nil)
            case .few, .none:
                return Route(integrationID: .snipcart, presetProvider: nil)
            }
        case .software:
            return Route(integrationID: .paddle, presetProvider: nil)
        }
    }
}
