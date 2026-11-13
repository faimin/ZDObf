use chacha20poly1305::{
    KeyInit, XChaCha20Poly1305, XNonce,
    aead::{Aead, Payload},
};

// 共享核心统一定义 Blob、ID、KDF 与 AEAD 字节规则，防止 Generator 与 Runtime 漂移。
use hkdf::Hkdf;
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;
use thiserror::Error;
use zeroize::Zeroizing;

// 协议标记与派生域保留既有字节值，使迁移前生成的 Blob 和稳定 ID 继续兼容。
pub const MAGIC: [u8; 4] = *b"LMST";
pub const FORMAT_VERSION: u16 = 1;
pub const ALGORITHM_ID: u16 = 1;
pub const HEADER_LEN: usize = 64;
pub const INDEX_ENTRY_LEN: usize = 20;
pub const NONCE_LEN: usize = 24;
pub const TAG_LEN: usize = 16;
pub const MAX_BLOB_LEN: usize = 64 * 1024 * 1024;
pub const MAX_RECORD_COUNT: usize = 1_000_000;
pub const MAX_STRING_LEN: usize = 1024 * 1024;
pub const MAX_NAMESPACE_LEN: usize = 256;

const FLAG_RANDOM_NONCE: u32 = 1;
// 扫描产生的 ID 由构建 key 经 HKDF 派生，没有 key 就无法离线验证对明文的猜测。
// 目录兼容 ID（CATALOG_ID_DOMAIN）在 Pod 编译期固化，无法携带 key，仍是无密钥哈希。
const ID_SALT: &[u8] = b"LMStringProtection/id/v2";
const CATALOG_ID_DOMAIN: &[u8] = b"LMStringProtection/catalog-id/v1";
const KEY_DOMAIN: &[u8] = b"LMStringProtection/key/v1";
const NONCE_DOMAIN: &[u8] = b"LMStringProtection/nonce/v1";
const AAD_DOMAIN: &[u8] = b"LMStringProtection/aad/v1";
// 将整个有序目录绑定到构建盐，避免目录变化时重用确定性 key/nonce。
const BUILD_SALT_DOMAIN: &[u8] = b"LMStringProtection/build-salt/v1";

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum NonceMode {
    Deterministic,
    Random,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct StringEntry {
    bytes: Vec<u8>,
    explicit_id: Option<u64>,
}

impl StringEntry {
    pub fn new(value: &str) -> Self {
        Self {
            bytes: value.as_bytes().to_vec(),
            explicit_id: None,
        }
    }

    pub fn from_bytes(bytes: Vec<u8>) -> Self {
        Self {
            bytes,
            explicit_id: None,
        }
    }

    pub fn with_id(value: &str, id: u64) -> Self {
        // 兼容目录在 Pod 编译期固化查询 ID，运行时仍由 Blob namespace 派生加密材料。
        Self {
            bytes: value.as_bytes().to_vec(),
            explicit_id: Some(id),
        }
    }

    pub fn bytes(&self) -> &[u8] {
        &self.bytes
    }

    pub fn id(&self, key: &[u8], namespace: &[u8]) -> u64 {
        self.explicit_id
            .unwrap_or_else(|| string_id(key, namespace, &self.bytes))
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct IndexEntry {
    pub id: u64,
    pub record_offset: u32,
    pub ciphertext_length: u32,
}

#[derive(Debug, Error, Eq, PartialEq)]
pub enum RuntimeError {
    #[error("invalid key length")]
    InvalidKeyLength,
    #[error("invalid namespace")]
    InvalidNamespace,
    #[error("invalid salt length")]
    InvalidSaltLength,
    #[error("invalid string length")]
    InvalidStringLength,
    #[error("invalid UTF-8")]
    InvalidUtf8,
    #[error("too many records")]
    TooManyRecords,
    #[error("blob is too large")]
    BlobTooLarge,
    #[error("malformed blob")]
    MalformedBlob,
    #[error("empty catalog: at least one string is required")]
    EmptyCatalog,
    #[error("string id collision between different strings")]
    IdCollision,
    #[error("unknown string id")]
    UnknownId,
    #[error("authentication failed")]
    AuthenticationFailed,
    #[error("random source unavailable")]
    RandomSourceUnavailable,
}

pub struct ParsedBlob {
    bytes: Vec<u8>,
    namespace_len: usize,
    records: Vec<IndexEntry>,
    salt: [u8; 32],
}

impl ParsedBlob {
    pub fn records(&self) -> &[IndexEntry] {
        &self.records
    }

    pub fn namespace(&self) -> &[u8] {
        &self.bytes[HEADER_LEN..HEADER_LEN + self.namespace_len]
    }

    fn header(&self) -> &[u8] {
        &self.bytes[..HEADER_LEN]
    }
}

pub fn string_id(key: &[u8], namespace: &[u8], bytes: &[u8]) -> u64 {
    // ID = HKDF-SHA256(salt = ID_SALT, ikm = key).expand(len(namespace) as u16 LE || namespace || 明文, 8 字节)。
    let hkdf = Hkdf::<Sha256>::new(Some(ID_SALT), key);
    let mut info = Vec::with_capacity(2 + namespace.len() + bytes.len());
    info.extend_from_slice(&(namespace.len() as u16).to_le_bytes());
    info.extend_from_slice(namespace);
    info.extend_from_slice(bytes);
    let mut output = [0u8; 8];
    hkdf.expand(&info, &mut output)
        .expect("8 bytes is a valid HKDF-SHA256 output length");
    u64::from_le_bytes(output)
}

pub fn catalog_string_id(bytes: &[u8]) -> u64 {
    // 目录兼容层的 ID 不含 App namespace，保证静态访问器可查询任意 App 专属 Blob。
    let mut hasher = Sha256::new();
    hasher.update(CATALOG_ID_DOMAIN);
    hasher.update(bytes);
    let digest = hasher.finalize();
    u64::from_le_bytes(digest[..8].try_into().expect("digest has eight bytes"))
}

pub fn build_blob(
    key: &[u8],
    namespace: &[u8],
    salt: &[u8],
    entries: &[StringEntry],
    nonce_mode: NonceMode,
) -> Result<Vec<u8>, RuntimeError> {
    validate_key(key)?;
    validate_namespace(namespace)?;
    if salt.len() != 32 {
        return Err(RuntimeError::InvalidSaltLength);
    }
    if entries.len() > MAX_RECORD_COUNT {
        return Err(RuntimeError::TooManyRecords);
    }

    // 按 ID 排序并去重，同时拒绝极低概率的不同字符串哈希碰撞。
    let mut unique = BTreeMap::<u64, Vec<u8>>::new();
    for entry in entries {
        if entry.bytes.len() > MAX_STRING_LEN {
            return Err(RuntimeError::InvalidStringLength);
        }
        std::str::from_utf8(&entry.bytes).map_err(|_| RuntimeError::InvalidUtf8)?;
        let id = entry.id(key, namespace);
        if let Some(previous) = unique.get(&id) {
            if previous != &entry.bytes {
                return Err(RuntimeError::IdCollision);
            }
        } else {
            unique.insert(id, entry.bytes.clone());
        }
    }

    // 空目录没有 AEAD 标签可验证；空字符串记录仍然合法且带有认证标签。
    if unique.is_empty() {
        return Err(RuntimeError::EmptyCatalog);
    }
    let mut salt_hasher = Sha256::new();
    salt_hasher.update(BUILD_SALT_DOMAIN);
    salt_hasher.update(salt);
    salt_hasher.update((namespace.len() as u16).to_le_bytes());
    salt_hasher.update(namespace);
    salt_hasher.update((unique.len() as u32).to_le_bytes());
    for (id, bytes) in &unique {
        salt_hasher.update(id.to_le_bytes());
        salt_hasher.update((bytes.len() as u32).to_le_bytes());
        salt_hasher.update(bytes);
    }
    let build_salt: [u8; 32] = salt_hasher.finalize().into();
    let salt = &build_salt;

    let index_offset = HEADER_LEN
        .checked_add(namespace.len())
        .ok_or(RuntimeError::MalformedBlob)?;
    let data_offset = index_offset
        .checked_add(
            unique
                .len()
                .checked_mul(INDEX_ENTRY_LEN)
                .ok_or(RuntimeError::MalformedBlob)?,
        )
        .ok_or(RuntimeError::MalformedBlob)?;
    let mut records = Vec::with_capacity(unique.len());
    let mut next_offset = data_offset;
    for (id, bytes) in &unique {
        let ciphertext_length = bytes
            .len()
            .checked_add(TAG_LEN)
            .ok_or(RuntimeError::MalformedBlob)?;
        let record_size = NONCE_LEN
            .checked_add(ciphertext_length)
            .ok_or(RuntimeError::MalformedBlob)?;
        let record_offset = next_offset;
        next_offset = next_offset
            .checked_add(record_size)
            .ok_or(RuntimeError::MalformedBlob)?;
        records.push(IndexEntry {
            id: *id,
            record_offset: record_offset as u32,
            ciphertext_length: ciphertext_length as u32,
        });
    }
    let total_length = next_offset;
    if total_length > MAX_BLOB_LEN || total_length > u32::MAX as usize {
        return Err(RuntimeError::BlobTooLarge);
    }

    let flags = if nonce_mode == NonceMode::Random {
        FLAG_RANDOM_NONCE
    } else {
        0
    };
    let header = encode_header(
        salt,
        namespace.len(),
        records.len(),
        index_offset,
        data_offset,
        total_length,
        flags,
    );
    let mut blob = Vec::with_capacity(total_length);
    blob.extend_from_slice(&header);
    blob.extend_from_slice(namespace);
    for record in &records {
        blob.extend_from_slice(&encode_index_entry(*record));
    }

    for (record, bytes) in records.iter().zip(unique.values()) {
        let record_key = derive_record_key(key, salt, namespace, record.id)?;
        let nonce = make_nonce(key, salt, namespace, record.id, nonce_mode)?;
        let cipher = XChaCha20Poly1305::new_from_slice(&*record_key)
            .map_err(|_| RuntimeError::InvalidKeyLength)?;
        let aad = make_aad(&header, *record);
        let encrypted = cipher
            .encrypt(
                XNonce::from_slice(&nonce),
                Payload {
                    msg: bytes,
                    aad: &aad,
                },
            )
            .map_err(|_| RuntimeError::AuthenticationFailed)?;
        blob.extend_from_slice(&nonce);
        blob.extend_from_slice(&encrypted);
    }
    Ok(blob)
}

pub fn parse_blob(blob: &[u8]) -> Result<ParsedBlob, RuntimeError> {
    if blob.len() > MAX_BLOB_LEN {
        return Err(RuntimeError::BlobTooLarge);
    }
    if blob.len() < HEADER_LEN || blob[..4] != MAGIC {
        return Err(RuntimeError::MalformedBlob);
    }
    if read_u16(blob, 4)? != FORMAT_VERSION || read_u16(blob, 6)? != ALGORITHM_ID {
        return Err(RuntimeError::MalformedBlob);
    }
    let flags = read_u32(blob, 8)?;
    if flags & !FLAG_RANDOM_NONCE != 0 {
        return Err(RuntimeError::MalformedBlob);
    }
    if read_u16(blob, 46)? != 0 {
        return Err(RuntimeError::MalformedBlob);
    }
    let namespace_len = read_u16(blob, 44)? as usize;
    let record_count = read_u32(blob, 48)? as usize;
    // 初始化必须至少能验证一条记录，禁止结构合法但无认证标签的空 Blob。
    if namespace_len == 0
        || namespace_len > MAX_NAMESPACE_LEN
        || record_count == 0
        || record_count > MAX_RECORD_COUNT
    {
        return Err(RuntimeError::MalformedBlob);
    }
    let index_offset = read_u32(blob, 52)? as usize;
    let data_offset = read_u32(blob, 56)? as usize;
    let total_length = read_u32(blob, 60)? as usize;
    if total_length != blob.len()
        || index_offset != HEADER_LEN + namespace_len
        || data_offset != index_offset + record_count * INDEX_ENTRY_LEN
        || data_offset > total_length
    {
        return Err(RuntimeError::MalformedBlob);
    }
    let mut salt = [0u8; 32];
    salt.copy_from_slice(&blob[12..44]);
    let mut records = Vec::with_capacity(record_count);
    let mut previous_id = None;
    let mut previous_end = data_offset;
    for index in 0..record_count {
        let offset = index_offset + index * INDEX_ENTRY_LEN;
        let id = read_u64(blob, offset)?;
        let record_offset = read_u32(blob, offset + 8)?;
        let ciphertext_length = read_u32(blob, offset + 12)?;
        if read_u32(blob, offset + 16)? != 0 {
            return Err(RuntimeError::MalformedBlob);
        }
        if previous_id.is_some_and(|previous| id <= previous)
            || record_offset as usize != previous_end
            || ciphertext_length < TAG_LEN as u32
        {
            return Err(RuntimeError::MalformedBlob);
        }
        let record_end = (record_offset as usize)
            .checked_add(NONCE_LEN + ciphertext_length as usize)
            .ok_or(RuntimeError::MalformedBlob)?;
        if record_end > total_length {
            return Err(RuntimeError::MalformedBlob);
        }
        previous_id = Some(id);
        previous_end = record_end;
        records.push(IndexEntry {
            id,
            record_offset,
            ciphertext_length,
        });
    }
    if previous_end != total_length {
        return Err(RuntimeError::MalformedBlob);
    }
    Ok(ParsedBlob {
        bytes: blob.to_vec(),
        namespace_len,
        records,
        salt,
    })
}

pub fn decrypt_by_id(
    parsed: &ParsedBlob,
    key: &[u8],
    namespace: &[u8],
    id: u64,
) -> Result<Vec<u8>, RuntimeError> {
    validate_key(key)?;
    if parsed.namespace() != namespace {
        return Err(RuntimeError::InvalidNamespace);
    }
    let index = parsed
        .records
        .binary_search_by_key(&id, |record| record.id)
        .map_err(|_| RuntimeError::UnknownId)?;
    let record = parsed.records[index];
    let start = record.record_offset as usize;
    let nonce = &parsed.bytes[start..start + NONCE_LEN];
    let encrypted_start = start + NONCE_LEN;
    let encrypted_end = encrypted_start + record.ciphertext_length as usize;
    let record_key = derive_record_key(key, &parsed.salt, namespace, id)?;
    let cipher = XChaCha20Poly1305::new_from_slice(&*record_key)
        .map_err(|_| RuntimeError::InvalidKeyLength)?;
    let aad = make_aad(parsed.header(), record);
    cipher
        .decrypt(
            XNonce::from_slice(nonce),
            Payload {
                msg: &parsed.bytes[encrypted_start..encrypted_end],
                aad: &aad,
            },
        )
        .map_err(|_| RuntimeError::AuthenticationFailed)
}

fn validate_key(key: &[u8]) -> Result<(), RuntimeError> {
    if key.len() == 32 {
        Ok(())
    } else {
        Err(RuntimeError::InvalidKeyLength)
    }
}
fn validate_namespace(namespace: &[u8]) -> Result<(), RuntimeError> {
    if !namespace.is_empty() && namespace.len() <= MAX_NAMESPACE_LEN {
        Ok(())
    } else {
        Err(RuntimeError::InvalidNamespace)
    }
}

fn derive_record_key(
    key: &[u8],
    salt: &[u8],
    namespace: &[u8],
    id: u64,
) -> Result<Zeroizing<[u8; 32]>, RuntimeError> {
    let hkdf = Hkdf::<Sha256>::new(Some(salt), key);
    let mut info = Vec::with_capacity(KEY_DOMAIN.len() + namespace.len() + 8);
    info.extend_from_slice(KEY_DOMAIN);
    info.extend_from_slice(namespace);
    info.extend_from_slice(&id.to_le_bytes());
    let mut output = Zeroizing::new([0u8; 32]);
    hkdf.expand(&info, output.as_mut())
        .map_err(|_| RuntimeError::MalformedBlob)?;
    Ok(output)
}

fn make_nonce(
    key: &[u8],
    salt: &[u8],
    namespace: &[u8],
    id: u64,
    mode: NonceMode,
) -> Result<[u8; 24], RuntimeError> {
    if mode == NonceMode::Random {
        let mut nonce = [0u8; NONCE_LEN];
        getrandom::getrandom(&mut nonce).map_err(|_| RuntimeError::RandomSourceUnavailable)?;
        return Ok(nonce);
    }
    let hkdf = Hkdf::<Sha256>::new(Some(salt), key);
    let mut info = Vec::with_capacity(NONCE_DOMAIN.len() + namespace.len() + 8);
    info.extend_from_slice(NONCE_DOMAIN);
    info.extend_from_slice(namespace);
    info.extend_from_slice(&id.to_le_bytes());
    let mut nonce = [0u8; NONCE_LEN];
    hkdf.expand(&info, &mut nonce)
        .map_err(|_| RuntimeError::MalformedBlob)?;
    Ok(nonce)
}

fn make_aad(header: &[u8], record: IndexEntry) -> Vec<u8> {
    let mut aad = Vec::with_capacity(AAD_DOMAIN.len() + header.len() + INDEX_ENTRY_LEN);
    aad.extend_from_slice(AAD_DOMAIN);
    aad.extend_from_slice(header);
    aad.extend_from_slice(&encode_index_entry(record));
    aad
}

fn encode_header(
    salt: &[u8],
    namespace_len: usize,
    record_count: usize,
    index_offset: usize,
    data_offset: usize,
    total_length: usize,
    flags: u32,
) -> Vec<u8> {
    let mut output = Vec::with_capacity(HEADER_LEN);
    output.extend_from_slice(&MAGIC);
    output.extend_from_slice(&FORMAT_VERSION.to_le_bytes());
    output.extend_from_slice(&ALGORITHM_ID.to_le_bytes());
    output.extend_from_slice(&flags.to_le_bytes());
    output.extend_from_slice(salt);
    output.extend_from_slice(&(namespace_len as u16).to_le_bytes());
    output.extend_from_slice(&0u16.to_le_bytes());
    output.extend_from_slice(&(record_count as u32).to_le_bytes());
    output.extend_from_slice(&(index_offset as u32).to_le_bytes());
    output.extend_from_slice(&(data_offset as u32).to_le_bytes());
    output.extend_from_slice(&(total_length as u32).to_le_bytes());
    output
}

fn encode_index_entry(record: IndexEntry) -> Vec<u8> {
    let mut output = Vec::with_capacity(INDEX_ENTRY_LEN);
    output.extend_from_slice(&record.id.to_le_bytes());
    output.extend_from_slice(&record.record_offset.to_le_bytes());
    output.extend_from_slice(&record.ciphertext_length.to_le_bytes());
    output.extend_from_slice(&0u32.to_le_bytes());
    output
}

fn read_u16(bytes: &[u8], offset: usize) -> Result<u16, RuntimeError> {
    bytes
        .get(offset..offset + 2)
        .and_then(|value| value.try_into().ok())
        .map(u16::from_le_bytes)
        .ok_or(RuntimeError::MalformedBlob)
}
fn read_u32(bytes: &[u8], offset: usize) -> Result<u32, RuntimeError> {
    bytes
        .get(offset..offset + 4)
        .and_then(|value| value.try_into().ok())
        .map(u32::from_le_bytes)
        .ok_or(RuntimeError::MalformedBlob)
}
fn read_u64(bytes: &[u8], offset: usize) -> Result<u64, RuntimeError> {
    bytes
        .get(offset..offset + 8)
        .and_then(|value| value.try_into().ok())
        .map(u64::from_le_bytes)
        .ok_or(RuntimeError::MalformedBlob)
}

#[cfg(test)]
mod lib_tests;
