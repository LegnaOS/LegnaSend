use crate::http::dto_v2::{
    InfoResponseDtoV2, PrepareUploadRequestDtoV2, PrepareUploadResponseDtoV2, RegisterDtoV2,
    RegisterResponseDtoV2,
};
use crate::http::server::PeerIp;
use crate::http::server::common::collect_to_json::CollectToJson;
use crate::http::server::common::error::AppError;
use crate::http::server::common::pin::check_pin;
use crate::http::server::common::query::parse_query;
use crate::http::server::common::response::{BoxedBody, JsonResponse, empty_body};
use crate::http::server::common::save::{FileTimestamps, FileUploadTarget, SaveResult};
use crate::http::server::common::session::{
    FileStatusV2, PendingSessionV2, SessionFileV2, SessionStateV2, UploadSessionV2,
};
use crate::http::server::{AppState, RequestClientInfo, V2State, common};
use crate::model::discovery::PROTOCOL_VERSION_V2;
use crate::model::transfer::FileDto;
use hyper::body::Incoming;
use hyper::{Request, Response, StatusCode};
use std::collections::{HashMap, HashSet};
use std::sync::Arc;
use tokio::sync::oneshot;
use tokio_util::sync::CancellationToken;
use uuid::Uuid;

/// Provider-owned candidate, supplied only by the private approved-target bridge.
pub struct CacheRecoverySource {
    pub file: std::fs::File,
    pub identity: crate::download_cache::CacheIdentity,
    pub transaction_id: String,
}

impl std::fmt::Debug for CacheRecoverySource {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("CacheRecoverySource")
            .finish_non_exhaustive()
    }
}

#[derive(Debug)]
pub enum ServerEventV2 {
    /// Private source-end authorization; never carries wire secrets. Completion
    /// fires only after the real cleanup worker has stopped using the directory.
    ReceiveSourceEndScope {
        directory: String,
        decision_tx: oneshot::Sender<bool>,
        completion_rx: oneshot::Receiver<()>,
    },

    /// Private, coalesced workspace observation persistence. No LocalSend wire changes.
    DirectoryContent {
        request: String,
        result_tx: oneshot::Sender<Result<String, String>>,
    },
    /// Private workspace publication bridge, independent of native upload sessions.
    DirectoryDocumentWrite {
        request: String,
        result_tx: oneshot::Sender<Result<super::directories::DirectoryWriteResponse, String>>,
    },
    /// Host document provider operation; never a public LocalSend wire message.
    DirectoryDocument {
        request: String,
        result_tx: oneshot::Sender<Result<super::directories::DocumentResponse, String>>,
    },
    /// Browser directory batch approval, independent of native protocol sessions.
    DirectoryUploadApproval {
        request_id: String,
        request: String,
        decision_tx: oneshot::Sender<bool>,
    },
    DirectoryUploadApprovalAborted {
        request_id: String,
    },
    /// App-owned persisted workspace management, unrelated to LocalSend wire requests.
    WorkspaceManagement {
        request: super::integration::PendingManagement,
    },
    /// A device registered itself via `POST /api/localsend/v2/register`.
    ///
    /// On TLS, this event is only emitted when `info.fingerprint` matches the
    /// SHA-256 fingerprint of the client certificate verified during the mTLS
    /// handshake, so the fingerprint cannot be spoofed.
    Register {
        /// The IP address of the remote device.
        ip: PeerIp,

        /// The device information sent by the remote device.
        info: RegisterDtoV2,
    },

    /// A sender requests to upload files via `POST /api/localsend/v2/prepare-upload`.
    ///
    /// The application must answer on `decision_tx`.
    /// Dropping `decision_tx` results in a 500 response.
    PrepareUpload {
        /// The session ID the upload session will have when the request is
        /// accepted. Pre-generated so the application can track the session
        /// consistently from the start.
        session_id: String,

        /// The IP address of the sender.
        ip: PeerIp,

        /// The device information of the sender.
        info: RegisterDtoV2,

        /// The SHA-256 fingerprint (uppercase hex) of the sender's client
        /// certificate verified during the mTLS handshake. Unlike
        /// `info.fingerprint`, this value cannot be spoofed.
        /// `None` when the server runs without TLS.
        cert_fingerprint: Option<String>,

        /// The offered files, mapped by file ID.
        files: HashMap<String, FileDto>,

        /// Channel to send the decision (accept all, a subset, or decline).
        decision_tx: oneshot::Sender<PrepareUploadDecisionV2>,
    },

    /// An accepted file is being uploaded via `POST /api/localsend/v2/upload`.
    ///
    /// The application must answer on `target_tx` with where the file content
    /// should go (a stream to consume itself, a path, or a file descriptor).
    /// Dropping `target_tx` results in a 500 response.
    FileUpload {
        /// The session ID of the upload session.
        session_id: String,

        /// The ID of the file being uploaded.
        file_id: String,

        /// The metadata of the file being uploaded.
        file: FileDto,

        /// Channel to send the target the file content should be written to.
        target_tx: oneshot::Sender<FileUploadTarget>,
    },

    FileUploadRecovery {
        session_id: String,
        file_id: String,
        attempt_id: String,
        file: FileDto,
        target_tx: oneshot::Sender<FileUploadTarget>,
    },
    FileVerification {
        session_id: String,
        file_id: String,
        attempt_id: String,
        verified_bytes: u64,
        total_bytes: u64,
        verifying: bool,
    },

    /// Persist the exact cache identity in the provider's private journal before
    /// writing even its header. This is internal, never a new wire requirement.
    ReceiveCacheIdentity {
        session_id: String,
        file_id: String,
        attempt_id: String,
        transaction_id: String,
        identity_json: String,
        result_tx: oneshot::Sender<Result<Option<CacheRecoverySource>, String>>,
    },
    /// Verified source records have been copied into the new synced cache and
    /// the old descriptor is closed. Persist the migration before reporting offset.
    ReceiveCacheRecovered {
        session_id: String,
        file_id: String,
        attempt_id: String,
        transaction_id: String,
        source_transaction_id: String,
        source_length: u64,
        source_sha256: String,
        result_tx: oneshot::Sender<Result<(), String>>,
    },

    /// Internal provider publication request. Both owned descriptors are closed;
    /// the application must commit through its journal and acknowledge publication.
    /// No upload success is reported until this responder returns `Ok(())`.
    PublishUpload {
        session_id: String,
        file_id: String,
        attempt_id: String,
        transaction_id: String,
        /// Verified exported original bytes, not sender-provided metadata.
        size: u64,
        sha256: String,
        result_tx: oneshot::Sender<Result<(), String>>,
    },

    /// Best-effort internal lifecycle notification after descriptor ownership ends.
    /// Delivery may be lost on shutdown/full event queues: the provider journal
    /// must reconcile abandoned transactions independently. `published` is true
    /// only when the application's publication acknowledgement was received.
    UploadCacheReleased {
        session_id: String,
        file_id: String,
        attempt_id: String,
        transaction_id: String,
        published: bool,
    },

    /// An upload session ended.
    SessionEnd {
        /// The session ID of the ended session.
        session_id: String,

        /// Why the session ended.
        reason: SessionEndReasonV2,
    },

    /// A prepare-upload request was aborted before a session was created,
    /// e.g. the sender disconnected while the application was still deciding.
    /// The `decision_tx` of the [ServerEventV2::PrepareUpload] with the same
    /// session ID is dead; answering it has no effect.
    PrepareUploadAborted {
        /// The session ID of the aborted prepare-upload request.
        session_id: String,
    },

    /// `POST /api/localsend/v2/cancel` was received for a session this server
    /// does not manage. This happens when the remote device cancels a transfer
    /// that this application is currently *sending* to it: the session ID is
    /// the one issued by the remote device during prepare-upload.
    ///
    /// The application must verify that `ip` matches the target of the
    /// send session before cancelling it.
    CancelReceived {
        /// The IP address of the remote device requesting the cancellation.
        ip: PeerIp,

        /// The session ID as known by the remote device.
        session_id: String,
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

/// The application's decision for a prepare-upload request.
#[derive(Debug)]
pub enum PrepareUploadDecisionV2 {
    /// Accept the given file IDs (a subset of the offered files).
    /// An empty set responds with 204 (no file transfer needed).
    Accept(HashSet<String>),

    /// Optional LegnaSend extension for approved ordinary persistent cache paths.
    /// The original v2 wire response is unchanged.
    AcceptResumable {
        file_ids: HashSet<String>,
        resumable_file_ids: HashSet<String>,
    },

    /// Internal opt-in; no required original-v2 fields change.
    AcceptDurable {
        file_ids: HashSet<String>,
        resumable_file_ids: HashSet<String>,
        durable_file_ids: HashSet<String>,
    },
    /// Decline the request (403).
    Decline,
}

/// Why an upload session ended.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum SessionEndReasonV2 {
    /// All accepted files reached a final state (finished or failed).
    Finished,

    /// The sender cancelled the session via `POST /api/localsend/v2/cancel`.
    Cancelled,

    /// An accepted session had no in-progress upload or activity for ten minutes.
    /// Internal event only; original LocalSend wire messages are unchanged.
    Expired,
}

pub(crate) async fn register(
    body: Incoming,
    state: AppState,
    client_info: RequestClientInfo,
) -> Result<JsonResponse<RegisterResponseDtoV2>, AppError> {
    let payload = body.collect_to_json::<RegisterDtoV2>().await?;

    // On TLS, only trust registrations whose claimed fingerprint is proven
    // by the client certificate of the mTLS handshake.
    let fingerprint_valid = match client_info.cert_fingerprint() {
        Some(cert_fingerprint) => payload.fingerprint.to_ascii_uppercase() == cert_fingerprint,
        None => true,
    };

    if let Some(v2) = &state.v2 {
        if fingerprint_valid {
            // Not awaited: registrations arrive in bursts (every device on the
            // network answers an announcement, and a peer scanning its subnet
            // registers with everyone), so the channel fills up easily. Waiting
            // would block this request handler — and every later one — until
            // the application catches up, which is what makes the device stop
            // answering `register` altogether.
            //
            // The event carries no responder, and peers repeat their
            // announcement, so a dropped registration is recoverable.
            if let Err(err) = v2.event_tx.try_send(ServerEventV2::Register {
                ip: client_info.ip,
                info: payload,
            }) {
                tracing::debug!("Dropped a register event: {err}");
            }
        } else {
            tracing::warn!(
                "Ignoring register from {}: claimed fingerprint does not match the client certificate",
                client_info.ip
            );
        }
    }

    let info = state.info.lock().await.clone();
    let download = state.web.share().download().is_some();

    Ok(JsonResponse {
        status: StatusCode::OK,
        body: RegisterResponseDtoV2 {
            alias: info.alias,
            version: PROTOCOL_VERSION_V2.to_string(),
            device_model: info.device_model,
            device_type: info.device_type,
            fingerprint: info.token,
            download,
        },
    })
}

pub(crate) async fn info(state: AppState) -> Result<JsonResponse<InfoResponseDtoV2>, AppError> {
    let info = state.info.lock().await.clone();
    let download = state.web.share().download().is_some();

    Ok(JsonResponse {
        status: StatusCode::OK,
        body: InfoResponseDtoV2 {
            alias: info.alias,
            version: PROTOCOL_VERSION_V2.to_string(),
            device_model: info.device_model,
            device_type: info.device_type,
            fingerprint: info.token,
            download,
        },
    })
}

pub(crate) async fn prepare_upload(
    req: Request<Incoming>,
    state: AppState,
    client_info: RequestClientInfo,
) -> Result<Response<BoxedBody>, AppError> {
    let v2 = require_v2(&state)?;
    let query = parse_query(req.uri().query());

    // Optional browser marker selects the workspace PIN, not the native-device PIN.
    // Native clients retain the original route, payload, PIN and file bodies.
    let workspace_request = query.get("web").is_some_and(|v| v == "1");
    if workspace_request && !state.web.duplex() {
        return Err(AppError::Status(StatusCode::FORBIDDEN));
    }
    let share = state.web.share();
    if workspace_request {
        state.web.upload_permission()?;
    }
    let pin = if workspace_request {
        share.download().and_then(|web| web.pin.as_deref())
    } else {
        v2.pin.as_deref()
    };
    check_pin(pin, &v2.pin_attempts, &query, client_info.ip.ip).await?;

    let payload = req
        .into_body()
        .collect_to_json::<PrepareUploadRequestDtoV2>()
        .await?;

    let browser = state.web.duplex()
        && (workspace_request
            || payload.info.device_type == Some(crate::model::discovery::DeviceType::Web));
    let permission_epoch = if browser {
        Some(state.web.upload_permission()?)
    } else {
        None
    };

    if payload.files.is_empty() {
        return Err(AppError::BadRequest("No files provided".to_string()));
    }

    let session_id = Uuid::new_v4().to_string();
    let cancelled = CancellationToken::new();

    // Claim the single session slot.
    {
        let mut slot = v2.session.lock().await;
        if slot.is_some() {
            return Err(AppError::Message(
                StatusCode::CONFLICT,
                "Blocked by another session".to_string(),
            ));
        }
        *slot = Some(SessionStateV2::Pending(PendingSessionV2 {
            session_id: session_id.clone(),
            sender_ip: client_info.ip,
            cancel: cancelled.clone(),
        }));
    }

    // Frees the slot again if this request is aborted before a session is created.
    let mut pending_guard = PendingSessionGuard::new(v2.clone(), session_id.clone());

    let (decision_tx, decision_rx) = oneshot::channel();
    let event = ServerEventV2::PrepareUpload {
        session_id: session_id.clone(),
        ip: client_info.ip,
        info: payload.info,
        cert_fingerprint: client_info.cert_fingerprint(),
        files: payload.files.clone(),
        decision_tx,
    };
    tokio::select! {
        biased;
        _ = cancelled.cancelled() => return Err(AppError::Status(StatusCode::FORBIDDEN)),
        sent = v2.event_tx.send(event) => {
            sent.map_err(|_| AppError::Status(StatusCode::INTERNAL_SERVER_ERROR))?;
        }
    }

    // The sender may cancel the request while the application is deciding.
    // Returning with the guard still armed frees the slot and emits
    // [ServerEventV2::PrepareUploadAborted], like a dropped connection.
    let decision = tokio::select! {
        biased;
        _ = cancelled.cancelled() => {
            return Err(AppError::Message(
                StatusCode::FORBIDDEN,
                "Cancelled by sender".to_string(),
            ));
        }
        decision = decision_rx => {
            decision.map_err(|_| AppError::Status(StatusCode::INTERNAL_SERVER_ERROR))?
        }
    };

    if let Some(epoch) = permission_epoch {
        // Disabling and re-enabling while a decision is pending must not revive it.
        if state.web.upload_permission()? != epoch {
            return Err(AppError::Message(
                StatusCode::FORBIDDEN,
                "Web upload permission changed".into(),
            ));
        }
    }
    let (accepted_ids, resumable_ids, durable_ids) = match decision {
        PrepareUploadDecisionV2::Decline => {
            pending_guard.clear().await;
            return Err(AppError::Message(
                StatusCode::FORBIDDEN,
                "Rejected".to_string(),
            ));
        }
        PrepareUploadDecisionV2::Accept(ids) => (ids, HashSet::new(), HashSet::new()),
        PrepareUploadDecisionV2::AcceptResumable {
            file_ids,
            resumable_file_ids,
        } => (file_ids, resumable_file_ids, HashSet::new()),
        PrepareUploadDecisionV2::AcceptDurable {
            file_ids,
            resumable_file_ids,
            durable_file_ids,
        } => (file_ids, resumable_file_ids, durable_file_ids),
    };

    let files: HashMap<String, SessionFileV2> = payload
        .files
        .into_iter()
        .filter(|(id, _)| accepted_ids.contains(id))
        .map(|(id, dto)| {
            let file = SessionFileV2 {
                dto,
                token: Uuid::new_v4().to_string(),
                status: FileStatusV2::Pending,
                attempts: 0,
                resumable: resumable_ids.contains(&id),
                durable: resumable_ids.contains(&id) && durable_ids.contains(&id),
            };
            (id, file)
        })
        .collect();

    if files.is_empty() {
        // Nothing to transfer.
        pending_guard.clear().await;
        let mut res = Response::new(empty_body());
        *res.status_mut() = StatusCode::NO_CONTENT;
        return Ok(res);
    }

    let tokens: HashMap<String, String> = files
        .iter()
        .map(|(id, file)| (id.clone(), file.token.clone()))
        .collect();

    {
        let mut slot = v2.session.lock().await;
        // A cancelled/dropped prepare must never resurrect itself or overwrite
        // a newer pending owner while the application's decision was in flight.
        if !matches!(slot.as_ref(), Some(SessionStateV2::Pending(pending))
            if pending.session_id == session_id && pending.sender_ip == client_info.ip && !pending.cancel.is_cancelled())
        {
            return Err(AppError::Message(
                StatusCode::FORBIDDEN,
                "Upload request is no longer active".into(),
            ));
        }
        *slot = Some(SessionStateV2::Active(UploadSessionV2 {
            cancel: cancelled.clone(),
            session_id: session_id.clone(),
            last_activity: tokio::time::Instant::now(),
            sender_ip: client_info.ip,
            sender_cert: client_info.cert_fingerprint(),
            files,
        }));
        v2.session_changed.notify_one();
    }
    pending_guard.disarm();

    tracing::info!("Upload session created: {session_id}");

    Ok(JsonResponse {
        status: StatusCode::OK,
        body: PrepareUploadResponseDtoV2 {
            session_id,
            files: tokens,
        },
    }
    .into_response())
}

pub(crate) async fn upload(
    req: Request<Incoming>,
    state: AppState,
    client_info: RequestClientInfo,
) -> Result<Response<BoxedBody>, AppError> {
    let v2 = require_v2(&state)?;
    let query = parse_query(req.uri().query());

    let (Some(session_id), Some(file_id), Some(token)) = (
        query.get("sessionId"),
        query.get("fileId"),
        query.get("token"),
    ) else {
        return Err(AppError::Message(
            StatusCode::BAD_REQUEST,
            "Missing parameters".to_string(),
        ));
    };

    // Validate the request and mark the file as in progress.
    let (file_dto, cancel) = {
        let mut slot = v2.session.lock().await;
        let Some(SessionStateV2::Active(session)) = slot.as_mut() else {
            return Err(invalid_token_error());
        };
        if session.session_id != *session_id || session.sender_ip != client_info.ip {
            return Err(invalid_token_error());
        }
        let Some(file) = session.files.get_mut(file_id) else {
            return Err(invalid_token_error());
        };
        if file.token != *token || file.status != FileStatusV2::Pending {
            return Err(invalid_token_error());
        }
        file.status = FileStatusV2::InProgress;
        file.attempts = file.attempts.saturating_add(1);
        session.last_activity = tokio::time::Instant::now();
        v2.session_changed.notify_one();
        (file.dto.clone(), session.cancel.clone())
    };

    // Marks the file as failed if this request is aborted mid-transfer.
    let mut upload_guard = UploadGuard::new(v2.clone(), session_id.clone(), file_id.clone());

    let file_size = file_dto.size;
    let expected_sha256 = match v2.verify_checksums {
        true => file_dto.sha256.clone(),
        false => None,
    };
    let timestamps = match &file_dto.metadata {
        Some(metadata) => FileTimestamps {
            modified: metadata.modified_time(),
            accessed: metadata.accessed_time(),
        },
        None => FileTimestamps::default(),
    };
    let (target_tx, target_rx) = oneshot::channel::<FileUploadTarget>();

    let event = ServerEventV2::FileUpload {
        session_id: session_id.clone(),
        file_id: file_id.clone(),
        file: file_dto,
        target_tx,
    };
    let delivered = tokio::select! {
        biased;
        _ = cancel.cancelled() => false,
        sent = v2.event_tx.send(event) => sent.is_ok(),
    };
    if !delivered {
        upload_guard.finish(SaveResult::Failed).await;
        return Err(AppError::Status(StatusCode::INTERNAL_SERVER_ERROR));
    }

    // Cancellation must not wait for a slow save-target/permission resolver.
    // Dropping target_rx also closes any late owned-descriptor response.
    let target = tokio::select! {
        biased;
        _ = cancel.cancelled() => None,
        target = target_rx => target.ok(),
    };
    let Some(target) = target else {
        upload_guard.finish(SaveResult::Failed).await;
        return Err(AppError::Status(StatusCode::INTERNAL_SERVER_ERROR));
    };

    let result = common::save::save_req_to_target(
        req,
        target,
        file_size,
        expected_sha256.as_deref(),
        timestamps,
        common::receive_cache::Context {
            cancel,
            session_id: session_id.clone(),
            file_id: file_id.clone(),
            attempt_id: Uuid::new_v4().to_string(),
            event_tx: v2.event_tx.clone(),
        },
    )
    .await;

    upload_guard.finish(result).await;

    match result {
        SaveResult::Success => Ok(Response::new(empty_body())),
        SaveResult::Failed => Err(AppError::Status(StatusCode::INTERNAL_SERVER_ERROR)),
        SaveResult::HashMismatch => Err(AppError::Message(
            StatusCode::UNPROCESSABLE_ENTITY,
            "Checksum mismatch".to_string(),
        )),
    }
}

pub(crate) async fn cancel(
    req: Request<Incoming>,
    state: AppState,
    client_info: RequestClientInfo,
) -> Result<Response<BoxedBody>, AppError> {
    let v2 = require_v2(&state)?;
    let query = parse_query(req.uri().query());
    let session_id = query.get("sessionId");

    // A pending prepare-upload request: the sender does not know the session
    // ID yet (it is part of the response), so a cancel from the pending
    // sender's address is accepted without one.
    let pending_cancelled = {
        let mut slot = v2.session.lock().await;
        match slot.as_ref() {
            Some(SessionStateV2::Pending(pending))
                if pending.sender_ip == client_info.ip
                    && session_id.is_none_or(|id| *id == pending.session_id) =>
            {
                tracing::info!(
                    "Pending upload session cancelled by sender: {}",
                    pending.session_id
                );
                // Release ownership before acknowledging cancellation. The
                // old request guard notifies the app using its exact old ID.
                pending.cancel.cancel();
                *slot = None;
                true
            }
            _ => false,
        }
    };

    if pending_cancelled {
        return Ok(Response::new(empty_body()));
    }

    if let Some(session_id) = session_id {
        let cancelled = {
            let mut slot = v2.session.lock().await;
            // Capability approval is not negotiation: original peers retain
            // their existing cancellation behavior until an extension opens.
            let negotiated = v2.resumes.contains_session(session_id);
            match slot.as_ref() {
                Some(SessionStateV2::Active(session))
                    if session.session_id == *session_id
                        && session.sender_ip == client_info.ip
                        && (!negotiated
                            || session.sender_cert == client_info.cert_fingerprint()) =>
                {
                    session.cancel.cancel();
                    *slot = None;
                    v2.session_changed.notify_one();
                    true
                }
                _ => false,
            }
        };

        v2.resumes.revoke(session_id, &client_info);

        if cancelled {
            tracing::info!("Upload session cancelled by sender: {session_id}");
            send_committed_session_end(&v2, session_id.clone(), SessionEndReasonV2::Cancelled)
                .await;
        } else {
            // Not one of our upload sessions: the remote device may be
            // cancelling a transfer this application is sending to it.
            let _ = v2
                .event_tx
                .send(ServerEventV2::CancelReceived {
                    ip: client_info.ip,
                    session_id: session_id.clone(),
                })
                .await;
        }
    }

    Ok(Response::new(empty_body()))
}

fn require_v2(state: &AppState) -> Result<Arc<V2State>, AppError> {
    state
        .v2
        .clone()
        .ok_or(AppError::Status(StatusCode::NOT_FOUND))
}

fn invalid_token_error() -> AppError {
    AppError::Message(
        StatusCode::FORBIDDEN,
        "Invalid token or IP address".to_string(),
    )
}

/// Frees a claimed `Pending` session slot unless a session was created.
///
/// The cleanup also runs on drop so the slot is not leaked
/// when the request future is cancelled (e.g. the sender disconnected
/// while the application was still deciding).
struct PendingSessionGuard {
    v2: Arc<V2State>,
    session_id: String,
    armed: bool,
}

impl PendingSessionGuard {
    fn new(v2: Arc<V2State>, session_id: String) -> Self {
        Self {
            v2,
            session_id,
            armed: true,
        }
    }

    /// Disarms the guard after the pending slot was replaced by an active session.
    fn disarm(&mut self) {
        self.armed = false;
    }

    /// Frees the pending slot immediately.
    async fn clear(&mut self) {
        clear_pending_session(&self.v2, &self.session_id).await;
        self.armed = false;
    }
}

impl Drop for PendingSessionGuard {
    fn drop(&mut self) {
        if !self.armed {
            return;
        }
        let v2 = self.v2.clone();
        let session_id = std::mem::take(&mut self.session_id);
        tokio::spawn(async move {
            clear_pending_session(&v2, &session_id).await;
            // The application may still be waiting for a decision; tell it
            // that answering is pointless now.
            tokio::select! {
                biased;
                _ = v2.stopped.cancelled() => {}
                _ = v2.event_tx.send(ServerEventV2::PrepareUploadAborted { session_id }) => {}
            }
        });
    }
}

async fn clear_pending_session(v2: &V2State, session_id: &str) {
    let mut slot = v2.session.lock().await;
    if matches!(slot.as_ref(), Some(SessionStateV2::Pending(pending)) if pending.session_id == session_id)
    {
        *slot = None;
    }
}

/// Sets the final status of a file after an upload attempt.
///
/// The cleanup also runs on drop (as a failure) so the file is not stuck
/// in progress when the request future is cancelled mid-transfer.
struct UploadGuard {
    v2: Arc<V2State>,
    session_id: String,
    file_id: String,
    armed: bool,
}

impl UploadGuard {
    fn new(v2: Arc<V2State>, session_id: String, file_id: String) -> Self {
        Self {
            v2,
            session_id,
            file_id,
            armed: true,
        }
    }

    async fn finish(&mut self, result: SaveResult) {
        finalize_file(&self.v2, &self.session_id, &self.file_id, result).await;
        self.armed = false;
    }
}

impl Drop for UploadGuard {
    fn drop(&mut self) {
        if !self.armed {
            return;
        }
        let v2 = self.v2.clone();
        let session_id = std::mem::take(&mut self.session_id);
        let file_id = std::mem::take(&mut self.file_id);
        tokio::spawn(async move {
            finalize_file(&v2, &session_id, &file_id, SaveResult::Failed).await;
        });
    }
}

/// How often an upload of the same file may be started, i.e. how often a
/// sender may retry a file after a checksum mismatch.
/// Senders must not retry more often than this (see the upload isolate).
const MAX_UPLOAD_ATTEMPTS: u8 = 3;

/// Sets the final status of a file and ends the session once all files are done.
///
/// A checksum mismatch resets the file to [FileStatusV2::Pending] (as long as
/// [MAX_UPLOAD_ATTEMPTS] is not exhausted) so the sender can retry the upload
/// with the same token; the session stays active in that case.
pub(super) async fn finalize_file(
    v2: &V2State,
    session_id: &str,
    file_id: &str,
    result: SaveResult,
) {
    let session_ended = {
        let mut slot = v2.session.lock().await;
        let Some(SessionStateV2::Active(session)) = slot.as_mut() else {
            return;
        };
        if session.session_id != session_id {
            return;
        }
        if let Some(file) = session.files.get_mut(file_id) {
            if file.status == FileStatusV2::InProgress {
                file.status = match result {
                    SaveResult::Success => FileStatusV2::Finished,
                    SaveResult::HashMismatch if file.attempts < MAX_UPLOAD_ATTEMPTS => {
                        FileStatusV2::Pending
                    }
                    SaveResult::Failed | SaveResult::HashMismatch => FileStatusV2::Failed,
                };
                session.last_activity = tokio::time::Instant::now();
                v2.session_changed.notify_one();
            }
        }
        match session.is_complete() {
            true => {
                session.cancel.cancel();
                *slot = None;
                true
            }
            false => false,
        }
    };

    if session_ended {
        tracing::info!("Upload session finished: {session_id}");
        send_committed_session_end(v2, session_id.to_string(), SessionEndReasonV2::Finished).await;
    }
}

/// Once the slot is released, the request no longer owns the terminal event.
/// Keep normal backpressure, but transfer a blocked delivery to a task before
/// awaiting: dropping the HTTP request must not erase a committed SessionEnd.
/// Closed application channels simply discard events; shutdown is not retried.
async fn send_committed_session_end(v2: &V2State, session_id: String, reason: SessionEndReasonV2) {
    if v2.stopped.is_cancelled() {
        return;
    }
    let event = ServerEventV2::SessionEnd { session_id, reason };
    match v2.event_tx.try_send(event) {
        Ok(()) | Err(tokio::sync::mpsc::error::TrySendError::Closed(_)) => {}
        Err(tokio::sync::mpsc::error::TrySendError::Full(event)) => {
            let tx = v2.event_tx.clone();
            let stopped = v2.stopped.clone();
            let delivery = tokio::spawn(async move {
                tokio::select! {
                    biased;
                    _ = stopped.cancelled() => {}
                    _ = tx.send(event) => {}
                }
            });
            let _ = delivery.await;
        }
    }
}

// The original protocol has no idle-expiry negotiation. This internal resource
// limit applies only after acceptance and while no upload owns an active file.
const ACTIVE_RECEIVE_IDLE_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(10 * 60);

/// One task per listener, not per file/request. Notifications reschedule a
/// single deadline; in-progress target selection, body I/O and publication
/// suspend it entirely. Every wake re-reads the current slot under its lock.
pub(crate) async fn watch_active_idle(v2: Arc<V2State>) {
    loop {
        let changed = v2.session_changed.notified();
        let deadline = {
            let slot = v2.session.lock().await;
            if v2.stopped.is_cancelled() {
                return;
            }
            match slot.as_ref() {
                Some(SessionStateV2::Active(session))
                    if !session
                        .files
                        .values()
                        .any(|file| file.status == FileStatusV2::InProgress) =>
                {
                    Some(session.last_activity + ACTIVE_RECEIVE_IDLE_TIMEOUT)
                }
                _ => None,
            }
        };
        tokio::select! {
            biased;
            _ = v2.stopped.cancelled() => return,
            _ = changed => continue,
            _ = async {
                match deadline {
                    Some(deadline) => tokio::time::sleep_until(deadline).await,
                    None => std::future::pending().await,
                }
            } => {}
        }
        // Never act on the session/deadline captured before the sleep.
        let expired = {
            let mut slot = v2.session.lock().await;
            if v2.stopped.is_cancelled() {
                return;
            }
            match slot.as_ref() {
                Some(SessionStateV2::Active(session))
                    if !session
                        .files
                        .values()
                        .any(|file| file.status == FileStatusV2::InProgress)
                        && session.last_activity.elapsed() >= ACTIVE_RECEIVE_IDLE_TIMEOUT =>
                {
                    let session_id = session.session_id.clone();
                    session.cancel.cancel();
                    *slot = None;
                    Some(session_id)
                }
                _ => None,
            }
        };
        if let Some(session_id) = expired {
            tracing::info!("Idle upload session expired: {session_id}");
            send_committed_session_end(&v2, session_id, SessionEndReasonV2::Expired).await;
        }
    }
}

/// Stop is not an idle expiry. Invalidate pending decisions and active tokens,
/// and let already-running file owners perform their ordinary cancellation.
pub(crate) async fn stop_native_sessions(v2: &V2State) {
    v2.stopped.cancel();
    v2.resumes.stop();
    let mut slot = v2.session.lock().await;
    if let Some(session) = slot.take() {
        match session {
            SessionStateV2::Pending(session) => session.cancel.cancel(),
            SessionStateV2::Active(session) => session.cancel.cancel(),
        }
    }
}

#[cfg(test)]
mod receive_guard_tests {
    use super::*;
    use std::{num::NonZeroUsize, task::Poll};
    use tokio::sync::{Mutex, mpsc};

    fn state() -> Arc<V2State> {
        let (event_tx, _) = mpsc::channel(16);
        Arc::new(V2State {
            pin: None,
            verify_checksums: true,
            event_tx,
            session: Mutex::new(None),
            resumes: crate::http::server::receive_resume::Registry::default(),
            session_changed: tokio::sync::Notify::new(),
            stopped: CancellationToken::new(),
            pin_attempts: Mutex::new(lru::LruCache::new(NonZeroUsize::new(2).unwrap())),
        })
    }
    fn pending(id: &str) -> SessionStateV2 {
        SessionStateV2::Pending(PendingSessionV2 {
            session_id: id.into(),
            sender_ip: PeerIp::from_remote_addr(&"127.0.0.1:1234".parse().unwrap()),
            cancel: CancellationToken::new(),
        })
    }

    fn active() -> SessionStateV2 {
        SessionStateV2::Active(UploadSessionV2 {
            cancel: CancellationToken::new(),
            session_id: "old".into(),
            last_activity: tokio::time::Instant::now(),
            sender_ip: PeerIp::from_remote_addr(&"127.0.0.1:1234".parse().unwrap()),
            sender_cert: None,
            files: HashMap::from([(
                "file".into(),
                SessionFileV2 {
                    dto: FileDto {
                        id: "file".into(),
                        file_name: "file.bin".into(),
                        size: 4,
                        file_type: "application/octet-stream".into(),
                        sha256: None,
                        preview: None,
                        metadata: None,
                    },
                    token: "token".into(),
                    status: FileStatusV2::InProgress,
                    attempts: 1,
                    resumable: false,
                    durable: false,
                },
            )]),
        })
    }

    #[tokio::test]
    async fn stale_pending_guard_never_clears_a_replacement_pending_session() {
        for dropped in [false, true] {
            let state = state();
            let mut guard = PendingSessionGuard::new(state.clone(), "old".into());
            *state.session.lock().await = Some(pending("new"));
            if dropped {
                drop(guard);
                tokio::task::yield_now().await;
            } else {
                guard.clear().await;
            }
            let slot = state.session.lock().await;
            assert!(
                matches!(&*slot, Some(SessionStateV2::Pending(pending)) if pending.session_id == "new")
            );
        }
    }

    #[tokio::test]
    async fn aborted_pending_clear_keeps_drop_cleanup_armed_while_waiting_for_lock() {
        let state = state();
        *state.session.lock().await = Some(pending("old"));
        let held_lock = state.session.lock().await;
        let mut guard = PendingSessionGuard::new(state.clone(), "old".into());
        let mut clearing = Box::pin(async move {
            guard.clear().await;
        });
        assert!(matches!(
            futures_util::poll!(clearing.as_mut()),
            Poll::Pending
        ));
        drop(clearing);
        drop(held_lock);
        tokio::task::yield_now().await;
        assert!(
            state.session.lock().await.is_none(),
            "Interrupted cleanup must not leak the occupied slot"
        );
    }

    #[tokio::test]
    async fn aborted_upload_finish_keeps_drop_cleanup_armed_while_waiting_for_lock() {
        let state = state();
        *state.session.lock().await = Some(active());
        let held_lock = state.session.lock().await;
        let mut guard = UploadGuard::new(state.clone(), "old".into(), "file".into());
        let mut finishing = Box::pin(async move {
            guard.finish(SaveResult::Success).await;
        });
        assert!(matches!(
            futures_util::poll!(finishing.as_mut()),
            Poll::Pending
        ));
        drop(finishing);
        drop(held_lock);
        tokio::task::yield_now().await;
        assert!(
            state.session.lock().await.is_none(),
            "Dropped file finalization must not leak InProgress"
        );
    }
    #[tokio::test]
    async fn committed_terminal_event_survives_dropped_backpressured_request() {
        let mut state = state();
        let (event_tx, mut events) = mpsc::channel(1);
        Arc::get_mut(&mut state).unwrap().event_tx = event_tx.clone();
        event_tx
            .send(ServerEventV2::PrepareUploadAborted {
                session_id: "blocker".into(),
            })
            .await
            .unwrap();
        *state.session.lock().await = Some(active());
        let mut guard = UploadGuard::new(state.clone(), "old".into(), "file".into());
        let mut finishing = Box::pin(async move {
            guard.finish(SaveResult::Success).await;
        });
        assert!(matches!(
            futures_util::poll!(finishing.as_mut()),
            Poll::Pending
        ));
        assert!(
            state.session.lock().await.is_none(),
            "Terminal state was committed"
        );
        drop(finishing);
        assert!(matches!(
            events.recv().await,
            Some(ServerEventV2::PrepareUploadAborted { .. })
        ));
        let end = tokio::time::timeout(std::time::Duration::from_millis(200), events.recv()).await;
        assert!(
            matches!(end, Ok(Some(ServerEventV2::SessionEnd { session_id, reason: SessionEndReasonV2::Finished })) if session_id == "old"),
            "Committed SessionEnd must survive cancellation of its backpressured request"
        );
        tokio::task::yield_now().await;
        assert!(
            events.try_recv().is_err(),
            "Drop fallback must not duplicate terminal events"
        );
    }

    #[tokio::test]
    async fn committed_sender_cancel_survives_dropped_backpressured_response() {
        let mut state = state();
        let (event_tx, mut events) = mpsc::channel(1);
        Arc::get_mut(&mut state).unwrap().event_tx = event_tx.clone();
        event_tx
            .send(ServerEventV2::PrepareUploadAborted {
                session_id: "blocker".into(),
            })
            .await
            .unwrap();
        let mut notification = Box::pin(send_committed_session_end(
            &state,
            "cancelled".into(),
            SessionEndReasonV2::Cancelled,
        ));
        assert!(matches!(
            futures_util::poll!(notification.as_mut()),
            Poll::Pending
        ));
        drop(notification);
        events.recv().await.unwrap();
        let end = tokio::time::timeout(std::time::Duration::from_millis(200), events.recv()).await;
        assert!(
            matches!(end, Ok(Some(ServerEventV2::SessionEnd { session_id, reason: SessionEndReasonV2::Cancelled })) if session_id == "cancelled")
        );
        assert!(events.try_recv().is_err());
    }
    fn idle_state(capacity: usize) -> (Arc<V2State>, mpsc::Receiver<ServerEventV2>) {
        let mut state = state();
        let (tx, rx) = mpsc::channel(capacity);
        Arc::get_mut(&mut state).unwrap().event_tx = tx;
        (state, rx)
    }

    fn idle_session(id: &str) -> SessionStateV2 {
        let SessionStateV2::Active(mut session) = active() else {
            unreachable!()
        };
        session.session_id = id.into();
        session.files.get_mut("file").unwrap().status = FileStatusV2::Pending;
        SessionStateV2::Active(session)
    }

    async fn advance_idle(seconds: u64) {
        tokio::time::advance(std::time::Duration::from_secs(seconds)).await;
        for _ in 0..3 {
            tokio::task::yield_now().await;
        }
    }

    #[tokio::test(start_paused = true)]
    async fn idle_expiry_invalidates_lifetime_once_at_ten_minutes() {
        let (state, mut events) = idle_state(4);
        let session = idle_session("old");
        let SessionStateV2::Active(ref active) = session else {
            unreachable!()
        };
        let lifetime = active.cancel.clone();
        *state.session.lock().await = Some(session);
        let task = tokio::spawn(watch_active_idle(state.clone()));
        tokio::task::yield_now().await;
        advance_idle(599).await;
        assert!(state.session.lock().await.is_some());
        assert!(events.try_recv().is_err());
        advance_idle(1).await;
        assert!(state.session.lock().await.is_none());
        assert!(lifetime.is_cancelled());
        assert!(
            matches!(events.try_recv(), Ok(ServerEventV2::SessionEnd { session_id, reason: SessionEndReasonV2::Expired }) if session_id == "old")
        );
        advance_idle(3600).await;
        assert!(events.try_recv().is_err());
        stop_native_sessions(&state).await;
        task.await.unwrap();
    }

    #[tokio::test(start_paused = true)]
    async fn idle_watchdog_never_times_out_manual_approval() {
        let (state, mut events) = idle_state(4);
        let session = pending("approval");
        let SessionStateV2::Pending(ref pending) = session else {
            unreachable!()
        };
        let lifetime = pending.cancel.clone();
        *state.session.lock().await = Some(session);
        let task = tokio::spawn(watch_active_idle(state.clone()));
        tokio::task::yield_now().await;
        advance_idle(24 * 3600).await;
        assert!(state.session.lock().await.is_some());
        assert!(!lifetime.is_cancelled());
        assert!(events.try_recv().is_err());
        stop_native_sessions(&state).await;
        task.await.unwrap();
        assert!(lifetime.is_cancelled());
        assert!(state.session.lock().await.is_none());
        assert!(
            events.try_recv().is_err(),
            "Shutdown must not invent an expiry"
        );
    }

    #[tokio::test(start_paused = true)]
    async fn idle_deadline_is_suspended_by_live_upload_and_reset_after_checksum_retry() {
        let (state, mut events) = idle_state(4);
        *state.session.lock().await = Some(idle_session("old"));
        let task = tokio::spawn(watch_active_idle(state.clone()));
        tokio::task::yield_now().await;
        advance_idle(599).await;
        {
            let mut slot = state.session.lock().await;
            let Some(SessionStateV2::Active(session)) = slot.as_mut() else {
                panic!()
            };
            session.files.get_mut("file").unwrap().status = FileStatusV2::InProgress;
            session.last_activity = tokio::time::Instant::now();
            state.session_changed.notify_one();
        }
        advance_idle(3600).await;
        assert!(state.session.lock().await.is_some());
        assert!(events.try_recv().is_err());
        finalize_file(&state, "old", "file", SaveResult::HashMismatch).await;
        advance_idle(599).await;
        assert!(state.session.lock().await.is_some());
        assert!(events.try_recv().is_err());
        advance_idle(1).await;
        assert!(state.session.lock().await.is_none());
        assert!(matches!(
            events.try_recv(),
            Ok(ServerEventV2::SessionEnd {
                reason: SessionEndReasonV2::Expired,
                ..
            })
        ));
        stop_native_sessions(&state).await;
        task.await.unwrap();
    }

    #[tokio::test(start_paused = true)]
    async fn idle_deadline_resets_after_one_file_completes_in_a_larger_session() {
        let (state, mut events) = idle_state(4);
        let SessionStateV2::Active(mut session) = active() else {
            unreachable!()
        };
        let SessionStateV2::Active(mut pending) = idle_session("unused") else {
            unreachable!()
        };
        session
            .files
            .insert("next".into(), pending.files.remove("file").unwrap());
        *state.session.lock().await = Some(SessionStateV2::Active(session));
        let task = tokio::spawn(watch_active_idle(state.clone()));
        tokio::task::yield_now().await;
        advance_idle(800).await;
        finalize_file(&state, "old", "file", SaveResult::Success).await;
        advance_idle(599).await;
        assert!(state.session.lock().await.is_some());
        assert!(events.try_recv().is_err());
        advance_idle(1).await;
        assert!(state.session.lock().await.is_none());
        assert!(matches!(
            events.try_recv(),
            Ok(ServerEventV2::SessionEnd {
                reason: SessionEndReasonV2::Expired,
                ..
            })
        ));
        stop_native_sessions(&state).await;
        task.await.unwrap();
    }

    #[tokio::test(start_paused = true)]
    async fn stale_idle_deadline_cannot_expire_a_replacement_session() {
        let (state, mut events) = idle_state(4);
        *state.session.lock().await = Some(idle_session("old"));
        let task = tokio::spawn(watch_active_idle(state.clone()));
        tokio::task::yield_now().await;
        advance_idle(599).await;
        *state.session.lock().await = Some(idle_session("replacement"));
        // Deliberately do not notify: even an already scheduled old wake must
        // inspect the replacement's current timestamp rather than its old ID.
        advance_idle(1).await;
        assert!(
            matches!(state.session.lock().await.as_ref(), Some(SessionStateV2::Active(session)) if session.session_id == "replacement")
        );
        assert!(events.try_recv().is_err());
        advance_idle(599).await;
        assert!(state.session.lock().await.is_none());
        assert!(
            matches!(events.try_recv(), Ok(ServerEventV2::SessionEnd { session_id, reason: SessionEndReasonV2::Expired }) if session_id == "replacement")
        );
        stop_native_sessions(&state).await;
        task.await.unwrap();
    }

    #[tokio::test(start_paused = true)]
    async fn listener_stop_clears_live_session_and_joins_idle_watchdog() {
        let (state, mut events) = idle_state(4);
        let session = active();
        let SessionStateV2::Active(ref active) = session else {
            unreachable!()
        };
        let lifetime = active.cancel.clone();
        *state.session.lock().await = Some(session);
        let task = tokio::spawn(watch_active_idle(state.clone()));
        tokio::task::yield_now().await;
        stop_native_sessions(&state).await;
        task.await.unwrap();
        assert!(lifetime.is_cancelled());
        assert!(state.session.lock().await.is_none());
        advance_idle(3600).await;
        assert!(events.try_recv().is_err());
        assert_eq!(
            Arc::strong_count(&state),
            1,
            "Watchdog must release listener ownership"
        );
    }

    #[tokio::test(start_paused = true)]
    async fn listener_stop_interrupts_expiry_delivery_backpressure_without_task_leak() {
        let (state, mut events) = idle_state(1);
        state
            .event_tx
            .send(ServerEventV2::PrepareUploadAborted {
                session_id: "blocker".into(),
            })
            .await
            .unwrap();
        *state.session.lock().await = Some(idle_session("old"));
        let task = tokio::spawn(watch_active_idle(state.clone()));
        tokio::task::yield_now().await;
        advance_idle(600).await;
        assert!(state.session.lock().await.is_none());
        assert!(!task.is_finished(), "Terminal delivery is backpressured");
        stop_native_sessions(&state).await;
        task.await.unwrap();
        assert_eq!(Arc::strong_count(&state), 1);
        assert_eq!(
            state.event_tx.strong_count(),
            1,
            "Delivery task released its sender"
        );
        assert!(matches!(
            events.try_recv(),
            Ok(ServerEventV2::PrepareUploadAborted { .. })
        ));
        assert!(
            events.try_recv().is_err(),
            "Stopped listener must not emit a delayed expiry"
        );
    }

    #[tokio::test(start_paused = true)]
    async fn expired_event_is_delivered_once_after_channel_recovers() {
        let (state, mut events) = idle_state(1);
        state
            .event_tx
            .send(ServerEventV2::PrepareUploadAborted {
                session_id: "blocker".into(),
            })
            .await
            .unwrap();
        *state.session.lock().await = Some(idle_session("old"));
        let task = tokio::spawn(watch_active_idle(state.clone()));
        tokio::task::yield_now().await;
        advance_idle(600).await;
        assert!(state.session.lock().await.is_none());
        events.try_recv().unwrap();
        for _ in 0..3 {
            tokio::task::yield_now().await;
        }
        assert!(
            matches!(events.try_recv(), Ok(ServerEventV2::SessionEnd { session_id, reason: SessionEndReasonV2::Expired }) if session_id == "old")
        );
        advance_idle(3600).await;
        assert!(events.try_recv().is_err());
        stop_native_sessions(&state).await;
        task.await.unwrap();
    }
}
