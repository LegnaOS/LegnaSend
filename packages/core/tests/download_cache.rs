#![cfg(feature = "crypto")]
use localsend::crypto::hash::sha256_hex;
use localsend::download_cache::{
    CacheError, CacheIdentity, DownloadCache, MAX_CHUNK_SIZE, MIN_CHUNK_SIZE,
};
use std::fs::{self, File, OpenOptions};
use std::io::{Seek, SeekFrom, Write};
use std::path::PathBuf;

struct Fixture(PathBuf);
impl Fixture {
    fn new() -> Self {
        let root =
            std::env::temp_dir().join(format!("legnasend .ls 碧绿-{}", uuid::Uuid::new_v4()));
        fs::create_dir(&root).unwrap();
        Self(root)
    }
    fn create(&self, name: &str) -> File {
        OpenOptions::new()
            .read(true)
            .write(true)
            .create_new(true)
            .open(self.0.join(name))
            .unwrap()
    }
    fn open(&self, name: &str) -> File {
        OpenOptions::new()
            .read(true)
            .write(true)
            .open(self.0.join(name))
            .unwrap()
    }
    fn bytes(&self, name: &str) -> Vec<u8> {
        fs::read(self.0.join(name)).unwrap()
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        fs::remove_dir_all(&self.0).unwrap();
    }
}

fn identity(size: u64) -> CacheIdentity {
    CacheIdentity {
        task_id: uuid::Uuid::new_v4().to_string(),
        source_id: "peer-fingerprint / workspace UUID".into(),
        resource_id: "opaque-resource-id".into(),
        version: "\"strong-resource-version\"".into(),
        file_name: " 目录/影片 100% # [ß]\\demo.mp4 ".into(),
        size,
        chunk_size: MIN_CHUNK_SIZE,
        created_unix_ms: 1790100000000,
        sha256: None,
    }
}
fn payload(index: u32, size: usize) -> Vec<u8> {
    (0..size)
        .map(|n| ((n + index as usize * 53) % 251) as u8)
        .collect()
}
fn header_end(bytes: &[u8]) -> usize {
    16 + u32::from_le_bytes(bytes[12..16].try_into().unwrap()) as usize + 32
}

#[test]
fn out_of_order_restart_and_export_restore_original_bytes_not_the_container() {
    let f = Fixture::new();
    let mut id = identity(u64::from(MIN_CHUNK_SIZE) * 2 + 37);
    let chunks = [
        payload(0, MIN_CHUNK_SIZE as usize),
        payload(1, MIN_CHUNK_SIZE as usize),
        payload(2, 37),
    ];
    let original = chunks.concat();
    id.sha256 = Some(sha256_hex(&original).to_uppercase());
    let mut cache = DownloadCache::create(f.create("video.mp4.ls"), id.clone()).unwrap();
    assert_eq!(cache.identity().file_name, id.file_name);
    cache.commit_chunk(2, &chunks[2]).unwrap();
    cache.commit_chunk(0, &chunks[0]).unwrap();
    assert_eq!(cache.committed_bytes(), u64::from(MIN_CHUNK_SIZE) + 37);
    assert_eq!(cache.missing_chunks().collect::<Vec<_>>(), [1]);
    drop(cache);
    let (mut cache, recovered) = DownloadCache::resume(f.open("video.mp4.ls"), &id).unwrap();
    assert_eq!(recovered.committed_chunks, 2);
    assert_eq!(recovered.discarded_tail_bytes, 0);
    assert_eq!(cache.missing_chunks().collect::<Vec<_>>(), [1]);
    cache.commit_chunk(1, &chunks[1]).unwrap();
    assert!(cache.is_complete());
    let mut output = f.create("video.mp4.staging");
    let receipt = cache.export(&mut output).unwrap();
    assert_eq!(receipt.bytes, id.size);
    assert_eq!(receipt.sha256, sha256_hex(&original));
    assert_eq!(f.bytes("video.mp4.staging"), original);
    drop(cache);
    assert!(f.bytes("video.mp4.ls").starts_with(b"LEGNALS\0"));
    assert!(f.bytes("video.mp4.ls").len() > original.len());
}

#[test]
fn exact_replay_is_idempotent_conflicting_duplicate_never_overwrites() {
    let f = Fixture::new();
    let id = identity(8);
    let mut cache = DownloadCache::create(f.create("a.ls"), id.clone()).unwrap();
    assert!(cache.commit_chunk(0, b"abcdefgh").unwrap());
    drop(cache);
    let before = f.bytes("a.ls");
    let (mut cache, _) = DownloadCache::resume(f.open("a.ls"), &id).unwrap();
    assert!(!cache.commit_chunk(0, b"abcdefgh").unwrap());
    assert!(matches!(
        cache.commit_chunk(0, b"Abcdefgh"),
        Err(CacheError::Chunk)
    ));
    assert!(matches!(
        cache.commit_chunk(1, b"abcdefgh"),
        Err(CacheError::Chunk)
    ));
    assert!(matches!(
        cache.commit_chunk(0, b"short"),
        Err(CacheError::Chunk)
    ));
    assert_eq!(cache.committed_bytes(), 8);
    drop(cache);
    assert_eq!(f.bytes("a.ls"), before);
}

#[test]
fn incomplete_cache_and_nonempty_outputs_are_never_published_or_overwritten() {
    let f = Fixture::new();
    let mut cache = DownloadCache::create(f.create("a.ls"), identity(8)).unwrap();
    let mut output = f.create("result");
    assert!(matches!(
        cache.export(&mut output),
        Err(CacheError::Incomplete)
    ));
    assert!(f.bytes("result").is_empty());
    cache.commit_chunk(0, b"abcdefgh").unwrap();
    output.write_all(b"user file").unwrap();
    assert!(matches!(
        cache.export(&mut output),
        Err(CacheError::NotEmpty)
    ));
    assert_eq!(f.bytes("result"), b"user file");
    // Failed export must release its temporary output lock.
    f.open("result").try_lock().unwrap();
}

#[test]
fn zero_length_source_has_no_fake_chunk_and_exports_empty_sha256() {
    let f = Fixture::new();
    let id = identity(0);
    drop(DownloadCache::create(f.create("empty.ls"), id.clone()).unwrap());
    let (mut cache, recovery) = DownloadCache::resume(f.open("empty.ls"), &id).unwrap();
    assert_eq!(recovery.committed_chunks, 0);
    assert!(cache.is_complete());
    assert_eq!(cache.missing_chunks().count(), 0);
    assert!(matches!(cache.commit_chunk(0, b""), Err(CacheError::Chunk)));
    let receipt = cache.export(&mut f.create("empty")).unwrap();
    assert_eq!(receipt.sha256, sha256_hex(b""));
    assert_eq!(receipt.bytes, 0);
}

#[test]
fn only_truncated_final_records_are_repaired_and_existing_progress_survives() {
    let f = Fixture::new();
    let id = identity(u64::from(MIN_CHUNK_SIZE) + 17);
    let mut cache = DownloadCache::create(f.create("base.ls"), id.clone()).unwrap();
    cache
        .commit_chunk(0, &payload(0, MIN_CHUNK_SIZE as usize))
        .unwrap();
    cache.commit_chunk(1, &payload(1, 17)).unwrap();
    drop(cache);
    let complete = f.bytes("base.ls");
    let checkpoint = complete[..header_end(&complete) + MIN_CHUNK_SIZE as usize + 56].to_vec();
    let second = &complete[checkpoint.len()..];
    // Every possible truncation in the final header, payload, hash and marker.
    for cut in 0..second.len() {
        let name = format!("cut-{cut}.ls");
        let mut file = f.create(&name);
        file.write_all(&checkpoint).unwrap();
        file.write_all(&second[..cut]).unwrap();
        drop(file);
        let (mut cache, recovery) = DownloadCache::resume(f.open(&name), &id).unwrap();
        assert_eq!(recovery.discarded_tail_bytes, cut as u64);
        assert_eq!(recovery.committed_bytes, u64::from(MIN_CHUNK_SIZE));
        assert_eq!(
            fs::metadata(f.0.join(&name)).unwrap().len(),
            checkpoint.len() as u64
        );
        assert_eq!(cache.missing_chunks().collect::<Vec<_>>(), [1]);
        cache.commit_chunk(1, &payload(1, 17)).unwrap();
        assert!(cache.is_complete());
        drop(cache);
        assert_eq!(f.bytes(&name), complete);
    }
}

#[test]
fn corrupt_full_records_are_retained_unchanged_for_diagnosis() {
    let f = Fixture::new();
    let id = identity(17);
    let mut cache = DownloadCache::create(f.create("base.ls"), id.clone()).unwrap();
    cache.commit_chunk(0, &payload(0, 17)).unwrap();
    drop(cache);
    let good = f.bytes("base.ls");
    let start = header_end(&good);
    for offset in [
        start,
        start + 8,
        start + 12,
        start + 16,
        start + 33,
        good.len() - 1,
    ] {
        let mut broken = good.clone();
        broken[offset] ^= 1;
        let name = format!("broken-{offset}.ls");
        f.create(&name).write_all(&broken).unwrap();
        assert!(matches!(
            DownloadCache::resume(f.open(&name), &id),
            Err(CacheError::Corrupt)
        ));
        assert_eq!(f.bytes(&name), broken);
    }
}

#[test]
fn duplicate_full_record_is_rejected_instead_of_inflating_progress() {
    let f = Fixture::new();
    let id = identity(17);
    let mut cache = DownloadCache::create(f.create("a.ls"), id.clone()).unwrap();
    cache.commit_chunk(0, &payload(0, 17)).unwrap();
    drop(cache);
    let mut bytes = f.bytes("a.ls");
    let record = bytes[header_end(&bytes)..].to_vec();
    bytes.extend(record);
    fs::write(f.0.join("a.ls"), &bytes).unwrap();
    assert!(matches!(
        DownloadCache::resume(f.open("a.ls"), &id),
        Err(CacheError::Corrupt)
    ));
    assert_eq!(f.bytes("a.ls"), bytes);
}

#[test]
fn another_task_or_source_version_never_reuses_or_truncates_data() {
    let f = Fixture::new();
    let id = identity(3);
    drop(DownloadCache::create(f.create("a.ls"), id.clone()).unwrap());
    OpenOptions::new()
        .append(true)
        .open(f.0.join("a.ls"))
        .unwrap()
        .write_all(b"partial")
        .unwrap();
    let before = f.bytes("a.ls");
    for field in 0..5 {
        let mut other = id.clone();
        match field {
            0 => other.task_id = uuid::Uuid::new_v4().to_string(),
            1 => other.source_id.push('x'),
            2 => other.resource_id.push('x'),
            3 => other.version.push('x'),
            _ => other.file_name.push('x'),
        }
        assert!(matches!(
            DownloadCache::resume(f.open("a.ls"), &other),
            Err(CacheError::IdentityMismatch)
        ));
        assert_eq!(f.bytes("a.ls"), before);
    }
}

#[test]
fn unknown_user_ls_bad_version_or_header_does_not_trigger_cleanup() {
    let f = Fixture::new();
    let id = identity(3);
    drop(DownloadCache::create(f.create("base.ls"), id.clone()).unwrap());
    let good = f.bytes("base.ls");
    let mut bad_version = good.clone();
    bad_version[8] = 99;
    let mut too_large = good.clone();
    too_large[12..16].copy_from_slice(&u32::MAX.to_le_bytes());
    let mut bad_hash = good.clone();
    *bad_hash.last_mut().unwrap() ^= 1;
    for (i, value) in [
        b"user-owned .ls document".to_vec(),
        good[..20].to_vec(),
        bad_version,
        too_large,
        bad_hash,
    ]
    .into_iter()
    .enumerate()
    {
        let name = format!("user-{i}.ls");
        f.create(&name).write_all(&value).unwrap();
        assert!(matches!(
            DownloadCache::resume(f.open(&name), &id),
            Err(CacheError::Format)
        ));
        assert_eq!(f.bytes(&name), value);
    }
}

#[test]
fn invalid_identity_is_rejected_before_writing_and_create_does_not_overwrite() {
    let f = Fixture::new();
    for case in 0..7 {
        let mut id = identity(1);
        match case {
            0 => id.task_id = "bad".into(),
            1 => id.source_id.clear(),
            2 => id.chunk_size = 0,
            3 => id.chunk_size = MAX_CHUNK_SIZE + 1,
            4 => id.size = u64::MAX,
            5 => id.sha256 = Some("not-a-checksum".into()),
            _ => id.version = "a\r\nb".into(),
        }
        let name = format!("invalid-{case}.ls");
        assert!(matches!(
            DownloadCache::create(f.create(&name), id),
            Err(CacheError::Identity)
        ));
        assert!(f.bytes(&name).is_empty());
    }
    f.create("existing.ls")
        .write_all(b"original user file")
        .unwrap();
    assert!(matches!(
        DownloadCache::create(f.open("existing.ls"), identity(1)),
        Err(CacheError::NotEmpty)
    ));
    assert_eq!(f.bytes("existing.ls"), b"original user file");
}

#[test]
fn cache_lock_excludes_other_handles_and_releases_on_drop() {
    let f = Fixture::new();
    let id = identity(3);
    let cache = DownloadCache::create(f.create("a.ls"), id.clone()).unwrap();
    assert!(matches!(
        DownloadCache::resume(f.open("a.ls"), &id),
        Err(CacheError::Busy)
    ));
    drop(cache);
    let (_, recovered) = DownloadCache::resume(f.open("a.ls"), &id).unwrap();
    assert_eq!(recovered.committed_bytes, 0);
}

#[test]
fn expected_checksum_mismatch_keeps_cache_and_never_returns_success_receipt() {
    let f = Fixture::new();
    let mut id = identity(3);
    id.sha256 = Some("0".repeat(64));
    let mut cache = DownloadCache::create(f.create("a.ls"), id.clone()).unwrap();
    cache.commit_chunk(0, b"abc").unwrap();
    drop(cache);
    let before = f.bytes("a.ls");
    let (mut cache, _) = DownloadCache::resume(f.open("a.ls"), &id).unwrap();
    assert!(matches!(
        cache.export(&mut f.create("stage")),
        Err(CacheError::Checksum)
    ));
    drop(cache);
    assert_eq!(f.bytes("a.ls"), before);
}

#[cfg(unix)]
#[test]
fn corruption_after_open_is_detected_again_during_export() {
    let f = Fixture::new();
    let id = identity(3);
    let mut cache = DownloadCache::create(f.create("a.ls"), id).unwrap();
    cache.commit_chunk(0, b"abc").unwrap();
    let offset = header_end(&f.bytes("a.ls")) + 16;
    // Simulate an external writer ignoring the advisory lock.
    let mut attacker = f.open("a.ls");
    attacker.seek(SeekFrom::Start(offset as u64)).unwrap();
    attacker.write_all(b"z").unwrap();
    assert!(matches!(
        cache.export(&mut f.create("stage")),
        Err(CacheError::Corrupt)
    ));
    assert!(f.0.join("a.ls").exists());
}

#[test]
fn four_producers_commit_to_one_bounded_writer_without_lost_chunks() {
    let f = Fixture::new();
    let id = identity(u64::from(MIN_CHUNK_SIZE) * 12);
    let cache = std::sync::Arc::new(std::sync::Mutex::new(
        DownloadCache::create(f.create("a.ls"), id.clone()).unwrap(),
    ));
    let handles: Vec<_> = (0..4)
        .map(|lane| {
            let cache = cache.clone();
            std::thread::spawn(move || {
                for index in (lane..12).step_by(4).rev() {
                    cache
                        .lock()
                        .unwrap()
                        .commit_chunk(index, &payload(index, MIN_CHUNK_SIZE as usize))
                        .unwrap();
                }
            })
        })
        .collect();
    for handle in handles {
        handle.join().unwrap();
    }
    let mut cache = cache.lock().unwrap();
    assert!(cache.is_complete());
    let receipt = cache.export(&mut f.create("original")).unwrap();
    let expected: Vec<_> = (0..12)
        .flat_map(|index| payload(index, MIN_CHUNK_SIZE as usize))
        .collect();
    assert_eq!(receipt.sha256, sha256_hex(&expected));
    assert_eq!(f.bytes("original"), expected);
}

#[test]
fn abrupt_process_exit_retains_synced_ranges_and_releases_lock() {
    let f = Fixture::new();
    let id = identity(u64::from(MIN_CHUNK_SIZE) * 4);
    fs::write(f.0.join("identity.json"), serde_json::to_vec(&id).unwrap()).unwrap();
    let result = std::process::Command::new(std::env::current_exe().unwrap())
        .args(["--exact", "cache_process_helper", "--nocapture"])
        .env("LEGNASEND_CACHE_FIXTURE", &f.0)
        .status()
        .unwrap();
    assert_eq!(result.code(), Some(23));
    let (mut cache, recovery) = DownloadCache::resume(f.open("crash.ls"), &id).unwrap();
    assert_eq!(recovery.committed_chunks, 2);
    assert_eq!(recovery.discarded_tail_bytes, 10);
    assert_eq!(cache.missing_chunks().collect::<Vec<_>>(), [1, 3]);
    for index in [1, 3] {
        cache
            .commit_chunk(index, &payload(index, MIN_CHUNK_SIZE as usize))
            .unwrap();
    }
    let receipt = cache.export(&mut f.create("restored")).unwrap();
    assert_eq!(receipt.bytes, id.size);
    let expected: Vec<_> = (0..4)
        .flat_map(|i| payload(i, MIN_CHUNK_SIZE as usize))
        .collect();
    assert_eq!(f.bytes("restored"), expected);
}

#[test]
fn cache_process_helper() {
    let Some(root) = std::env::var_os("LEGNASEND_CACHE_FIXTURE").map(PathBuf::from) else {
        return;
    };
    let id: CacheIdentity =
        serde_json::from_slice(&fs::read(root.join("identity.json")).unwrap()).unwrap();
    let file = OpenOptions::new()
        .read(true)
        .write(true)
        .create_new(true)
        .open(root.join("crash.ls"))
        .unwrap();
    let mut cache = DownloadCache::create(file, id).unwrap();
    for index in [2, 0] {
        cache
            .commit_chunk(index, &payload(index, MIN_CHUNK_SIZE as usize))
            .unwrap();
    }
    drop(cache);
    // The next append is interrupted before it contains a complete record.
    // Use the locked writer itself, including on mandatory-locking platforms.
    let mut writer = OpenOptions::new()
        .read(true)
        .write(true)
        .open(root.join("crash.ls"))
        .unwrap();
    writer.try_lock().unwrap();
    writer.seek(SeekFrom::End(0)).unwrap();
    writer.write_all(b"LSCHUNK1xx").unwrap();
    writer.sync_data().unwrap();
    std::process::exit(23); // No destructors; simulates process loss, not power loss.
}

#[test]
fn display_name_round_trips_whitespace_newlines_and_path_characters_verbatim() {
    let f = Fixture::new();
    let mut id = identity(0);
    id.file_name = " ../碧绿\\TAB\t换行\n百分号%23# ".into();
    drop(DownloadCache::create(f.create("owned.ls"), id.clone()).unwrap());
    let (cache, _) = DownloadCache::resume(f.open("owned.ls"), &id).unwrap();
    assert_eq!(cache.identity().file_name, id.file_name);
    // Stored display metadata never opens a path or creates a directory.
    assert_eq!(fs::read_dir(&f.0).unwrap().count(), 1);
}

#[cfg(unix)]
#[test]
fn failed_append_requires_recovery_and_does_not_acknowledge_progress() {
    let f = Fixture::new();
    let id = identity(3);
    drop(DownloadCache::create(f.create("owned.ls"), id.clone()).unwrap());
    let before = f.bytes("owned.ls");
    // On Unix a read-only descriptor can hold flock but cannot append bytes.
    let (mut cache, _) =
        DownloadCache::resume(File::open(f.0.join("owned.ls")).unwrap(), &id).unwrap();
    assert!(matches!(
        cache.commit_chunk(0, b"abc"),
        Err(CacheError::Io(_))
    ));
    assert_eq!(cache.committed_bytes(), 0);
    assert!(matches!(
        cache.commit_chunk(0, b"abc"),
        Err(CacheError::ReopenRequired)
    ));
    assert!(!cache.is_complete());
    assert_eq!(f.bytes("owned.ls"), before);
    drop(cache);
    let (mut cache, _) = DownloadCache::resume(f.open("owned.ls"), &id).unwrap();
    cache.commit_chunk(0, b"abc").unwrap();
    assert!(cache.is_complete());
}

#[test]
fn forty_mib_file_uses_the_same_disk_container_without_a_memory_size_branch() {
    use sha2::{Digest, Sha256};
    use std::io::Read;
    let f = Fixture::new();
    let mut id = identity(40 * 1024 * 1024);
    id.chunk_size = 1024 * 1024;
    let mut expected = Sha256::new();
    let mut cache = DownloadCache::create(f.create("large.ls"), id.clone()).unwrap();
    for index in 0..40 {
        let bytes = payload(index, id.chunk_size as usize);
        expected.update(&bytes);
        cache.commit_chunk(index, &bytes).unwrap();
    }
    drop(cache);
    let (mut cache, recovery) = DownloadCache::resume(f.open("large.ls"), &id).unwrap();
    assert_eq!(recovery.committed_bytes, 40 * 1024 * 1024);
    let receipt = cache.export(&mut f.create("original")).unwrap();
    println!(
        "LS_CACHE_FIXTURE bytes={} sha256={}",
        receipt.bytes, receipt.sha256
    );
    let mut actual = Sha256::new();
    let mut file = f.open("original");
    let mut buffer = [0; 64 * 1024];
    loop {
        let size = file.read(&mut buffer).unwrap();
        if size == 0 {
            break;
        }
        actual.update(&buffer[..size]);
    }
    let expected = expected.finalize();
    assert_eq!(actual.finalize().as_slice(), expected.as_slice());
    assert_eq!(
        receipt.sha256,
        expected
            .iter()
            .map(|b| format!("{b:02x}"))
            .collect::<String>()
    );
    assert_eq!(file.metadata().unwrap().len(), id.size);
}

#[test]
fn cancelling_recovery_keeps_even_an_incomplete_tail_and_releases_the_lock() {
    let f = Fixture::new();
    let id = identity(u64::from(MIN_CHUNK_SIZE) * 2);
    let mut cache = DownloadCache::create(f.create("a.ls"), id.clone()).unwrap();
    cache
        .commit_chunk(0, &payload(0, MIN_CHUNK_SIZE as usize))
        .unwrap();
    drop(cache);
    OpenOptions::new()
        .append(true)
        .open(f.0.join("a.ls"))
        .unwrap()
        .write_all(b"tail")
        .unwrap();
    let before = f.bytes("a.ls");
    let mut progress = vec![];
    assert!(matches!(
        DownloadCache::resume_with_progress(f.open("a.ls"), &id, |bytes| {
            progress.push(bytes);
            bytes == 0
        }),
        Err(CacheError::Cancelled)
    ));
    assert_eq!(progress, [0, u64::from(MIN_CHUNK_SIZE)]);
    assert_eq!(f.bytes("a.ls"), before);
    let (_, recovery) = DownloadCache::resume(f.open("a.ls"), &id).unwrap();
    assert_eq!(recovery.discarded_tail_bytes, 4);
}

#[test]
fn cancelling_export_keeps_cache_and_never_publishes_a_receipt() {
    let f = Fixture::new();
    let id = identity(u64::from(MIN_CHUNK_SIZE) * 2);
    let mut cache = DownloadCache::create(f.create("a.ls"), id).unwrap();
    for index in 0..2 {
        cache
            .commit_chunk(index, &payload(index, MIN_CHUNK_SIZE as usize))
            .unwrap();
    }
    let mut output = f.create("stage");
    let mut progress = vec![];
    assert!(matches!(
        cache.export_with_progress(&mut output, |bytes| {
            progress.push(bytes);
            bytes == 0
        }),
        Err(CacheError::Cancelled)
    ));
    assert_eq!(progress, [0, u64::from(MIN_CHUNK_SIZE)]);
    assert_eq!(output.metadata().unwrap().len(), u64::from(MIN_CHUNK_SIZE));
    assert!(cache.is_complete());
    // Caller may clean its known staging file and retry, never the cache.
    output.set_len(0).unwrap();
    assert_eq!(
        cache.export(&mut output).unwrap().bytes,
        u64::from(MIN_CHUNK_SIZE) * 2
    );
}

#[test]
fn unwinding_a_progress_callback_does_not_leak_the_borrowed_output_lock() {
    let f = Fixture::new();
    let mut cache = DownloadCache::create(f.create("empty.ls"), identity(0)).unwrap();
    let mut output = f.create("stage");
    let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        let _ = cache.export_with_progress(&mut output, |_| panic!("fixture callback failure"));
    }));
    assert!(result.is_err());
    f.open("stage").try_lock().unwrap();
    assert!(cache.export(&mut output).is_ok());
}

#[test]
fn unreadable_handle_is_a_storage_error_not_a_corrupt_format() {
    let f = Fixture::new();
    let id = identity(0);
    drop(DownloadCache::create(f.create("owned.ls"), id.clone()).unwrap());
    let before = f.bytes("owned.ls");
    let file = OpenOptions::new()
        .write(true)
        .open(f.0.join("owned.ls"))
        .unwrap();
    assert!(matches!(
        DownloadCache::resume(file, &id),
        Err(CacheError::Io(_))
    ));
    assert_eq!(f.bytes("owned.ls"), before);
}
