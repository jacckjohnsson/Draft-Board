// swift-tools-version:5.10
import PackageDescription

// FactorKit holds everything that does not need UIKit/SwiftUI/SwiftData:
//  - FactorEngine: pure factor math, statistics, backtest, clustering. No I/O.
//  - FactorData: provider protocols, Massive/Yahoo/FMP clients, request scheduler,
//    sync orchestration, bundled universes. Foundation only, so it builds on Linux.
// The iOS app target (App/FactorLens) depends on both and adds SwiftData + UI.
let package = Package(
    name: "FactorKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "FactorEngine", targets: ["FactorEngine"]),
        .library(name: "FactorData", targets: ["FactorData"]),
    ],
    targets: [
        .target(name: "FactorEngine"),
        .target(
            name: "FactorData",
            dependencies: ["FactorEngine"],
            resources: [.process("Resources")]
        ),
        .testTarget(name: "FactorEngineTests", dependencies: ["FactorEngine"]),
        .testTarget(name: "FactorDataTests", dependencies: ["FactorData", "FactorEngine"]),
    ]
)
