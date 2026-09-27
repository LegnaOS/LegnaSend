//! Descriptor receive foundation. The provider owns document names, publication
//! and its durable cleanup journal; core owns only the two transferred handles.
//! Provider selection stays in Dart; this internal target keeps the wire protocol unchanged.
use super::receive_cache::{ACTIVE, Context, apply_timestamps, identity};
use super::save::{FileTimestamps, SaveResult};
use crate::download_cache::{CacheError, CacheIdentity, DownloadCache, ExportReceipt};
use crate::http::server::v2::ServerEventV2;
use bytes::Bytes;
use http_body_util::BodyExt;
use hyper::{Request, body::Incoming};
use std::fs::{File, TryLockError};
use std::io::{self, Seek, SeekFrom};
use std::time::Duration;
use tokio::sync::{mpsc, oneshot};
use tokio_util::sync::CancellationToken;

const FRAME_BYTES: usize = 64 * 1024;
const QUEUE: usize = 8;
// Provider publication includes verification, copy, close and independent readback.
// A fixed one-minute cutoff rejects healthy multi-GB files after the body finished.
// Budget conservatively at one MiB of original data per second plus fixed overhead;
// this is a bounded allowance, not measured throughput or a peer timeout promise.
const PUBLICATION_BASE_SECONDS: u64 = 60;
const PUBLICATION_MAX_SECONDS: u64 = 6 * 60 * 60;
const PUBLICATION_BYTES_PER_SECOND: u64 = 1024 * 1024;

fn publication_timeout(verified_bytes: u64) -> Duration {
    Duration::from_secs(
        PUBLICATION_BASE_SECONDS
            .saturating_add(verified_bytes.div_ceil(PUBLICATION_BYTES_PER_SECOND))
            .min(PUBLICATION_MAX_SECONDS),
    )
}

pub(crate) enum Message {
    Data(Bytes),
    // A channel drop (even after size bytes) is never a successful EOF.
    Finish,
}

pub(super) struct Target {
    pub cache: File,
    pub staging: File,
    pub transaction_id: String,
    pub result_tx: oneshot::Sender<Result<(), String>>,
    pub progress_tx: Option<mpsc::Sender<u64>>,
}

pub(crate) struct Release {
    context: Context,
    transaction_id: String,
    published: bool,
}
impl Release {
    pub(crate) fn new(context: Context, transaction_id: String) -> Self {
        Self {
            context,
            transaction_id,
            published: false,
        }
    }
    /// Registration is a separate responder namespace from final publication:
    /// a delayed journal acknowledgement cannot approve a later output copy.
    pub(crate) async fn bind_identity(
        &self,
        identity: &CacheIdentity,
        cancel: &CancellationToken,
    ) -> Result<Option<crate::http::server::v2::CacheRecoverySource>, String> {
        let identity_json =
            serde_json::to_string(identity).map_err(|_| "Invalid receive identity".to_owned())?;
        tokio::select! {
            biased;
            _ = cancel.cancelled() => Err("Receive identity registration cancelled".to_owned()),
            result = tokio::time::timeout(Duration::from_secs(60), async {
                let (result_tx, result_rx) = oneshot::channel();
                self.context.event_tx.send(ServerEventV2::ReceiveCacheIdentity {
                    session_id: self.context.session_id.clone(), file_id: self.context.file_id.clone(),
                    attempt_id: self.context.attempt_id.clone(), transaction_id: self.transaction_id.clone(),
                    identity_json, result_tx,
                }).await.map_err(|_| "Receive identity channel closed".to_owned())?;
                result_rx.await.map_err(|_| "Receive identity acknowledgement dropped".to_owned())?
            }) => result.unwrap_or_else(|_| Err("Receive identity registration timed out".to_owned())),
        }
    }

    pub(crate) async fn recovered(
        &self,
        source_transaction_id: String,
        source_length: u64,
        source_sha256: String,
        cancel: &CancellationToken,
    ) -> Result<(), String> {
        tokio::select! {
            biased;
            _ = cancel.cancelled() => Err("Receive recovery cancelled".to_owned()),
            result = tokio::time::timeout(Duration::from_secs(60), async {
                let (result_tx, result_rx) = oneshot::channel();
                self.context.event_tx.send(ServerEventV2::ReceiveCacheRecovered {
                    session_id: self.context.session_id.clone(), file_id: self.context.file_id.clone(),
                    attempt_id: self.context.attempt_id.clone(), transaction_id: self.transaction_id.clone(),
                    source_transaction_id, source_length, source_sha256, result_tx,
                }).await.map_err(|_| "Recovery channel closed".to_owned())?;
                result_rx.await.map_err(|_| "Recovery acknowledgement dropped".to_owned())?
            }) => result.unwrap_or_else(|_| Err("Recovery registration timed out".to_owned())),
        }
    }

    /// Both core descriptors must already be closed before invoking this gate.
    pub(crate) async fn publish_verified(
        &mut self,
        receipt: ExportReceipt,
        cancel: &CancellationToken,
    ) -> Result<(), String> {
        let deadline = publication_timeout(receipt.bytes);
        let result = publish(self, receipt, cancel, deadline).await;
        if result.is_ok() {
            self.published = true;
        }
        result
    }
}

impl Drop for Release {
    fn drop(&mut self) {
        // Never block a destructor/network executor, and never delete provider
        // documents here. A journal reconcile is mandatory if delivery is lost.
        let _ = self
            .context
            .event_tx
            .try_send(ServerEventV2::UploadCacheReleased {
                session_id: self.context.session_id.clone(),
                file_id: self.context.file_id.clone(),
                attempt_id: self.context.attempt_id.clone(),
                transaction_id: self.transaction_id.clone(),
                published: self.published,
            });
    }
}

// Field order is intentional: dropping while waiting for worker capacity closes
// both handles before the release notification. Once spawned, the worker owns
// the guard until all blocking I/O and descriptor drops have actually completed.
struct OwnedFiles {
    cache: File,
    staging: File,
    release: Release,
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
        cache,
        staging,
        transaction_id,
        result_tx,
        progress_tx: progress,
    } = target;
    let cancel = context.cancel.child_token();
    let _abort_on_drop = cancel.clone().drop_guard();
    let mut identity = identity(
        std::path::Path::new("received-file"),
        size,
        expected,
        &context,
    );
    // The formal cache header carries the durable provider transaction lineage.
    // CacheIdentity validation requires a UUID before any payload is written.
    identity.task_id = transaction_id.clone();
    let owned = OwnedFiles {
        cache,
        staging,
        release: Release {
            context,
            transaction_id,
            published: false,
        },
    };
    let permit = tokio::select! {
        biased;
        _ = cancel.cancelled() => {
            drop(owned);
            let _ = result_tx.send(Err("Upload cancelled".into()));
            return SaveResult::Failed;
        },
        permit = ACTIVE.acquire() => permit.expect("receive semaphore never closes"),
    };
    let (tx, rx) = mpsc::channel(QUEUE);
    let worker_cancel = cancel.clone();
    let worker_progress = progress.clone();
    let mut worker = tokio::task::spawn_blocking(move || {
        #[cfg(test)]
        let worker_key = std::path::PathBuf::from(&owned.release.transaction_id);
        #[cfg(test)]
        super::receive_cache::blocked_tests::checkpoint(
            &worker_key,
            super::receive_cache::blocked_tests::Point::WorkerStarted,
        );
        // receive() owns and closes the handles before it returns, including on
        // error/panic. The release guard remains alive outside that call.
        let OwnedFiles {
            cache,
            staging,
            release,
        } = owned;
        let result = receive(
            cache,
            staging,
            identity,
            times,
            rx,
            worker_cancel,
            worker_progress,
            None,
        );
        drop(permit);
        #[cfg(test)]
        super::receive_cache::blocked_tests::checkpoint(
            &worker_key,
            super::receive_cache::blocked_tests::Point::WorkerReleased,
        );
        (result, release)
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
    let joined = match early_result {
        Some(result) => result,
        None => tokio::select! {
            biased;
            result = &mut worker => result,
            _ = cancel.cancelled() => {
                // Publication has not been requested. The detached worker keeps
                // its budget and owned handles; its Release drops only after
                // receive() actually closes them. Never wait for a blocked OS
                // write or announce provider release from this HTTP task.
                let _ = result_tx.send(Err("Upload cancelled before publication".into()));
                return SaveResult::Failed;
            },
        },
    };
    let (result, mut release) = match joined {
        Ok(result) => result,
        Err(error) => {
            // A panicking worker has already unwound its descriptor/release
            // ownership. Publication is never attempted after a worker failure.
            let _ = result_tx.send(Err(format!("Receive worker failed: {error}")));
            return SaveResult::Failed;
        }
    };
    let receipt = match result {
        Ok(receipt) => receipt,
        Err(error) => {
            let outcome = if matches!(error, CacheError::Checksum) {
                SaveResult::HashMismatch
            } else {
                SaveResult::Failed
            };
            drop(release);
            let _ = result_tx.send(Err(error.to_string()));
            return outcome;
        }
    };

    // No descriptors are alive here. The deadline includes queue backpressure
    // as well as the application's response; the file body has no such deadline.
    // Only the core-verified exported length controls the budget. No provider or
    // network keepalive can extend it; cancellation remains immediately selectable.
    let deadline = publication_timeout(receipt.bytes);
    let published = publish(&release, receipt, &cancel, deadline).await;
    let outcome = if published.is_ok() {
        release.published = true;
        if let Some(tx) = progress {
            let _ = tx.try_send(size);
        }
        SaveResult::Success
    } else {
        SaveResult::Failed
    };
    drop(release);
    let _ = result_tx.send(published);
    outcome
}

async fn publish(
    release: &Release,
    receipt: ExportReceipt,
    cancel: &CancellationToken,
    deadline: Duration,
) -> Result<(), String> {
    tokio::select! {
        biased;
        _ = cancel.cancelled() => Err("Upload cancelled before publication".to_owned()),
        result = tokio::time::timeout(deadline, async {
            let (ack_tx, ack_rx) = oneshot::channel();
            release.context.event_tx.send(ServerEventV2::PublishUpload {
                session_id: release.context.session_id.clone(),
                file_id: release.context.file_id.clone(),
                attempt_id: release.context.attempt_id.clone(),
                transaction_id: release.transaction_id.clone(),
                size: receipt.bytes,
                sha256: receipt.sha256,
                result_tx: ack_tx,
            }).await.map_err(|_| "Publication event channel closed".to_owned())?;
            ack_rx.await.map_err(|_| "Publication acknowledgement dropped".to_owned())?
        }) => result.unwrap_or_else(|_| Err("Publication acknowledgement timed out".to_owned())),
    }
}

/// Fixed diagnostic fields only: never format provider errors or file paths.
pub(crate) fn failure_category(error: &CacheError) -> &'static str {
    match error {
        CacheError::Io(_) => "io",
        CacheError::Busy => "busy",
        CacheError::Identity => "identity",
        CacheError::IdentityMismatch => "identity_mismatch",
        CacheError::Format => "format",
        CacheError::Corrupt => "corrupt",
        CacheError::Chunk => "chunk",
        CacheError::ReopenRequired => "reopen_required",
        CacheError::Incomplete => "incomplete",
        CacheError::NotEmpty => "not_empty",
        CacheError::Checksum => "checksum",
        CacheError::Cancelled => "cancelled",
    }
}
#[allow(clippy::too_many_arguments)]
pub(crate) fn receive(
    cache_file: File,
    staging: File,
    identity: CacheIdentity,
    times: FileTimestamps,
    rx: mpsc::Receiver<Message>,
    cancel: CancellationToken,
    progress: Option<mpsc::Sender<u64>>,
    on_committed: Option<&dyn Fn(u64)>,
) -> Result<ExportReceipt, CacheError> {
    let stage = std::cell::Cell::new("admission");
    let result = receive_inner(
        cache_file,
        staging,
        identity,
        times,
        rx,
        cancel,
        progress,
        on_committed,
        &stage,
    );
    if let Err(error) = &result {
        let (os_errno, io_kind) = match error {
            CacheError::Io(e) => (e.raw_os_error(), Some(e.kind())),
            _ => (None, None),
        };
        tracing::warn!(
            event = "descriptor_receive_failed",
            stage = stage.get(),
            category = failure_category(error),
            ?os_errno,
            ?io_kind,
            "Descriptor receive rejected"
        );
    }
    result
}
#[allow(clippy::too_many_arguments)]
fn receive_inner(
    mut cache_file: File,
    mut staging: File,
    identity: CacheIdentity,
    times: FileTimestamps,
    mut rx: mpsc::Receiver<Message>,
    cancel: CancellationToken,
    progress: Option<mpsc::Sender<u64>>,
    on_committed: Option<&dyn Fn(u64)>,
    stage: &std::cell::Cell<&'static str>,
) -> Result<ExportReceipt, CacheError> {
    let cancelled = || {
        if cancel.is_cancelled() {
            Err(CacheError::Cancelled)
        } else {
            Ok(())
        }
    };
    #[cfg(test)]
    super::receive_cache::blocked_tests::checkpoint(
        std::path::Path::new(&identity.task_id),
        super::receive_cache::blocked_tests::Point::DescriptorsReady,
    );
    cancelled()?;
    stage.set("file_type");
    if !cache_file.metadata()?.is_file() || !staging.metadata()?.is_file() {
        return Err(io::Error::other("Receive cache and staging must be regular files").into());
    }
    // Check identity before locks or mutation, including two handles for one inode.
    stage.set("distinct_descriptors");
    if same_file::Handle::from_file(cache_file.try_clone()?)?
        == same_file::Handle::from_file(staging.try_clone()?)?
    {
        return Err(io::Error::other("Receive cache and staging must be distinct files").into());
    }
    stage.set("seek_cache");
    cache_file.seek(SeekFrom::Start(0))?;
    stage.set("seek_staging");
    staging.seek(SeekFrom::Start(0))?;
    let lock = |file: &File| {
        crate::file_lock::try_exclusive(file).map_err(|e| match e {
            TryLockError::WouldBlock => CacheError::Busy,
            TryLockError::Error(e) => CacheError::Io(e),
        })
    };
    stage.set("lock_cache");
    lock(&cache_file)?;
    stage.set("lock_staging");
    lock(&staging)?;
    cancelled()?;
    // This foundation accepts only newly-created empty transaction documents.
    // Unknown bytes (including provider preparation markers) are never erased.
    // Marker-to-formal-cache handoff belongs to the later provider integration.
    stage.set("check_empty");
    if cache_file.metadata()?.len() != 0 || staging.metadata()?.len() != 0 {
        return Err(CacheError::NotEmpty);
    }
    let size = identity.size;
    let chunk_size = identity.chunk_size as usize;
    #[cfg(test)]
    let cache_task = identity.task_id.clone();
    stage.set("cache_create");
    let mut cache = DownloadCache::create_receive_attempt_locked(cache_file, identity)?;
    let mut buffer = Vec::with_capacity(chunk_size);
    let mut index = 0;
    let mut total = 0u64;
    loop {
        cancelled()?;
        stage.set("body_read");
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
                        stage.set("cache_commit");
                        cache.commit_chunk(index, &buffer)?;
                        if let Some(update) = on_committed {
                            update(buffer.len() as u64);
                        }
                        #[cfg(test)]
                        super::receive_cache::blocked_tests::checkpoint(
                            std::path::Path::new(&cache_task),
                            super::receive_cache::blocked_tests::Point::Write,
                        );
                        cancelled()?;
                        index += 1;
                        buffer.clear();
                        if size > 0 {
                            if let Some(tx) = &progress {
                                let _ = tx.try_send(cache.committed_bytes().min(size - 1));
                            }
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
        stage.set("cache_commit");
        cache.commit_chunk(index, &buffer)?;
        if let Some(update) = on_committed {
            update(buffer.len() as u64);
        }
    }
    cancelled()?;
    stage.set("cache_export");
    let receipt = cache.export_receive_attempt_locked(&mut staging, |_| !cancel.is_cancelled())?;
    apply_timestamps(&staging, times);
    cancelled()?;
    Ok(receipt)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn receipt() -> ExportReceipt {
        ExportReceipt {
            bytes: 0,
            sha256: crate::crypto::hash::sha256_hex(b""),
        }
    }

    fn release(tx: mpsc::Sender<ServerEventV2>) -> Release {
        Release {
            context: Context {
                cancel: CancellationToken::new(),
                session_id: "session".into(),
                file_id: "file".into(),
                attempt_id: uuid::Uuid::new_v4().to_string(),
                event_tx: tx,
            },
            transaction_id: uuid::Uuid::new_v4().to_string(),
            published: false,
        }
    }

    #[tokio::test]
    async fn identity_registration_waits_for_native_ack_and_never_marks_published() {
        let (tx, mut rx) = mpsc::channel(4);
        let release = release(tx);
        let id = identity(
            std::path::Path::new("received-file"),
            1024 * 1024,
            Some(&"a".repeat(64)),
            &release.context,
        );
        let cancel = CancellationToken::new();
        let mut pending = std::pin::pin!(release.bind_identity(&id, &cancel));
        tokio::select! { biased; result = &mut pending => panic!("premature registration: {result:?}"), event = rx.recv() => {
            let Some(ServerEventV2::ReceiveCacheIdentity {identity_json, result_tx, session_id, file_id, attempt_id, transaction_id}) = event else {panic!("wrong event")};
            assert_eq!(serde_json::from_str::<serde_json::Value>(&identity_json).unwrap(), serde_json::to_value(&id).unwrap());
            assert_eq!(session_id, release.context.session_id); assert_eq!(file_id, release.context.file_id);
            assert_eq!(attempt_id, release.context.attempt_id); assert_eq!(transaction_id, release.transaction_id);
            assert!(tokio::time::timeout(Duration::from_millis(5), &mut pending).await.is_err());
            result_tx.send(Ok(None)).unwrap();
        }}
        pending.await.unwrap();
        assert!(!release.published);
    }

    #[tokio::test(start_paused = true)]
    async fn identity_registration_timeout_includes_queue_and_cancellation_is_immediate() {
        let (tx, _rx) = mpsc::channel(1);
        tx.send(ServerEventV2::ListenerFailed {
            error: "full".into(),
        })
        .await
        .unwrap();
        let release = release(tx);
        let id = identity(
            std::path::Path::new("received-file"),
            1024 * 1024,
            None,
            &release.context,
        );
        let cancel = CancellationToken::new();
        let start = tokio::time::Instant::now();
        assert!(
            release
                .bind_identity(&id, &cancel)
                .await
                .unwrap_err()
                .contains("timed out")
        );
        assert_eq!(start.elapsed(), Duration::from_secs(60));
        cancel.cancel();
        let start = tokio::time::Instant::now();
        assert!(
            release
                .bind_identity(&id, &cancel)
                .await
                .unwrap_err()
                .contains("cancelled")
        );
        assert_eq!(start.elapsed(), Duration::ZERO);
    }

    #[tokio::test]
    async fn publication_deadline_includes_full_event_queue() {
        let (tx, mut rx) = mpsc::channel(1);
        tx.send(ServerEventV2::ListenerFailed {
            error: "occupy queue".into(),
        })
        .await
        .unwrap();
        let release = release(tx);
        let error = publish(
            &release,
            receipt(),
            &CancellationToken::new(),
            Duration::from_millis(20),
        )
        .await
        .unwrap_err();
        assert!(error.contains("timed out"));
        assert!(matches!(
            rx.recv().await,
            Some(ServerEventV2::ListenerFailed { .. })
        ));
        assert!(
            rx.try_recv().is_err(),
            "timed-out queued publication must be cancelled"
        );
    }

    #[tokio::test]
    async fn publication_deadline_includes_pending_ack_and_closes_responder() {
        let (tx, mut rx) = mpsc::channel(1);
        let release = release(tx);
        let cancel = CancellationToken::new();
        let publishing = publish(&release, receipt(), &cancel, Duration::from_millis(20));
        let reading = async {
            let Some(ServerEventV2::PublishUpload { result_tx, .. }) = rx.recv().await else {
                panic!("publication missing");
            };
            tokio::time::sleep(Duration::from_millis(40)).await;
            assert!(result_tx.is_closed());
            assert!(
                result_tx.send(Ok(())).is_err(),
                "late acknowledgement must fail"
            );
        };
        let (result, _) = tokio::join!(publishing, reading);
        assert!(result.unwrap_err().contains("timed out"));
    }

    #[tokio::test]
    async fn cancelled_publication_does_not_enter_event_queue() {
        let (tx, mut rx) = mpsc::channel(1);
        let release = release(tx);
        let cancel = CancellationToken::new();
        cancel.cancel();
        assert!(
            publish(&release, receipt(), &cancel, Duration::from_secs(60))
                .await
                .unwrap_err()
                .contains("cancelled")
        );
        assert!(rx.try_recv().is_err());
    }

    #[test]
    fn publication_budget_scales_rounds_up_and_caps_without_overflow() {
        let mib = 1024 * 1024;
        for (bytes, seconds) in [
            (0, 60),
            (1, 61),
            (mib, 61),
            (mib + 1, 62),
            (1024 * mib, 1084),
            (4096 * mib, 4156),
            (
                (PUBLICATION_MAX_SECONDS - PUBLICATION_BASE_SECONDS) * mib,
                PUBLICATION_MAX_SECONDS,
            ),
            (u64::MAX, PUBLICATION_MAX_SECONDS),
        ] {
            assert_eq!(publication_timeout(bytes), Duration::from_secs(seconds));
        }
    }

    #[tokio::test(start_paused = true)]
    async fn large_verified_file_can_acknowledge_after_old_one_minute_cutoff() {
        let (tx, mut rx) = mpsc::channel(1);
        let release = release(tx);
        let receipt = ExportReceipt {
            bytes: 4 * 1024 * 1024 * 1024,
            ..receipt()
        };
        let deadline = publication_timeout(receipt.bytes);
        let work = tokio::spawn(async move {
            publish(&release, receipt, &CancellationToken::new(), deadline).await
        });
        let Some(ServerEventV2::PublishUpload {
            size, result_tx, ..
        }) = rx.recv().await
        else {
            panic!("publication missing");
        };
        assert_eq!(size, 4 * 1024 * 1024 * 1024);
        tokio::time::advance(Duration::from_secs(61)).await;
        assert!(!work.is_finished());
        assert!(!result_tx.is_closed());
        result_tx.send(Ok(())).unwrap();
        assert!(work.await.unwrap().is_ok());
    }

    #[tokio::test(start_paused = true)]
    async fn large_publication_budget_still_expires_and_rejects_late_receipts() {
        let (tx, mut rx) = mpsc::channel(1);
        let release = release(tx);
        let receipt = ExportReceipt {
            bytes: u64::MAX,
            ..receipt()
        };
        let deadline = publication_timeout(receipt.bytes);
        let work = tokio::spawn(async move {
            publish(&release, receipt, &CancellationToken::new(), deadline).await
        });
        let Some(ServerEventV2::PublishUpload { result_tx, .. }) = rx.recv().await else {
            panic!("publication missing");
        };
        tokio::time::advance(deadline + Duration::from_secs(1)).await;
        assert!(work.await.unwrap().unwrap_err().contains("timed out"));
        assert!(result_tx.send(Ok(())).is_err());
    }

    #[tokio::test(start_paused = true)]
    async fn cancellation_interrupts_extended_publication_budget() {
        let (tx, mut rx) = mpsc::channel(1);
        let release = release(tx);
        let receipt = ExportReceipt {
            bytes: 4 * 1024 * 1024 * 1024,
            ..receipt()
        };
        let deadline = publication_timeout(receipt.bytes);
        let cancel = CancellationToken::new();
        let worker_cancel = cancel.clone();
        let work =
            tokio::spawn(async move { publish(&release, receipt, &worker_cancel, deadline).await });
        let Some(ServerEventV2::PublishUpload { result_tx, .. }) = rx.recv().await else {
            panic!("publication missing");
        };
        let start = tokio::time::Instant::now();
        cancel.cancel();
        assert!(work.await.unwrap().unwrap_err().contains("cancelled"));
        assert_eq!(start.elapsed(), Duration::ZERO);
        assert!(result_tx.send(Ok(())).is_err());
    }
}
