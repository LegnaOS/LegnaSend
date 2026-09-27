//! Native path receive transaction. Cache and export staging live beside the
//! destination; only verified original bytes are published, without overwrite.
use super::save::{FileTimestamps, SaveResult};
use crate::download_cache::{CacheError, CacheIdentity, DownloadCache, MAX_CHUNKS, MAX_CHUNK_SIZE};
use bytes::Bytes;
use cap_fs_ext::{FollowSymlinks, OpenOptionsFollowExt};
use cap_std::fs::{Dir, OpenOptions};
use http_body_util::BodyExt;
use hyper::{body::Incoming, Request};
use std::{ffi::OsString, fs::File, io, path::PathBuf};
use tokio::sync::{mpsc, oneshot, Semaphore};
use tokio_util::sync::CancellationToken;

const FRAME_BYTES: usize = 64 * 1024;
const QUEUE: usize = 8;
pub(crate) static ACTIVE: Semaphore = Semaphore::const_new(8);

#[derive(Clone)]
pub(crate) struct Context {
    pub cancel: CancellationToken,
    pub session_id: String,
    pub file_id: String,
    pub attempt_id: String,
    pub event_tx: mpsc::Sender<crate::http::server::v2::ServerEventV2>,
}

// A closed channel is an aborted request, never a successful EOF. This also
// prevents publication when a complete-size body is dropped before its EOF.
enum Message {
    Data(Bytes),
    Finish,
}

pub(super) struct Target {
    pub path: PathBuf,
    pub result_tx: oneshot::Sender<Result<(), String>>,
    pub progress_tx: Option<mpsc::Sender<u64>>,
}

pub(super) async fn save(
    req: Request<Incoming>,
    target: Target,
    size: u64,
    expected: Option<&str>,
    times: FileTimestamps,
    context: Context,
) -> SaveResult {
    let Target {
        path,
        result_tx,
        progress_tx: progress,
    } = target;
    let cancel = context.cancel.child_token();
    let _abort_on_drop = cancel.clone().drop_guard();
    let permit = tokio::select! {
        biased;
        _ = cancel.cancelled() => {
            let _ = result_tx.send(Err("Upload cancelled".into()));
            return SaveResult::Failed;
        },
        permit = ACTIVE.acquire() => permit.expect("receive semaphore never closes"),
    };
    let (tx, rx) = mpsc::channel(QUEUE);
    let identity = identity(&path, size, expected, &context);
    let worker_cancel = cancel.clone();
    let mut worker = tokio::task::spawn_blocking(move || {
        // Hold the global budget until cleanup, even if the HTTP task is dropped.
        #[cfg(test)]
        let worker_path = path.clone();
        #[cfg(test)]
        blocked_tests::checkpoint(&worker_path, blocked_tests::Point::WorkerStarted);
        let result = receive(path, identity, times, rx, worker_cancel, progress);
        // The worker, not its HTTP awaiter, releases this only after transaction
        // cleanup has finished. No observer task or replacement worker is spawned.
        drop(permit);
        #[cfg(test)]
        blocked_tests::checkpoint(&worker_path, blocked_tests::Point::WorkerReleased);
        let outcome = match &result {
            Ok(()) => SaveResult::Success,
            Err(CacheError::Checksum) => SaveResult::HashMismatch,
            Err(_) => SaveResult::Failed,
        };
        // The real owner reports completion only after its filesystem work and
        // cleanup end. Early HTTP cancellation must not steal this result: a
        // publication already in progress can still complete successfully.
        let _ = result_tx.send(result.map_err(|e| e.to_string()));
        outcome
    });
    let mut early_result = None;
    let mut body = req.into_body();
    'body: loop {
        let frame = tokio::select! {
            biased;
            _ = cancel.cancelled() => break,
            result = &mut worker => { early_result = Some(result); break; },
            frame = body.frame() => frame,
        };
        match frame {
            Some(Ok(frame)) => {
                if let Ok(data) = frame.into_data() {
                    for chunk in data.chunks(FRAME_BYTES) {
                        let sent = tokio::select! {
                            biased;
                            _ = cancel.cancelled() => break 'body,
                            sent = tx.send(Message::Data(Bytes::copy_from_slice(chunk))) => sent,
                        };
                        if sent.is_err() {
                            break 'body;
                        }
                    }
                }
            }
            None => {
                tokio::select! {
                    biased;
                    _ = cancel.cancelled() => {},
                    _ = tx.send(Message::Finish) => {},
                }
                break;
            }
            Some(Err(_)) => {
                cancel.cancel();
                break;
            }
        }
    }
    drop(tx);
    // A blocking OS open/write cannot be forcibly interrupted. Keep its budget
    // owned by the worker, but release the HTTP request without waiting for it.
    // A ready actual result wins over a simultaneous cancellation.
    let result = match early_result {
        Some(result) => result,
        None => tokio::select! {
            biased;
            result = &mut worker => result,
            _ = cancel.cancelled() => return SaveResult::Failed,
        },
    };
    result.unwrap_or(SaveResult::Failed)
}

pub(super) fn identity(
    path: &std::path::Path,
    size: u64,
    expected: Option<&str>,
    context: &Context,
) -> CacheIdentity {
    // Adapt the bounded chunk buffer for large files while retaining the format's
    // maximum of one million records. Oversized identities fail before payload IO.
    let chunk = size
        .div_ceil(MAX_CHUNKS)
        .max(size.clamp(64 * 1024, 1024 * 1024))
        .min(u64::from(MAX_CHUNK_SIZE));
    let id = uuid::Uuid::new_v4().to_string();
    CacheIdentity {
        task_id: id.clone(),
        source_id: format!("localsend-v2:{}", context.session_id),
        resource_id: crate::crypto::hash::sha256_hex(context.file_id.as_bytes()),
        version: id,
        file_name: path
            .file_name()
            .unwrap_or_default()
            .to_string_lossy()
            .into_owned(),
        size,
        chunk_size: chunk as u32,
        created_unix_ms: std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_millis() as u64,
        sha256: expected.map(str::to_owned),
    }
}

struct Transaction {
    dir: Dir,
    // Original open handles identify our files, including when a path is replaced.
    owned: Vec<(OsString, File)>,
    timestamps: FileTimestamps,
    registration: Option<(
        std::sync::Arc<crate::receive_registry::Registry>,
        PathBuf,
        CacheIdentity,
    )>,
    records: Vec<(OsString, crate::receive_registry::Registration)>,
}
impl Transaction {
    fn create(&mut self, name: OsString) -> io::Result<File> {
        let mut options = OpenOptions::new();
        options
            .read(true)
            .write(true)
            .create_new(true)
            .follow(FollowSymlinks::No);
        #[cfg(unix)]
        {
            use cap_std::fs::OpenOptionsExt;
            options.mode(0o600);
        }
        let file = self.dir.open_with(&name, &options)?.into_std();
        self.owned.push((name.clone(), file));
        let file = &self.owned.last().unwrap().1;
        // On APFS, setting an earlier modification time can also move birthtime.
        // Apply it before recording the export identity; repeat after export to
        // restore modification/access times changed by writing the original bytes.
        if name.to_string_lossy().ends_with(".part") {
            apply_timestamps(file, self.timestamps);
        }
        if let Some((registry, parent, identity)) = &self.registration {
            let export = name.to_string_lossy().ends_with(".part");
            let record = registry.register(parent, &self.dir, file, identity, export)?;
            self.records.push((name, record));
        }
        file.try_clone()
    }
    fn is_owned(&self, name: &std::ffi::OsStr, original: &File) -> io::Result<bool> {
        let mut options = OpenOptions::new();
        options.read(true).follow(FollowSymlinks::No);
        let current = self.dir.open_with(name, &options)?.into_std();
        // Obtain both identities at comparison time (important on Windows).
        Ok(same_file::Handle::from_file(current)?
            == same_file::Handle::from_file(original.try_clone()?)?)
    }
    fn publish(
        &self,
        staging: &std::ffi::OsStr,
        destination: &std::ffi::OsStr,
        cancel: &CancellationToken,
    ) -> io::Result<()> {
        let (_, original) = self
            .owned
            .iter()
            .find(|(name, _)| name == staging)
            .ok_or_else(|| io::Error::other("Unowned receive staging file"))?;
        if !self.is_owned(staging, original)? {
            return Err(io::Error::other("Receive staging file changed"));
        }
        // Identity verification can itself wait on filesystem access. Recheck
        // immediately before entering the irreversible no-overwrite operation.
        if cancel.is_cancelled() {
            return Err(io::Error::new(
                io::ErrorKind::Interrupted,
                "Upload cancelled",
            ));
        }
        #[cfg(any(
            target_os = "linux",
            target_os = "android",
            target_os = "macos",
            target_os = "ios"
        ))]
        {
            use rustix::fs::{renameat_with, RenameFlags};
            use rustix::io::Errno;
            match renameat_with(
                &self.dir,
                staging,
                &self.dir,
                destination,
                RenameFlags::NOREPLACE,
            ) {
                Ok(()) => return Ok(()),
                Err(Errno::NOSYS | Errno::INVAL | Errno::OPNOTSUPP) => {}
                Err(e) => return Err(e.into()),
            }
        }
        // Atomic no-overwrite fallback on filesystems supporting hard links.
        // Do not silently fall back to truncating/copying the final destination.
        if cancel.is_cancelled() {
            return Err(io::Error::new(
                io::ErrorKind::Interrupted,
                "Upload cancelled",
            ));
        }
        self.dir.hard_link(staging, &self.dir, destination)
    }
}
impl Drop for Transaction {
    fn drop(&mut self) {
        for (name, original) in &self.owned {
            match self.is_owned(name, original) {
                Ok(true) => {
                    if let Err(e) = self.dir.remove_file(name) {
                        tracing::warn!(
                            "Receive cache cleanup failed for {}: {e}",
                            name.to_string_lossy()
                        );
                    }
                }
                Ok(false) => tracing::warn!(
                    "Receive cache identity changed; keeping {}",
                    name.to_string_lossy()
                ),
                Err(e) if e.kind() == io::ErrorKind::NotFound => {}
                Err(e) => tracing::warn!(
                    "Receive cache cleanup not verified for {}: {e}",
                    name.to_string_lossy()
                ),
            }
        }
        for (name, record) in &self.records {
            // Never retire a record if cleanup failed or the name was replaced.
            if self
                .dir
                .symlink_metadata(name)
                .is_err_and(|e| e.kind() == io::ErrorKind::NotFound)
            {
                if let Err(e) = record.retire() {
                    tracing::warn!("Receive registry retirement failed: {e}");
                }
            }
        }
    }
}

fn receive(
    path: PathBuf,
    identity: CacheIdentity,
    times: FileTimestamps,
    mut rx: mpsc::Receiver<Message>,
    cancel: CancellationToken,
    progress: Option<mpsc::Sender<u64>>,
) -> Result<(), CacheError> {
    let cancelled = || {
        if cancel.is_cancelled() {
            Err(CacheError::Cancelled)
        } else {
            Ok(())
        }
    };
    cancelled()?;
    let name = path
        .file_name()
        .ok_or_else(|| io::Error::other("Missing receive file name"))?;
    let parent = path
        .parent()
        .filter(|p| !p.as_os_str().is_empty())
        .unwrap_or(std::path::Path::new("."));
    let dir = Dir::open_ambient_dir(parent, cap_std::ambient_authority())?;
    #[cfg(test)]
    blocked_tests::checkpoint(&path, blocked_tests::Point::Opened);
    cancelled()?;
    let mut txn = Transaction {
        dir,
        owned: Vec::new(),
        timestamps: times,
        registration: crate::receive_registry::current()
            .map(|registry| (registry, parent.to_owned(), identity.clone())),
        records: Vec::new(),
    };
    // Refuse an existing entry, including symlinks. Publication rechecks atomically.
    match txn.dir.symlink_metadata(name) {
        Ok(_) => {
            return Err(io::Error::new(
                io::ErrorKind::AlreadyExists,
                "Receive destination already exists",
            )
            .into());
        }
        Err(e) if e.kind() == io::ErrorKind::NotFound => {}
        Err(e) => return Err(e.into()),
    }
    let cache_name = OsString::from(format!(".legnasend-receive-{}.ls", identity.task_id));
    let staging = OsString::from(format!(".legnasend-receive-{}.part", identity.task_id));
    let size = identity.size;
    let chunk_size = identity.chunk_size as usize;
    cancelled()?;
    let cache_file = txn.create(cache_name)?;
    cancelled()?;
    let mut cache = DownloadCache::create_receive_attempt(cache_file, identity)?;
    #[cfg(test)]
    blocked_tests::checkpoint(&path, blocked_tests::Point::CacheCreated);
    let mut buffer = Vec::with_capacity(chunk_size);
    let mut index = 0;
    let mut total = 0u64;
    loop {
        cancelled()?;
        let message = rx.blocking_recv();
        cancelled()?;
        match message {
            Some(Message::Data(bytes)) => {
                total = total
                    .checked_add(bytes.len() as u64)
                    .ok_or(CacheError::Chunk)?;
                if total > size {
                    return Err(CacheError::Chunk);
                }
                let mut bytes = bytes.as_ref();
                while !bytes.is_empty() {
                    let take = bytes.len().min(chunk_size - buffer.len());
                    buffer.extend_from_slice(&bytes[..take]);
                    bytes = &bytes[take..];
                    if buffer.len() == chunk_size {
                        cancelled()?;
                        cache.commit_chunk(index, &buffer)?;
                        #[cfg(test)]
                        blocked_tests::checkpoint(&path, blocked_tests::Point::Write);
                        cancelled()?;
                        index += 1;
                        buffer.clear();
                        if let Some(tx) = &progress {
                            let _ =
                                tx.try_send(cache.committed_bytes().min(size.saturating_sub(1)));
                        }
                    }
                }
            }
            Some(Message::Finish) => break,
            None => return Err(CacheError::Cancelled),
        }
    }
    cancelled()?;
    if total != size {
        return Err(CacheError::Incomplete);
    }
    if !buffer.is_empty() {
        cache.commit_chunk(index, &buffer)?;
    }
    cancelled()?;
    let mut output = txn.create(staging.clone())?;
    cancelled()?;
    cache.export_with_progress(&mut output, |_| !cancel.is_cancelled())?;
    apply_timestamps(&output, times);
    cancelled()?;
    // The atomic publication is the commit point. A later cancellation never
    // deletes an already-published user's file. Progress reaches 100% only here.
    #[cfg(test)]
    blocked_tests::checkpoint(&path, blocked_tests::Point::BeforePublish);
    cancelled()?;
    txn.publish(&staging, name, &cancel)?;
    #[cfg(test)]
    blocked_tests::checkpoint(&path, blocked_tests::Point::Published);
    if let Some(tx) = &progress {
        let _ = tx.try_send(size);
    }
    Ok(())
}

/// An explicitly negotiated same-session receive. Its owner retains this object
/// only across short network interruptions, never across application restarts.
pub(crate) struct ResumableReceive {
    txn: Transaction,
    cache: DownloadCache,
    name: OsString,
    staging: OsString,
    times: FileTimestamps,
    cancel: CancellationToken,
    progress: Option<mpsc::Sender<u64>>,
}
impl ResumableReceive {
    pub(crate) fn create(
        path: PathBuf,
        identity: CacheIdentity,
        times: FileTimestamps,
        cancel: CancellationToken,
        progress: Option<mpsc::Sender<u64>>,
    ) -> Result<Self, CacheError> {
        if cancel.is_cancelled() {
            return Err(CacheError::Cancelled);
        }
        let name = path.file_name().ok_or(CacheError::Identity)?.to_os_string();
        let parent = path
            .parent()
            .filter(|p| !p.as_os_str().is_empty())
            .unwrap_or(std::path::Path::new("."));
        let dir = Dir::open_ambient_dir(parent, cap_std::ambient_authority())?;
        if cancel.is_cancelled() {
            return Err(CacheError::Cancelled);
        }
        let mut txn = Transaction {
            dir,
            owned: Vec::new(),
            timestamps: times,
            registration: crate::receive_registry::current()
                .map(|registry| (registry, parent.to_owned(), identity.clone())),
            records: Vec::new(),
        };
        match txn.dir.symlink_metadata(&name) {
            Ok(_) => {
                return Err(io::Error::new(
                    io::ErrorKind::AlreadyExists,
                    "Receive destination already exists",
                )
                .into());
            }
            Err(e) if e.kind() == io::ErrorKind::NotFound => {}
            Err(e) => return Err(e.into()),
        }
        if cancel.is_cancelled() {
            return Err(CacheError::Cancelled);
        }
        let cache_name = OsString::from(format!(".legnasend-receive-{}.ls", identity.task_id));
        let staging = OsString::from(format!(".legnasend-receive-{}.part", identity.task_id));
        // Keep the cache lock and original identity handles for this short-lived
        // logical receive. Durable chunk records never make wire restart claims.
        let file = txn.create(cache_name)?;
        if cancel.is_cancelled() {
            return Err(CacheError::Cancelled);
        }
        let cache = DownloadCache::create(file, identity)?;
        if cancel.is_cancelled() {
            return Err(CacheError::Cancelled);
        }
        Ok(Self {
            txn,
            cache,
            name,
            staging,
            times,
            cancel,
            progress,
        })
    }
    pub(crate) fn offset(&self) -> u64 {
        self.cache.committed_bytes()
    }
    pub(crate) fn commit(&mut self, offset: u64, bytes: &[u8]) -> Result<u64, CacheError> {
        if self.cancel.is_cancelled() {
            return Err(CacheError::Cancelled);
        }
        if offset != self.offset() {
            return Err(CacheError::Chunk);
        }
        let index = offset / u64::from(self.cache.identity().chunk_size);
        self.cache
            .commit_chunk(index.try_into().map_err(|_| CacheError::Chunk)?, bytes)?;
        let offset = self.offset();
        if let Some(tx) = &self.progress {
            let _ = tx.try_send(offset.min(self.cache.identity().size.saturating_sub(1)));
        }
        Ok(offset)
    }
    pub(crate) fn finish(&mut self) -> Result<(), CacheError> {
        if self.cancel.is_cancelled() {
            return Err(CacheError::Cancelled);
        }
        let mut output = self.txn.create(self.staging.clone())?;
        self.cache
            .export_with_progress(&mut output, |_| !self.cancel.is_cancelled())?;
        apply_timestamps(&output, self.times);
        self.txn.publish(&self.staging, &self.name, &self.cancel)?;
        if let Some(tx) = &self.progress {
            let _ = tx.try_send(self.cache.identity().size);
        }
        Ok(())
    }
}

/// Durable native recovery owns a separate journal, never the orphan-cache
/// registry. No destructor preserves state accidentally: callers choose retain
/// only after a network suspension; explicit errors take the discard path.
pub(crate) struct DurableReceive {
    cache: Option<DownloadCache>,
    txn: Option<Transaction>,
    lease: Option<crate::receive_resume_registry::Lease>,
    registry: std::sync::Arc<crate::receive_resume_registry::Registry>,
    name: OsString,
    staging: OsString,
    cancel: CancellationToken,
    progress: Option<mpsc::Sender<u64>>,
    keep: bool,
    complete: bool,
}
impl DurableReceive {
    pub(crate) fn open(
        path: PathBuf,
        source: crate::receive_resume_registry::Source,
        owned_lease: Option<crate::receive_resume_registry::Lease>,
        approved_root: PathBuf,
        requested_name: String,
        receipt_id: String,
        times: FileTimestamps,
        cancel: CancellationToken,
        progress: Option<mpsc::Sender<u64>>,
        mut verify: impl FnMut(u64) -> bool,
    ) -> anyhow::Result<Self> {
        let registry = crate::receive_resume_registry::current()
            .ok_or_else(|| anyhow::anyhow!("Durable registry unavailable"))?;
        if cancel.is_cancelled() {
            anyhow::bail!("Recovery canceled");
        }
        let target =
            crate::receive_resume_registry::Target::new(&approved_root, &requested_name, &path)?;
        let mut lease = match owned_lease {
            Some(lease) => Some(lease),
            None => registry.claim(&source, &approved_root, &requested_name)?,
        };
        if let Some(old) = &lease {
            if old.record.target.path() != target.path() {
                anyhow::bail!("Recovery target changed");
            }
        }
        let name = path
            .file_name()
            .ok_or_else(|| anyhow::anyhow!("Invalid target"))?
            .to_os_string();
        let parent = path
            .parent()
            .ok_or_else(|| anyhow::anyhow!("Invalid target"))?;
        if let Some(old) = lease.as_mut() {
            if old
                .reconcile_published(|n| !cancel.is_cancelled() && verify(n))?
                .is_some()
            {
                let staging = OsString::from(old.record.staging_name());
                registry.cleanup_completed_cache(old)?;
                return Ok(Self {
                    cache: None,
                    txn: None,
                    lease,
                    registry,
                    name,
                    staging,
                    cancel,
                    progress,
                    keep: true,
                    complete: true,
                });
            }
            old.reset_export()?;
        }
        let dir = Dir::open_ambient_dir(parent, cap_std::ambient_authority())?;
        match dir.symlink_metadata(&name) {
            Ok(_) => anyhow::bail!("Receive destination already exists"),
            Err(e) if e.kind() == io::ErrorKind::NotFound => {}
            Err(e) => return Err(e.into()),
        }
        let mut txn = Transaction {
            dir,
            owned: Vec::new(),
            timestamps: times,
            registration: None,
            records: Vec::new(),
        };
        let (cache, staging) = if let Some(old) = lease.as_mut() {
            let opened = old.open_cache()?;
            let (cache, _) = old.resume_cache(|n| !cancel.is_cancelled() && verify(n))?;
            txn.owned
                .push((OsString::from(old.record.cache_name()), opened));
            old.receiving()?;
            (cache, OsString::from(old.record.staging_name()))
        } else {
            let now = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)?
                .as_millis() as u64;
            let identity =
                crate::receive_resume_registry::Registry::identity(&source, &target, now)?;
            let staging = OsString::from(format!(".legnasend-receive-{}.part", identity.task_id));
            let file = txn.create(OsString::from(format!(
                ".legnasend-receive-{}.ls",
                identity.task_id
            )))?;
            let registered =
                registry.create(source, target, identity.clone(), &file, receipt_id)?;
            let cache = DownloadCache::create(file, identity)?;
            lease = Some(registered);
            (cache, staging)
        };
        if cancel.is_cancelled() {
            anyhow::bail!("Recovery canceled");
        }
        Ok(Self {
            cache: Some(cache),
            txn: Some(txn),
            lease,
            registry,
            name,
            staging,
            cancel,
            progress,
            keep: false,
            complete: false,
        })
    }
    pub(crate) fn source_end_grant(
        &mut self,
        enabled: bool,
    ) -> anyhow::Result<Option<crate::http::source_end::SourceEndGrant>> {
        let lease = self
            .lease
            .as_mut()
            .ok_or_else(|| anyhow::anyhow!("Recovery lease unavailable"))?;
        self.registry
            .rotate_source_end(lease, enabled)
            .map_err(Into::into)
    }
    pub(crate) fn offset(&self) -> u64 {
        self.cache.as_ref().map_or_else(
            || self.lease.as_ref().unwrap().record.source.size,
            DownloadCache::committed_bytes,
        )
    }
    pub(crate) fn discard_on_drop(&mut self) {
        if !self.complete {
            self.keep = false;
        }
    }
    pub(crate) fn complete(&self) -> bool {
        self.complete
    }
    pub(crate) fn commit(&mut self, offset: u64, bytes: &[u8]) -> anyhow::Result<u64> {
        if self.cancel.is_cancelled() || !self.lease.as_ref().unwrap().valid_lease() {
            anyhow::bail!("Recovery canceled or expired");
        }
        if offset != self.offset() {
            anyhow::bail!("Recovery offset changed");
        }
        let cache = self
            .cache
            .as_mut()
            .ok_or_else(|| anyhow::anyhow!("Already published"))?;
        cache.commit_chunk(
            (offset / u64::from(crate::receive_resume_registry::BLOCK)).try_into()?,
            bytes,
        )?;
        let offset = cache.committed_bytes();
        self.lease.as_mut().unwrap().checkpoint_activity(false)?;
        if let Some(tx) = &self.progress {
            let _ = tx.try_send(offset.min(cache.identity().size.saturating_sub(1)));
        }
        Ok(offset)
    }
    pub(crate) fn suspend(&mut self) -> anyhow::Result<()> {
        if self.cancel.is_cancelled() || !self.lease.as_ref().unwrap().valid_lease() {
            anyhow::bail!("Recovery canceled or expired");
        }
        self.lease.as_mut().unwrap().suspend()?;
        self.keep = true;
        Ok(())
    }
    pub(crate) fn finish(&mut self) -> anyhow::Result<()> {
        if self.complete {
            return Ok(());
        }
        if self.cancel.is_cancelled() || !self.lease.as_ref().unwrap().valid_lease() {
            anyhow::bail!("Recovery canceled or expired");
        }
        let txn = self.txn.as_mut().unwrap();
        let mut output = txn.create(self.staging.clone())?;
        let lease = self.lease.as_mut().unwrap();
        lease.exporting(&output)?;
        let receipt = self
            .cache
            .as_mut()
            .unwrap()
            .export_with_progress(&mut output, |_| {
                !self.cancel.is_cancelled() && lease.valid_lease()
            })?;
        apply_timestamps(&output, txn.timestamps);
        lease.publishing(&receipt)?;
        txn.publish(&self.staging, &self.name, &self.cancel)?;
        // Publication is irreversible: no later cancel may erase the final file.
        self.keep = true;
        self.complete = true;
        lease.published(&output, &receipt)?;
        self.cache.take();
        txn.owned.clear();
        self.registry.cleanup_completed_cache(lease)?;
        if let Some(tx) = &self.progress {
            let _ = tx.try_send(receipt.bytes);
        }
        Ok(())
    }
}
impl Drop for DurableReceive {
    fn drop(&mut self) {
        self.cache.take();
        if let Some(txn) = &mut self.txn {
            txn.owned.clear();
        }
        if !self.keep {
            if let Some(mut lease) = self.lease.take() {
                match lease.discard() {
                    Ok(_) => {
                        if let Err(e) = self.registry.retire(lease) {
                            tracing::warn!("Durable receive retirement: {e}");
                        }
                    }
                    Err(e) => tracing::warn!("Durable receive cleanup: {e}"),
                }
            }
        }
    }
}

pub(super) fn apply_timestamps(output: &File, times: FileTimestamps) {
    let mut timestamps = std::fs::FileTimes::new();
    if let Some(t) = times.modified {
        timestamps = timestamps.set_modified(t);
    }
    if let Some(t) = times.accessed {
        timestamps = timestamps.set_accessed(t);
    }
    if times.modified.is_some() || times.accessed.is_some() {
        if let Err(e) = output.set_times(timestamps) {
            tracing::warn!("Receive timestamps not applied: {e}");
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    struct Root(PathBuf);
    impl Root {
        fn new() -> Self {
            let path = std::env::temp_dir()
                .join(format!("legnasend-receive-test-{}", uuid::Uuid::new_v4()));
            std::fs::create_dir(&path).unwrap();
            Self(path)
        }
        fn names(&self) -> Vec<OsString> {
            let mut names: Vec<_> = std::fs::read_dir(&self.0)
                .unwrap()
                .map(|e| e.unwrap().file_name())
                .collect();
            names.sort();
            names
        }
    }
    impl Drop for Root {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }
    fn context() -> Context {
        Context {
            cancel: CancellationToken::new(),
            session_id: "approved-session".into(),
            file_id: "opaque-id/中文".into(),
            attempt_id: uuid::Uuid::new_v4().to_string(),
            event_tx: mpsc::channel(8).0,
        }
    }
    fn messages(data: &[u8], finish: bool) -> mpsc::Receiver<Message> {
        let (tx, rx) = mpsc::channel(3);
        tx.try_send(Message::Data(Bytes::copy_from_slice(data)))
            .unwrap();
        if finish {
            tx.try_send(Message::Finish).unwrap();
        }
        rx
    }
    #[test]
    fn publishes_verified_original_bytes_timestamps_and_final_progress() {
        let root = Root::new();
        let path = root.0.join("中文 %.bin");
        let data = vec![73; 2 * 1024 * 1024 + 31];
        let sha = crate::crypto::hash::sha256_hex(&data);
        let identity = identity(&path, data.len() as u64, Some(&sha), &context());
        assert!(!identity.resource_id.contains('/'));
        let modified = std::time::UNIX_EPOCH + std::time::Duration::from_secs(1_600_000_000);
        let (tx, mut progress) = mpsc::channel(16);
        receive(
            path.clone(),
            identity,
            FileTimestamps {
                modified: Some(modified),
                accessed: None,
            },
            messages(&data, true),
            CancellationToken::new(),
            Some(tx),
        )
        .unwrap();
        assert_eq!(std::fs::read(&path).unwrap(), data);
        assert_eq!(
            std::fs::metadata(&path).unwrap().modified().unwrap(),
            modified
        );
        assert_eq!(root.names(), vec![path.file_name().unwrap().to_owned()]);
        let mut events = Vec::new();
        while let Ok(n) = progress.try_recv() {
            events.push(n);
        }
        assert_eq!(events.last(), Some(&(data.len() as u64)));
        assert!(events[..events.len() - 1]
            .iter()
            .all(|n| *n < data.len() as u64));
    }
    #[test]
    fn checksum_failure_cleans_only_owned_cache_and_retry_reuses_destination() {
        let root = Root::new();
        let path = root.0.join("out");
        std::fs::write(root.0.join("user.ls"), b"unrelated").unwrap();
        let sha = crate::crypto::hash::sha256_hex(b"right");
        let id = identity(&path, 5, Some(&sha), &context());
        assert!(matches!(
            receive(
                path.clone(),
                id,
                FileTimestamps::default(),
                messages(b"wrong", true),
                CancellationToken::new(),
                None
            ),
            Err(CacheError::Checksum)
        ));
        assert!(!path.exists());
        assert_eq!(root.names(), vec![OsString::from("user.ls")]);
        receive(
            path.clone(),
            identity(&path, 5, Some(&sha), &context()),
            FileTimestamps::default(),
            messages(b"right", true),
            CancellationToken::new(),
            None,
        )
        .unwrap();
        assert_eq!(std::fs::read(path).unwrap(), b"right");
        assert_eq!(std::fs::read(root.0.join("user.ls")).unwrap(), b"unrelated");
    }
    #[test]
    fn short_long_and_missing_eof_never_publish_even_when_size_matches() {
        for (data, size, finish) in [
            (b"abc".as_slice(), 4, true),
            (b"abc".as_slice(), 2, true),
            (b"abc".as_slice(), 3, false),
            (b"".as_slice(), 0, false),
        ] {
            let root = Root::new();
            let path = root.0.join("out");
            assert!(receive(
                path.clone(),
                identity(&path, size, None, &context()),
                FileTimestamps::default(),
                messages(data, finish),
                CancellationToken::new(),
                None
            )
            .is_err());
            assert!(root.names().is_empty());
        }
    }
    #[test]
    fn zero_byte_file_is_published_but_existing_destination_is_never_replaced() {
        let root = Root::new();
        let path = root.0.join("out");
        receive(
            path.clone(),
            identity(&path, 0, None, &context()),
            FileTimestamps::default(),
            messages(b"", true),
            CancellationToken::new(),
            None,
        )
        .unwrap();
        assert_eq!(std::fs::metadata(&path).unwrap().len(), 0);
        std::fs::write(&path, b"user content").unwrap();
        assert!(receive(
            path.clone(),
            identity(&path, 3, None, &context()),
            FileTimestamps::default(),
            messages(b"new", true),
            CancellationToken::new(),
            None
        )
        .is_err());
        assert_eq!(std::fs::read(&path).unwrap(), b"user content");
        assert_eq!(root.names(), vec![OsString::from("out")]);
    }
    #[test]
    fn late_destination_collision_is_atomic_and_cache_is_locked_until_cleanup() {
        let root = Root::new();
        let path = root.0.join("out");
        let id = identity(&path, 1024 * 1024, None, &context());
        let expected = id.clone();
        let cache_path = root.0.join(format!(".legnasend-receive-{}.ls", id.task_id));
        let (tx, rx) = mpsc::channel(2);
        let (ptx, mut prx) = mpsc::channel(16);
        let dest = path.clone();
        let worker = std::thread::spawn(move || {
            receive(
                dest,
                id,
                FileTimestamps::default(),
                rx,
                CancellationToken::new(),
                Some(ptx),
            )
        });
        tx.blocking_send(Message::Data(Bytes::from(vec![1; 1024 * 1024])))
            .unwrap();
        assert_eq!(prx.blocking_recv(), Some(1024 * 1024 - 1));
        assert!(!path.exists());
        let opened = std::fs::OpenOptions::new()
            .read(true)
            .write(true)
            .open(cache_path)
            .unwrap();
        assert!(matches!(
            DownloadCache::resume(opened, &expected),
            Err(CacheError::Busy)
        ));
        std::fs::write(&path, b"created by another program").unwrap();
        tx.blocking_send(Message::Finish).unwrap();
        drop(tx);
        assert!(worker.join().unwrap().is_err());
        assert_eq!(std::fs::read(path).unwrap(), b"created by another program");
        assert_eq!(root.names(), vec![OsString::from("out")]);
    }
    #[test]
    fn cancelled_transaction_cleans_owned_files_and_does_not_publish() {
        let root = Root::new();
        let path = root.0.join("out");
        let id = identity(&path, 2 * 1024 * 1024, None, &context());
        let (tx, rx) = mpsc::channel(2);
        let (ptx, mut prx) = mpsc::channel(16);
        let cancel = CancellationToken::new();
        let token = cancel.clone();
        let worker = std::thread::spawn(move || {
            receive(path, id, FileTimestamps::default(), rx, token, Some(ptx))
        });
        tx.blocking_send(Message::Data(Bytes::from(vec![1; 1024 * 1024])))
            .unwrap();
        assert_eq!(prx.blocking_recv(), Some(1024 * 1024));
        cancel.cancel();
        drop(tx);
        assert!(matches!(worker.join().unwrap(), Err(CacheError::Cancelled)));
        assert!(root.names().is_empty());
    }
    #[test]
    fn replacement_paths_are_not_published_or_cleaned_as_owned_files() {
        let root = Root::new();
        let mut txn = Transaction {
            dir: Dir::open_ambient_dir(&root.0, cap_std::ambient_authority()).unwrap(),
            owned: vec![],
            timestamps: FileTimestamps::default(),
            registration: None,
            records: Vec::new(),
        };
        let file = txn.create("owned.ls".into()).unwrap();
        drop(file);
        std::fs::rename(root.0.join("owned.ls"), root.0.join("moved.ls")).unwrap();
        std::fs::write(root.0.join("owned.ls"), b"external").unwrap();
        assert!(txn
            .publish(
                std::ffi::OsStr::new("owned.ls"),
                std::ffi::OsStr::new("out"),
                &CancellationToken::new()
            )
            .is_err());
        drop(txn);
        assert_eq!(std::fs::read(root.0.join("owned.ls")).unwrap(), b"external");
        assert!(root.0.join("moved.ls").exists());
        assert!(!root.0.join("out").exists());
    }
    #[cfg(unix)]
    #[test]
    fn cleanup_and_destination_checks_never_follow_symlinks() {
        let root = Root::new();
        let mut txn = Transaction {
            dir: Dir::open_ambient_dir(&root.0, cap_std::ambient_authority()).unwrap(),
            owned: vec![],
            timestamps: FileTimestamps::default(),
            registration: None,
            records: Vec::new(),
        };
        let file = txn.create("owned.ls".into()).unwrap();
        drop(file);
        std::fs::remove_file(root.0.join("owned.ls")).unwrap();
        std::fs::write(root.0.join("keep"), b"external").unwrap();
        std::os::unix::fs::symlink("keep", root.0.join("owned.ls")).unwrap();
        drop(txn);
        assert!(std::fs::symlink_metadata(root.0.join("owned.ls"))
            .unwrap()
            .is_symlink());
        let path = root.0.join("owned.ls");
        assert!(receive(
            path.clone(),
            identity(&path, 0, None, &context()),
            FileTimestamps::default(),
            messages(b"", true),
            CancellationToken::new(),
            None
        )
        .is_err());
        assert_eq!(std::fs::read(root.0.join("keep")).unwrap(), b"external");
    }
    #[test]
    fn export_birthtime_is_registered_after_sender_timestamp_is_applied() {
        let root = Root::new();
        let registry = std::sync::Arc::new(
            crate::receive_registry::Registry::open(root.0.join("registry")).unwrap(),
        );
        let id = identity(&root.0.join("out"), 4, None, &context());
        let name = OsString::from(format!(".legnasend-receive-{}.part", id.task_id));
        let times = FileTimestamps {
            modified: Some(std::time::UNIX_EPOCH + std::time::Duration::from_secs(1_600_000_000)),
            accessed: None,
        };
        let mut txn = Transaction {
            dir: Dir::open_ambient_dir(&root.0, cap_std::ambient_authority()).unwrap(),
            owned: vec![],
            records: vec![],
            timestamps: times,
            registration: Some((registry.clone(), root.0.clone(), id)),
        };
        let mut output = txn.create(name.clone()).unwrap();
        use std::io::Write;
        output.write_all(b"data").unwrap();
        apply_timestamps(&output, times);
        drop(output);
        // Release the handles without normal unlink, as after a process exit.
        txn.records.clear();
        txn.owned.clear();
        drop(txn);
        let report = registry.cleanup(100).unwrap();
        assert_eq!(report.removed_files, 1);
        assert!(!root.0.join(name).exists());
    }
}

#[cfg(test)]
#[path = "receive_cache_blocked_tests.rs"]
pub(super) mod blocked_tests;
