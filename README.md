# ZDObf

ZDObf 是一个面向 Apple 平台的字符串保护组件。它在构建阶段扫描 Swift/Objective-C 源码，把受保护的字符串字面量替换成稳定 ID；随后使用 Rust 加密目录，将密文嵌入最终 App 可执行文件的 Mach-O `__DATA,__zdstring` section。运行时由 Swift 或 Objective-C wrapper 使用 32 字节 key 解密查询。

组件降低静态提取客户端字符串的便利性。字符串在运行时仍会以明文出现在进程内存中，因此它不能替代服务端鉴权、密钥管理或反调试方案。

## 实现思路

```text
Swift / Objective-C 源码
        │
        ├─ zdstring-gen scan
        │    ├─ 生成只包含 ZDStringDecodeBytes(...) 的源码
        │    └─ 生成构建期明文 Manifest
        │
        ├─ zdstring-gen merge-manifests
        │
        └─ Rust zdstring-crypto
             └─ 生成加密 LMST Blob（沿用既有 Blob 格式）
                    │
                    └─ embed_macho_section.sh
                         └─ 链接为 __DATA,__zdstring section

ZDObfRuntime.xcframework + ZDObfKit wrapper
                         └─ App 运行时初始化和按 ID 查询
```

- **源码扫描**：`ZDString("...")` 和 `ZDString(@"...")` 只允许使用单个普通字符串字面量。扫描器把调用替换为内部 `ZDStringDecodeBytes(...)`，原始文件不参与编译。
- **加密目录**：Rust crypto core 使用 XChaCha20-Poly1305、HKDF 和 SHA-256 派生 ID、key、nonce 与 AAD，初始化时逐条认证全部记录，任何篡改或错误 key 都会使初始化失败。
- **Mach-O 嵌入**：构建脚本按 device/simulator 和架构把 Blob 编成带 `S_ATTR_NO_DEAD_STRIP` 的 `__DATA,__zdstring` relocatable object，最终链接的 `-dead_strip` 也不会剥掉它。
- **运行时查询**：wrapper 只把 Runtime callback 中的字节复制成 `String`/`NSString`，Runtime 返回后清理临时明文缓冲区。

`ZDStringDecodeBytes(...)` 的 8 字节参数是稳定查询 ID 的小端表示，不是字符串密文本身。真正的密文位于 `__DATA,__zdstring` section；wrapper 还原 ID 后调用 Rust Runtime 解密对应记录。业务源码只写 `ZDString(...)`，无需维护字节数组或生成函数名。

## 目录结构

```text
Apple/ObjectiveC/          Objective-C 公共头和实现
Apple/Swift/               Swift wrapper
crates/crypto-core/        Blob 格式、ID、KDF 和 AEAD
crates/runtime/            C ABI Runtime 和 XCFramework 输入
crates/crypto-cli/         构建期加密 CLI
Generator/                 Zig 源码扫描器和 Manifest 编排器
scripts/                   Xcode Build Phase、XCFramework 和 Mach-O 脚本
Tools/                     目录兼容访问器生成器
Examples/ZDObfDemo/        可运行的示例 Xcode 工程（Swift + Objective-C）
Tests/                     Rust/Zig/Python/XCTest/端到端测试
Package.swift              Swift Package Manager manifest
dist/ZDObfRuntime.xcframework  本地构建或下载的 Runtime（不入库，见“固定 Release”）
ZDObf.podspec             CocoaPods 规格
```

## 快速开始

最快的方式是跑一遍示例工程，它完整演示了“标记字符串 → 构建期加密 → 运行时解密”：

```sh
# 1. 构建 host 工具（Zig 扫描器 + Rust 加密 CLI，只需一次）
Examples/ZDObfDemo/Scripts/bootstrap.sh

# 2. 构建并运行（也可以 open Examples/ZDObfDemo/ZDObfDemo.xcodeproj 后直接 Run）
xcodebuild -project Examples/ZDObfDemo/ZDObfDemo.xcodeproj -scheme ZDObfDemo \
  -derivedDataPath /tmp/zdobf-demo build
/tmp/zdobf-demo/Build/Products/Debug/ZDObfDemo
```

输出里的 URL、问候语和主机名都是运行时才解密出来的；用 `strings` 查看二进制找不到它们。接入自己的 App 只有四件事：

1. **标记**：把需要保护的字面量写成 `ZDString("...")`（Swift）或 `ZDString(@"...")`（Objective-C）。
2. **构建**：在 App target 加一个 Run Script Build Phase 调用 `scripts/xcode_build_phase.sh`，并把生成的源码和 section object 加进编译与链接（见“Xcode 接入”）。
3. **初始化**：App 启动时调用一次 `ZDObf.initializeEmbedded(key:)`，key 必须与构建时的 `ZD_STRING_RUNTIME_KEY_B64` 相同；想只在构建环境配置一处 key，可开启 `ZD_STRING_EMBED_KEY=1` 后无参调用 `ZDObf.initializeEmbedded()`（安全取舍见“内嵌 key 模式”，示例工程用的就是这种）。
4. **使用**：之后正常访问包含 `ZDString(...)` 的代码。

## 示例工程

`Examples/ZDObfDemo` 是一个 macOS 命令行 App，用的配置与 iOS/tvOS/watchOS/visionOS App 相同（把平台和 `PLATFORM_NAME` 换成对应值即可）：

| 路径 | 说明 |
| --- | --- |
| `App/Protected/ProtectedAPI.swift`、`ProtectedAPIObjC.m` | 含 `ZDString(...)` 的原始源码；**不参与编译** |
| `Generated/`（构建时生成，已 gitignore） | Build Phase 生成的、只含 ID 的源码；**只有它们进入 Compile Sources** |
| `App/main.swift` | 启动时调用无参的 `ZDObf.initializeEmbedded()`，然后使用受保护字符串；演示抛错查询 API |
| `Scripts/zdobf_build_phase.sh` | 写 source-map、调用 `scripts/xcode_build_phase.sh`；⚠️ 这里是整个 Demo **唯一**的 key（仅供演示），并开启 `ZD_STRING_EMBED_KEY=1` |
| `project.yml` | XcodeGen 配置；`xcodegen generate` 可重新生成 `.xcodeproj`（已提交，无需安装 XcodeGen） |

工程里的关键设置与“Xcode 接入”一节一致：`ZD_STRING_NAMESPACE`、`ZD_STRING_DERIVED_DIR`、`ZD_STRING_SECTION_OBJECT`，`OTHER_LDFLAGS` 追加 section object，`ENABLE_USER_SCRIPT_SANDBOXING = NO`。依赖通过本地 Swift Package 引入（`ZDObfKit` 和 `ZDObfKitObjC`），Objective-C 里用 `@import ZDObfKitObjC;`。

测试：`python3 -m unittest discover -s Tests -p test_demo.py` 会构建 Demo、运行它，并用 `scripts/verify_macho_artifact.sh` 断言二进制含 `__zdstring` section 且不含明文。

## 环境要求

- macOS、完整 Xcode 27 或兼容版本
- Rust stable toolchain（支持 Rust 2024 edition）
- Zig 0.17.1
- Python 3
- CocoaPods 1.17 或兼容版本

最低平台版本为 iOS 15、macOS 15、tvOS 15、watchOS 8 和 visionOS 1；arm64 模拟器使用对应平台的最低模拟器版本。watchOS 真机切片同时包含 `arm64_32`（Series 4–8、SE 1 等 32 位指针设备，最低 watchOS 8）和 `arm64`（64 位设备，LLVM 对其最低要求为 watchOS 26）。以下构建命令均在本仓库根目录执行。组件同时提供 CocoaPods 和 Swift Package Manager 接入。

## 安装

Runtime 是预编译好的 `ZDObfRuntime.xcframework`，由 GitHub Release 提供，安装时不会调用 Cargo。

### CocoaPods

推荐直接用 Git tag（发布版本见 Releases）：

```ruby
pod 'ZDObf', :git => 'https://github.com/faimin/ZDObf.git', :tag => 'v0.1.1'
```

`pod install` 时 podspec 的 `prepare_command` 会从固定的 GitHub Release 下载并校验 Runtime。Objective-C 源码导入 `<ZDObfKit/ZDObf.h>`，Swift 源码导入 `ZDObfKit`。

> 本地开发用 `:path => '/absolute/path/to/ZDObf'` 时，CocoaPods **不会**对 `:path` Pod 执行 `prepare_command`。请先在仓库根目录运行一次 `scripts/fetch_runtime.sh`（或 `scripts/build_xcframework.sh` 自行构建），再 `pod install`。

### 发布与预构建包

Runtime 通过手动触发的 `.github/workflows/release-xcframework.yml`（`workflow_dispatch`）发布，输入版本号如 `0.1.1`：

- `publish=false`：只构建全平台 slice（iOS、iOS Simulator、tvOS、watchOS、visionOS、macOS、Mac Catalyst）并上传 Actions artifact，用于演练。
- `publish=true`（只允许在 `main` 上）：构建 → 把 `Package.swift` 固定到本次资产并同步 podspec 版本 → 提交 `release: vX.Y.Z` 到 `main` → 在该提交上创建 `vX.Y.Z` Release 并上传 `ZDObfRuntime.xcframework.zip` 和 `.sha256`。固定值提交先于 tag，所以每个 tag 的 `Package.swift` 指向它自己的 Runtime。

构建脚本会用 `--remap-path-prefix` 去掉构建机的用户名和工具链路径；`arm64_32` 是 tier 3 目标，脚本会自动安装 nightly（含 `rust-src`）并用 `-Zbuild-std` 构建；构建结束前会断言每个切片的 `minos` 不高于声明的最低版本。

#### 固定 Release（URL + checksum）

`Package.swift` 顶部的 `runtimeReleaseVersion` / `runtimeReleaseChecksum` 决定远程 binaryTarget：

- `dist/ZDObfRuntime.xcframework` 存在时优先使用本地产物；设置 `ZDOBF_USE_RELEASE_RUNTIME=1` 可强制走 Release 资产。
- 本地没有 `dist/` 且未固定 Release 时，`swift package` 会报出明确错误，而不是生成无效依赖。
- `scripts/pin_runtime_release.sh <版本> <zip>` 写入版本和 SHA-256（发布 workflow 自动调用）；`scripts/fetch_runtime.sh` 按固定值下载并校验 zip 到 `dist/`。
- `dist/` 不入库（`.gitignore`）。SwiftPM 会缓存已解析的 manifest，本地 `dist/` 出现或消失后选择可能不更新：切换后运行 `swift package reset`（或 `rm -rf .build`）即可。

### Swift Package Manager

本仓库的 `Package.swift` 包名为 `ZDObf`，提供两个产品。包名与模块名分开：

- `ZDObfKit`：Swift 模块、Swift wrapper 和 `ZDObf.initializeEmbedded(key:)` API。
- `ZDObfKitObjC`：Objective-C 模块、Objective-C wrapper 和 `ZDObfInitializeEmbedded(...)` API。

```swift
dependencies: [
    .package(url: "https://github.com/faimin/ZDObf.git", from: "0.1.1")
    // 本地开发：.package(path: "../ZDObf")
]
```

在 target 中依赖产品 `ZDObfKit`；如果需要单独使用 Objective-C API，则依赖 `ZDObfKitObjC`。Swift 源码导入 `ZDObfKit`；Objective-C 源码用 `@import ZDObfKitObjC;`（SwiftPM 产品的模块名，头文件没有 `ZDObfKit/` 目录前缀，CocoaPods 才使用 `<ZDObfKit/ZDObf.h>`）。`Package.swift` 的 binary target 指向固定的 GitHub Release 资产（URL + checksum），因此执行 `swift package resolve` 或 `swift build` 不需要本机安装 Rust。本地存在 `dist/ZDObfRuntime.xcframework` 时优先使用它。

## 构建工具和密钥

```sh
cargo build --locked --release -p zd_string_crypto_cli
(cd Generator && zig build -Doptimize=ReleaseSafe)
```

产物为 `target/release/zdstring-crypto`、`Generator/zig-out/bin/zdstring-gen` 和 `dist/ZDObfRuntime.xcframework`。

构建 key 必须通过环境变量注入，且 Base64 解码后正好是 32 bytes：

```sh
export ZD_STRING_RUNTIME_KEY_B64="$(openssl rand -base64 32)"
```

正式环境应从 CI Secret Manager 注入。不要把 key 写入源码、Scheme、`.xcconfig`、Podfile、Bundle 或 README；App 初始化时必须取得同一份原始 32-byte key。

上面的随机命令只用于首次创建开发密钥；应将其保存到自己的密钥管理系统，后续构建复用并按发布版本管理。运行时收到的是 Base64 文本时，需要先解码为 `Data` / `NSData`，不能把 Base64 字符串的 UTF-8 字节直接作为 key。组件不自动把构建环境变量传给 App，也不提供密钥获取服务。

### 只配置一处：内嵌 key 模式（可选）

默认情况下 key 要在两处保持一致：构建环境的 `ZD_STRING_RUNTIME_KEY_B64`，和 App 运行时传给 `initializeEmbedded(key:)` 的值。如果更看重省事，可以只在构建环境配置一处：

```sh
export ZD_STRING_RUNTIME_KEY_B64="$(openssl rand -base64 32)"   # 唯一的 key 配置点
export ZD_STRING_EMBED_KEY=1
```

构建时 `zdstring-gen embed-key` 会把 key 与由 key 派生的 32 字节掩码异或后写入 `__DATA,__zdkey` section，运行时无参初始化即可：

```swift
try ZDObf.initializeEmbedded()                      // Swift
```

```objc
ZDObfInitializeEmbeddedWithBuiltInKey(&error);      // Objective-C
```

> ⚠️ **安全取舍**：此时 key（仅经异或掩码，不是加密）和密文在同一个二进制里，攻击者拿到二进制就能还原 key 并解密全部字符串，保护强度只相当于混淆。需要把 key 与密文分离时，不要开启 `ZD_STRING_EMBED_KEY`，改用 `initializeEmbedded(key:)` 并从 Keychain 或服务端取得 key。
>
> 只开了内嵌 key 的构建才有 `__zdkey`；用无参初始化调用一个没有该 section 的二进制会返回 `malformedBlob`。构建目录里的临时 key 载荷（`zdkey.bin`）会在构建结束时删除。更换 key 只需改环境变量并重新构建，不需要再改 App 代码。

### 更换 Runtime key

Runtime key 可以更换，但构建期和运行时必须同步使用同一份新 key，并重新构建、链接和发布 App。推荐按 App 版本轮换，不要在已经运行的进程中尝试切换 key。

1. 保留旧版本使用的 key，确保已经发布的旧 App 仍能解密自己的 Blob。
2. 在密钥管理系统中生成新的 32-byte key，并只注入当前构建环境：

   ```sh
   export ZD_STRING_RUNTIME_KEY_B64="$(openssl rand -base64 32)"
   ```

3. 使用新 key 重新运行 App 的 `scripts/xcode_build_phase.sh`，让扫描器、加密 CLI 和 `__DATA,__zdstring` section 生成新的 Blob。
4. 让新 App 启动时从同一密钥管理系统取得这份新 key，再调用 `ZDObf.initializeEmbedded(key:)` 或 `ZDObfInitializeEmbedded(...)`。
5. 完成新的 App 构建并发布；旧 App 继续使用旧 key，新 App 使用新 key。

开启了内嵌 key 模式时没有“运行时 key”这一份，换 key 只需改构建环境变量并重新构建（见上一节）。

只更新运行时 key 而不重新生成 Blob，或只重新生成 Blob 而不更新运行时 key，都会导致 `authenticationFailed`。Runtime 初始化成功后，当前进程不能再次切换 key；如果需要旧 key 与新 key 在同一版本同时兼容，需要另外设计 key version 和多 key 迁移协议，当前实现不提供该能力。

## Xcode 接入

在最终 App target 增加：

```text
ZD_STRING_NAMESPACE = $(PRODUCT_BUNDLE_IDENTIFIER)
ZD_STRING_DERIVED_DIR = $(DERIVED_FILE_DIR)/ZDObf
ZD_STRING_SECTION_OBJECT = $(ZD_STRING_DERIVED_DIR)/zdstring-section.o
```

在 Other Linker Flags 中追加：

```text
$(inherited)
"$(ZD_STRING_SECTION_OBJECT)"
```

新增 Run Script Build Phase，放在 Compile Sources 之前：

```sh
set -eu

library_dir="$SRCROOT/../ZDObf"
export ZD_STRING_DERIVED_DIR="${ZD_STRING_DERIVED_DIR:-$DERIVED_FILE_DIR/ZDObf}"
export ZD_STRING_SECTION_OBJECT="${ZD_STRING_SECTION_OBJECT:-$ZD_STRING_DERIVED_DIR/zdstring-section.o}"
mkdir -p "$ZD_STRING_DERIVED_DIR/Sources"
source_map="$ZD_STRING_DERIVED_DIR/source-map.txt"

printf '%s|%s|%s\n' \
  "$SRCROOT/App/Protected/ProtectedAPI.swift" \
  "$ZD_STRING_DERIVED_DIR/Sources/ProtectedAPI.swift" swift \
  "$SRCROOT/App/Protected/ProtectedAPIObjC.m" \
  "$ZD_STRING_DERIVED_DIR/Sources/ProtectedAPIObjC.m" objc \
  > "$source_map"

: "${ZD_STRING_RUNTIME_KEY_B64:?请先向构建环境注入字符串保护 key}"
"$library_dir/scripts/xcode_build_phase.sh" "$source_map"
```

原始 Protected 源文件保留在仓库中，但从 App target 的 Compile Sources/Target Membership 移除；将 `$(ZD_STRING_DERIVED_DIR)/Sources/...` 生成文件加入 Compile Sources；Run Script 的 Input Files 列出原始文件，Output Files 列出生成源码和 `$(ZD_STRING_SECTION_OBJECT)`。首次接入建议关闭 Based on dependency analysis。

示例中的 `library_dir`、App 源文件路径需按工程布局调整；脚本内部默认从自身路径定位生成器和加密 CLI。原始文件不参与编译，`ZDString` 只是构建期标记，不是透传函数或宏。不要在 Copy Bundle Resources 中加入 Manifest 或 Blob。

生成文件引用使用 `sourceTree = DERIVED_FILE_DIR`，例如 `path = ZDObf/Sources/ProtectedAPI.swift`，并创建对应的 Compile Sources 条目；不要引用某台机器的 DerivedData 绝对路径。脚本 Output Files 至少声明两份生成源码及 `$(ZD_STRING_SECTION_OBJECT)`。首次接入可将 `ENABLE_USER_SCRIPT_SANDBOXING` 设为 `NO`；若开启，需要完整声明脚本读取和写入的文件。

标记要求精确匹配 `ZDString(`；不支持插值、动态表达式、拼接、raw/multiline 参数或 Unicode 转义。支持普通 UTF-8、`\\`、`\"`、`\n`、`\r`、`\t`、`\0`。详细扫描限制见 `ZDObf-技术方案.md`。

## 使用方法

### Swift

```swift
import ZDObfKit

enum ProtectedAPI {
    static func userURL() -> String? {
        // 业务源码始终保留 ZDString；Build Phase 只编译生成文件。
        return ZDString("https://api.example.com/v1/user")
    }
}
```

在任何受保护字符串首次访问前初始化：

```swift
import Foundation
import ZDObfKit

func prepareProtectedStrings(runtimeKey: Data) throws {
    try ZDObf.initializeEmbedded(key: runtimeKey)
}
```

初始化成功后，业务代码可以直接调用 `ProtectedAPI.userURL()`；构建生成的 `ZDStringDecodeBytes(...)` 只存在于 Derived Sources 中，业务源码不需要知道它。

需要明确错误时，可以使用 Runtime 查询 API：

```swift
let value = try ZDObf.string(for: generatedID)
```

通常不需要手工维护 `generatedID`，因为 `ZDString("...")` 会在构建阶段自动生成对应的 ID 字节数组。

例如，把下面的请求方法放在已配置扫描的 `App/Protected/ProtectedAPI.swift` 中；`startProtectedRequest` 可以放在普通启动文件中。`keyBase64` 由 App 自己的密钥提供方传入，必须对应当前构建所用的 key：

```swift
import Foundation
import ZDObfKit

enum ProtectedRequest {
    static func userRequest() -> URLRequest? {
        guard let text = ZDString("https://api.example.com/v1/user"),
              let url = URL(string: text) else { return nil }
        return URLRequest(url: url)
    }
}

func startProtectedRequest(keyBase64: String) throws {
    guard let key = Data(base64Encoded: keyBase64), key.count == 32 else {
        throw ZDObfError.invalidArgument
    }
    try ZDObf.initializeEmbedded(key: key)
    guard let request = ProtectedRequest.userRequest() else {
        throw ZDObfError.invalidID
    }
    URLSession.shared.dataTask(with: request).resume()
}
```

上例将字符串访问失败转换为业务层的 `invalidID`；需要诊断具体原因时使用前述抛错查询接口。`startProtectedRequest` 中的初始化只应在启动流程执行一次；后续请求直接调用 `ProtectedRequest.userRequest()`。

### Objective-C

```objc
#import <ZDObfKit/ZDObf.h>

NSString * _Nullable ProtectedUserURL(void) {
    return ZDString(@"https://api.example.com/v1/user");
}

BOOL PrepareProtectedStrings(NSData *runtimeKey, NSError **error) {
    return ZDObfInitializeEmbedded(runtimeKey, error);
}
```

在普通启动代码中先初始化，再调用已扫描业务文件中的 `ProtectedUserURL()`。下面的 `keyBase64` 同样由业务密钥提供方传入：

```objc
#import <ZDObfKit/ZDObf.h>

extern NSString * _Nullable ProtectedUserURL(void);

BOOL StartProtectedRequest(NSString *keyBase64, NSError **error) {
    NSData *key = [[NSData alloc] initWithBase64EncodedString:keyBase64 options:0];
    if (key.length != 32) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:ZDObfErrorDomain code:1 userInfo:nil];
        }
        return NO;
    }
    if (!ZDObfInitializeEmbedded(key, error)) {
        return NO;
    }
    NSString *text = ProtectedUserURL();
    NSURL *url = text == nil ? nil : [NSURL URLWithString:text];
    if (url == nil) {
        return NO;
    }
    [[[NSURLSession sharedSession] dataTaskWithURL:url] resume];
    return YES;
}
```

初始化只执行一次；不要在每个网络请求前重复调用此启动函数。

Objective-C 初始化失败时通过 `NSError` 获取 Runtime 错误码。初始化成功后，可以直接调用返回 `ZDString(...)` 的业务函数；生成源码中的 `ZDStringDecodeBytes(...)` 失败时返回 `nil`。

如果需要从普通 `NSData` Blob 初始化，而不是从最终 Mach-O section 初始化：

```objc
NSError *error = nil;
BOOL ok = ZDObfInitialize(blob, runtimeKey, &error);
if (!ok) {
    NSLog(@"ZDObf initialization failed: %@", error);
}
```

### 最小接入清单

1. 构建 host 工具（Runtime 由 SwiftPM/CocoaPods 从 Release 获取，无需自己构建）：

   ```sh
   cargo build --locked --release -p zd_string_crypto_cli
   (cd Generator && zig build -Doptimize=ReleaseSafe)
   ```

2. 在 App target 中把包含 `ZDString(...)` 的原始 Swift/Objective-C 文件移出 Compile Sources，保留它们作为 Build Phase 的输入。
3. 让 Run Script 生成的 `$(ZD_STRING_DERIVED_DIR)/Sources/*.swift` 和 `*.m` 进入 Compile Sources，并把 `$(ZD_STRING_SECTION_OBJECT)` 加入 Other Linker Flags。
4. 在构建环境注入 32-byte `ZD_STRING_RUNTIME_KEY_B64`，然后运行 `scripts/xcode_build_phase.sh`。如需免去运行时传 key，同时设置 `ZD_STRING_EMBED_KEY=1`。
5. App 启动时先调用 `ZDObf.initializeEmbedded(key:)` 或 `ZDObfInitializeEmbedded(...)`（内嵌 key 模式下改用无参的 `ZDObf.initializeEmbedded()` / `ZDObfInitializeEmbeddedWithBuiltInKey(&error)`），再访问包含 `ZDString(...)` 的业务函数。
6. 构建完成后检查 section 和明文泄露：

   ```sh
   scripts/verify_macho_artifact.sh \
     --binary /absolute/path/to/Payload/MyApp.app/MyApp \
     --forbid 'https://api.example.com/v1/user'
   ```

关键约束是：原始源码不能继续参与编译；只有生成源码可以进入 Compile Sources。否则 `ZDString(@"...")` 或 `ZDString("...")` 的明文仍会进入目标文件。

## 目录兼容模式

当访问器编译在独立 Pod 中、Blob 由 App 生成时，可以从 JSON 目录生成稳定 ID 访问器：

```sh
python3 Tools/zdstring_catalog_codegen.py \
  --input Tests/fixtures/catalog_paths.json \
  --objc-header /tmp/zdstring-catalog/ZDURLPathCatalog.h \
  --objc-implementation /tmp/zdstring-catalog/ZDURLPathCatalog.mm \
  --swift-output /tmp/zdstring-catalog/ZDURLPathCatalog.swift
```

生成的 Swift 类型为 `ZDURLPathCatalog`，Objective-C 类型为 `ZDURLPathCatalogObjC`。访问器只包含稳定 ID，不包含目录明文；App Build Phase 仍需使用同一 JSON 生成 Blob。

映射格式为“合法标识符 → 非空字符串”。把生成文件加入访问器 target，并让该 target 依赖 `ZDObf`；然后在 App Build Settings 中设置 `ZD_STRING_CATALOG_MAPPING = /absolute/path/to/catalog.json`。仅目录模式运行 `"$library_dir/scripts/xcode_build_phase.sh"`，不传 source-map；仍需配置 namespace、key、链接 object 和 Runtime 初始化。映射变化后，重新生成访问器和 App Blob。

目录访问器查询失败时返回空字符串，应先初始化并在请求边界检查空值。目录 ID 不依赖 App namespace；普通扫描 ID 依赖 namespace 和 key，修改其中任何一个后必须同时重新生成源码和 Blob。

## 构建配置与排错

| 变量 | 默认值或用途 |
| --- | --- |
| `ZD_STRING_RUNTIME_KEY_B64` | 必填；Base64 解码后 32 bytes。扫描阶段也用它派生稳定 ID，缺失时扫描失败 |
| `ZD_STRING_EMBED_KEY` | 设为 `1` 时把（掩码后的）key 内嵌进二进制，运行时可无参初始化；默认关闭，见“内嵌 key 模式” |
| `ZD_STRING_NAMESPACE` | 默认 `PRODUCT_BUNDLE_IDENTIFIER` |
| `ZD_STRING_GENERATOR` / `ZD_STRING_CRYPTO_CLI` | 默认本仓库内构建的 host 工具 |
| `ZD_STRING_CATALOG_MAPPING` | 可选；目录模式 JSON |
| `ZD_STRING_PROFILE` / `ZD_STRING_NONCE_MODE` | Debug 为 `debug` / `deterministic`；Release 为 `release` / `random` |
| `ZD_STRING_KEEP_MANIFESTS` | 设为 `1` 时保留含明文的中间 Manifest（权限 0600）；默认构建结束后删除 |
| `ZD_STRING_BUILD_SALT_B64` | 可选；确定性 Release 必填，解码后 32 bytes |
| `ZD_STRING_ARCH` | 可选；覆盖自动选择的架构或架构列表 |

只有名称恰好为 `Release` 的构建配置会自动切换发布模式。`AdHoc`、`Production` 等配置需显式设置 `ZD_STRING_PROFILE=release` 和 `ZD_STRING_NONCE_MODE=random`。Xcode GUI 进程不会自动继承之后在终端 export 的 key，应由构建环境注入。

| 现象 | 检查方向 |
| --- | --- |
| `ZDString` 未定义 | 原始文件被直接编译，应改为编译生成源码 |
| 工具或 XCFramework 不存在 | 先构建 host 工具和 Runtime |
| Embedded 初始化失败 | 确认 object 链接进最终 App 主可执行文件 |
| `authenticationFailed` | 检查运行时原始 key 与本次构建是否一致 |
| `invalidID` 或查询空值 | 检查初始化顺序、namespace、访问器和 Blob 是否一致 |
| device/simulator 架构错误 | 重建对应平台的 section object，避免复用旧 object |

## 验证

```sh
cargo test --locked --workspace
(cd Generator && zig build test && zig fmt --check src)
swift test                                            # ZDObfKit / ZDObfKitObjC 的 XCTest
python3 -m unittest discover -s Tests -p 'test_*.py'  # 含端到端和 Demo 构建
```

测试分层：

| 测试 | 覆盖 |
| --- | --- |
| `cargo test` | Blob 格式、加解密、ID 固定向量、篡改/截断、C ABI 参数校验 |
| `zig build test` | 扫描器词法规则、ID 派生与 Rust 的一致性 |
| `swift test` | Swift 和 Objective-C API：未初始化、错误 key、篡改 Blob、单例、解码（固定 Blob 由 `Tests/ZDObfKitTests/regenerate_fixture.py` 生成） |
| `Tests/test_end_to_end.py` | 扫描 → 加密 → 嵌入 → 链接（含动态库、Debug dylib 两种布局）→ 解密 |
| `Tests/test_demo.py` | 构建并运行示例工程，断言无明文泄露 |

验收最终 App 是否包含 section 且没有指定明文：

```sh
scripts/verify_macho_artifact.sh \
  --binary /absolute/path/to/Payload/MyApp.app/MyApp \
  --forbid 'https://api.example.com/v1/user'
```

## 限制与安全边界

- Runtime 初始化只允许成功一次；成功后再次初始化返回 `alreadyInitialized`。
- `ZDObfInitializeEmbedded` 按 dyld 加载顺序查找第一个带 `__DATA,__zdstring` 的镜像（通常是主可执行文件；Xcode 的 Debug dylib 模式下是 `App.debug.dylib`）；wrapper 本身可以位于动态 framework 中。
- 开启 `ZD_STRING_EMBED_KEY=1` 后，（经异或掩码的）key 与密文同在二进制里，只剩混淆强度的保护，详见“内嵌 key 模式”。
- Blob 最大 64 MiB，单条 UTF-8 字符串最大 1 MiB，最多 1,000,000 条记录。
- 原始 Manifest、映射 JSON 和构建 key 只应存在于构建环境，不应加入 Bundle 或公开 CI artifact。
- 该方案降低静态字符串提取便利性，不能抵御调试、Hook、运行时内存读取或客户端 key 提取。
- 普通扫描的稳定 ID 由构建 key 派生，不持有 key 无法离线验证猜测的明文；目录兼容模式的 ID 是无密钥哈希（Pod 编译期固化），可被离线验证，不要用它保护低熵敏感字符串。
- 为保持已有 Blob 格式兼容，内部 magic `LMST` 与 `LMStringProtection/...` 派生域保留原始字节值；文件名、公开类型、函数、构建变量和工具均使用 `ZD` 前缀。普通扫描的 ID 派生已改为带 key 的 `LMStringProtection/id/v2`，与迁移前的无密钥 ID 不兼容，升级后需重新生成源码和 Blob。

## 项目背景与设计取舍

ZDObf 由原业务仓库中的字符串保护组件迁移而来，目标是成为可独立接入的仓库：公开文件名、类名、函数名、Rust crate、构建变量和文档统一使用 `ZD` 前缀，继续同时支持 Swift、Objective-C、Rust、Zig、CocoaPods 和 Mach-O section 嵌入。

- **保持不变**：加密格式（`LMST` v1 Blob）、Runtime C ABI、源码扫描器、目录兼容模式和 Xcode Build Phase。
- **不在范围内**：原业务仓库的 Podfile 接入和业务调用点不属于本仓库。
- **为什么是一个仓库**：Rust crypto core、Runtime、Zig generator、Apple wrapper、构建脚本和测试共享同一套 Blob 协议。只抽取 Apple wrapper 会破坏“扫描 → 加密 → 嵌入 → 运行时查询”的构建闭环，也会引入额外的跨仓库依赖，因此整体迁移，只改命名空间和布局，不改变加密算法或构建语义。

### 验收标准

- `cargo test --locked --workspace`、Zig generator 测试和 Python 测试通过。
- 公开头文件不依赖仓库内部路径（Pod 符号链接、SPM binary target 和 framework 复制布局均可编译）。
- 代码、脚本、Podspec、测试和文档中不残留旧的 `LM` 公开标识；`LMST` 与 `LMStringProtection/...` 作为协议字节值除外。
