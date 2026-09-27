use super::*;
use crate::download_cache::{DownloadCache, MIN_CHUNK_SIZE};
use crate::receive_scope_policy::CoordinatedRoot;

struct Fixture {
    base: PathBuf,
    root: PathBuf,
    other: PathBuf,
    registry: Arc<Registry>,
}
impl Fixture {
    fn new() -> Self {
        let base =
            std::env::temp_dir().join(format!("ls-scoped-registry-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir(&base).unwrap();
        let base = std::fs::canonicalize(base).unwrap();
        let root = base.join("chosen");
        let other = base.join("chosen-other");
        std::fs::create_dir(&root).unwrap();
        std::fs::create_dir(&other).unwrap();
        let registry = Arc::new(Registry::open(base.join("private")).unwrap());
        Self {
            base,
            root,
            other,
            registry,
        }
    }
    fn create(&self, parent: &Path) -> (Registration, PathBuf) {
        std::fs::create_dir_all(parent).unwrap();
        let identity = CacheIdentity {
            task_id: uuid::Uuid::new_v4().to_string(),
            source_id: "localsend-v2:approved".into(),
            resource_id: "resource".into(),
            version: "attempt".into(),
            file_name: "source.bin".into(),
            size: 4,
            chunk_size: MIN_CHUNK_SIZE,
            created_unix_ms: 0,
            sha256: None,
        };
        let path = parent.join(format!(".legnasend-receive-{}.ls", identity.task_id));
        let file = std::fs::OpenOptions::new()
            .read(true)
            .write(true)
            .create_new(true)
            .open(&path)
            .unwrap();
        let dir = Dir::open_ambient_dir(parent, cap_std::ambient_authority()).unwrap();
        let registration = self
            .registry
            .register(parent, &dir, &file, &identity, false)
            .unwrap();
        let mut cache = DownloadCache::create(file, identity).unwrap();
        cache.commit_chunk(0, b"data").unwrap();
        drop(cache);
        (registration, path)
    }
    fn orphan(&self, parent: &Path) -> PathBuf {
        let (registration, path) = self.create(parent);
        drop(registration);
        path
    }
    fn scan(&self, root: &Path, inspection: bool, policy: RetentionPolicy) -> CleanupReport {
        self.registry
            .scan_scope(
                &CoordinatedRoot::open(root).unwrap(),
                100,
                inspection,
                policy,
            )
            .unwrap()
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.base);
    }
}

#[test]
fn scoped_cleanup_visits_registered_descendants_not_sibling_roots_or_user_files() {
    let f = Fixture::new();
    let a = f.orphan(&f.root);
    let b = f.orphan(&f.root.join("folder/deep"));
    let outside = f.orphan(&f.other);
    let outside_bytes = std::fs::read(&outside).unwrap();
    let user = f.root.join("user.ls");
    let guessed = f
        .root
        .join(format!(".legnasend-receive-{}.ls", uuid::Uuid::new_v4()));
    std::fs::write(&user, b"user data").unwrap();
    std::fs::write(&guessed, b"not registered").unwrap();
    let unknown = f
        .registry
        .path
        .join(format!("{}.json", uuid::Uuid::new_v4()));
    std::fs::write(&unknown, b"unknown registry data").unwrap();
    let bytes = std::fs::metadata(&a).unwrap().len() + std::fs::metadata(&b).unwrap().len();
    let report = f.scan(&f.root, false, RetentionPolicy::default());
    assert_eq!(report.examined, 2);
    assert_eq!(report.removed_files, 2);
    assert_eq!(report.removed_records, 2);
    assert_eq!(report.unlinked_bytes, bytes);
    assert_eq!(report.planned_bytes, bytes);
    assert_eq!(report.entries.len(), 2);
    assert!(!report.budget_reached);
    assert!(!a.exists() && !b.exists());
    assert_eq!(std::fs::read(outside).unwrap(), outside_bytes);
    assert_eq!(std::fs::read(user).unwrap(), b"user data");
    assert_eq!(std::fs::read(guessed).unwrap(), b"not registered");
    assert_eq!(std::fs::read(unknown).unwrap(), b"unknown registry data");
}

#[test]
fn scoped_inspection_has_its_own_cursor_and_never_mutates_candidates() {
    let f = Fixture::new();
    let paths: Vec<_> = (0..3).map(|_| f.orphan(&f.root)).collect();
    let before: Vec<_> = paths.iter().map(|p| std::fs::read(p).unwrap()).collect();
    let scope = CoordinatedRoot::open(&f.root).unwrap();
    let preview = f
        .registry
        .scan_scope(&scope, 1, true, RetentionPolicy::default())
        .unwrap();
    assert!(preview.inspection);
    assert!(preview.budget_reached);
    assert_eq!(preview.examined, 1);
    assert_eq!(preview.removed_files, 0);
    assert_eq!(preview.removed_records, 0);
    assert_eq!(preview.unlinked_bytes, 0);
    assert!(preview.planned_bytes > 0);
    for (path, bytes) in paths.iter().zip(&before) {
        assert_eq!(&std::fs::read(path).unwrap(), bytes);
    }
    let cleanup = f.scan(&f.root, false, RetentionPolicy::default());
    assert_eq!(cleanup.removed_files, 3);
    assert_eq!(
        cleanup.unlinked_bytes,
        before.iter().map(|b| b.len() as u64).sum::<u64>()
    );
}

#[test]
fn scoped_cleanup_preserves_active_registration_and_active_cache_writer() {
    let f = Fixture::new();
    let (registration, first) = f.create(&f.root);
    let second = f.orphan(&f.root);
    let writer = std::fs::OpenOptions::new()
        .read(true)
        .write(true)
        .open(&second)
        .unwrap();
    writer.try_lock().unwrap();
    let report = f.scan(&f.root, false, RetentionPolicy::default());
    assert_eq!(report.active, 2);
    assert_eq!(report.removed_files, 0);
    assert_eq!(report.reasons.get("active_registration"), Some(&1));
    assert_eq!(report.reasons.get("active_file"), Some(&1));
    assert!(first.exists() && second.exists());
    drop(writer);
    drop(registration);
    assert_eq!(
        f.scan(&f.root, false, RetentionPolicy::default())
            .removed_files,
        2
    );
}

#[test]
fn scoped_cleanup_respects_manual_and_age_retention_before_explicit_immediate_policy() {
    let f = Fixture::new();
    let file = f.orphan(&f.root);
    let before = std::fs::read(&file).unwrap();
    for (policy, reason) in [
        (
            RetentionPolicy {
                mode: RetentionMode::Manual,
                days: None,
            },
            "retention_manual",
        ),
        (
            RetentionPolicy {
                mode: RetentionMode::Days,
                days: Some(1),
            },
            "retention_period",
        ),
    ] {
        let report = f.scan(&f.root, false, policy);
        assert_eq!(report.retained, 1);
        assert_eq!(report.reasons.get(reason), Some(&1));
        assert_eq!(report.removed_files, 0);
        assert_eq!(std::fs::read(&file).unwrap(), before);
    }
    assert_eq!(
        f.scan(&f.root, false, RetentionPolicy::default())
            .removed_files,
        1
    );
}

#[test]
fn scoped_cleanup_rejects_replaced_parent_identity() {
    let f = Fixture::new();
    let parent = f.root.join("folder");
    let path = f.orphan(&parent);
    let old = f.root.join("old-folder");
    std::fs::rename(&parent, &old).unwrap();
    std::fs::create_dir(&parent).unwrap();
    std::fs::write(&path, b"replacement user file").unwrap();
    let report = f.scan(&f.root, false, RetentionPolicy::default());
    assert_eq!(report.retained, 1);
    assert_eq!(report.reasons.get("parent_identity_unverified"), Some(&1));
    assert_eq!(report.removed_files, 0);
    assert_eq!(std::fs::read(&path).unwrap(), b"replacement user file");
    assert!(old.join(path.file_name().unwrap()).exists());
}

#[cfg(unix)]
#[test]
fn scoped_cleanup_does_not_follow_replaced_descendant_symlinks() {
    let f = Fixture::new();
    let parent = f.root.join("folder");
    let path = f.orphan(&parent);
    let old = f.root.join("old-folder");
    std::fs::rename(&parent, &old).unwrap();
    let victim = f.other.join(path.file_name().unwrap());
    std::fs::write(&victim, b"external user file").unwrap();
    std::os::unix::fs::symlink(&f.other, &parent).unwrap();
    let report = f.scan(&f.root, false, RetentionPolicy::default());
    assert_eq!(report.removed_files, 0);
    assert_eq!(report.failed + report.retained, 1);
    assert_eq!(std::fs::read(victim).unwrap(), b"external user file");
    assert!(old.join(path.file_name().unwrap()).exists());
}

#[test]
fn scoped_cursor_is_bounded_and_reaches_candidates_among_other_roots() {
    let f = Fixture::new();
    let wanted: Vec<_> = (0..7).map(|_| f.orphan(&f.root)).collect();
    let others: Vec<_> = (0..5).map(|_| f.orphan(&f.other)).collect();
    let scope = CoordinatedRoot::open(&f.root).unwrap();
    let zero = f
        .registry
        .scan_scope(&scope, 0, false, RetentionPolicy::default())
        .unwrap();
    assert_eq!(zero.examined, 0);
    assert!(!zero.budget_reached);
    assert!(f.registry.scoped_scans.lock().unwrap().is_empty());
    let mut removed = 0;
    let mut finished = false;
    for _ in 0..20 {
        let report = f
            .registry
            .scan_scope(&scope, 1, false, RetentionPolicy::default())
            .unwrap();
        assert!(report.examined <= 1 && report.entries.len() <= 1);
        removed += report.removed_files;
        if !report.budget_reached {
            finished = true;
            break;
        }
    }
    assert!(finished);
    assert_eq!(removed, 7);
    assert!(wanted.iter().all(|path| !path.exists()));
    assert!(others.iter().all(|path| path.exists()));
    assert!(f.registry.scoped_scans.lock().unwrap().is_empty());
    assert_eq!(
        f.scan(&f.other, false, RetentionPolicy::default())
            .removed_files,
        5
    );
}

#[test]
fn coordinated_root_rejects_relative_traversal_root_and_symlink_inputs() {
    let f = Fixture::new();
    for path in [
        PathBuf::from("relative"),
        PathBuf::from("/"),
        f.root.join("../chosen-other"),
    ] {
        assert!(CoordinatedRoot::open(&path).is_err());
    }
    let scope = CoordinatedRoot::open(&f.root).unwrap();
    assert!(scope.contains(&f.root));
    assert!(scope.contains(&f.root.join("nested/child")));
    assert!(!scope.contains(&f.other));
    assert!(!scope.contains(&f.root.join("nested/../outside")));
    assert!(scope.open_parent(&f.other).is_err());
    #[cfg(unix)]
    {
        let link = f.base.join("root-link");
        std::os::unix::fs::symlink(&f.root, &link).unwrap();
        assert!(CoordinatedRoot::open(&link).is_err());
    }
}

#[test]
fn durable_scan_details_keep_identity_and_actual_removal_counts() {
    let mut report = CleanupReport::default();
    merge_durable_report(
        &mut report,
        Ok(crate::receive_resume_registry::CleanupReport {
            examined: 2,
            retained: 1,
            removed_files: 1,
            removed_records: 1,
            unlinked_bytes: 42,
            planned_bytes: 42,
            entries: vec![
                CleanupEntry {
                    id: "a".repeat(64),
                    source_kind: "nativeReceive".into(),
                    disposition: "retained".into(),
                    reason: "durable_resume".into(),
                    ..Default::default()
                },
                CleanupEntry {
                    id: "b".repeat(64),
                    source_kind: "nativeReceive".into(),
                    disposition: "removed".into(),
                    reason: "durable_resume".into(),
                    planned_bytes: 42,
                    unlinked_bytes: 42,
                    ..Default::default()
                },
            ],
            ..Default::default()
        }),
        64,
    );
    assert_eq!(
        (
            report.examined,
            report.retained,
            report.removed_files,
            report.unlinked_bytes
        ),
        (2, 1, 1, 42)
    );
    assert_eq!(report.entries.len(), 2);
    assert_eq!(report.entries[1].id, "b".repeat(64));
    assert!(!report.entries_truncated);
    assert_eq!(report.reasons["durable_resume"], 2);
}

#[test]
fn missing_durable_details_are_not_invented_or_silently_counted_as_complete() {
    let mut report = CleanupReport::default();
    merge_durable_report(
        &mut report,
        Ok(crate::receive_resume_registry::CleanupReport {
            examined: 1,
            retained: 1,
            ..Default::default()
        }),
        64,
    );
    assert!(report.entries_truncated);
    assert!(report.entries.is_empty());
    assert_eq!(report.examined, 1);
    assert_eq!(report.reasons["durable_resume"], 1);
}
