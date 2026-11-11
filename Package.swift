// swift-tools-version: 6.2
import PackageDescription

/// The same upcoming language features as the pingfront SDK (pingfront-ios).
let upcoming: [SwiftSetting] = [
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),  // SE-0461
    .enableUpcomingFeature("InferIsolatedConformances"),  // SE-0470
    .enableUpcomingFeature("ExistentialAny"),  // SE-0335
    .enableUpcomingFeature("MemberImportVisibility"),  // SE-0444
    .enableUpcomingFeature("InternalImportsByDefault"),  // SE-0409
]

/// The pingfront adapter for Adapty.
///
/// Placements become offer slots, offer cards open the Adapty paywall.
/// It is its own package, so an app that adds it fetches Adapty and nothing from the other vendors.
let package = Package(
    name: "PingFrontAdapty",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "PingFrontAdapty", targets: ["PingFrontAdapty"])
    ],
    dependencies: [
        .package(url: "https://github.com/pingfront/pingfront-ios", from: "1.0.0"),
        .package(url: "https://github.com/pingfront/pingfront-ios-adapter-kit", from: "1.0.0"),
        // Current stable major, as built and tested here: Adapty 4.
        .package(url: "https://github.com/adaptyteam/AdaptySDK-iOS.git", from: "4.3.1"),
    ],
    targets: [
        .target(
            name: "PingFrontAdapty",
            dependencies: [
                .product(name: "PingFrontAdapterKit", package: "pingfront-ios-adapter-kit"),
                .product(name: "PingFrontCore", package: "pingfront-ios"),
                .product(name: "Adapty", package: "AdaptySDK-iOS"),
                .product(name: "AdaptyUI", package: "AdaptySDK-iOS"),
            ],
            swiftSettings: upcoming
        ),
        .testTarget(
            name: "PingFrontAdaptyTests",
            dependencies: [
                "PingFrontAdapty",
                .product(name: "PingFrontAdapterKit", package: "pingfront-ios-adapter-kit"),
                .product(name: "PingFrontAdapterTestSupport", package: "pingfront-ios-adapter-kit"),
                .product(name: "PingFrontCore", package: "pingfront-ios"),
                .product(name: "Adapty", package: "AdaptySDK-iOS"),
            ],
            swiftSettings: upcoming
        ),
    ],
    swiftLanguageModes: [.v6]
)
