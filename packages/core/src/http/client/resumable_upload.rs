//! Optional, per-file recovery after the unchanged v2 approval handshake.
//! Unknown peers and unsupported targets keep the original whole-file upload.
use super::{
    ClientError, RecoveryFailureKind, RecoveryPhase, RecoveryRetention,
    url::{ApiVersion, TargetUrl},
    v2::LsHttpClientV2,
};
use crate::model::{discovery::ProtocolType, transfer::FileContent};
use serde::Deserialize;
use sha2::{Digest, Sha256};
use std::{
    fs::File,
    io::{self, Read, Seek, SeekFrom},
    time::{Duration, SystemTime},
};
use tokio_util::sync::CancellationToken;

const BLOCK: usize = 1024 * 1024;
const REPLY_LIMIT: usize = 8192;
const PREFIX: &str = "/api/legnasend/v1/receive-resume/";

pub(super) struct Target<'a> {
    pub protocol: ProtocolType,
    pub ip: &'a str,
    pub port: u16,
    pub public_key: Option<String>,
    pub session: &'a str,
    pub file: &'a str,
    pub token: &'a str,
    pub resume_key: Option<String>,
}
impl Target<'_> {
    fn url(&self, operation: &str, resume: Option<&str>, offset: Option<u64>) -> String {
        let base = TargetUrl {
            version: ApiVersion::V2,
            protocol: self.protocol.as_str(),
            host: self.ip.into(),
            port: self.port,
            path: "/info",
            params: &[],
        }
        .to_string();
        let mut url = reqwest::Url::parse(&base).expect("validated native peer URL");
        url.set_path(&format!("{PREFIX}{operation}"));
        let mut q = url.query_pairs_mut();
        q.append_pair("sessionId", self.session)
            .append_pair("fileId", self.file)
            .append_pair("token", self.token);
        if let Some(id) = resume {
            q.append_pair("resumeId", id);
        }
        if let Some(offset) = offset {
            q.append_pair("offset", &offset.to_string());
        }
        drop(q);
        url.to_string()
    }
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Capability {
    version: u32,
    supported: bool,
    block_size: usize,
    #[serde(default)]
    durable: Option<DurableCapability>,
}
#[derive(Deserialize)]
struct DurableCapability {
    version: u32,
    #[serde(default, rename = "sourceEnd")]
    source_end: Option<SourceEndCapability>,
}
#[derive(Deserialize)]
struct SourceEndCapability {
    version: u32,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Receipt {
    version: u32,
    resume_id: String,
    block_size: usize,
    offset: u64,
    size: u64,
    sha256: String,
    state: String,
    #[serde(default)]
    verified_bytes: Option<u64>,
    #[serde(default)]
    source_end: Option<crate::http::source_end::SourceEndGrant>,
}
impl Receipt {
    fn validate(&self, source: &Source, resume: Option<&str>) -> Result<(), ClientError> {
        if self.version != 1
            || self.block_size != BLOCK
            || self.size != source.size
            || self.sha256.to_ascii_lowercase() != source.sha256
            || uuid::Uuid::parse_str(&self.resume_id).is_err()
            || resume.is_some_and(|id| id != self.resume_id)
            || self.offset > self.size
            || (self.offset != self.size && self.offset % BLOCK as u64 != 0)
            || !["ready", "receiving", "complete", "verifying", "suspended"]
                .contains(&self.state.as_str())
            || (self.state == "complete" && self.offset != self.size)
            || (self.state == "verifying" && self.offset != 0)
            || self.verified_bytes.is_some_and(|n| n > self.size)
        {
            return Err(invalid("Invalid resumable upload receipt"));
        }
        Ok(())
    }
}
struct Source {
    file: File,
    size: u64,
    modified: Option<SystemTime>,
    sha256: String,
}
fn invalid(message: &str) -> ClientError {
    let _ = message;
    ClientError::Recovery {
        kind: RecoveryFailureKind::InvalidResponse,
        retention: RecoveryRetention::NotRetained,
        status: None,
    }
}
fn source_changed() -> ClientError {
    ClientError::Recovery {
        kind: RecoveryFailureKind::SourceChanged,
        retention: RecoveryRetention::NotRetained,
        status: None,
    }
}
fn classify(error: ClientError, durable: bool) -> ClientError {
    let retention = if durable {
        RecoveryRetention::Unknown
    } else {
        RecoveryRetention::NotRetained
    };
    match error {
        ClientError::StatusCode(code) => ClientError::Recovery {
            kind: if [401, 403].contains(&code.status) {
                RecoveryFailureKind::AuthorizationRequired
            } else {
                RecoveryFailureKind::Retryable
            },
            retention,
            status: Some(code.status),
        },
        ClientError::Reqwest(_) => ClientError::Recovery {
            kind: RecoveryFailureKind::Retryable,
            retention,
            status: None,
        },
        ClientError::Json(_) => ClientError::Recovery {
            kind: RecoveryFailureKind::InvalidResponse,
            retention: RecoveryRetention::NotRetained,
            status: None,
        },
        other => other,
    }
}
fn cancelled(cancel: &CancellationToken) -> Result<(), ClientError> {
    if cancel.is_cancelled() {
        Err(ClientError::Cancelled)
    } else {
        Ok(())
    }
}
fn check_file(file: &File, size: u64, modified: Option<SystemTime>) -> Result<(), ClientError> {
    let metadata = file.metadata()?;
    if !metadata.is_file() || metadata.len() != size || metadata.modified().ok() != modified {
        return Err(source_changed());
    }
    Ok(())
}
async fn source(content: FileContent) -> Result<Result<Source, FileContent>, ClientError> {
    if matches!(content, FileContent::Stream(_)) {
        return Ok(Err(content));
    }
    tokio::task::spawn_blocking(move || -> Result<_, ClientError> {
        let mut file = match content {
            FileContent::Path(path) => File::open(path)?,
            FileContent::OpenedFile(file) => file,
            #[cfg(target_os = "android")]
            FileContent::Fd(fd) => {
                use std::os::fd::FromRawFd;
                unsafe { File::from_raw_fd(fd) }
            }
            FileContent::Stream(_) => unreachable!(),
        };
        let metadata = file.metadata()?;
        if !metadata.is_file() || metadata.len() < BLOCK as u64 {
            return Ok(Err(FileContent::OpenedFile(file)));
        }
        // Never turn a partially consumed application descriptor into a different source.
        if file.stream_position().ok() != Some(0) {
            return Ok(Err(FileContent::OpenedFile(file)));
        }
        Ok(Ok(Source {
            file,
            size: metadata.len(),
            modified: metadata.modified().ok(),
            sha256: String::new(),
        }))
    })
    .await
    .map_err(io::Error::other)?
}
async fn hash_source(mut source: Source, cancel: CancellationToken) -> Result<Source, ClientError> {
    tokio::task::spawn_blocking(move || {
        cancelled(&cancel)?;
        check_file(&source.file, source.size, source.modified)?;
        let mut hash = Sha256::new();
        let mut buffer = [0u8; 64 * 1024];
        let mut total = 0u64;
        loop {
            cancelled(&cancel)?;
            let n = source.file.read(&mut buffer)?;
            if n == 0 {
                break;
            }
            total += n as u64;
            if total > source.size {
                return Err(source_changed());
            }
            hash.update(&buffer[..n]);
        }
        if total != source.size {
            return Err(source_changed());
        }
        check_file(&source.file, source.size, source.modified)?;
        source.file.seek(SeekFrom::Start(0))?;
        source.sha256 = hash.finalize().iter().map(|b| format!("{b:02x}")).collect();
        Ok(source)
    })
    .await
    .map_err(io::Error::other)?
}
async fn read_block(
    mut source: Source,
    offset: u64,
    cancel: CancellationToken,
) -> Result<(Source, Vec<u8>), ClientError> {
    tokio::task::spawn_blocking(move || {
        cancelled(&cancel)?;
        check_file(&source.file, source.size, source.modified)?;
        source.file.seek(SeekFrom::Start(offset))?;
        let mut data = vec![0; ((source.size - offset).min(BLOCK as u64)) as usize];
        source.file.read_exact(&mut data).map_err(|e| {
            if e.kind() == io::ErrorKind::UnexpectedEof {
                source_changed()
            } else {
                e.into()
            }
        })?;
        check_file(&source.file, source.size, source.modified)?;
        cancelled(&cancel)?;
        Ok((source, data))
    })
    .await
    .map_err(io::Error::other)?
}
async fn response(
    client: &LsHttpClientV2,
    target: &Target<'_>,
    request: reqwest::RequestBuilder,
    cancel: &CancellationToken,
) -> Result<reqwest::Response, ClientError> {
    client.validate_route()?;
    cancelled(cancel)?;
    let res = tokio::select! {biased;_=cancel.cancelled()=>return Err(ClientError::Cancelled),res=request.timeout(Duration::from_secs(30)).send()=>res?};
    if target.protocol == ProtocolType::Https {
        super::verify_cert_from_res(&res, target.public_key.clone())?;
    }
    Ok(res)
}
async fn json<T: serde::de::DeserializeOwned>(
    mut response: reqwest::Response,
    cancel: &CancellationToken,
) -> Result<T, ClientError> {
    let status = response.status();
    if !status.is_success() {
        // Never surface arbitrary peer HTML or an unbounded error payload.
        return Err(ClientError::StatusCode(crate::http::StatusCodeError {
            status: status.as_u16(),
            message: Some("Resumable transfer request failed".into()),
        }));
    }
    let mut bytes = Vec::new();
    while let Some(chunk) = tokio::select! {biased;_=cancel.cancelled()=>return Err(ClientError::Cancelled),chunk=response.chunk()=>chunk?}
    {
        if bytes.len() + chunk.len() > REPLY_LIMIT {
            return Err(invalid("Resumable reply exceeds budget"));
        }
        bytes.extend_from_slice(&chunk);
    }
    Ok(serde_json::from_slice(&bytes)?)
}
fn busy(error: &ClientError) -> bool {
    matches!(error, ClientError::StatusCode(code) if code.status == 409)
}
fn retryable(error: &ClientError) -> bool {
    matches!(error,ClientError::Reqwest(e) if e.is_connect()||e.is_timeout()||e.is_body()||e.is_request())
}
async fn backoff(
    attempt: &mut u8,
    cancel: &CancellationToken,
    durable: bool,
    recovery: &impl Fn(RecoveryPhase),
) -> Result<(), ClientError> {
    if *attempt >= 3 {
        if durable {
            return Err(ClientError::ResumeInterrupted {
                retained_confirmed: false,
            });
        }
        return Err(ClientError::Recovery {
            kind: RecoveryFailureKind::Retryable,
            retention: RecoveryRetention::NotRetained,
            status: None,
        });
    }
    let delay = Duration::from_secs(1 << *attempt);
    *attempt += 1;
    recovery(RecoveryPhase {
        waiting: true,
        attempt: *attempt,
        retry_after_ms: delay.as_millis() as u32,
    });
    let result = tokio::select! {biased;_=cancel.cancelled()=>Err(ClientError::Cancelled),_=tokio::time::sleep(delay)=>Ok(())};
    recovery(RecoveryPhase {
        waiting: false,
        attempt: *attempt,
        retry_after_ms: 0,
    });
    result
}
async fn status(
    client: &LsHttpClientV2,
    target: &Target<'_>,
    resume: &str,
    cancel: &CancellationToken,
) -> Result<Receipt, ClientError> {
    json(
        response(
            client,
            target,
            client.client.get(target.url("status", Some(resume), None)),
            cancel,
        )
        .await?,
        cancel,
    )
    .await
}
/// All HTTP requests share the already-pinned, task-bound original v2 client.
pub(super) async fn upload<
    P: Fn(u64) + Send + 'static,
    V: Fn(u64, u64) + Send + 'static,
    R: Fn(RecoveryPhase) + Send + 'static,
>(
    client: &LsHttpClientV2,
    target: Target<'_>,
    content: FileContent,
    progress: P,
    verification: V,
    recovery: R,
    source_end: Option<crate::http::source_end::SourceEndCallback>,
    cancel: CancellationToken,
) -> Result<(), ClientError> {
    let candidate = source(content).await?;
    let mut src = match candidate {
        Ok(src) => src,
        Err(content) => {
            if let Some(callback) = &source_end {
                callback(crate::http::source_end::SourceEndEvent::Unavailable);
            }
            return legacy(client, target, content, progress, cancel)
                .await
                .map_err(|e| classify(e, false));
        }
    };
    // Probe before hashing: legacy peers and ordinary small-file throughput keep
    // their old data path. A timeout/auth/storage error is not 'unsupported'.
    let cap = response(
        client,
        &target,
        client.client.get(target.url("capabilities", None, None)),
        &cancel,
    )
    .await
    .map_err(|e| classify(e, false))?;
    if [404, 405, 501].contains(&cap.status().as_u16()) {
        drop(cap);
        if let Some(callback) = &source_end {
            callback(crate::http::source_end::SourceEndEvent::Unavailable);
        }
        return legacy(
            client,
            target,
            FileContent::OpenedFile(src.file),
            progress,
            cancel,
        )
        .await
        .map_err(|e| classify(e, false));
    }
    let cap: Capability = json(cap, &cancel).await.map_err(|e| classify(e, false))?;
    if cap.version != 1 || !cap.supported || cap.block_size != BLOCK {
        return Err(invalid("Unsupported resumable capability contract"));
    }
    let durable =
        cap.durable.as_ref().is_some_and(|d| d.version == 1) && target.resume_key.is_some();
    let source_end = match source_end {
        Some(callback)
            if durable
                && cap
                    .durable
                    .as_ref()
                    .and_then(|d| d.source_end.as_ref())
                    .is_some_and(|v| v.version == 1) =>
        {
            Some(callback)
        }
        Some(callback) => {
            callback(crate::http::source_end::SourceEndEvent::Unavailable);
            None
        }
        None => None,
    };
    if let Some(key) = &target.resume_key {
        if uuid::Uuid::parse_str(key)
            .ok()
            .is_none_or(|id| id.to_string() != *key)
        {
            return Err(invalid("Invalid durable recovery key"));
        }
    }
    src = hash_source(src, cancel.clone()).await?;
    let mut attempts = 0;
    let receipt: Receipt = loop {
        let mut body = serde_json::json!({"size":src.size,"sha256":src.sha256});
        if durable {
            body["recovery"] = serde_json::json!({"version":1,"resumeKey":target.resume_key});
            if source_end.is_some() {
                body["recovery"]["sourceEnd"] = serde_json::json!(1);
            }
        }
        let request = client
            .client
            .post(target.url("open", None, None))
            .json(&body);
        let result = async {
            json::<Receipt>(response(client, &target, request, &cancel).await?, &cancel).await
        }
        .await;
        match result {
            Ok(r) => break r,
            Err(e)
                if retryable(&e)
                    || matches!(&e, ClientError::StatusCode(code) if code.status == 409) =>
            {
                backoff(&mut attempts, &cancel, durable, &recovery).await?
            }
            Err(e) => return Err(classify(e, durable)),
        }
    };
    receipt.validate(&src, None)?;
    let resume = receipt.resume_id.clone();
    let size = src.size;
    let sha256 = src.sha256.clone();
    let result = transfer(
        client,
        &target,
        src,
        receipt,
        &progress,
        &verification,
        &recovery,
        source_end.as_ref(),
        durable,
        &cancel,
        &mut attempts,
    )
    .await
    .map_err(|e| classify(e, durable));
    if matches!(result, Err(ClientError::ResumeInterrupted { .. })) {
        // An unacknowledged suspend is not permission to send v2 cancel: the
        // two connections can reorder and destroy a checkpoint being detached.
        let suspended = tokio::time::timeout(Duration::from_secs(2), async {
            let stop = CancellationToken::new();
            json::<Receipt>(
                response(
                    client,
                    &target,
                    client
                        .client
                        .post(target.url("suspend", Some(&resume), None)),
                    &stop,
                )
                .await?,
                &stop,
            )
            .await
        })
        .await;
        if let Ok(Ok(receipt)) = suspended {
            let valid = receipt.version == 1
                && receipt.resume_id == resume
                && receipt.size == size
                && receipt.sha256.eq_ignore_ascii_case(&sha256)
                && receipt.block_size == BLOCK
                && receipt.offset <= size
                && (receipt.offset == size || receipt.offset % BLOCK as u64 == 0);
            if valid && receipt.state == "complete" && receipt.offset == size {
                progress(size);
                return Ok(());
            }
            if valid && receipt.state == "suspended" {
                return Err(ClientError::ResumeInterrupted {
                    retained_confirmed: true,
                });
            }
        }
        return Err(ClientError::ResumeInterrupted {
            retained_confirmed: false,
        });
    }
    if matches!(
        &result,
        Err(ClientError::Recovery {
            kind: RecoveryFailureKind::Retryable | RecoveryFailureKind::AuthorizationRequired,
            retention: RecoveryRetention::Unknown,
            ..
        })
    ) {
        return result;
    }
    if result.is_err() {
        // Best effort, file-local cleanup only. Never cancel unrelated session files.
        let _ = tokio::time::timeout(Duration::from_secs(2), async {
            response(
                client,
                &target,
                client.client.post(target.url("abort", Some(&resume), None)),
                &CancellationToken::new(),
            )
            .await?;
            Ok::<(), ClientError>(())
        })
        .await;
    }
    result
}
async fn transfer<P: Fn(u64) + Send, V: Fn(u64, u64) + Send, R: Fn(RecoveryPhase) + Send>(
    client: &LsHttpClientV2,
    target: &Target<'_>,
    mut source: Source,
    mut receipt: Receipt,
    progress: &P,
    verification: &V,
    recovery: &R,
    source_end: Option<&crate::http::source_end::SourceEndCallback>,
    durable: bool,
    cancel: &CancellationToken,
    attempts: &mut u8,
) -> Result<(), ClientError> {
    let resume = receipt.resume_id.clone();
    let mut saved_grant: Option<(String, String)> = None;
    let mut verification_waiting = false;
    let verification_deadline = tokio::time::Instant::now() + Duration::from_secs(30 * 60);
    loop {
        cancelled(cancel)?;
        receipt.validate(&source, Some(&resume))?;
        check_file(&source.file, source.size, source.modified)?;
        if receipt.state == "verifying" {
            // A newly approved provider receive may validate an older local
            // cache without negotiating durable sender/session recovery. This
            // state only waits for offset zero to become ready; durable grants
            // and suspension retain their separate capability gates.
            verification(receipt.verified_bytes.unwrap_or(0), source.size);
            if tokio::time::Instant::now() >= verification_deadline {
                return Err(ClientError::ResumeInterrupted {
                    retained_confirmed: false,
                });
            }
            tokio::select! { biased; _ = cancel.cancelled() => return Err(ClientError::Cancelled),
            _ = tokio::time::sleep(Duration::from_secs(1)) => {} }
            if verification_waiting {
                recovery(RecoveryPhase {
                    waiting: false,
                    attempt: 1,
                    retry_after_ms: 0,
                });
                verification_waiting = false;
            }
            match status(client, target, &resume, cancel).await {
                Ok(next) => {
                    next.validate(&source, Some(&resume))?;
                    receipt = next;
                }
                Err(e) if retryable(&e) => {
                    verification_waiting = true;
                    recovery(RecoveryPhase {
                        waiting: true,
                        attempt: 1,
                        retry_after_ms: 1000,
                    });
                }
                Err(e) if busy(&e) => {}
                Err(e) => return Err(e),
            }
            continue;
        }
        if let Some(callback) = source_end {
            let grant = receipt
                .source_end
                .as_ref()
                .filter(|g| g.valid())
                .ok_or_else(|| invalid("Missing source-end authority"))?;
            let key = (grant.grant_id.clone(), grant.round.clone());
            if saved_grant.as_ref() != Some(&key) {
                let (tx, rx) = tokio::sync::oneshot::channel();
                callback(crate::http::source_end::SourceEndEvent::Grant {
                    grant: grant.clone(),
                    persisted: tx,
                });
                let saved = tokio::select! {biased;
                    _=cancel.cancelled()=>return Err(ClientError::Cancelled),
                    result=tokio::time::timeout(Duration::from_secs(30),rx)=>matches!(result,Ok(Ok(true))),
                };
                if !saved {
                    return Err(ClientError::ResumeInterrupted {
                        retained_confirmed: false,
                    });
                }
                saved_grant = Some(key);
            }
        }
        if receipt.state == "suspended" {
            return Err(invalid("Unexpected suspended upload"));
        }
        if receipt.state == "complete" {
            progress(source.size);
            return Ok(());
        }
        progress(receipt.offset.min(source.size.saturating_sub(1)));
        let expected_offset = (receipt.offset + BLOCK as u64).min(source.size);
        let finishing = receipt.offset == source.size;
        let result = if !finishing {
            let (s, bytes) = read_block(source, receipt.offset, cancel.clone()).await?;
            source = s;
            let hash = crate::crypto::hash::sha256_hex(&bytes);
            let request = client
                .client
                .put(target.url("block", Some(&resume), Some(receipt.offset)))
                .header("X-LegnaSend-Block-Sha256", hash)
                .body(bytes);
            async {
                json::<Receipt>(response(client, target, request, cancel).await?, cancel).await
            }
            .await
        } else {
            let request = client
                .client
                .post(target.url("finish", Some(&resume), None));
            async {
                json::<Receipt>(response(client, target, request, cancel).await?, cancel).await
            }
            .await
        };
        match result {
            Ok(next) => {
                next.validate(&source, Some(&resume))?;
                if next.offset != expected_offset || (finishing && next.state != "complete") {
                    return Err(invalid(
                        "Receiver returned an inconsistent resume checkpoint",
                    ));
                }
                receipt = next;
            }
            Err(e) if retryable(&e) || busy(&e) => loop {
                backoff(attempts, cancel, durable, recovery).await?;
                match status(client, target, &resume, cancel).await {
                    Ok(next) => {
                        next.validate(&source, Some(&resume))?;
                        if next.offset < receipt.offset || next.offset > expected_offset {
                            return Err(invalid(
                                "Receiver returned an impossible resume checkpoint",
                            ));
                        }
                        receipt = next;
                        break;
                    }
                    Err(e) if retryable(&e) || busy(&e) => {}
                    Err(e) => return Err(e),
                }
            },
            Err(e) => return Err(e),
        }
    }
}
async fn legacy<P: Fn(u64) + Send + 'static>(
    client: &LsHttpClientV2,
    target: Target<'_>,
    content: FileContent,
    progress: P,
    cancel: CancellationToken,
) -> Result<(), ClientError> {
    let body = tokio::select! {biased;_=cancel.cancelled()=>return Err(ClientError::Cancelled),body=super::upload_body::build(content,progress)=>body?};
    client
        .upload(
            target.protocol,
            target.ip,
            target.port,
            target.public_key,
            target.session,
            target.file,
            target.token,
            body,
            cancel,
        )
        .await
}

#[allow(clippy::too_many_arguments)]
pub(super) async fn end_source(
    client: &LsHttpClientV2,
    protocol: ProtocolType,
    ip: &str,
    port: u16,
    public_key: Option<String>,
    grant: crate::http::source_end::SourceEndGrant,
    request_id: String,
    cancel: CancellationToken,
) -> Result<crate::http::source_end::SourceEndResult, ClientError> {
    if !grant.valid() || !crate::http::source_end::valid_uuid(&request_id) {
        return Err(invalid("Invalid authority"));
    }
    let target = Target {
        protocol,
        ip,
        port,
        public_key,
        session: "",
        file: "",
        token: "",
        resume_key: None,
    };
    let mut url = reqwest::Url::parse(&target.url("source-end", None, None))
        .map_err(|_| invalid("Invalid peer"))?;
    url.set_query(None);
    let request = crate::http::source_end::SourceEndRequest {
        version: 1,
        request_id,
        grant_id: grant.grant_id,
        round: grant.round,
        token: grant.token,
    };
    let response = response(
        client,
        &target,
        client.client.post(url).json(&request),
        &cancel,
    )
    .await?;
    json(response, &cancel).await
}
