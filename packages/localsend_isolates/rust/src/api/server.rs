use crate::frb_generated::StreamSink;
use flutter_rust_bridge::frb;
pub use localsend::http::dto_v2::RegisterDtoV2;
use localsend::http::server::ServerConfigV2;
pub use localsend::http::server::TlsConfig;
use localsend::http::server::common::save::FileUploadTarget;
use localsend::http::server::internal::{InternalConfig, InternalEvent};
pub use localsend::http::server::v2::SessionEndReasonV2;
use localsend::http::server::v2::{CacheRecoverySource, PrepareUploadDecisionV2, ServerEventV2};
use localsend::http::server::web::{
    WebConfig, WebDownloadConfig, WebDownloadEvent, WebMode as CoreWebMode,
};
pub use localsend::http::server::web::{WebI18n, WebPages};
use localsend::http::state::ClientInfo;
use localsend::model::discovery::DeviceType;
use localsend::model::discovery::ProtocolType;
use localsend::model::transfer::{FileContent, FileDto};
use std::collections::HashMap;
use std::sync::{Arc, LazyLock};
use tokio::sync::{Mutex, mpsc, oneshot};
use tokio_util::sync::CancellationToken;

/// Delete one registered private export through pinned no-follow directory handles.
/// The host must hold the export store's process lease and exclude active stages.
pub async fn cleanup_workspace_capture(root: String, id: String) -> anyhow::Result<String> {
    localsend::workspace_capture_cleanup::cleanup_workspace_capture(root, id).await
}

/// Consume a temporary SAF descriptor pair and close both before returning.
/// An unsupported filesystem is a negative capability, not a no-lock success.
pub async fn probe_receive_descriptor_pair(
    cache_descriptor: i32,
    staging_descriptor: i32,
) -> anyhow::Result<bool> {
    let (cache, staging) =
        resolve_cached_files(None, Some(cache_descriptor), None, Some(staging_descriptor))?;
    Ok(tokio::task::spawn_blocking(move || {
        localsend::receive_descriptor::DescriptorReceive::probe(cache, staging).is_ok()
    })
    .await?)
}

/// Owns the strict source lock until the native deletion future has drained.
#[frb(opaque)]
pub struct RsReceiveCleanupGuard {
    guard: std::sync::Mutex<Option<localsend::receive_descriptor::ReceiveCleanupGuard>>,
}
impl RsReceiveCleanupGuard {
    pub async fn release(&self) {
        self.guard.lock().unwrap().take();
    }
}

/// Takes ownership before validating the supplied proof. Rejection closes the FD.
pub async fn acquire_receive_cleanup_guard(
    descriptor: i32,
    expected_length: u64,
    expected_sha256: String,
) -> anyhow::Result<RsReceiveCleanupGuard> {
    let file = take_android_descriptor(Some(descriptor))?
        .ok_or_else(|| anyhow::anyhow!("Missing cleanup descriptor"))?;
    let guard = tokio::task::spawn_blocking(move || {
        localsend::receive_descriptor::ReceiveCleanupGuard::acquire(
            file,
            expected_length,
            &expected_sha256,
            || true,
        )
    })
    .await??;
    Ok(RsReceiveCleanupGuard {
        guard: std::sync::Mutex::new(Some(guard)),
    })
}

/// Read-only output verification held through native durable publication acknowledgement.
#[frb(opaque)]
pub struct RsReceivePublicationGuard {
    guard: std::sync::Mutex<Option<localsend::receive_descriptor::ReceivePublicationGuard>>,
}
impl RsReceivePublicationGuard {
    pub async fn release(&self) {
        self.guard.lock().unwrap().take();
    }
}

/// Adopt the independently opened read-only descriptor before checking proof
/// fields. Rejected or abandoned bridge calls retain no detached file handle.
pub async fn acquire_receive_publication_guard(
    file_descriptor: i32,
    length: u64,
    sha256: String,
) -> anyhow::Result<RsReceivePublicationGuard> {
    let file = take_android_descriptor(Some(file_descriptor))?
        .ok_or_else(|| anyhow::anyhow!("Missing publication descriptor"))?;
    let guard = tokio::task::spawn_blocking(move || {
        localsend::receive_descriptor::ReceivePublicationGuard::acquire(
            file,
            length,
            &sha256,
            || true,
        )
    })
    .await??;
    Ok(RsReceivePublicationGuard {
        guard: std::sync::Mutex::new(Some(guard)),
    })
}

/// Events emitted by the HTTP server that must be handled by the application.
///
/// [RsServerEvent::PrepareUpload] must be answered with [RsHttpServer::respond_prepare_upload]
/// and [RsServerEvent::FileUpload] with [RsHttpServer::respond_file_upload].
///
/// The `ip` of an event renders a link-local IPv6 peer as `fe80::1%3`,
/// including the interface scope, which the Rust HTTP client accepts back as
/// a host.
pub enum RsServerEvent {
    /// A private coordinated root lease for source-end cleanup, not peer approval.
    ReceiveSourceEndScope {
        request_id: String,
        directory: String,
    },
    /// Private observation persistence request; never expose its source locator.
    DirectoryContent {
        request_id: String,
        request: String,
    },
    /// Bounded snapshot of actual temporary-share HTTP response bodies.
    WebDownloadActivity {
        snapshot: String,
    },
    DirectoryDocument {
        request_id: String,
        request: String,
    },
    DirectoryDocumentCancelled {
        request_id: String,
    },
    DirectoryDocumentWrite {
        request_id: String,
        request: String,
    },
    DirectoryDocumentWriteCancelled {
        request_id: String,
    },
    /// Only already-admitted write owners may finish after listener stop.
    DirectoryDocumentWriteDraining,

    DirectoryUploadApproval {
        request_id: String,
        request: String,
    },
    DirectoryUploadApprovalAborted {
        request_id: String,
    },
    /// An explicitly authorized integration request for the persistent workspace catalog.
    WorkspaceManagement {
        request_id: String,
        request: String,
    },

    /// A device registered itself via `POST /api/localsend/v2/register`.
    ///
    /// On TLS, this event is only emitted when `info.fingerprint` matches the
    /// fingerprint of the client certificate verified during the mTLS
    /// handshake, so the fingerprint cannot be spoofed.
    Register {
        ip: String,
        info: RegisterDtoV2,
    },

    /// A sender requests to upload files via `POST /api/localsend/v2/prepare-upload`.
    PrepareUpload {
        /// The session ID the upload session will have when the request is accepted.
        session_id: String,
        ip: String,
        info: RegisterDtoV2,
        /// The SHA-256 fingerprint (uppercase hex) of the sender's client
        /// certificate verified during the mTLS handshake. Unlike
        /// `info.fingerprint`, this value cannot be spoofed.
        /// `None` when the server runs without TLS.
        cert_fingerprint: Option<String>,
        files: HashMap<String, FileDto>,
    },

    /// An accepted file is being uploaded via `POST /api/localsend/v2/upload`.
    FileUpload {
        session_id: String,
        file_id: String,
        file: FileDto,
        /// Internal-only approved durable attempt; missing retains original behavior.
        durable_recovery: Option<bool>,
        recovery_attempt_id: Option<String>,
    },

    /// Verification bytes are not transferred bytes or a resumable offset.
    FileVerification {
        session_id: String,
        file_id: String,
        attempt_id: String,
        verified_bytes: u64,
        total_bytes: u64,
        verifying: bool,
    },

    /// The provider must durably bind the exact cache identity before body writes.
    ReceiveCacheIdentity {
        session_id: String,
        file_id: String,
        attempt_id: String,
        transaction_id: String,
        identity_json: String,
    },

    ReceiveCacheRecovered {
        session_id: String,
        file_id: String,
        attempt_id: String,
        transaction_id: String,
        source_transaction_id: String,
        source_length: u64,
        source_sha256: String,
    },

    /// Verified cache export is ready; publication must be acknowledged before HTTP success.
    PublishUpload {
        session_id: String,
        file_id: String,
        attempt_id: String,
        transaction_id: String,
        size: u64,
        sha256: String,
    },

    /// All handles for this attempt are closed. This does not authorize guessing document URIs.
    UploadCacheReleased {
        session_id: String,
        file_id: String,
        attempt_id: String,
        transaction_id: String,
        published: bool,
    },

    /// An upload session ended.
    SessionEnd {
        session_id: String,
        reason: SessionEndReasonV2,
    },

    /// A prepare-upload request was aborted before a session was created,
    /// e.g. the sender disconnected while the application was still deciding.
    /// The [RsServerEvent::PrepareUpload] with the same session ID
    /// no longer needs to be answered.
    PrepareUploadAborted {
        session_id: String,
    },

    /// `POST /api/localsend/v2/cancel` was received for a session this server
    /// does not manage: the remote device cancels a transfer this application
    /// is currently *sending* to it. The application must verify that [ip]
    /// matches the target of the send session before cancelling it.
    CancelReceived {
        ip: String,
        session_id: String,
    },

    /// A web client requests to download the shared files via `POST /api/localsend/v2/prepare-download`.
    ///
    /// Must be answered with [RsHttpServer::respond_prepare_download].
    WebPrepareDownload {
        ip: String,
        session_id: String,
        user_agent: Option<String>,
    },

    /// Removes an unapproved browser request that disconnected or expired.
    WebPrepareDownloadAborted {
        session_id: String,
    },

    /// A web client downloads an offered file via `GET /api/localsend/v2/download`.
    ///
    /// Must be answered with [RsHttpServer::respond_file_download].
    WebFileDownload {
        request_id: String,
        session_id: String,
        file_id: String,
        file: FileDto,
    },

    /// Another application instance requested the running application to show itself
    /// via `POST /api/localsend/v2/show`.
    Show {
        /// Command-line arguments forwarded by the other application instance.
        args: Vec<String>,
    },

    /// The listening socket failed permanently, e.g. because the OS
    /// invalidated it while the application was suspended (iOS reclaims the
    /// sockets of suspended apps). The server has stopped itself; the
    /// application must restart it to become reachable again.
    ListenerFailed {
        /// Description of the failure.
        error: String,
    },
}

/// Owned durable-receive registry identity. A path is only a candidate until
/// the normal save result confirms full content verification/publication.
#[derive(Clone, Debug)]
pub struct RsReceiveRecoveryTarget {
    pub path: Option<String>,
    pub receipt_id: String,
    pub completed_unix_ms: Option<u64>,
}

pub struct RsHttpServer {
    instance: Arc<ServerInstance>,
    event_rx: Mutex<Option<mpsc::Receiver<ServerEventV2>>>,
    pending_directory_content: Mutex<HashMap<String, oneshot::Sender<Result<String, String>>>>,
    pending_directory_documents: Mutex<HashMap<String, PendingDirectoryDocument>>,
    directory_writes: Mutex<DirectoryWriteState>,
    pending_directory_approvals: Mutex<HashMap<String, oneshot::Sender<bool>>>,
    pending_decision: Mutex<Option<(String, oneshot::Sender<PrepareUploadDecisionV2>)>>,
    pending_uploads: Mutex<HashMap<(String, String), PendingUploadTarget>>,
    pending_publications: Mutex<PendingPublications>,
    pending_cache_identities: Mutex<PendingReplies<Option<CacheRecoverySource>>>,
    pending_cache_recoveries: Mutex<PendingPublications>,
    pending_source_end_scopes: Mutex<HashMap<String, PendingSourceEndScope>>,
    pending_management:
        Mutex<HashMap<String, localsend::http::server::integration::PendingManagement>>,
    web_event_rx: Mutex<Option<mpsc::Receiver<WebDownloadEvent>>>,
    web_event_tx: mpsc::Sender<WebDownloadEvent>,
    pending_download_decisions: Mutex<HashMap<String, oneshot::Sender<bool>>>,
    pending_downloads: Mutex<HashMap<(String, String, String), oneshot::Sender<FileContent>>>,
    internal_event_rx: Mutex<Option<mpsc::Receiver<InternalEvent>>>,
}

struct PendingSourceEndScope {
    deadline: tokio::time::Instant,
    decision: oneshot::Sender<bool>,
    completion: oneshot::Receiver<()>,
}

fn prune_source_end_scopes(pending: &mut HashMap<String, PendingSourceEndScope>) {
    let now = tokio::time::Instant::now();
    pending.retain(|_, value| !value.decision.is_closed() && value.deadline > now);
}

fn register_source_end_scope(
    pending: &mut HashMap<String, PendingSourceEndScope>,
    decision: oneshot::Sender<bool>,
    completion: oneshot::Receiver<()>,
) -> Option<String> {
    prune_source_end_scopes(pending);
    if pending.len() >= 4 || decision.is_closed() {
        return None;
    }
    let id = uuid::Uuid::new_v4().to_string();
    pending.insert(
        id.clone(),
        PendingSourceEndScope {
            deadline: tokio::time::Instant::now() + std::time::Duration::from_secs(15),
            decision,
            completion,
        },
    );
    Some(id)
}

/// Once granted, this response future owns the completion receiver independently
/// of listener lifetime. Only actual worker completion permits the host to release
/// its coordinated scope; stop, timeout or responder cancellation is not a fence.
async fn deliver_source_end_scope(
    pending: Option<PendingSourceEndScope>,
    granted: bool,
    stopped: bool,
) -> anyhow::Result<bool> {
    let Some(pending) = pending else {
        return Ok(false);
    };
    if stopped || pending.deadline <= tokio::time::Instant::now() {
        return Ok(false);
    }
    if pending.decision.send(granted).is_err() || !granted {
        return Ok(false);
    }
    pending
        .completion
        .await
        .map_err(|_| anyhow::anyhow!("Source-end scoped work did not confirm completion"))?;
    Ok(true)
}

struct PendingUploadTarget {
    attempt_id: Option<String>,
    responder: oneshot::Sender<FileUploadTarget>,
}

fn take_upload_target(
    pending: &mut HashMap<(String, String), PendingUploadTarget>,
    session_id: String,
    file_id: String,
    expected_attempt_id: Option<&str>,
) -> Option<oneshot::Sender<FileUploadTarget>> {
    let key = (session_id, file_id);
    if pending.get(&key)?.attempt_id.as_deref() != expected_attempt_id {
        return None;
    }
    pending.remove(&key).map(|value| value.responder)
}

struct PendingDirectoryDocument {
    deadline: tokio::time::Instant,
    result: oneshot::Sender<Result<localsend::http::server::directories::DocumentResponse, String>>,
}

#[frb(ignore)]
struct DirectoryWriteState {
    pending: HashMap<String, PendingDirectoryWrite>,
    owners: std::collections::HashSet<String>,
}
struct PendingDirectoryWrite {
    scope: String,
    operation: String,
    deadline: Option<tokio::time::Instant>,
    result: oneshot::Sender<
        Result<localsend::http::server::directories::DirectoryWriteResponse, String>,
    >,
}

fn directory_write_header(request: &str) -> anyhow::Result<(String, String, String)> {
    anyhow::ensure!(
        request.len() <= 64 * 1024,
        "Workspace write request too large"
    );
    let value: serde_json::Value = serde_json::from_str(request)?;
    let id = value["requestId"]
        .as_str()
        .ok_or_else(|| anyhow::anyhow!("Missing request identity"))?;
    let operation = value["op"]
        .as_str()
        .ok_or_else(|| anyhow::anyhow!("Missing write operation"))?;
    anyhow::ensure!(
        value["version"] == 1 && uuid::Uuid::parse_str(id).is_ok(),
        "Invalid write identity"
    );
    anyhow::ensure!(
        matches!(operation, "begin" | "publish" | "release" | "cancel"),
        "Invalid write operation"
    );
    for key in ["owner", "workspaceId", "attemptId"] {
        anyhow::ensure!(
            value[key]
                .as_str()
                .is_some_and(|v| uuid::Uuid::parse_str(v).is_ok()),
            "Invalid scoped write identity"
        );
    }
    anyhow::ensure!(
        value["generation"].as_u64().is_some_and(|v| v > 0)
            && value["tree"]
                .as_str()
                .is_some_and(|v| v.starts_with("content://")),
        "Invalid write scope"
    );
    let scope = serde_json::json!([
        value["owner"],
        value["workspaceId"],
        value["generation"],
        value["tree"],
        value["attemptId"]
    ])
    .to_string();
    Ok((id.into(), operation.into(), scope))
}

fn adopt_write_descriptor(fd: Option<i32>) -> anyhow::Result<Option<std::fs::File>> {
    match fd {
        None => Ok(None),
        Some(fd) => {
            anyhow::ensure!(fd >= 0, "Invalid write descriptor");
            #[cfg(unix)]
            {
                use std::os::fd::FromRawFd;
                Ok(Some(unsafe { std::fs::File::from_raw_fd(fd) }))
            }
            #[cfg(not(unix))]
            {
                anyhow::bail!("Document descriptors require Android")
            }
        }
    }
}

/// Adopt BOTH descriptors before any error/lookup/await. Equal descriptor numbers
/// are adopted once then rejected, never closed twice after descriptor reuse.
fn directory_write_result(
    payload: Option<String>,
    cache: Option<i32>,
    staging: Option<i32>,
    error: Option<String>,
) -> anyhow::Result<Result<localsend::http::server::directories::DirectoryWriteResponse, String>> {
    let same = cache.is_some() && cache == staging;
    let (cache, staging) = (
        adopt_write_descriptor(cache),
        if same {
            Ok(None)
        } else {
            adopt_write_descriptor(staging)
        },
    );
    let cache = cache?;
    let staging = staging?;
    anyhow::ensure!(!same, "Aliased write descriptors");
    #[cfg(all(not(target_os = "android"), not(test)))]
    anyhow::ensure!(
        cache.is_none() && staging.is_none(),
        "Document descriptors require Android"
    );
    if let Some(error) = error {
        anyhow::ensure!(payload.is_none(), "Ambiguous write response");
        let code = match error.as_str() {
            "invalid"
            | "permission"
            | "not_found"
            | "unsupported"
            | "busy"
            | "expired"
            | "cancelled"
            | "provider_error"
            | "conflict"
            | "publication_unconfirmed" => error,
            _ => "provider_error".into(),
        };
        return Ok(Err(code));
    }
    let payload = payload.ok_or_else(|| anyhow::anyhow!("Missing write response"))?;
    anyhow::ensure!(payload.len() <= 16384, "Write response too large");
    anyhow::ensure!(
        cache.is_some() == staging.is_some(),
        "Partial write descriptor pair"
    );
    Ok(Ok(
        localsend::http::server::directories::DirectoryWriteResponse {
            payload,
            cache,
            staging,
        },
    ))
}

fn deliver_directory_write(
    state: &mut DirectoryWriteState,
    id: &str,
    result: anyhow::Result<
        Result<localsend::http::server::directories::DirectoryWriteResponse, String>,
    >,
    stopped: bool,
) -> anyhow::Result<bool> {
    let Some(pending) = state.pending.remove(id) else {
        drop(result);
        return Ok(false);
    };
    if pending.operation == "begin"
        && (stopped
            || pending
                .deadline
                .is_some_and(|d| d <= tokio::time::Instant::now()))
    {
        drop(result);
        let _ = pending.result.send(Err("cancelled".into()));
        return Ok(false);
    }
    let response = match result {
        Ok(value) => value,
        Err(error) => {
            let _ = pending.result.send(Err(if pending.operation == "publish" {
                "publication_unconfirmed"
            } else {
                "invalid"
            }
            .into()));
            return Err(error);
        }
    };
    let new_owner = pending.operation == "begin" && response.is_ok();
    if new_owner {
        state.owners.insert(pending.scope.clone());
    }
    let released = pending.operation == "release";
    let delivered = pending.result.send(response).is_ok();
    if released || new_owner && !delivered {
        state.owners.remove(&pending.scope);
    }
    Ok(delivered)
}

/// Takes ownership before any asynchronous lookup or validation. Even a stale
/// request, malformed payload or unsupported desktop call must close its FD.
fn directory_document_result(
    payload: Option<String>,
    descriptor: Option<i32>,
    error: Option<String>,
) -> anyhow::Result<Result<localsend::http::server::directories::DocumentResponse, String>> {
    let file = match descriptor {
        None => None,
        Some(fd) => {
            anyhow::ensure!(fd >= 0, "Invalid document descriptor");
            #[cfg(unix)]
            {
                use std::os::fd::FromRawFd;
                // SAFETY: native caller transfers one fresh detached descriptor.
                Some(unsafe { std::fs::File::from_raw_fd(fd) })
            }
            #[cfg(not(unix))]
            {
                anyhow::bail!("Document descriptors require Android");
            }
        }
    };
    #[cfg(all(not(target_os = "android"), not(test)))]
    anyhow::ensure!(file.is_none(), "Document descriptors require Android");
    if let Some(error) = error {
        anyhow::ensure!(payload.is_none(), "Ambiguous document response");
        let code = match error.as_str() {
            "invalid" | "permission" | "not_found" | "unsupported" | "busy" | "expired"
            | "cancelled" | "provider_error" | "loading" => error,
            _ => "provider_error".into(),
        };
        return Ok(Err(code));
    }
    let payload = payload.ok_or_else(|| anyhow::anyhow!("Missing document payload"))?;
    anyhow::ensure!(
        payload.len() <= 2 * 1024 * 1024,
        "Document response too large"
    );
    Ok(Ok(localsend::http::server::directories::DocumentResponse {
        payload,
        file,
    }))
}

fn deliver_directory_document(
    pending: Option<PendingDirectoryDocument>,
    result: anyhow::Result<Result<localsend::http::server::directories::DocumentResponse, String>>,
    stopped: bool,
) -> anyhow::Result<bool> {
    let Some(pending) = pending else {
        drop(result);
        return Ok(false);
    };
    if pending.deadline <= tokio::time::Instant::now() || stopped {
        drop(result);
        return Ok(false);
    }
    match result {
        Ok(result) => Ok(pending.result.send(result).is_ok()),
        Err(error) => {
            let _ = pending.result.send(Err("invalid".into()));
            Err(error)
        }
    }
}

/// The stoppable part of a running server, shared between [RsHttpServer] and
/// [RUNNING_SERVER] so that a leftover instance can be stopped without its
/// Dart owner.
struct ServerInstance {
    handle: localsend::http::server::ServerHandle,
    stop_tx: Mutex<Option<oneshot::Sender<()>>>,
    stopping: CancellationToken,
}

impl ServerInstance {
    /// Stops the server and waits until the listeners are closed, so the port
    /// can be bound again. Does nothing when already stopped.
    async fn stop(&self) {
        self.stopping.cancel();
        if let Some(stop_tx) = self.stop_tx.lock().await.take() {
            let _ = stop_tx.send(());
            self.handle.wait_stopped().await;
        }
    }
}

/// The most recently started server. A Flutter hot restart kills all Dart
/// isolates without stopping the Rust server task, which would keep the port
/// bound forever; [start_server] stops such a leftover instance before
/// binding again.
static RUNNING_SERVER: Mutex<Option<Arc<ServerInstance>>> = Mutex::const_new(None);
// One bounded history per application host, not a list of retired servers. Late
// filesystem publication guards retain only this registry and their own gate.
static ACTIVITY_HISTORY: LazyLock<localsend::http::server::WebActivityHistory> =
    LazyLock::new(localsend::http::server::WebActivityHistory::default);

/// Configuration for the pages served to browsers. Always part of the server
/// configuration: even with web share disabled ([WebMode::Disabled]), the
/// server serves the 403 page at `/`.
pub struct WebParams {
    /// What is served at `/` and which browser-facing API is active.
    pub mode: WebMode,

    /// Translations for the web pages, served via `/i18n.json`.
    pub i18n: WebI18n,

    /// Custom HTML pages replacing the embedded web pages.
    /// Pages left `null` are served from the assets embedded at compile time.
    pub pages: WebPages,
}

/// What is served at `/` and which browser-facing API is active.
/// The modes are mutually exclusive: only one page can live at `/`.
pub enum WebMode {
    /// No web share active: `/` serves the 403 page and client certificates
    /// are mandatory under TLS, so the 403 page is effectively only reachable
    /// when encryption is off.
    Disabled,

    /// Web download: the download page and the download API, offering files for
    /// download by web browsers.
    ///
    /// Web download can be enabled independently of the v2 protocol endpoints.
    Download {
        /// The metadata of the files offered for download, mapped by file ID.
        /// The content is requested per download via [RsServerEvent::WebFileDownload].
        files: HashMap<String, FileDto>,

        /// Optional PIN that web clients must provide via the `pin` query parameter.
        pin: Option<String>,
    },

    /// The upload page: web browsers upload files via the v2
    /// `prepare-upload`/`upload` endpoints.
    Upload,

    /// Persistent bidirectional browser workspace.
    Duplex {
        files: HashMap<String, FileDto>,
        pin: Option<String>,
        allow_upload: bool,
    },
}

/// Starts the HTTP server on the given port (IPv4 and IPv6).
/// The server runs until [RsHttpServer::stop] is called.
///
/// [web] configures the pages served to browsers: [WebParams::mode] selects
/// the download page ([WebMode::Download], so web browsers can download the
/// offered files), the upload page ([WebMode::Upload]) or no web share at all
/// ([WebMode::Disabled], serving the 403 page).
///
/// Passing [show_token] enables the internal `show` endpoint that lets another
/// application instance request this one to show itself (emitted as
/// [RsServerEvent::Show]). The token guards the endpoint against other clients.
///
/// Events are received by listening to [RsHttpServer::listen].
pub async fn start_server(
    port: u16,
    tls: Option<TlsConfig>,
    alias: String,
    version: String,
    device_model: Option<String>,
    device_type: Option<DeviceType>,
    fingerprint: String,
    pin: Option<String>,
    verify_checksums: bool,
    web: WebParams,
    show_token: Option<String>,
) -> anyhow::Result<RsHttpServer> {
    // Stop a server left over from before a hot restart (its Dart owner died
    // without calling stop)
    let mut running_server = RUNNING_SERVER.lock().await;
    if let Some(previous) = running_server.take() {
        previous.stop().await;
    }

    let (event_tx, event_rx) = mpsc::channel::<ServerEventV2>(16);
    let (stop_tx, stop_rx) = oneshot::channel::<()>();

    let (web_event_tx, web_event_rx) = mpsc::channel::<WebDownloadEvent>(16);
    let web_mode = match web.mode {
        WebMode::Disabled => CoreWebMode::Disabled,
        WebMode::Upload => CoreWebMode::Upload,
        WebMode::Download { files, pin } => CoreWebMode::Download(WebDownloadConfig {
            files,
            pin,
            event_tx: web_event_tx.clone(),
        }),
        WebMode::Duplex {
            files,
            pin,
            allow_upload,
        } => CoreWebMode::Duplex {
            download: WebDownloadConfig {
                files,
                pin,
                event_tx: web_event_tx.clone(),
            },
            allow_upload,
        },
    };
    let web_config = WebConfig {
        mode: web_mode,
        i18n: web.i18n,
        pages: web.pages,
    };

    let (internal_config, internal_event_rx) = match show_token {
        Some(show_token) => {
            let (internal_event_tx, internal_event_rx) = mpsc::channel::<InternalEvent>(16);
            let config = InternalConfig {
                show_token,
                event_tx: internal_event_tx,
            };
            (Some(config), Some(internal_event_rx))
        }
        None => (None, None),
    };

    let handle = localsend::http::server::start_with_port_or_available_with_activity_history(
        port,
        tls,
        ClientInfo {
            alias,
            version,
            device_model,
            device_type,
            token: fingerprint,
        },
        internal_config,
        Some(ServerConfigV2 {
            pin,
            verify_checksums,
            event_tx,
        }),
        web_config,
        stop_rx,
        ACTIVITY_HISTORY.clone(),
    )
    .await?;

    let instance = Arc::new(ServerInstance {
        handle,
        stop_tx: Mutex::new(Some(stop_tx)),
        stopping: CancellationToken::new(),
    });
    *running_server = Some(instance.clone());

    Ok(RsHttpServer {
        instance,
        event_rx: Mutex::new(Some(event_rx)),
        pending_directory_content: Mutex::new(HashMap::new()),
        pending_directory_documents: Mutex::new(HashMap::new()),
        directory_writes: Mutex::new(DirectoryWriteState {
            pending: HashMap::new(),
            owners: std::collections::HashSet::new(),
        }),
        pending_directory_approvals: Mutex::new(HashMap::new()),
        pending_decision: Mutex::new(None),
        pending_uploads: Mutex::new(HashMap::new()),
        pending_publications: Mutex::new(HashMap::new()),
        pending_cache_identities: Mutex::new(HashMap::new()),
        pending_cache_recoveries: Mutex::new(HashMap::new()),
        pending_source_end_scopes: Mutex::new(HashMap::new()),
        pending_management: Mutex::new(HashMap::new()),
        web_event_rx: Mutex::new(Some(web_event_rx)),
        web_event_tx,
        pending_download_decisions: Mutex::new(HashMap::new()),
        pending_downloads: Mutex::new(HashMap::new()),
        internal_event_rx: Mutex::new(internal_event_rx),
    })
}

impl RsHttpServer {
    /// Trusted host only: the destination is an owned staging root, never API input.
    pub async fn capture_workspace_sources(
        &self,
        workspace_id: String,
        generation: u64,
        files: String,
        destination: String,
    ) -> anyhow::Result<String> {
        self.instance
            .handle
            .capture_workspace_sources(&workspace_id, generation, &files, destination)
            .await
    }

    pub async fn cancel_web_download(&self, id: String) -> bool {
        self.instance.handle.cancel_web_download(&id)
    }

    pub async fn web_download_activity(&self) -> String {
        self.instance.handle.web_download_activity()
    }

    /// Reply only after the app-owned observation state has been durably written.
    pub async fn respond_directory_content(&self, request_id: String, response: Option<String>) {
        if let Some(result) = self
            .pending_directory_content
            .lock()
            .await
            .remove(&request_id)
        {
            let value = response
                .filter(|value| value.len() <= 4096)
                .ok_or_else(|| "unavailable".to_owned());
            let _ = result.send(value);
        }
    }

    /// Atomically authorizes a queued management action before the host mutates persistence.
    pub async fn claim_workspace_management(&self, request_id: String) -> bool {
        let mut pending = self.pending_management.lock().await;
        pending.retain(|_, request| request.is_claimed() || !request.is_closed());
        pending
            .get(&request_id)
            .is_some_and(|request| request.claim())
    }

    /// Native ownership transfers once at entry, including late/rejected replies.
    pub async fn respond_directory_document(
        &self,
        request_id: String,
        payload: Option<String>,
        file_descriptor: Option<i32>,
        error: Option<String>,
    ) -> anyhow::Result<bool> {
        let result = directory_document_result(payload, file_descriptor, error);
        let pending = self
            .pending_directory_documents
            .lock()
            .await
            .remove(&request_id);
        deliver_directory_document(pending, result, self.instance.stopping.is_cancelled())
    }

    /// Private descriptor-pair ownership transfer; accepts real late publication
    /// outcomes on the original handle even after its listening socket stopped.
    pub async fn respond_directory_document_write(
        &self,
        request_id: String,
        payload: Option<String>,
        cache_descriptor: Option<i32>,
        staging_descriptor: Option<i32>,
        error: Option<String>,
    ) -> anyhow::Result<bool> {
        let result = directory_write_result(payload, cache_descriptor, staging_descriptor, error);
        let mut state = self.directory_writes.lock().await;
        deliver_directory_write(
            &mut state,
            &request_id,
            result,
            self.instance.stopping.is_cancelled(),
        )
    }

    /// False means the peer has cancelled, expired, or this decision was already used.
    pub async fn respond_directory_upload_approval(
        &self,
        request_id: String,
        accept: bool,
    ) -> bool {
        self.pending_directory_approvals
            .lock()
            .await
            .remove(&request_id)
            .is_some_and(|tx| tx.send(accept).is_ok())
    }

    /// Complete an already claimed action with a bounded, root-free receipt.
    pub async fn respond_workspace_management(
        &self,
        request_id: String,
        response: String,
    ) -> anyhow::Result<()> {
        let request = self.pending_management.lock().await.remove(&request_id);
        let Some(request) = request else {
            anyhow::bail!("Management request is no longer active");
        };
        request
            .respond(response)
            .map_err(|_| anyhow::anyhow!("Invalid management response"))
    }

    /// Real loopback API execution. A supplied Android read descriptor transfers once,
    /// before parsing or any asynchronous work; all rejection paths retain RAII ownership.
    pub async fn integration_api_request(
        &self,
        request: String,
        file_descriptor: Option<i32>,
    ) -> anyhow::Result<String> {
        let file = take_android_descriptor(file_descriptor)?;
        self.instance
            .handle
            .integration_api_request_with_file(&request, file)
            .await
    }

    /// Enable or close only the temporary share on the existing listener.
    pub async fn set_web_workspace(
        &self,
        enabled: bool,
        files: HashMap<String, FileDto>,
        pin: Option<String>,
        allow_upload: bool,
    ) -> anyhow::Result<()> {
        // Old decisions cannot authorize the newly configured share.
        self.pending_download_decisions.lock().await.clear();
        self.pending_downloads.lock().await.clear();
        self.instance.handle.set_web_mode(if enabled {
            CoreWebMode::Duplex {
                download: WebDownloadConfig {
                    files,
                    pin,
                    event_tx: self.web_event_tx.clone(),
                },
                allow_upload,
            }
        } else {
            CoreWebMode::Disabled
        });
        Ok(())
    }

    /// Apply integration policy without restarting any transfer listener.
    pub async fn configure_integration_api(&self, config: String) -> anyhow::Result<String> {
        self.instance
            .handle
            .configure_integration_api(&config)
            .await
    }

    /// Local management reads only redacted metadata, never verifiers or secrets.
    pub async fn integration_api_snapshot(&self) -> String {
        self.instance.handle.integration_api_snapshot()
    }

    /// Atomically replace named directory routes without restarting the listener.
    pub async fn configure_directory_workspaces(&self, config: String) -> anyhow::Result<String> {
        self.instance
            .handle
            .configure_directory_workspaces(&config)
            .await
    }

    /// Revoke selected file IDs and publish replacements without restarting listeners.
    pub async fn patch_web_workspace(
        &self,
        files: HashMap<String, FileDto>,
        remove_file_ids: Vec<String>,
    ) -> anyhow::Result<()> {
        self.instance
            .handle
            .patch_web_workspace(
                files.into_iter().map(|(id, f)| (id, f.into())).collect(),
                remove_file_ids.clone(),
            )
            .await?;
        self.pending_downloads
            .lock()
            .await
            .retain(|(_, _, file), sender| !remove_file_ids.contains(file) && !sender.is_closed());
        Ok(())
    }

    /// Append immutable shared IDs and change permission without restarting listeners.
    pub async fn update_web_workspace(
        &self,
        files: HashMap<String, FileDto>,
        allow_upload: bool,
    ) -> anyhow::Result<()> {
        self.instance
            .handle
            .update_web_workspace(files, allow_upload)
            .await
    }

    /// The actual bound HTTP port, which may differ after a conflict fallback.
    pub fn port(&self) -> u16 {
        self.instance.handle.port()
    }

    /// Emits server events until the server is stopped.
    /// Can only be listened to once.
    ///
    /// The v2 protocol, the web download (download API), and the internal endpoint
    /// events are all emitted on the same stream.
    ///
    /// Also returns when the Dart side of the stream is gone (e.g. after a
    /// hot restart), so this call does not keep the server alive forever.
    pub async fn listen(&self, sink: StreamSink<RsServerEvent>) {
        let Some(mut event_rx) = self.event_rx.lock().await.take() else {
            let _ = sink.add_error(anyhow::anyhow!("Server events already listened to"));
            return;
        };
        let mut web_event_rx = self.web_event_rx.lock().await.take();
        let mut internal_event_rx = self.internal_event_rx.lock().await.take();

        self.instance
            .handle
            .set_workspace_management_available(true);
        let mut v2_open = true;
        let mut write_draining = false;
        let mut web_cleanup = tokio::time::interval(std::time::Duration::from_secs(1));
        web_cleanup.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
        loop {
            if write_draining && self.directory_writes.lock().await.owners.is_empty() {
                break;
            }
            let sink_open = tokio::select! {
                biased;
                _ = self.instance.stopping.cancelled(), if !write_draining => {
                    self.pending_source_end_scopes.lock().await.clear();
                    write_draining=true;web_event_rx=None;internal_event_rx=None;
                    let mut writes=self.directory_writes.lock().await;
                    let ids:Vec<_>=writes.pending.iter().filter(|(_,p)|p.operation=="begin").map(|(id,_)|id.clone()).collect();
                    for id in ids {if let Some(p)=writes.pending.remove(&id){let _=p.result.send(Err("cancelled".into()));}}
                    drop(writes);
                    sink.add(RsServerEvent::DirectoryDocumentWriteDraining).is_ok()
                },
                _ = web_cleanup.tick() => {
                    prune_source_end_scopes(&mut *self.pending_source_end_scopes.lock().await);
                    let mut writes=self.directory_writes.lock().await;
                    let expired:Vec<_>=writes.pending.iter().filter(|(_,p)|p.operation=="begin"&&(p.result.is_closed()||p.deadline.is_some_and(|d|d<=tokio::time::Instant::now()))).map(|(id,_)|id.clone()).collect();
                    let mut writes_open=true;
                    for id in expired {writes.pending.remove(&id);writes_open &= sink.add(RsServerEvent::DirectoryDocumentWriteCancelled {request_id:id}).is_ok();}
                    drop(writes);
                    if write_draining { if !writes_open {break;} continue; }
                    let mut documents = self.pending_directory_documents.lock().await;
                    let expired: Vec<_> = documents.iter().filter(|(_, value)| value.result.is_closed() || value.deadline <= tokio::time::Instant::now()).map(|(id, _)| id.clone()).collect();
                    let mut documents_open = true;
                    for id in expired { documents.remove(&id); documents_open &= sink.add(RsServerEvent::DirectoryDocumentCancelled { request_id: id }).is_ok(); }
                    drop(documents);
                    self.pending_directory_content.lock().await.retain(|_, reply| !reply.is_closed());
                    self.pending_management.lock().await.retain(|_, request| request.is_claimed() || !request.is_closed());
                    let mut pending = self.pending_directory_approvals.lock().await;
                    let expired: Vec<_> = pending.iter().filter(|(_, tx)| tx.is_closed()).map(|(id, _)| id.clone()).collect();
                    let mut open = true;
                    for id in expired { pending.remove(&id); open &= sink.add(RsServerEvent::DirectoryUploadApprovalAborted { request_id: id }).is_ok(); }
                    drop(pending);
                    documents_open && open && self.emit_expired_download_decisions(&sink).await
                },
                event = event_rx.recv(), if v2_open => {
                    match event {
                        Some(event) => {
                            if !write_draining || matches!(event, ServerEventV2::DirectoryDocumentWrite { .. }) {
                                self.handle_server_event(&sink, event).await
                            } else { drop(event); true }
                        },
                        None => {
                            v2_open = false;
                            true
                        }
                    }
                }
                event = recv_opt(&mut web_event_rx) => {
                    match event {
                        Some(event) => self.handle_web_event(&sink, event).await,
                        None => {
                            web_event_rx = None;
                            true
                        }
                    }
                }
                event = recv_opt(&mut internal_event_rx) => {
                    match event {
                        Some(InternalEvent::Show { args }) => {
                            sink.add(RsServerEvent::Show { args }).is_ok()
                        }
                        None => {
                            internal_event_rx = None;
                            true
                        }
                    }
                }
            };

            // The Dart listener is gone; the remaining events have no receiver.
            if !sink_open {
                break;
            }

            if !v2_open && web_event_rx.is_none() && internal_event_rx.is_none() {
                break;
            }
        }
        self.pending_downloads.lock().await.clear();
        self.pending_download_decisions.lock().await.clear();
        self.instance
            .handle
            .set_workspace_management_available(false);
        self.pending_directory_content.lock().await.clear();
        self.pending_directory_documents.lock().await.clear();
        self.pending_directory_approvals.lock().await.clear();
        self.pending_management.lock().await.clear();
        self.pending_publications.lock().await.clear();
        self.pending_cache_identities.lock().await.clear();
        self.pending_cache_recoveries.lock().await.clear();
        self.pending_source_end_scopes.lock().await.clear();
    }

    /// Returns whether the sink is still open.
    async fn handle_server_event(
        &self,
        sink: &StreamSink<RsServerEvent>,
        event: ServerEventV2,
    ) -> bool {
        match event {
            ServerEventV2::ReceiveSourceEndScope {
                directory,
                decision_tx,
                completion_rx,
            } => {
                if self.instance.stopping.is_cancelled() {
                    return true;
                }
                let mut pending = self.pending_source_end_scopes.lock().await;
                let Some(request_id) =
                    register_source_end_scope(&mut pending, decision_tx, completion_rx)
                else {
                    return true;
                };
                if sink
                    .add(RsServerEvent::ReceiveSourceEndScope {
                        request_id: request_id.clone(),
                        directory,
                    })
                    .is_err()
                {
                    pending.remove(&request_id);
                    return false;
                }
                true
            }
            ServerEventV2::DirectoryDocumentWrite { request, result_tx } => {
                let (id, operation, scope) = match directory_write_header(&request) {
                    Ok(value) => value,
                    Err(_) => {
                        let _ = result_tx.send(Err("invalid".into()));
                        return true;
                    }
                };
                let mut state = self.directory_writes.lock().await;
                let begin = operation == "begin";
                if begin && (self.instance.stopping.is_cancelled() || result_tx.is_closed()) {
                    let _ = result_tx.send(Err("cancelled".into()));
                    return true;
                }
                if !begin && !state.owners.contains(&scope) {
                    let _ = result_tx.send(Err("invalid".into()));
                    return true;
                }
                let begins = state
                    .pending
                    .values()
                    .filter(|p| p.operation == "begin")
                    .count();
                if state.pending.len() >= 24
                    || state.pending.contains_key(&id)
                    || begin
                        && (state.owners.len() + begins >= 8
                            || state.owners.contains(&scope)
                            || state.pending.values().any(|p| p.scope == scope))
                {
                    let _ = result_tx.send(Err("busy".into()));
                    return true;
                }
                state.pending.insert(
                    id.clone(),
                    PendingDirectoryWrite {
                        scope,
                        operation,
                        deadline: begin.then(|| {
                            tokio::time::Instant::now() + std::time::Duration::from_secs(30)
                        }),
                        result: result_tx,
                    },
                );
                if sink
                    .add(RsServerEvent::DirectoryDocumentWrite {
                        request_id: id.clone(),
                        request,
                    })
                    .is_err()
                {
                    state.pending.remove(&id);
                    return false;
                }
                true
            }
            ServerEventV2::DirectoryDocument { request, result_tx } => {
                if request.len() > 64 * 1024 || result_tx.is_closed() {
                    return true;
                }
                let id = serde_json::from_str::<serde_json::Value>(&request)
                    .ok()
                    .and_then(|value| {
                        value
                            .get("requestId")
                            .and_then(|v| v.as_str())
                            .map(str::to_owned)
                    });
                let Some(id) = id.filter(|id| uuid::Uuid::parse_str(id).is_ok()) else {
                    let _ = result_tx.send(Err("invalid".into()));
                    return true;
                };
                let mut pending = self.pending_directory_documents.lock().await;
                if pending.len() >= 16 || pending.contains_key(&id) {
                    let _ = result_tx.send(Err("busy".into()));
                    return true;
                }
                pending.insert(
                    id.clone(),
                    PendingDirectoryDocument {
                        deadline: tokio::time::Instant::now() + std::time::Duration::from_secs(10),
                        result: result_tx,
                    },
                );
                if sink
                    .add(RsServerEvent::DirectoryDocument {
                        request_id: id.clone(),
                        request,
                    })
                    .is_err()
                {
                    pending.remove(&id);
                    return false;
                }
                true
            }
            ServerEventV2::DirectoryUploadApproval {
                request_id,
                request,
                decision_tx,
            } => {
                let mut pending = self.pending_directory_approvals.lock().await;
                if decision_tx.is_closed()
                    || pending.len() >= 16
                    || pending.contains_key(&request_id)
                {
                    return true;
                }
                pending.insert(request_id.clone(), decision_tx);
                if sink
                    .add(RsServerEvent::DirectoryUploadApproval {
                        request_id: request_id.clone(),
                        request,
                    })
                    .is_err()
                {
                    pending.remove(&request_id);
                    return false;
                }
                true
            }
            ServerEventV2::DirectoryUploadApprovalAborted { request_id } => {
                self.pending_directory_approvals
                    .lock()
                    .await
                    .remove(&request_id);
                sink.add(RsServerEvent::DirectoryUploadApprovalAborted { request_id })
                    .is_ok()
            }
            ServerEventV2::DirectoryContent { request, result_tx } => {
                let mut pending = self.pending_directory_content.lock().await;
                pending.retain(|_, reply| !reply.is_closed());
                if result_tx.is_closed() || pending.len() >= 256 || request.len() > 128 * 1024 {
                    let _ = result_tx.send(Err("busy".into()));
                    return true;
                }
                let id = uuid::Uuid::new_v4().to_string();
                pending.insert(id.clone(), result_tx);
                if sink
                    .add(RsServerEvent::DirectoryContent {
                        request_id: id.clone(),
                        request,
                    })
                    .is_err()
                {
                    pending.remove(&id);
                    return false;
                }
                true
            }
            ServerEventV2::WorkspaceManagement { request } => {
                let id = request.id();
                let json = request.request_json();
                let mut pending = self.pending_management.lock().await;
                pending.retain(|_, value| value.is_claimed() || !value.is_closed());
                if pending.len() >= 32 {
                    return true;
                }
                pending.insert(id.clone(), request);
                if sink
                    .add(RsServerEvent::WorkspaceManagement {
                        request_id: id.clone(),
                        request: json,
                    })
                    .is_err()
                {
                    pending.remove(&id);
                    return false;
                }
                true
            }
            ServerEventV2::Register { ip, info } => sink
                .add(RsServerEvent::Register {
                    ip: ip.to_string(),
                    info,
                })
                .is_ok(),
            ServerEventV2::PrepareUpload {
                session_id,
                ip,
                info,
                cert_fingerprint,
                files,
                decision_tx,
            } => {
                *self.pending_decision.lock().await = Some((session_id.clone(), decision_tx));
                sink.add(RsServerEvent::PrepareUpload {
                    session_id,
                    ip: ip.to_string(),
                    info,
                    cert_fingerprint,
                    files,
                })
                .is_ok()
            }
            ServerEventV2::FileUpload {
                session_id,
                file_id,
                file,
                target_tx,
            } => {
                self.pending_uploads.lock().await.insert(
                    (session_id.clone(), file_id.clone()),
                    PendingUploadTarget {
                        attempt_id: None,
                        responder: target_tx,
                    },
                );
                sink.add(RsServerEvent::FileUpload {
                    session_id,
                    file_id,
                    file,
                    durable_recovery: None,
                    recovery_attempt_id: None,
                })
                .is_ok()
            }
            ServerEventV2::FileUploadRecovery {
                session_id,
                file_id,
                attempt_id,
                file,
                target_tx,
            } => {
                self.pending_uploads.lock().await.insert(
                    (session_id.clone(), file_id.clone()),
                    PendingUploadTarget {
                        attempt_id: Some(attempt_id.clone()),
                        responder: target_tx,
                    },
                );
                sink.add(RsServerEvent::FileUpload {
                    session_id,
                    file_id,
                    file,
                    durable_recovery: Some(true),
                    recovery_attempt_id: Some(attempt_id),
                })
                .is_ok()
            }
            ServerEventV2::FileVerification {
                session_id,
                file_id,
                attempt_id,
                verified_bytes,
                total_bytes,
                verifying,
            } => sink
                .add(RsServerEvent::FileVerification {
                    session_id,
                    file_id,
                    attempt_id,
                    verified_bytes,
                    total_bytes,
                    verifying,
                })
                .is_ok(),
            ServerEventV2::ReceiveCacheIdentity {
                session_id,
                file_id,
                attempt_id,
                transaction_id,
                identity_json,
                result_tx,
            } => {
                let key = (
                    session_id.clone(),
                    file_id.clone(),
                    attempt_id.clone(),
                    transaction_id.clone(),
                );
                if !register_publication(
                    &mut *self.pending_cache_identities.lock().await,
                    key,
                    result_tx,
                ) {
                    return true;
                }
                sink.add(RsServerEvent::ReceiveCacheIdentity {
                    session_id,
                    file_id,
                    attempt_id,
                    transaction_id,
                    identity_json,
                })
                .is_ok()
            }
            ServerEventV2::ReceiveCacheRecovered {
                session_id,
                file_id,
                attempt_id,
                transaction_id,
                source_transaction_id,
                source_length,
                source_sha256,
                result_tx,
            } => {
                let key = (
                    session_id.clone(),
                    file_id.clone(),
                    attempt_id.clone(),
                    transaction_id.clone(),
                );
                if !register_publication(
                    &mut *self.pending_cache_recoveries.lock().await,
                    key,
                    result_tx,
                ) {
                    return true;
                }
                sink.add(RsServerEvent::ReceiveCacheRecovered {
                    session_id,
                    file_id,
                    attempt_id,
                    transaction_id,
                    source_transaction_id,
                    source_length,
                    source_sha256,
                })
                .is_ok()
            }
            ServerEventV2::PublishUpload {
                session_id,
                file_id,
                attempt_id,
                transaction_id,
                size,
                sha256,
                result_tx,
            } => {
                let key = (
                    session_id.clone(),
                    file_id.clone(),
                    attempt_id.clone(),
                    transaction_id.clone(),
                );
                let accepted = {
                    let mut pending = self.pending_publications.lock().await;
                    register_publication(&mut pending, key, result_tx)
                };
                if !accepted {
                    return true;
                }
                sink.add(RsServerEvent::PublishUpload {
                    session_id,
                    file_id,
                    attempt_id,
                    transaction_id,
                    size,
                    sha256,
                })
                .is_ok()
            }
            ServerEventV2::UploadCacheReleased {
                session_id,
                file_id,
                attempt_id,
                transaction_id,
                published,
            } => {
                self.pending_cache_recoveries.lock().await.remove(&(
                    session_id.clone(),
                    file_id.clone(),
                    attempt_id.clone(),
                    transaction_id.clone(),
                ));
                self.pending_cache_identities.lock().await.remove(&(
                    session_id.clone(),
                    file_id.clone(),
                    attempt_id.clone(),
                    transaction_id.clone(),
                ));
                self.pending_publications.lock().await.remove(&(
                    session_id.clone(),
                    file_id.clone(),
                    attempt_id.clone(),
                    transaction_id.clone(),
                ));
                sink.add(RsServerEvent::UploadCacheReleased {
                    session_id,
                    file_id,
                    attempt_id,
                    transaction_id,
                    published,
                })
                .is_ok()
            }
            ServerEventV2::SessionEnd { session_id, reason } => {
                self.pending_publications
                    .lock()
                    .await
                    .retain(|(sid, _, _, _), _| sid != &session_id);
                self.pending_cache_identities
                    .lock()
                    .await
                    .retain(|(sid, _, _, _), _| sid != &session_id);
                self.pending_cache_recoveries
                    .lock()
                    .await
                    .retain(|(sid, _, _, _), _| sid != &session_id);

                // Drop stale upload responders of this session (their requests already ended).
                self.pending_uploads
                    .lock()
                    .await
                    .retain(|(sid, _), _| sid != &session_id);
                sink.add(RsServerEvent::SessionEnd { session_id, reason })
                    .is_ok()
            }
            ServerEventV2::PrepareUploadAborted { session_id } => {
                // Drop the stale decision responder (the request already ended).
                // A newer prepare-upload request may already hold the slot;
                // only clear it if it still belongs to the aborted request.
                {
                    let mut pending = self.pending_decision.lock().await;
                    if pending.as_ref().is_some_and(|(sid, _)| sid == &session_id) {
                        *pending = None;
                    }
                }
                sink.add(RsServerEvent::PrepareUploadAborted { session_id })
                    .is_ok()
            }
            ServerEventV2::CancelReceived { ip, session_id } => sink
                .add(RsServerEvent::CancelReceived {
                    ip: ip.to_string(),
                    session_id,
                })
                .is_ok(),
            ServerEventV2::ListenerFailed { error } => {
                sink.add(RsServerEvent::ListenerFailed { error }).is_ok()
            }
        }
    }

    async fn emit_expired_download_decisions(&self, sink: &StreamSink<RsServerEvent>) -> bool {
        let expired = {
            let mut pending = self.pending_download_decisions.lock().await;
            take_expired_download_decisions(&mut pending)
        };
        for session_id in expired {
            if sink
                .add(RsServerEvent::WebPrepareDownloadAborted { session_id })
                .is_err()
            {
                return false;
            }
        }
        true
    }

    /// Returns whether the sink is still open.
    async fn handle_web_event(
        &self,
        sink: &StreamSink<RsServerEvent>,
        event: WebDownloadEvent,
    ) -> bool {
        // A full core event queue may omit its best-effort abort notification.
        // Every dequeue reconciles closed responders before showing new events.
        // Process explicit aborts before reconciliation so this dequeue does not
        // emit a duplicate for the same ID. An earlier timer may already have
        // reported it; the UI's UUID-based removal is intentionally idempotent.
        if !matches!(&event, WebDownloadEvent::PrepareDownloadAborted { .. })
            && !self.emit_expired_download_decisions(sink).await
        {
            return false;
        }
        match event {
            WebDownloadEvent::PrepareDownloadAborted { session_id } => {
                let event = {
                    let mut pending = self.pending_download_decisions.lock().await;
                    abort_download_decision(&mut pending, session_id)
                };
                sink.add(event).is_ok()
            }
            WebDownloadEvent::PrepareDownload {
                ip,
                session_id,
                user_agent,
                decision_tx,
            } => {
                {
                    let mut pending = self.pending_download_decisions.lock().await;
                    if !register_download_decision(&mut pending, session_id.clone(), decision_tx) {
                        return true; // timed out/disconnected while waiting in the event queue
                    }
                }
                sink.add(RsServerEvent::WebPrepareDownload {
                    ip: ip.to_string(),
                    session_id,
                    user_agent,
                })
                .is_ok()
            }
            WebDownloadEvent::FileDownload {
                session_id,
                file_id,
                file,
                content_tx,
            } => {
                let request_id = uuid::Uuid::new_v4().to_string();
                {
                    let mut pending = self.pending_downloads.lock().await;
                    pending.retain(|_, tx| !tx.is_closed());
                    // Bound unresolved application-side sources, independently of file size.
                    if content_tx.is_closed() || pending.len() >= 1024 {
                        return true; // stale event or dropping content_tx fails this request only
                    }
                    pending.insert(
                        (request_id.clone(), session_id.clone(), file_id.clone()),
                        content_tx,
                    );
                }
                sink.add(RsServerEvent::WebFileDownload {
                    request_id,
                    session_id,
                    file_id,
                    file,
                })
                .is_ok()
            }
        }
    }

    /// Answers the pending [RsServerEvent::PrepareUpload] event.
    ///
    /// Passing the accepted file IDs (a subset of the offered files) accepts the request.
    /// Passing `None` declines the request.
    pub async fn respond_prepare_upload(
        &self,
        session_id: String,
        accepted_file_ids: Option<Vec<String>>,
        resumable_file_ids: Option<Vec<String>>,
        durable_file_ids: Option<Vec<String>>,
    ) -> anyhow::Result<bool> {
        let decision_tx = {
            let mut pending = self.pending_decision.lock().await;
            take_prepare_decision(&mut pending, &session_id)
        };
        let Some(decision_tx) = decision_tx else {
            return Ok(false);
        };
        let decision = match accepted_file_ids {
            Some(ids) => match resumable_file_ids {
                Some(resumable) => {
                    let file_ids: std::collections::HashSet<String> = ids.into_iter().collect();
                    let resumable_file_ids: std::collections::HashSet<String> = resumable
                        .into_iter()
                        .filter(|id| file_ids.contains(id))
                        .collect();
                    if let Some(durable) = durable_file_ids {
                        let durable_file_ids = durable
                            .into_iter()
                            .filter(|id| resumable_file_ids.contains(id))
                            .collect();
                        PrepareUploadDecisionV2::AcceptDurable {
                            file_ids,
                            resumable_file_ids,
                            durable_file_ids,
                        }
                    } else {
                        PrepareUploadDecisionV2::AcceptResumable {
                            file_ids,
                            resumable_file_ids,
                        }
                    }
                }
                None => PrepareUploadDecisionV2::Accept(ids.into_iter().collect()),
            },
            None => PrepareUploadDecisionV2::Decline,
        };
        Ok(decision_tx.send(decision).is_ok())
    }

    /// Filesystem capability probe only; never creates or selects a user file.
    pub async fn supports_receive_recovery_target(
        &self,
        approved_directory: String,
        requested_name: String,
    ) -> anyhow::Result<bool> {
        self.instance
            .handle
            .supports_receive_recovery_target(approved_directory, requested_name)
            .await
    }

    /// Private lookup under a fresh approved session and exact active attempt.
    /// The peer never supplies an old path, token or receipt identity here.
    pub async fn lookup_receive_recovery_target(
        &self,
        session_id: String,
        file_id: String,
        expected_attempt_id: String,
        approved_directory: String,
        requested_name: String,
    ) -> anyhow::Result<RsReceiveRecoveryTarget> {
        let target = self
            .instance
            .handle
            .lookup_receive_recovery_target(
                &session_id,
                &file_id,
                &expected_attempt_id,
                approved_directory,
                requested_name,
            )
            .await?;
        Ok(RsReceiveRecoveryTarget {
            path: target.path,
            receipt_id: target.receipt_id,
            completed_unix_ms: target.completed_unix_ms,
        })
    }

    /// Answers the pending [RsServerEvent::FileUpload] event with the target
    /// the file should be saved to (either a path or a file descriptor)
    /// and waits until the file has been received completely.
    ///
    /// The progress (fraction of [file_size]) is emitted on [sink]
    /// while the file is being received. Failures are emitted on [sink] as
    /// well: flutter_rust_bridge discards the returned `Result` of functions
    /// taking a [StreamSink], so a returned error would become an uncaught
    /// async error killing the calling isolate.
    ///
    /// Timestamps provided in the sender's file metadata are applied to the
    /// written file by the server.
    pub async fn respond_file_upload(
        &self,
        sink: StreamSink<f64>,
        session_id: String,
        file_id: String,
        path: Option<String>,
        file_descriptor: Option<i32>,
        file_size: u64,
        expected_attempt_id: Option<String>,
    ) {
        let result = async {
            // Adopt platform ownership before waiting on pending state. Late
            // answers, rejected targets and cancellation must still close SAF FDs.
            let source = resolve_file_content(path, file_descriptor)?;
            let target_tx = {
                let mut pending = self.pending_uploads.lock().await;
                take_upload_target(
                    &mut pending,
                    session_id,
                    file_id,
                    expected_attempt_id.as_deref(),
                )
            };
            let Some(target_tx) = target_tx else {
                return Err(anyhow::anyhow!("No pending file upload for this file"));
            };

            let (progress_tx, mut progress_rx) = mpsc::channel::<u64>(16);
            let progress_sink = sink.clone();
            tokio::spawn(async move {
                let mut last_emit = None::<std::time::Instant>;
                while let Some(written) = progress_rx.recv().await {
                    let now = std::time::Instant::now();
                    let is_final = written >= file_size;
                    if !is_final {
                        if let Some(last) = last_emit {
                            if now.duration_since(last) < std::time::Duration::from_millis(20) {
                                continue;
                            }
                        }
                    }
                    last_emit = Some(now);
                    let progress = if file_size == 0 {
                        1.0
                    } else {
                        (written as f64 / file_size as f64).min(1.0)
                    };
                    let _ = progress_sink.add(progress);
                }
            });

            let (result_tx, result_rx) = oneshot::channel::<Result<(), String>>();
            let target = resolve_upload_target(source, result_tx, progress_tx)?;

            target_tx
                .send(target)
                .map_err(|_| anyhow::anyhow!("Upload request already ended"))?;

            match result_rx.await {
                Ok(Ok(())) => Ok(()),
                Ok(Err(err)) => Err(anyhow::anyhow!(err)),
                Err(_) => Err(anyhow::anyhow!("Upload request aborted")),
            }
        }
        .await;

        if let Err(err) = result {
            let _ = sink.add_error(err);
        }
    }

    /// Internal cached-descriptor foundation. Both files must be new, empty, seekable
    /// owned documents. Paths are existing-file test/desktop inputs; no creation or
    /// truncation happens here. Android must transfer each fresh detached FD once.
    /// This API does not activate the provider adapter in the normal receive path.
    pub async fn respond_cached_file_upload(
        &self,
        sink: StreamSink<f64>,
        session_id: String,
        file_id: String,
        transaction_id: String,
        cache_path: Option<String>,
        cache_descriptor: Option<i32>,
        staging_path: Option<String>,
        staging_descriptor: Option<i32>,
        file_size: u64,
    ) {
        let result = async {
            // Both handles are adopted before any validation can return or await.
            let (cache, staging) = resolve_cached_files(
                cache_path,
                cache_descriptor,
                staging_path,
                staging_descriptor,
            )?;
            anyhow::ensure!(
                uuid::Uuid::parse_str(&transaction_id).is_ok(),
                "Invalid cache transaction identity"
            );
            let target_tx = {
                let mut pending = self.pending_uploads.lock().await;
                take_upload_target(&mut pending, session_id, file_id, None)
            };
            let Some(target_tx) = target_tx else {
                return Err(anyhow::anyhow!("No pending file upload for this file"));
            };
            let (progress_tx, mut progress_rx) = mpsc::channel::<u64>(16);
            let progress_sink = sink.clone();
            let progress = tokio::spawn(async move {
                while let Some(written) = progress_rx.recv().await {
                    let fraction = if file_size == 0 {
                        1.0
                    } else {
                        (written as f64 / file_size as f64).min(1.0)
                    };
                    if progress_sink.add(fraction).is_err() {
                        break;
                    }
                }
            });
            let (result_tx, result_rx) = oneshot::channel();
            let sent = target_tx.send(FileUploadTarget::CachedOpenedFiles {
                cache,
                staging,
                transaction_id,
                result_tx,
                progress_tx: Some(progress_tx),
            });
            if sent.is_err() {
                // Drop the returned target before joining its progress receiver.
                drop(sent);
                let _ = progress.await;
                return Err(anyhow::anyhow!("Upload request already ended"));
            }
            let result = match result_rx.await {
                Ok(Ok(())) => Ok(()),
                Ok(Err(error)) => Err(anyhow::anyhow!(error)),
                Err(_) => Err(anyhow::anyhow!("Cached upload request aborted")),
            };
            let _ = progress.await;
            result
        }
        .await;
        if let Err(error) = result {
            let _ = sink.add_error(error);
        }
    }

    /// Granted replies finish only when the actual core source-end worker drains.
    pub async fn respond_receive_source_end_scope(
        &self,
        request_id: String,
        granted: bool,
    ) -> anyhow::Result<bool> {
        let pending = self
            .pending_source_end_scopes
            .lock()
            .await
            .remove(&request_id);
        deliver_source_end_scope(pending, granted, self.instance.stopping.is_cancelled()).await
    }

    /// A journal acknowledgement cannot consume a publication acknowledgement.
    pub async fn respond_receive_cache_identity(
        &self,
        session_id: String,
        file_id: String,
        attempt_id: String,
        transaction_id: String,
        error: Option<String>,
        recovery_transaction_id: Option<String>,
        recovery_identity_json: Option<String>,
        recovery_source_descriptor: Option<i32>,
    ) -> bool {
        // Adopt before looking up responders: stale/malformed replies also close handles.
        let response = parse_cache_recovery(
            recovery_transaction_id,
            recovery_identity_json,
            recovery_source_descriptor,
        )
        .and_then(|candidate| match error {
            Some(error) => Err(error),
            None => Ok(candidate),
        });
        self.pending_cache_identities
            .lock()
            .await
            .remove(&(session_id, file_id, attempt_id, transaction_id))
            .is_some_and(|sender| sender.send(response).is_ok())
    }

    pub async fn respond_receive_cache_recovered(
        &self,
        session_id: String,
        file_id: String,
        attempt_id: String,
        transaction_id: String,
        error: Option<String>,
    ) -> bool {
        answer_publication(
            &mut *self.pending_cache_recoveries.lock().await,
            (session_id, file_id, attempt_id, transaction_id),
            error,
        )
    }

    /// Match every identity before consuming a responder. A stale or duplicate
    /// reply can never approve the next whole-file retry.
    pub async fn respond_upload_publication(
        &self,
        session_id: String,
        file_id: String,
        attempt_id: String,
        transaction_id: String,
        error: Option<String>,
    ) -> bool {
        let key = (session_id, file_id, attempt_id, transaction_id);
        let mut pending = self.pending_publications.lock().await;
        answer_publication(&mut pending, key, error)
    }

    /// Fails the pending [RsServerEvent::FileUpload] event, e.g. because
    /// the application failed to prepare a save target for the file.
    ///
    /// The upload request fails with an error response and the file is marked
    /// as failed. Does nothing if the upload was already answered.
    pub async fn fail_file_upload(
        &self,
        session_id: String,
        file_id: String,
        expected_attempt_id: Option<String>,
    ) {
        // A stale error cannot drop a replacement attempt's responder.
        let mut pending = self.pending_uploads.lock().await;
        drop(take_upload_target(
            &mut pending,
            session_id,
            file_id,
            expected_attempt_id.as_deref(),
        ));
    }

    /// Answers the pending [RsServerEvent::WebPrepareDownload] event.
    ///
    /// Passing `true` accepts the download request, `false` declines it.
    pub async fn respond_prepare_download(
        &self,
        session_id: String,
        accept: bool,
    ) -> anyhow::Result<()> {
        let Some(decision_tx) = self
            .pending_download_decisions
            .lock()
            .await
            .remove(&session_id)
        else {
            return Err(anyhow::anyhow!("No pending prepare-download request"));
        };

        decision_tx
            .send(accept)
            .map_err(|_| anyhow::anyhow!("Prepare-download request already ended"))?;

        Ok(())
    }

    /// Answers the pending [RsServerEvent::WebFileDownload] event with the source
    /// the file content should be read from (either a path or a file descriptor).
    ///
    /// The server reads the content and streams it to the web client.
    pub async fn respond_file_download(
        &self,
        request_id: String,
        session_id: String,
        file_id: String,
        path: Option<String>,
        file_descriptor: Option<i32>,
    ) -> anyhow::Result<bool> {
        // Own descriptors even when this answer is late or duplicated.
        let content = resolve_file_content(path, file_descriptor)?;
        let Some(content_tx) = self
            .pending_downloads
            .lock()
            .await
            .remove(&(request_id, session_id, file_id))
        else {
            return Ok(false);
        };
        Ok(content_tx.send(content).is_ok())
    }

    /// Fails this request only; other requests for the same session/file survive.
    pub async fn fail_file_download(
        &self,
        request_id: String,
        session_id: String,
        file_id: String,
    ) {
        self.pending_downloads
            .lock()
            .await
            .remove(&(request_id, session_id, file_id));
    }

    /// Cancels the active upload session, e.g. because the user aborted the
    /// transfer on the receiving side.
    ///
    /// Uploads that are already in progress still run to completion, but new
    /// upload requests fail and a new session can be created.
    /// No [RsServerEvent::SessionEnd] is emitted: the application initiated
    /// the cancellation itself.
    pub async fn cancel_session(&self, session_id: String) {
        self.instance.handle.cancel_v2_session(&session_id).await;
        self.pending_publications
            .lock()
            .await
            .retain(|(sid, _, _, _), _| sid != &session_id);
        self.pending_cache_identities
            .lock()
            .await
            .retain(|(sid, _, _, _), _| sid != &session_id);
        self.pending_cache_recoveries
            .lock()
            .await
            .retain(|(sid, _, _, _), _| sid != &session_id);

        // Drop unanswered upload responders of this session so their requests
        // fail instead of waiting for a target forever.
        self.pending_uploads
            .lock()
            .await
            .retain(|(sid, _), _| sid != &session_id);
    }

    /// Stops the server.
    /// Returns after the listeners are closed, so the port can be bound again.
    pub async fn stop(&self) {
        self.pending_downloads.lock().await.clear();
        self.pending_download_decisions.lock().await.clear();
        self.instance
            .handle
            .set_workspace_management_available(false);
        self.pending_directory_content.lock().await.clear();
        self.pending_directory_documents.lock().await.clear();
        self.pending_directory_approvals.lock().await.clear();
        self.pending_management.lock().await.clear();
        self.pending_publications.lock().await.clear();
        self.pending_cache_identities.lock().await.clear();
        self.pending_cache_recoveries.lock().await.clear();
        self.pending_source_end_scopes.lock().await.clear();
        self.instance.stop().await;

        let mut running_server = RUNNING_SERVER.lock().await;
        if running_server
            .as_ref()
            .is_some_and(|running| Arc::ptr_eq(running, &self.instance))
        {
            *running_server = None;
        }
    }
}

/// Receives the next event from an optional channel, or pends forever when the
/// channel is absent (i.e. that feature is disabled).
async fn recv_opt<T>(rx: &mut Option<mpsc::Receiver<T>>) -> Option<T> {
    match rx {
        Some(rx) => rx.recv().await,
        None => std::future::pending::<Option<T>>().await,
    }
}

type PublicationKey = (String, String, String, String);
type PendingReplies<T> = HashMap<PublicationKey, oneshot::Sender<Result<T, String>>>;
type PendingPublications = PendingReplies<()>;

fn register_publication<T>(
    pending: &mut PendingReplies<T>,
    key: PublicationKey,
    sender: oneshot::Sender<Result<T, String>>,
) -> bool {
    pending.retain(|_, value| !value.is_closed());
    if sender.is_closed() || pending.len() >= 64 || pending.contains_key(&key) {
        return false;
    }
    pending.insert(key, sender);
    true
}

fn answer_publication(
    pending: &mut PendingPublications,
    key: PublicationKey,
    error: Option<String>,
) -> bool {
    pending
        .remove(&key)
        .is_some_and(|sender| sender.send(error.map_or(Ok(()), Err)).is_ok())
}

fn parse_cache_recovery(
    transaction_id: Option<String>,
    identity_json: Option<String>,
    descriptor: Option<i32>,
) -> Result<Option<CacheRecoverySource>, String> {
    let file = take_android_descriptor(descriptor).map_err(|error| error.to_string())?;
    match (transaction_id, identity_json, file) {
        (None, None, None) => Ok(None),
        (Some(transaction_id), Some(json), Some(file)) => {
            let identity: localsend::download_cache::CacheIdentity =
                serde_json::from_str(&json).map_err(|_| "Invalid recovery identity")?;
            if identity.task_id != transaction_id || uuid::Uuid::parse_str(&transaction_id).is_err()
            {
                return Err("Recovery transaction mismatch".into());
            }
            Ok(Some(CacheRecoverySource {
                file,
                identity,
                transaction_id,
            }))
        }
        _ => Err("Incomplete recovery candidate".into()),
    }
}

fn resolve_cached_files(
    cache_path: Option<String>,
    cache_fd: Option<i32>,
    staging_path: Option<String>,
    staging_fd: Option<i32>,
) -> anyhow::Result<(std::fs::File, std::fs::File)> {
    if cache_fd.is_some() && cache_fd == staging_fd {
        // Never construct two owners for one integer. Even rejection consumes it once.
        drop(take_android_descriptor(cache_fd)?);
        return Err(anyhow::anyhow!("Cache and staging descriptors must differ"));
    }
    let cache = take_android_descriptor(cache_fd);
    let staging = take_android_descriptor(staging_fd);
    let cache = cache?;
    let staging = staging?;
    fn open(path: Option<String>, file: Option<std::fs::File>) -> anyhow::Result<std::fs::File> {
        match (path, file) {
            (Some(path), None) => Ok(std::fs::OpenOptions::new()
                .read(true)
                .write(true)
                .open(path)?),
            (None, Some(file)) => Ok(file),
            _ => Err(anyhow::anyhow!(
                "Exactly one source for each cache document is required"
            )),
        }
    }
    let cache = open(cache_path, cache)?;
    let staging = open(staging_path, staging)?;
    Ok((cache, staging))
}

fn resolve_upload_target(
    source: FileContent,
    result_tx: oneshot::Sender<Result<(), String>>,
    progress_tx: mpsc::Sender<u64>,
) -> anyhow::Result<FileUploadTarget> {
    match source {
        FileContent::Path(path) => Ok(FileUploadTarget::CachedPath {
            path,
            result_tx,
            progress_tx: Some(progress_tx),
        }),
        FileContent::OpenedFile(file) => Ok(FileUploadTarget::OpenedFile {
            file,
            result_tx,
            progress_tx: Some(progress_tx),
        }),
        _ => Err(anyhow::anyhow!(
            "Expected an owned file or destination path"
        )),
    }
}

/// Releases a source acquired after the owning server has already stopped.
pub fn discard_download_source(
    path: Option<String>,
    file_descriptor: Option<i32>,
) -> anyhow::Result<()> {
    drop(resolve_file_content(path, file_descriptor)?);
    Ok(())
}

fn resolve_file_content(
    path: Option<String>,
    file_descriptor: Option<i32>,
) -> anyhow::Result<FileContent> {
    // Even invalid both-target input transfers a supplied descriptor to Rust.
    // Take ownership before validating exclusivity so the rejection cannot leak.
    let file = take_android_descriptor(file_descriptor)?;
    match (path, file) {
        (Some(path), None) => Ok(FileContent::Path(path.into())),
        (None, Some(file)) => Ok(FileContent::OpenedFile(file)),
        _ => Err(anyhow::anyhow!(
            "Exactly one file source or target must be provided"
        )),
    }
}

fn take_android_descriptor(descriptor: Option<i32>) -> anyhow::Result<Option<std::fs::File>> {
    let Some(fd) = descriptor else {
        return Ok(None);
    };
    anyhow::ensure!(fd >= 0, "Invalid file descriptor");
    #[cfg(any(target_os = "android", all(test, unix)))]
    {
        use std::os::fd::FromRawFd;
        // SAFETY: the platform caller transfers a fresh, valid detached FD once.
        // Never clone/re-adopt its integer after handing it to this function.
        Ok(Some(unsafe { std::fs::File::from_raw_fd(fd) }))
    }
    #[cfg(not(any(target_os = "android", all(test, unix))))]
    {
        let _ = fd;
        Err(anyhow::anyhow!(
            "File descriptors are only supported on Android"
        ))
    }
}

#[frb(mirror(WebI18n))]
pub struct _WebI18n {
    pub waiting: String,
    pub enter_pin: String,
    pub invalid_pin: String,
    pub too_many_attempts: String,
    pub rejected: String,
    pub upload_rejected: String,
    pub busy: String,
    pub files: String,
    pub file_name: String,
    pub size: String,
    pub drop_hint: String,
    pub preview: Option<String>,
    pub close_preview: Option<String>,
    pub download_original: Option<String>,
    pub preview_loading: Option<String>,
    pub preview_error: Option<String>,
    pub preview_unsupported: Option<String>,
    pub text_preview: Option<HashMap<String, String>>,
}

#[frb(mirror(WebPages))]
pub struct _WebPages {
    pub download_html: Option<String>,
    pub upload_html: Option<String>,
    pub error_403_html: Option<String>,
}

#[frb(mirror(TlsConfig))]
pub struct _TlsConfig {
    pub cert: String,
    pub private_key: String,
}

#[frb(mirror(RegisterDtoV2))]
pub struct _RegisterDtoV2 {
    pub alias: String,
    pub version: String,
    pub device_model: Option<String>,
    pub device_type: Option<DeviceType>,
    pub fingerprint: String,
    pub port: u16,
    pub protocol: ProtocolType,
    pub download: bool,
}

#[frb(mirror(SessionEndReasonV2))]
pub enum _SessionEndReasonV2 {
    Finished,
    Cancelled,
    Expired,
}

// A successful reply consumes the responder before the HTTP handler records
// acceptance. If that handler is dropped in between, its explicit abort must
// still reach Dart; absence from this map is not evidence of a live session.
fn abort_download_decision(
    pending: &mut HashMap<String, oneshot::Sender<bool>>,
    session_id: String,
) -> RsServerEvent {
    pending.remove(&session_id);
    RsServerEvent::WebPrepareDownloadAborted { session_id }
}

fn take_expired_download_decisions(
    pending: &mut HashMap<String, oneshot::Sender<bool>>,
) -> Vec<String> {
    let mut expired = Vec::new();
    pending.retain(|id, sender| {
        if sender.is_closed() {
            expired.push(id.clone());
            false
        } else {
            true
        }
    });
    expired
}

// A disconnected browser can leave an unanswered UI event behind. Prune only
// closed responders and suppress already-stale queued events; approved core
// sessions and unrelated pending decisions are not affected.
fn register_download_decision(
    pending: &mut HashMap<String, oneshot::Sender<bool>>,
    session_id: String,
    decision: oneshot::Sender<bool>,
) -> bool {
    if decision.is_closed() {
        return false;
    }
    pending.insert(session_id, decision);
    true
}

// A delayed UI decision must not consume a newer request's responder.
fn take_prepare_decision(
    pending: &mut Option<(String, oneshot::Sender<PrepareUploadDecisionV2>)>,
    session_id: &str,
) -> Option<oneshot::Sender<PrepareUploadDecisionV2>> {
    if pending.as_ref().is_some_and(|(id, _)| id == session_id) {
        pending.take().map(|(_, sender)| sender)
    } else {
        None
    }
}

/// Derive a persistent workspace verifier without blocking Flutter's UI isolate.
/// The result is private configuration, never a browser-visible password.
pub async fn hash_directory_password(password: String) -> anyhow::Result<String> {
    localsend::http::server::directory_auth::hash_password(password).await
}

#[cfg(test)]
mod prepare_decision_tests {
    use super::*;

    #[tokio::test]
    async fn explicit_browser_abort_is_forwarded_after_successful_reply_consumed_responder() {
        let mut pending = HashMap::new();
        let (old_sender, old_receiver) = oneshot::channel();
        assert!(register_download_decision(
            &mut pending,
            "old".into(),
            old_sender
        ));
        // respond_prepare_download removes the sender and succeeds locally, but
        // core can still abort before committing its accepted session state.
        pending.remove("old").unwrap().send(true).unwrap();
        assert!(old_receiver.await.unwrap());
        let (new_sender, mut new_receiver) = oneshot::channel();
        assert!(register_download_decision(
            &mut pending,
            "new".into(),
            new_sender
        ));
        for _ in 0..2 {
            assert!(
                matches!(abort_download_decision(&mut pending, "old".into()),
                RsServerEvent::WebPrepareDownloadAborted { session_id } if session_id == "old")
            );
            assert_eq!(pending.len(), 1);
            assert!(matches!(
                new_receiver.try_recv(),
                Err(oneshot::error::TryRecvError::Empty)
            ));
        }
        pending.remove("new").unwrap().send(true).unwrap();
        assert!(new_receiver.await.unwrap());
    }

    #[tokio::test]
    async fn stale_browser_events_are_pruned_without_consuming_current_decision() {
        let mut pending = HashMap::new();
        for index in 0..128 {
            let (sender, receiver) = oneshot::channel();
            pending.insert(format!("expired-{index}"), sender);
            drop(receiver);
        }
        let expired = take_expired_download_decisions(&mut pending);
        assert_eq!(expired.len(), 128);
        assert!(pending.is_empty());
        let (current, receiver) = oneshot::channel();
        assert!(register_download_decision(
            &mut pending,
            "current".into(),
            current
        ));
        assert_eq!(pending.len(), 1);
        let (late, closed) = oneshot::channel();
        drop(closed);
        assert!(!register_download_decision(
            &mut pending,
            "late".into(),
            late
        ));
        assert_eq!(pending.len(), 1);
        assert!(pending.remove("current").unwrap().send(true).is_ok());
        assert!(receiver.await.unwrap());
    }

    #[tokio::test]
    async fn stale_decision_preserves_new_request() {
        let (tx, mut rx) = oneshot::channel();
        let mut pending = Some(("new".to_owned(), tx));
        assert!(take_prepare_decision(&mut pending, "old").is_none());
        assert!(matches!(
            rx.try_recv(),
            Err(oneshot::error::TryRecvError::Empty)
        ));
        let current = take_prepare_decision(&mut pending, "new").unwrap();
        assert!(current.send(PrepareUploadDecisionV2::Decline).is_ok());
        assert!(matches!(
            rx.await.unwrap(),
            PrepareUploadDecisionV2::Decline
        ));
        assert!(take_prepare_decision(&mut pending, "new").is_none());
    }
}

#[cfg(all(test, unix))]
mod upload_ownership_tests {
    use super::*;
    use std::io::{ErrorKind, Read};
    use std::os::{fd::IntoRawFd, unix::net::UnixStream};

    fn descriptor() -> (i32, UnixStream) {
        let (file, observer) = UnixStream::pair().unwrap();
        observer.set_nonblocking(true).unwrap();
        (file.into_raw_fd(), observer)
    }
    fn closed(observer: &mut UnixStream) {
        assert_eq!(observer.read(&mut [0]).unwrap(), 0);
    }
    fn open(observer: &mut UnixStream) {
        assert_eq!(
            observer.read(&mut [0]).unwrap_err().kind(),
            ErrorKind::WouldBlock
        );
    }

    #[test]
    fn invalid_target_combination_still_releases_descriptor() {
        let (fd, mut observer) = descriptor();
        assert!(resolve_file_content(Some("unused".into()), Some(fd)).is_err());
        closed(&mut observer);
        assert!(resolve_file_content(None, Some(-1)).is_err());
        assert!(resolve_file_content(None, None).is_err());
    }

    #[test]
    fn missing_pending_upload_drops_adopted_file_without_starting_a_writer() {
        let (fd, mut observer) = descriptor();
        let source = resolve_file_content(None, Some(fd)).unwrap();
        open(&mut observer);
        drop(source);
        closed(&mut observer);
    }

    #[test]
    fn rejected_target_channel_closes_owned_file() {
        let (fd, mut observer) = descriptor();
        let source = resolve_file_content(None, Some(fd)).unwrap();
        let (result_tx, _result_rx) = oneshot::channel();
        let (progress_tx, _progress_rx) = mpsc::channel(1);
        let target = resolve_upload_target(source, result_tx, progress_tx).unwrap();
        let (target_tx, target_rx) = oneshot::channel();
        drop(target_rx);
        assert!(target_tx.send(target).is_err());
        closed(&mut observer);
    }

    #[test]
    fn discard_late_platform_target_closes_without_writing() {
        let (fd, mut observer) = descriptor();
        discard_download_source(None, Some(fd)).unwrap();
        closed(&mut observer);
    }

    #[tokio::test]
    async fn cancellation_while_waiting_for_pending_state_closes_file() {
        let lock = std::sync::Arc::new(tokio::sync::Mutex::new(()));
        let held = lock.lock().await;
        let (fd, mut observer) = descriptor();
        let (owned_tx, owned_rx) = oneshot::channel();
        let task = tokio::spawn({
            let lock = lock.clone();
            async move {
                let file = resolve_file_content(None, Some(fd)).unwrap();
                owned_tx.send(()).unwrap();
                let _pending = lock.lock().await;
                drop(file);
            }
        });
        owned_rx.await.unwrap();
        open(&mut observer);
        task.abort();
        assert!(task.await.unwrap_err().is_cancelled());
        closed(&mut observer);
        drop(held);
    }
}

#[cfg(test)]
mod publication_tests {
    use super::*;

    fn key(attempt: &str) -> PublicationKey {
        (
            "session".into(),
            "file".into(),
            attempt.into(),
            "transaction".into(),
        )
    }

    #[tokio::test]
    async fn identity_acknowledgement_cannot_consume_final_publication_even_with_same_key() {
        let mut identity = HashMap::new();
        let mut publication = HashMap::new();
        let (identity_tx, identity_rx) = oneshot::channel();
        let (publication_tx, mut publication_rx) = oneshot::channel();
        assert!(register_publication(
            &mut identity,
            key("current"),
            identity_tx
        ));
        assert!(register_publication(
            &mut publication,
            key("current"),
            publication_tx
        ));
        assert!(!answer_publication(&mut identity, key("stale"), None));
        assert!(answer_publication(&mut identity, key("current"), None));
        assert_eq!(identity_rx.await.unwrap(), Ok(()));
        assert!(!answer_publication(&mut identity, key("current"), None));
        assert!(matches!(
            publication_rx.try_recv(),
            Err(oneshot::error::TryRecvError::Empty)
        ));
        assert!(answer_publication(
            &mut publication,
            key("current"),
            Some("not published".into())
        ));
        assert_eq!(publication_rx.await.unwrap(), Err("not published".into()));
    }

    #[tokio::test]
    async fn publication_reply_matches_all_identities_and_consumes_once() {
        let mut pending = HashMap::new();
        let (sender, mut receiver) = oneshot::channel();
        assert!(register_publication(&mut pending, key("current"), sender));
        let current = key("current");
        for wrong in [
            (
                "other".into(),
                current.1.clone(),
                current.2.clone(),
                current.3.clone(),
            ),
            (
                current.0.clone(),
                "other".into(),
                current.2.clone(),
                current.3.clone(),
            ),
            key("old"),
            (
                current.0.clone(),
                current.1.clone(),
                current.2.clone(),
                "other".into(),
            ),
        ] {
            assert!(!answer_publication(&mut pending, wrong, None));
        }
        assert!(matches!(
            receiver.try_recv(),
            Err(oneshot::error::TryRecvError::Empty)
        ));
        assert!(answer_publication(&mut pending, key("current"), None));
        assert_eq!(receiver.await.unwrap(), Ok(()));
        assert!(!answer_publication(&mut pending, key("current"), None));
    }

    #[tokio::test]
    async fn bounded_publications_prune_closed_but_preserve_live_duplicate() {
        let mut pending = HashMap::new();
        let mut receivers = Vec::new();
        for index in 0..64 {
            let (sender, receiver) = oneshot::channel();
            assert!(register_publication(
                &mut pending,
                key(&index.to_string()),
                sender
            ));
            receivers.push(receiver);
        }
        let (extra, extra_rx) = oneshot::channel();
        assert!(!register_publication(&mut pending, key("extra"), extra));
        assert!(extra_rx.await.is_err());
        drop(receivers.remove(0));
        let (replacement, replacement_rx) = oneshot::channel();
        assert!(register_publication(
            &mut pending,
            key("replacement"),
            replacement
        ));
        let (duplicate, duplicate_rx) = oneshot::channel();
        assert!(!register_publication(
            &mut pending,
            key("replacement"),
            duplicate
        ));
        assert!(duplicate_rx.await.is_err());
        assert!(answer_publication(
            &mut pending,
            key("replacement"),
            Some("Provider denied publication".into())
        ));
        assert_eq!(
            replacement_rx.await.unwrap(),
            Err("Provider denied publication".into())
        );
    }

    #[cfg(unix)]
    mod ownership {
        use super::*;
        use std::io::Read;
        use std::os::{fd::IntoRawFd, unix::net::UnixStream};
        fn descriptor() -> (i32, UnixStream) {
            let (file, observer) = UnixStream::pair().unwrap();
            observer.set_nonblocking(true).unwrap();
            (file.into_raw_fd(), observer)
        }
        fn closed(observer: &mut UnixStream) {
            assert_eq!(observer.read(&mut [0]).unwrap(), 0);
        }
        fn recovery_json(id: &str) -> String {
            serde_json::json!({"taskId":id,"sourceId":"http:127.0.0.1","resourceId":"a".repeat(64),"version":"a".repeat(64),"fileName":"received-file","size":1048576,"chunkSize":1048576,"createdUnixMs":1,"sha256":"a".repeat(64)}).to_string()
        }
        #[test]
        fn malformed_recovery_candidates_consume_their_descriptor() {
            let id = uuid::Uuid::new_v4().to_string();
            for (transaction, json) in [
                (None, Some(recovery_json(&id))),
                (Some(id.clone()), None),
                (Some(id.clone()), Some("bad".into())),
                (
                    Some(id.clone()),
                    Some(recovery_json(&uuid::Uuid::new_v4().to_string())),
                ),
            ] {
                let (fd, mut observer) = descriptor();
                assert!(parse_cache_recovery(transaction, json, Some(fd)).is_err());
                closed(&mut observer);
            }
            assert!(parse_cache_recovery(None, None, None).unwrap().is_none());
        }
        #[tokio::test]
        async fn stale_identity_reply_drops_owned_recovery_source() {
            let id = uuid::Uuid::new_v4().to_string();
            let (fd, mut observer) = descriptor();
            let response =
                parse_cache_recovery(Some(id.clone()), Some(recovery_json(&id)), Some(fd)).unwrap();
            let (sender, receiver) =
                oneshot::channel::<Result<Option<CacheRecoverySource>, String>>();
            drop(receiver);
            assert!(sender.send(Ok(response)).is_err());
            closed(&mut observer);
        }
        #[tokio::test]
        async fn publication_guard_rejection_consumes_read_descriptor_before_validation() {
            for hash in ["invalid".to_owned(), "a".repeat(64)] {
                let (fd, mut observer) = descriptor();
                assert!(
                    acquire_receive_publication_guard(fd, 0, hash)
                        .await
                        .is_err()
                );
                closed(&mut observer);
            }
            assert!(
                acquire_receive_publication_guard(-1, 0, "a".repeat(64))
                    .await
                    .is_err()
            );
        }

        #[tokio::test]
        async fn publication_guard_readonly_opaque_blocks_writers_until_idempotent_release() {
            use std::fs::{File, OpenOptions};
            let path =
                std::env::temp_dir().join(format!("ls-publication-guard-{}", uuid::Uuid::new_v4()));
            let content = b"already visible native output";
            std::fs::write(&path, content).unwrap();
            let observer = OpenOptions::new()
                .read(true)
                .write(true)
                .open(&path)
                .unwrap();
            let guard = acquire_receive_publication_guard(
                File::open(&path).unwrap().into_raw_fd(),
                content.len() as u64,
                localsend::crypto::hash::sha256_hex(content),
            )
            .await
            .unwrap();
            assert!(matches!(
                observer.try_lock(),
                Err(std::fs::TryLockError::WouldBlock)
            ));
            assert_eq!(std::fs::read(&path).unwrap(), content);
            guard.release().await;
            guard.release().await;
            observer.try_lock().unwrap();
            drop(observer);
            std::fs::write(&path, b"changed user output").unwrap();
            assert!(
                acquire_receive_publication_guard(
                    File::open(&path).unwrap().into_raw_fd(),
                    content.len() as u64,
                    localsend::crypto::hash::sha256_hex(content),
                )
                .await
                .is_err()
            );
            assert_eq!(std::fs::read(&path).unwrap(), b"changed user output");
            OpenOptions::new()
                .read(true)
                .write(true)
                .open(&path)
                .unwrap()
                .try_lock()
                .unwrap();
            std::fs::remove_file(path).unwrap();
        }

        #[tokio::test]
        async fn cleanup_guard_rejection_consumes_descriptor() {
            let (fd, mut observer) = descriptor();
            assert!(
                acquire_receive_cleanup_guard(fd, 0, "a".repeat(64))
                    .await
                    .is_err()
            );
            closed(&mut observer);
        }
        #[tokio::test]
        async fn cleanup_guard_opaque_holds_lock_until_explicit_idempotent_release() {
            use std::fs::OpenOptions;
            use std::io::Write;
            let path =
                std::env::temp_dir().join(format!("ls-cleanup-guard-{}", uuid::Uuid::new_v4()));
            let mut file = OpenOptions::new()
                .read(true)
                .write(true)
                .create_new(true)
                .open(&path)
                .unwrap();
            file.write_all(b"registered cache").unwrap();
            file.sync_all().unwrap();
            let observer = OpenOptions::new()
                .read(true)
                .write(true)
                .open(&path)
                .unwrap();
            let guard = acquire_receive_cleanup_guard(
                file.into_raw_fd(),
                16,
                localsend::crypto::hash::sha256_hex(b"registered cache"),
            )
            .await
            .unwrap();
            assert!(matches!(
                observer.try_lock(),
                Err(std::fs::TryLockError::WouldBlock)
            ));
            guard.release().await;
            guard.release().await;
            observer.try_lock().unwrap();
            drop(observer);
            std::fs::remove_file(path).unwrap();
        }
        #[tokio::test]
        async fn capability_probe_rejection_closes_both_before_reply() {
            let (cache, mut a) = descriptor();
            let (staging, mut b) = descriptor();
            assert!(!probe_receive_descriptor_pair(cache, staging).await.unwrap());
            closed(&mut a);
            closed(&mut b);
            let (staging, mut b) = descriptor();
            assert!(probe_receive_descriptor_pair(-1, staging).await.is_err());
            closed(&mut b);
        }
        #[tokio::test]
        async fn capability_probe_accepts_empty_regular_pair_without_writing_and_releases_locks() {
            let root = std::env::temp_dir().join(format!("legna-probe-{}", uuid::Uuid::new_v4()));
            std::fs::create_dir(&root).unwrap();
            let cache = root.join("cache");
            let staging = root.join("staging");
            let create = |path: &std::path::Path| {
                std::fs::OpenOptions::new()
                    .read(true)
                    .write(true)
                    .create_new(true)
                    .open(path)
                    .unwrap()
            };
            assert!(
                probe_receive_descriptor_pair(
                    create(&cache).into_raw_fd(),
                    create(&staging).into_raw_fd()
                )
                .await
                .unwrap()
            );
            for path in [&cache, &staging] {
                let file = std::fs::OpenOptions::new()
                    .read(true)
                    .write(true)
                    .open(path)
                    .unwrap();
                assert_eq!(file.metadata().unwrap().len(), 0);
                file.try_lock().unwrap();
            }
            std::fs::remove_dir_all(root).unwrap();
        }
        #[test]
        fn invalid_first_target_still_adopts_and_closes_both_descriptors() {
            let (cache, mut a) = descriptor();
            let (staging, mut b) = descriptor();
            assert!(
                resolve_cached_files(Some("invalid".into()), Some(cache), None, Some(staging))
                    .is_err()
            );
            closed(&mut a);
            closed(&mut b);
        }
        #[test]
        fn invalid_descriptor_does_not_leak_other_owned_target() {
            let (staging, mut observer) = descriptor();
            assert!(resolve_cached_files(None, Some(-1), None, Some(staging)).is_err());
            closed(&mut observer);
        }
        #[test]
        fn identical_integer_is_adopted_exactly_once() {
            let (fd, mut observer) = descriptor();
            assert!(resolve_cached_files(None, Some(fd), None, Some(fd)).is_err());
            closed(&mut observer);
        }
        #[tokio::test]
        async fn cancelling_while_waiting_for_pending_target_releases_both_files() {
            let lock = Arc::new(Mutex::new(()));
            let held = lock.lock().await;
            let (cache, mut a) = descriptor();
            let (staging, mut b) = descriptor();
            let (ready, wait) = oneshot::channel();
            let task = tokio::spawn({
                let lock = lock.clone();
                async move {
                    let files =
                        resolve_cached_files(None, Some(cache), None, Some(staging)).unwrap();
                    ready.send(()).unwrap();
                    let _wait = lock.lock().await;
                    drop(files);
                }
            });
            wait.await.unwrap();
            task.abort();
            assert!(task.await.unwrap_err().is_cancelled());
            closed(&mut a);
            closed(&mut b);
            drop(held);
        }
    }
}

#[cfg(all(test, unix))]
mod directory_document_tests {
    use super::*;
    use std::{
        io::Read,
        os::{fd::IntoRawFd, unix::net::UnixStream},
        time::Duration,
    };
    fn owned() -> (i32, UnixStream) {
        let (file, peer) = UnixStream::pair().unwrap();
        peer.set_read_timeout(Some(Duration::from_millis(100)))
            .unwrap();
        (file.into_raw_fd(), peer)
    }
    fn closed(mut peer: UnixStream) {
        assert_eq!(peer.read(&mut [0]).unwrap(), 0);
    }
    #[tokio::test]
    async fn document_late_expired_stopped_and_dropped_receiver_close_owned_fd() {
        for mode in 0..4 {
            let (fd, peer) = owned();
            let (tx, rx) = oneshot::channel();
            let pending = PendingDirectoryDocument {
                deadline: tokio::time::Instant::now()
                    + if mode == 1 {
                        Duration::ZERO
                    } else {
                        Duration::from_secs(10)
                    },
                result: tx,
            };
            let result = directory_document_result(Some("{}".into()), Some(fd), None);
            let receiver = if mode == 3 {
                drop(rx);
                None
            } else {
                Some(rx)
            };
            assert!(
                !deliver_directory_document(
                    if mode == 0 { None } else { Some(pending) },
                    result,
                    mode == 2
                )
                .unwrap()
            );
            closed(peer);
            drop(receiver);
        }
    }
    #[test]
    fn document_invalid_or_error_payload_closes_fd_before_return() {
        for (payload, error) in [
            (None, None),
            (Some("{}".into()), Some("invalid".into())),
            (None, Some("permission".into())),
            (Some("x".repeat(2 * 1024 * 1024 + 1)), None),
        ] {
            let (fd, peer) = owned();
            drop(directory_document_result(payload, Some(fd), error));
            closed(peer);
        }
    }
    #[tokio::test]
    async fn document_success_transfers_to_receiver_once() {
        let (fd, mut peer) = owned();
        let (tx, rx) = oneshot::channel();
        let pending = PendingDirectoryDocument {
            deadline: tokio::time::Instant::now() + Duration::from_secs(10),
            result: tx,
        };
        assert!(
            deliver_directory_document(
                Some(pending),
                directory_document_result(Some("{}".into()), Some(fd), None),
                false
            )
            .unwrap()
        );
        let value = rx.await.unwrap().unwrap();
        assert!(
            peer.read(&mut [0]).is_err(),
            "receiver still owns the descriptor"
        );
        drop(value);
        closed(peer);
    }
}

#[cfg(test)]
mod recovery_target_responder_tests {
    use super::*;
    #[tokio::test]
    async fn stale_failure_or_response_does_not_take_new_durable_attempt() {
        let (tx, mut rx) = oneshot::channel();
        let mut pending = HashMap::new();
        pending.insert(
            ("session".into(), "file".into()),
            PendingUploadTarget {
                attempt_id: Some("new".into()),
                responder: tx,
            },
        );
        assert!(
            take_upload_target(&mut pending, "session".into(), "file".into(), Some("old"))
                .is_none()
        );
        assert!(take_upload_target(&mut pending, "session".into(), "file".into(), None).is_none());
        assert!(matches!(
            rx.try_recv(),
            Err(tokio::sync::oneshot::error::TryRecvError::Empty)
        ));
        drop(take_upload_target(
            &mut pending,
            "session".into(),
            "file".into(),
            Some("new"),
        ));
        assert!(rx.await.is_err());
    }
    #[tokio::test]
    async fn null_attempt_preserves_original_upload_and_rejects_durable_responder() {
        let (tx, rx) = oneshot::channel();
        let mut pending = HashMap::new();
        pending.insert(
            ("session".into(), "file".into()),
            PendingUploadTarget {
                attempt_id: None,
                responder: tx,
            },
        );
        assert!(
            take_upload_target(
                &mut pending,
                "session".into(),
                "file".into(),
                Some("durable")
            )
            .is_none()
        );
        drop(take_upload_target(
            &mut pending,
            "session".into(),
            "file".into(),
            None,
        ));
        assert!(rx.await.is_err());
    }
}

#[cfg(all(test, unix))]
mod directory_write_bridge_tests {
    use super::*;
    use std::{io::Read, os::fd::IntoRawFd, os::unix::net::UnixStream, time::Duration};
    fn owned() -> (i32, UnixStream) {
        let (file, peer) = UnixStream::pair().unwrap();
        peer.set_read_timeout(Some(Duration::from_millis(100)))
            .unwrap();
        (file.into_raw_fd(), peer)
    }
    fn closed(mut peer: UnixStream) {
        assert_eq!(peer.read(&mut [0]).unwrap(), 0);
    }
    fn pending(
        scope: &str,
        operation: &str,
    ) -> (
        PendingDirectoryWrite,
        oneshot::Receiver<
            Result<localsend::http::server::directories::DirectoryWriteResponse, String>,
        >,
    ) {
        let (tx, rx) = oneshot::channel();
        (
            PendingDirectoryWrite {
                scope: scope.into(),
                operation: operation.into(),
                deadline: None,
                result: tx,
            },
            rx,
        )
    }
    #[test]
    fn partial_invalid_and_aliased_pairs_are_adopted_without_descriptor_number_aba() {
        let (a, peer) = owned();
        assert!(directory_write_result(Some("{}".into()), Some(a), None, None).is_err());
        closed(peer);
        let (a, peer) = owned();
        assert!(directory_write_result(Some("{}".into()), Some(-1), Some(a), None).is_err());
        closed(peer);
        let (a, peer) = owned();
        assert!(directory_write_result(Some("{}".into()), Some(a), Some(a), None).is_err());
        closed(peer);
        let (a, pa) = owned();
        let (b, pb) = owned();
        assert!(directory_write_result(Some("x".repeat(16385)), Some(a), Some(b), None).is_err());
        closed(pa);
        closed(pb);
    }
    #[tokio::test]
    async fn stopped_or_unknown_begin_closes_both_files_before_owner_is_claimed() {
        for known in [true, false] {
            let mut state = DirectoryWriteState {
                pending: HashMap::new(),
                owners: std::collections::HashSet::new(),
            };
            let (pending, rx) = pending("owner", "begin");
            if known {
                state.pending.insert("request".into(), pending);
            } else {
                drop(pending);
            }
            let (a, pa) = owned();
            let (b, pb) = owned();
            let result = directory_write_result(Some("{}".into()), Some(a), Some(b), None);
            assert!(!deliver_directory_write(&mut state, "request", result, true).unwrap());
            closed(pa);
            closed(pb);
            assert!(state.owners.is_empty());
            if known {
                assert!(rx.await.unwrap().is_err());
            }
        }
    }
    #[tokio::test]
    async fn real_publication_after_stop_is_delivered_and_only_release_ends_owner() {
        let mut state = DirectoryWriteState {
            pending: HashMap::new(),
            owners: std::collections::HashSet::new(),
        };
        let (begin, rx) = pending("owner", "begin");
        state.pending.insert("begin".into(), begin);
        let (a, pa) = owned();
        let (b, pb) = owned();
        assert!(
            deliver_directory_write(
                &mut state,
                "begin",
                directory_write_result(Some("{}".into()), Some(a), Some(b), None),
                false
            )
            .unwrap()
        );
        let files = rx.await.unwrap().unwrap();
        assert!(state.owners.contains("owner"));
        drop(files);
        closed(pa);
        closed(pb);
        let (publish, rx) = pending("owner", "publish");
        state.pending.insert("publish".into(), publish);
        assert!(
            deliver_directory_write(
                &mut state,
                "publish",
                directory_write_result(
                    Some("{\"version\":1,\"published\":true}".into()),
                    None,
                    None,
                    None
                ),
                true
            )
            .unwrap()
        );
        assert!(rx.await.unwrap().unwrap().payload.contains("true"));
        assert!(state.owners.contains("owner"));
        let (release, rx) = pending("owner", "release");
        state.pending.insert("release".into(), release);
        assert!(
            deliver_directory_write(
                &mut state,
                "release",
                directory_write_result(Some("{}".into()), None, None, None),
                true
            )
            .unwrap()
        );
        assert!(rx.await.unwrap().is_ok());
        assert!(state.owners.is_empty());
    }
    #[tokio::test]
    async fn unknown_publication_does_not_become_a_false_cancel_or_release_fd_owner() {
        let mut state = DirectoryWriteState {
            pending: HashMap::new(),
            owners: std::collections::HashSet::new(),
        };
        state.owners.insert("owner".into());
        let (publish, rx) = pending("owner", "publish");
        state.pending.insert("publish".into(), publish);
        assert!(
            deliver_directory_write(
                &mut state,
                "publish",
                directory_write_result(None, None, None, Some("publication_unconfirmed".into())),
                true
            )
            .unwrap()
        );
        assert_eq!(rx.await.unwrap().unwrap_err(), "publication_unconfirmed");
        assert!(state.owners.contains("owner"));
    }
}

#[cfg(test)]
mod source_end_scope_bridge_tests {
    use super::*;

    #[tokio::test]
    async fn actual_server_stop_clears_unanswered_requests_but_response_api_still_waits_for_worker()
    {
        let server = Arc::new(
            start_server(
                0,
                None,
                "scope-fixture".into(),
                "2.2".into(),
                None,
                None,
                "scope-fingerprint".into(),
                None,
                true,
                WebParams {
                    mode: WebMode::Disabled,
                    i18n: WebI18n::default(),
                    pages: WebPages::default(),
                },
                None,
            )
            .await
            .unwrap(),
        );
        let (decision, accepted) = oneshot::channel();
        let (complete, completion) = oneshot::channel();
        let id = register_source_end_scope(
            &mut *server.pending_source_end_scopes.lock().await,
            decision,
            completion,
        )
        .unwrap();
        let answering_server = server.clone();
        let answering = tokio::spawn(async move {
            answering_server
                .respond_receive_source_end_scope(id, true)
                .await
        });
        assert!(accepted.await.unwrap());
        let (waiting_decision, waiting_response) = oneshot::channel();
        let (_waiting_complete, waiting_completion) = oneshot::channel();
        let waiting_id = register_source_end_scope(
            &mut *server.pending_source_end_scopes.lock().await,
            waiting_decision,
            waiting_completion,
        )
        .unwrap();
        server.stop().await;
        assert!(waiting_response.await.is_err());
        assert!(
            !server
                .respond_receive_source_end_scope(waiting_id, true)
                .await
                .unwrap()
        );
        assert!(!answering.is_finished());
        complete.send(()).unwrap();
        assert!(answering.await.unwrap().unwrap());
    }

    #[tokio::test]
    async fn granted_scope_waits_for_real_worker_completion_despite_listener_stop_and_expiry() {
        let mut map = HashMap::new();
        let (decision, accepted) = oneshot::channel();
        let (complete, completion) = oneshot::channel();
        let id = register_source_end_scope(&mut map, decision, completion).unwrap();
        let responding = tokio::spawn(deliver_source_end_scope(map.remove(&id), true, false));
        assert!(accepted.await.unwrap());
        // Both listener teardown and the periodic reaper only own unanswered entries.
        map.clear();
        prune_source_end_scopes(&mut map);
        tokio::task::yield_now().await;
        assert!(!responding.is_finished());
        assert!(
            !deliver_source_end_scope(map.remove(&id), true, true)
                .await
                .unwrap()
        );
        assert!(!responding.is_finished());
        complete.send(()).unwrap();
        assert!(responding.await.unwrap().unwrap());
    }

    #[tokio::test]
    async fn missing_reply_listener_teardown_and_stop_drop_decision_without_starting_work() {
        for stopped in [false, true] {
            let mut map = HashMap::new();
            let (decision, accepted) = oneshot::channel();
            let (_complete, completion) = oneshot::channel();
            let id = register_source_end_scope(&mut map, decision, completion).unwrap();
            let pending = if stopped {
                map.remove(&id)
            } else {
                map.clear();
                map.remove(&id)
            };
            assert!(
                !deliver_source_end_scope(pending, true, stopped)
                    .await
                    .unwrap()
            );
            assert!(accepted.await.is_err());
        }
    }

    #[tokio::test]
    async fn denial_returns_false_without_waiting_for_a_worker_that_never_started() {
        let mut map = HashMap::new();
        let (decision, accepted) = oneshot::channel();
        let (_complete, completion) = oneshot::channel();
        let id = register_source_end_scope(&mut map, decision, completion).unwrap();
        assert!(
            !deliver_source_end_scope(map.remove(&id), false, false)
                .await
                .unwrap()
        );
        assert!(!accepted.await.unwrap());
    }

    #[tokio::test]
    async fn lost_completion_after_grant_is_error_not_a_false_drain_confirmation() {
        let mut map = HashMap::new();
        let (decision, accepted) = oneshot::channel();
        let (complete, completion) = oneshot::channel();
        let id = register_source_end_scope(&mut map, decision, completion).unwrap();
        let responding = tokio::spawn(deliver_source_end_scope(map.remove(&id), true, false));
        assert!(accepted.await.unwrap());
        drop(complete);
        assert!(responding.await.unwrap().is_err());
    }

    #[tokio::test]
    async fn unanswered_requests_are_bounded_and_expire_without_granting_work() {
        let mut map = HashMap::new();
        let mut accepted = Vec::new();
        let mut workers = Vec::new();
        for _ in 0..4 {
            let (decision, response) = oneshot::channel();
            let (complete, completion) = oneshot::channel();
            register_source_end_scope(&mut map, decision, completion).unwrap();
            accepted.push(response);
            workers.push(complete);
        }
        let (decision, extra) = oneshot::channel();
        let (_complete, completion) = oneshot::channel();
        assert!(register_source_end_scope(&mut map, decision, completion).is_none());
        assert!(extra.await.is_err());
        for value in map.values_mut() {
            value.deadline = tokio::time::Instant::now();
        }
        prune_source_end_scopes(&mut map);
        assert!(map.is_empty());
        for response in accepted {
            assert!(response.await.is_err());
        }
        assert!(workers.iter().all(oneshot::Sender::is_closed));
    }

    #[tokio::test]
    async fn sink_failure_and_core_cancellation_drop_only_unanswered_entries() {
        let mut map = HashMap::new();
        let (decision, accepted) = oneshot::channel();
        let (_complete, completion) = oneshot::channel();
        let id = register_source_end_scope(&mut map, decision, completion).unwrap();
        map.remove(&id); // Same operation used when StreamSink::add fails.
        assert!(accepted.await.is_err());
        let (decision, accepted) = oneshot::channel();
        let (_complete, completion) = oneshot::channel();
        register_source_end_scope(&mut map, decision, completion).unwrap();
        drop(accepted);
        prune_source_end_scopes(&mut map);
        assert!(map.is_empty());
    }
}
