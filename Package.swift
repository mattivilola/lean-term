// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "LeanTerm",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git",
                 revision: "309adcc28bdf0e01f6403d04616323b379fb5635"),
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1")
    ],
    targets: [
        .target(name: "LeanTermCore"),
        .executableTarget(name: "LeanTerm", dependencies: ["LeanTermCore", "SwiftTerm", .product(name: "Sparkle", package: "Sparkle")]),
        .executableTarget(name: "LeanTermBench", dependencies: ["SwiftTerm"]),
        .testTarget(name: "LeanTermCoreTests", dependencies: ["LeanTermCore"])
    ],
    swiftLanguageModes: [.v6]
)
