# pingfront for Adapty

The Adapty adapter for the [pingfront iOS SDK](https://github.com/pingfront/pingfront-ios). The Adapty placements you
list become offer slots your team can send as offer cards, and a card opens the Adapty paywall. It is its own Swift
package, so an app that adds it fetches Adapty and nothing from the other vendors.

The adapter:

- reports your paywalls as offer slots, so your team can send them as offer cards;
- opens the Adapty paywall when the person taps an offer card;
- reports the Adapty entitlement as the person's entitlement;
- links the person to Adapty so its webhooks match them on pingfront's server.

It leaves transactions to Adapty (it never finishes one) and reports no store events: Adapty's webhook
delivers purchases, renewals and lapses.

## Install

In Xcode, choose File > Add Package Dependencies, enter `https://github.com/pingfront/pingfront-ios-adapty`, and add the
**PingFrontAdapty** product to your app target. In a `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/pingfront/pingfront-ios-adapty", from: "1.0.0"),
],
// and in your target:
dependencies: [.product(name: "PingFrontAdapty", package: "pingfront-ios-adapty")]
```

It brings in the pingfront SDK (`pingfront-ios`), the shared adapter kit (`pingfront-ios-adapter-kit`) and
Adapty's `AdaptySDK-iOS` (Adapty and AdaptyUI), 4.3.1 or later in major 4. iOS 17 or later, Swift 6.

## Set up

```swift
import PingFrontAdapty
Adapty.activate("public_live_…"); AdaptyUI.activate()
PingFront.configure("pk_live_…") { $0.use(.adapty(placements: ["winback", "settings_paywall"])) }
```

Configure Adapty before or right after `PingFront.configure`. The adapter waits up to a minute for it, then
stays idle and logs why.

## How it works

- **Offer slots:** one per placement you list. `title` is the paywall name and `kind` the remote config key
  `pingfront_kind`. Products come from `getPaywallProducts`. A slot is unavailable once the person owns every
  product. Slots refresh at start and when the app becomes active.
- **Offer cards:**
  - a Paywall Builder paywall opens with AdaptyUI;
  - otherwise your `onOffer` handler runs;
  - without one, the first product is bought.
- **Store offers:**
  - `promotional` and `winback`: bought directly when a paywall product carries that offer, and Adapty signs and
    applies it. Adapty applies only the offer configured on the paywall product. If no product carries it, the
    paywall opens.
  - `intro`: a plain purchase of the named product.
  - `code`: Apple's offer code sheet opens.
- **Entitlement:** `AdaptyProfile.accessLevels`. Lifetime, grace, billing issue (`billing_retry`), auto-renew off
  (`cancelled`), free trial, then `active`; `source: adapty`.
- **Identity:** pick one in `AdaptyOptions.identity`:
  - `.appManaged` (default): you call `Adapty.identify(_:withAppAccountToken:)` and pass
    `PingFront.shared.storeAccountToken` as the app account token.
  - `.customerUserId { currentUser?.id }`: the adapter calls `Adapty.identify(id, withAppAccountToken:
    storeAccountToken)` whenever the token changes. The server matches Adapty's `customer_user_id`, and App Store
    notifications match the token.
  - `.storeAccountToken`: for apps without their own user ids.
- **Observer mode:** with `observerMode: true` the adapter never buys. Every card goes to `onOffer`.

## Reference

The public API. Everything else is internal.

| Symbol | What it is |
| --- | --- |
| `PingFrontModule.adapty(placements:)` | The adapter with default options. |
| `PingFrontModule.adapty(_ options: AdaptyOptions)` | The adapter with options. Module id `pingfront.adapty`. |
| `AdaptyOptions.placements: [String]` | Placement ids the team can offer. |
| `AdaptyOptions.identity: AdaptyIdentity` | Who identifies the person to Adapty. Default `.appManaged`. |
| `AdaptyOptions.observerMode: Bool` | Adapty runs in observer mode: the adapter never buys. Default `false`. |
| `AdaptyOptions.presentsPaywalls: Bool` | Present AdaptyUI paywalls for Paywall Builder placements. Default `true`. |
| `AdaptyOptions.reportsEntitlement: Bool` | Report access levels as the entitlement. Default `true`. |
| `AdaptyOptions.onOffer` | `@MainActor @Sendable (OfferRequest) async -> OfferOutcome`: your own paywall. |
| `AdaptyOptions.init(placements:identity:observerMode:presentsPaywalls:reportsEntitlement:onOffer:)` | Creates options. |
| `AdaptyIdentity.appManaged` | You call `Adapty.identify` yourself. |
| `AdaptyIdentity.customerUserId(_:)` | The adapter identifies with your user id and the store account token. |
| `AdaptyIdentity.storeAccountToken` | The adapter identifies with the store account token. |

## More

- [Modules and vendor adapters](https://pingfront.sh/docs/modules#revenuecat-superwall-and-adapty) in the pingfront docs.
- Connect Adapty's webhook too: [Store events](https://pingfront.sh/docs/store-events).
- [CHANGELOG.md](CHANGELOG.md). MIT licensed (see `LICENSE`).
