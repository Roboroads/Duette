// swift-tools-version:5.9
import PackageDescription

// DuetteKit: the real-time engine (DuetteEngine, C++ behind a C header) and the Swift control
// plane around it (DuetteAudio). The app and duettectl depend on the DuetteKit product.
//
// DuetteEngine uses the header-only DSP core in <repo>/core/include. SwiftPM refuses header
// search paths outside the package, so `core` in this folder is a symlink to <repo>/core.
let package = Package(
    name: "DuetteKit",
    platforms: [.macOS("14.2")],
    products: [
        .library(name: "DuetteKit", targets: ["DuetteAudio", "DuetteEngine"]),
    ],
    targets: [
        .target(
            name: "DuetteEngine",
            cxxSettings: [
                .headerSearchPath("../../core/include"),
            ],
            linkerSettings: [
                .linkedFramework("CoreAudio"),
            ]
        ),
        .target(
            name: "DuetteAudio",
            dependencies: ["DuetteEngine"],
            linkerSettings: [
                .linkedFramework("CoreAudio"),
            ]
        ),
        // Test-only: replaces the global operator new to count allocations on the calling
        // thread. Only the test targets depend on it.
        .target(name: "DuetteEngineTestSupport"),
        .testTarget(
            name: "DuetteEngineTests",
            dependencies: ["DuetteEngine", "DuetteEngineTestSupport"]
        ),
        .testTarget(
            name: "DuetteAudioTests",
            dependencies: ["DuetteAudio", "DuetteEngine"]
        ),
    ],
    cxxLanguageStandard: .cxx17
)
