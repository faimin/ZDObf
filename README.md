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
- **Mach-O 嵌入**：构建脚本按 device/simulator 和架构生成 relocatable object，使用 `ld -sectcreate` 把 Blob 链接到最终 App。
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
Tests/                     Rust/Zig/Python/Apple 集成测试
Package.swift              Swift Package Manager manifest
dist/ZDObfRuntime.xcframework  可追踪的 Apple 平台 Runtime binary target
ZDObf.podspec             CocoaPods 规格
```

## 环境要求

- macOS、完整 Xcode 27 或兼容版本
- Rust stable toolchain（支持 Rust 2024 edition）
- Zig 0.17.1
- Python 3
- CocoaPods 1.17 或兼容版本

最低平台版本为 iOS 15、macOS 15、tvOS 15、watchOS 8 和 visionOS 1；arm64 模拟器使用对应平台的最低模拟器版本。watchOS 真机切片同时包含 `arm64_32`（Series 4–8、SE 1 等 32 位指针设备，最低 watchOS 8）和 `arm64`（64 位设备，LLVM 对其最低要求为 watchOS 26）。以下构建命令均在本仓库根目录执行。组件同时提供 CocoaPods 和 Swift Package Manager 接入。

## 安装

先构建 Runtime XCFramework：

```sh
./scripts/build_xcframework.sh
```

在 App target 对应的 Podfile 中添加：

```ruby
pod 'ZDObf', :path => '/absolute/path/to/ZDObf'
```

然后执行 `pod install`。Pod 只编译 Apple wrapper 并链接已准备好的 `dist/ZDObfRuntime.xcframework`，不会在安装或日常 App 构建时调用 Cargo。

### 使用 GitHub Release 预构建包

推送形如 `v0.1.0` 的 Git tag 后，`.github/workflows/release-xcframework.yml` 会在 macOS runner 上构建 iOS、iOS Simulator、tvOS、watchOS、visionOS、macOS 和 Mac Catalyst 全平台 slice，并通过 `softprops/action-gh-release@v3` 上传：

- `ZDObfRuntime.xcframework.zip`
- `ZDObfRuntime.xcframework.zip.sha256`

下载 Release 中的 zip 后解压到仓库的 `dist/ZDObfRuntime.xcframework`，即可按上面的 CocoaPods 配置使用。`workflow_dispatch` 可以手动验证构建并取得 Actions artifact；只有 tag push 会创建或更新 Release assets。

构建脚本会用 `--remap-path-prefix` 去掉构建机的用户名和工具链路径；`arm64_32` 是 tier 3 目标，脚本会自动安装 nightly（含 `rust-src`）并用 `-Zbuild-std` 构建；构建结束前会断言每个切片的 `minos` 不高于声明的最低版本。Job Summary 会给出 zip 的 SHA-256 和固定命令。

#### 固定 Release（URL + checksum）

`Package.swift` 顶部的 `runtimeReleaseVersion` / `runtimeReleaseChecksum` 决定远程 binaryTarget：

- `dist/ZDObfRuntime.xcframework` 存在时优先使用本地产物；设置 `ZDOBF_USE_RELEASE_RUNTIME=1` 可强制走 Release 资产。
- 本地没有 `dist/` 且未固定 Release 时，`swift package` 会报出明确错误，而不是生成无效依赖。
- Release 发布后，用 `scripts/pin_runtime_release.sh <版本> <zip>` 写入版本和 SHA-256，提交到 `main`。
- `scripts/fetch_runtime.sh` 按固定值下载并校验 zip，解压到 `dist/`；`ZDObf.podspec` 的 `prepare_command` 在 `dist/` 缺失时自动调用它。
- 完成第一次固定并验证后，才可以把 `dist/` 从 Git 中移除（`git rm -r --cached dist/ZDObfRuntime.xcframework` 并去掉 `.gitignore` 里的例外）。在此之前保持跟踪，否则按 tag 引入的使用者拿不到 Runtime。

### Swift Package Manager

本仓库的 `Package.swift` 包名为 `ZDObf`，提供两个产品。包名与模块名分开：

- `ZDObfKit`：Swift 模块、Swift wrapper 和 `ZDObf.initializeEmbedded(key:)` API。
- `ZDObfKitObjC`：Objective-C 模块、Objective-C wrapper 和 `ZDObfInitializeEmbedded(...)` API。

本地开发或使用源码依赖时：

```swift
dependencies: [
    .package(path: "../ZDObf")
]
```

在 target 中依赖产品 `ZDObfKit`；如果需要单独使用 Objective-C API，则依赖 `ZDObfKitObjC`。Swift 源码导入 `ZDObfKit`，Objective-C 源码导入 `<ZDObfKit/ZDObf.h>`。`Package.swift` 使用仓库内可追踪的 `dist/ZDObfRuntime.xcframework` binary target，因此执行 `swift package resolve` 或 `swift build` 不需要本机安装 Rust。发布版本可以先从 GitHub Release 下载同名 XCFramework 覆盖 `dist/ZDObfRuntime.xcframework`，再通过本地包或 Git tag 引入。

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

1. 构建 Runtime 和 host 工具：

   ```sh
   ./scripts/build_xcframework.sh
   cargo build --locked --release -p zd_string_crypto_cli
   (cd Generator && zig build -Doptimize=ReleaseSafe)
   ```

2. 在 App target 中把包含 `ZDString(...)` 的原始 Swift/Objective-C 文件移出 Compile Sources，保留它们作为 Build Phase 的输入。
3. 让 Run Script 生成的 `$(ZD_STRING_DERIVED_DIR)/Sources/*.swift` 和 `*.m` 进入 Compile Sources，并把 `$(ZD_STRING_SECTION_OBJECT)` 加入 Other Linker Flags。
4. 在构建环境注入同一份 32-byte `ZD_STRING_RUNTIME_KEY_B64`，然后运行 `scripts/xcode_build_phase.sh`。
5. App 启动时先调用 `ZDObf.initializeEmbedded(key:)` 或 `ZDObfInitializeEmbedded(...)`，再访问包含 `ZDString(...)` 的业务函数。
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
(cd Generator && zig build test && zig fmt --check src/main.zig)
python3 -m unittest discover -s Tests -p 'test_*.py'
```

验收最终 App 是否包含 section 且没有指定明文：

```sh
scripts/verify_macho_artifact.sh \
  --binary /absolute/path/to/Payload/MyApp.app/MyApp \
  --forbid 'https://api.example.com/v1/user'
```

## 限制与安全边界

- Runtime 初始化只允许成功一次；成功后再次初始化返回 `alreadyInitialized`。
- `ZDObfInitializeEmbedded` 通过 dyld 的主可执行文件镜像定位 `__DATA,__zdstring`，不会自动搜索 framework 或 dylib；wrapper 本身可以位于动态 framework 中。
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
