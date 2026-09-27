//! Versioned `.ls` containers, local to the receiving device; never wire payloads.
//!
//! All I/O is blocking: call this module from a worker, not a UI/network executor.
//! Callers supply exclusively owned, seekable read/write files opened through
//! their platform's destination authority. No path is reconstructed from metadata.
//! File locks are required, not silently bypassed on unsupported providers.
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::fs::{File, TryLockError};
use std::io::{self, Read, Seek, SeekFrom, Write};

const MAGIC: &[u8; 8] = b"LEGNALS\0";
const VERSION: u32 = 1;
const RECORD: &[u8; 8] = b"LSCHUNK1";
const COMMIT: &[u8; 8] = b"LSDONE1\0";
const HEADER_LIMIT: usize = 16 * 1024;
const BUFFER: usize = 64 * 1024;
pub const MIN_CHUNK_SIZE: u32 = 64 * 1024;
pub const MAX_CHUNK_SIZE: u32 = 8 * 1024 * 1024;
pub const MAX_CHUNKS: u64 = 1024 * 1024;

#[derive(thiserror::Error, Debug)]
pub enum CacheError {
    #[error("Cache storage operation failed: {0}")]
    Io(#[from] io::Error),
    #[error("Cache or output file is in use")]
    Busy,
    #[error("Invalid cache identity or limits")]
    Identity,
    #[error("Cache belongs to another task or source version")]
    IdentityMismatch,
    #[error("Unknown, incomplete or unsupported cache header")]
    Format,
    #[error("Cache record is damaged or duplicated")]
    Corrupt,
    #[error("Chunk index, length or existing bytes disagree")]
    Chunk,
    #[error("Cache must be reopened after a storage failure")]
    ReopenRequired,
    #[error("Download is not complete")]
    Incomplete,
    #[error("Output or cache file is not empty")]
    NotEmpty,
    #[error("Restored content does not match the expected source checksum")]
    Checksum,
    #[error("Cache operation cancelled")]
    Cancelled,
}
type Result<T> = std::result::Result<T, CacheError>;

/// The application registry owns this identity. It must contain no credentials:
/// source/resource IDs identify a resource; auth is kept separately by the caller.
/// `file_name` is display metadata, NEVER a filesystem destination.
#[derive(Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct CacheIdentity {
    pub task_id: String,
    pub source_id: String,
    pub resource_id: String,
    pub version: String,
    pub file_name: String,
    pub size: u64,
    pub chunk_size: u32,
    pub created_unix_ms: u64,
    pub sha256: Option<String>,
}

impl CacheIdentity {
    pub fn chunk_count(&self) -> u64 {
        self.size.div_ceil(u64::from(self.chunk_size.max(1)))
    }

    fn validate(&self) -> Result<()> {
        let valid_text =
            |s: &str, max| !s.is_empty() && s.len() <= max && !s.chars().any(char::is_control);
        if uuid::Uuid::parse_str(&self.task_id).is_err()
            || !valid_text(&self.source_id, 2048)
            || !valid_text(&self.resource_id, 4096)
            || !valid_text(&self.version, 1024)
            || self.file_name.is_empty()
            || self.file_name.len() > 4096
            || self.file_name.contains('\0')
            || !(MIN_CHUNK_SIZE..=MAX_CHUNK_SIZE).contains(&self.chunk_size)
            || self.chunk_count() > MAX_CHUNKS
            || self
                .sha256
                .as_ref()
                .is_some_and(|s| s.len() != 64 || !s.bytes().all(|b| b.is_ascii_hexdigit()))
        {
            return Err(CacheError::Identity);
        }
        Ok(())
    }

    fn chunk_len(&self, index: u32) -> Result<u32> {
        if u64::from(index) >= self.chunk_count() {
            return Err(CacheError::Chunk);
        }
        Ok((self.size - u64::from(index) * u64::from(self.chunk_size))
            .min(u64::from(self.chunk_size)) as u32)
    }
}

/// A single append writer can accept results from bounded parallel HTTP workers
/// in any order. Only a fully written, synced chunk counts as committed progress.
pub struct DownloadCache {
    file: File,
    identity: CacheIdentity,
    // Zero is absent; actual record positions always follow the nonempty header.
    // <= 8 MiB for one million chunks. Payloads are never retained here.
    offsets: Vec<u64>,
    committed: u64,
    end: u64,
    healthy: bool,
    durable: bool,
}

#[derive(Debug, PartialEq, Eq)]
pub struct Recovery {
    pub committed_bytes: u64,
    pub committed_chunks: u64,
    pub discarded_tail_bytes: u64,
}

#[derive(Debug, PartialEq, Eq)]
pub struct ExportReceipt {
    pub bytes: u64,
    pub sha256: String,
}

fn lock(file: &File, durable: bool) -> Result<()> {
    let result = if durable {
        crate::file_lock::try_exclusive_strict(file)
    } else {
        // Preserve the explicitly non-resumable ordinary receive policy.
        crate::file_lock::try_exclusive(file)
    };
    result.map_err(|error| match error {
        TryLockError::WouldBlock => CacheError::Busy,
        TryLockError::Error(error) => CacheError::Io(error),
    })
}

struct OutputLock<'a> {
    file: &'a mut File,
    held: bool,
    flavor: crate::file_lock::LockFlavor,
}
impl OutputLock<'_> {
    fn release(&mut self) -> io::Result<()> {
        crate::file_lock::unlock(self.file, self.flavor)?;
        self.held = false;
        Ok(())
    }
}
impl Drop for OutputLock<'_> {
    fn drop(&mut self) {
        if self.held {
            let _ = crate::file_lock::unlock(self.file, self.flavor);
        }
    }
}

fn array<const N: usize>(file: &mut File) -> io::Result<[u8; N]> {
    let mut value = [0; N];
    file.read_exact(&mut value)?;
    Ok(value)
}

fn header_error(error: io::Error) -> CacheError {
    if error.kind() == io::ErrorKind::UnexpectedEof {
        CacheError::Format
    } else {
        CacheError::Io(error)
    }
}

fn digest_hex(value: &[u8]) -> String {
    value.iter().map(|b| format!("{b:02x}")).collect()
}

impl DownloadCache {
    /// `file` must have been newly created by the caller with no-overwrite
    /// semantics in the chosen download directory. Existing bytes are rejected.
    pub fn create(file: File, identity: CacheIdentity) -> Result<Self> {
        Self::create_inner(file, identity, true)
    }

    /// A single non-resumable native receive attempt. Keep the identical checked
    /// format and exclusive lock, but use OS-buffered writes (like the original
    /// receiver), not per-file fsync. No crash-durable checkpoint is advertised.
    /// Only the receive transaction may use this; public create/resume remain
    /// durable, and receive attempts are discarded rather than resumed on wire.
    #[cfg(feature = "http")]
    pub(crate) fn create_receive_attempt(file: File, identity: CacheIdentity) -> Result<Self> {
        Self::create_inner(file, identity, false)
    }

    fn create_inner(file: File, identity: CacheIdentity, durable: bool) -> Result<Self> {
        Self::create_inner_with_lock(file, identity, durable, false)
    }

    /// The descriptor receive transaction already owns both exclusive locks.
    /// This avoids relocking the same descriptor, which is platform-dependent.
    #[cfg(feature = "http")]
    pub(crate) fn create_receive_attempt_locked(
        file: File,
        identity: CacheIdentity,
    ) -> Result<Self> {
        Self::create_inner_with_lock(file, identity, false, true)
    }

    fn create_inner_with_lock(
        mut file: File,
        identity: CacheIdentity,
        durable: bool,
        already_locked: bool,
    ) -> Result<Self> {
        identity.validate()?;
        let json = serde_json::to_vec(&identity).map_err(|_| CacheError::Identity)?;
        if json.len() > HEADER_LIMIT {
            return Err(CacheError::Identity);
        }
        if !already_locked {
            lock(&file, durable)?;
        }
        if file.metadata()?.len() != 0 {
            return Err(CacheError::NotEmpty);
        }
        let mut header = Vec::with_capacity(16 + json.len());
        header.extend_from_slice(MAGIC);
        header.extend_from_slice(&VERSION.to_le_bytes());
        header.extend_from_slice(&(json.len() as u32).to_le_bytes());
        header.extend_from_slice(&json);
        file.seek(SeekFrom::Start(0))?;
        file.write_all(&header)?;
        file.write_all(&Sha256::digest(&header))?;
        if durable {
            file.sync_data()?;
        }
        Ok(Self {
            end: (header.len() + 32) as u64,
            offsets: vec![0; identity.chunk_count() as usize],
            identity,
            file,
            committed: 0,
            healthy: true,
            durable,
        })
    }

    /// The expected identity comes from a managed task registry, not the file
    /// extension. Recovery verifies every committed payload before accepting it.
    /// Only an incomplete final record is truncated, after full validation.
    /// Unknown headers, identity mismatch and corrupt complete records are left
    /// untouched for diagnosis; this function is not a wildcard `.ls` cleaner.
    pub fn resume(file: File, expected: &CacheIdentity) -> Result<(Self, Recovery)> {
        Self::resume_with_progress(file, expected, |_| true)
    }

    /// Reports verified bytes after each complete chunk (and initially zero).
    /// Return false to cancel before any tail repair; releasing this operation
    /// releases its file lock. In-flight blocking platform I/O cannot be preempted.
    pub fn resume_with_progress(
        file: File,
        expected: &CacheIdentity,
        progress: impl FnMut(u64) -> bool,
    ) -> Result<(Self, Recovery)> {
        Self::resume_inner(file, expected, progress, false, true)
    }

    /// Copy verified committed records from an authorized candidate into a new,
    /// separately owned cache. The candidate is NEVER repaired or mutated. All
    /// three provider handles (source, destination, staging) are already locked.
    #[cfg(feature = "http")]
    pub(crate) fn recover_copy_locked(
        source: File,
        expected: &CacheIdentity,
        target: File,
        target_identity: CacheIdentity,
        mut progress: impl FnMut(u64, bool) -> bool,
    ) -> Result<(Self, Recovery)> {
        // New native transactions require their own task ID and creation time.
        // All source/content attributes must remain exactly bound to the source.
        let mut comparable = target_identity.clone();
        comparable.task_id = expected.task_id.clone();
        comparable.created_unix_ms = expected.created_unix_ms;
        if &comparable != expected {
            return Err(CacheError::IdentityMismatch);
        }
        target_identity.validate()?;
        let (mut source, recovery) =
            Self::resume_inner(source, expected, |bytes| progress(bytes, true), true, false)?;
        let mut target = Self::create_durable_locked(target, target_identity)?;
        let mut copied = 0;
        for index in 0..source.offsets.len() {
            if source.offsets[index] == 0 {
                continue;
            }
            if !progress(copied, false) {
                return Err(CacheError::Cancelled);
            }
            source
                .file
                .seek(SeekFrom::Start(source.offsets[index] + 16))?;
            let mut bytes = vec![0; expected.chunk_len(index as u32)? as usize];
            source.file.read_exact(&mut bytes)?;
            // Validate again against the source record digest before committing
            // copied bytes, including providers that ignore advisory exclusion.
            let mut record = [0; 16];
            record[..8].copy_from_slice(RECORD);
            record[8..12].copy_from_slice(&(index as u32).to_le_bytes());
            record[12..].copy_from_slice(&(bytes.len() as u32).to_le_bytes());
            let mut hash = Sha256::new();
            hash.update(record);
            hash.update(&bytes);
            if array::<32>(&mut source.file)? != hash.finalize().as_slice()
                || &array::<8>(&mut source.file)? != COMMIT
            {
                return Err(CacheError::Corrupt);
            }
            target.commit_chunk(index as u32, &bytes)?;
            copied += bytes.len() as u64;
            if !progress(copied, false) {
                return Err(CacheError::Cancelled);
            }
        }
        Ok((target, recovery))
    }

    /// Both descriptors were independently locked by the provider transaction.
    /// Keep that exact lock lifetime through validation, tail repair and export.
    #[cfg(feature = "http")]
    pub(crate) fn resume_locked(
        file: File,
        expected: &CacheIdentity,
        progress: impl FnMut(u64) -> bool,
    ) -> Result<(Self, Recovery)> {
        Self::resume_inner(file, expected, progress, true, true)
    }

    #[cfg(feature = "http")]
    pub(crate) fn create_durable_locked(file: File, identity: CacheIdentity) -> Result<Self> {
        Self::create_inner_with_lock(file, identity, true, true)
    }

    fn resume_inner(
        mut file: File,
        expected: &CacheIdentity,
        mut progress: impl FnMut(u64) -> bool,
        already_locked: bool,
        repair_tail: bool,
    ) -> Result<(Self, Recovery)> {
        expected.validate()?;
        if !progress(0) {
            return Err(CacheError::Cancelled);
        }
        if !already_locked {
            lock(&file, true)?;
        }
        file.seek(SeekFrom::Start(0))?;
        let mut header = array::<16>(&mut file).map_err(header_error)?.to_vec();
        if &header[..8] != MAGIC || u32::from_le_bytes(header[8..12].try_into().unwrap()) != VERSION
        {
            return Err(CacheError::Format);
        }
        let length = u32::from_le_bytes(header[12..16].try_into().unwrap()) as usize;
        if length == 0 || length > HEADER_LIMIT {
            return Err(CacheError::Format);
        }
        header.resize(16 + length, 0);
        file.read_exact(&mut header[16..]).map_err(header_error)?;
        let digest = array::<32>(&mut file).map_err(header_error)?;
        if Sha256::digest(&header).as_slice() != digest {
            return Err(CacheError::Format);
        }
        let identity: CacheIdentity =
            serde_json::from_slice(&header[16..]).map_err(|_| CacheError::Format)?;
        identity.validate()?;
        if &identity != expected {
            return Err(CacheError::IdentityMismatch);
        }
        let length = file.metadata()?.len();
        let mut cache = Self {
            end: (header.len() + 32) as u64,
            offsets: vec![0; identity.chunk_count() as usize],
            identity,
            file,
            committed: 0,
            healthy: true,
            durable: true,
        };
        let mut count = 0;
        while cache.end < length {
            if length - cache.end < 16 {
                break;
            }
            cache.file.seek(SeekFrom::Start(cache.end))?;
            let record = array::<16>(&mut cache.file)?;
            let (index, size) = cache.record_info(&record)?;
            if cache.offsets[index as usize] != 0 {
                return Err(CacheError::Corrupt);
            }
            if length - cache.end < 16 + u64::from(size) + 40 {
                break;
            }
            cache.verify_payload(&record, size, None)?;
            cache.offsets[index as usize] = cache.end;
            cache.end += 16 + u64::from(size) + 40;
            cache.committed += u64::from(size);
            count += 1;
            if !progress(cache.committed) {
                return Err(CacheError::Cancelled);
            }
        }
        let discarded_tail_bytes = length - cache.end;
        if discarded_tail_bytes > 0 && repair_tail {
            cache.file.set_len(cache.end)?;
            cache.file.sync_data()?;
        }
        let recovery = Recovery {
            committed_bytes: cache.committed,
            committed_chunks: count,
            discarded_tail_bytes,
        };
        Ok((cache, recovery))
    }

    pub fn identity(&self) -> &CacheIdentity {
        &self.identity
    }

    pub fn committed_bytes(&self) -> u64 {
        self.committed
    }

    pub fn missing_chunks(&self) -> impl Iterator<Item = u32> + '_ {
        self.offsets
            .iter()
            .enumerate()
            .filter_map(|(i, &offset)| (offset == 0).then_some(i as u32))
    }

    /// Caller already knows that every byte before `offset` is committed.
    #[cfg(feature = "http")]
    pub(crate) fn contiguous_prefix_from(&self, offset: u64) -> u64 {
        let start = (offset / u64::from(self.identity.chunk_size)) as usize;
        self.offsets
            .iter()
            .enumerate()
            .skip(start)
            .find_map(|(index, record)| {
                (*record == 0).then_some(index as u64 * u64::from(self.identity.chunk_size))
            })
            .unwrap_or(self.identity.size)
    }

    pub fn is_complete(&self) -> bool {
        self.healthy && self.committed == self.identity.size
    }

    fn record_info(&self, record: &[u8; 16]) -> Result<(u32, u32)> {
        let index = u32::from_le_bytes(record[8..12].try_into().unwrap());
        let size = u32::from_le_bytes(record[12..16].try_into().unwrap());
        if &record[..8] != RECORD || self.identity.chunk_len(index).ok() != Some(size) {
            return Err(CacheError::Corrupt);
        }
        Ok((index, size))
    }

    fn verify_payload(
        &mut self,
        record: &[u8; 16],
        size: u32,
        mut output: Option<(&mut File, &mut Sha256)>,
    ) -> Result<()> {
        let mut hash = Sha256::new();
        hash.update(record);
        let mut buffer = [0; BUFFER];
        let mut remaining = size as usize;
        while remaining > 0 {
            let n = remaining.min(buffer.len());
            self.file.read_exact(&mut buffer[..n])?;
            hash.update(&buffer[..n]);
            if let Some((file, content_hash)) = output.as_mut() {
                file.write_all(&buffer[..n])?;
                content_hash.update(&buffer[..n]);
            }
            remaining -= n;
        }
        if array::<32>(&mut self.file)? != hash.finalize().as_slice()
            || &array::<8>(&mut self.file)? != COMMIT
        {
            return Err(CacheError::Corrupt);
        }
        Ok(())
    }

    /// Returns false for an exact replay. Conflicting duplicates never overwrite.
    /// The caller bounds HTTP buffers/concurrency and sends each result here once.
    pub fn commit_chunk(&mut self, index: u32, bytes: &[u8]) -> Result<bool> {
        if !self.healthy {
            return Err(CacheError::ReopenRequired);
        }
        let size = self.identity.chunk_len(index)?;
        if bytes.len() != size as usize {
            return Err(CacheError::Chunk);
        }
        let mut record = [0; 16];
        record[..8].copy_from_slice(RECORD);
        record[8..12].copy_from_slice(&index.to_le_bytes());
        record[12..16].copy_from_slice(&size.to_le_bytes());
        let mut hash = Sha256::new();
        hash.update(record);
        hash.update(bytes);
        let digest = hash.finalize();
        let previous = self.offsets[index as usize];
        if previous != 0 {
            self.file.seek(SeekFrom::Start(previous))?;
            if array::<16>(&mut self.file)? != record {
                return Err(CacheError::Corrupt);
            }
            self.verify_payload(&record, size, None)?;
            self.file
                .seek(SeekFrom::Start(previous + 16 + u64::from(size)))?;
            return if array::<32>(&mut self.file)? == digest.as_slice() {
                Ok(false)
            } else {
                Err(CacheError::Chunk)
            };
        }
        // An uncertain append must be recovered before any subsequent write.
        self.healthy = false;
        self.file.seek(SeekFrom::Start(self.end))?;
        self.file.write_all(&record)?;
        self.file.write_all(bytes)?;
        self.file.write_all(&digest)?;
        self.file.write_all(COMMIT)?;
        if self.durable {
            self.file.sync_data()?;
        }
        self.offsets[index as usize] = self.end;
        self.end += 16 + u64::from(size) + 40;
        self.committed += u64::from(size);
        self.healthy = true;
        Ok(true)
    }

    /// Restore only original bytes, in source order, to a newly created empty
    /// staging file owned by the task. This never renames the `.ls` container or
    /// removes it. The caller owns atomic publication/no-overwrite and cleanup;
    /// a receipt is returned only after checksum verification and output sync.
    /// A failure can leave a partial staging file, while the cache stays intact.
    pub fn export(&mut self, output: &mut File) -> Result<ExportReceipt> {
        self.export_with_progress(output, |_| true)
    }

    /// Reports verified/written bytes, not final publication. Returning false
    /// retains the cache and leaves output staging ownership with the caller.
    pub fn export_with_progress(
        &mut self,
        output: &mut File,
        progress: impl FnMut(u64) -> bool,
    ) -> Result<ExportReceipt> {
        if !self.healthy {
            return Err(CacheError::ReopenRequired);
        }
        if !self.is_complete() {
            return Err(CacheError::Incomplete);
        }
        let acquired = if self.durable {
            crate::file_lock::acquire_strict(output)
        } else {
            crate::file_lock::acquire(output)
        };
        let flavor = acquired.map_err(|error| match error {
            TryLockError::WouldBlock => CacheError::Busy,
            TryLockError::Error(error) => CacheError::Io(error),
        })?;
        let mut output = OutputLock {
            file: output,
            held: true,
            flavor,
        };
        let result = self.export_locked(output.file, progress);
        // The output handle remains with its caller, unlike the owned cache.
        let unlocked = output.release();
        match result {
            Err(error) => Err(error),
            Ok(receipt) => {
                unlocked?;
                Ok(receipt)
            }
        }
    }

    /// Export under the receive transaction's existing output lock. The caller
    /// retains that lock until closing the descriptor before publication.
    #[cfg(feature = "http")]
    pub(crate) fn export_receive_attempt_locked(
        &mut self,
        output: &mut File,
        progress: impl FnMut(u64) -> bool,
    ) -> Result<ExportReceipt> {
        if !self.healthy {
            return Err(CacheError::ReopenRequired);
        }
        if !self.is_complete() {
            return Err(CacheError::Incomplete);
        }
        self.export_locked(output, progress)
    }

    fn export_locked(
        &mut self,
        output: &mut File,
        mut progress: impl FnMut(u64) -> bool,
    ) -> Result<ExportReceipt> {
        if output.metadata()?.len() != 0 {
            return Err(CacheError::NotEmpty);
        }
        output.seek(SeekFrom::Start(0))?;
        if !progress(0) {
            return Err(CacheError::Cancelled);
        }
        let mut hash = Sha256::new();
        let mut verified = 0;
        for index in 0..self.offsets.len() {
            self.file.seek(SeekFrom::Start(self.offsets[index]))?;
            let record = array::<16>(&mut self.file)?;
            let (actual, size) = self.record_info(&record)?;
            if actual as usize != index {
                return Err(CacheError::Corrupt);
            }
            self.verify_payload(&record, size, Some((output, &mut hash)))?;
            verified += u64::from(size);
            if !progress(verified) {
                return Err(CacheError::Cancelled);
            }
        }
        let sha256 = digest_hex(&hash.finalize());
        if self
            .identity
            .sha256
            .as_ref()
            .is_some_and(|expected| !expected.eq_ignore_ascii_case(&sha256))
        {
            return Err(CacheError::Checksum);
        }
        if output.metadata()?.len() != self.identity.size {
            return Err(CacheError::Incomplete);
        }
        if self.durable {
            output.sync_data()?;
        } else {
            output.flush()?;
        }
        Ok(ExportReceipt {
            bytes: self.identity.size,
            sha256,
        })
    }
}

#[cfg(all(test, feature = "http"))]
mod receive_attempt_tests {
    use super::*;
    #[test]
    fn ephemeral_receive_format_remains_readable_and_public_recovery_stays_durable() {
        let dir =
            std::env::temp_dir().join(format!("legnasend-cache-mode-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir(&dir).unwrap();
        let open = |name: &str| {
            std::fs::OpenOptions::new()
                .read(true)
                .write(true)
                .create_new(true)
                .open(dir.join(name))
                .unwrap()
        };
        let identity = CacheIdentity {
            task_id: uuid::Uuid::new_v4().to_string(),
            source_id: "source".into(),
            resource_id: "file".into(),
            version: "attempt".into(),
            file_name: "original".into(),
            size: 3,
            chunk_size: MIN_CHUNK_SIZE,
            created_unix_ms: 0,
            sha256: None,
        };
        let mut attempt =
            DownloadCache::create_receive_attempt(open("attempt.ls"), identity.clone()).unwrap();
        assert!(!attempt.durable);
        attempt.commit_chunk(0, b"abc").unwrap();
        drop(attempt);
        let file = std::fs::OpenOptions::new()
            .read(true)
            .write(true)
            .open(dir.join("attempt.ls"))
            .unwrap();
        let (mut recovered, report) = DownloadCache::resume(file, &identity).unwrap();
        assert!(recovered.durable);
        assert_eq!(report.committed_bytes, 3);
        let mut output = open("out");
        recovered.export(&mut output).unwrap();
        assert_eq!(std::fs::read(dir.join("out")).unwrap(), b"abc");
        let public = DownloadCache::create(open("durable.ls"), identity).unwrap();
        assert!(public.durable);
        drop((public, recovered, output));
        std::fs::remove_dir_all(dir).unwrap();
    }
}
