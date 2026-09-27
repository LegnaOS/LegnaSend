//! Durable byte recovery from provider-owned handles, never guessed paths.
//!
//! The platform must revalidate its durable source/authorization journal before
//! calling this API. It transfers independent opens for the registered cache and
//! a NEW empty export staging document. The core owns/locks both until close;
//! it never deletes, renames or publishes provider documents. Native publication
//! must still verify ownership and durably acknowledge the returned receipt.
use crate::download_cache::{CacheError, CacheIdentity, DownloadCache, ExportReceipt, Recovery};
use sha2::{Digest, Sha256};
use std::fs::{File, TryLockError};
use std::io::{self, Read, Seek, SeekFrom};

/// Copy recovery reports phases separately; verification never masquerades as
/// newly downloaded bytes, and copying does not reset a network byte counter.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RecoveryProgress {
    Verifying(u64),
    Copying(u64),
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CopyRecovery {
    /// Exact historical container, including header and any incomplete tail.
    pub source_length: u64,
    pub source_sha256: String,
    pub committed_bytes: u64,
    pub committed_chunks: u64,
    /// Identified in the old source, deliberately left untouched.
    pub retained_tail_bytes: u64,
}

/// Byte-level receive transaction for a separately authenticated, stable source.
/// Dropping retains the durable .ls file, and closes both handles. Source-end and
/// user cancellation cleanup are exclusively the platform journal's decision.
pub struct DescriptorReceive {
    cache: DownloadCache,
    staging: File,
    offset: u64,
    failed: bool,
}

impl DescriptorReceive {
    /// Consume and close a temporary provider pair after a real capability
    /// check. This writes no header or payload and is not a future-access grant.
    pub fn probe(cache: File, staging: File) -> Result<(), CacheError> {
        let (cache, _staging) = admit(cache, staging)?;
        if cache.metadata()?.len() != 0 {
            return Err(CacheError::NotEmpty);
        }
        Ok(())
    }

    /// Start a durable cache. Existing bytes are never replaced or truncated.
    pub fn create(cache: File, staging: File, identity: CacheIdentity) -> Result<Self, CacheError> {
        require_strong_identity(&identity)?;
        let (cache, staging) = admit(cache, staging)?;
        let cache = DownloadCache::create_durable_locked(cache, identity)?;
        Ok(Self {
            cache,
            staging,
            offset: 0,
            failed: false,
        })
    }

    /// Resume only the full expected identity from the trusted private journal,
    /// not one inferred from a filename or read back from untrusted cache bytes.
    /// Every complete record is verified before an incomplete tail is repaired.
    /// Nonempty export staging is rejected, NOT reset: the native owner must
    /// reconcile any previous publication and allocate new staging if appropriate.
    pub fn resume(
        cache: File,
        staging: File,
        identity: &CacheIdentity,
        progress: impl FnMut(u64) -> bool,
    ) -> Result<(Self, Recovery), CacheError> {
        require_strong_identity(identity)?;
        let (cache, staging) = admit(cache, staging)?;
        let (cache, recovery) = DownloadCache::resume_locked(cache, identity, progress)?;
        let offset = cache.contiguous_prefix_from(0);
        Ok((
            Self {
                cache,
                staging,
                offset,
                failed: false,
            },
            recovery,
        ))
    }

    /// Cross-process provider recovery when historical in-place ownership cannot
    /// be proven: read/verify the old candidate, copy committed blocks into a NEW
    /// cache and retain the old file unchanged (including an incomplete tail).
    /// The platform must persist the new document generation before serving its
    /// offset or accepting additional bytes; a failed call leaves new documents
    /// for that owner's transaction cleanup, never deletes provider data here.
    pub fn recover_copy(
        source: File,
        cache: File,
        staging: File,
        identity: &CacheIdentity,
        progress: impl FnMut(RecoveryProgress) -> bool,
    ) -> Result<(Self, CopyRecovery), CacheError> {
        Self::recover_copy_as(source, cache, staging, identity, identity.clone(), progress)
    }

    /// Recover into a new registered native transaction, never reuse an old
    /// transaction's publication identity. Only task ID/time may change.
    pub fn recover_copy_as(
        mut source: File,
        cache: File,
        staging: File,
        identity: &CacheIdentity,
        target_identity: CacheIdentity,
        mut progress: impl FnMut(RecoveryProgress) -> bool,
    ) -> Result<(Self, CopyRecovery), CacheError> {
        require_strong_identity(identity)?;
        if !source.metadata()?.is_file() {
            return Err(CacheError::Identity);
        }
        if aliases(&source, &cache)? || aliases(&source, &staging)? {
            return Err(io::Error::other("Recovery source aliases destination").into());
        }
        source.seek(SeekFrom::Start(0))?;
        crate::file_lock::try_shared_strict(&source).map_err(|error| match error {
            TryLockError::WouldBlock => CacheError::Busy,
            TryLockError::Error(error) => CacheError::Io(error),
        })?;
        let (cache, staging) = admit(cache, staging)?;
        if cache.metadata()?.len() != 0 {
            return Err(CacheError::NotEmpty);
        }
        let mut witness = source.try_clone()?;
        let before = container_fingerprint(&mut witness, &mut || {
            progress(RecoveryProgress::Verifying(0))
        })?;
        let (cache, recovery) = DownloadCache::recover_copy_locked(
            source,
            identity,
            cache,
            target_identity,
            |bytes, verifying| {
                progress(if verifying {
                    RecoveryProgress::Verifying(bytes)
                } else {
                    RecoveryProgress::Copying(bytes)
                })
            },
        )?;
        let after = container_fingerprint(&mut witness, &mut || {
            progress(RecoveryProgress::Copying(recovery.committed_bytes))
        })?;
        if before != after {
            return Err(CacheError::IdentityMismatch);
        }
        // witness keeps the original open-description lock alive through both
        // hashes and verified copying. No historical bytes are changed here.
        let offset = cache.contiguous_prefix_from(0);
        let recovery = CopyRecovery {
            source_length: after.0,
            source_sha256: after.1,
            committed_bytes: recovery.committed_bytes,
            committed_chunks: recovery.committed_chunks,
            retained_tail_bytes: recovery.discarded_tail_bytes,
        };
        Ok((
            Self {
                cache,
                staging,
                offset,
                failed: false,
            },
            recovery,
        ))
    }

    /// The verified contiguous prefix, not the sum of possibly sparse records.
    pub fn offset(&self) -> u64 {
        self.offset
    }

    /// Accept one exact source block at the current contiguous offset. The
    /// format's synced commit marker, not bytes merely written, advances progress.
    pub fn commit(&mut self, offset: u64, bytes: &[u8]) -> Result<u64, CacheError> {
        if self.failed {
            return Err(CacheError::ReopenRequired);
        }
        if offset != self.offset || offset >= self.cache.identity().size {
            return Err(CacheError::Chunk);
        }
        let index = u32::try_from(offset / u64::from(self.cache.identity().chunk_size))
            .map_err(|_| CacheError::Chunk)?;
        // A failed append may have an uncertain outcome. Force verification of
        // the on-disk record before another command can continue this writer.
        self.failed = true;
        self.cache.commit_chunk(index, bytes)?;
        self.offset = self.cache.contiguous_prefix_from(self.offset);
        self.failed = false;
        Ok(self.offset)
    }

    /// Export verified original bytes, flush staging, and close BOTH handles
    /// before returning the receipt. The receipt is not publication success.
    /// Even complete cached content must pass the full-source hash here.
    pub fn finish(
        mut self,
        progress: impl FnMut(u64) -> bool,
    ) -> Result<ExportReceipt, CacheError> {
        if self.failed {
            return Err(CacheError::ReopenRequired);
        }
        self.cache
            .export_receive_attempt_locked(&mut self.staging, progress)
    }
}

/// An exclusive, content-verified lease. The native caller must keep this alive
/// across its identity recheck and deletion acknowledgement. Never deletes files.
pub struct ReceiveCleanupGuard {
    _file: File,
}
impl ReceiveCleanupGuard {
    pub fn acquire(
        mut file: File,
        expected_length: u64,
        expected_sha256: &str,
        mut is_active: impl FnMut() -> bool,
    ) -> Result<Self, CacheError> {
        if expected_sha256.len() != 64 || !expected_sha256.bytes().all(|b| b.is_ascii_hexdigit()) {
            return Err(CacheError::Identity);
        }
        if !is_active() {
            return Err(CacheError::Cancelled);
        }
        if !file.metadata()?.is_file() {
            return Err(CacheError::Identity);
        }
        strict_lock(&file)?;
        let before = PublicationStamp::of(&file)?;
        if before.length != expected_length {
            return Err(CacheError::IdentityMismatch);
        }
        let (length, sha256) = container_fingerprint(&mut file, &mut is_active)?;
        let after = PublicationStamp::of(&file)?;
        // Providers may ignore advisory exclusion. A same-size rewrite of an
        // already-hashed block must not authorize deleting the changed file.
        if before != after
            || length != expected_length
            || !sha256.eq_ignore_ascii_case(expected_sha256)
        {
            return Err(CacheError::IdentityMismatch);
        }
        Ok(Self { _file: file })
    }
}

/// A read-only verification lease for an already visible publication. This is
/// not deletion authority and must never be substituted with the cleanup EX guard.
/// Native confirms its pinned output identity and persists PUBLISHED while the
/// shared lock is still held, then explicitly releases this guard.
pub struct ReceivePublicationGuard {
    _file: File,
}
impl ReceivePublicationGuard {
    pub fn acquire(
        mut file: File,
        expected_length: u64,
        expected_sha256: &str,
        mut is_active: impl FnMut() -> bool,
    ) -> Result<Self, CacheError> {
        if expected_sha256.len() != 64 || !expected_sha256.bytes().all(|b| b.is_ascii_hexdigit()) {
            return Err(CacheError::Identity);
        }
        if !is_active() {
            return Err(CacheError::Cancelled);
        }
        if !file.metadata()?.is_file() {
            return Err(CacheError::Identity);
        }
        crate::file_lock::try_shared_strict(&file).map_err(|error| match error {
            TryLockError::WouldBlock => CacheError::Busy,
            TryLockError::Error(error) => CacheError::Io(error),
        })?;
        let before = PublicationStamp::of(&file)?;
        if before.length != expected_length {
            return Err(CacheError::IdentityMismatch);
        }
        // The caller transferred an independent read-only open. The fixed-buffer
        // hash may seek that transport, never a separately retained native witness.
        let (length, digest) = container_fingerprint(&mut file, &mut is_active)?;
        let after = PublicationStamp::of(&file)?;
        if before != after
            || length != expected_length
            || !digest.eq_ignore_ascii_case(expected_sha256)
        {
            return Err(CacheError::IdentityMismatch);
        }
        Ok(Self { _file: file })
    }
}

#[derive(PartialEq, Eq)]
struct PublicationStamp {
    identity: same_file::Handle,
    length: u64,
    modified: std::time::SystemTime,
    created: Option<std::time::SystemTime>,
    #[cfg(unix)]
    change_time: (i64, i64),
}
impl PublicationStamp {
    fn of(file: &File) -> Result<Self, CacheError> {
        let meta = file.metadata()?;
        if !meta.is_file() {
            return Err(CacheError::Identity);
        }
        Ok(Self {
            identity: same_file::Handle::from_file(file.try_clone()?)?,
            length: meta.len(),
            modified: meta.modified()?,
            // Android providers need not expose birth time; identity is still
            // the held file handle, not a guessed path or creation timestamp.
            created: meta.created().ok(),
            #[cfg(unix)]
            change_time: {
                use std::os::unix::fs::MetadataExt;
                (meta.ctime(), meta.ctime_nsec())
            },
        })
    }
}

fn container_fingerprint(
    file: &mut File,
    is_active: &mut impl FnMut() -> bool,
) -> Result<(u64, String), CacheError> {
    let meta = file.metadata()?;
    // Bound disk work by the format's maximum payload and record/header budget.
    let max = u64::from(crate::download_cache::MAX_CHUNK_SIZE) * crate::download_cache::MAX_CHUNKS
        + 56 * crate::download_cache::MAX_CHUNKS
        + 16 * 1024
        + 48;
    if !meta.is_file() || meta.len() > max {
        return Err(CacheError::Identity);
    }
    let length = meta.len();
    file.seek(SeekFrom::Start(0))?;
    let mut hash = Sha256::new();
    let mut read = 0;
    let mut buffer = [0u8; 64 * 1024];
    while read < length {
        if !is_active() {
            return Err(CacheError::Cancelled);
        }
        let count = (length - read).min(buffer.len() as u64) as usize;
        file.read_exact(&mut buffer[..count])?;
        hash.update(&buffer[..count]);
        read += count as u64;
    }
    if !is_active() {
        return Err(CacheError::Cancelled);
    }
    if file.metadata()?.len() != length || file.read(&mut buffer[..1])? != 0 {
        return Err(CacheError::IdentityMismatch);
    }
    Ok((length, crate::crypto::hash::to_hex(&hash.finalize())))
}

fn require_strong_identity(identity: &CacheIdentity) -> Result<(), CacheError> {
    if !identity
        .sha256
        .as_ref()
        .is_some_and(|hash| hash.len() == 64 && hash.bytes().all(|b| b.is_ascii_hexdigit()))
    {
        return Err(CacheError::Identity);
    }
    Ok(())
}

fn admit(mut cache: File, mut staging: File) -> Result<(File, File), CacheError> {
    if !cache.metadata()?.is_file() || !staging.metadata()?.is_file() {
        return Err(io::Error::other("Receive descriptors must be regular files").into());
    }
    if aliases(&cache, &staging)? {
        return Err(io::Error::other("Receive descriptors must be distinct").into());
    }
    cache.seek(SeekFrom::Start(0))?;
    staging.seek(SeekFrom::Start(0))?;
    strict_lock(&cache)?;
    strict_lock(&staging)?;
    // Check this BEFORE cache tail repair: rejecting a foreign or previously
    // exported staging document must leave both input files unmodified.
    if staging.metadata()?.len() != 0 {
        return Err(CacheError::NotEmpty);
    }
    Ok((cache, staging))
}

fn aliases(a: &File, b: &File) -> Result<bool, CacheError> {
    Ok(same_file::Handle::from_file(a.try_clone()?)?
        == same_file::Handle::from_file(b.try_clone()?)?)
}
fn strict_lock(file: &File) -> Result<(), CacheError> {
    crate::file_lock::try_exclusive_strict(file).map_err(|error| match error {
        TryLockError::WouldBlock => CacheError::Busy,
        TryLockError::Error(error) => CacheError::Io(error),
    })
}
