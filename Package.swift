// swift-tools-version: 5.10
import PackageDescription
import Foundation

let packageDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let vendorLibDir = "\(packageDir)/Vendor/lib"

let package = Package(
    name: "UPreviewX",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "UPreviewXCore", targets: ["UPreviewXCore"]),
        .executable(name: "UPreviewX", targets: ["UPreviewX"])
    ],
    targets: [
        .target(
            name: "CMPV",
            path: "Sources/CMPV",
            publicHeadersPath: "include",
            linkerSettings: [
                .unsafeFlags([
                    "-L\(vendorLibDir)",
                    "-lmpv",
                    "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
                    "-Xlinker", "-rpath", "-Xlinker", vendorLibDir
                ]),
                .linkedFramework("OpenGL"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("IOSurface")
            ]
        ),
        .target(
            name: "UPreviewXCore",
            dependencies: ["CMPV"],
            path: "Sources/UPreviewXCore",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("OpenGL"),
                .linkedFramework("Metal")
            ]
        ),
        .executableTarget(
            name: "UPreviewX",
            dependencies: ["UPreviewXCore"],
            path: "Sources/UPreviewX"
        ),
        .testTarget(
            name: "UPreviewXTests",
            dependencies: ["UPreviewXCore", "CMPV"],
            path: "Tests/UPreviewXTests",
            linkerSettings: [
                .unsafeFlags([
                    "-L\(vendorLibDir)",
                    "-Xlinker", "-rpath", "-Xlinker", vendorLibDir
                ])
            ]
        )
    ]
)

