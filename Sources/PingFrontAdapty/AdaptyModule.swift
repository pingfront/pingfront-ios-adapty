import Foundation
import PingFrontAdapterKit
public import PingFrontCore

/// How Adapty knows who the person is, so Adapty webhooks and App Store notifications match them.
public enum AdaptyIdentity: Sendable {
    /// Your app calls `Adapty.identify(_:withAppAccountToken:)` itself. Pass `PingFront.shared.storeAccountToken`
    /// as the app account token.
    case appManaged
    /// The adapter calls `Adapty.identify(id, withAppAccountToken: storeAccountToken)` with the id this closure
    /// returns (the same id you pass to `PingFront.shared.identify`), whenever the token changes. `nil`: not signed in.
    case customerUserId(@MainActor @Sendable () -> String?)
    /// The adapter identifies Adapty with `PingFront.shared.storeAccountToken`, for apps without their own user ids.
    case storeAccountToken
}

/// Options for the Adapty adapter.
public struct AdaptyOptions: Sendable {
    /// The placement ids the team can offer.
    ///
    /// Each becomes an offer slot with the placement id as its id.
    public var placements: [String]
    /// Who identifies the person to Adapty.
    public var identity: AdaptyIdentity
    /// Adapty runs in observer mode: your code buys and finishes transactions, so the adapter never buys and calls
    /// `onOffer` for every card.
    public var observerMode: Bool
    /// Presents the AdaptyUI paywall for placements built with the Paywall Builder.
    ///
    /// Needs `AdaptyUI.activate()`.
    public var presentsPaywalls: Bool
    /// Report Adapty's access levels as the entitlement.
    ///
    /// Turn it off when another module already reports it.
    public var reportsEntitlement: Bool
    /// Shows your own paywall for an offer card and returns what happened.
    ///
    /// Called for placements without an AdaptyUI paywall, for cards that match no placement, and in observer mode.
    /// Without it, a placement without an AdaptyUI paywall buys its first product.
    public var onOffer: (@MainActor @Sendable (OfferRequest) async -> OfferOutcome)?

    /// Creates options.
    public init(
        placements: [String], identity: AdaptyIdentity = .appManaged, observerMode: Bool = false, presentsPaywalls: Bool = true,
        reportsEntitlement: Bool = true, onOffer: (@MainActor @Sendable (OfferRequest) async -> OfferOutcome)? = nil
    ) {
        self.placements = placements
        self.identity = identity
        self.observerMode = observerMode
        self.presentsPaywalls = presentsPaywalls
        self.reportsEntitlement = reportsEntitlement
        self.onOffer = onOffer
    }
}

extension PingFrontModule {
    /// Adapty with these placements and the default options.
    ///
    /// - Parameter placements: The placement ids the team can offer.
    /// - Returns: The module, for `config.use(_:)`.
    public static func adapty(placements: [String]) -> PingFrontModule { adapty(AdaptyOptions(placements: placements)) }

    /// Adapty: each placement's paywall becomes an offer slot, an offer card opens it, and the profile's access levels
    /// become the person's entitlement.
    ///
    /// - Activate Adapty (`Adapty.activate`, and `AdaptyUI.activate()` for Paywall Builder paywalls) before or right
    ///   after pingfront; the adapter waits for it.
    /// - A slot's kind comes from the paywall's remote config key `pingfront_kind`.
    /// - Purchases go through Adapty, which finishes them; in observer mode the adapter never buys. It never finishes
    ///   a transaction itself.
    /// - A card's promotional or win-back offer is redeemed when the paywall product carries that offer: Adapty signs
    ///   and applies the offer configured in Adapty. Otherwise the paywall opens.
    /// - It reports no store events: the Adapty webhook delivers them.
    ///
    /// - Parameter options: Placements, identity and how cards open.
    /// - Returns: The module, for `config.use(_:)`.
    public static func adapty(_ options: AdaptyOptions) -> PingFrontModule {
        PingFrontModule(id: "pingfront.adapty") { context in
            let adapter = AdaptyAdapter(client: AdaptyLive(), host: ContextHost(context), options: options)
            context.setOfferHandler(adapter)
            context.run { await adapter.run() }
        }
    }
}
