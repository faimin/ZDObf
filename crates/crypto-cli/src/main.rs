use zd_string_crypto_cli::{build_manifest_blob, decode_key, decode_salt, resolve_nonce_mode};
use std::env;
use std::fs::{self, OpenOptions};
use std::io::{self, Read, Write};
#[cfg(unix)]
use std::os::unix::fs::OpenOptionsExt;

// 进程参数只描述构建模式，Runtime Key 始终从环境变量读取而不进入 argv。

const DEBUG_SALT: [u8; 32] = [0x5A; 32];

fn main() {
    if let Err(error) = run() {
        eprintln!("zdstring-crypto: {error}");
        std::process::exit(2);
    }
}

fn run() -> Result<(), String> {
    let arguments: Vec<String> = env::args().skip(1).collect();
    if arguments.first().map(String::as_str) != Some("encrypt") {
        return Err("usage: zdstring-crypto encrypt [options]".to_string());
    }
    let mut manifest_path = "-".to_string();
    let mut output_path = "-".to_string();
    let mut profile = "debug".to_string();
    let mut nonce_mode = None;
    let mut salt_b64 = None;
    let mut index = 1;
    while index < arguments.len() {
        let option = arguments[index].as_str();
        match option {
            "--manifest" | "--output" | "--profile" | "--nonce-mode" | "--build-salt-b64" => {
                index += 1;
                let value = arguments
                    .get(index)
                    .ok_or_else(|| format!("{option} requires a value"))?
                    .clone();
                match option {
                    "--manifest" => manifest_path = value,
                    "--output" => output_path = value,
                    "--profile" => profile = value,
                    "--nonce-mode" => nonce_mode = Some(value),
                    "--build-salt-b64" => salt_b64 = Some(value),
                    _ => unreachable!(),
                }
                index += 1;
            }
            unknown => return Err(format!("unknown argument: {unknown}")),
        }
    }

    let key_value = env::var("ZD_STRING_RUNTIME_KEY_B64")
        .map_err(|_| "ZD_STRING_RUNTIME_KEY_B64 is required")?;
    let key = decode_key(&key_value)?;
    let mode = resolve_nonce_mode(nonce_mode.as_deref(), &profile)?;
    if profile == "release"
        && mode == zd_string_crypto_core::NonceMode::Deterministic
        && salt_b64.is_none()
    {
        return Err("release deterministic mode requires --build-salt-b64".to_string());
    }
    let salt = match salt_b64 {
        Some(value) => decode_salt(&value)?,
        None if profile == "debug" => DEBUG_SALT,
        None => random_salt()?,
    };
    let manifest = read_input(&manifest_path)?;
    let blob = build_manifest_blob(&manifest, &key, &salt, mode)?;
    write_output(&output_path, &blob)
}

fn read_input(path: &str) -> Result<Vec<u8>, String> {
    if path == "-" {
        let mut input = Vec::new();
        io::stdin()
            .read_to_end(&mut input)
            .map_err(|error| error.to_string())?;
        Ok(input)
    } else {
        fs::read(path).map_err(|error| format!("read manifest: {error}"))
    }
}

fn write_output(path: &str, bytes: &[u8]) -> Result<(), String> {
    if path == "-" {
        io::stdout()
            .write_all(bytes)
            .map_err(|error| error.to_string())?;
        io::stdout().flush().map_err(|error| error.to_string())?;
        return Ok(());
    }
    let directory = std::path::Path::new(path)
        .parent()
        .ok_or("output path has no parent")?;
    let temporary = directory.join(format!(
        ".{}.{}.tmp",
        std::path::Path::new(path)
            .file_name()
            .and_then(|value| value.to_str())
            .unwrap_or("zdstring"),
        std::process::id()
    ));
    // 先写同目录临时文件并同步，再原子替换，避免构建中断留下半成品。
    let mut options = OpenOptions::new();
    options.create_new(true).write(true);
    #[cfg(unix)]
    options.mode(0o600);
    let result = (|| {
        let mut file = options
            .open(&temporary)
            .map_err(|error| format!("write temporary blob: {error}"))?;
        file.write_all(bytes)
            .map_err(|error| format!("write temporary blob: {error}"))?;
        file.sync_all()
            .map_err(|error| format!("sync temporary blob: {error}"))?;
        drop(file);
        fs::rename(&temporary, path).map_err(|error| format!("atomically replace blob: {error}"))
    })();
    if result.is_err() {
        let _ = fs::remove_file(&temporary);
    }
    result
}

fn random_salt() -> Result<[u8; 32], String> {
    let mut salt = [0u8; 32];
    getrandom::getrandom(&mut salt)
        .map_err(|error| format!("random source unavailable: {error}"))?;
    Ok(salt)
}
