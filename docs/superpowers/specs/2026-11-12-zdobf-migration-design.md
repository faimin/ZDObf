# ZDObf 迁移设计

## 目标

将 `Sopi` 中的字符串保护组件迁移为独立的 `ZDObf` 仓库，并把公开文件名、类名、函数名、Rust crate、构建变量和文档统一为 `ZD` 前缀。迁移后的仓库继续支持 Swift、Objective-C、Rust、Zig、CocoaPods 和 Mach-O section 嵌入。

## 范围

- 保留现有加密格式、Runtime ABI、源码扫描器、目录兼容模式和 Xcode Build Phase。
- 将 `LMStringProtection`、`LMStringID`、`lm_string_*`、`LM_STRING_*` 等公开标识迁移为对应的 `ZD` 命名。
- 更新 Podspec、脚本默认路径、测试 fixture、技术文档和 README。
- 不迁移原业务仓库中的 Podfile 接入，也不修改业务调用点。

## 方案

采用完整复制后重命名的方案。组件的 Rust crypto core、Runtime、Zig generator、Apple wrapper、构建脚本和测试共享同一套 Blob 协议；只抽取 Apple wrapper 会破坏构建闭环，也会增加外部依赖。迁移只改变命名空间和仓库布局，不改变加密算法或构建语义。

## 目录与接口

- `Apple/ObjectiveC/ZDStringProtection.{h,mm}`：Objective-C wrapper 和主可执行文件 section 初始化。
- `Apple/Swift/ZDStringProtection.swift`：Swift wrapper、错误类型和查询接口。
- `crates/crypto-core`、`crates/runtime`、`crates/crypto-cli`：加密协议、运行时和构建期 CLI。
- `Generator`、`scripts`、`Tools`：源码扫描、Manifest 合并、Blob 生成和 Mach-O 嵌入。
- `README.md`：独立仓库的安装、构建、接入、使用和验证说明。

## 验收

- `cargo test --locked --workspace` 通过。
- Zig generator 测试、Python 测试通过。
- 公开头文件不再依赖原仓库路径。
- 代码、脚本、Podspec、测试和文档中不残留旧的 `LM` 公开标识。
