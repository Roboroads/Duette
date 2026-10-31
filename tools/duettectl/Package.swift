// swift-tools-version:5.9
import PackageDescription

// duettectl: the command-line tool CI uses to check Duette on a machine without a person at it.
// See tools/duettectl/README.md for the commands.
//
//  - DuettectlDSP:  a C header over the header-only DSP core (LatencyEstimator). No Apple headers.
//  - DuettectlIO:   C++ IOProcs that record from and play into a device, with a C header. They
//                   only copy samples on the I/O thread, like the driver's probe.
//  - DuettectlCore: the Swift logic the unit tests cover: argument parsing, WAV files, the FFT
//                   tone checker, loopback analysis and check reporting. No Core Audio.
//  - duettectl:     the executable, on DuetteKit.
//
// SwiftPM refuses header search paths outside the package, so `core` in this folder is a symlink
// to <repo>/core, as in Packages/DuetteKit.
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
        .target(
            name: "DuettectlDSP",
            cxxSettings: [
                .headerSearchPath("../../core/include"),
            ]
        ),
        .target(
            name: "DuettectlIO",
            linkerSettings: [
                .linkedFramework("CoreAudio"),
            ]
        ),
        .target(
            name: "DuettectlCore",
            dependencies: ["DuettectlDSP"]
        ),
        .executableTarget(
            name: "duettectl",
            dependencies: [
                "DuettectlCore",
                "DuettectlIO",
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
    ],
    cxxLanguageStandard: .cxx17
)
