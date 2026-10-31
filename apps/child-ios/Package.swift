// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "FamilyShieldAgent",
    defaultLocalization: "en",
    platforms: [.iOS(.v16)],
    products: [.library(name: "FamilyShieldAgent", targets: ["FamilyShieldAgent"])],
    dependencies: [],
    targets: [
        // #511: the block screen's strings (en, ar) ship as the package's resource bundle (`Bundle.module`).
        .target(name: "FamilyShieldAgent", resources: [.process("Resources")]),
        .testTarget(name: "FamilyShieldAgentTests", dependencies: ["FamilyShieldAgent"])
    ]
)
