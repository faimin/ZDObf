use base64::{Engine, engine::general_purpose::STANDARD};
use serde::Deserialize;
use zd_string_crypto_core::{NonceMode, RuntimeError, StringEntry, build_blob};

// Host CLI 将 JSON Manifest 限定为构建期输入，最终只输出加密 Blob。

#[derive(Debug)]
pub struct ParsedManifest {
    pub version: u32,
    pub app_namespace: Vec<u8>,
    pub entries: Vec<StringEntry>,
}

#[derive(Debug, Deserialize)]
struct ManifestFile {
    version: u32,
    app_namespace: String,
    strings: Vec<ManifestString>,
}

#[derive(Debug, Deserialize)]
struct ManifestString {
    text: String,
    #[allow(dead_code)]
    source: Option<String>,
    id: Option<String>,
}

pub fn parse_manifest(bytes: &[u8]) -> Result<ParsedManifest, String> {
    let file: ManifestFile =
        serde_json::from_slice(bytes).map_err(|error| format!("invalid manifest JSON: {error}"))?;
    if file.version != 1 {
        return Err("unsupported manifest version".to_string());
    }
    let namespace = file.app_namespace.into_bytes();
    if namespace.is_empty() || namespace.len() > 256 {
        return Err("invalid app namespace".to_string());
    }
    let entries = file
        .strings
        .into_iter()
        .map(|value| {
            // 目录兼容 Manifest 显式提供稳定 ID；普通扫描 Manifest 继续由 namespace 计算 ID。
            let entry_id = value.id.as_deref().map(parse_hex_id).transpose()?;
            Ok(match entry_id {
                Some(id) => StringEntry::with_id(&value.text, id),
                None => StringEntry::new(&value.text),
            })
        })
        .collect::<Result<Vec<_>, String>>()?;
    Ok(ParsedManifest {
        version: file.version,
        app_namespace: namespace,
        entries,
    })
}

fn parse_hex_id(value: &str) -> Result<u64, String> {
    // 固定 64 位十六进制格式避免 JSON number 精度损失和跨语言序列化歧义。
    let digits = value
        .strip_prefix("0x")
        .ok_or_else(|| "string id must start with 0x".to_string())?;
    if digits.len() != 16 || !digits.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        return Err("string id must contain exactly 16 hexadecimal digits".to_string());
    }
    u64::from_str_radix(digits, 16).map_err(|_| "invalid string id".to_string())
}

pub fn decode_key(value: &str) -> Result<[u8; 32], String> {
    let bytes = STANDARD
        .decode(value)
        .map_err(|error| format!("invalid key Base64: {error}"))?;
    bytes
        .try_into()
        .map_err(|_| "key must decode to exactly 32 bytes".to_string())
}

pub fn decode_salt(value: &str) -> Result<[u8; 32], String> {
    let bytes = STANDARD
        .decode(value)
        .map_err(|error| format!("invalid salt Base64: {error}"))?;
    bytes
        .try_into()
        .map_err(|_| "salt must decode to exactly 32 bytes".to_string())
}

pub fn resolve_nonce_mode(explicit: Option<&str>, profile: &str) -> Result<NonceMode, String> {
    if profile != "debug" && profile != "release" {
        return Err("profile must be debug or release".to_string());
    }
    match explicit.unwrap_or(if profile == "debug" {
        "deterministic"
    } else {
        "random"
    }) {
        "deterministic" => Ok(NonceMode::Deterministic),
        "random" => Ok(NonceMode::Random),
        _ => Err(
            "profile must be debug or release, nonce mode must be deterministic or random"
                .to_string(),
        ),
    }
}

pub fn build_manifest_blob(
    manifest: &[u8],
    key: &[u8],
    salt: &[u8],
    nonce_mode: NonceMode,
) -> Result<Vec<u8>, String> {
    let parsed = parse_manifest(manifest)?;
    build_blob(
        key,
        &parsed.app_namespace,
        salt,
        &parsed.entries,
        nonce_mode,
    )
    .map_err(|error: RuntimeError| error.to_string())
}

#[cfg(test)]
mod tests {
    // CLI 测试锁定 Manifest 和 profile 参数的构建期契约。
    use super::*;
    use zd_string_crypto_core::NonceMode;

    #[test]
    fn parses_manifest_and_retains_plaintext_entries_for_encryption() {
        let manifest = br#"{
            "version": 1,
            "app_namespace": "com.example.test",
            "strings": [
                {"text": "hello", "source": "A.swift:1"},
                {"text": "hello"}
            ]
        }"#;
        let parsed = parse_manifest(manifest).expect("manifest should parse");
        assert_eq!(parsed.version, 1);
        assert_eq!(parsed.entries.len(), 2);
        assert_eq!(
            resolve_nonce_mode(Some("random"), "debug").unwrap(),
            NonceMode::Random
        );
    }

    #[test]
    fn rejects_unknown_profile_and_nonce_mode() {
        assert!(resolve_nonce_mode(None, "preview").is_err());
        assert!(resolve_nonce_mode(Some("weak"), "debug").is_err());
    }

    #[test]
    fn parses_explicit_catalog_id() {
        // 目录 Manifest 的显式 ID 必须覆盖 namespace ID，供静态访问器跨 App 查询。
        let manifest = br#"{
            "version": 1,
            "app_namespace": "com.example.catalog",
            "strings": [{"text": "/v1/catalog", "id": "0x0123456789abcdef"}]
        }"#;

        let parsed = parse_manifest(manifest).expect("manifest should parse");
        assert_eq!(
            parsed.entries[0].id(&[0u8; 32], b"ignored-namespace"),
            0x0123_4567_89ab_cdef
        );
    }
}
