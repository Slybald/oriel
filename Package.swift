// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Oriel",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Oriel",
            dependencies: ["FanControl"],
            path: "Sources/Oriel"
        ),
        // Accès au SMC, partagé par l'app (lecture) et l'outil d'aide `fanctl` (écriture, en root).
        .target(
            name: "FanControl",
            path: "Sources/FanControl"
        ),
        .executableTarget(
            name: "fanctl",
            dependencies: ["FanControl"],
            path: "Sources/fanctl"
        ),
        .testTarget(
            name: "OrielTests",
            dependencies: ["Oriel", "FanControl"],
            path: "Tests/OrielTests"
        ),
    ],
    swiftLanguageVersions: [.v5]
)
