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
        // Spikes for docs/design/realtime-sync.md (experiments, not shipped): see Experiments/README.md.
        .executableTarget(name: "kk-spike-mse", path: "Experiments/mse-lookahead",
                          swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "kk-spike-timing", dependencies: ["KikitoriCore"], path: "Experiments/timing", exclude: ["make_truth.py", "karaoke.py"],
                          swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "kk-spike-gpu", path: "Experiments/gpu-process",
                          swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "kk-check-mediatap", path: "Experiments/mediatap-check",
                          swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "kk-check-reveal", path: "Experiments/reveal-check",
                          swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "kk-spike-diar", dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
                          path: "Experiments/speakers/offline", swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "kk-check-sync", dependencies: ["KikitoriCore"], path: "Experiments/sync-check",
                          swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "KikitoriCoreTests", dependencies: ["KikitoriCore"],
                    resources: [.copy("Fixtures")]),
    ]
)
