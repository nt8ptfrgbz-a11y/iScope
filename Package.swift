// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "iScope",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "iScopeCore", targets: ["iScopeCore"]),
        .executable(name: "iScope", targets: ["iScopeApp"])
    ],
    targets: [
        .target(name: "iScopeCore", resources: [.copy("Resources/HookTools")]),
        .executableTarget(name: "iScopeApp", dependencies: ["iScopeCore"]),
        .testTarget(name: "iScopeCoreTests", dependencies: ["iScopeCore"]),
        .testTarget(name: "iScopeAppTests", dependencies: ["iScopeApp", "iScopeCore"])
    ]
)
