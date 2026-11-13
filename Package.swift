// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ZDObf",
    platforms: [
        .iOS(.v15),
        .macOS(.v15),
        .tvOS(.v15),
        .watchOS(.v8),
        .visionOS(.v1)
    ],
    products: [
        .library(name: "ZDObf", targets: ["ZDObf"]),
        .library(name: "ZDObfObjC", targets: ["ZDObfObjC"])
    ],
    targets: [
        .binaryTarget(
            name: "ZDObfRuntime",
            path: "dist/ZDObfRuntime.xcframework"
        ),
        .target(
            name: "ZDObf",
            dependencies: ["ZDObfRuntime", "ZDObfObjC"],
            path: "Apple/Swift"
        ),
        .target(
            name: "ZDObfObjC",
            dependencies: ["ZDObfRuntime"],
            path: "Apple/ObjectiveC",
            publicHeadersPath: ".",
            cxxSettings: [
                .headerSearchPath("../../crates/runtime/include")
            ]
        )
    ]
)
