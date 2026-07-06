// Tests/AnglesiteCoreTests/AddStoreRouterTests.swift
import Testing
@testable import AnglesiteCore

@Suite struct AddStoreRouterTests {
    @Test func serviceRoutesToStripeBuyButton() {
        let route = AddStoreRouter.route(category: .service)
        #expect(route == AddStoreRouter.Route(integrationID: .buyButton, presetProvider: "stripe"))
    }

    @Test func donationsRoutesToDonationsDescriptor() {
        let route = AddStoreRouter.route(category: .donations)
        #expect(route == AddStoreRouter.Route(integrationID: .donations, presetProvider: nil))
    }

    @Test func digitalDownloadsDefaultsToPolar() {
        let route = AddStoreRouter.route(category: .digitalDownloads)
        #expect(route == AddStoreRouter.Route(integrationID: .buyButton, presetProvider: "polar"))
    }

    @Test func digitalDownloadsExplicitPolar() {
        let route = AddStoreRouter.route(category: .digitalDownloads, digitalPreference: .polar)
        #expect(route == AddStoreRouter.Route(integrationID: .buyButton, presetProvider: "polar"))
    }

    @Test func digitalDownloadsLemonSqueezy() {
        let route = AddStoreRouter.route(category: .digitalDownloads, digitalPreference: .lemonSqueezy)
        #expect(route == AddStoreRouter.Route(integrationID: .lemonSqueezy, presetProvider: nil))
    }

    @Test func physicalGoodsDefaultsToSnipcart() {
        let route = AddStoreRouter.route(category: .physicalGoods)
        #expect(route == AddStoreRouter.Route(integrationID: .snipcart, presetProvider: nil))
    }

    @Test func physicalGoodsFewIsSnipcart() {
        let route = AddStoreRouter.route(category: .physicalGoods, catalogSize: .few)
        #expect(route == AddStoreRouter.Route(integrationID: .snipcart, presetProvider: nil))
    }

    @Test func physicalGoodsCatalogIsShopify() {
        let route = AddStoreRouter.route(category: .physicalGoods, catalogSize: .catalog)
        #expect(route == AddStoreRouter.Route(integrationID: .shopifyBuyButton, presetProvider: nil))
    }

    @Test func softwareRoutesToPaddle() {
        let route = AddStoreRouter.route(category: .software)
        #expect(route == AddStoreRouter.Route(integrationID: .paddle, presetProvider: nil))
    }

    @Test func followUpParametersIgnoredOutsideTheirCategory() {
        // catalogSize only matters for .physicalGoods — passing it alongside .service must not
        // change the result.
        let route = AddStoreRouter.route(category: .service, catalogSize: .catalog)
        #expect(route == AddStoreRouter.Route(integrationID: .buyButton, presetProvider: "stripe"))
    }
}
