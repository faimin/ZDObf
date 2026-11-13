// swift-tools-version: 6.0
import Foundation
import PackageDescription

// 预编译 Runtime 的发布固定值，由 scripts/pin_runtime_release.sh 在发布时改写；
// 版本或 checksum 为空表示尚未固定到某个 GitHub Release。
let runtimeReleaseVersion = "0.1.0"
let runtimeReleaseChecksum = "6ef27a368543bb88b01d5e49330181d51928fe491ff0f863fcbe1797bec5aff1"

// 本地存在 dist/ZDObfRuntime.xcframework 时直接使用（开发、CI 构建、仓库内跟踪的产物）；
// 设置 ZDOBF_USE_RELEASE_RUNTIME=1 可强制改用 Release 资产验证远程路径。
let localRuntimePath = "dist/ZDObfRuntime.xcframework"
let runtimeTarget: Target = {
    let localExists = FileManager.default.fileExists(
        atPath: Context.packageDirectory + "/" + localRuntimePath
    )
    if localExists && Context.environment["ZDOBF_USE_RELEASE_RUNTIME"] == nil {
        return .binaryTarget(name: "ZDObfRuntime", path: localRuntimePath)
    }
    guard !runtimeReleaseVersion.isEmpty, !runtimeReleaseChecksum.isEmpty else {
        FileHandle.standardError.write(
            Data(
                ("error: \(localRuntimePath) is missing and no Runtime release is pinned. "
                    + "Run scripts/fetch_runtime.sh or build it with scripts/build_xcframework.sh.\n").utf8
            )
        )
        exit(1)
    }
    return .binaryTarget(
        name: "ZDObfRuntime",
        url: "https://github.com/faimin/ZDObf/releases/download/v\(runtimeReleaseVersion)/ZDObfRuntime.xcframework.zip",
        checksum: runtimeReleaseChecksum
    )
}()

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
        runtimeTarget,
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
