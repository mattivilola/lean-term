// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "LeanTerm",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git",
                 revision: "309adcc28bdf0e01f6403d04616323b379fb5635")
    ],
    targets: [
        .executableTarget(name: "LeanTermBench", dependencies: ["SwiftTerm"])
    ],
    swiftLanguageModes: [.v6]
)
