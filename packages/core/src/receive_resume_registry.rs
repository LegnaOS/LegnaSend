//! Durable, host-owned native receive reservations. Wire tokens are never stored.
//! Blocking filesystem calls belong on a bounded worker. This registry is not
//! authorization: the caller must first approve a new original-v2 session.
use crate::{crypto::hash::sha256_hex, download_cache::CacheIdentity};
use cap_fs_ext::{DirExt, FollowSymlinks, MetadataExt, OpenOptionsFollowExt};
use cap_std::fs::{Dir, Metadata, OpenOptions};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{
    fs::{File, TryLockError},
    io::{self, Read, Write},
    path::{Path, PathBuf},
    sync::{Arc, Mutex, OnceLock, RwLock},
};
#[cfg(not(target_vendor = "apple"))]
use {cap_std::ambient_authority, std::path::Component};

pub(crate) const LEASE_MS: u64 = 86_400_000;
pub(crate) const MAX_RECORDS: usize = 128;
const MAX_JSON: u64 = 64 * 1024;
pub(crate) const BLOCK: u32 = 1024 * 1024;
#[derive(Debug, thiserror::Error)]
pub(crate) enum Error {
    #[error("durable-resume-invalid")]
    Invalid,
    #[error("durable-resume-identity-mismatch")]
    Identity,
    #[error("durable-resume-busy")]
    Busy,
    #[error("durable-resume-expired")]
    Expired,
    #[error("durable-resume-capacity")]
    Capacity,
    #[error(transparent)]
    Io(#[from] io::Error),
    #[error(transparent)]
    Cache(#[from] crate::download_cache::CacheError),
}
#[path = "receive_source_end.rs"]
mod source_end;
pub(crate) use source_end::SourceEndPreflight;

type Result<T> = std::result::Result<T, Error>;
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(tag = "kind", rename_all = "camelCase", deny_unknown_fields)]
pub(crate) enum Peer {
    Certificate { sha256: String },
    Http { address: String },
}
impl Peer {
    fn valid(&self) -> bool {
        match self {
            Self::Certificate { sha256 } => strong(sha256),
            Self::Http { address } => address.split_once('%').map_or_else(
                || address.parse::<std::net::IpAddr>().is_ok(),
                |(ip, scope)| {
                    ip.parse::<std::net::Ipv6Addr>().is_ok()
                        && scope.parse::<u32>().is_ok_and(|s| s > 0)
                },
            ),
        }
    }
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct Source {
    pub(crate) resume_key: String,
    pub(crate) peer: Peer,
    pub(crate) sha256: String,
    pub(crate) size: u64,
}
impl Source {
    pub(crate) fn valid(&self) -> bool {
        uuid::Uuid::parse_str(&self.resume_key).is_ok_and(|id| id.to_string() == self.resume_key)
            && self.peer.valid()
            && strong(&self.sha256)
            && self.size >= u64::from(BLOCK)
            && self.size.div_ceil(u64::from(BLOCK)) <= crate::download_cache::MAX_CHUNKS
    }
    pub(crate) fn key(&self) -> String {
        sha256_hex(&serde_json::to_vec(&(&self.peer, &self.resume_key)).unwrap())
    }
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub(crate) struct Stamp {
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
                .and_then(|v| v.into_std().duration_since(std::time::UNIX_EPOCH).ok())
                .map(|d| (d.as_secs(), d.subsec_nanos())),
        }
    }
    fn valid(&self) -> bool {
        self.created.is_some()
    }
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct Target {
    approved_root: PathBuf,
    approved_stamp: Stamp,
    requested_name: String,
    parent: PathBuf,
    final_name: String,
    parent_stamp: Stamp,
}
impl Target {
    /// Both paths come from this newly approved local save configuration, never HTTP.
    pub(crate) fn new(
        approved_root: &Path,
        requested_name: &str,
        final_path: &Path,
    ) -> Result<Self> {
        if !relative(requested_name) || !approved_root.is_absolute() || !final_path.is_absolute() {
            return Err(Error::Invalid);
        }
        let approved_root = std::fs::canonicalize(approved_root)?;
        let approved_stamp = Stamp::of(&open_directory(&approved_root)?.dir_metadata()?);
        if !approved_stamp.valid() {
            return Err(Error::Identity);
        }
        let parent = std::fs::canonicalize(final_path.parent().ok_or(Error::Invalid)?)?;
        if !parent.starts_with(&approved_root) {
            return Err(Error::Identity);
        }
        let final_name = final_path
            .file_name()
            .and_then(|s| s.to_str())
            .filter(|s| component(s))
            .ok_or(Error::Invalid)?
            .to_owned();
        let dir = open_directory(&parent)?;
        let parent_stamp = Stamp::of(&dir.dir_metadata()?);
        if !parent_stamp.valid() {
            return Err(Error::Identity);
        }
        Ok(Self {
            approved_root,
            approved_stamp,
            requested_name: requested_name.into(),
            parent,
            final_name,
            parent_stamp,
        })
    }
    pub(crate) fn path(&self) -> PathBuf {
        self.parent.join(&self.final_name)
    }
    fn directory(&self) -> Result<Dir> {
        if Stamp::of(&open_directory(&self.approved_root)?.dir_metadata()?) != self.approved_stamp {
            return Err(Error::Identity);
        }
        let dir = open_directory(&self.parent)?;
        if Stamp::of(&dir.dir_metadata()?) != self.parent_stamp {
            return Err(Error::Identity);
        }
        Ok(dir)
    }
    fn directory_in_scope(
        &self,
        scope: &crate::receive_scope_policy::CoordinatedRoot,
    ) -> Result<Dir> {
        let approved = scope.open_parent(&self.approved_root)?;
        if Stamp::of(&approved.dir_metadata()?) != self.approved_stamp {
            return Err(Error::Identity);
        }
        let dir = scope.open_parent(&self.parent)?;
        if Stamp::of(&dir.dir_metadata()?) != self.parent_stamp {
            return Err(Error::Identity);
        }
        Ok(dir)
    }
    fn approved(&self, root: &Path, name: &str) -> Result<bool> {
        Ok(std::fs::canonicalize(root)? == self.approved_root && name == self.requested_name)
    }
    fn valid(&self) -> bool {
        self.approved_root.is_absolute()
            && self.approved_stamp.valid()
            && self.parent.is_absolute()
            && self.parent.starts_with(&self.approved_root)
            && relative(&self.requested_name)
            && component(&self.final_name)
            && self.parent_stamp.valid()
    }
}
#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct Record {
    pub(crate) source: Source,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    source_end: Option<source_end::Reference>,
    pub(crate) receipt_id: String,
    pub(crate) target: Target,
    pub(crate) cache: CacheIdentity,
    cache_stamp: Stamp,
    pub(crate) created_unix_ms: u64,
    pub(crate) expires_unix_ms: u64,
}
impl Record {
    fn valid(&self) -> bool {
        self.source.valid()
            && uuid::Uuid::parse_str(&self.receipt_id)
                .is_ok_and(|id| id.to_string() == self.receipt_id)
            && self.target.valid()
            && self.cache_stamp.valid()
            && uuid::Uuid::parse_str(&self.cache.task_id).is_ok()
            && self.cache.source_id
                == format!(
                    "legnasend-durable-v1:{}",
                    sha256_hex(&serde_json::to_vec(&self.source.peer).unwrap())
                )
            && self.cache.resource_id == self.source.key()
            && self.cache.version == self.source.sha256
            && self.cache.sha256.as_ref() == Some(&self.source.sha256)
            && self.cache.size == self.source.size
            && self.cache.chunk_size == BLOCK
            && self.cache.file_name == self.target.final_name
            && self.cache.created_unix_ms == self.created_unix_ms
            && self.expires_unix_ms.checked_sub(self.created_unix_ms) == Some(LEASE_MS)
    }
    pub(crate) fn key(&self) -> String {
        sha256_hex(
            &serde_json::to_vec(&(
                &self.source.key(),
                &self.target.approved_root,
                &self.target.approved_stamp,
                &self.target.requested_name,
            ))
            .unwrap(),
        )
    }
    pub(crate) fn cache_name(&self) -> String {
        format!(".legnasend-receive-{}.ls", self.cache.task_id)
    }
    pub(crate) fn staging_name(&self) -> String {
        format!(".legnasend-receive-{}.part", self.cache.task_id)
    }
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(tag = "phase", rename_all = "camelCase", deny_unknown_fields)]
pub(crate) enum State {
    Receiving,
    Suspended,
    Exporting {
        staging_stamp: Stamp,
    },
    Publishing {
        staging_stamp: Stamp,
    },
    Published {
        final_stamp: Stamp,
        completed_unix_ms: u64,
    },
    Discarded {
        staging_stamp: Option<Stamp>,
    },
}
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Envelope<T> {
    version: u32,
    value: T,
    sha256: String,
}
fn encoded<T: Serialize>(value: &T) -> Result<Vec<u8>> {
    let data = serde_json::to_vec(value).map_err(|_| Error::Invalid)?;
    let bytes = serde_json::to_vec(&Envelope {
        version: 1,
        value,
        sha256: sha256_hex(&data),
    })
    .map_err(|_| Error::Invalid)?;
    if bytes.len() > MAX_JSON as usize {
        return Err(Error::Invalid);
    }
    Ok(bytes)
}
fn decode<T: serde::de::DeserializeOwned + Serialize>(dir: &Dir, name: &str) -> Result<T> {
    let mut file = open_file(dir, name, false)?;
    let mut bytes = Vec::new();
    (&mut file).take(MAX_JSON + 1).read_to_end(&mut bytes)?;
    let e: Envelope<T> = serde_json::from_slice(&bytes).map_err(|_| Error::Invalid)?;
    if bytes.len() > MAX_JSON as usize
        || e.version != 1
        || sha256_hex(&serde_json::to_vec(&e.value).map_err(|_| Error::Invalid)?) != e.sha256
    {
        return Err(Error::Invalid);
    }
    Ok(e.value)
}
fn atomic<T: Serialize>(dir: &Dir, name: &str, value: &T) -> Result<()> {
    let bytes = encoded(value)?;
    let temp = format!("writing-{}", uuid::Uuid::new_v4());
    let mut options = options();
    options.create_new(true);
    let mut file = dir.open_with(&temp, &options)?.into_std();
    let result = (|| {
        file.write_all(&bytes)?;
        file.sync_all()?;
        dir.rename(&temp, dir, name)?;
        sync_dir(dir)?;
        Ok::<_, io::Error>(())
    })();
    if result.is_err() {
        let _ = dir.remove_file(&temp);
    }
    result?;
    Ok(())
}
fn sync_dir(dir: &Dir) -> io::Result<()> {
    #[cfg(unix)]
    {
        dir.try_clone()?.into_std_file().sync_all()?;
    }
    Ok(())
}
fn options() -> OpenOptions {
    let mut o = OpenOptions::new();
    o.read(true).write(true).follow(FollowSymlinks::No);
    #[cfg(unix)]
    {
        use cap_std::fs::OpenOptionsExt;
        o.mode(0o600);
    }
    o
}
fn open_file(dir: &Dir, name: &str, create: bool) -> Result<File> {
    if let Ok(meta) = dir.symlink_metadata(name) {
        if !meta.is_file() {
            return Err(Error::Identity);
        }
    }
    let mut o = options();
    o.create(create);
    let file = dir.open_with(name, &o)?.into_std();
    if !file.metadata()?.is_file() {
        return Err(Error::Identity);
    }
    Ok(file)
}
fn lock(file: &File) -> Result<()> {
    crate::file_lock::try_exclusive_strict(file).map_err(|e| match e {
        TryLockError::WouldBlock => Error::Busy,
        other => Error::Io(io::Error::other(other)),
    })
}
fn component(v: &str) -> bool {
    !v.is_empty()
        && v.len() <= 4096
        && !matches!(v, "." | "..")
        && !v.contains(['/', '\\', ':'])
        && !v.chars().any(char::is_control)
}
fn relative(v: &str) -> bool {
    v.len() <= 4096 && !v.is_empty() && v.split('/').all(component)
}
fn strong(v: &str) -> bool {
    v.len() == 64 && v.bytes().all(|b| b.is_ascii_hexdigit())
}
#[cfg(target_vendor = "apple")]
fn open_directory(path: &Path) -> Result<Dir> {
    let root = crate::receive_scope_policy::CoordinatedRoot::open(path)?;
    Ok(root.open_parent(path)?)
}
#[cfg(not(target_vendor = "apple"))]
fn open_directory(path: &Path) -> Result<Dir> {
    if !path.is_absolute() {
        return Err(Error::Invalid);
    }
    let mut anchor = PathBuf::new();
    let mut components = Vec::new();
    for part in path.components() {
        match part {
            Component::Prefix(_) | Component::RootDir => anchor.push(part.as_os_str()),
            Component::Normal(v) => components.push(v),
            _ => return Err(Error::Invalid),
        }
    }
    let mut dir = Dir::open_ambient_dir(anchor, ambient_authority())?;
    for name in components {
        dir = dir.open_dir_nofollow(name)?;
    }
    Ok(dir)
}
fn now_ms() -> Result<u64> {
    u64::try_from(
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_err(|_| Error::Invalid)?
            .as_millis(),
    )
    .map_err(|_| Error::Invalid)
}

static CURRENT: OnceLock<RwLock<Option<Arc<Registry>>>> = OnceLock::new();
pub(crate) fn current() -> Option<Arc<Registry>> {
    CURRENT
        .get_or_init(|| RwLock::new(None))
        .read()
        .ok()?
        .clone()
}
pub(crate) fn configure(path: &Path) -> Result<()> {
    match std::fs::symlink_metadata(path) {
        Ok(meta) if !meta.is_dir() || meta.file_type().is_symlink() => return Err(Error::Identity),
        Ok(_) => {}
        Err(e) if e.kind() == io::ErrorKind::NotFound => {
            let mut builder = std::fs::DirBuilder::new();
            #[cfg(unix)]
            {
                use std::os::unix::fs::DirBuilderExt;
                builder.mode(0o700);
            }
            builder.create(path)?;
        }
        Err(e) => return Err(e.into()),
    }
    let registry = Registry::open(path)?;
    *CURRENT
        .get_or_init(|| RwLock::new(None))
        .write()
        .map_err(|_| Error::Busy)? = Some(registry);
    Ok(())
}
pub(crate) struct Registry {
    dir: Dir,
    cleanup_cursor: Mutex<Option<cap_std::fs::ReadDir>>,
    inspect_cursor: Mutex<Option<cap_std::fs::ReadDir>>,
    scoped_cursors: Mutex<Vec<(PathBuf, bool, Option<cap_std::fs::ReadDir>)>>,
}
pub(crate) struct Lease {
    registry_dir: Dir,
    directory: Dir,
    _lock: File,
    pub(crate) record: Record,
    pub(crate) state: State,
}
impl Registry {
    /// Caller creates the private application-support directory before use.
    pub(crate) fn open(path: &Path) -> Result<Arc<Self>> {
        if std::fs::symlink_metadata(path)?.file_type().is_symlink() {
            return Err(Error::Identity);
        }
        Ok(Arc::new(Self {
            dir: open_directory(&std::fs::canonicalize(path)?)?,
            cleanup_cursor: Mutex::new(None),
            inspect_cursor: Mutex::new(None),
            scoped_cursors: Mutex::new(Vec::new()),
        }))
    }
    fn index_lock(&self) -> Result<File> {
        let file = open_file(&self.dir, ".index.lock", true)?;
        lock(&file)?;
        Ok(file)
    }
    pub(crate) fn reservation_key(
        source: &Source,
        root: &Path,
        requested_name: &str,
    ) -> Result<String> {
        if !source.valid() || !relative(requested_name) {
            return Err(Error::Invalid);
        }
        let root = std::fs::canonicalize(root)?;
        let stamp = Stamp::of(&open_directory(&root)?.dir_metadata()?);
        if !stamp.valid() {
            return Err(Error::Identity);
        }
        Ok(sha256_hex(
            &serde_json::to_vec(&(source.key(), root, stamp, requested_name))
                .map_err(|_| Error::Invalid)?,
        ))
    }
    pub(crate) fn identity(source: &Source, target: &Target, now: u64) -> Result<CacheIdentity> {
        if !source.valid() || !target.valid() {
            return Err(Error::Invalid);
        }
        Ok(CacheIdentity {
            task_id: uuid::Uuid::new_v4().to_string(),
            source_id: format!(
                "legnasend-durable-v1:{}",
                sha256_hex(&serde_json::to_vec(&source.peer).unwrap())
            ),
            resource_id: source.key(),
            version: source.sha256.clone(),
            file_name: target.final_name.clone(),
            size: source.size,
            chunk_size: BLOCK,
            created_unix_ms: now,
            sha256: Some(source.sha256.clone()),
        })
    }
    pub(crate) fn create(
        &self,
        source: Source,
        target: Target,
        cache: CacheIdentity,
        file: &File,
        receipt_id: String,
    ) -> Result<Lease> {
        let _index = self.index_lock()?;
        let mut count = 0;
        for entry in self.dir.entries()? {
            let entry = entry?;
            if entry.file_name() == ".index.lock" || entry.file_name() == ".source-end" {
                continue;
            }
            count += 1;
            if count >= MAX_RECORDS {
                return Err(Error::Capacity);
            }
        }
        let record = Record {
            source,
            source_end: None,
            receipt_id,
            target,
            cache_stamp: Stamp::of(&Metadata::from_file(file)?),
            created_unix_ms: cache.created_unix_ms,
            expires_unix_ms: cache
                .created_unix_ms
                .checked_add(LEASE_MS)
                .ok_or(Error::Invalid)?,
            cache,
        };
        if !record.valid() {
            return Err(Error::Invalid);
        }
        let parent = record.target.directory()?;
        let actual = open_file(&parent, &record.cache_name(), false)?;
        if Stamp::of(&Metadata::from_file(&actual)?) != record.cache_stamp {
            return Err(Error::Identity);
        }
        let key = record.key();
        self.dir.create_dir(&key)?;
        sync_dir(&self.dir)?;
        let directory = self.dir.open_dir_nofollow(&key)?;
        let file = open_file(&directory, ".active.lock", true)?;
        lock(&file)?;
        atomic(&directory, "record.json", &record)?;
        atomic(&directory, "state.json", &State::Receiving)?;
        Ok(Lease {
            registry_dir: self.dir.try_clone()?,
            directory,
            _lock: file,
            record,
            state: State::Receiving,
        })
    }
    /// Fresh approval's local root/name gate lookup; source identity is not authorization.
    pub(crate) fn claim(
        &self,
        source: &Source,
        approved_root: &Path,
        requested_name: &str,
    ) -> Result<Option<Lease>> {
        self.claim_at(source, approved_root, requested_name, now_ms()?)
    }
    fn claim_at(
        &self,
        source: &Source,
        approved_root: &Path,
        requested_name: &str,
        now: u64,
    ) -> Result<Option<Lease>> {
        if !source.valid() {
            return Err(Error::Invalid);
        }
        let _index = self.index_lock()?;
        let key = Self::reservation_key(source, approved_root, requested_name)?;
        let directory = match self.dir.open_dir_nofollow(&key) {
            Ok(dir) => dir,
            Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(None),
            Err(e) => return Err(e.into()),
        };
        let file = open_file(&directory, ".active.lock", false)?;
        lock(&file)?;
        let record: Record = decode(&directory, "record.json")?;
        let state: State = decode(&directory, "state.json")?;
        if !record.valid()
            || record.key() != key
            || &record.source != source
            || !record.target.approved(approved_root, requested_name)?
        {
            return Err(Error::Identity);
        }
        if now < record.created_unix_ms
            || now >= record.expires_unix_ms
            || matches!(state, State::Discarded { .. })
        {
            return Err(Error::Expired);
        }
        record.target.directory()?;
        Ok(Some(Lease {
            registry_dir: self.dir.try_clone()?,
            directory,
            _lock: file,
            record,
            state,
        }))
    }
}
#[derive(Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct CleanupReport {
    pub(crate) examined: u32,
    pub(crate) active: u32,
    pub(crate) retained: u32,
    pub(crate) removed_records: u32,
    pub(crate) removed_files: u32,
    pub(crate) unlinked_bytes: u64,
    pub(crate) planned_bytes: u64,
    pub(crate) failed: u32,
    pub(crate) budget_reached: bool,
    pub(crate) entries: Vec<crate::receive_registry::CleanupEntry>,
}
impl Registry {
    /// Explicit caller intent may remove inactive recovery reservations before
    /// their lease expires. Startup maintenance passes false, unlike orphan cleanup.
    pub(crate) fn cleanup(&self, limit: usize, force: bool) -> Result<CleanupReport> {
        self.scan(limit, force, false)
    }
    pub(crate) fn inspect(&self, limit: usize, force: bool) -> Result<CleanupReport> {
        self.scan(limit, force, true)
    }
    fn scan(&self, limit: usize, force: bool, inspection: bool) -> Result<CleanupReport> {
        self.scan_with_scope(None, limit, force, inspection)
    }
    pub(crate) fn scan_in_scope(
        &self,
        scope: &crate::receive_scope_policy::CoordinatedRoot,
        limit: usize,
        force: bool,
        inspection: bool,
    ) -> Result<CleanupReport> {
        self.scan_with_scope(Some(scope), limit, force, inspection)
    }
    fn scan_names(
        &self,
        cursor: &mut Option<cap_std::fs::ReadDir>,
        limit: usize,
    ) -> Result<(Vec<std::ffi::OsString>, bool)> {
        if cursor.is_none() {
            *cursor = Some(self.dir.entries()?);
        }
        let mut names = Vec::new();
        for _ in 0..limit.min(MAX_RECORDS).saturating_add(2) {
            match cursor.as_mut().unwrap().next() {
                Some(Ok(entry)) => {
                    if entry.file_name() != ".index.lock" && entry.file_name() != ".source-end" {
                        names.push(entry.file_name());
                    }
                }
                Some(Err(e)) => return Err(e.into()),
                None => {
                    *cursor = None;
                    return Ok((names, false));
                }
            }
            if names.len() >= limit.min(MAX_RECORDS) {
                break;
            }
        }
        Ok((names, true))
    }
    fn scan_with_scope(
        &self,
        scope: Option<&crate::receive_scope_policy::CoordinatedRoot>,
        limit: usize,
        force: bool,
        inspection: bool,
    ) -> Result<CleanupReport> {
        let now = now_ms()?;
        let mut report = CleanupReport::default();
        if limit == 0 {
            return Ok(report);
        }
        let (names, budget_reached) = {
            let _index = self.index_lock()?;
            if let Some(scope) = scope {
                let mut cursors = self.scoped_cursors.lock().map_err(|_| Error::Busy)?;
                let mut cursor = if let Some(index) = cursors
                    .iter()
                    .position(|(root, preview, _)| root == scope.path() && *preview == inspection)
                {
                    cursors.remove(index).2
                } else {
                    None
                };
                let result = self.scan_names(&mut cursor, limit);
                if cursor.is_some() {
                    if cursors.len() >= 256 {
                        cursors.remove(0);
                    }
                    cursors.push((scope.path().into(), inspection, cursor));
                }
                result?
            } else {
                let mut cursor = if inspection {
                    &self.inspect_cursor
                } else {
                    &self.cleanup_cursor
                }
                .lock()
                .map_err(|_| Error::Busy)?;
                self.scan_names(&mut cursor, limit)?
            }
        };
        report.budget_reached = budget_reached;
        for name in names {
            let mut removed = (0u64, 0u32);
            let mut planned = 0;
            let mut matched = scope.is_none();
            let mut detail = crate::receive_registry::CleanupEntry {
                id: name
                    .to_str()
                    .filter(|s| s.len() == 64 && s.bytes().all(|b| b.is_ascii_hexdigit()))
                    .map(str::to_owned)
                    .unwrap_or_else(|| sha256_hex(name.as_encoded_bytes())),
                source_kind: "nativeReceive".into(),
                reason: "durable_resume".into(),
                ..Default::default()
            };
            let result = (|| -> Result<bool> {
                let key = name
                    .to_str()
                    .filter(|s| s.len() == 64 && s.bytes().all(|b| b.is_ascii_hexdigit()))
                    .ok_or(Error::Invalid)?;
                let directory = self.dir.open_dir_nofollow(key)?;
                // Private metadata routes the candidate before acquiring the
                // record lock; no unrelated external root is opened or counted.
                if let Some(scope) = scope {
                    let preview: Record = decode(&directory, "record.json")?;
                    if !preview.valid() || preview.key() != key {
                        return Err(Error::Identity);
                    }
                    if !scope.contains(&preview.target.approved_root)
                        || !scope.contains(&preview.target.parent)
                    {
                        return Ok(false);
                    }
                    matched = true;
                }
                let lock_file = open_file(&directory, ".active.lock", false)?;
                lock(&lock_file)?;
                let record: Record = decode(&directory, "record.json")?;
                let state: State = decode(&directory, "state.json")?;
                if !record.valid() || record.key() != key {
                    return Err(Error::Identity);
                }
                detail.file_name = Some(record.cache.file_name.chars().take(512).collect());
                if let Some(scope) = scope {
                    if !scope.contains(&record.target.approved_root)
                        || !scope.contains(&record.target.parent)
                    {
                        return Err(Error::Identity);
                    }
                } else if crate::receive_scope_policy::requires_coordinated_access(
                    &record.target.parent,
                ) {
                    return Ok(false);
                }
                if !force && (now < record.created_unix_ms || now < record.expires_unix_ms) {
                    return Ok(false);
                }
                let mut lease = Lease {
                    registry_dir: self.dir.try_clone()?,
                    directory,
                    _lock: lock_file,
                    record,
                    state,
                };
                if inspection {
                    planned = match scope {
                        Some(scope) => lease.eligible_bytes_in_scope(scope)?,
                        None => lease.eligible_bytes()?,
                    };
                    return Ok(false);
                }
                match scope {
                    Some(scope) => lease.discard_report_in_scope(&mut removed, scope)?,
                    None => lease.discard_report(&mut removed)?,
                };
                self.retire(lease)?;
                Ok(true)
            })();
            if !matched {
                continue;
            }
            report.examined += 1;
            report.unlinked_bytes += removed.0;
            report.removed_files += removed.1;
            report.planned_bytes += planned;
            detail.planned_bytes = planned;
            detail.unlinked_bytes = removed.0;
            detail.disposition = match result {
                Ok(true) => {
                    report.removed_records += 1;
                    if removed.1 > 0 { "removed" } else { "retired" }
                }
                Ok(false) => {
                    if inspection && planned > 0 {
                        "candidate"
                    } else {
                        report.retained += 1;
                        "retained"
                    }
                }
                Err(Error::Busy) => {
                    report.active += 1;
                    "active"
                }
                Err(Error::Invalid | Error::Identity | Error::Expired) => {
                    report.retained += 1;
                    "retained"
                }
                Err(_) => {
                    report.failed += 1;
                    detail.reason = "durable_resume_failed".into();
                    "failed"
                }
            }
            .into();
            report.entries.push(detail);
        }
        Ok(report)
    }
    pub(crate) fn cleanup_completed_cache(&self, lease: &Lease) -> Result<()> {
        if !matches!(lease.state, State::Published { .. }) {
            return Err(Error::Invalid);
        }
        let dir = lease.record.target.directory()?;
        let stamp = match &lease.state {
            State::Published { final_stamp, .. } => final_stamp.clone(),
            _ => unreachable!(),
        };
        for (name, expected) in [
            (lease.record.cache_name(), lease.record.cache_stamp.clone()),
            (lease.record.staging_name(), stamp),
        ] {
            let file = match open_file(&dir, &name, false) {
                Ok(file) => file,
                Err(Error::Io(e)) if e.kind() == io::ErrorKind::NotFound => continue,
                Err(e) => return Err(e),
            };
            if Stamp::of(&Metadata::from_file(&file)?) != expected {
                return Err(Error::Identity);
            }
            lock(&file)?;
            let current = open_file(&dir, &name, false)?;
            if same_file::Handle::from_file(current)?
                != same_file::Handle::from_file(file.try_clone()?)?
            {
                return Err(Error::Identity);
            }
            dir.remove_file(name)?;
        }
        sync_dir(&dir)?;
        Ok(())
    }
    pub(crate) fn retire_expired(&self, source: &Source, root: &Path, name: &str) -> Result<bool> {
        let key = Self::reservation_key(source, root, name)?;
        let directory = {
            let _index = self.index_lock()?;
            match self.dir.open_dir_nofollow(&key) {
                Ok(d) => d,
                Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(false),
                Err(e) => return Err(e.into()),
            }
        };
        let file = open_file(&directory, ".active.lock", false)?;
        lock(&file)?;
        let record: Record = decode(&directory, "record.json")?;
        let state: State = decode(&directory, "state.json")?;
        if !record.valid() || record.key() != key || !record.target.approved(root, name)? {
            return Err(Error::Identity);
        }
        let now = now_ms()?;
        if now < record.created_unix_ms {
            return Err(Error::Expired);
        }
        if now < record.expires_unix_ms && !matches!(state, State::Discarded { .. }) {
            return Ok(false);
        }
        let mut lease = Lease {
            registry_dir: self.dir.try_clone()?,
            directory,
            _lock: file,
            record,
            state,
        };
        lease.discard()?;
        self.retire(lease)?;
        Ok(true)
    }
    /// Only a fresh approved request may invalidate the same peer/key's known
    /// changed source. A different approval target uses a separate reservation.
    pub(crate) fn invalidate_changed_source(
        &self,
        source: &Source,
        root: &Path,
        name: &str,
    ) -> Result<bool> {
        let key = Self::reservation_key(source, root, name)?;
        let directory = {
            let _index = self.index_lock()?;
            match self.dir.open_dir_nofollow(&key) {
                Ok(d) => d,
                Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(false),
                Err(e) => return Err(e.into()),
            }
        };
        let file = open_file(&directory, ".active.lock", false)?;
        lock(&file)?;
        let record: Record = decode(&directory, "record.json")?;
        let state: State = decode(&directory, "state.json")?;
        if !record.valid()
            || record.key() != key
            || record.source.peer != source.peer
            || record.source.resume_key != source.resume_key
            || !record.target.approved(root, name)?
        {
            return Err(Error::Identity);
        }
        if record.source == *source {
            return Ok(false);
        }
        let mut lease = Lease {
            registry_dir: self.dir.try_clone()?,
            directory,
            _lock: file,
            record,
            state,
        };
        lease.discard()?;
        self.retire(lease)?;
        Ok(true)
    }
    /// Called after verified cache cleanup. No final destination is ever visited.
    pub(crate) fn retire(&self, lease: Lease) -> Result<()> {
        if !matches!(lease.state, State::Discarded { .. }) {
            return Err(Error::Invalid);
        }
        let _index = self.index_lock()?;
        let key = lease.record.key();
        let current = self.dir.open_dir_nofollow(&key)?;
        if same_file::Handle::from_file(current.try_clone()?.into_std_file())?
            != same_file::Handle::from_file(lease.directory.try_clone()?.into_std_file())?
        {
            return Err(Error::Identity);
        }
        let expected = ["record.json", "state.json", ".active.lock"];
        let mut count = 0;
        for entry in lease.directory.entries()? {
            let entry = entry?;
            count += 1;
            if count > 3
                || !expected.iter().any(|name| entry.file_name() == *name)
                || !entry.file_type()?.is_file()
            {
                return Err(Error::Identity);
            }
        }
        // Keep all original handles until each relative unlink has been checked.
        let mut files = Vec::new();
        for name in expected {
            files.push((name, open_file(&lease.directory, name, false)?));
        }
        for (name, file) in &files {
            let current = open_file(&lease.directory, name, false)?;
            if same_file::Handle::from_file(current)?
                != same_file::Handle::from_file(file.try_clone()?)?
            {
                return Err(Error::Identity);
            }
            lease.directory.remove_file(name)?;
        }
        self.dir.remove_dir(&key)?;
        sync_dir(&self.dir)?;
        Ok(())
    }
}

impl Lease {
    /// Only private metadata is consulted. Dropping a Lease closes its private
    /// registration handles and never opens the recorded provider destination.
    pub(crate) fn requires_coordinated_access(&self) -> bool {
        crate::receive_scope_policy::requires_coordinated_access(&self.record.target.approved_root)
    }
    pub(crate) fn valid_lease(&self) -> bool {
        now_ms().is_ok_and(|now| {
            now >= self.record.created_unix_ms && now < self.record.expires_unix_ms
        })
    }
    fn eligible_bytes(&self) -> Result<u64> {
        self.eligible_bytes_in_directory(self.record.target.directory()?)
    }
    fn eligible_bytes_in_scope(
        &self,
        scope: &crate::receive_scope_policy::CoordinatedRoot,
    ) -> Result<u64> {
        self.eligible_bytes_in_directory(self.record.target.directory_in_scope(scope)?)
    }
    fn eligible_bytes_in_directory(&self, dir: Dir) -> Result<u64> {
        let staging = match &self.state {
            State::Exporting { staging_stamp } | State::Publishing { staging_stamp } => {
                Some(staging_stamp.clone())
            }
            State::Published { final_stamp, .. } => Some(final_stamp.clone()),
            State::Discarded { staging_stamp } => staging_stamp.clone(),
            _ => None,
        };
        let mut bytes = 0;
        for (name, stamp) in [
            (
                self.record.cache_name(),
                Some(self.record.cache_stamp.clone()),
            ),
            (self.record.staging_name(), staging),
        ] {
            let Some(stamp) = stamp else {
                continue;
            };
            let file = match open_file(&dir, &name, false) {
                Ok(file) => file,
                Err(Error::Io(e)) if e.kind() == io::ErrorKind::NotFound => continue,
                Err(e) => return Err(e),
            };
            if Stamp::of(&Metadata::from_file(&file)?) != stamp {
                return Err(Error::Identity);
            }
            lock(&file)?;
            bytes += file.metadata()?.len();
        }
        Ok(bytes)
    }
    pub(crate) fn completed_unix_ms(&self) -> Option<u64> {
        match self.state {
            State::Published {
                completed_unix_ms, ..
            } => Some(completed_unix_ms),
            _ => None,
        }
    }
    pub(crate) fn open_cache(&self) -> Result<File> {
        let dir = self.record.target.directory()?;
        let file = open_file(&dir, &self.record.cache_name(), false)?;
        if Stamp::of(&Metadata::from_file(&file)?) != self.record.cache_stamp {
            return Err(Error::Identity);
        }
        Ok(file)
    }
    /// An offset is granted only after every stored record was checked and the
    /// committed set forms a continuous prefix. Generic LS caches permit gaps;
    /// this sequential native extension deliberately does not.
    pub(crate) fn resume_cache(
        &self,
        mut progress: impl FnMut(u64) -> bool,
    ) -> Result<(crate::download_cache::DownloadCache, u64)> {
        let (cache, _) = crate::download_cache::DownloadCache::resume_with_progress(
            self.open_cache()?,
            &self.record.cache,
            |n| self.valid_lease() && progress(n),
        )?;
        let prefix = cache
            .missing_chunks()
            .next()
            .map_or(self.record.source.size, |index| {
                u64::from(index) * u64::from(BLOCK)
            });
        if cache.committed_bytes() != prefix {
            return Err(Error::Identity);
        }
        Ok((cache, prefix))
    }
    fn write_state(&mut self, state: State) -> Result<()> {
        atomic(&self.directory, "state.json", &state)?;
        self.state = state;
        Ok(())
    }
    pub(crate) fn suspend(&mut self) -> Result<()> {
        match self.state {
            State::Receiving | State::Suspended => self.write_state(State::Suspended),
            // Retain publication evidence if verification was interrupted; never
            // erase a committed final-file identity just to label the task paused.
            State::Exporting { .. } | State::Publishing { .. } | State::Published { .. } => Ok(()),
            State::Discarded { .. } => Err(Error::Invalid),
        }
    }
    pub(crate) fn receiving(&mut self) -> Result<()> {
        if !matches!(self.state, State::Receiving | State::Suspended) {
            return Err(Error::Invalid);
        }
        self.write_state(State::Receiving)
    }
    pub(crate) fn exporting(&mut self, staging: &File) -> Result<()> {
        if !matches!(self.state, State::Receiving) {
            return Err(Error::Invalid);
        }
        let dir = self.record.target.directory()?;
        let original = open_file(&dir, &self.record.staging_name(), false)?;
        let stamp = Stamp::of(&Metadata::from_file(staging)?);
        if !stamp.valid() || Stamp::of(&Metadata::from_file(&original)?) != stamp {
            return Err(Error::Identity);
        }
        self.write_state(State::Exporting {
            staging_stamp: stamp,
        })
    }
    pub(crate) fn publishing(
        &mut self,
        receipt: &crate::download_cache::ExportReceipt,
    ) -> Result<()> {
        if receipt.bytes != self.record.source.size
            || !receipt
                .sha256
                .eq_ignore_ascii_case(&self.record.source.sha256)
        {
            return Err(Error::Identity);
        }
        let State::Exporting { staging_stamp } = &self.state else {
            return Err(Error::Invalid);
        };
        self.write_state(State::Publishing {
            staging_stamp: staging_stamp.clone(),
        })
    }
    /// Takes the actual verified export receipt; no same-size publication shortcut.
    pub(crate) fn published(
        &mut self,
        final_file: &File,
        receipt: &crate::download_cache::ExportReceipt,
    ) -> Result<()> {
        if receipt.bytes != self.record.source.size
            || !receipt
                .sha256
                .eq_ignore_ascii_case(&self.record.source.sha256)
        {
            return Err(Error::Identity);
        }
        let State::Publishing { staging_stamp } = &self.state else {
            return Err(Error::Invalid);
        };
        let stamp = Stamp::of(&Metadata::from_file(final_file)?);
        if &stamp != staging_stamp {
            return Err(Error::Identity);
        }
        self.write_state(State::Published {
            final_stamp: stamp,
            completed_unix_ms: now_ms()?,
        })
    }
    pub(crate) fn published_file(&self) -> Result<Option<File>> {
        let expected = match &self.state {
            State::Publishing { staging_stamp } => staging_stamp,
            State::Published { final_stamp, .. } => final_stamp,
            _ => return Ok(None),
        };
        let dir = self.record.target.directory()?;
        let file = match open_file(&dir, &self.record.target.final_name, false) {
            Ok(v) => v,
            Err(Error::Io(e)) if e.kind() == io::ErrorKind::NotFound => return Ok(None),
            Err(e) => return Err(e),
        };
        if Stamp::of(&Metadata::from_file(&file)?) != *expected
            || file.metadata()?.len() != self.record.source.size
        {
            return Err(Error::Identity);
        }
        Ok(Some(file))
    }
    /// Reconcile a publication whose HTTP acknowledgement was lost. The same
    /// original inode and whole SHA are both mandatory; caller supplies cancellation.
    pub(crate) fn reconcile_published(
        &mut self,
        mut progress: impl FnMut(u64) -> bool,
    ) -> Result<Option<crate::download_cache::ExportReceipt>> {
        let Some(mut file) = self.published_file()? else {
            return Ok(None);
        };
        lock(&file)?;
        let before = file.metadata()?;
        let mut hash = Sha256::new();
        let mut bytes = 0u64;
        let mut buffer = [0; 64 * 1024];
        if !self.valid_lease() || !progress(0) {
            return Err(Error::Io(io::Error::new(
                io::ErrorKind::Interrupted,
                "Verification cancelled",
            )));
        }
        loop {
            let n = file.read(&mut buffer)?;
            if n == 0 {
                break;
            }
            bytes = bytes.checked_add(n as u64).ok_or(Error::Invalid)?;
            if bytes > self.record.source.size {
                return Err(Error::Identity);
            }
            hash.update(&buffer[..n]);
            if !self.valid_lease() || !progress(bytes) {
                return Err(Error::Io(io::Error::new(
                    io::ErrorKind::Interrupted,
                    "Verification cancelled",
                )));
            }
        }
        let actual = hash
            .finalize()
            .iter()
            .map(|v| format!("{v:02x}"))
            .collect::<String>();
        let after = file.metadata()?;
        if bytes != self.record.source.size
            || actual != self.record.source.sha256
            || before.modified().ok() != after.modified().ok()
        {
            return Err(Error::Identity);
        }
        let receipt = crate::download_cache::ExportReceipt {
            bytes,
            sha256: actual,
        };
        if matches!(self.state, State::Publishing { .. }) {
            self.published(&file, &receipt)?;
        }
        Ok(Some(receipt))
    }
    /// Only un-published, exactly owned export staging can be discarded before
    /// rebuilding it from verified LS blocks. A final-file collision is preserved.
    pub(crate) fn reset_export(&mut self) -> Result<()> {
        let stamp = match &self.state {
            State::Exporting { staging_stamp } | State::Publishing { staging_stamp } => {
                staging_stamp.clone()
            }
            _ => return self.receiving(),
        };
        if self.published_file()?.is_some() {
            return Err(Error::Identity);
        }
        let dir = self.record.target.directory()?;
        let name = self.record.staging_name();
        match open_file(&dir, &name, false) {
            Ok(file) => {
                if Stamp::of(&Metadata::from_file(&file)?) != stamp {
                    return Err(Error::Identity);
                }
                lock(&file)?;
                dir.remove_file(&name)?;
                sync_dir(&dir)?;
            }
            Err(Error::Io(e)) if e.kind() == io::ErrorKind::NotFound => {}
            Err(e) => return Err(e),
        }
        self.write_state(State::Receiving)
    }
    /// Marks intent first. Only identity-verified staging/cache names are touched;
    /// a final published destination is never a cleanup target.
    pub(crate) fn discard(&mut self) -> Result<u64> {
        let mut report = (0, 0);
        self.discard_report(&mut report)?;
        Ok(report.0)
    }
    fn discard_report(&mut self, report: &mut (u64, u32)) -> Result<()> {
        self.discard_report_with_directory(report, None)
    }
    fn discard_report_in_scope(
        &mut self,
        report: &mut (u64, u32),
        scope: &crate::receive_scope_policy::CoordinatedRoot,
    ) -> Result<()> {
        let dir = self.record.target.directory_in_scope(scope)?;
        self.discard_report_with_directory(report, Some(dir))
    }
    fn discard_report_with_directory(
        &mut self,
        report: &mut (u64, u32),
        directory: Option<Dir>,
    ) -> Result<()> {
        let previously_published = matches!(self.state, State::Published { .. });
        let initial = *report;
        if previously_published {
            self.record_source_end_cleanup(true, 0, 0)?;
        }
        let staging = match &self.state {
            State::Exporting { staging_stamp } | State::Publishing { staging_stamp } => {
                Some(staging_stamp.clone())
            }
            State::Published { final_stamp, .. } => Some(final_stamp.clone()),
            State::Discarded { staging_stamp } => staging_stamp.clone(),
            _ => None,
        };
        self.write_state(State::Discarded {
            staging_stamp: staging.clone(),
        })?;
        let dir = match directory {
            Some(dir) => dir,
            None => self.record.target.directory()?,
        };
        for (name, stamp) in [
            (
                self.record.cache_name(),
                Some(self.record.cache_stamp.clone()),
            ),
            (self.record.staging_name(), staging),
        ] {
            let Some(stamp) = stamp else {
                continue;
            };
            let file = match open_file(&dir, &name, false) {
                Ok(v) => v,
                Err(Error::Io(e)) if e.kind() == io::ErrorKind::NotFound => continue,
                Err(e) => return Err(e),
            };
            if Stamp::of(&Metadata::from_file(&file)?) != stamp {
                return Err(Error::Identity);
            }
            lock(&file)?;
            let current = open_file(&dir, &name, false)?;
            if same_file::Handle::from_file(current)?
                != same_file::Handle::from_file(file.try_clone()?)?
            {
                return Err(Error::Identity);
            }
            let size = file.metadata()?.len();
            dir.remove_file(name)?;
            report.0 += size;
            report.1 += 1;
        }
        sync_dir(&dir)?;
        self.record_source_end_cleanup(
            previously_published,
            report.0 - initial.0,
            report.1 - initial.1,
        )?;
        Ok(())
    }
}

/// Capability check before durable opt-in. Missing birthtime or advisory-lock
/// support disables only this extension, never the original transfer protocol.
pub(crate) fn supports_target(root: &Path, requested_name: &str) -> Result<bool> {
    if !relative(requested_name) || !root.is_absolute() {
        return Err(Error::Invalid);
    }
    let canonical = std::fs::canonicalize(root)?;
    let mut parent = open_directory(&canonical)?;
    if !Stamp::of(&parent.dir_metadata()?).valid() {
        return Ok(false);
    }
    let components: Vec<_> = requested_name.split('/').collect();
    for component in &components[..components.len() - 1] {
        match parent.open_dir_nofollow(component) {
            Ok(next) => parent = next,
            Err(e) if e.kind() == io::ErrorKind::NotFound => break,
            Err(_) => return Ok(false),
        }
    }
    if !Stamp::of(&parent.dir_metadata()?).valid() {
        return Ok(false);
    }
    let name = format!(".legnasend-resume-probe-{}", uuid::Uuid::new_v4());
    let mut options = options();
    options.create_new(true);
    let file = parent.open_with(&name, &options)?.into_std();
    let supported = (|| -> Result<bool> {
        if !Stamp::of(&Metadata::from_file(&file)?).valid() {
            return Ok(false);
        }
        match lock(&file) {
            Ok(()) => Ok(true),
            Err(_) => Ok(false),
        }
    })();
    let current = open_file(&parent, &name, false)?;
    if same_file::Handle::from_file(current)? != same_file::Handle::from_file(file.try_clone()?)? {
        return Err(Error::Identity);
    }
    parent.remove_file(&name)?;
    supported
}
