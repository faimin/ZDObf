# ZDObf 技术方案

## 1. 文档定位

本文是 `ZDObf` 当前实现的技术方案与接入契约，以代码和脚本的实际行为为准。

- 组件目录：`ZDObf/`
- 首次交付：Rust Runtime、加密核心、Rust CLI、Zig Generator、Apple Wrapper、XCFramework 构建。
- 当前交付：Mach-O section 注入、受限字面量扫描、Xcode 编排脚本、CocoaPods 规格、Swift Package Manager 包和 CI 验收脚本。
- 独立性：不依赖原业务仓库或旧字符串混淆组件。

本文明确区分已实现能力与后续演进，避免把设计目标误认为当前功能。

---

## 2. 目标与边界

开发者在原始源码中使用受限调用：

### Objective-C

```objc
NSString *url = ZDString(@"https://api.example.com/v1/user");
```

### Swift

```swift
let url = ZDString("https://api.example.com/v1/user")
```

构建期将调用替换为只包含稳定查询 ID 字节的内部解码表达式（以下字节仅为格式示意）：

```objc
NSString *url = ZDStringDecodeBytes((const unsigned char[]){0x82, 0x4a, 0x8f, 0xd7, 0x21, 0x79, 0x12, 0x02}, 8);
```

```swift
let url = ZDStringDecodeBytes([0x82, 0x4a, 0x8f, 0xd7, 0x21, 0x79, 0x12, 0x02])
```

这里的 8 字节数组是 `u64` 查询 ID 的小端表示，不是字符串密文。`ZDStringDecodeBytes` 先还原 ID，再查询已初始化的 Rust Runtime；XChaCha20-Poly1305 密文保存在独立的 LMST Blob 中，最终嵌入 Mach-O section。该实现依赖 Blob 和相同的运行时 key，不能只凭源码中的字节数组独立解密字符串。业务开发者不需要编写或维护内部表达式。

最终 App 的数据流：

```text
原始 Swift / Objective-C 源码
        |
        | Zig scanner
        v
Derived Sources + JSON Manifests
        |
        | merge-manifests + Rust crypto CLI
        v
加密 LMST Blob
        |
        | 汇编 .incbin __DATA,__zdstring (no_dead_strip)
        v
relocatable Mach-O object
        |
        | App 最终链接
        v
App Mach-O 的 __DATA,__zdstring
        |
        | Objective-C bootstrap 定位 section
        v
Rust Runtime 按 ID 解密
        |
        v
NSString / String
```

### 2.1 已满足的目标

1. Rust Runtime 不包含业务字符串，也不读取 App Bundle、Foundation 或 UIKit。
2. App 字符串改变只会重新扫描、生成 Blob 并链接 App，不需要重新构建 Rust XCFramework。
3. Blob 不作为独立资源复制到 App Bundle；目标位置是 `__DATA,__zdstring`。
4. 支持 Objective-C 和 Swift 的 ID 查询 API。
5. Blob、密钥长度、UTF-8、记录边界、认证标签和未知 ID 均 fail-closed。
6. Debug/Release 与随机/确定性 nonce 均可由构建参数控制。
7. 可在最终 Mach-O 上检查 section 存在和指定明文是否泄露。

### 2.2 安全边界

该方案旨在抑制 `strings`、`__cstring` 搜索、独立资源文件搜索和静态逆向中的直接明文提取。它不保证对拥有进程控制权、可附加调试器或 hook 解密 API 的攻击者保密；字符串在正常业务使用时仍会短暂以明文出现在进程内存中。

构建密钥和运行时初始化密钥均不能提交到 Git、Podspec、XCFramework、Build Setting 明文或日志。当前组件不负责从业务安全系统取得运行时密钥，App 必须在启动时以安全的业务方式注入该 32-byte key。

---

## 3. 组件与职责

```text
ZDObf/
├── crates/
│   ├── crypto-core/          共享 Blob、ID、HKDF、AEAD 实现
│   ├── crypto-cli/           host 构建期加密 CLI
│   └── runtime/              静态 Rust Runtime 与 C ABI
├── Generator/                Zig 编排器、扫描器和 Manifest 合并器
├── Apple/
│   ├── ObjectiveC/           section bootstrap 与 ObjC Wrapper
│   └── Swift/                Swift Wrapper
├── Package.swift              Swift Package Manager manifest
├── dist/ZDObfRuntime.xcframework  本地构建或下载的 Runtime（不入库）
├── scripts/                  XCFramework、Xcode、section、CI 脚本
└── ZDObf.podspec
```

### 3.1 Rust `crypto-core`

`crates/crypto-core` 是唯一的密码学和 Blob 格式来源，Generator 与 Runtime 不重复实现这些规则。它负责：

- `LMST` v1 Blob 的创建和严格解析。
- 由构建 key 经 HKDF-SHA256 派生的稳定 ID（目录模式为 SHA-256 无密钥 ID）。
- HKDF-SHA256 派生每条记录的 32-byte key。
- XChaCha20-Poly1305 加密、解密与 AAD 认证。
- 确定性或随机 24-byte nonce。
- ID 排序、相同明文去重和不同明文的 ID 碰撞拒绝。

### 3.2 Rust Runtime

`crates/runtime` 对外导出稳定 C ABI：

```c
uint32_t zd_string_runtime_init(
    const uint8_t *blob, size_t blob_length,
    const uint8_t *key, size_t key_length
);
uint32_t zd_string_with_utf8(uint64_t id, ZDStringUseCallback callback, void *context);
ZDStringResult zd_string_get(uint64_t id);
void zd_string_result_free(ZDStringResult *result);
```

Runtime 使用进程级 `OnceLock`：

- 首次初始化解析并复制 Blob，逐条解密认证并校验 UTF-8 后才提交单例；认证过程的临时明文逐条清理，调用者可随后释放输入 Blob。
- 32-byte key 被复制到 `Zeroizing<[u8; 32]>`。
- 同一进程只能成功初始化一次；第二次初始化返回 `ZD_STRING_ERROR_ALREADY_INITIALIZED`，不支持重新加载或切换 key。
- 错误 key、篡改或无效 UTF-8 不会占用单例，可用正确输入重试；无记录的空目录因无法验证 key 而被拒绝，空字符串记录仍合法。
- ID 查询在已排序索引中二分查找，按记录派生 key 并验证 AEAD 认证标签。
- `zd_string_with_utf8` 是首选接口：明文只在同步 callback 内有效，回调返回后 Runtime 的临时明文缓冲区会 zeroize。
- `zd_string_get` 为兼容 API，会分配明文；调用者必须以 `zd_string_result_free` 释放，函数会先 zeroize 再 dealloc。

错误码包括无效参数、未初始化、重复初始化、未知 ID、格式错误、认证失败、无效 UTF-8、分配失败和容量超限。所有 FFI 入口使用 panic guard，panic 不跨越 C ABI。

### 3.3 Zig Generator

`Generator/` 使用 Zig `0.17.1`，只做构建期编排，不复制 Rust 密码学实现：

- 默认命令：验证 Manifest 后以 stdin/stdout 直接调用 `zdstring-crypto encrypt`。
- `scan`：扫描一个 Swift 或 Objective-C 源文件，输出改写源码和该文件的 Manifest。
- 扫描器会跳过 Swift raw / multiline / regex 字面量、嵌套块注释、ObjC 字符常量和 Objective-C++ raw 字符串；无法安全判断的无定界符正则会终止构建。
- `merge-manifests`：合并多个 Manifest，强制要求相同 `app_namespace`。
- 文件输出均采用同目录临时文件后原子替换。

### 3.4 Apple Wrapper

Objective-C Wrapper 提供：

```objc
BOOL ZDObfInitialize(NSData *blob, NSData *key, NSError **error);
BOOL ZDObfInitializeEmbedded(NSData *key, NSError **error);
NSString * _Nullable ZDStringDecodeBytes(const unsigned char *bytes, size_t length);
```

可选的内嵌 key 模式（`ZD_STRING_EMBED_KEY=1`）：`zdstring-gen embed-key` 读取同一个 `ZD_STRING_RUNTIME_KEY_B64`，写出 72 字节载荷 `"ZDKY" | version u16 LE=1 | flags u16 LE=0 | mask[32] | masked[32]`，其中 `mask = HKDF-SHA256(salt="LMStringProtection/key-mask/v1", ikm=key).expand("mask", 32)`，`masked = key xor mask`。`embed_macho_section.sh` 把它放进 `__DATA,__zdkey`（`no_dead_strip`）。Wrapper 在找到 `__zdstring` 的同一镜像里读取 `__zdkey`，还原 key 后调用 Runtime 并清零。这只是避免 key 以明文字节出现的混淆，不提供额外安全性；默认关闭。

`ZDObfInitializeEmbedded` 通过 `getsectiondata(_dyld_get_image_header(0), "__DATA", "__zdstring", ...)` 找到最终可执行文件的密文 section，再将 pointer、length 和 key 传给 Rust。定位 Mach-O 的平台代码停留在 Apple Wrapper；Rust 仍是纯运行时库。

Swift Wrapper 提供：

```swift
try ZDObf.initialize(blob: blob, key: key)
try ZDObf.initializeEmbedded(key: key)
let value = try ZDObf.string(for: id)
let optionalValue = ZDStringDecodeBytes([0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08])
```

Swift 通过同步 callback 复制为 `String`；全局 `ZDStringDecodeBytes` 返回 `String?`，与 Objective-C 的 `nil` 失败语义一致。

---

## 4. 字符串 ID 与扫描契约

### 4.1 稳定 ID

扫描得到的每条字符串，其 ID 由构建 key 派生：`HKDF-SHA256(salt = "LMStringProtection/id/v2", ikm = runtime key)`，以下列 `info` 展开 8 bytes 并按 little-endian 解释为 `u64`：

```text
namespace_length 的 u16 little-endian 编码
+ app_namespace UTF-8 bytes
+ 字符串 UTF-8 bytes
```

因此相同字符串在不同 namespace 或不同 key 下具有不同 ID；每个 App 应将 namespace 设置为稳定且独有的标识，通常是 `$(PRODUCT_BUNDLE_IDENTIFIER)`。ID 同时出现在 Blob index 和调用点字节中，由于派生需要 key，攻击者无法在不持有 key 的情况下离线验证对某个 URL 或口令的猜测。`zdstring-gen scan` 与 crypto CLI 都从 `ZD_STRING_RUNTIME_KEY_B64` 读取 key，缺失或长度错误时扫描失败，不会退化为无密钥 ID。Rust（`string_id`）与 Zig（`string_id`）必须保持逐字节一致，两侧和 Python 测试共享同一组固定向量。

目录兼容模式的 ID 是 `SHA-256("LMStringProtection/catalog-id/v1" || 路径)` 的前 8 bytes，不含 key 也不含 namespace：访问器在 Pod 编译期固化 ID，此时没有 App key。该模式的 ID 因此可被离线验证，仅适合不敏感的路径类字符串。

Blob 构建时将记录按 ID 排序并去重。相同 ID 但不同明文会使构建失败，绝不静默选择其中之一。

### 4.2 `scan` 的当前支持范围

命令：

```sh
zdstring-gen scan \
  --input <source> \
  --output <rewritten-source> \
  --manifest <file-manifest.json> \
  --language swift|objc \
  --namespace <app-namespace>
```

当前只接受单行、单一字面量调用：

```swift
ZDString("literal")
```

```objc
ZDString(@"literal")
```

支持的转义仅为 `\\`, `\"`, `\n`, `\r`, `\t`, `\0`。ObjC 的多位八进制转义（如 `\012`）明确拒绝，不会误解为 NUL 加数字；Swift `\012` 仍表示 NUL 加 `12`。扫描器会跳过行注释、块注释（Swift 可嵌套）、Swift raw/multiline 字符串、普通字符串和 ObjC 字符常量，避免把示例文本改写；它不是完整语法分析器。Swift 插值表达式内的保护调用会显式失败，不能静默遗漏。

以下形式会导致 `UnsupportedLiteral` 并使构建失败：

```swift
ZDString("https://\(host)")
ZDString("first" + "second")
ZDString(
    "multiline"
)
```

```objc
ZDString([NSString stringWithFormat:@"%@", host])
ZDString(@"first" @"second")
```

调用名当前要求精确匹配 `ZDString(`；不支持空格、换行或其他 token 变体。改写后会生成内部 `ZDStringDecodeBytes(...)`，因此 Swift 和 Objective-C target 都必须链接相应 Wrapper。生成源码只保留 ID 的小端字节数组，不保留原始明文或注释。

### 4.3 Manifest

单文件 Manifest 格式为：

```json
{
  "version": 1,
  "app_namespace": "com.example.app",
  "strings": [
    {"text": "https://api.example.com/v1/user", "source": "/absolute/API.swift"}
  ]
}
```

Manifest 是派生构建输入，不得复制到 App Bundle 或提交包含敏感业务字符串的构建产物。`merge-manifests` 只合并相同 namespace 的 Manifest；最终 crypto core 负责去重。

---

## 5. 加密、Blob 与 nonce

### 5.1 加密构造

每条记录使用 XChaCha20-Poly1305：

- Master key：严格 32 bytes。
- Salt：输入严格 32 bytes，再与 namespace、有序去重后的完整目录绑定，生成写入 Blob header 的 32-byte 有效 salt。
- Record key：HKDF-SHA256，以 salt 为 HKDF salt，info 为 `"LMStringProtection/key/v1" + namespace + id_le`。
- Nonce：24 bytes。
- AAD：`"LMStringProtection/aad/v1" + header + index_entry`。

header 和索引都进入 AAD，因此攻击者修改版本、salt、namespace 长度、索引 ID、记录偏移或密文长度都会导致认证或格式校验失败。

有效 salt 的派生规则为 SHA-256：`"LMStringProtection/build-salt/v1" || input_salt || namespace_len_u16_le || namespace || count_u32_le || each(id_u64_le || plaintext_len_u32_le || plaintext)`。记录按 ID 排序并去重后参与派生，保证输入顺序和重复项不影响可复现性。任何记录内容、数量或 ID 变化都会更换有效 salt，从而避免 header/index 的 AAD 变化时复用确定性 key/nonce。Blob v1 字节布局不变，旧的非空 Blob 仍可读取。

### 5.2 Blob v1

Blob 最大 64 MiB，包含 1 至 1,000,000 条记录；单条 UTF-8 字符串最大 1 MiB，允许空字符串但不允许零记录目录。格式为：

```text
64-byte Header
namespace bytes
N x 20-byte sorted IndexEntry
N x (24-byte nonce + ciphertext + 16-byte tag)
```

Header 包含：

```text
magic "LMST"
format version = 1
algorithm id = 1
flags（bit 0 表示 random nonce）
32-byte salt
namespace length
record count
index offset
data offset
total length
```

每个 `IndexEntry` 包含 `id: u64`、`record_offset: u32`、`ciphertext_length: u32` 和保留字段。Runtime 对所有 offset、长度、排序、记录连续性、保留字段和 UTF-8 进行检查。

### 5.3 nonce 与构建 profile

`zdstring-crypto` 的行为：

| Profile | 未显式设置 nonce mode | 未显式设置 salt |
| --- | --- | --- |
| `debug` | `deterministic` | 固定 Debug salt |
| `release` | `random` | 系统随机 salt |

通过 `--nonce-mode deterministic|random` 或 Xcode 的 `ZD_STRING_NONCE_MODE` 覆盖默认值，用于测试随机 nonce 的运行时兼容性。

Release 若选择 deterministic，必须提供 `--build-salt-b64` 或 `ZD_STRING_BUILD_SALT_B64`；否则 CLI 明确失败。随机 nonce 失败时不会退回确定性模式。`ZD_STRING_RUNTIME_KEY_B64` 必须是解码后恰好 32 bytes 的标准 Base64，crypto CLI 只从环境读取它，不接受 argv 中的 key。

---

## 6. Mach-O 注入与运行时发现

### 6.1 section object

`scripts/embed_macho_section.sh` 将 Blob 转换为可参与最终链接的 relocatable object：

```sh
scripts/embed_macho_section.sh <strings.zdstr> <zdstring-section.o> [arch]
```

脚本根据 `ZD_STRING_SDK` 选择 Apple SDK，以显式 target/sysroot 编译临时 object。当前支持 `iphoneos`、`iphonesimulator`、`appletvos`、`appletvsimulator`、`watchos`、`watchsimulator`、`xros`、`xrsimulator` 和 `macosx`；Mac Catalyst 通过 `EFFECTIVE_PLATFORM_NAME=-maccatalyst` 使用 `ios-macabi` target：

```sh
clang -target <arch-apple-ios-version[-simulator]> -isysroot <sdk-path> -x assembler -c -o <output> <<'EOF'
.section __DATA,__zdstring,regular,no_dead_strip
.incbin "<blob>"
EOF
```

生成 object。section 标记 `S_ATTR_NO_DEAD_STRIP`，即使最终链接开启 `-dead_strip`（Xcode 默认）也保留。最终 object 必须进入 App 的链接输入；不能将 `.zdstr` 作为 Copy Bundle Resources。

最低版本默认跟随各平台设置：iOS 15、macOS 15、tvOS 15、watchOS 8 和 visionOS 1。架构参数支持带引号的空格分隔列表，各架构分别生成后由 `lipo` 合并。共享构建阶段若收到 `CURRENT_ARCH=undefined_arch`，会回退到完整 `ARCHS`，也可用 `ZD_STRING_ARCH` 显式覆盖。ObjC 公共头仅依赖系统类型，Rust ABI 头仅由 `.mm` 实现引入，兼容 Pod 符号链接、SPM binary target 和 framework 复制布局。

可使用以下命令检查：

```sh
otool -l MyApp | rg -A 5 '__zdstring'
```

### 6.2 初始化

App 在使用任意 `ZDString(...)` 生成字符串前，应只执行一次：

```objc
NSError *error = nil;
BOOL ok = ZDObfInitializeEmbedded(runtimeKey, &error);
```

或：

```swift
try ZDObf.initializeEmbedded(key: runtimeKey)
```

Blob section 缺失、内容为空、key 长度错误、格式错误或认证失败均返回失败；不提供明文 fallback。

---

## 7. Xcode 集成

### 7.1 一次性项目配置

`scripts/xcode_build_phase.sh` 必须作为 App target 的 Run Script Build Phase，并排在 Compile Sources 之前。脚本本身不修改 `.xcodeproj`，项目必须显式完成以下一次性配置：

1. 创建 source-map 文件，每行格式为 `原始源码绝对路径|生成源码绝对路径|swift 或 objc`。
2. 将 target 的 Compile Sources 从原始文件改为 source-map 中对应的生成文件路径。
3. 把 `ZD_STRING_SECTION_OBJECT` 指向的 `.o` 加入最终链接输入。
4. 为 target 设置 namespace，通常为 `$(PRODUCT_BUNDLE_IDENTIFIER)`。
5. 在 App 启动路径注入 runtime key 并调用 embedded 初始化 API。

若 Xcode 仍编译原始源码，源码字面量会进入目标文件，方案不满足“最终 Mach-O 无明文”的目标。

### 7.2 Build Phase

调用形式：

```sh
scripts/xcode_build_phase.sh <source-map>
```

脚本按 source-map 顺序执行：

```text
scan 每个源文件
    -> 生成改写源码与单文件 Manifest
merge-manifests
    -> 合并且校验 namespace
zdstring-gen
    -> 调用 Rust crypto CLI 生成 Blob
embed_macho_section.sh
    -> 生成最终链接用 .o
```

推荐 Build Settings：

```text
ZD_STRING_NAMESPACE = $(PRODUCT_BUNDLE_IDENTIFIER)
ZD_STRING_DERIVED_DIR = $(DERIVED_FILE_DIR)/ZDObf
ZD_STRING_SECTION_OBJECT = $(DERIVED_FILE_DIR)/ZDObf/zdstring-section.o
```

`ZD_STRING_RUNTIME_KEY_B64` 通过构建环境或 CI Secret 注入，不直接写进 Build Settings。Debug 默认使用 deterministic nonce，名称为 `Release` 的配置默认使用 random nonce；可用 `ZD_STRING_PROFILE` 和 `ZD_STRING_NONCE_MODE` 显式覆盖。只有 Release + deterministic 组合必须额外提供 Base64 解码后为 32 字节的 `ZD_STRING_BUILD_SALT_B64`。

可选变量：`ZD_STRING_GENERATOR`、`ZD_STRING_CRYPTO_CLI`、`ZD_STRING_PROFILE`、`ZD_STRING_SDK`、`ZD_STRING_ARCH`。脚本会以 `CONFIGURATION=Release` 自动选择 `profile=release` 和 random nonce，除非显式覆盖。

### 7.3 XCFramework、CocoaPods 与 SwiftPM

Rust Runtime 与 App Blob 分离。发布 Runtime 时执行：

```sh
scripts/build_xcframework.sh
```

它生成 iOS、iOS Simulator、tvOS、watchOS、visionOS、macOS 和 Mac Catalyst 的静态 `ZDObfRuntime.xcframework`。watchOS 真机切片 `watchos-arm64_arm64_32` 由 `aarch64-apple-watchos`（稳定版 Rust）与 `arm64_32-apple-watchos`（nightly + `-Zbuild-std=std,panic_unwind`，tier 3 目标）合并而成：64 位 arm64 的 watchOS 真机代码在 LLVM 中最低为 watchOS 26，声明的 watchOS 8 最低版本由 arm64_32 切片承担。构建脚本统一加 `--remap-path-prefix` 去掉构建机路径，并在输出前对每个切片逐个目标文件断言 `minos` 不高于声明值。`ZDObf.podspec` 使用 `ZDObfKit` 模块名，`Package.swift` 使用包名 `ZDObf`、Swift 模块名 `ZDObfKit` 和 Objective-C 模块名 `ZDObfKitObjC`，二者都通过 `Package.swift` 里固定的 GitHub Release 资产（URL + SHA-256）获取 Runtime，本地存在 `dist/ZDObfRuntime.xcframework` 时优先使用；`dist/` 不入库；Pod 安装、SwiftPM resolve、source scan 和每次 App 增量构建不调用 Cargo 来重编 Runtime。GitHub Release workflow（手动触发，`publish=true` 仅限 main）会构建同一目录，把 `Package.swift` 固定到本次 zip 并同步 podspec 版本，提交 `release: vX.Y.Z` 后在该提交上创建同名 tag 的 Release，并上传 zip 与 SHA-256 校验文件。

### 7.4 端到端接入示例

假设 App 和本仓库位于同一父目录：

```text
Workspace/
├── ZDObf/
└── MyApp/
    ├── MyApp.xcodeproj
    ├── Podfile
    └── App/Protected/
        ├── ProtectedAPI.swift
        └── ProtectedAPIObjC.m
```

先在 `ZDObf/` 中构建 host 工具和 Runtime：

```sh
cargo build --locked --release -p zd_string_crypto_cli
(cd Generator && zig build -Doptimize=ReleaseSafe)
./scripts/build_xcframework.sh
```

在 `MyApp/Podfile` 的 App target 中添加 `pod 'ZDObf', :path => '../ZDObf'`，运行 `pod install` 后打开 `.xcworkspace`。

Swift 原始业务文件 `App/Protected/ProtectedAPI.swift`：

```swift
import Foundation
import ZDObfKit

enum ProtectedAPI {
    static func userURL() -> URL? {
        guard let text = ZDString("https://api.example.com/v1/user") else { return nil }
        return URL(string: text)
    }
}
```

Objective-C 原始业务文件 `App/Protected/ProtectedAPIObjC.m`：

```objc
#import <ZDObfKit/ZDObf.h>

NSString * _Nullable ProtectedUserURL(void) {
    return ZDString(@"https://api.example.com/v1/user");
}
```

在 Compile Sources 前新增 Run Script，设置第 7.2 节中的三个 Build Settings，并在 Other Linker Flags 追加 `"$(ZD_STRING_SECTION_OBJECT)"`：

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
: "${ZD_STRING_RUNTIME_KEY_B64:?Inject the build key before compiling}"
"$library_dir/scripts/xcode_build_phase.sh" "$source_map"
```

source-map 每行只接受三个以 `|` 分隔的字段，路径必须与工程对应；不支持路径中包含 `|`。Objective-C++ 源码使用 `objc` 语言标记，并保留生成文件的 `.mm` 后缀。

Run Script 的输入和输出声明如下：

| Xcode 项 | 文件 |
| --- | --- |
| Input Files | `$(SRCROOT)/App/Protected/ProtectedAPI.swift` |
| Input Files | `$(SRCROOT)/App/Protected/ProtectedAPIObjC.m` |
| Output Files | `$(ZD_STRING_DERIVED_DIR)/Sources/ProtectedAPI.swift` |
| Output Files | `$(ZD_STRING_DERIVED_DIR)/Sources/ProtectedAPIObjC.m` |
| Output Files | `$(ZD_STRING_SECTION_OBJECT)` |

将两个原始文件移出 Compile Sources；为生成文件添加 `sourceTree = DERIVED_FILE_DIR` 引用，`path` 分别为 `ZDObf/Sources/ProtectedAPI.swift` 和 `ZDObf/Sources/ProtectedAPIObjC.m`，并将生成引用加入 Compile Sources。首次接入关闭 Based on dependency analysis；若启用脚本 sandbox，必须额外声明工具、脚本、Manifest 和 Blob 等所有读写路径，或先设置 `ENABLE_USER_SCRIPT_SANDBOXING = NO`。

在启动时由业务自己的密钥提供方取得与构建一致的 key，然后二选一初始化。Swift：

```swift
func initializeProtectedStrings(keyBase64: String) throws {
    guard let key = Data(base64Encoded: keyBase64), key.count == 32 else {
        throw ZDObfError.invalidArgument
    }
    try ZDObf.initializeEmbedded(key: key)
}
```

Objective-C：

```objc
BOOL InitializeProtectedStrings(NSData *runtimeKey, NSError **error) {
    return ZDObfInitializeEmbedded(runtimeKey, error);
}
```

Swift 启动函数所在文件需要导入 `Foundation` 和 `ZDObfKit`，Objective-C 文件导入 `<ZDObfKit/ZDObf.h>`。两条路径共享同一个 Runtime 单例，一个进程只选择其中一条成功初始化一次。初始化成功后才调用 `ProtectedAPI.userURL()` 或 `ProtectedUserURL()`；未初始化或查询失败时，生成的访问器返回 `nil`。Swift 可以直接用 `URLSession.shared.dataTask(with: url).resume()` 发起请求。

构建后的验收命令：

```sh
scripts/verify_macho_artifact.sh \
  --binary /absolute/path/to/Payload/MyApp.app/MyApp \
  --forbid 'https://api.example.com/v1/user'
```

该检查证明指定字符串未以直接明文形式出现在该二进制中，不能证明客户端 key 无法提取，也不能替代实际 App 初始化与请求回归。Manifest 是构建期明文中间文件，不能复制到 Bundle 或公开构建产物。

---

## 8. CI 与验收

### 8.1 必跑检查

```sh
cargo fmt --check
cargo test --locked --workspace
cargo clippy --locked --workspace --all-targets -- -D warnings
zig fmt --check build.zig src/main.zig
zig test src/main.zig
zig build -Doptimize=ReleaseSafe
scripts/build_xcframework.sh
```

在最终 IPA 解包后的 App 可执行文件上执行：

```sh
scripts/verify_macho_artifact.sh \
  --binary Payload/MyApp.app/MyApp \
  --forbid 'https://api.example.com/v1/user'
```

脚本会检查 `__zdstring` section 存在，并对每个 `--forbid` 值执行 `strings -a` 检查。每一个受保护的敏感字面量都应作为独立 `--forbid` 参数传入。

### 8.2 已覆盖的行为

- 确定性 Blob 可复现；随机 nonce Blob 不同且可解密。
- 目录增删和显式 ID 明文变更会更换有效 salt/nonce，排序和重复项不影响确定性输出。
- 篡改 Blob、错误 key、未知 ID、非法 UTF-8、错误长度和无效格式均失败关闭。
- 空字符串与内嵌 NUL 可处理。
- Scanner 改写 Swift 与 Objective-C 的受限字面量，并跳过注释中的示例文本。
- Apple 集成测试真实链接 device arm64、simulator arm64/x86_64，验证平台、dead-strip 后的 section、多架构 object 及 Pod/framework 公共头消费。
- Objective-C++ iOS Simulator 语法检查、Swift iOS Simulator typecheck、Rust XCFramework 构建和静态链接 smoke test 已验证。

---

## 9. 当前限制与后续演进

下列能力不是当前实现的一部分：

1. Scanner 尚未使用 Clang AST 或 SwiftSyntax，不能安全解析完整的 Swift/Objective-C 语法。
2. 保护调用参数不支持多行、空格变体、Objective-C 拼接字面量、多位八进制转义、Swift 插值、原始字符串和 Unicode 转义；外围 raw/multiline 字符串可安全跳过。
3. 不自动改写 `.xcodeproj`；source-map、Compile Sources 切换和 section object 链接是明确的一次性接入步骤。
4. Runtime 未实现明文缓存；每次 `ZDStringDecodeBytes(...)` 都解密，优先缩短明文驻留时间。
5. Runtime 为进程单例，测试或多容器场景不能在同一进程中切换 Blob/key。
6. CI 明文扫描只检查显式传入的 `--forbid` 值；它不是未知明文的通用检测器。
7. 不提供抵抗动态调试、内存抓取或 API hook 的承诺。

下一阶段应先以 SwiftSyntax 和 Clang tooling 替换当前轻量 scanner，再评估带容量上限、可显式清除的热点字符串缓存。任何扩展都必须保持以下不变式：Runtime 不包含业务字符串、不读取 Bundle；新字符串不触发 XCFramework 重建；最终编译器只看到 ID 调用而非原始字面量。
