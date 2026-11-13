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
        .library(name: "ZDObfKit", targets: ["ZDObfKit"]),
        .library(name: "ZDObfKitObjC", targets: ["ZDObfKitObjC"])
    ],
    targets: [
        .binaryTarget(
            name: "ZDObfRuntime",
            path: "dist/ZDObfRuntime.xcframework"
        ),
        .target(
            name: "ZDObfKit",
            dependencies: ["ZDObfRuntime", "ZDObfKitObjC"],
            path: "Apple/Swift"
        ),
        .target(
            name: "ZDObfKitObjC",
            dependencies: ["ZDObfRuntime"],
            path: "Apple/ObjectiveC",
            publicHeadersPath: ".",
            cxxSettings: [
                .headerSearchPath("../../crates/runtime/include")
            ]
        )
    ]
)
