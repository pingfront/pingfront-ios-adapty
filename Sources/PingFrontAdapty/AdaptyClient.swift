import Foundation
import PingFrontAdapterKit
import PingFrontCore

/// An Adapty flow (paywall) for a placement, reduced to what offer slots and offer cards need.
struct ADFlow: Sendable, Equatable {
    var placementId: String
    var title: String
    var kind: OfferSlot.Kind
    /// Built with the Adapty Paywall Builder, so AdaptyUI can show it.
    var hasPaywall: Bool
    var products: [ADProduct]
}

/// A product on an Adapty paywall.
struct ADProduct: Sendable, Equatable {
    var id: String
    var price: String
    var period: String?
    var trial: String?
    /// The subscription offer Adapty applies when this product is bought, if any.
    var offer: ADOffer?
}

/// A subscription offer configured on an Adapty paywall product.
///
/// Adapty signs promotional offers itself.
struct ADOffer: Sendable, Equatable {
    var id: String?
    var kind: StoreOffer.Kind
}

/// The slice of Adapty the adapter uses.
///
/// The live client wraps `Adapty` and `AdaptyUI`.
@MainActor protocol AdaptyClient: AnyObject {
    /// `Adapty.isActivated`.
    func isActivated() async -> Bool
    /// `Adapty.getFlow(placementId:)` with `getPaywallProducts(flow:)`.
    func flow(placementId: String) async throws -> ADFlow
    /// `Adapty.getProfile()`.
    func profile() async throws -> AccessState
    /// Yields when the profile may have changed (the app became active).
    func changes() -> AsyncStream<Void>
    /// `Adapty.identify(_:withAppAccountToken:)`.
    func identify(customerUserId: String, appAccountToken: UUID?) async throws
    /// `Adapty.makePurchase(product:)` for a product of the placement's paywall. Adapty finishes the transaction.
    func purchase(placementId: String, productId: String) async -> OfferOutcome
    /// Presents the placement's AdaptyUI paywall and waits until it closes.
    func presentPaywall(placementId: String) async -> OfferOutcome
    /// Presents Apple's offer code sheet.
    func presentCodeRedemption() async -> OfferOutcome
}
