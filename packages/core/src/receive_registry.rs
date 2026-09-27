//! Persistent ownership of non-resumable native receive attempts. Never scan a
//! user's destination for '*.ls': cleanup visits only explicitly registered files.
use crate::{crypto::hash::sha256_hex, download_cache::CacheIdentity};
use cap_fs_ext::{FollowSymlinks, MetadataExt, OpenOptionsFollowExt};
use cap_std::fs::{Dir, Metadata, OpenOptions};
use serde::{Deserialize, Serialize};
use std::{
    collections::BTreeMap,
    fs::File,
    io::{self, Read, Write},
    path::{Path, PathBuf},
    sync::{
        Arc, Mutex, OnceLock, RwLock,
        atomic::{AtomicBool, Ordering},
    },
};

const RECORD_LIMIT: u64 = 64 * 1024;
const SCAN_LIMIT: usize = 4096;
static CURRENT: OnceLock<RwLock<Option<Arc<Registry>>>> = OnceLock::new();
static RETENTION: OnceLock<RwLock<RetentionPolicy>> = OnceLock::new();
const DAY_MS: u64 = 86_400_000;
static SINGLE_CLEANUP_DURABLE: AtomicBool = AtomicBool::new(false);
static SINGLE_INSPECT_DURABLE: AtomicBool = AtomicBool::new(false);

/// Local maintenance preference, not a resume capability or a wire setting.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum RetentionMode {
    #[default]
    Immediate,
    Days,
    Manual,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize)]
pub struct RetentionPolicy {
    pub mode: RetentionMode,
    pub days: Option<u32>,
}
impl RetentionPolicy {
    fn parse(mode: &str, days: Option<u32>) -> io::Result<Self> {
        let mode = match (mode, days) {
            ("immediate", None) => RetentionMode::Immediate,
            ("manual", None) => RetentionMode::Manual,
            ("days", Some(1..=3650)) => RetentionMode::Days,
            _ => {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidInput,
                    "Invalid receive retention policy",
                ));
            }
        };
        Ok(Self { mode, days })
    }
    fn retained_reason(self, registered: Option<u64>, now: Option<u64>) -> Option<&'static str> {
        match self.mode {
            RetentionMode::Immediate => None,
            RetentionMode::Manual => Some("retention_manual"),
            RetentionMode::Days => {
                let Some(registered) = registered else {
                    return Some("retention_age_unknown");
                };
                let Some(age) = now.and_then(|now| now.checked_sub(registered)) else {
                    return Some("retention_clock_unverified");
                };
                (age < u64::from(self.days.unwrap_or(3650)) * DAY_MS).then_some("retention_period")
            }
        }
    }
}

/// Apply a validated process preference before maintenance starts. The app owns
/// persistence. Invalid input leaves the previous policy unchanged. The write
/// lock waits for any previous maintenance batch to finish before returning.
pub fn configure_retention_policy(mode: &str, days: Option<u32>) -> io::Result<RetentionPolicy> {
    let policy = RetentionPolicy::parse(mode, days)?;
    *RETENTION
        .get_or_init(|| RwLock::new(RetentionPolicy::default()))
        .write()
        .map_err(|_| io::Error::other("Receive retention policy unavailable"))? = policy;
    Ok(policy)
}

/// Read back the effective process preference without touching cache files.
pub fn retention_policy() -> io::Result<RetentionPolicy> {
    RETENTION
        .get_or_init(|| RwLock::new(RetentionPolicy::default()))
        .read()
        .map(|policy| *policy)
        .map_err(|_| io::Error::other("Receive retention policy unavailable"))
}

fn unix_ms() -> Option<u64> {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .ok()
        .and_then(|elapsed| elapsed.as_millis().try_into().ok())
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Stamp {
    device: u64,
    inode: u64,
    created: Option<(u64, u32)>,
}
impl Stamp {
    fn of(meta: &Metadata) -> Self {
        Self {
            device: meta.dev(),
            inode: meta.ino(),
            created: meta
                .created()
                .ok()
                .and_then(|t| t.into_std().duration_since(std::time::UNIX_EPOCH).ok())
                .map(|t| (t.as_secs(), t.subsec_nanos())),
        }
    }
    fn verifiable(&self) -> bool {
        self.created.is_some()
    }
}

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Record {
    id: String,
    parent: PathBuf,
    parent_stamp: Stamp,
    file_stamp: Stamp,
    cache: CacheIdentity,
    // Only cache and export staging are permitted. No final destination path.
    export: bool,
    // Keep None absent when hashing old receipts: adding a null would invalidate
    // the checksum of records written before retention timestamps existed.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    registered_unix_ms: Option<u64>,
}
impl Record {
    fn name(&self) -> String {
        format!(
            ".legnasend-receive-{}.{}",
            self.cache.task_id,
            if self.export { "part" } else { "ls" }
        )
    }
    fn directory_upload(&self) -> bool {
        self.export
            && self.cache.version == "directory-upload-v1"
            && self
                .cache
                .source_id
                .strip_prefix("directory-upload:")
                .is_some_and(|source| {
                    source.split_once(':').is_some_and(|(id, generation)| {
                        uuid::Uuid::parse_str(id).is_ok()
                            && generation.parse::<u64>().is_ok_and(|value| value > 0)
                    })
                })
    }
    fn valid(&self) -> bool {
        uuid::Uuid::parse_str(&self.id).is_ok()
            && uuid::Uuid::parse_str(&self.cache.task_id).is_ok()
            && self.parent.is_absolute()
            && (self.cache.source_id.starts_with("localsend-v2:")
                || self.directory_upload()
                || (self
                    .cache
                    .source_id
                    .strip_prefix("legnasend-resume:")
                    .is_some_and(|id| uuid::Uuid::parse_str(id).is_ok())
                    && self.cache.resource_id.len() == 64
                    && self
                        .cache
                        .resource_id
                        .bytes()
                        .all(|b| b.is_ascii_hexdigit())
                    && self.cache.version.len() == 64
                    && self.cache.version.bytes().all(|b| b.is_ascii_hexdigit())
                    && self.cache.sha256.as_ref() == Some(&self.cache.version)))
    }
}
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Envelope {
    version: u32,
    record: Record,
    sha256: String,
}

pub(crate) struct Registry {
    dir: Dir,
    path: PathBuf,
    scan: Mutex<Option<cap_std::fs::ReadDir>>,
    inspection_scan: Mutex<Option<cap_std::fs::ReadDir>>,
    scoped_scans: Mutex<BTreeMap<(PathBuf, bool), (std::time::Instant, cap_std::fs::ReadDir)>>,
}
pub(crate) struct Registration {
    registry: Arc<Registry>,
    name: String,
    file: File,
}
impl Registration {
    /// Called only after the owned destination name has been unlinked or is gone.
    /// A changed registry entry is kept rather than deleting someone else's file.
    pub(crate) fn retire(&self) -> io::Result<()> {
        let current = self
            .registry
            .dir
            .open_with(&self.name, &read_options())?
            .into_std();
        if same_file::Handle::from_file(current)?
            != same_file::Handle::from_file(self.file.try_clone()?)?
        {
            return Err(io::Error::other("Receive registry entry changed"));
        }
        self.registry.dir.remove_file(&self.name)
    }
}

pub(crate) fn current() -> Option<Arc<Registry>> {
    CURRENT
        .get_or_init(|| RwLock::new(None))
        .read()
        .ok()
        .and_then(|r| r.clone())
}

/// Configure once per process, using private application support (not temp).
/// Opens only the registry; destination cleanup is a separate background action.
pub fn configure(directory: PathBuf) -> io::Result<()> {
    let registry = Arc::new(Registry::open(directory)?);
    let mut current = CURRENT
        .get_or_init(|| RwLock::new(None))
        .write()
        .map_err(|_| io::Error::other("Receive registry state unavailable"))?;
    if current.as_ref().is_some_and(|r| r.path != registry.path) {
        return Err(io::Error::other("Receive registry is already configured"));
    }
    let durable = registry.path.with_file_name(format!(
        "{}.resume",
        registry
            .path
            .file_name()
            .unwrap_or_default()
            .to_string_lossy()
    ));
    crate::receive_resume_registry::configure(&durable).map_err(io::Error::other)?;
    *current = Some(registry);
    Ok(())
}

/// One bounded diagnostic. IDs are opaque hashes of registry entry names;
/// private paths, peer identities and session credentials are never returned.
#[derive(Default, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CleanupEntry {
    pub id: String,
    pub file_name: Option<String>,
    pub source_kind: String,
    pub disposition: String,
    pub reason: String,
    pub planned_bytes: u64,
    pub unlinked_bytes: u64,
}

#[derive(Default, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CleanupReport {
    pub examined: u32,
    pub removed_files: u32,
    pub removed_records: u32,
    pub planned_bytes: u64,
    /// Logical lengths successfully unlinked, NOT a disk free-space claim.
    pub unlinked_bytes: u64,
    pub active: u32,
    pub retained: u32,
    pub failed: u32,
    pub budget_reached: bool,
    pub reasons: BTreeMap<String, u32>,
    pub entries: Vec<CleanupEntry>,
    pub inspection: bool,
    pub entries_truncated: bool,
    #[serde(skip)]
    last_reason: String,
}
impl CleanupReport {
    fn reason(&mut self, reason: &str) {
        *self.reasons.entry(reason.into()).or_default() += 1;
        self.last_reason = reason.into();
    }
}

/// Blocking, bounded metadata cleanup. Invoke on a worker, not the Flutter UI.
/// Invalid records/headers, missing identity support and changed files are kept.
pub fn cleanup(limit: usize) -> io::Result<CleanupReport> {
    scan_with_policy(limit, false, false)
}

/// Explicit local user cleanup: bypass only the retention period, never locks,
/// ownership, source validation or header checks. Automatic callers use cleanup.
pub fn cleanup_now(limit: usize) -> io::Result<CleanupReport> {
    scan_with_policy(limit, false, true)
}

/// Read-only eligibility inspection with its own bounded cursor. It holds the
/// same ownership/active locks as cleanup but never removes payload or records.
pub fn inspect(limit: usize) -> io::Result<CleanupReport> {
    scan_with_policy(limit, true, false)
}

/// Read-only preview for the explicit cleanup-now confirmation.
pub fn inspect_now(limit: usize) -> io::Result<CleanupReport> {
    scan_with_policy(limit, true, true)
}

/// Maintains only registered non-resumable attempts under a currently acquired
/// native coordinated root. Not an HTTP API: callers must retain the native
/// authorization through worker completion. Applies to both orphan attempts
/// and expired or explicitly discarded durable reservations.
pub fn maintain_in_scope(
    directory: PathBuf,
    limit: usize,
    inspection: bool,
    force: bool,
) -> io::Result<CleanupReport> {
    let registry =
        current().ok_or_else(|| io::Error::other("Receive registry is not configured"))?;
    let scope = crate::receive_scope_policy::CoordinatedRoot::open(&directory)?;
    let policy = RETENTION
        .get_or_init(|| RwLock::new(RetentionPolicy::default()))
        .read()
        .map_err(|_| io::Error::other("Receive retention policy unavailable"))?;
    let durable_budget = durable_scan_budget(limit, inspection);
    let mut report = registry.scan_scope(
        &scope,
        limit.saturating_sub(durable_budget),
        inspection,
        if force {
            RetentionPolicy::default()
        } else {
            *policy
        },
    )?;
    if let Some(durable) = crate::receive_resume_registry::current() {
        merge_durable_report(
            &mut report,
            durable.scan_in_scope(&scope, durable_budget, force, inspection),
            limit,
        );
    }
    Ok(report)
}

fn scan_with_policy(limit: usize, inspection: bool, force: bool) -> io::Result<CleanupReport> {
    let registry =
        current().ok_or_else(|| io::Error::other("Receive registry is not configured"))?;
    let policy = RETENTION
        .get_or_init(|| RwLock::new(RetentionPolicy::default()))
        .read()
        .map_err(|_| io::Error::other("Receive retention policy unavailable"))?;
    let durable_budget = durable_scan_budget(limit, inspection);
    let mut report = if limit == durable_budget {
        CleanupReport {
            inspection,
            ..Default::default()
        }
    } else {
        registry.scan_entries_at(
            limit.saturating_sub(durable_budget),
            inspection,
            if force {
                RetentionPolicy::default()
            } else {
                *policy
            },
            unix_ms(),
        )?
    };
    if let Some(durable) = crate::receive_resume_registry::current() {
        let result = if inspection {
            durable.inspect(durable_budget, force)
        } else {
            durable.cleanup(durable_budget, force)
        };
        merge_durable_report(&mut report, result, limit);
    }
    Ok(report)
}

fn durable_scan_budget(limit: usize, inspection: bool) -> usize {
    if limit == 1 {
        let turn = if inspection {
            &SINGLE_INSPECT_DURABLE
        } else {
            &SINGLE_CLEANUP_DURABLE
        };
        usize::from(turn.fetch_xor(true, Ordering::Relaxed))
    } else {
        limit.min(128) / 2
    }
}

fn merge_durable_report(
    report: &mut CleanupReport,
    result: Result<
        crate::receive_resume_registry::CleanupReport,
        crate::receive_resume_registry::Error,
    >,
    limit: usize,
) {
    match result {
        Ok(r) => {
            report.examined += r.examined;
            report.active += r.active;
            report.retained += r.retained;
            report.failed += r.failed;
            report.removed_files += r.removed_files;
            report.removed_records += r.removed_records;
            report.unlinked_bytes += r.unlinked_bytes;
            report.planned_bytes += r.planned_bytes;
            report.budget_reached |= r.budget_reached || limit == 1;
            let missing = r.examined.saturating_sub(r.entries.len() as u32);
            if missing > 0 {
                *report.reasons.entry("durable_resume".into()).or_default() += missing;
                report.entries_truncated = true;
            }
            for entry in &r.entries {
                *report.reasons.entry(entry.reason.clone()).or_default() += 1;
            }
            report.entries.extend(r.entries);
        }
        Err(crate::receive_resume_registry::Error::Busy) => {
            report.active += 1;
            report.budget_reached = true;
        }
        Err(error) => {
            report.failed += 1;
            *report
                .reasons
                .entry("durable_resume_failed".into())
                .or_default() += 1;
            tracing::warn!("Durable receive maintenance: {error}");
        }
    }
}

fn read_options() -> OpenOptions {
    let mut options = OpenOptions::new();
    options.read(true).write(true).follow(FollowSymlinks::No);
    options
}
impl Registry {
    pub(crate) fn open(path: PathBuf) -> io::Result<Self> {
        let path = std::path::absolute(path)?;
        match std::fs::symlink_metadata(&path) {
            Ok(meta) if meta.file_type().is_symlink() || !meta.is_dir() => {
                return Err(io::Error::other("Invalid receive registry directory"));
            }
            Ok(_) => {}
            Err(e) if e.kind() == io::ErrorKind::NotFound => {
                let mut builder = std::fs::DirBuilder::new();
                #[cfg(unix)]
                {
                    use std::os::unix::fs::DirBuilderExt;
                    builder.mode(0o700);
                }
                match builder.create(&path) {
                    Ok(()) => {}
                    Err(e) if e.kind() == io::ErrorKind::AlreadyExists => {}
                    Err(e) => return Err(e),
                }
            }
            Err(e) => return Err(e),
        }
        // Only a caller-selected application-support root is admitted.
        if std::fs::symlink_metadata(&path)?.file_type().is_symlink() {
            return Err(io::Error::other("Receive registry is a link"));
        }
        Ok(Self {
            dir: Dir::open_ambient_dir(&path, cap_std::ambient_authority())?,
            path,
            scan: Mutex::new(None),
            inspection_scan: Mutex::new(None),
            scoped_scans: Mutex::new(BTreeMap::new()),
        })
    }
    pub(crate) fn register(
        self: &Arc<Self>,
        parent: &Path,
        dir: &Dir,
        file: &File,
        cache: &CacheIdentity,
        export: bool,
    ) -> io::Result<Registration> {
        let id = uuid::Uuid::new_v4().to_string();
        let record = Record {
            id: id.clone(),
            parent: std::path::absolute(parent)?,
            parent_stamp: Stamp::of(&dir.dir_metadata()?),
            file_stamp: Stamp::of(&Metadata::from_file(file)?),
            cache: cache.clone(),
            export,
            registered_unix_ms: unix_ms(),
        };
        let durable_upload = record.directory_upload();
        let payload = serde_json::to_vec(&record)?;
        let bytes = serde_json::to_vec(&Envelope {
            version: 1,
            record,
            sha256: sha256_hex(&payload),
        })?;
        if bytes.len() > RECORD_LIMIT as usize {
            return Err(io::Error::other("Receive registry record too large"));
        }
        let name = format!("{id}.json");
        let mut options = read_options();
        options.create_new(true);
        #[cfg(unix)]
        {
            use cap_std::fs::OpenOptionsExt;
            options.mode(0o600);
        }
        let mut entry = self.dir.open_with(&name, &options)?.into_std();
        // Hold the registration lock through all writing, publication and cleanup.
        crate::file_lock::try_exclusive_strict(&entry).map_err(io::Error::other)?;
        entry.write_all(&bytes)?;
        entry.flush()?;
        // Crash reconciliation requires durable directory-upload ownership before body writes.
        // Preserve the native receive path without adding per-file forced sync overhead.
        if durable_upload {
            entry.sync_all()?;
            #[cfg(unix)]
            self.dir.try_clone()?.into_std_file().sync_all()?;
        }
        Ok(Registration {
            registry: self.clone(),
            name,
            file: entry,
        })
    }
    #[cfg(test)]
    pub(crate) fn cleanup(&self, limit: usize) -> io::Result<CleanupReport> {
        self.scan_entries(limit, false)
    }
    #[cfg(test)]
    fn scan_entries(&self, limit: usize, inspection: bool) -> io::Result<CleanupReport> {
        self.scan_entries_at(limit, inspection, RetentionPolicy::default(), unix_ms())
    }
    fn scan_entries_at(
        &self,
        limit: usize,
        inspection: bool,
        policy: RetentionPolicy,
        now: Option<u64>,
    ) -> io::Result<CleanupReport> {
        let mut report = CleanupReport {
            inspection,
            ..Default::default()
        };
        let mut scan = (if inspection {
            &self.inspection_scan
        } else {
            &self.scan
        })
        .lock()
        .map_err(|_| io::Error::other("Receive scan unavailable"))?;
        if scan.is_none() {
            *scan = Some(self.dir.entries()?);
        }
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(2);
        loop {
            if report.examined as usize >= limit.min(SCAN_LIMIT)
                || std::time::Instant::now() >= deadline
            {
                report.budget_reached = true;
                break;
            }
            let Some(entry) = scan.as_mut().unwrap().next() else {
                *scan = None;
                break;
            };
            report.examined += 1;
            let entry = match entry {
                Ok(e) => e,
                Err(_) => {
                    report.failed += 1;
                    report.reason("registry_entry_io");
                    report.entries.push(CleanupEntry {
                        id: sha256_hex(format!("scan-error-{}", uuid::Uuid::new_v4()).as_bytes()),
                        source_kind: "unknown".into(),
                        disposition: "failed".into(),
                        reason: "registry_entry_io".into(),
                        ..Default::default()
                    });
                    continue;
                }
            };
            let name = entry.file_name();
            let mut detail = CleanupEntry {
                id: sha256_hex(name.as_encoded_bytes()),
                source_kind: "unknown".into(),
                ..Default::default()
            };
            let before = (
                report.removed_files,
                report.removed_records,
                report.planned_bytes,
                report.unlinked_bytes,
                report.active,
                report.retained,
                report.failed,
            );
            let id = name
                .to_str()
                .and_then(|n| n.strip_suffix(".json"))
                .filter(|id| uuid::Uuid::parse_str(id).is_ok());
            if let Some(id) = id {
                if let Err(error) =
                    self.clean_one(&name, id, &mut report, &mut detail, policy, now, None)
                {
                    report.failed += 1;
                    report.reason(match error.kind() {
                        io::ErrorKind::PermissionDenied => "permission_denied",
                        _ => "storage_error",
                    });
                    tracing::warn!("Receive registry maintenance failed: {error}");
                }
            } else {
                report.retained += 1;
                report.reason("unknown_registry_entry");
            }
            detail.planned_bytes = report.planned_bytes.saturating_sub(before.2);
            detail.unlinked_bytes = report.unlinked_bytes.saturating_sub(before.3);
            detail.reason.clone_from(&report.last_reason);
            detail.disposition = if report.failed > before.6 {
                "failed"
            } else if report.active > before.4 {
                "active"
            } else if report.retained > before.5 {
                "retained"
            } else if report.removed_files > before.0 {
                "removed"
            } else if report.removed_records > before.1 {
                "retired"
            } else {
                "candidate"
            }
            .into();
            report.entries.push(detail);
        }
        Ok(report)
    }
    /// Routing reads only private index metadata; all deletion authority is
    /// rechecked under the original registration/file locks in clean_one.
    fn scan_scope(
        &self,
        scope: &crate::receive_scope_policy::CoordinatedRoot,
        limit: usize,
        inspection: bool,
        policy: RetentionPolicy,
    ) -> io::Result<CleanupReport> {
        let mut report = CleanupReport {
            inspection,
            ..Default::default()
        };
        if limit == 0 {
            return Ok(report);
        }
        let mut scans = self
            .scoped_scans
            .lock()
            .map_err(|_| io::Error::other("Receive scan unavailable"))?;
        let key = (scope.path().to_owned(), inspection);
        if !scans.contains_key(&key) {
            // At most 128 retained receive grants, independently inspect/clean.
            if scans.len() >= 256 {
                // Replaced/revoked grants must not permanently exhaust the cursor
                // budget. Eviction only restarts a bounded private-index scan.
                if let Some(oldest) = scans
                    .iter()
                    .min_by_key(|(_, (touched, _))| *touched)
                    .map(|(key, _)| key.clone())
                {
                    scans.remove(&oldest);
                }
            }
            scans.insert(
                key.clone(),
                (std::time::Instant::now(), self.dir.entries()?),
            );
        }
        let (touched, scan) = scans.get_mut(&key).unwrap();
        *touched = std::time::Instant::now();
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(2);
        let now = unix_ms();
        let mut finished = false;
        for _ in 0..limit.min(SCAN_LIMIT) {
            if std::time::Instant::now() >= deadline {
                break;
            }
            let Some(entry) = scan.next() else {
                finished = true;
                break;
            };
            let entry = match entry {
                Ok(entry) => entry,
                Err(_) => {
                    report.failed += 1;
                    report.reason("registry_entry_io");
                    continue;
                }
            };
            let name = entry.file_name();
            let Some(id) = name
                .to_str()
                .and_then(|n| n.strip_suffix(".json"))
                .filter(|id| uuid::Uuid::parse_str(id).is_ok())
            else {
                continue;
            };
            let routed = (|| -> io::Result<Option<Vec<u8>>> {
                if !self.dir.symlink_metadata(&name)?.is_file() {
                    return Ok(None);
                }
                // RDWR cannot wait for a FIFO writer if a private entry is
                // replaced after stat. Reject non-regular handles before reads.
                let file = self.dir.open_with(&name, &read_options())?;
                if !file.metadata()?.is_file() {
                    return Ok(None);
                }
                let mut bytes = Vec::new();
                file.take(RECORD_LIMIT + 1).read_to_end(&mut bytes)?;
                Ok(Some(bytes))
            })();
            let bytes = match routed {
                Ok(Some(bytes)) => bytes,
                Ok(None) => continue,
                Err(e) if e.kind() == io::ErrorKind::NotFound => continue,
                Err(_) => {
                    report.failed += 1;
                    report.reason("registry_entry_io");
                    continue;
                }
            };
            let matches = serde_json::from_slice::<Envelope>(&bytes)
                .ok()
                .is_some_and(|e| {
                    bytes.len() <= RECORD_LIMIT as usize
                        && e.version == 1
                        && e.record.id == id
                        && e.record.valid()
                        && scope.contains(&e.record.parent)
                        && serde_json::to_vec(&e.record).is_ok_and(|b| sha256_hex(&b) == e.sha256)
                });
            if !matches {
                continue;
            }
            report.examined += 1;
            let mut detail = CleanupEntry {
                id: sha256_hex(name.as_encoded_bytes()),
                source_kind: "unknown".into(),
                ..Default::default()
            };
            let before = (
                report.removed_files,
                report.removed_records,
                report.planned_bytes,
                report.unlinked_bytes,
                report.active,
                report.retained,
                report.failed,
            );
            if let Err(error) = self.clean_one(
                &name,
                id,
                &mut report,
                &mut detail,
                policy,
                now,
                Some(scope),
            ) {
                report.failed += 1;
                report.reason(if error.kind() == io::ErrorKind::PermissionDenied {
                    "permission_denied"
                } else {
                    "storage_error"
                });
            }
            detail.planned_bytes = report.planned_bytes.saturating_sub(before.2);
            detail.unlinked_bytes = report.unlinked_bytes.saturating_sub(before.3);
            detail.reason.clone_from(&report.last_reason);
            detail.disposition = if report.failed > before.6 {
                "failed"
            } else if report.active > before.4 {
                "active"
            } else if report.retained > before.5 {
                "retained"
            } else if report.removed_files > before.0 {
                "removed"
            } else if report.removed_records > before.1 {
                "retired"
            } else {
                "candidate"
            }
            .into();
            report.entries.push(detail);
        }
        report.budget_reached = !finished;
        if finished {
            scans.remove(&key);
        }
        Ok(report)
    }

    fn clean_one(
        &self,
        name: &std::ffi::OsStr,
        id: &str,
        report: &mut CleanupReport,
        detail: &mut CleanupEntry,
        policy: RetentionPolicy,
        now: Option<u64>,
        scope: Option<&crate::receive_scope_policy::CoordinatedRoot>,
    ) -> io::Result<()> {
        // Reject links and special files before opening (including FIFOs).
        if !self.dir.symlink_metadata(name)?.is_file() {
            report.retained += 1;
            report.reason("registry_not_regular");
            return Ok(());
        }
        let mut entry = self.dir.open_with(name, &read_options())?.into_std();
        match crate::file_lock::try_exclusive_strict(&entry) {
            Ok(()) => {}
            Err(std::fs::TryLockError::WouldBlock) => {
                report.active += 1;
                report.reason("active_registration");
                return Ok(());
            }
            Err(e) => return Err(io::Error::other(e)),
        }
        let mut bytes = Vec::new();
        (&mut entry)
            .take(RECORD_LIMIT + 1)
            .read_to_end(&mut bytes)?;
        let parsed = serde_json::from_slice::<Envelope>(&bytes).ok().filter(|e| {
            bytes.len() <= RECORD_LIMIT as usize
                && e.version == 1
                && e.record.id == id
                && e.record.valid()
                && serde_json::to_vec(&e.record).is_ok_and(|b| sha256_hex(&b) == e.sha256)
        });
        let Some(envelope) = parsed else {
            report.retained += 1;
            report.reason("invalid_registry_record");
            return Ok(());
        };
        let record = envelope.record;
        detail.file_name = Some(record.cache.file_name.chars().take(512).collect());
        detail.source_kind = if record.directory_upload() {
            "directoryUpload"
        } else {
            "nativeReceive"
        }
        .into();
        if scope.is_none()
            && crate::receive_scope_policy::requires_coordinated_access(&record.parent)
        {
            report.retained += 1;
            report.reason("external_scope_required");
            return Ok(());
        }
        let opened = match scope {
            Some(scope) => scope.open_parent(&record.parent),
            None => Dir::open_ambient_dir(&record.parent, cap_std::ambient_authority()),
        };
        let dir = match opened {
            Ok(d) => d,
            Err(e) if e.kind() == io::ErrorKind::NotFound => {
                report.retained += 1;
                report.reason("parent_unavailable");
                return Ok(());
            }
            Err(e) => return Err(e),
        };
        if !record.parent_stamp.verifiable()
            || !record.file_stamp.verifiable()
            || Stamp::of(&dir.dir_metadata()?) != record.parent_stamp
        {
            report.retained += 1;
            report.reason("parent_identity_unverified");
            return Ok(());
        }
        let target_name = record.name();
        match dir.symlink_metadata(&target_name) {
            Err(e) if e.kind() == io::ErrorKind::NotFound => {
                if !report.inspection {
                    self.retire_checked(name, &entry)?;
                    report.removed_records += 1;
                }
                report.reason("already_absent");
                return Ok(());
            }
            Err(e) => return Err(e),
            Ok(meta) if !meta.is_file() => {
                report.retained += 1;
                report.reason("target_not_regular");
                return Ok(());
            }
            Ok(_) => {}
        }
        let mut file = dir.open_with(&target_name, &read_options())?.into_std();
        if Stamp::of(&Metadata::from_file(&file)?) != record.file_stamp {
            report.retained += 1;
            report.reason("file_identity_changed");
            return Ok(());
        }
        match crate::file_lock::try_exclusive_strict(&file) {
            Ok(()) => {}
            Err(std::fs::TryLockError::WouldBlock) => {
                report.active += 1;
                report.reason("active_file");
                return Ok(());
            }
            Err(e) => return Err(io::Error::other(e)),
        }
        if !record.export && !cache_header_matches(&mut file, &record.cache)? {
            report.retained += 1;
            report.reason("cache_header_unverified");
            return Ok(());
        }
        // Apply age only after all existing safety checks. Directory-upload
        // staging has its own lifecycle and is not a native receive cache.
        if !record.directory_upload() {
            if let Some(reason) = policy.retained_reason(record.registered_unix_ms, now) {
                report.retained += 1;
                report.reason(reason);
                return Ok(());
            }
        }
        let size = file.metadata()?.len();
        report.planned_bytes = report.planned_bytes.saturating_add(size);
        // Reopen without following links and recheck immediately before unlink.
        let current = dir.open_with(&target_name, &read_options())?.into_std();
        if same_file::Handle::from_file(current)?
            != same_file::Handle::from_file(file.try_clone()?)?
        {
            report.retained += 1;
            report.reason("target_changed_during_cleanup");
            return Ok(());
        }
        if report.inspection {
            report.reason(if record.directory_upload() {
                "interrupted_directory_upload"
            } else {
                "non_resumable_receive_attempt"
            });
            return Ok(());
        }
        dir.remove_file(&target_name)?;
        report.removed_files += 1;
        report.unlinked_bytes = report.unlinked_bytes.saturating_add(size);
        report.reason(if record.directory_upload() {
            "interrupted_directory_upload"
        } else {
            "non_resumable_receive_attempt"
        });
        self.retire_checked(name, &entry)?;
        report.removed_records += 1;
        Ok(())
    }
    fn retire_checked(&self, name: &std::ffi::OsStr, entry: &File) -> io::Result<()> {
        let current = self.dir.open_with(name, &read_options())?.into_std();
        if same_file::Handle::from_file(current)?
            != same_file::Handle::from_file(entry.try_clone()?)?
        {
            return Err(io::Error::other(
                "Receive registry entry changed during cleanup",
            ));
        }
        self.dir.remove_file(name)
    }
}

fn cache_header_matches(file: &mut File, expected: &CacheIdentity) -> io::Result<bool> {
    let mut header = [0u8; 16];
    if let Err(e) = file.read_exact(&mut header) {
        return if e.kind() == io::ErrorKind::UnexpectedEof {
            Ok(false)
        } else {
            Err(e)
        };
    }
    let len = u32::from_le_bytes(header[12..16].try_into().unwrap()) as usize;
    if &header[..8] != b"LEGNALS\0"
        || u32::from_le_bytes(header[8..12].try_into().unwrap()) != 1
        || len == 0
        || len > 16384
    {
        return Ok(false);
    }
    let mut json = vec![0; len];
    let mut digest = [0u8; 32];
    if let Err(e) = file
        .read_exact(&mut json)
        .and_then(|_| file.read_exact(&mut digest))
    {
        return if e.kind() == io::ErrorKind::UnexpectedEof {
            Ok(false)
        } else {
            Err(e)
        };
    }
    let mut encoded = header.to_vec();
    encoded.extend(&json);
    Ok(crate::crypto::hash::sha256(&encoded).as_slice() == digest
        && serde_json::from_slice::<CacheIdentity>(&json).is_ok_and(|id| &id == expected))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::download_cache::{DownloadCache, MIN_CHUNK_SIZE};
    struct Fixture {
        root: PathBuf,
        destination: PathBuf,
        registry: Arc<Registry>,
    }
    impl Fixture {
        fn new() -> Self {
            let root = std::env::temp_dir()
                .join(format!("legnasend-registry-test-{}", uuid::Uuid::new_v4()));
            std::fs::create_dir(&root).unwrap();
            let destination = root.join("downloads 中文 %");
            std::fs::create_dir(&destination).unwrap();
            let registry = Arc::new(Registry::open(root.join("registry")).unwrap());
            Self {
                root,
                destination,
                registry,
            }
        }
        fn cleanup(&self) -> CleanupReport {
            self.scan(false)
        }
        fn inspect(&self) -> CleanupReport {
            self.scan(true)
        }
        fn scan(&self, inspection: bool) -> CleanupReport {
            // Like the app, continue a soft-budget batch. A busy test machine
            // may deschedule a worker beyond its wall-clock deadline.
            let mut all = CleanupReport {
                inspection,
                ..Default::default()
            };
            for _ in 0..16 {
                let batch = self.registry.scan_entries(100, inspection).unwrap();
                all.examined += batch.examined;
                all.removed_files += batch.removed_files;
                all.removed_records += batch.removed_records;
                all.planned_bytes += batch.planned_bytes;
                all.unlinked_bytes += batch.unlinked_bytes;
                all.active += batch.active;
                all.retained += batch.retained;
                all.failed += batch.failed;
                all.entries.extend(batch.entries);
                for (reason, count) in batch.reasons {
                    *all.reasons.entry(reason).or_default() += count;
                }
                if !batch.budget_reached {
                    return all;
                }
            }
            panic!("Fixture cleanup did not finish: {all:?}");
        }
        fn identity(&self) -> CacheIdentity {
            CacheIdentity {
                task_id: uuid::Uuid::new_v4().to_string(),
                source_id: "localsend-v2:approved".into(),
                resource_id: "resource".into(),
                version: "attempt".into(),
                file_name: "original.bin".into(),
                size: 4,
                chunk_size: MIN_CHUNK_SIZE,
                created_unix_ms: 0,
                sha256: None,
            }
        }
        fn create(&self, cache: &CacheIdentity, export: bool) -> (File, Registration, PathBuf) {
            let name = format!(
                ".legnasend-receive-{}.{}",
                cache.task_id,
                if export { "part" } else { "ls" }
            );
            let path = self.destination.join(&name);
            let file = std::fs::OpenOptions::new()
                .read(true)
                .write(true)
                .create_new(true)
                .open(&path)
                .unwrap();
            let dir =
                Dir::open_ambient_dir(&self.destination, cap_std::ambient_authority()).unwrap();
            let registration = self
                .registry
                .register(&self.destination, &dir, &file, cache, export)
                .unwrap();
            (file, registration, path)
        }
    }
    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.root);
        }
    }

    #[test]
    fn directory_upload_registration_is_export_only_and_never_accepts_arbitrary_sources() {
        let f = Fixture::new();
        let mut cache = f.identity();
        cache.source_id = format!("directory-upload:{}:1", uuid::Uuid::new_v4());
        cache.version = "directory-upload-v1".into();
        let (file, registration, path) = f.create(&cache, true);
        drop(file);
        drop(registration);
        let report = f.cleanup();
        assert_eq!(report.removed_files, 1, "{report:?}");
        assert!(!path.exists());
        cache.task_id = uuid::Uuid::new_v4().to_string();
        let (file, registration, path) = f.create(&cache, false);
        drop(file);
        drop(registration);
        let report = f.cleanup();
        assert_eq!(report.removed_files, 0);
        assert!(path.exists());
        cache.task_id = uuid::Uuid::new_v4().to_string();
        cache.source_id = "directory-upload:invalid:0".into();
        let (file, registration, path) = f.create(&cache, true);
        drop(file);
        drop(registration);
        assert_eq!(f.cleanup().removed_files, 0);
        assert!(path.exists());
    }

    #[test]
    fn registered_cache_and_partial_export_are_removed_but_final_and_user_ls_are_kept() {
        let f = Fixture::new();
        let id = f.identity();
        let (file, record, path) = f.create(&id, false);
        let mut cache = DownloadCache::create_receive_attempt(file, id.clone()).unwrap();
        cache.commit_chunk(0, b"data").unwrap();
        let (mut part, part_record, part_path) = f.create(&id, true);
        part.write_all(b"da").unwrap();
        std::fs::write(f.destination.join("original.bin"), b"published").unwrap();
        std::fs::write(f.destination.join("user.ls"), b"user").unwrap();
        let size = std::fs::metadata(&path).unwrap().len() + 2;
        drop((cache, record, part, part_record));
        let report = f.cleanup();
        assert_eq!(report.removed_files, 2);
        assert_eq!(report.removed_records, 2);
        assert_eq!(report.unlinked_bytes, size);
        assert_eq!(report.planned_bytes, size);
        assert!(!path.exists() && !part_path.exists());
        assert_eq!(
            std::fs::read(f.destination.join("original.bin")).unwrap(),
            b"published"
        );
        assert_eq!(
            std::fs::read(f.destination.join("user.ls")).unwrap(),
            b"user"
        );
        assert_eq!(f.cleanup().examined, 0);
    }
    #[test]
    fn live_registration_and_independent_file_writer_are_both_skipped() {
        let f = Fixture::new();
        let id = f.identity();
        let (file, record, path) = f.create(&id, false);
        let mut cache = DownloadCache::create_receive_attempt(file, id).unwrap();
        cache.commit_chunk(0, b"data").unwrap();
        let report = f.cleanup();
        assert_eq!(report.active, 1);
        assert!(path.exists());
        drop(record);
        let report = f.cleanup();
        assert_eq!(report.active, 1);
        assert_eq!(report.reasons["active_file"], 1);
        drop(cache);
        assert_eq!(f.cleanup().removed_files, 1);
    }
    #[test]
    fn matching_name_with_replaced_inode_is_retained() {
        let f = Fixture::new();
        let id = f.identity();
        let (mut file, record, path) = f.create(&id, true);
        file.write_all(b"owned").unwrap();
        std::fs::rename(&path, f.destination.join("moved.part")).unwrap();
        std::fs::write(&path, b"user replacement").unwrap();
        drop((file, record));
        let report = f.cleanup();
        assert_eq!(report.retained, 1, "{report:?}");
        assert_eq!(report.removed_files, 0);
        assert_eq!(std::fs::read(&path).unwrap(), b"user replacement");
        assert!(f.destination.join("moved.part").exists());
    }
    #[test]
    fn replaced_parent_directory_is_not_treated_as_the_registered_destination() {
        let f = Fixture::new();
        let id = f.identity();
        let (mut file, record, path) = f.create(&id, true);
        file.write_all(b"owned").unwrap();
        drop((file, record));
        std::fs::rename(&f.destination, f.root.join("moved-directory")).unwrap();
        std::fs::create_dir(&f.destination).unwrap();
        std::fs::write(&path, b"keep").unwrap();
        let report = f.cleanup();
        assert_eq!(report.retained, 1, "{report:?}");
        assert_eq!(report.reasons["parent_identity_unverified"], 1);
        assert_eq!(std::fs::read(path).unwrap(), b"keep");
    }
    #[test]
    fn corrupt_or_truncated_cache_header_is_retained_without_deleting_by_extension() {
        for bytes in [b"".as_slice(), b"LEGNALS\0", b"not a cache"] {
            let f = Fixture::new();
            let id = f.identity();
            let (mut file, record, path) = f.create(&id, false);
            file.write_all(bytes).unwrap();
            drop((file, record));
            let report = f.cleanup();
            assert_eq!(report.retained, 1, "{report:?}");
            assert_eq!(report.reasons["cache_header_unverified"], 1);
            assert!(path.exists());
        }
    }
    #[test]
    fn other_cache_identity_and_unknown_registry_metadata_are_preserved() {
        let f = Fixture::new();
        let id = f.identity();
        let (file, record, path) = f.create(&id, false);
        let mut changed = id.clone();
        changed.resource_id = "other resource".into();
        let cache = DownloadCache::create_receive_attempt(file, changed).unwrap();
        drop((cache, record));
        std::fs::write(
            f.registry
                .path
                .join(format!("{}.json", uuid::Uuid::new_v4())),
            b"{broken",
        )
        .unwrap();
        std::fs::write(f.registry.path.join("user-note"), b"keep").unwrap();
        let report = f.cleanup();
        assert_eq!(report.retained, 3);
        assert_eq!(report.removed_files, 0);
        assert!(path.exists());
    }
    #[test]
    fn stale_receipt_is_retired_after_publication_without_touching_the_final_file() {
        let f = Fixture::new();
        let id = f.identity();
        let (mut file, record, path) = f.create(&id, true);
        file.write_all(b"data").unwrap();
        let final_path = f.destination.join("published.bin");
        std::fs::rename(path, &final_path).unwrap();
        drop((file, record));
        let report = f.cleanup();
        assert_eq!(report.removed_records, 1);
        assert_eq!(report.removed_files, 0);
        assert_eq!(report.unlinked_bytes, 0);
        assert_eq!(std::fs::read(final_path).unwrap(), b"data");
    }
    #[test]
    fn missing_external_destination_is_retained_and_cleanup_is_bounded() {
        let f = Fixture::new();
        let id = f.identity();
        let (file, record, _) = f.create(&id, true);
        drop((file, record));
        std::fs::rename(&f.destination, f.root.join("disconnected")).unwrap();
        let report = f.cleanup();
        assert_eq!(report.retained, 1, "{report:?}");
        assert_eq!(report.reasons["parent_unavailable"], 1);
        for _ in 0..3 {
            std::fs::write(
                f.registry
                    .path
                    .join(format!("{}.json", uuid::Uuid::new_v4())),
                b"bad",
            )
            .unwrap();
        }
        let report = f.registry.cleanup(2).unwrap();
        assert_eq!(report.examined, 2);
        assert!(report.budget_reached);
        // Continue the cursor instead of revisiting retained records or skipping
        // the first entry after a batch boundary.
        let next = f.registry.cleanup(2).unwrap();
        assert_eq!(next.examined, 2);
        assert_eq!(next.retained, 2);
        assert!(next.budget_reached);
        let end = f.registry.cleanup(2).unwrap();
        assert_eq!(end.examined, 0);
        assert!(!end.budget_reached);
    }
    #[cfg(unix)]
    #[test]
    fn symlink_and_fifo_targets_or_registry_entries_are_never_followed() {
        let f = Fixture::new();
        let id = f.identity();
        let (file, record, path) = f.create(&id, true);
        drop((file, record));
        std::fs::remove_file(&path).unwrap();
        let external = f.root.join("external");
        std::fs::write(&external, b"keep").unwrap();
        std::os::unix::fs::symlink(&external, &path).unwrap();
        std::os::unix::fs::symlink(
            &external,
            f.registry
                .path
                .join(format!("{}.json", uuid::Uuid::new_v4())),
        )
        .unwrap();
        use std::ffi::CString;
        use std::os::unix::ffi::OsStrExt;
        let fifo = f
            .registry
            .path
            .join(format!("{}.json", uuid::Uuid::new_v4()));
        let c = CString::new(fifo.as_os_str().as_bytes()).unwrap();
        assert_eq!(unsafe { libc::mkfifo(c.as_ptr(), 0o600) }, 0);
        let report = f.cleanup();
        assert_eq!(report.retained, 3);
        assert_eq!(report.removed_files, 0);
        assert_eq!(std::fs::read(external).unwrap(), b"keep");
    }
    #[test]
    fn inspection_reports_verified_candidates_without_mutation_then_cleanup_reports_actual_unlinks()
    {
        let f = Fixture::new();
        let (mut file, record, path) = f.create(&f.identity(), true);
        file.write_all(b"owned partial bytes").unwrap();
        drop((file, record));
        let before = std::fs::read(&path).unwrap();
        let inspection = f.inspect();
        assert!(inspection.inspection);
        assert_eq!(inspection.removed_files, 0);
        assert_eq!(inspection.removed_records, 0);
        assert_eq!(inspection.unlinked_bytes, 0);
        assert_eq!(inspection.planned_bytes, before.len() as u64);
        assert_eq!(inspection.entries.len(), 1);
        let candidate = &inspection.entries[0];
        assert_eq!(candidate.disposition, "candidate");
        assert_eq!(candidate.file_name.as_deref(), Some("original.bin"));
        assert_eq!(candidate.source_kind, "nativeReceive");
        assert_eq!(candidate.id.len(), 64);
        assert_eq!(std::fs::read(&path).unwrap(), before);
        assert_eq!(std::fs::read_dir(&f.registry.path).unwrap().count(), 1);
        let serialized = serde_json::to_string(&inspection).unwrap();
        assert!(!serialized.contains(&f.destination.to_string_lossy().to_string()));
        assert!(!serialized.contains("localsend-v2:approved"));
        let cleanup = f.cleanup();
        assert_eq!(cleanup.entries[0].id, candidate.id);
        assert_eq!(cleanup.entries[0].disposition, "removed");
        assert_eq!(cleanup.entries[0].unlinked_bytes, before.len() as u64);
        assert!(!path.exists());
    }

    #[test]
    fn inspection_keeps_absent_receipts_until_explicit_cleanup() {
        let f = Fixture::new();
        let (file, record, path) = f.create(&f.identity(), true);
        drop((file, record));
        std::fs::remove_file(path).unwrap();
        let inspection = f.inspect();
        assert_eq!(inspection.entries[0].reason, "already_absent");
        assert_eq!(inspection.entries[0].disposition, "candidate");
        assert_eq!(inspection.removed_records, 0);
        assert_eq!(std::fs::read_dir(&f.registry.path).unwrap().count(), 1);
        let cleanup = f.cleanup();
        assert_eq!(cleanup.entries[0].disposition, "retired");
        assert_eq!(cleanup.removed_records, 1);
    }

    #[test]
    fn inspection_classifies_active_and_unknown_entries_without_exposing_unverified_names() {
        let f = Fixture::new();
        let (file, record, path) = f.create(&f.identity(), true);
        std::fs::write(
            f.registry.path.join("unknown-secret-name.txt"),
            b"user owned",
        )
        .unwrap();
        let inspection = f.inspect();
        assert_eq!(inspection.active, 1);
        assert_eq!(inspection.retained, 1);
        assert_eq!(inspection.entries.len(), 2);
        assert!(
            inspection
                .entries
                .iter()
                .all(|entry| entry.file_name.is_none())
        );
        assert!(inspection
            .entries
            .iter()
            .any(|entry| entry.disposition == "active" && entry.reason == "active_registration"));
        let encoded = serde_json::to_string(&inspection).unwrap();
        assert!(!encoded.contains("unknown-secret-name"));
        assert!(path.exists());
        drop((file, record));
    }

    #[test]
    fn bounded_inspection_cursor_does_not_consume_cleanup_cursor() {
        let f = Fixture::new();
        for _ in 0..3 {
            let (file, record, _) = f.create(&f.identity(), true);
            drop((file, record));
        }
        let inspection = f.registry.scan_entries(1, true).unwrap();
        assert!(inspection.budget_reached);
        assert_eq!(inspection.entries.len(), 1);
        assert_eq!(std::fs::read_dir(&f.destination).unwrap().count(), 3);
        let cleanup = f.cleanup();
        assert_eq!(cleanup.removed_files, 3);
        assert_eq!(cleanup.entries.len(), 3);
    }

    #[cfg(unix)]
    #[test]
    fn failed_unlink_reports_permission_and_planned_bytes_without_claiming_space_removed() {
        use std::os::unix::fs::PermissionsExt;
        let f = Fixture::new();
        let (mut file, record, path) = f.create(&f.identity(), true);
        file.write_all(b"owned").unwrap();
        drop((file, record));
        std::fs::set_permissions(&f.destination, std::fs::Permissions::from_mode(0o500)).unwrap();
        let report = f.cleanup();
        std::fs::set_permissions(&f.destination, std::fs::Permissions::from_mode(0o700)).unwrap();
        // Root on some CI runners bypasses filesystem permission bits.
        if report.removed_files == 1 {
            return;
        }
        assert_eq!(report.failed, 1);
        assert_eq!(report.planned_bytes, 5);
        assert_eq!(report.unlinked_bytes, 0);
        assert_eq!(report.entries[0].disposition, "failed");
        assert_eq!(report.entries[0].reason, "permission_denied");
        assert_eq!(report.entries[0].planned_bytes, 5);
        assert!(path.exists());
        assert_eq!(std::fs::read_dir(&f.registry.path).unwrap().count(), 1);
    }
    #[cfg(unix)]
    #[test]
    fn failed_record_retirement_keeps_successful_unlink_visible_in_the_same_entry() {
        use std::os::unix::fs::PermissionsExt;
        let f = Fixture::new();
        let (mut file, record, path) = f.create(&f.identity(), true);
        file.write_all(b"owned").unwrap();
        drop((file, record));
        std::fs::set_permissions(&f.registry.path, std::fs::Permissions::from_mode(0o500)).unwrap();
        let report = f.cleanup();
        std::fs::set_permissions(&f.registry.path, std::fs::Permissions::from_mode(0o700)).unwrap();
        if report.removed_records == 1 {
            return;
        } // Privileged CI may bypass mode bits.
        assert_eq!(report.failed, 1);
        assert_eq!(report.removed_files, 1);
        assert_eq!(report.unlinked_bytes, 5);
        assert_eq!(report.entries[0].disposition, "failed");
        assert_eq!(report.entries[0].planned_bytes, 5);
        assert_eq!(report.entries[0].unlinked_bytes, 5);
        assert!(!path.exists());
        assert_eq!(std::fs::read_dir(&f.registry.path).unwrap().count(), 1);
        assert_eq!(f.cleanup().entries[0].disposition, "retired");
    }

    fn stored_record(f: &Fixture, registration: &Registration) -> Envelope {
        serde_json::from_slice(&std::fs::read(f.registry.path.join(&registration.name)).unwrap())
            .unwrap()
    }
    fn retained_scan(
        f: &Fixture,
        policy: RetentionPolicy,
        now: Option<u64>,
        inspection: bool,
    ) -> CleanupReport {
        f.registry
            .scan_entries_at(100, inspection, policy, now)
            .unwrap()
    }

    #[test]
    fn retention_clock_boundaries_and_unknown_age_are_conservative() {
        let days = RetentionPolicy::parse("days", Some(7)).unwrap();
        let created = 1234;
        assert_eq!(
            days.retained_reason(Some(created), Some(created + 7 * DAY_MS - 1)),
            Some("retention_period")
        );
        assert_eq!(
            days.retained_reason(Some(created), Some(created + 7 * DAY_MS)),
            None
        );
        assert_eq!(
            days.retained_reason(Some(created), Some(created - 1)),
            Some("retention_clock_unverified")
        );
        assert_eq!(
            days.retained_reason(Some(created), None),
            Some("retention_clock_unverified")
        );
        assert_eq!(
            days.retained_reason(None, Some(u64::MAX)),
            Some("retention_age_unknown")
        );
        assert_eq!(RetentionPolicy::default().retained_reason(None, None), None);
        assert_eq!(
            RetentionPolicy::parse("manual", None)
                .unwrap()
                .retained_reason(Some(0), Some(u64::MAX)),
            Some("retention_manual")
        );
    }

    #[test]
    fn retention_configuration_is_validated_atomically_and_has_stable_json() {
        assert_eq!(retention_policy().unwrap(), RetentionPolicy::default());
        let policy = configure_retention_policy("days", Some(30)).unwrap();
        assert_eq!(
            serde_json::to_value(policy).unwrap(),
            serde_json::json!({"mode":"days","days":30})
        );
        for (mode, days) in [
            ("days", None),
            ("days", Some(0)),
            ("days", Some(3651)),
            ("manual", Some(1)),
            ("immediate", Some(0)),
            ("unknown", None),
        ] {
            assert!(configure_retention_policy(mode, days).is_err());
            assert_eq!(retention_policy().unwrap(), policy);
        }
        assert!(RetentionPolicy::parse("days", Some(3650)).is_ok());
        assert_eq!(
            serde_json::to_value(configure_retention_policy("manual", None).unwrap()).unwrap(),
            serde_json::json!({"mode":"manual","days":null})
        );
        configure_retention_policy("immediate", None).unwrap();
    }

    #[test]
    fn registered_timestamp_survives_reopen_and_days_expire_at_exact_boundary() {
        let f = Fixture::new();
        let before = unix_ms().unwrap();
        let (file, registration, path) = f.create(&f.identity(), true);
        let envelope = stored_record(&f, &registration);
        let registered = envelope.record.registered_unix_ms.unwrap();
        assert!((before..=unix_ms().unwrap()).contains(&registered));
        assert_eq!(
            envelope.record.cache.created_unix_ms, 0,
            "Never use peer/cache age as registry age"
        );
        drop((file, registration));
        let reopened = Registry::open(f.registry.path.clone()).unwrap();
        let policy = RetentionPolicy::parse("days", Some(1)).unwrap();
        let retained = reopened
            .scan_entries_at(100, false, policy, Some(registered + DAY_MS - 1))
            .unwrap();
        assert_eq!(retained.reasons["retention_period"], 1);
        assert_eq!(retained.planned_bytes, 0);
        assert!(path.exists());
        let inspection = reopened
            .scan_entries_at(100, true, policy, Some(registered + DAY_MS))
            .unwrap();
        assert_eq!(inspection.entries[0].disposition, "candidate");
        assert!(path.exists());
        assert_eq!(
            reopened
                .scan_entries_at(100, false, policy, Some(registered + DAY_MS))
                .unwrap()
                .removed_files,
            1
        );
        assert!(!path.exists());
    }

    #[test]
    fn old_receipt_checksum_is_unchanged_and_missing_age_is_not_inferred() {
        let f = Fixture::new();
        let (file, registration, path) = f.create(&f.identity(), true);
        let record_path = f.registry.path.join(&registration.name);
        let mut envelope = stored_record(&f, &registration);
        envelope.record.registered_unix_ms = None;
        let payload = serde_json::to_vec(&envelope.record).unwrap();
        assert!(!String::from_utf8_lossy(&payload).contains("registered_unix_ms"));
        envelope.sha256 = sha256_hex(&payload);
        drop((file, registration));
        std::fs::write(record_path, serde_json::to_vec(&envelope).unwrap()).unwrap();
        let policy = RetentionPolicy::parse("days", Some(1)).unwrap();
        let retained = retained_scan(&f, policy, Some(u64::MAX), false);
        assert_eq!(retained.reasons["retention_age_unknown"], 1);
        assert!(path.exists());
        assert_eq!(
            f.cleanup().removed_files,
            1,
            "Immediate keeps historical behavior for old receipts"
        );
    }

    #[test]
    fn manual_retention_preserves_verified_files_but_retires_absent_receipts() {
        let f = Fixture::new();
        let (mut file, registration, path) = f.create(&f.identity(), true);
        file.write_all(b"partial").unwrap();
        drop((file, registration));
        let policy = RetentionPolicy::parse("manual", None).unwrap();
        for inspection in [true, false] {
            let report = retained_scan(&f, policy, Some(u64::MAX), inspection);
            assert_eq!(report.entries[0].reason, "retention_manual");
            assert_eq!(report.entries[0].disposition, "retained");
            assert_eq!(report.planned_bytes, 0);
            assert!(path.exists());
        }
        assert_eq!(
            f.inspect().entries[0].disposition,
            "candidate",
            "Explicit now preview bypasses age only"
        );
        assert!(path.exists());
        std::fs::remove_file(path).unwrap();
        let report = retained_scan(&f, policy, None, false);
        assert_eq!(report.entries[0].reason, "already_absent");
        assert_eq!(report.removed_records, 1);
    }

    #[test]
    fn retention_never_masks_live_locks_invalid_headers_or_replaced_identity() {
        let f = Fixture::new();
        let identity = f.identity();
        let (file, registration, path) = f.create(&identity, false);
        let mut cache = DownloadCache::create_receive_attempt(file, identity).unwrap();
        cache.commit_chunk(0, b"data").unwrap();
        let policy = RetentionPolicy::parse("manual", None).unwrap();
        assert_eq!(
            retained_scan(&f, policy, None, false).reasons["active_registration"],
            1
        );
        drop(registration);
        assert_eq!(
            retained_scan(&f, policy, None, false).reasons["active_file"],
            1
        );
        drop(cache);
        assert_eq!(
            retained_scan(&f, policy, None, false).reasons["retention_manual"],
            1
        );
        std::fs::write(&path, b"broken header").unwrap();
        assert_eq!(
            retained_scan(&f, policy, None, false).reasons["cache_header_unverified"],
            1
        );
        std::fs::rename(&path, f.destination.join("original.ls")).unwrap();
        std::fs::write(&path, b"replacement").unwrap();
        assert_eq!(
            retained_scan(&f, policy, None, false).reasons["file_identity_changed"],
            1
        );
        assert_eq!(
            f.cleanup().removed_files,
            0,
            "Force immediate does not override identity"
        );
    }

    #[test]
    fn directory_upload_staging_does_not_inherit_native_retention() {
        let f = Fixture::new();
        let mut identity = f.identity();
        identity.source_id = format!("directory-upload:{}:1", uuid::Uuid::new_v4());
        identity.version = "directory-upload-v1".into();
        let (file, registration, path) = f.create(&identity, true);
        drop((file, registration));
        let report = retained_scan(
            &f,
            RetentionPolicy::parse("manual", None).unwrap(),
            None,
            false,
        );
        assert_eq!(report.removed_files, 1);
        assert_eq!(report.entries[0].reason, "interrupted_directory_upload");
        assert!(!path.exists());
    }
}

#[cfg(test)]
#[path = "receive_registry_scoped_tests.rs"]
mod scoped_tests;
