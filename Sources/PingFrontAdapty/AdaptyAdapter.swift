import Foundation
import PingFrontAdapterKit
import PingFrontCore
import os

/// Reports the configured placements' paywalls as offer slots and the profile's access levels as the entitlement,
/// identifies the person to Adapty, and handles offer cards.
@MainActor final class AdaptyAdapter: OfferHandling {
    private let client: any AdaptyClient
    private let host: any AdapterHost
    private let options: AdaptyOptions
    private let sleep: Sleep
    private let log = AdapterLog.logger("adapty")
    let slots: SlotPublisher
    private(set) var flows: [String: ADFlow] = [:]
    private(set) var state = AccessState()
    /// The customer user id and token last passed to `identify`.
    private(set) var identified: (userId: String, token: UUID)?

    init(client: any AdaptyClient, host: any AdapterHost, options: AdaptyOptions, sleep: @escaping Sleep = liveSleep) {
        self.client = client
        self.host = host
        self.options = options
        self.sleep = sleep
        slots = SlotPublisher(host: host, source: .adapty)
    }

    /// Runs until cancelled: waits for `Adapty.activate`, then follows the token and the profile.
    func run() async {
        guard await Readiness.wait(until: { [client] in await client.isActivated() }, sleep: sleep) else {
            log.error("Adapty is not activated, so the adapter is idle. Call Adapty.activate before PingFront.configure.")
            return
        }
        async let tokens: Void = watchTokens()
        await refresh()
        for await _ in client.changes() { await refresh() }
        await tokens
    }

    private func watchTokens() async {
        for await token in host.storeAccountTokenChanges() { await tokenChanged(token) }
    }

    func tokenChanged(_ token: UUID?) async {
        guard let token else { return }
        let userId: String?
        switch options.identity {
        case .appManaged: userId = nil
        case .customerUserId(let current): userId = current()
        case .storeAccountToken: userId = tokenString(token)
        }
        if let userId, identified?.userId != userId || identified?.token != token {
            do {
                try await client.identify(customerUserId: userId, appAccountToken: token)
                identified = (userId, token)
            } catch {
                log.error("Adapty.identify failed: \(String(describing: error), privacy: .private)")
            }
        }
        await refreshProfile()
        // A new person: report the slots again (once any placement loaded).
        if !flows.isEmpty { slots.publish(makeSlots(), force: true) }
    }

    func refresh() async {
        await refreshProfile()
        await refreshFlows()
    }

    func refreshProfile() async {
        do {
            state = try await client.profile()
            if options.reportsEntitlement { host.setEntitlement(EntitlementRules.entitlement(from: state.access, source: .adapty)) }
        } catch {
            log.error("Could not load the Adapty profile: \(String(describing: error), privacy: .private)")
        }
    }

    func refreshFlows() async {
        for placementId in options.placements {
            do {
                flows[placementId] = try await client.flow(placementId: placementId)
            } catch {
                log.error("Could not load placement \(placementId, privacy: .public): \(String(describing: error), privacy: .private)")
            }
        }
        // Nothing loaded (offline): keep what was reported rather than clearing it.
        if !flows.isEmpty { slots.publish(makeSlots()) }
    }

    /// One slot per configured placement that loaded, in the configured order.
    func makeSlots() -> [OfferSlot] {
        options.placements.compactMap { flows[$0] }.map { flow in
            OfferSlot(
                id: SlotRules.id(flow.placementId), title: SlotRules.title(flow.title, fallback: flow.placementId), kind: flow.kind,
                isAvailable: SlotRules.isAvailable(products: flow.products.map(\.id), owned: state.owned),
                products: flow.products.map { SlotRules.product(id: $0.id, price: $0.price, period: $0.period, trial: $0.trial) })
        }
    }

    func handle(_ request: OfferRequest) async -> OfferOutcome {
        let onOffer = options.onOffer
        return await handle(CardTap(request)) { await onOffer?(request) }
    }

    func handle(_ card: CardTap, app: AppOfferHandler) async -> OfferOutcome {
        guard await client.isActivated() else { return await fallback(app, reason: "Adapty is not activated") }
        // In observer mode the app's own code buys and finishes transactions.
        guard !options.observerMode else { return await fallback(app, reason: "Adapty runs in observer mode") }
        if card.storeOffer?.kind == .code { return await client.presentCodeRedemption() }
        guard let placementId = options.placements.first(where: { SlotRules.id($0) == card.offerId }) else {
            return await fallback(app, reason: "no configured placement matches the card")
        }
        if flows[placementId] == nil { await refreshFlows() }
        guard let flow = flows[placementId] else { return await fallback(app, reason: "the placement did not load") }
        let outcome = await open(flow, card: card, app: app)
        await refreshProfile()
        return outcome
    }

    private func open(_ flow: ADFlow, card: CardTap, app: AppOfferHandler) async -> OfferOutcome {
        if let productId = Self.storeOfferProduct(card.storeOffer, in: flow) {
            return await client.purchase(placementId: flow.placementId, productId: productId)
        }
        if options.presentsPaywalls, flow.hasPaywall { return await client.presentPaywall(placementId: flow.placementId) }
        if let outcome = await app() { return outcome }
        guard let first = flow.products.first else { return .unavailable }
        return await client.purchase(placementId: flow.placementId, productId: first.id)
    }

    private func fallback(_ app: AppOfferHandler, reason: String) async -> OfferOutcome {
        if let outcome = await app() { return outcome }
        log.error("Offer card not shown: \(reason, privacy: .public). Set AdaptyOptions.onOffer to show your own paywall.")
        return .unavailable
    }

    /// The product to buy for the card's store offer, or `nil` to open the paywall.
    ///
    /// Adapty applies only the offer configured on the paywall product, so a promotional or win-back offer is bought
    /// directly when a product carries it; an intro offer is a plain purchase of the named product.
    static func storeOfferProduct(_ offer: StoreOffer?, in flow: ADFlow) -> String? {
        guard let offer else { return nil }
        switch offer.kind {
        case .promotional, .winback:
            let carrying = flow.products.filter { $0.offer?.kind == offer.kind && $0.offer?.id == offer.id }
            return (carrying.first { $0.id == offer.productId } ?? carrying.first)?.id
        case .intro:
            return flow.products.first { $0.id == offer.productId }?.id
        case .code, .unknown:
            return nil
        // An offer kind a later SDK adds opens the paywall until this adapter learns it.
        @unknown default:
            return nil
        }
    }
}
