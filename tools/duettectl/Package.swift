// swift-tools-version:5.9
import PackageDescription

// duettectl: the command-line tool CI uses to check Duette on a machine without a person at it.
// See tools/duettectl/README.md for the commands.
//
//  - DuettectlCore: the Swift logic the unit tests cover: argument parsing, WAV files, the FFT
//                   tone checker, check reporting and the soak's plan. No Core Audio.
//  - duettectl:     the executable, on DuetteKit. The recorder and player IOProcs and the
//                   loopback analysis come from DuetteKit (duette_probe.h, LoopbackAnalysis), the
//                   same code the app's "Measure latency" runs.
let package = Package(
    name: "duettectl",
    platforms: [.macOS("14.2")],
    products: [
        .executable(name: "duettectl", targets: ["duettectl"]),
    ],
    dependencies: [
        .package(path: "../../Packages/DuetteKit"),
    ],
    targets: [
        .target(name: "DuettectlCore"),
        .executableTarget(
            name: "duettectl",
            dependencies: [
                "DuettectlCore",
                .product(name: "DuetteKit", package: "DuetteKit"),
            ],
            linkerSettings: [
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("AppKit"),
            ]
        ),
        .testTarget(
            name: "DuettectlCoreTests",
            dependencies: ["DuettectlCore"]
        ),
    ]
)
