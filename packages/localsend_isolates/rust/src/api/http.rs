use crate::api::cancel::RsCancellationToken;
use crate::api::stream;
use crate::frb_generated::StreamSink;
use flutter_rust_bridge::frb;
pub use localsend::http::client::{ClientError, LsHttpClientVersion};
pub use localsend::http::dto::{
    PrepareUploadRequestDto, PrepareUploadResponseDto, PrepareUploadResult, RegisterDto,
    RegisterResponseDto,
};
use localsend::model::discovery::ProtocolType;
use localsend::util::error::ErrorChain;

pub struct RsHttpClient {
    inner: localsend::http::client::LsHttpClient,
    source_end_acks: std::sync::Arc<
        std::sync::Mutex<std::collections::HashMap<String, tokio::sync::oneshot::Sender<bool>>>,
    >,
}

/// Creates an HTTP client.
/// Optional source address and exact interface name must be supplied together.
/// Supported desktop targets additionally constrain the interface. Android may
/// select a trusted live Network handle; no mode promises VPN policy bypass.
///
/// `expected_fingerprint` pins the peer to the certificate with that SHA-256
/// fingerprint (uppercase hex). It is enforced during the TLS handshake, so a
/// peer that does not present the expected certificate never receives the
/// request. Pass `None` only for discovery, where the peer is not known yet.
#[frb(sync)]
pub fn create_client(
    private_key: String,
    cert: String,
    version: LsHttpClientVersion,
    expected_fingerprint: Option<String>,
    timeout_ms: Option<u32>,
    local_address: Option<String>,
    interface_name: Option<String>,
    android_network_handle: Option<String>,
    android_network_epoch: Option<String>,
) -> Result<RsHttpClient, RsHttpClientError> {
    let inner = localsend::http::client::LsHttpClient::new_with_network_route(
        &private_key,
        &cert,
        version,
        expected_fingerprint,
        timeout_ms.map(|ms| std::time::Duration::from_millis(ms as u64)),
        local_address,
        interface_name,
        android_network_handle,
        android_network_epoch,
    )
    .map_err(RsHttpClientError::from)?;

    Ok(RsHttpClient {
        inner,
        source_end_acks: Default::default(),
    })
}

/// Synchronize trusted ConnectivityManager identities, never process-wide routing.
#[frb(sync)]
pub fn configure_android_network_routes(snapshot: Option<String>) -> Result<(), RsHttpClientError> {
    localsend::http::client::route::configure_android_network_routes(snapshot.as_deref())
        .map_err(RsHttpClientError::from)
}

impl RsHttpClient {
    pub async fn register(
        &self,
        protocol: ProtocolType,
        ip: &str,
        port: u16,
        payload: RegisterDto,
    ) -> Result<ResultWithPublicKeyRegisterResponseDto, RsHttpClientError> {
        let response = self
            .inner
            .register(protocol, ip, port, payload)
            .await
            .map_err(RsHttpClientError::from)?;

        Ok(ResultWithPublicKeyRegisterResponseDto {
            public_key: response.public_key,
            body: response.body,
        })
    }

    pub async fn prepare_upload(
        &self,
        protocol: ProtocolType,
        ip: &str,
        port: u16,
        payload: PrepareUploadRequestDto,
        public_key: Option<String>,
        pin: Option<String>,
        cancel_token: &RsCancellationToken,
    ) -> Result<PrepareUploadResult, RsHttpClientError> {
        let response = self
            .inner
            .prepare_upload(
                protocol,
                ip,
                port,
                public_key,
                payload,
                pin.as_deref(),
                cancel_token.inner.clone(),
            )
            .await
            .map_err(RsHttpClientError::from)?;

        Ok(response)
    }

    /// Uploads a single file, emitting [RsUploadEvent]s on [sink].
    ///
    /// Failures are emitted as [RsUploadEvent::Failed] instead of being
    /// returned: flutter_rust_bridge discards the returned `Result` of
    /// functions taking a [StreamSink], so a returned error would become an
    /// uncaught async error killing the calling isolate.
    pub async fn upload(
        &self,
        sink: StreamSink<RsUploadEvent>,
        protocol: ProtocolType,
        ip: &str,
        port: u16,
        public_key: Option<String>,
        session_id: &str,
        file_id: &str,
        token: &str,
        binary: Option<stream::Dart2RustStreamReceiver>,
        path: Option<String>,
        file_descriptor: Option<i32>,
        content_length: u64,
        resume_key: Option<String>,
        enable_source_end: Option<bool>,
        cancel_token: &RsCancellationToken,
    ) {
        let result = async {
            let content = resolve_file_content(binary, path, file_descriptor)?;
            let last_emit = std::sync::Mutex::new(None::<std::time::Instant>);
            let progress_sink = sink.clone();
            let progress = move |sent| {
                let now = std::time::Instant::now();
                let is_final = sent >= content_length;
                let mut last_emit = last_emit.lock().unwrap_or_else(|e| e.into_inner());
                if !is_final {
                    if let Some(last) = *last_emit {
                        if now.duration_since(last) < std::time::Duration::from_millis(20) {
                            return;
                        }
                    }
                }
                *last_emit = Some(now);
                drop(last_emit);
                let progress = if content_length == 0 {
                    1.0
                } else {
                    (sent as f64 / content_length as f64).min(1.0)
                };
                let _ = progress_sink.add(RsUploadEvent::Progress { progress });
            };

            let verification_sink = sink.clone();
            let recovery_sink = sink.clone();
            let source_end = if enable_source_end.unwrap_or(false) {
                let acknowledgements = self.source_end_acks.clone();
                let grant_sink = sink.clone();
                Some(std::sync::Arc::new(move |event| match event {
                    localsend::http::source_end::SourceEndEvent::Unavailable => {
                        let _ = grant_sink.add(RsUploadEvent::SourceEndUnavailable);
                    }
                    localsend::http::source_end::SourceEndEvent::Grant { grant, persisted } => {
                        let ack_id = uuid::Uuid::new_v4().to_string();
                        let mut pending =
                            acknowledgements.lock().unwrap_or_else(|e| e.into_inner());
                        pending.retain(|_, tx| !tx.is_closed());
                        if pending.len() >= 8 {
                            let _ = persisted.send(false);
                            return;
                        }
                        pending.insert(ack_id.clone(), persisted);
                        drop(pending);
                        if grant_sink
                            .add(RsUploadEvent::SourceEndGrant {
                                ack_id: ack_id.clone(),
                                grant: RsSourceEndGrant::from(grant),
                            })
                            .is_err()
                        {
                            if let Some(tx) = acknowledgements
                                .lock()
                                .unwrap_or_else(|e| e.into_inner())
                                .remove(&ack_id)
                            {
                                let _ = tx.send(false);
                            }
                        }
                    }
                })
                    as localsend::http::source_end::SourceEndCallback)
            } else {
                None
            };
            self.inner
                .upload_with_source_end(
                    protocol,
                    ip,
                    port,
                    public_key,
                    session_id,
                    file_id,
                    token,
                    content,
                    resume_key,
                    progress,
                    move |verified_bytes, total_bytes| {
                        let _ = verification_sink.add(RsUploadEvent::Verification {
                            verified_bytes,
                            total_bytes,
                        });
                    },
                    move |phase| {
                        let _ = recovery_sink.add(RsUploadEvent::Recovery {
                            waiting: phase.waiting,
                            attempt: phase.attempt,
                            retry_after_ms: phase.retry_after_ms,
                        });
                    },
                    source_end,
                    cancel_token.inner.clone(),
                )
                .await
                .map_err(RsHttpClientError::from)?;

            Ok(())
        }
        .await;

        if let Err(error) = result {
            let _ = sink.add(RsUploadEvent::Failed { error });
        }
    }

    #[frb(sync)]
    pub fn ack_source_end_grant(&self, ack_id: String, persisted: bool) -> bool {
        self.source_end_acks
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .remove(&ack_id)
            .is_some_and(|tx| tx.send(persisted).is_ok())
    }

    pub async fn end_source(
        &self,
        protocol: ProtocolType,
        ip: &str,
        port: u16,
        public_key: Option<String>,
        grant: RsSourceEndGrant,
        request_id: String,
        cancel_token: &RsCancellationToken,
    ) -> Result<RsSourceEndResult, RsHttpClientError> {
        self.inner
            .end_source(
                protocol,
                ip,
                port,
                public_key,
                grant.into(),
                request_id,
                cancel_token.inner.clone(),
            )
            .await
            .map(RsSourceEndResult::from)
            .map_err(RsHttpClientError::from)
    }

    pub async fn cancel(
        &self,
        protocol: ProtocolType,
        ip: &str,
        port: u16,
        session_id: &str,
    ) -> Result<(), RsHttpClientError> {
        self.inner
            .cancel(protocol, ip, port, session_id)
            .await
            .map_err(RsHttpClientError::from)?;

        Ok(())
    }
}

fn resolve_file_content(
    binary: Option<stream::Dart2RustStreamReceiver>,
    path: Option<String>,
    file_descriptor: Option<i32>,
) -> Result<localsend::model::transfer::FileContent, RsHttpClientError> {
    match (binary, path, file_descriptor) {
        (Some(binary), None, None) => Ok(localsend::model::transfer::FileContent::Stream(
            binary.receiver,
        )),
        (None, Some(path), None) => Ok(localsend::model::transfer::FileContent::Path(path.into())),
        (None, None, Some(file_descriptor)) => {
            #[cfg(target_os = "android")]
            {
                Ok(localsend::model::transfer::FileContent::Fd(file_descriptor))
            }
            #[cfg(not(target_os = "android"))]
            {
                let _ = file_descriptor;
                Err(RsHttpClientError::Other(
                    "File descriptors are only supported on Android".into(),
                ))
            }
        }
        _ => Err(RsHttpClientError::Other(
            "Exactly one upload content source must be provided".into(),
        )),
    }
}

/// An event emitted while a file is being uploaded by [RsHttpClient::upload].
#[derive(Clone)]
pub enum RsUploadEvent {
    SourceEndGrant {
        ack_id: String,
        grant: RsSourceEndGrant,
    },
    SourceEndUnavailable,
    /// The upload progress as a fraction (0.0 to 1.0). Throttled.
    Progress {
        progress: f64,
    },
    /// Source/cache validation only; never transfer throughput.
    Verification {
        verified_bytes: u64,
        total_bytes: u64,
    },

    /// The upload failed. Always the last event of the stream.
    Failed {
        error: RsHttpClientError,
    },
    /// A real bounded retry delay, not transfer or verification progress.
    Recovery {
        waiting: bool,
        attempt: u8,
        retry_after_ms: u32,
    },
}

#[derive(Clone)]
pub enum RsHttpClientError {
    StatusCode {
        status: u16,
        message: Option<String>,
    },
    ResumeInterrupted {
        retained_confirmed: bool,
    },
    Reqwest(String),
    Json(String),
    Io(String),
    Other(String),
    Recovery {
        kind: RsRecoveryFailureKind,
        retention: RsRecoveryRetention,
        status: Option<u16>,
    },
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RsRecoveryFailureKind {
    Retryable,
    AuthorizationRequired,
    SourceChanged,
    InvalidResponse,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RsRecoveryRetention {
    NotRetained,
    Unknown,
    Confirmed,
}

impl From<ClientError> for RsHttpClientError {
    fn from(e: ClientError) -> Self {
        match e {
            ClientError::StatusCode(e) => RsHttpClientError::StatusCode {
                status: e.status,
                message: e.message,
            },
            ClientError::Reqwest(e) => RsHttpClientError::Reqwest(ErrorChain(&e).to_string()),
            ClientError::Json(e) => RsHttpClientError::Json(e.to_string()),
            ClientError::Io(e) => RsHttpClientError::Io(e.to_string()),
            ClientError::Other(e) => RsHttpClientError::Other(e.to_string()),
            ClientError::ResumeInterrupted { retained_confirmed } => {
                RsHttpClientError::ResumeInterrupted { retained_confirmed }
            }
            ClientError::Recovery {
                kind,
                retention,
                status,
            } => RsHttpClientError::Recovery {
                kind: match kind {
                    localsend::http::client::RecoveryFailureKind::Retryable => {
                        RsRecoveryFailureKind::Retryable
                    }
                    localsend::http::client::RecoveryFailureKind::AuthorizationRequired => {
                        RsRecoveryFailureKind::AuthorizationRequired
                    }
                    localsend::http::client::RecoveryFailureKind::SourceChanged => {
                        RsRecoveryFailureKind::SourceChanged
                    }
                    localsend::http::client::RecoveryFailureKind::InvalidResponse => {
                        RsRecoveryFailureKind::InvalidResponse
                    }
                },
                retention: match retention {
                    localsend::http::client::RecoveryRetention::NotRetained => {
                        RsRecoveryRetention::NotRetained
                    }
                    localsend::http::client::RecoveryRetention::Unknown => {
                        RsRecoveryRetention::Unknown
                    }
                    localsend::http::client::RecoveryRetention::Confirmed => {
                        RsRecoveryRetention::Confirmed
                    }
                },
                status,
            },
            ClientError::Cancelled => RsHttpClientError::Other("Upload cancelled".to_string()),
        }
    }
}

#[frb(mirror(LsHttpClientVersion))]
pub enum _LsHttpClientVersion {
    V2,
    V3,
}

#[frb(mirror(PrepareUploadResult))]
pub struct _PrepareUploadResult {
    pub status_code: u16,
    pub response: Option<PrepareUploadResponseDto>,
}

pub struct ResultWithPublicKeyRegisterResponseDto {
    pub public_key: Option<String>,
    pub body: RegisterResponseDto,
}

/// Private host-only source-end control storage. Never expose journal contents
/// or local paths through error messages or public integration APIs.
pub async fn read_source_end_journal(path: String) -> anyhow::Result<Option<String>> {
    tokio::task::spawn_blocking(move || localsend::source_end_journal::read(&path))
        .await
        .map_err(|_| anyhow::anyhow!("source-end journal read worker failed"))?
        .map_err(|_| anyhow::anyhow!("source-end journal read failed"))
}

pub async fn write_source_end_journal(path: String, data: String) -> anyhow::Result<()> {
    tokio::task::spawn_blocking(move || localsend::source_end_journal::write(&path, &data))
        .await
        .map_err(|_| anyhow::anyhow!("source-end journal write worker failed"))?
        .map_err(|_| anyhow::anyhow!("source-end journal write failed"))
}

pub async fn prepare_source_end_journal(path: String) -> anyhow::Result<()> {
    tokio::task::spawn_blocking(move || localsend::source_end_journal::prepare(&path))
        .await
        .map_err(|_| anyhow::anyhow!("source-end journal prepare worker failed"))?
        .map_err(|_| anyhow::anyhow!("source-end journal prepare failed"))
}

// Secrets are deliberately not Debug/Display. Do not include this DTO in logs.
#[derive(Clone)]
pub struct RsSourceEndGrant {
    pub version: u32,
    pub grant_id: String,
    pub round: String,
    pub token: String,
    pub expires_at_unix_ms: u64,
}
impl From<localsend::http::source_end::SourceEndGrant> for RsSourceEndGrant {
    fn from(v: localsend::http::source_end::SourceEndGrant) -> Self {
        Self {
            version: v.version,
            grant_id: v.grant_id,
            round: v.round,
            token: v.token,
            expires_at_unix_ms: v.expires_at_unix_ms,
        }
    }
}
impl From<RsSourceEndGrant> for localsend::http::source_end::SourceEndGrant {
    fn from(v: RsSourceEndGrant) -> Self {
        Self {
            version: v.version,
            grant_id: v.grant_id,
            round: v.round,
            token: v.token,
            expires_at_unix_ms: v.expires_at_unix_ms,
        }
    }
}
pub enum RsSourceEndOutcome {
    Cleared,
    PublishedPreserved,
    Active,
    PublicationPending,
    RetainedUnknown,
    UnknownOrExpired,
    Superseded,
    AuthorizationRequired,
}
pub struct RsSourceEndResult {
    pub outcome: RsSourceEndOutcome,
    pub receipt_id: Option<String>,
    pub removed_files: u32,
    pub unlinked_bytes: u64,
}
impl From<localsend::http::source_end::SourceEndResult> for RsSourceEndResult {
    fn from(v: localsend::http::source_end::SourceEndResult) -> Self {
        use localsend::http::source_end::SourceEndOutcome as O;
        Self {
            outcome: match v.outcome {
                O::Cleared => RsSourceEndOutcome::Cleared,
                O::PublishedPreserved => RsSourceEndOutcome::PublishedPreserved,
                O::Active => RsSourceEndOutcome::Active,
                O::PublicationPending => RsSourceEndOutcome::PublicationPending,
                O::RetainedUnknown => RsSourceEndOutcome::RetainedUnknown,
                O::UnknownOrExpired => RsSourceEndOutcome::UnknownOrExpired,
                O::Superseded => RsSourceEndOutcome::Superseded,
                O::AuthorizationRequired => RsSourceEndOutcome::AuthorizationRequired,
            },
            receipt_id: v.receipt_id,
            removed_files: v.removed_files,
            unlinked_bytes: v.unlinked_bytes,
        }
    }
}

/// Host-owned process lease; never reconstruct a journal from a path per write.
#[frb(opaque)]
pub struct RsSourceEndJournal {
    inner: std::sync::Arc<localsend::source_end_journal::Lease>,
}

pub async fn open_source_end_journal(path: String) -> anyhow::Result<RsSourceEndJournal> {
    let lease = tokio::task::spawn_blocking(move || localsend::source_end_journal::open(&path))
        .await
        .map_err(|_| anyhow::anyhow!("source-end journal open worker failed"))?
        .map_err(|error| anyhow::anyhow!("source-end journal open failed: {error}"))?;
    Ok(RsSourceEndJournal {
        inner: std::sync::Arc::new(lease),
    })
}
impl RsSourceEndJournal {
    pub async fn read(&self) -> anyhow::Result<Option<String>> {
        let inner = self.inner.clone();
        tokio::task::spawn_blocking(move || inner.read())
            .await
            .map_err(|_| anyhow::anyhow!("source-end journal read worker failed"))?
            .map_err(|_| anyhow::anyhow!("source-end journal read failed"))
    }
    pub async fn write(&self, data: String) -> anyhow::Result<()> {
        let inner = self.inner.clone();
        tokio::task::spawn_blocking(move || inner.write(&data))
            .await
            .map_err(|_| anyhow::anyhow!("source-end journal write worker failed"))?
            .map_err(|_| anyhow::anyhow!("source-end journal write failed"))
    }
    pub async fn close(&self) -> anyhow::Result<()> {
        let inner = self.inner.clone();
        tokio::task::spawn_blocking(move || inner.close())
            .await
            .map_err(|_| anyhow::anyhow!("source-end journal close worker failed"))?
            .map_err(|_| anyhow::anyhow!("source-end journal close failed"))
    }
}

#[cfg(test)]
mod source_end_journal_tests {
    use super::open_source_end_journal;

    #[tokio::test]
    async fn journal_open_preserves_redacted_os_diagnostic() {
        let result = open_source_end_journal("sensitive-path-and-token".into()).await;
        let error = result.err().expect("Invalid path must fail").to_string();
        assert_eq!(
            error,
            "source-end journal open failed: source_end_journal_unavailable(kind=Other, errno=none)"
        );
        assert!(!error.contains("sensitive-path"));
        assert!(!error.contains("token"));
    }
}
