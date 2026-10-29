// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Palette",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Palette", targets: ["Palette"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .target(name: "PaletteCore"),
        .executableTarget(
            name: "Palette",
            dependencies: ["PaletteCore", .product(name: "Sparkle", package: "Sparkle")],
            linkerSettings: [
                // scripts/build.sh copies Sparkle.framework into Palette.app/Contents/Frameworks.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
            ]
        ),
        .testTarget(name: "PaletteCoreTests", dependencies: ["PaletteCore"]),
    ]
)
