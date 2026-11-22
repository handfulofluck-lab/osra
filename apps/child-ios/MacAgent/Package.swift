// swift-tools-version:5.9
import PackageDescription

// Mac step (ii), #775 (roadmap 5.9, ADR-0036 rule 3): the OSRA Agent daemon. It is its own package, nested in
// the shared package's folder: SwiftPM reads only `Sources/` and `Tests/` of the package above, so the iPhone
// builds never compile this macOS-only executable, and the existing `apps/child-ios/**` CI path filter covers
// it unchanged. Everything portable (pairing, the HMAC signer, rule sync, the command drain, the identity
// store) comes from the package above as a dependency, not as a copy.
let package = Package(
    name: "OSRAMacAgent",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "osra-agent", targets: ["osra-agent"]),
        .library(name: "OSRAMacAgentCore", targets: ["OSRAMacAgentCore"]),
        .library(name: "OSRAMacAgentFilter", targets: ["OSRAMacAgentFilter"]),
    ],
    dependencies: [.package(path: "..")],
    targets: [
        // Step (iii), #988: the web filter's decision table, the daemon→extension snapshot and the capability
        // answer. Foundation only — no NetworkExtension — so it compiles and tests on any macOS runner, unsigned.
        .target(name: "OSRAMacAgentFilter"),
        .target(
            name: "OSRAMacAgentCore",
            dependencies: [
                .product(name: "FamilyShieldAgent", package: "child-ios"),
                "OSRAMacAgentFilter",
            ]
        ),
        .executableTarget(name: "osra-agent", dependencies: ["OSRAMacAgentCore"]),
        .testTarget(
            name: "OSRAMacAgentCoreTests",
            dependencies: ["OSRAMacAgentCore", "OSRAMacAgentFilter", .product(name: "FamilyShieldAgent", package: "child-ios")]
        ),
        .testTarget(name: "OSRAMacAgentFilterTests", dependencies: ["OSRAMacAgentFilter"]),
    ]
)
