#![cfg(feature = "http")]
use localsend::{crypto, download_cache, receive_registry};
#[allow(dead_code)]
#[path = "../src/file_lock.rs"]
mod file_lock;
#[allow(dead_code)]
#[path = "../src/receive_scope_policy.rs"]
mod receive_scope_policy;
#[allow(dead_code)]
#[path = "../src/http/source_end.rs"]
mod source_end;
mod http {
    pub(crate) use crate::source_end;
}
#[allow(dead_code, unused_imports)]
#[path = "../src/receive_resume_registry.rs"]
mod registry;
use registry::{Error, Peer, Registry, Source, Target};
use std::{io::Write, path::PathBuf};
struct Fixture {
    root: PathBuf,
    registry: std::sync::Arc<Registry>,
    source: Source,
    target: Target,
}
impl Fixture {
    fn new() -> Self {
        let root =
            std::env::temp_dir().join(format!("legna-durable-registry-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir(&root).unwrap();
        std::fs::create_dir(root.join("journal")).unwrap();
        std::fs::create_dir(root.join("received")).unwrap();
        let root = std::fs::canonicalize(root).unwrap();
        let registry = Registry::open(&root.join("journal")).unwrap();
        let source = Source {
            resume_key: uuid::Uuid::new_v4().to_string(),
            peer: Peer::Http {
                address: "127.0.0.1".into(),
            },
            sha256: "a".repeat(64),
            size: 1024 * 1024,
        };
        let target = Target::new(
            &root.join("received"),
            "file.bin",
            &root.join("received/file.bin"),
        )
        .unwrap();
        Self {
            root,
            registry,
            source,
            target,
        }
    }
    fn create(&self) -> registry::Lease {
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_millis() as u64;
        let id = Registry::identity(&self.source, &self.target, now).unwrap();
        let path = self
            .root
            .join("received")
            .join(format!(".legnasend-receive-{}.ls", id.task_id));
        let file = std::fs::OpenOptions::new()
            .read(true)
            .write(true)
            .create_new(true)
            .open(path)
            .unwrap();
        self.registry
            .create(
                self.source.clone(),
                self.target.clone(),
                id,
                &file,
                uuid::Uuid::new_v4().to_string(),
            )
            .unwrap()
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.root);
    }
}
#[test]
fn restart_requires_matching_source_approved_target_and_released_process_lease() {
    let f = Fixture::new();
    let mut lease = f.create();
    lease.suspend().unwrap();
    let second = Registry::open(&f.root.join("journal")).unwrap();
    assert!(matches!(
        second.claim(&f.source, &f.root.join("received"), "file.bin"),
        Err(Error::Busy)
    ));
    drop(lease);
    let restored = second
        .claim(&f.source, &f.root.join("received"), "file.bin")
        .unwrap()
        .unwrap();
    assert_eq!(restored.record.target.path(), f.target.path());
    drop(restored);
    let mut changed = f.source.clone();
    changed.sha256 = "b".repeat(64);
    assert!(matches!(
        second.claim(&changed, &f.root.join("received"), "file.bin"),
        Err(Error::Identity)
    ));
    assert!(second
        .claim(&f.source, &f.root.join("received"), "other.bin")
        .unwrap()
        .is_none());
    changed = f.source.clone();
    changed.peer = Peer::Http {
        address: "127.0.0.2".into(),
    };
    assert!(second
        .claim(&changed, &f.root.join("received"), "file.bin")
        .unwrap()
        .is_none());
}
#[test]
fn replaced_parent_or_cache_inode_is_never_adopted_or_deleted() {
    let f = Fixture::new();
    let mut lease = f.create();
    let cache = f.root.join("received").join(lease.record.cache_name());
    std::fs::rename(&cache, cache.with_extension("original")).unwrap();
    std::fs::write(&cache, b"foreign").unwrap();
    assert!(matches!(lease.open_cache(), Err(Error::Identity)));
    assert!(matches!(lease.discard(), Err(Error::Identity)));
    assert_eq!(std::fs::read(&cache).unwrap(), b"foreign");
    drop(lease);
    std::fs::rename(f.root.join("received"), f.root.join("previous")).unwrap();
    std::fs::create_dir(f.root.join("received")).unwrap();
    assert!(f
        .registry
        .claim(&f.source, &f.root.join("received"), "file.bin")
        .unwrap()
        .is_none());
}
#[test]
fn publishing_intent_can_identify_lost_ack_without_overwriting_or_cleaning_final() {
    let mut f = Fixture::new();
    f.source.sha256 = crypto::hash::sha256_hex(&vec![0; f.source.size as usize]);
    let mut lease = f.create();
    let staging = f.root.join("received").join(lease.record.staging_name());
    let mut output = std::fs::OpenOptions::new()
        .read(true)
        .write(true)
        .create_new(true)
        .open(&staging)
        .unwrap();
    output.write_all(&vec![0; f.source.size as usize]).unwrap();
    output.sync_all().unwrap();
    lease.exporting(&output).unwrap();
    let receipt = download_cache::ExportReceipt {
        bytes: f.source.size,
        sha256: f.source.sha256.clone(),
    };
    lease.publishing(&receipt).unwrap();
    std::fs::rename(&staging, f.target.path()).unwrap();
    drop(lease);
    let mut restored = f
        .registry
        .claim(&f.source, &f.root.join("received"), "file.bin")
        .unwrap()
        .unwrap();
    let final_file = restored.published_file().unwrap().unwrap();
    assert_eq!(final_file.metadata().unwrap().len(), f.source.size);
    // This primitive establishes identity only; integration must verify whole SHA.
    let verified = restored.reconcile_published(|_| true).unwrap().unwrap();
    assert_eq!(verified, receipt);
    restored.discard().unwrap();
    assert!(f.target.path().exists());
}
#[cfg(unix)]
#[test]
fn symlink_cache_and_unknown_record_are_not_followed() {
    let f = Fixture::new();
    let lease = f.create();
    let cache = f.root.join("received").join(lease.record.cache_name());
    std::fs::remove_file(&cache).unwrap();
    let victim = f.root.join("victim");
    std::fs::write(&victim, b"keep").unwrap();
    std::os::unix::fs::symlink(&victim, &cache).unwrap();
    assert!(lease.open_cache().is_err());
    assert_eq!(std::fs::read(&victim).unwrap(), b"keep");
    drop(lease);
    let record = f
        .root
        .join("journal")
        .join(Registry::reservation_key(&f.source, &f.root.join("received"), "file.bin").unwrap())
        .join("record.json");
    std::fs::write(record, b"{}").unwrap();
    assert!(matches!(
        f.registry
            .claim(&f.source, &f.root.join("received"), "file.bin"),
        Err(Error::Invalid)
    ));
}
#[test]
fn manual_cleanup_respects_real_locks_and_default_cleanup_retains_pending_lease() {
    let f = Fixture::new();
    let lease = f.create();
    assert_eq!(f.registry.cleanup(128, true).unwrap().active, 1);
    let cache = f.root.join("received").join(lease.record.cache_name());
    drop(lease);
    assert_eq!(f.registry.cleanup(128, false).unwrap().retained, 1);
    assert!(cache.exists());
    let report = f.registry.cleanup(128, true).unwrap();
    assert_eq!(report.removed_records, 1);
    assert_eq!(report.removed_files, 1);
    assert!(!cache.exists());
    assert!(f
        .registry
        .claim(&f.source, &f.root.join("received"), "file.bin")
        .unwrap()
        .is_none());
}
#[test]
fn unknown_journal_file_is_not_recursively_deleted() {
    let f = Fixture::new();
    let lease = f.create();
    let unknown = f
        .root
        .join("journal")
        .join(Registry::reservation_key(&f.source, &f.root.join("received"), "file.bin").unwrap())
        .join("user-data");
    std::fs::write(&unknown, b"keep").unwrap();
    drop(lease);
    let report = f.registry.cleanup(128, true).unwrap();
    assert_eq!(report.removed_records, 0);
    assert_eq!(report.removed_files, 1);
    assert_eq!(report.retained, 1);
    assert_eq!(std::fs::read(unknown).unwrap(), b"keep");
}
#[test]
fn verified_resume_offset_requires_a_contiguous_prefix_not_total_record_bytes() {
    let mut f = Fixture::new();
    f.source.size = 2 * 1024 * 1024;
    let lease = f.create();
    let mut cache = download_cache::DownloadCache::create(
        lease.open_cache().unwrap(),
        lease.record.cache.clone(),
    )
    .unwrap();
    cache.commit_chunk(1, &vec![1; 1024 * 1024]).unwrap();
    drop(cache);
    assert!(matches!(lease.resume_cache(|_| true), Err(Error::Identity)));
}
#[test]
fn publication_reconciliation_rejects_same_inode_wrong_content_and_preserves_final() {
    let f = Fixture::new();
    let mut lease = f.create();
    let staging = f.root.join("received").join(lease.record.staging_name());
    let file = std::fs::OpenOptions::new()
        .read(true)
        .write(true)
        .create_new(true)
        .open(&staging)
        .unwrap();
    file.set_len(f.source.size).unwrap();
    lease.exporting(&file).unwrap();
    lease
        .publishing(&download_cache::ExportReceipt {
            bytes: f.source.size,
            sha256: f.source.sha256.clone(),
        })
        .unwrap();
    std::fs::rename(staging, f.target.path()).unwrap();
    assert!(matches!(
        lease.reconcile_published(|_| true),
        Err(Error::Identity)
    ));
    lease.discard().unwrap();
    assert!(f.target.path().exists());
}
#[test]
fn partial_export_can_be_rebuilt_only_from_owned_staging() {
    let f = Fixture::new();
    let mut lease = f.create();
    let staging = f.root.join("received").join(lease.record.staging_name());
    let file = std::fs::OpenOptions::new()
        .read(true)
        .write(true)
        .create_new(true)
        .open(&staging)
        .unwrap();
    lease.exporting(&file).unwrap();
    drop(file);
    lease.reset_export().unwrap();
    assert!(!staging.exists());
    assert!(lease.open_cache().is_ok());
}

#[test]
fn new_reservations_expire_after_one_hour_and_legacy_one_day_records_still_restore() {
    let f = Fixture::new();
    let lease = f.create();
    assert_eq!(
        lease.record.expires_unix_ms - lease.record.created_unix_ms,
        3_600_000
    );
    let mut record = lease.record.clone();
    let path = f
        .root
        .join("journal")
        .join(record.key())
        .join("record.json");
    drop(lease);
    // Preserve an already-issued legacy reservation's original deadline.
    record.expires_unix_ms = record.created_unix_ms + 86_400_000;
    let write = |record: &registry::Record| {
        let sha256 = crypto::hash::sha256_hex(&serde_json::to_vec(record).unwrap());
        std::fs::write(
            &path,
            serde_json::to_vec(&serde_json::json!({
                "version": 1, "value": record, "sha256": sha256,
            }))
            .unwrap(),
        )
        .unwrap();
    };
    write(&record);
    let restored = f
        .registry
        .claim(&f.source, &f.root.join("received"), "file.bin")
        .unwrap()
        .unwrap();
    assert_eq!(restored.record.expires_unix_ms, record.expires_unix_ms);
    drop(restored);
    // An arbitrary new duration is not accepted as a trusted reservation format.
    record.expires_unix_ms = record.created_unix_ms + 7_200_000;
    write(&record);
    assert!(matches!(
        f.registry
            .claim(&f.source, &f.root.join("received"), "file.bin"),
        Err(Error::Identity)
    ));
    // One-hour records actually expire, independent of day-based preferences.
    record.created_unix_ms -= 3_600_001;
    record.cache.created_unix_ms = record.created_unix_ms;
    record.expires_unix_ms = record.created_unix_ms + 3_600_000;
    write(&record);
    assert!(matches!(
        f.registry
            .claim(&f.source, &f.root.join("received"), "file.bin"),
        Err(Error::Expired)
    ));
}

#[test]
fn long_active_transfer_retention_never_renews_sender_authorization() {
    let f = Fixture::new();
    let mut lease = f.create();
    let original = lease.record.created_unix_ms;
    lease.record.created_unix_ms = original - 7_200_000;
    lease.record.cache.created_unix_ms = lease.record.created_unix_ms;
    lease.record.expires_unix_ms = lease.record.created_unix_ms + 3_600_000;
    let expiry = lease.record.expires_unix_ms;
    assert!(
        lease.valid_lease(),
        "An exclusive active writer must not be stopped by retention"
    );
    lease.suspend().unwrap();
    assert_eq!(
        lease.record.expires_unix_ms, expiry,
        "Activity must not extend advertised authorization"
    );
    drop(lease);
    assert!(matches!(
        f.registry
            .claim(&f.source, &f.root.join("received"), "file.bin"),
        Err(Error::Expired)
    ));
    let report = f.registry.cleanup(128, false).unwrap();
    assert_eq!(
        report.removed_files, 0,
        "Recently interrupted cache remains despite expired authorization"
    );
    assert_eq!(report.retained, 1);
}
