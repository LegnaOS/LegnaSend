#![cfg(feature = "full")]
use localsend::{
    crypto::hash::sha256_hex,
    download_cache::{CacheError, CacheIdentity, DownloadCache, MIN_CHUNK_SIZE},
    receive_descriptor::{
        DescriptorReceive, ReceiveCleanupGuard, ReceivePublicationGuard, RecoveryProgress,
    },
};
use std::{
    fs::{self, File, OpenOptions},
    io::Write,
    path::PathBuf,
};

struct Fixture(PathBuf);
impl Fixture {
    fn new() -> Self {
        let p =
            std::env::temp_dir().join(format!("legna-provider-recovery-{}", uuid::Uuid::new_v4()));
        fs::create_dir(&p).unwrap();
        Self(p)
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
fn identity(bytes: &[u8]) -> CacheIdentity {
    CacheIdentity {
        task_id: uuid::Uuid::new_v4().to_string(),
        source_id: "authenticated-source-fingerprint".into(),
        resource_id: uuid::Uuid::new_v4().to_string(),
        version: "stable-content-version".into(),
        file_name: "中文 100%.bin".into(),
        size: bytes.len() as u64,
        chunk_size: MIN_CHUNK_SIZE,
        created_unix_ms: 1790400000000,
        sha256: Some(sha256_hex(bytes)),
    }
}
fn data() -> Vec<u8> {
    (0..MIN_CHUNK_SIZE as usize * 3 + 17)
        .map(|i| (i % 251) as u8)
        .collect()
}

#[test]
fn reopen_verifies_prefix_and_exports_original_bytes_after_all_handles_close() {
    let f = Fixture::new();
    let bytes = data();
    let id = identity(&bytes);
    let n = MIN_CHUNK_SIZE as usize;
    let mut txn =
        DescriptorReceive::create(f.create("cache.ls"), f.create("old.part"), id.clone()).unwrap();
    assert_eq!(txn.commit(0, &bytes[..n]).unwrap(), n as u64);
    drop(txn);
    let (mut txn, report) =
        DescriptorReceive::resume(f.open("cache.ls"), f.create("new.part"), &id, |_| true).unwrap();
    assert_eq!(report.committed_bytes, n as u64);
    assert_eq!(txn.offset(), n as u64);
    for block in bytes[n..].chunks(n) {
        txn.commit(txn.offset(), block).unwrap();
    }
    let receipt = txn.finish(|_| true).unwrap();
    assert_eq!(receipt.sha256, sha256_hex(&bytes));
    assert_eq!(f.bytes("new.part"), bytes);
    // Success is returned only once both owned descriptions have closed.
    let cache = f.open("cache.ls");
    let staging = f.open("new.part");
    cache.try_lock().unwrap();
    staging.try_lock().unwrap();
}

#[test]
fn migration_leaves_old_partial_tail_unchanged_and_only_copies_verified_records() {
    let f = Fixture::new();
    let bytes = data();
    let id = identity(&bytes);
    let n = MIN_CHUNK_SIZE as usize;
    let mut original = DownloadCache::create(f.create("old.ls"), id.clone()).unwrap();
    original.commit_chunk(0, &bytes[..n]).unwrap();
    original.commit_chunk(2, &bytes[n * 2..n * 3]).unwrap();
    drop(original);
    OpenOptions::new()
        .append(true)
        .open(f.0.join("old.ls"))
        .unwrap()
        .write_all(b"partial")
        .unwrap();
    let before = f.bytes("old.ls");
    let (mut txn, report) = DescriptorReceive::recover_copy(
        f.open("old.ls"),
        f.create("new.ls"),
        f.create("new.part"),
        &id,
        |_| true,
    )
    .unwrap();
    assert_eq!(report.source_length, before.len() as u64);
    assert_eq!(
        report.source_sha256,
        sha256_hex(&before).to_ascii_lowercase()
    );
    assert_eq!(report.retained_tail_bytes, 7); // Identified, NOT discarded in the old source.
    assert_eq!(f.bytes("old.ls"), before);
    assert_eq!(report.committed_bytes, (n * 2) as u64);
    assert_eq!(txn.offset(), n as u64); // Sparse total must not skip the missing block.
    assert_eq!(
        txn.commit(n as u64, &bytes[n..n * 2]).unwrap(),
        (n * 3) as u64
    );
    txn.commit((n * 3) as u64, &bytes[n * 3..]).unwrap();
    txn.finish(|_| true).unwrap();
    assert_eq!(f.bytes("new.part"), bytes);
    assert_eq!(f.bytes("old.ls"), before);
}

#[test]
fn mismatch_never_repairs_old_tail_or_initializes_new_files() {
    let f = Fixture::new();
    let bytes = data();
    let id = identity(&bytes);
    drop(DownloadCache::create(f.create("old.ls"), id.clone()).unwrap());
    OpenOptions::new()
        .append(true)
        .open(f.0.join("old.ls"))
        .unwrap()
        .write_all(b"tail")
        .unwrap();
    let before = f.bytes("old.ls");
    let mut wrong = id;
    wrong.source_id = "other-peer".into();
    assert!(matches!(
        DescriptorReceive::recover_copy(
            f.open("old.ls"),
            f.create("new.ls"),
            f.create("stage"),
            &wrong,
            |_| true
        ),
        Err(CacheError::IdentityMismatch)
    ));
    assert_eq!(f.bytes("old.ls"), before);
    assert!(f.bytes("new.ls").is_empty());
    assert!(f.bytes("stage").is_empty());
}

#[test]
fn active_cache_or_staging_writer_blocks_recovery_before_any_mutation() {
    for held_name in ["old.ls", "new.ls", "stage"] {
        let f = Fixture::new();
        let id = identity(b"hello");
        drop(DownloadCache::create(f.create("old.ls"), id.clone()).unwrap());
        drop(f.create("new.ls"));
        drop(f.create("stage"));
        let before = f.bytes("old.ls");
        let held = f.open(held_name);
        held.try_lock().unwrap();
        assert!(matches!(
            DescriptorReceive::recover_copy(
                f.open("old.ls"),
                f.open("new.ls"),
                f.open("stage"),
                &id,
                |_| true
            ),
            Err(CacheError::Busy)
        ));
        assert_eq!(f.bytes("old.ls"), before);
        assert!(f.bytes("new.ls").is_empty());
        drop(held);
        DescriptorReceive::recover_copy(
            f.open("old.ls"),
            f.open("new.ls"),
            f.open("stage"),
            &id,
            |_| true,
        )
        .unwrap();
    }
}

#[test]
fn aliases_and_nonempty_staging_are_never_truncated_even_with_repairable_tail() {
    let f = Fixture::new();
    let id = identity(b"hello");
    drop(DownloadCache::create(f.create("old.ls"), id.clone()).unwrap());
    OpenOptions::new()
        .append(true)
        .open(f.0.join("old.ls"))
        .unwrap()
        .write_all(b"tail")
        .unwrap();
    let before = f.bytes("old.ls");
    assert!(DescriptorReceive::resume(f.open("old.ls"), f.open("old.ls"), &id, |_| true).is_err());
    f.create("stage").write_all(b"user data").unwrap();
    assert!(matches!(
        DescriptorReceive::resume(f.open("old.ls"), f.open("stage"), &id, |_| true),
        Err(CacheError::NotEmpty)
    ));
    assert!(
        DescriptorReceive::recover_copy(
            f.open("old.ls"),
            f.open("old.ls"),
            f.open("stage"),
            &id,
            |_| true
        )
        .is_err()
    );
    assert_eq!(f.bytes("old.ls"), before);
    assert_eq!(f.bytes("stage"), b"user data");
}

#[test]
fn complete_corruption_is_not_migrated_or_repaired() {
    let f = Fixture::new();
    let bytes = data();
    let id = identity(&bytes);
    let n = MIN_CHUNK_SIZE as usize;
    let mut cache = DownloadCache::create(f.create("old.ls"), id.clone()).unwrap();
    cache.commit_chunk(0, &bytes[..n]).unwrap();
    drop(cache);
    let mut corrupt = f.bytes("old.ls");
    let i = corrupt.len() - 50;
    corrupt[i] ^= 1;
    fs::write(f.0.join("old.ls"), &corrupt).unwrap();
    assert!(matches!(
        DescriptorReceive::recover_copy(
            f.open("old.ls"),
            f.create("new.ls"),
            f.create("stage"),
            &id,
            |_| true
        ),
        Err(CacheError::Corrupt)
    ));
    assert_eq!(f.bytes("old.ls"), corrupt);
    assert!(f.bytes("new.ls").is_empty());
}

#[test]
fn cancel_during_scan_or_copy_keeps_source_and_releases_all_locks() {
    for stop in [1, 3, 5] {
        let f = Fixture::new();
        let bytes = data();
        let id = identity(&bytes);
        let n = MIN_CHUNK_SIZE as usize;
        let mut cache = DownloadCache::create(f.create("old.ls"), id.clone()).unwrap();
        cache.commit_chunk(0, &bytes[..n]).unwrap();
        cache.commit_chunk(1, &bytes[n..n * 2]).unwrap();
        drop(cache);
        let before = f.bytes("old.ls");
        let mut visits = 0;
        assert!(matches!(
            DescriptorReceive::recover_copy(
                f.open("old.ls"),
                f.create("new.ls"),
                f.create("stage"),
                &id,
                |_| {
                    visits += 1;
                    visits < stop
                }
            ),
            Err(CacheError::Cancelled)
        ));
        assert_eq!(f.bytes("old.ls"), before);
        for name in ["old.ls", "new.ls", "stage"] {
            f.open(name).try_lock().unwrap();
        }
    }
}

#[test]
fn failed_command_requires_reopen_and_strong_full_hash_gates_export() {
    let f = Fixture::new();
    let id = identity(b"hello");
    let mut txn =
        DescriptorReceive::create(f.create("cache"), f.create("stage"), id.clone()).unwrap();
    assert!(matches!(txn.commit(0, b"short!"), Err(CacheError::Chunk)));
    assert!(matches!(
        txn.commit(0, b"hello"),
        Err(CacheError::ReopenRequired)
    ));
    drop(txn);
    let (mut txn, _) =
        DescriptorReceive::resume(f.open("cache"), f.create("stage2"), &id, |_| true).unwrap();
    txn.commit(0, b"wrong").unwrap();
    assert!(matches!(txn.finish(|_| true), Err(CacheError::Checksum)));
}

#[test]
fn missing_strong_identity_and_unknown_cache_are_retained() {
    let f = Fixture::new();
    let mut id = identity(b"hello");
    id.sha256 = None;
    assert!(matches!(
        DescriptorReceive::create(f.create("cache"), f.create("stage"), id),
        Err(CacheError::Identity)
    ));
    assert!(f.bytes("cache").is_empty());
    f.open("cache").write_all(b"unknown file").unwrap();
    let before = f.bytes("cache");
    assert!(
        DescriptorReceive::resume(
            f.open("cache"),
            f.open("stage"),
            &identity(b"hello"),
            |_| true
        )
        .is_err()
    );
    assert_eq!(f.bytes("cache"), before);
}

#[test]
fn empty_file_exports_and_incomplete_file_never_returns_a_receipt() {
    let f = Fixture::new();
    let txn =
        DescriptorReceive::create(f.create("empty"), f.create("stage"), identity(b"")).unwrap();
    assert_eq!(txn.finish(|_| true).unwrap().bytes, 0);
    let txn = DescriptorReceive::create(
        f.create("incomplete"),
        f.create("stage2"),
        identity(b"hello"),
    )
    .unwrap();
    assert!(matches!(txn.finish(|_| true), Err(CacheError::Incomplete)));
    assert!(f.bytes("stage2").is_empty());
}

#[test]
fn child_writer_or_lock_probe() {
    let Some(root) = std::env::var_os("LEGNA_DESCRIPTOR_CHILD_ROOT") else {
        return;
    };
    let root = PathBuf::from(root);
    let id: CacheIdentity =
        serde_json::from_slice(&fs::read(root.join("identity.json")).unwrap()).unwrap();
    let open = |name: &str| {
        OpenOptions::new()
            .read(true)
            .write(true)
            .open(root.join(name))
            .unwrap()
    };
    if std::env::var("LEGNA_DESCRIPTOR_CHILD_MODE").unwrap() == "probe" {
        assert!(matches!(
            DescriptorReceive::resume(open("cache"), open("stage"), &id, |_| true),
            Err(CacheError::Busy)
        ));
        return;
    }
    let mut txn = DescriptorReceive::create(open("cache"), open("stage"), id).unwrap();
    txn.commit(0, &data()[..MIN_CHUNK_SIZE as usize]).unwrap();
    // No destructors or user-space shutdown: only committed bytes and kernel FD
    // release survive this process boundary, as with a lost application process.
    std::process::exit(0);
}

#[test]
fn independent_process_exit_recovers_durable_prefix_and_real_contention_blocks() {
    let f = Fixture::new();
    let bytes = data();
    let id = identity(&bytes);
    fs::write(f.0.join("identity.json"), serde_json::to_vec(&id).unwrap()).unwrap();
    drop(f.create("cache"));
    drop(f.create("stage"));
    let run = |mode: &str| {
        let output = std::process::Command::new(std::env::current_exe().unwrap())
            .args(["--exact", "child_writer_or_lock_probe", "--nocapture"])
            .env("LEGNA_DESCRIPTOR_CHILD_ROOT", &f.0)
            .env("LEGNA_DESCRIPTOR_CHILD_MODE", mode)
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "{}",
            String::from_utf8_lossy(&output.stderr)
        );
    };
    run("write");
    let (mut txn, report) = DescriptorReceive::recover_copy(
        f.open("cache"),
        f.create("new.ls"),
        f.create("new.part"),
        &id,
        |_| true,
    )
    .unwrap();
    assert_eq!(report.committed_bytes, u64::from(MIN_CHUNK_SIZE));
    let source_container = f.bytes("cache");
    assert_eq!(report.source_length, source_container.len() as u64);
    assert_eq!(
        report.source_sha256,
        sha256_hex(&source_container).to_ascii_lowercase()
    );
    // Hold a separate real lock on the original source for the child probe.
    let held = f.open("cache");
    held.try_lock().unwrap();
    run("probe");
    drop(held);
    for block in bytes[MIN_CHUNK_SIZE as usize..].chunks(MIN_CHUNK_SIZE as usize) {
        txn.commit(txn.offset(), block).unwrap();
    }
    txn.finish(|_| true).unwrap();
    assert_eq!(f.bytes("new.part"), bytes);
}

#[test]
fn readonly_recovery_rebinds_only_task_and_creation_time() {
    let f = Fixture::new();
    let bytes = data();
    let old = identity(&bytes);
    let mut original = DownloadCache::create(f.create("old.ls"), old.clone()).unwrap();
    original
        .commit_chunk(0, &bytes[..MIN_CHUNK_SIZE as usize])
        .unwrap();
    drop(original);
    let before = f.bytes("old.ls");
    let mut new = old.clone();
    new.task_id = uuid::Uuid::new_v4().to_string();
    new.created_unix_ms += 1;
    let (copy, proof) = DescriptorReceive::recover_copy_as(
        File::open(f.0.join("old.ls")).unwrap(),
        f.create("new.ls"),
        f.create("new.part"),
        &old,
        new.clone(),
        |_| true,
    )
    .unwrap();
    assert_eq!(copy.offset(), MIN_CHUNK_SIZE as u64);
    assert_eq!(proof.source_length, before.len() as u64);
    assert_eq!(
        proof.source_sha256,
        sha256_hex(&before).to_ascii_lowercase()
    );
    drop(copy);
    let (_, report) =
        DescriptorReceive::resume(f.open("new.ls"), f.create("verify.part"), &new, |_| true)
            .unwrap();
    assert_eq!(report.committed_bytes, MIN_CHUNK_SIZE as u64);
    assert_eq!(f.bytes("old.ls"), before);
}

#[test]
fn new_transaction_cannot_rebind_source_or_content_identity() {
    for field in 0..6 {
        let f = Fixture::new();
        let old = identity(&data());
        drop(DownloadCache::create(f.create("old.ls"), old.clone()).unwrap());
        let mut new = old.clone();
        new.task_id = uuid::Uuid::new_v4().to_string();
        match field {
            0 => new.source_id = "wrong".into(),
            1 => new.resource_id = "wrong".into(),
            2 => new.version = "wrong".into(),
            3 => new.size += 1,
            4 => new.file_name = "wrong".into(),
            _ => new.sha256 = Some("0".repeat(64)),
        };
        assert!(matches!(
            DescriptorReceive::recover_copy_as(
                File::open(f.0.join("old.ls")).unwrap(),
                f.create("new.ls"),
                f.create("stage"),
                &old,
                new,
                |_| true
            ),
            Err(CacheError::IdentityMismatch)
        ));
        assert!(f.bytes("new.ls").is_empty());
        assert!(f.bytes("stage").is_empty());
    }
}

#[test]
fn recovery_proof_covers_uncommitted_tail_and_rejects_provider_mutation_during_copy() {
    use std::io::{Seek, SeekFrom};
    for extend in [false, true] {
        let f = Fixture::new();
        let bytes = data();
        let id = identity(&bytes);
        let mut original = DownloadCache::create(f.create("old.ls"), id.clone()).unwrap();
        original
            .commit_chunk(0, &bytes[..MIN_CHUNK_SIZE as usize])
            .unwrap();
        drop(original);
        let mut mutator = f.open("old.ls");
        mutator.seek(SeekFrom::End(0)).unwrap();
        mutator.write_all(b"partial").unwrap();
        let before = f.bytes("old.ls");
        let mut changed = false;
        let result = DescriptorReceive::recover_copy(
            File::open(f.0.join("old.ls")).unwrap(),
            f.create("new.ls"),
            f.create("stage"),
            &id,
            |phase| {
                if matches!(phase, RecoveryProgress::Copying(_)) && !changed {
                    // Simulate a provider ignoring advisory exclusion. The
                    // committed record remains valid, but the exact old container
                    // no longer matches the pre-copy deletion proof.
                    mutator
                        .seek(SeekFrom::End(if extend { 0 } else { -1 }))
                        .unwrap();
                    mutator.write_all(b"X").unwrap();
                    mutator.sync_data().unwrap();
                    changed = true;
                }
                true
            },
        );
        assert!(changed);
        assert!(result.is_err());
        let after = f.bytes("old.ls");
        assert_ne!(after, before);
        assert_eq!(after.len(), before.len() + usize::from(extend));
        // Rejection preserves the provider's changed document and releases
        // every transaction lock; it is not authority to repair or delete it.
        assert_eq!(after.last(), Some(&b'X'));
        for name in ["old.ls", "new.ls", "stage"] {
            f.open(name).try_lock().unwrap();
        }
    }
}

fn cleanup_source(f: &Fixture) -> (Vec<u8>, String) {
    let bytes = data();
    let id = identity(&bytes);
    let mut cache = DownloadCache::create(f.create("old.ls"), id).unwrap();
    for (index, block) in bytes.chunks(MIN_CHUNK_SIZE as usize).take(3).enumerate() {
        cache.commit_chunk(index as u32, block).unwrap();
    }
    drop(cache);
    OpenOptions::new()
        .append(true)
        .open(f.0.join("old.ls"))
        .unwrap()
        .write_all(b"uncommitted-tail")
        .unwrap();
    let container = f.bytes("old.ls");
    let hash = sha256_hex(&container).to_ascii_lowercase();
    (container, hash)
}

#[test]
fn cleanup_guard_holds_real_exclusive_lock_until_drop_without_deleting_source() {
    let f = Fixture::new();
    let (container, hash) = cleanup_source(&f);
    let writer = f.open("old.ls");
    writer.try_lock().unwrap();
    assert!(matches!(
        ReceiveCleanupGuard::acquire(f.open("old.ls"), container.len() as u64, &hash, || true,),
        Err(CacheError::Busy)
    ));
    assert_eq!(f.bytes("old.ls"), container);
    drop(writer);
    let guard =
        ReceiveCleanupGuard::acquire(f.open("old.ls"), container.len() as u64, &hash, || true)
            .unwrap();
    assert!(matches!(
        f.open("old.ls").try_lock(),
        Err(std::fs::TryLockError::WouldBlock)
    ));
    assert!(matches!(
        f.open("old.ls").try_lock_shared(),
        Err(std::fs::TryLockError::WouldBlock)
    ));
    assert_eq!(f.bytes("old.ls"), container);
    drop(guard);
    assert_eq!(f.bytes("old.ls"), container);
    f.open("old.ls").try_lock().unwrap();
}

#[test]
fn cleanup_guard_rejects_wrong_length_digest_or_changed_payload_and_tail() {
    for mutation in 0..5 {
        let f = Fixture::new();
        let (container, hash) = cleanup_source(&f);
        let mut expected_length = container.len() as u64;
        let mut expected_hash = hash.clone();
        let mut current = container.clone();
        match mutation {
            0 => expected_length -= 1,
            1 => expected_hash = "0".repeat(64),
            2 => current[container.len() / 2] ^= 1,
            3 => current.push(b'X'),
            _ => {
                current.pop();
            }
        }
        fs::write(f.0.join("old.ls"), &current).unwrap();
        assert!(matches!(
            ReceiveCleanupGuard::acquire(f.open("old.ls"), expected_length, &expected_hash, || {
                true
            },),
            Err(CacheError::IdentityMismatch)
        ));
        assert_eq!(f.bytes("old.ls"), current);
        f.open("old.ls").try_lock().unwrap();
    }
}

#[test]
fn cleanup_guard_cancellation_or_invalid_proof_closes_handle_and_preserves_file() {
    let f = Fixture::new();
    let (container, hash) = cleanup_source(&f);
    assert!(matches!(
        ReceiveCleanupGuard::acquire(
            f.open("old.ls"),
            container.len() as u64,
            "not-a-sha256",
            || true,
        ),
        Err(CacheError::Identity)
    ));
    for stop in [1, 3] {
        let mut visits = 0;
        assert!(matches!(
            ReceiveCleanupGuard::acquire(f.open("old.ls"), container.len() as u64, &hash, || {
                visits += 1;
                visits < stop
            },),
            Err(CacheError::Cancelled)
        ));
        assert!(visits >= stop);
        assert_eq!(f.bytes("old.ls"), container);
        f.open("old.ls").try_lock().unwrap();
    }
}

#[test]
fn readonly_cleanup_handle_never_claims_a_guard_without_an_exclusive_lock() {
    let f = Fixture::new();
    let (container, hash) = cleanup_source(&f);
    let result = ReceiveCleanupGuard::acquire(
        File::open(f.0.join("old.ls")).unwrap(),
        container.len() as u64,
        &hash,
        || true,
    );
    match result {
        Ok(guard) => {
            // POSIX flock accepts read-only descriptions. A successful guard
            // must still prevent an independent writer, not downgrade to SH.
            assert!(matches!(
                f.open("old.ls").try_lock(),
                Err(std::fs::TryLockError::WouldBlock)
            ));
            drop(guard);
        }
        Err(CacheError::Io(_)) => {
            // Platforms whose strict fallback needs a write-capable FD fail
            // closed; no lock-free or process-local fallback is acceptable.
        }
        Err(_) => panic!("Unexpected cleanup admission failure"),
    }
    assert_eq!(f.bytes("old.ls"), container);
    f.open("old.ls").try_lock().unwrap();
}

#[test]
fn publication_guard_reads_readonly_transport_holds_shared_lock_and_preserves_witness_position() {
    use std::io::{Seek, SeekFrom};
    let f = Fixture::new();
    let content = b"already published output";
    f.create("output").write_all(content).unwrap();
    let mut witness = File::open(f.0.join("output")).unwrap();
    witness.seek(SeekFrom::Start(7)).unwrap();
    let guard = ReceivePublicationGuard::acquire(
        File::open(f.0.join("output")).unwrap(),
        content.len() as u64,
        &sha256_hex(content),
        || true,
    )
    .unwrap();
    assert_eq!(witness.stream_position().unwrap(), 7);
    assert_eq!(f.bytes("output"), content);
    let second_reader = File::open(f.0.join("output")).unwrap();
    second_reader.try_lock_shared().unwrap();
    assert!(matches!(
        f.open("output").try_lock(),
        Err(std::fs::TryLockError::WouldBlock)
    ));
    drop(second_reader);
    assert!(matches!(
        f.open("output").try_lock(),
        Err(std::fs::TryLockError::WouldBlock)
    ));
    drop(guard);
    f.open("output").try_lock().unwrap();
    assert_eq!(f.bytes("output"), content);
    f.open("output").write_all(b"changed").unwrap();
    assert!(matches!(
        ReceivePublicationGuard::acquire(
            File::open(f.0.join("output")).unwrap(),
            content.len() as u64,
            &sha256_hex(content),
            || true,
        ),
        Err(CacheError::IdentityMismatch)
    ));
    assert!(f.0.join("output").exists());
}

#[test]
fn publication_guard_rejects_active_writer_bad_hash_bad_length_and_nonregular_input() {
    let f = Fixture::new();
    let content = b"published file";
    f.create("output").write_all(content).unwrap();
    let writer = f.open("output");
    writer.try_lock().unwrap();
    assert!(matches!(
        ReceivePublicationGuard::acquire(
            File::open(f.0.join("output")).unwrap(),
            content.len() as u64,
            &sha256_hex(content),
            || true,
        ),
        Err(CacheError::Busy)
    ));
    drop(writer);
    for (length, hash) in [
        (content.len() as u64 + 1, sha256_hex(content)),
        (content.len() as u64, "0".repeat(64)),
        (content.len() as u64, "invalid".into()),
    ] {
        assert!(
            ReceivePublicationGuard::acquire(
                File::open(f.0.join("output")).unwrap(),
                length,
                &hash,
                || true
            )
            .is_err()
        );
        assert_eq!(f.bytes("output"), content);
        f.open("output").try_lock().unwrap();
    }
    #[cfg(unix)]
    {
        assert!(matches!(
            ReceivePublicationGuard::acquire(
                File::open(&f.0).unwrap(),
                0,
                &sha256_hex(b""),
                || true,
            ),
            Err(CacheError::Identity)
        ));
    }
}

#[test]
fn publication_guard_detects_same_size_rewrite_of_bytes_already_hashed() {
    use std::io::{Seek, SeekFrom};
    let f = Fixture::new();
    let content = vec![17; 256 * 1024];
    f.create("output").write_all(&content).unwrap();
    let mut writer = f.open("output");
    let mut calls = 0;
    let result = ReceivePublicationGuard::acquire(
        File::open(f.0.join("output")).unwrap(),
        content.len() as u64,
        &sha256_hex(&content),
        || {
            calls += 1;
            if calls == 3 {
                // Advisory-lock-ignoring provider: change the first block after
                // hashing it. A digest-only check would still see the old hash.
                writer.seek(SeekFrom::Start(0)).unwrap();
                writer.write_all(b"X").unwrap();
                writer.sync_data().unwrap();
            }
            true
        },
    );
    assert!(calls >= 3);
    assert!(matches!(result, Err(CacheError::IdentityMismatch)));
    assert_eq!(f.bytes("output")[0], b'X');
    f.open("output").try_lock().unwrap();
}

#[test]
fn publication_guard_mid_hash_cancellation_and_length_changes_retain_output() {
    use std::io::{Seek, SeekFrom};
    for mode in ["cancel", "append", "truncate"] {
        let f = Fixture::new();
        let content = vec![21; 256 * 1024];
        f.create("output").write_all(&content).unwrap();
        let mut writer = f.open("output");
        let mut calls = 0;
        let result = ReceivePublicationGuard::acquire(
            File::open(f.0.join("output")).unwrap(),
            content.len() as u64,
            &sha256_hex(&content),
            || {
                calls += 1;
                if calls == 3 {
                    match mode {
                        "cancel" => return false,
                        "append" => {
                            writer.seek(SeekFrom::End(0)).unwrap();
                            writer.write_all(b"X").unwrap();
                        }
                        _ => writer.set_len(32).unwrap(),
                    }
                }
                true
            },
        );
        assert!(result.is_err());
        if mode == "cancel" {
            assert_eq!(f.bytes("output"), content);
        }
        assert!(f.0.join("output").exists());
        f.open("output").try_lock().unwrap();
    }
}

#[test]
fn publication_guard_large_file_streams_with_fixed_buffer_and_empty_file_is_valid() {
    use sha2::{Digest, Sha256};
    let f = Fixture::new();
    let mut output = f.create("large-output");
    let block = [43; 64 * 1024];
    let mut hash = Sha256::new();
    let blocks = 768; // 48 MiB: above the retired browser-memory cache limit.
    for _ in 0..blocks {
        output.write_all(&block).unwrap();
        hash.update(block);
    }
    output.sync_all().unwrap();
    drop(output);
    let length = blocks * block.len() as u64;
    let hash = hash
        .finalize()
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect::<String>();
    let mut calls = 0;
    let guard = ReceivePublicationGuard::acquire(
        File::open(f.0.join("large-output")).unwrap(),
        length,
        &hash,
        || {
            calls += 1;
            true
        },
    )
    .unwrap();
    assert!(
        calls >= blocks,
        "The stream must observe cancellation between fixed-size reads"
    );
    assert_eq!(
        std::fs::metadata(f.0.join("large-output")).unwrap().len(),
        length
    );
    drop(guard);
    f.create("empty");
    drop(
        ReceivePublicationGuard::acquire(
            File::open(f.0.join("empty")).unwrap(),
            0,
            &sha256_hex(b""),
            || true,
        )
        .unwrap(),
    );
    assert_eq!(f.bytes("empty"), b"");
}

#[test]
fn cleanup_guard_rejects_same_size_changes_after_first_block_was_hashed() {
    use std::io::{Seek, SeekFrom};
    let f = Fixture::new();
    let bytes = vec![37; 256 * 1024];
    f.create("published.part").write_all(&bytes).unwrap();
    let mut provider = f.open("published.part");
    let mut visits = 0;
    let result = ReceiveCleanupGuard::acquire(
        f.open("published.part"),
        bytes.len() as u64,
        &sha256_hex(&bytes),
        || {
            visits += 1;
            if visits == 3 {
                // A provider ignoring advisory locks changes a block already
                // hashed. Digest+length alone still match the previous content.
                provider.seek(SeekFrom::Start(0)).unwrap();
                provider.write_all(b"X").unwrap();
                provider.sync_data().unwrap();
            }
            true
        },
    );
    assert!(visits >= 3);
    assert!(matches!(result, Err(CacheError::IdentityMismatch)));
    assert_eq!(f.bytes("published.part")[0], b'X');
    f.open("published.part").try_lock().unwrap();
}

#[test]
fn cleanup_guard_accepts_zero_byte_staging_with_empty_hash_and_keeps_exclusive_lock() {
    let f = Fixture::new();
    drop(f.create("published-output"));
    drop(f.create("published.part"));
    let guard =
        ReceiveCleanupGuard::acquire(f.open("published.part"), 0, &sha256_hex(b""), || true)
            .unwrap();
    assert!(matches!(
        f.open("published.part").try_lock(),
        Err(std::fs::TryLockError::WouldBlock)
    ));
    assert!(matches!(
        f.open("published.part").try_lock_shared(),
        Err(std::fs::TryLockError::WouldBlock)
    ));
    assert!(f.0.join("published.part").exists());
    assert_eq!(f.bytes("published-output"), b"");
    drop(guard);
    f.open("published.part").try_lock().unwrap();
    assert!(
        ReceiveCleanupGuard::acquire(f.open("published.part"), 0, &"0".repeat(64), || true)
            .is_err()
    );
    assert!(
        ReceiveCleanupGuard::acquire(f.open("published.part"), 1, &sha256_hex(b""), || true)
            .is_err()
    );
    assert_eq!(f.bytes("published.part"), b"");
    assert_eq!(f.bytes("published-output"), b"");
}
