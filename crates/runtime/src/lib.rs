use zd_string_crypto_core::{ParsedBlob, RuntimeError, decrypt_by_id, parse_blob};
use std::alloc::{Layout, alloc, dealloc};
use std::ffi::c_void;
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::slice;
use std::sync::OnceLock;
use zeroize::{Zeroize, Zeroizing};

// C ABI 只负责校验与生命周期管理，密码学和 Blob 解析全部复用共享核心。

pub const ZD_STRING_ERROR_OK: u32 = 0;
pub const ZD_STRING_ERROR_INVALID_ARGUMENT: u32 = 1;
pub const ZD_STRING_ERROR_ALREADY_INITIALIZED: u32 = 2;
pub const ZD_STRING_ERROR_NOT_INITIALIZED: u32 = 3;
pub const ZD_STRING_ERROR_INVALID_ID: u32 = 4;
pub const ZD_STRING_ERROR_MALFORMED_BLOB: u32 = 5;
pub const ZD_STRING_ERROR_AUTHENTICATION_FAILED: u32 = 6;
pub const ZD_STRING_ERROR_INVALID_UTF8: u32 = 7;
pub const ZD_STRING_ERROR_ALLOCATION_FAILED: u32 = 8;
pub const ZD_STRING_ERROR_LIMIT_EXCEEDED: u32 = 9;
pub const ZD_STRING_ERROR_INTERNAL: u32 = 100;

#[repr(C)]
pub struct ZDStringResult {
    pub bytes: *mut u8,
    pub length: usize,
    pub error: u32,
}

pub type ZDStringUseCallback = unsafe extern "C" fn(*const u8, usize, *mut c_void) -> u32;

struct RuntimeState {
    blob: ParsedBlob,
    key: Zeroizing<[u8; 32]>,
}

static RUNTIME: OnceLock<RuntimeState> = OnceLock::new();

#[unsafe(no_mangle)]
#[allow(clippy::not_unsafe_ptr_arg_deref)]
pub extern "C" fn zd_string_runtime_init(
    blob: *const u8,
    blob_length: usize,
    key: *const u8,
    key_length: usize,
) -> u32 {
    ffi_guard(|| {
        if blob.is_null()
            || blob_length == 0
            || (key.is_null() && key_length != 0)
            || key_length != 32
        {
            return ZD_STRING_ERROR_INVALID_ARGUMENT;
        }
        let blob_bytes = unsafe { slice::from_raw_parts(blob, blob_length) };
        let key_bytes = unsafe { slice::from_raw_parts(key, key_length) };
        let parsed = match parse_blob(blob_bytes) {
            Ok(value) => value,
            Err(error) => return map_error(error),
        };
        let mut owned_key = Zeroizing::new([0u8; 32]);
        owned_key.copy_from_slice(key_bytes);
        // 全量认证成功后才发布单例；错误 key 或尾部篡改不会阻止后续正确初始化。
        for record in parsed.records() {
            let plaintext =
                match decrypt_by_id(&parsed, &owned_key[..], parsed.namespace(), record.id) {
                    Ok(value) => Zeroizing::new(value),
                    Err(error) => return map_error(error),
                };
            if std::str::from_utf8(&plaintext).is_err() {
                return ZD_STRING_ERROR_INVALID_UTF8;
            }
        }
        if RUNTIME
            .set(RuntimeState {
                blob: parsed,
                key: owned_key,
            })
            .is_err()
        {
            return ZD_STRING_ERROR_ALREADY_INITIALIZED;
        }
        ZD_STRING_ERROR_OK
    })
}

#[unsafe(no_mangle)]
#[allow(clippy::not_unsafe_ptr_arg_deref)]
pub extern "C" fn zd_string_with_utf8(
    id: u64,
    callback: Option<ZDStringUseCallback>,
    context: *mut c_void,
) -> u32 {
    ffi_guard(|| {
        let callback = match callback {
            Some(value) => value,
            None => return ZD_STRING_ERROR_INVALID_ARGUMENT,
        };
        let state = match RUNTIME.get() {
            Some(value) => value,
            None => return ZD_STRING_ERROR_NOT_INITIALIZED,
        };
        let plaintext = match decrypt_by_id(&state.blob, &state.key[..], state.blob.namespace(), id)
        {
            Ok(value) => Zeroizing::new(value),
            Err(error) => return map_error(error),
        };
        unsafe { callback(plaintext.as_ptr(), plaintext.len(), context) }
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn zd_string_get(id: u64) -> ZDStringResult {
    let error = catch_unwind(AssertUnwindSafe(|| zd_string_get_inner(id)));
    match error {
        Ok(result) => result,
        Err(_) => ZDStringResult {
            bytes: std::ptr::null_mut(),
            length: 0,
            error: ZD_STRING_ERROR_INTERNAL,
        },
    }
}

fn zd_string_get_inner(id: u64) -> ZDStringResult {
    let state = match RUNTIME.get() {
        Some(value) => value,
        None => return empty_result(ZD_STRING_ERROR_NOT_INITIALIZED),
    };
    let plaintext = match decrypt_by_id(&state.blob, &state.key[..], state.blob.namespace(), id) {
        Ok(value) => Zeroizing::new(value),
        Err(error) => return empty_result(map_error(error)),
    };
    if plaintext.is_empty() {
        return ZDStringResult {
            bytes: std::ptr::null_mut(),
            length: 0,
            error: ZD_STRING_ERROR_OK,
        };
    }
    let layout = match Layout::array::<u8>(plaintext.len()) {
        Ok(value) => value,
        Err(_) => return empty_result(ZD_STRING_ERROR_ALLOCATION_FAILED),
    };
    let output = unsafe { alloc(layout) };
    if output.is_null() {
        return empty_result(ZD_STRING_ERROR_ALLOCATION_FAILED);
    }
    unsafe {
        output.copy_from_nonoverlapping(plaintext.as_ptr(), plaintext.len());
    }
    ZDStringResult {
        bytes: output,
        length: plaintext.len(),
        error: ZD_STRING_ERROR_OK,
    }
}

#[unsafe(no_mangle)]
#[allow(clippy::not_unsafe_ptr_arg_deref)]
pub extern "C" fn zd_string_result_free(result: *mut ZDStringResult) {
    let _ = catch_unwind(AssertUnwindSafe(|| {
        if result.is_null() {
            return;
        }
        let result = unsafe { &mut *result };
        if !result.bytes.is_null()
            && result.length != 0
            && let Ok(layout) = Layout::array::<u8>(result.length)
        {
            unsafe {
                let bytes = slice::from_raw_parts_mut(result.bytes, result.length);
                bytes.zeroize();
                dealloc(result.bytes, layout);
            }
        }
        result.bytes = std::ptr::null_mut();
        result.length = 0;
        result.error = ZD_STRING_ERROR_OK;
    }));
}

fn empty_result(error: u32) -> ZDStringResult {
    ZDStringResult {
        bytes: std::ptr::null_mut(),
        length: 0,
        error,
    }
}

fn ffi_guard(function: impl FnOnce() -> u32) -> u32 {
    catch_unwind(AssertUnwindSafe(function)).unwrap_or(ZD_STRING_ERROR_INTERNAL)
}

fn map_error(error: RuntimeError) -> u32 {
    match error {
        RuntimeError::InvalidKeyLength
        | RuntimeError::InvalidNamespace
        | RuntimeError::InvalidSaltLength => ZD_STRING_ERROR_INVALID_ARGUMENT,
        RuntimeError::InvalidStringLength
        | RuntimeError::TooManyRecords
        | RuntimeError::BlobTooLarge => ZD_STRING_ERROR_LIMIT_EXCEEDED,
        RuntimeError::InvalidUtf8 => ZD_STRING_ERROR_INVALID_UTF8,
        RuntimeError::UnknownId => ZD_STRING_ERROR_INVALID_ID,
        RuntimeError::AuthenticationFailed => ZD_STRING_ERROR_AUTHENTICATION_FAILED,
        RuntimeError::MalformedBlob | RuntimeError::RandomSourceUnavailable => {
            ZD_STRING_ERROR_MALFORMED_BLOB
        }
    }
}

#[cfg(test)]
mod tests {
    // Runtime 测试通过真实 C ABI 检查 callback 与显式释放路径。
    use super::*;
    use zd_string_crypto_core::{NonceMode, StringEntry, build_blob};
    use std::ffi::c_void;

    static KEY: [u8; 32] = [0x31; 32];
    static SALT: [u8; 32] = [0x41; 32];
    static NAMESPACE: &[u8] = b"com.example.runtime.test";

    unsafe extern "C" fn collect(bytes: *const u8, length: usize, context: *mut c_void) -> u32 {
        // 测试回调只在同步调用期间复制明文，验证 Runtime 自动清理边界。
        let output = unsafe { std::slice::from_raw_parts(bytes, length) };
        let target = unsafe { &mut *(context as *mut Vec<u8>) };
        target.extend_from_slice(output);
        ZD_STRING_ERROR_OK
    }

    #[test]
    fn c_abi_callback_returns_decrypted_utf8() {
        // 错误 key 和任意位置篡改必须在提交单例前失败，随后仍可用正确输入初始化。
        let entries = vec![
            StringEntry::new("runtime-value"),
            StringEntry::new("second-value"),
        ];
        let blob = build_blob(&KEY, NAMESPACE, &SALT, &entries, NonceMode::Deterministic).unwrap();
        let id = entries[0].id(NAMESPACE);
        let wrong_key = [0x32; 32];
        assert_eq!(
            zd_string_runtime_init(
                blob.as_ptr(),
                blob.len(),
                wrong_key.as_ptr(),
                wrong_key.len()
            ),
            ZD_STRING_ERROR_AUTHENTICATION_FAILED
        );
        assert_eq!(zd_string_get(id).error, ZD_STRING_ERROR_NOT_INITIALIZED);
        let parsed = parse_blob(&blob).unwrap();
        for record in parsed.records() {
            let mut tampered = blob.clone();
            tampered[record.record_offset as usize + 24] ^= 1;
            assert_eq!(
                zd_string_runtime_init(tampered.as_ptr(), tampered.len(), KEY.as_ptr(), KEY.len()),
                ZD_STRING_ERROR_AUTHENTICATION_FAILED
            );
        }
        assert_eq!(
            zd_string_runtime_init(blob.as_ptr(), blob.len(), KEY.as_ptr(), KEY.len()),
            ZD_STRING_ERROR_OK
        );
        let mut output = Vec::new();
        let error = zd_string_with_utf8(id, Some(collect), (&mut output as *mut Vec<u8>).cast());
        assert_eq!(error, ZD_STRING_ERROR_OK);
        assert_eq!(output, b"runtime-value");

        let mut result = zd_string_get(id);
        assert_eq!(result.error, ZD_STRING_ERROR_OK);
        let copied = unsafe { std::slice::from_raw_parts(result.bytes, result.length) };
        assert_eq!(copied, b"runtime-value");
        zd_string_result_free(&mut result);
        assert!(result.bytes.is_null());
    }
}
