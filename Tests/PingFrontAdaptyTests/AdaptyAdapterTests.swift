import Adapty
import Foundation
import PingFrontAdapterKit
import PingFrontAdapterTestSupport
import PingFrontCore
import Testing

@testable import PingFrontAdapty

struct FlowMissing: Error {}

/// Records every call the adapter makes to Adapty.
@MainActor final class FakeAdapty: AdaptyClient {
    var activated = true
    var flowsById: [String: ADFlow] = [:]
    var profileResult = AccessState()
    var purchaseOutcome: OfferOutcome = .purchased
    var paywallOutcome: OfferOutcome = .cancelled
    private(set) var identified: [(userId: String, token: UUID?)] = []
    private(set) var purchases: [(placementId: String, productId: String)] = []
    private(set) var paywalls: [String] = []
    private(set) var codeSheets = 0
    private(set) var profileLoads = 0

    func isActivated() async -> Bool { activated }

    func flow(placementId: String) async throws -> ADFlow {
        guard let flow = flowsById[placementId] else { throw FlowMissing() }
        return flow
    }

    func profile() async throws -> AccessState {
        profileLoads += 1
        return profileResult
    }

    func changes() -> AsyncStream<Void> { AsyncStream { _ in } }

    func identify(customerUserId: String, appAccountToken: UUID?) async throws { identified.append((customerUserId, appAccountToken)) }

    func purchase(placementId: String, productId: String) async -> OfferOutcome {
        purchases.append((placementId, productId))
        return purchaseOutcome
    }

    func presentPaywall(placementId: String) async -> OfferOutcome {
        paywalls.append(placementId)
        return paywallOutcome
    }

    func presentCodeRedemption() async -> OfferOutcome {
        codeSheets += 1
        return .pending
    }
}

@MainActor final class AppPaywall {
    private(set) var calls = 0
    let outcome: OfferOutcome?
    init(_ outcome: OfferOutcome?) { self.outcome = outcome }
    var handler: AppOfferHandler {
        {
            self.calls += 1
            return self.outcome
        }
    }
}

extension ADFlow {
    static let winback = ADFlow(
        placementId: "winback", title: "Win back", kind: .winback, hasPaywall: true,
        products: [
            ADProduct(id: "pro.annual", price: "€29.99", period: "P1Y", offer: ADOffer(id: "back50", kind: .winback)),
            ADProduct(id: "pro.monthly", price: "€4.99", period: "P1M", trial: "P1W", offer: ADOffer(id: nil, kind: .intro)),
            ADProduct(id: "pro.monthly.promo", price: "€4.99", period: "P1M", offer: ADOffer(id: "save50", kind: .promotional)),
        ])
    static let custom = ADFlow(
        placementId: "settings paywall", title: "Settings", kind: .standard, hasPaywall: false,
        products: [ADProduct(id: "pro.monthly", price: "€4.99", period: "P1M")])
}

@Suite("Adapty adapter")
@MainActor struct AdaptyAdapterTests {
    let client = FakeAdapty()
    let host = FakeHost()

    init() { client.flowsById = ["winback": .winback, "settings paywall": .custom] }

    func adapter(_ options: AdaptyOptions = AdaptyOptions(placements: ["winback", "settings paywall"])) -> AdaptyAdapter {
        AdaptyAdapter(client: client, host: host, options: options, sleep: noSleep)
    }

    // MARK: Slots and entitlement

    @Test("Each configured placement that loads becomes a slot, in order")
    func slots() async {
        client.profileResult = AccessState(owned: ["pro.monthly"])
        let adapter = adapter(AdaptyOptions(placements: ["settings paywall", "missing", "winback"]))
        await adapter.refresh()
        let slots = host.lastOffers ?? []
        #expect(slots.map(\.id) == ["settings_paywall", "winback"])
        #expect(slots[1].kind == .winback)
        #expect(slots[1].products[1] == OfferSlot.Product(id: "pro.monthly", price: "€4.99", period: "P1M", trial: "P1W"))
        #expect(!slots[0].isAvailable)
        #expect(slots[1].isAvailable)
        #expect(adapter.slots.source == .adapty)
    }

    @Test("When no placement loads (offline), the reported slots are kept")
    func offline() async {
        client.flowsById = [:]
        let adapter = adapter()
        await adapter.refresh()
        await adapter.tokenChanged(sampleToken)
        #expect(host.offers.isEmpty)
    }

    @Test("Access levels map to the entitlement with source adapty")
    func entitlement() async {
        let adapter = adapter()
        for access in [
            AccessSnapshot(productId: "pro.annual", isActive: true, isInGracePeriod: true),
            AccessSnapshot(productId: "pro.annual", isActive: true, willRenew: false),
            AccessSnapshot(productId: "lifetime", isActive: true, isLifetime: true),
            AccessSnapshot(productId: "pro.annual", isActive: true),
        ] {
            client.profileResult = AccessState(access: [access])
            await adapter.refreshProfile()
        }
        #expect(host.entitlements.map(\.state) == [.grace, .cancelled, .lifetime, .active])
        #expect(host.entitlements.allSatisfy { $0.source == .adapty })
    }

    @Test("reportsEntitlement false leaves the entitlement to another module")
    func noEntitlement() async {
        await adapter(AdaptyOptions(placements: ["winback"], reportsEntitlement: false)).refresh()
        #expect(host.entitlements.isEmpty)
        #expect(host.lastOffers?.count == 1)
    }

    // MARK: Identity

    @Test("customerUserId identifies with the app's id and the store account token as appAccountToken")
    func identifiesWithAppId() async {
        let adapter = adapter(AdaptyOptions(placements: [], identity: .customerUserId { "user_42" }))
        await adapter.tokenChanged(nil)
        await adapter.tokenChanged(sampleToken)
        await adapter.tokenChanged(sampleToken)
        let next = UUID()
        await adapter.tokenChanged(next)
        #expect(client.identified.map(\.userId) == ["user_42", "user_42"])
        #expect(client.identified.map(\.token) == [sampleToken, next])
    }

    @Test("customerUserId returning nil (signed out) does not identify")
    func signedOut() async {
        await adapter(AdaptyOptions(placements: [], identity: .customerUserId { nil })).tokenChanged(sampleToken)
        #expect(client.identified.isEmpty)
    }

    @Test("storeAccountToken identifies with the token itself; appManaged never identifies")
    func otherIdentities() async {
        await adapter(AdaptyOptions(placements: [], identity: .storeAccountToken)).tokenChanged(sampleToken)
        await adapter(AdaptyOptions(placements: [])).tokenChanged(UUID())
        #expect(client.identified.count == 1)
        #expect(client.identified.first?.userId == tokenString(sampleToken))
        #expect(client.identified.first?.token == sampleToken)
    }

    // MARK: Offer cards

    @Test("A Paywall Builder paywall opens through AdaptyUI, then the profile reloads")
    func paywall() async {
        client.paywallOutcome = .purchased
        let adapter = adapter()
        let outcome = await adapter.handle(CardTap(offerId: "winback"), app: AppPaywall(.cancelled).handler)
        #expect(outcome == .purchased)
        #expect(client.paywalls == ["winback"])
        #expect(client.purchases.isEmpty)
        #expect(client.profileLoads >= 1)
    }

    @Test("Without an AdaptyUI paywall the app's handler runs, else the first product is bought")
    func appOrFirst() async {
        let adapter = adapter()
        let app = AppPaywall(.cancelled)
        #expect(await adapter.handle(CardTap(offerId: "settings_paywall"), app: app.handler) == .cancelled)
        #expect(app.calls == 1)
        #expect(await adapter.handle(CardTap(offerId: "settings_paywall"), app: AppPaywall(nil).handler) == .purchased)
        #expect(client.purchases.map(\.productId) == ["pro.monthly"])
    }

    @Test("A promotional or win-back offer on a paywall product is bought directly; Adapty applies it")
    func storeOffers() async {
        let adapter = adapter()
        _ = await adapter.handle(
            CardTap(offerId: "winback", storeOffer: StoreOffer(kind: .winback, id: "back50")), app: AppPaywall(nil).handler)
        _ = await adapter.handle(
            CardTap(offerId: "winback", storeOffer: StoreOffer(kind: .promotional, id: "save50", productId: "pro.monthly.promo")),
            app: AppPaywall(nil).handler)
        _ = await adapter.handle(
            CardTap(offerId: "winback", storeOffer: StoreOffer(kind: .intro, id: "trial", productId: "pro.monthly")),
            app: AppPaywall(nil).handler)
        #expect(client.purchases.map(\.productId) == ["pro.annual", "pro.monthly.promo", "pro.monthly"])
        #expect(client.paywalls.isEmpty)
    }

    @Test("An offer no paywall product carries opens the paywall instead")
    func uncarriedOffer() async {
        _ = await adapter().handle(
            CardTap(offerId: "winback", storeOffer: StoreOffer(kind: .promotional, id: "other", productId: "pro.annual")),
            app: AppPaywall(nil).handler)
        #expect(client.purchases.isEmpty)
        #expect(client.paywalls == ["winback"])
    }

    @Test("An offer code opens Apple's redemption sheet")
    func code() async {
        #expect(
            await adapter().handle(CardTap(offerId: "winback", storeOffer: StoreOffer(kind: .code, id: "X")), app: AppPaywall(nil).handler)
                == .pending)
        #expect(client.codeSheets == 1)
    }

    @Test("In observer mode the adapter never buys or presents: the app does")
    func observer() async {
        let adapter = adapter(AdaptyOptions(placements: ["winback"], observerMode: true))
        let app = AppPaywall(.purchased)
        #expect(
            await adapter.handle(CardTap(offerId: "winback", storeOffer: StoreOffer(kind: .winback, id: "back50")), app: app.handler)
                == .purchased)
        #expect(await adapter.handle(CardTap(offerId: "winback"), app: AppPaywall(nil).handler) == .unavailable)
        #expect(app.calls == 1)
        #expect(client.purchases.isEmpty && client.paywalls.isEmpty && client.codeSheets == 0)
    }

    @Test("An unknown or unloadable placement, or Adapty not activated, is unavailable")
    func unavailable() async {
        client.flowsById = [:]
        let adapter = adapter()
        #expect(await adapter.handle(CardTap(offerId: "nope"), app: AppPaywall(nil).handler) == .unavailable)
        #expect(await adapter.handle(CardTap(offerId: "winback"), app: AppPaywall(nil).handler) == .unavailable)
        client.activated = false
        #expect(await adapter.handle(CardTap(offerId: "winback"), app: AppPaywall(nil).handler) == .unavailable)
        #expect(client.purchases.isEmpty && client.paywalls.isEmpty)
    }

    @Test("run waits for Adapty.activate, then identifies and reports slots and entitlement")
    func runs() async {
        client.activated = false
        host.setToken(sampleToken)
        let adapter = AdaptyAdapter(
            client: client, host: host, options: AdaptyOptions(placements: ["winback"], identity: .storeAccountToken), sleep: yieldingSleep)
        let task = Task { await adapter.run() }
        await Task.yield()
        #expect(client.identified.isEmpty)
        client.activated = true
        #expect(await settle { client.identified.count == 1 && host.lastOffers?.count == 1 && !host.entitlements.isEmpty })
        task.cancel()
    }

    // MARK: Live mapping

    @Test("Adapty offer types map to store offer kinds")
    func offerKinds() {
        #expect(AdaptyLive.kind(.promotional) == .promotional)
        #expect(AdaptyLive.kind(.winBack) == .winback)
        #expect(AdaptyLive.kind(.introductory) == .intro)
        #expect(AdaptyLive.kind(AdaptySubscriptionOfferType(rawValue: "future")) == .unknown)
    }
}
