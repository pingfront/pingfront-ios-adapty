import Adapty
import Foundation
import PingFrontAdapterKit
import PingFrontCore
import StoreKit
import os

#if canImport(UIKit)
    import AdaptyUI
    import UIKit
#endif

/// The live Adapty client: `Adapty` and AdaptyUI's flow controller.
@MainActor final class AdaptyLive: AdaptyClient {
    private let log = AdapterLog.logger("adapty")
    #if canImport(UIKit)
        /// The paywall on screen; the controller holds its delegate weakly.
        private var paywall: FlowSession?
    #endif

    func isActivated() async -> Bool { await Adapty.isActivated }

    func flow(placementId: String) async throws -> ADFlow {
        let flow = try await Adapty.getFlow(placementId: placementId)
        let products = try await Adapty.getPaywallProducts(flow: flow)
        return ADFlow(
            placementId: placementId, title: flow.name, kind: SlotRules.kind(flow.remoteConfigs.first?.dictionary?[SlotRules.kindKey]),
            hasPaywall: flow.hasViewConfiguration, products: products.map(Self.product))
    }

    func profile() async throws -> AccessState { Self.state(try await Adapty.getProfile()) }

    func changes() -> AsyncStream<Void> { AppSignals.becameActive() }

    func identify(customerUserId: String, appAccountToken: UUID?) async throws {
        try await Adapty.identify(customerUserId, withAppAccountToken: appAccountToken)
    }

    func purchase(placementId: String, productId: String) async -> OfferOutcome {
        do {
            let flow = try await Adapty.getFlow(placementId: placementId)
            let products = try await Adapty.getPaywallProducts(flow: flow)
            guard let product = products.first(where: { $0.vendorProductId == productId }) else { return .failed(.productNotFound) }
            return Self.outcome(try await Adapty.makePurchase(product: product))
        } catch {
            log.error("Purchase failed: \(String(describing: error), privacy: .private)")
            return Self.outcome(for: error)
        }
    }

    func presentPaywall(placementId: String) async -> OfferOutcome {
        #if canImport(UIKit)
            let controller: AdaptyFlowController
            let session = FlowSession()
            do {
                let flow = try await Adapty.getFlow(placementId: placementId)
                let configuration = try await AdaptyUI.getFlowConfiguration(forFlow: flow)
                controller = try AdaptyUI.flowController(with: configuration, delegate: session)
            } catch {
                log.error("Could not open the Adapty paywall: \(String(describing: error), privacy: .private)")
                return .unavailable
            }
            guard let top = Presentation.topViewController() else { return .unavailable }
            paywall = session
            defer { paywall = nil }
            return await withCheckedContinuation { continuation in
                session.once = ResumeOnce(continuation)
                top.present(controller, animated: true)
            }
        #else
            return .unavailable
        #endif
    }

    func presentCodeRedemption() async -> OfferOutcome { await OfferCodes.present() }

    // MARK: Mapping

    nonisolated static func product(_ product: AdaptyPaywallProduct) -> ADProduct {
        var trial: String?
        let offer = product.subscriptionOffer
        if let offer, offer.offerType == .introductory, offer.paymentMode == .freeTrial { trial = iso(offer.subscriptionPeriod) }
        return ADProduct(
            id: product.vendorProductId, price: product.localizedPrice, period: product.subscriptionPeriod.flatMap(iso), trial: trial,
            offer: offer.map { ADOffer(id: $0.identifier, kind: kind($0.offerType)) })
    }

    nonisolated static func kind(_ type: AdaptySubscriptionOfferType) -> StoreOffer.Kind {
        switch type {
        case .promotional: .promotional
        case .winBack: .winback
        case .introductory: .intro
        default: .unknown
        }
    }

    nonisolated static func iso(_ period: AdaptySubscriptionPeriod) -> String? {
        let unit: PeriodUnit? =
            switch period.unit {
            case .day: .day
            case .week: .week
            case .month: .month
            case .year: .year
            case .unknown: nil
            }
        return SlotRules.iso(value: period.numberOfUnits, unit: unit)
    }

    nonisolated static func state(_ profile: AdaptyProfile) -> AccessState {
        let access = profile.accessLevels.values.map { level in
            AccessSnapshot(
                productId: level.vendorProductId, isActive: level.isActive, isLifetime: level.isLifetime,
                isTrial: level.activeIntroductoryOfferType == "free_trial", willRenew: level.willRenew,
                isInGracePeriod: level.isInGracePeriod, hasBillingIssue: level.billingIssueDetectedAt != nil, expiresAt: level.expiresAt)
        }
        let subscribed = profile.subscriptions.values.filter(\.isActive).map(\.vendorProductId)
        let bought = profile.nonSubscriptions.filter { _, purchases in purchases.contains { !$0.isRefund && !$0.isConsumable } }.keys
        return AccessState(access: access, owned: Set(subscribed).union(bought))
    }

    nonisolated static func outcome(_ result: AdaptyPurchaseResult) -> OfferOutcome {
        switch result {
        case .userCancelled: .cancelled
        case .pending: .pending
        case .success: .purchased
        }
    }

    nonisolated static func outcome(for error: any Error) -> OfferOutcome {
        guard let error = error as? AdaptyError else { return .failed(.store) }
        switch error.adaptyErrorCode {
        case .paymentCancelled: return .cancelled
        case .paymentPendingError: return .pending
        case .networkFailed, .cloudServiceNetworkConnectionFailed: return .failed(.network)
        case .noProductIDsFound, .storeProductNotAvailable: return .failed(.productNotFound)
        case .paymentNotAllowed, .cantMakePayments: return .failed(.notAllowed)
        default: return .failed(.store)
        }
    }
}

#if canImport(UIKit)
    /// Waits for an AdaptyUI paywall to close and remembers whether something was bought.
    @MainActor final class FlowSession: AdaptyFlowControllerDelegate {
        var once: ResumeOnce<OfferOutcome>?
        private var outcome: OfferOutcome = .cancelled

        func flowController(
            _ controller: AdaptyFlowController, didFinishPurchase product: AdaptyPaywallProduct, purchaseResult: AdaptyPurchaseResult
        ) {
            let result = AdaptyLive.outcome(purchaseResult)
            if result != .cancelled { outcome = result }
            if result == .purchased { controller.dismiss(animated: true) }
        }

        func flowController(_ controller: AdaptyFlowController, didFailPurchase product: AdaptyPaywallProduct, error: AdaptyError) {
            if outcome != .purchased { outcome = AdaptyLive.outcome(for: error) }
        }

        func flowController(_ controller: AdaptyFlowController, didFinishRestoreWith profile: AdaptyProfile) {}

        func flowController(_ controller: AdaptyFlowController, didFailRestoreWith error: AdaptyError) {}

        func flowControllerDidDisappear(_ controller: AdaptyFlowController) { once?.resume(outcome) }
    }
#endif
