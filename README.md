# ZDObf

ZDObf 是一个面向 iOS 的字符串保护组件。它在构建阶段扫描 Swift/Objective-C 源码，把受保护的字符串字面量替换成稳定 ID；随后使用 Rust 加密目录，将密文嵌入最终 App 可执行文件的 Mach-O `__DATA,__zdstring` section。运行时由 Swift 或 Objective-C wrapper 使用 32 字节 key 解密查询。

组件降低静态提取客户端字符串的便利性。字符串在运行时仍会以明文出现在进程内存中，因此它不能替代服务端鉴权、密钥管理或反调试方案。

## 实现思路

```text
Swift / Objective-C 源码
        │
        ├─ zdstring-gen scan
        │    ├─ 生成只包含 LMStringDecodeBytes(...) 的源码
        │    └─ 生成构建期明文 Manifest
        │
        ├─ zdstring-gen merge-manifests
        │
        └─ Rust zdstring-crypto
             └─ 生成加密 LMST Blob（沿用既有 Blob 格式）
                    │
                    └─ embed_macho_section.sh
                         └─ 链接为 __DATA,__zdstring section

ZDStringProtectionRuntime.xcframework + ZDStringProtection wrapper
                         └─ App 运行时初始化和按 ID 查询
```

- **源码扫描**：`LMString("...")` 和 `LMString(@"...")` 只允许使用单个普通字符串字面量。扫描器把调用替换为内部 `LMStringDecodeBytes(...)`，原始文件不参与编译。
- **加密目录**：Rust crypto core 使用 XChaCha20-Poly1305、HKDF 和 SHA-256 派生 ID、key、nonce 与 AAD，并校验完整 Manifest。
- **Mach-O 嵌入**：构建脚本按 device/simulator 和架构生成 relocatable object，使用 `ld -sectcreate` 把 Blob 链接到最终 App。
- **运行时查询**：wrapper 只把 Runtime callback 中的字节复制成 `String`/`NSString`，Runtime 返回后清理临时明文缓冲区。

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
ZDStringProtection.podspec CocoaPods 规格
```

## 环境要求

- macOS、完整 Xcode 27 或兼容版本
- Rust stable toolchain（支持 Rust 2024 edition）
- Zig 0.17.1
- Python 3
- CocoaPods 1.17 或兼容版本

最低 iOS 13；arm64 模拟器最低 iOS 14。以下构建命令均在本仓库根目录执行。当前提供 CocoaPods 接入，尚未提供 SPM Package。

## 安装

先构建 Runtime XCFramework：

```sh
./scripts/build_xcframework.sh
```

在 App target 对应的 Podfile 中添加：

```ruby
pod 'ZDStringProtection', :path => '/absolute/path/to/ZDObf'
```

然后执行 `pod install`。Pod 只编译 Apple wrapper 并链接已准备好的 `dist/ZDStringProtectionRuntime.xcframework`，不会在安装或日常 App 构建时调用 Cargo。

## 构建工具和密钥

```sh
cargo build --locked --release -p zd_string_crypto_cli
(cd Generator && zig build -Doptimize=ReleaseSafe)
```

产物为 `target/release/zdstring-crypto`、`Generator/zig-out/bin/zdstring-gen` 和 `dist/ZDStringProtectionRuntime.xcframework`。

构建 key 必须通过环境变量注入，且 Base64 解码后正好是 32 bytes：

```sh
export ZD_STRING_RUNTIME_KEY_B64="$(openssl rand -base64 32)"
```

正式环境应从 CI Secret Manager 注入。不要把 key 写入源码、Scheme、`.xcconfig`、Podfile、Bundle 或 README；App 初始化时必须取得同一份原始 32-byte key。

## Xcode 接入

在最终 App target 增加：

```text
ZD_STRING_NAMESPACE = $(PRODUCT_BUNDLE_IDENTIFIER)
ZD_STRING_DERIVED_DIR = $(DERIVED_FILE_DIR)/ZDStringProtection
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
export ZD_STRING_DERIVED_DIR="${ZD_STRING_DERIVED_DIR:-$DERIVED_FILE_DIR/ZDStringProtection}"
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

生成文件引用使用 `sourceTree = DERIVED_FILE_DIR`，例如 `path = ZDStringProtection/Sources/ProtectedAPI.swift`，并创建对应的 Compile Sources 条目；不要引用某台机器的 DerivedData 绝对路径。脚本 Output Files 至少声明两份生成源码及 `$(ZD_STRING_SECTION_OBJECT)`。首次接入可将 `ENABLE_USER_SCRIPT_SANDBOXING` 设为 `NO`；若开启，需要完整声明脚本读取和写入的文件。

标记要求精确匹配 `LMString(`；不支持插值、动态表达式、拼接、raw/multiline 参数或 Unicode 转义。支持普通 UTF-8、`\\`、`\"`、`\n`、`\r`、`\t`、`\0`。详细扫描限制见 `ZDStringProtection-技术方案.md`。

## 使用方法

### Swift

```swift
import ZDStringProtection

enum ProtectedAPI {
    static func userURL() -> String? {
        // 构建阶段会把 LMString 替换为内部 LMStringDecodeBytes。
        return LMString("https://api.example.com/v1/user")
    }
}
```

在任何受保护字符串首次访问前初始化：

```swift
import Foundation
import ZDStringProtection

func prepareProtectedStrings(runtimeKey: Data) throws {
    try ZDStringProtection.initializeEmbedded(key: runtimeKey)
}
```

需要明确错误时使用 `try ZDStringProtection.string(for: generatedID)`；兼容函数 `ZDStringID(generatedID)` 会把查询失败转换为 `nil`。

### Objective-C

```objc
#import <ZDStringProtection/ZDStringProtection.h>

NSString * _Nullable ProtectedUserURL(void) {
    return LMString(@"https://api.example.com/v1/user");
}

BOOL PrepareProtectedStrings(NSData *runtimeKey, NSError **error) {
    return ZDStringProtectionInitializeEmbedded(runtimeKey, error);
}
```

Objective-C 初始化失败时通过 `NSError` 获取 Runtime 错误码；`ZDStringID(generatedID)` 返回 `nil` 表示未初始化、ID 不存在或解密失败。

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

映射格式为“合法标识符 → 非空字符串”。把生成文件加入访问器 target，并让该 target 依赖 `ZDStringProtection`；然后在 App Build Settings 中设置 `ZD_STRING_CATALOG_MAPPING = /absolute/path/to/catalog.json`。仅目录模式运行 `"$library_dir/scripts/xcode_build_phase.sh"`，不传 source-map；仍需配置 namespace、key、链接 object 和 Runtime 初始化。映射变化后，重新生成访问器和 App Blob。

目录访问器查询失败时返回空字符串，应先初始化并在请求边界检查空值。目录 ID 不依赖 App namespace；普通扫描 ID 依赖 namespace，修改 namespace 后必须同时重新生成源码和 Blob。

## 构建配置与排错

| 变量 | 默认值或用途 |
| --- | --- |
| `ZD_STRING_RUNTIME_KEY_B64` | 必填；Base64 解码后 32 bytes |
| `ZD_STRING_NAMESPACE` | 默认 `PRODUCT_BUNDLE_IDENTIFIER` |
| `ZD_STRING_GENERATOR` / `ZD_STRING_CRYPTO_CLI` | 默认本仓库内构建的 host 工具 |
| `ZD_STRING_CATALOG_MAPPING` | 可选；目录模式 JSON |
| `ZD_STRING_PROFILE` / `ZD_STRING_NONCE_MODE` | Debug 为 `debug` / `deterministic`；Release 为 `release` / `random` |
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
- `ZDStringProtectionInitializeEmbedded` 只从主可执行文件定位 `__DATA,__zdstring`，不会自动搜索 framework 或 dylib。
- Blob 最大 64 MiB，单条 UTF-8 字符串最大 1 MiB，最多 1,000,000 条记录。
- 原始 Manifest、映射 JSON 和构建 key 只应存在于构建环境，不应加入 Bundle 或公开 CI artifact。
- 该方案降低静态字符串提取便利性，不能抵御调试、Hook、运行时内存读取或客户端 key 提取。
- 为保持已有 Blob 和 ID 兼容，内部 magic `LMST` 与 `LMStringProtection/...` 派生域保留原始字节值；文件名、公开类型、函数、构建变量和工具均使用 `ZD` 前缀。
