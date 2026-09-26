// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "FamilyShieldAgent",
    platforms: [.iOS(.v16)],
    products: [.library(name: "FamilyShieldAgent", targets: ["FamilyShieldAgent"])],
    dependencies: [],
    targets: [
        .target(name: "FamilyShieldAgent"),
        .testTarget(name: "FamilyShieldAgentTests", dependencies: ["FamilyShieldAgent"])
    ]
)
