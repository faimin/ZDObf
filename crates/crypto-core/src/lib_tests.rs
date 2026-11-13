#[cfg(test)]
mod tests {
    // 固定测试向量覆盖 UTF-8、NUL、篡改和两种 nonce 行为。
    use crate::{
        NonceMode, RuntimeError, StringEntry, build_blob, catalog_string_id, decrypt_by_id,
        parse_blob, string_id,
    };

    const KEY: [u8; 32] = [0x11; 32];
    const SALT: [u8; 32] = [0x22; 32];
    const APP_NAMESPACE: &str = "com.example.zdstring.test";

    #[test]
    fn deterministic_build_salt_commits_to_all_sorted_records() {
        // 相同输入保持可复现；其他记录和显式 ID 的内容变化必须更换加密材料。
        let original = vec![StringEntry::with_id("unchanged", 1)];
        let first = build_blob(
            &KEY,
            APP_NAMESPACE.as_bytes(),
            &SALT,
            &original,
            NonceMode::Deterministic,
        )
        .unwrap();
        let changed_sets = [
            vec![
                StringEntry::with_id("unchanged", 1),
                StringEntry::with_id("new", 2),
            ],
            vec![StringEntry::with_id("changed", 1)],
        ];
        for entries in changed_sets {
            let changed = build_blob(
                &KEY,
                APP_NAMESPACE.as_bytes(),
                &SALT,
                &entries,
                NonceMode::Deterministic,
            )
            .unwrap();
            assert_ne!(&first[12..44], &changed[12..44]);
            let first_parsed = parse_blob(&first).unwrap();
            let changed_parsed = parse_blob(&changed).unwrap();
            let first_offset = first_parsed.records()[0].record_offset as usize;
            let changed_offset = changed_parsed.records()[0].record_offset as usize;
            assert_ne!(
                &first[first_offset..first_offset + 24],
                &changed[changed_offset..changed_offset + 24]
            );
        }
        let forward = vec![
            StringEntry::with_id("one", 1),
            StringEntry::with_id("two", 2),
        ];
        let reverse = vec![forward[1].clone(), forward[0].clone(), forward[0].clone()];
        assert_eq!(
            build_blob(
                &KEY,
                APP_NAMESPACE.as_bytes(),
                &SALT,
                &forward,
                NonceMode::Deterministic
            )
            .unwrap(),
            build_blob(
                &KEY,
                APP_NAMESPACE.as_bytes(),
                &SALT,
                &reverse,
                NonceMode::Deterministic
            )
            .unwrap()
        );
    }

    #[test]
    fn empty_catalog_cannot_bypass_blob_authentication() {
        // 没有任何 AEAD 记录时无法验证 key，因此生成端与解析端都拒绝空目录。
        assert_eq!(
            build_blob(
                &KEY,
                APP_NAMESPACE.as_bytes(),
                &SALT,
                &[],
                NonceMode::Deterministic
            ),
            Err(RuntimeError::EmptyCatalog)
        );
        let total = crate::HEADER_LEN + APP_NAMESPACE.len();
        let mut empty = crate::encode_header(&SALT, APP_NAMESPACE.len(), 0, total, total, total, 0);
        empty.extend_from_slice(APP_NAMESPACE.as_bytes());
        assert!(matches!(
            parse_blob(&empty),
            Err(RuntimeError::MalformedBlob)
        ));
    }

    #[test]
    fn deterministic_blob_round_trips_unicode_and_embedded_nul() {
        let entries = vec![
            StringEntry::new("hello"),
            StringEntry::from_bytes("e\u{301}".as_bytes().to_vec()),
            StringEntry::from_bytes(b"nul\0tail".to_vec()),
        ];

        let blob = build_blob(
            &KEY,
            APP_NAMESPACE.as_bytes(),
            &SALT,
            &entries,
            NonceMode::Deterministic,
        )
        .expect("blob should build");
        let parsed = parse_blob(&blob).expect("blob should parse");

        assert_eq!(
            decrypt_by_id(
                &parsed,
                &KEY,
                APP_NAMESPACE.as_bytes(),
                entries[0].id(&KEY, APP_NAMESPACE.as_bytes())
            )
            .unwrap(),
            b"hello"
        );
        assert_eq!(
            decrypt_by_id(
                &parsed,
                &KEY,
                APP_NAMESPACE.as_bytes(),
                entries[1].id(&KEY, APP_NAMESPACE.as_bytes())
            )
            .unwrap(),
            "e\u{301}".as_bytes()
        );
        assert_eq!(
            decrypt_by_id(
                &parsed,
                &KEY,
                APP_NAMESPACE.as_bytes(),
                entries[2].id(&KEY, APP_NAMESPACE.as_bytes())
            )
            .unwrap(),
            b"nul\0tail"
        );
    }

    #[test]
    fn deterministic_input_is_reproducible_and_deduplicated() {
        let entries = vec![StringEntry::new("repeat"), StringEntry::new("repeat")];
        let first = build_blob(
            &KEY,
            APP_NAMESPACE.as_bytes(),
            &SALT,
            &entries,
            NonceMode::Deterministic,
        )
        .unwrap();
        let second = build_blob(
            &KEY,
            APP_NAMESPACE.as_bytes(),
            &SALT,
            &entries,
            NonceMode::Deterministic,
        )
        .unwrap();

        assert_eq!(first, second);
        assert_eq!(parse_blob(&first).unwrap().records().len(), 1);
    }

    #[test]
    fn random_nonce_changes_blob_but_round_trips() {
        let entries = vec![StringEntry::new("same")];
        let first = build_blob(
            &KEY,
            APP_NAMESPACE.as_bytes(),
            &SALT,
            &entries,
            NonceMode::Random,
        )
        .unwrap();
        let second = build_blob(
            &KEY,
            APP_NAMESPACE.as_bytes(),
            &SALT,
            &entries,
            NonceMode::Random,
        )
        .unwrap();

        assert_ne!(first, second);
        let parsed = parse_blob(&first).unwrap();
        let id = entries[0].id(&KEY, APP_NAMESPACE.as_bytes());
        assert_eq!(
            decrypt_by_id(&parsed, &KEY, APP_NAMESPACE.as_bytes(), id).unwrap(),
            b"same"
        );
    }

    #[test]
    fn empty_string_is_a_valid_record() {
        let entries = vec![StringEntry::new("")];
        let blob = build_blob(
            &KEY,
            APP_NAMESPACE.as_bytes(),
            &SALT,
            &entries,
            NonceMode::Deterministic,
        )
        .unwrap();
        let parsed = parse_blob(&blob).unwrap();
        assert_eq!(
            decrypt_by_id(
                &parsed,
                &KEY,
                APP_NAMESPACE.as_bytes(),
                entries[0].id(&KEY, APP_NAMESPACE.as_bytes())
            )
            .unwrap(),
            b""
        );
    }

    #[test]
    fn tampering_and_unknown_ids_fail_closed() {
        let entries = vec![StringEntry::new("protected")];
        let blob = build_blob(
            &KEY,
            APP_NAMESPACE.as_bytes(),
            &SALT,
            &entries,
            NonceMode::Deterministic,
        )
        .unwrap();
        let parsed = parse_blob(&blob).unwrap();
        assert_eq!(
            decrypt_by_id(&parsed, &KEY, APP_NAMESPACE.as_bytes(), 7),
            Err(RuntimeError::UnknownId)
        );

        let mut tampered = blob;
        *tampered.last_mut().unwrap() ^= 1;
        let parsed = parse_blob(&tampered).unwrap();
        let id = entries[0].id(&KEY, APP_NAMESPACE.as_bytes());
        assert!(matches!(
            decrypt_by_id(&parsed, &KEY, APP_NAMESPACE.as_bytes(), id),
            Err(RuntimeError::AuthenticationFailed)
        ));
    }

    #[test]
    fn catalog_entries_keep_query_id_and_change_blob_per_app() {
        // 兼容目录的查询 ID 固定，App namespace 仍必须让同一条路径生成不同密文 Blob。
        let path = "/api/thanos/im/token/get";
        let id = catalog_string_id(path.as_bytes());
        let entry = StringEntry::with_id(path, id);
        let first_namespace = b"com.example.first";
        let second_namespace = b"com.example.second";
        let first = build_blob(
            &KEY,
            first_namespace,
            &SALT,
            std::slice::from_ref(&entry),
            NonceMode::Deterministic,
        )
        .unwrap();
        let second = build_blob(
            &KEY,
            second_namespace,
            &SALT,
            std::slice::from_ref(&entry),
            NonceMode::Deterministic,
        )
        .unwrap();

        assert_ne!(first, second);
        assert_eq!(entry.id(&KEY, first_namespace), id);
        assert_eq!(entry.id(&KEY, second_namespace), id);
        let first_parsed = parse_blob(&first).unwrap();
        let second_parsed = parse_blob(&second).unwrap();
        assert_eq!(
            decrypt_by_id(&first_parsed, &KEY, first_namespace, id).unwrap(),
            path.as_bytes()
        );
        assert_eq!(
            decrypt_by_id(&second_parsed, &KEY, second_namespace, id).unwrap(),
            path.as_bytes()
        );
    }
    #[test]
    fn string_ids_match_known_answers() {
        // 固定向量由独立的 Python hmac/hashlib HKDF 实现计算；Zig 扫描器侧在 Tests/test_generator.py
        // 和 Generator 单元测试里校验同一组值，任何一侧的派生规则漂移都会让构建产物无法解密。
        assert_eq!(
            string_id(&KEY, b"com.example.scanner", b"secret"),
            0x26e8_6c4a_43c0_723d
        );
        assert_eq!(
            string_id(&KEY, b"com.example.scanner", b""),
            0x4604_befa_00d3_c591
        );
        assert_eq!(catalog_string_id(b"/v1/token"), 0x52a6_5564_87d8_12ea);
    }

    #[test]
    fn string_ids_depend_on_key_and_namespace() {
        // 没有 key 就算不出 ID，换 key 或 namespace 都会得到不同 ID。
        let base = string_id(&KEY, b"com.example.a", b"secret");
        assert_ne!(base, string_id(&[0x12; 32], b"com.example.a", b"secret"));
        assert_ne!(base, string_id(&KEY, b"com.example.b", b"secret"));
        assert_ne!(base, string_id(&KEY, b"com.example.a", b"secret2"));
    }

    #[test]
    fn malformed_blobs_are_rejected_without_panicking() {
        let entries = vec![StringEntry::new("alpha"), StringEntry::new("beta")];
        let blob = build_blob(
            &KEY,
            APP_NAMESPACE.as_bytes(),
            &SALT,
            &entries,
            NonceMode::Deterministic,
        )
        .unwrap();
        assert!(parse_blob(&blob).is_ok());

        // 任意长度的截断都必须是可恢复的错误。
        for length in 0..blob.len() {
            assert!(parse_blob(&blob[..length]).is_err(), "length {length}");
        }
        // magic、版本、算法、flags、保留字段逐项破坏。
        for (offset, value) in [(0usize, 0xff), (4, 0xff), (6, 0xff), (9, 0x01), (46, 0x01)] {
            let mut broken = blob.clone();
            broken[offset] ^= value;
            assert_eq!(
                parse_blob(&broken).err(),
                Some(RuntimeError::MalformedBlob),
                "offset {offset}"
            );
        }
        // 额外尾部字节与 total_length 不一致。
        let mut extended = blob.clone();
        extended.push(0);
        assert!(parse_blob(&extended).is_err());
        // 单字节翻转遍历：解析要么失败，要么成功后解密不 panic。
        for position in 0..blob.len() {
            let mut mutated = blob.clone();
            mutated[position] ^= 0x80;
            if let Ok(parsed) = parse_blob(&mutated) {
                let _ = decrypt_by_id(
                    &parsed,
                    &KEY,
                    APP_NAMESPACE.as_bytes(),
                    entries[0].id(&KEY, APP_NAMESPACE.as_bytes()),
                );
            }
        }
    }
}
