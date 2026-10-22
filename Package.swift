// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "kikitori",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "Kikitori", targets: ["Kikitori"]),
        .executable(name: "kikitori-cli", targets: ["kikitori-cli"]),
    ],
    dependencies: [
        // Silero VAD (and later speaker labels) on the Neural Engine.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.17.7", traits: []),
    ],
    targets: [
        // Everything that is not UI: capture, speech, translation, cost, storage.
        .target(name: "KikitoriCore", dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
                resources: [.process("Resources")]),
        .executableTarget(name: "Kikitori", dependencies: ["KikitoriCore"]),
        .executableTarget(name: "kikitori-cli", dependencies: ["KikitoriCore"]),
        .testTarget(name: "KikitoriCoreTests", dependencies: ["KikitoriCore"],
                    resources: [.copy("Fixtures")]),
    ]
)
