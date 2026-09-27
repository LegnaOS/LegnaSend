//! Opt-in same-session resume. Legacy v2 upload behavior remains unchanged.
use super::common::{error::AppError, response::BoxedBody};
use super::{
    AppState, RequestClientInfo, V2State,
    common::{
        receive_cache::{self, ResumableReceive},
        save::{FileTimestamps, FileUploadTarget, SaveResult},
        session::{FileStatusV2, SessionStateV2},
    },
    v2,
};
use crate::download_cache::CacheIdentity;
use http_body_util::BodyExt;
use hyper::{Method, Request, Response, StatusCode, body::Incoming};
use serde::Deserialize;
use serde_json::json;

use std::{
    collections::HashMap,
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, AtomicU8, Ordering},
        mpsc as sync,
    },
    time::{Duration, Instant},
};
use tokio::sync::oneshot;
use tokio_util::sync::CancellationToken;

const PREFIX: &str = "/api/legnasend/v1/receive-resume/";
const BLOCK: u64 = 1024 * 1024;
const IDLE: Duration = Duration::from_secs(60);
#[derive(Default)]
pub(crate) struct Registry {
    entries: Mutex<HashMap<String, Arc<Entry>>>,
}
struct Entry {
    id: String,
    session: String,
    file: String,
    token: String,
    peer: super::PeerIp,
    cert: Option<String>,
    size: u64,
    sha: String,
    cancel: CancellationToken,
    busy: AtomicBool,
    state: Mutex<Progress>,
    tx: sync::SyncSender<Command>,
    durable: Option<Durable>,
    exit: AtomicU8,
    detached: AtomicBool,
}
const DISCARD: u8 = 0;
const SUSPEND: u8 = 1;
const ABORT: u8 = 2;
const DETACHED: u8 = 3;
struct Durable {
    source_end: bool,
    end_grant: Mutex<Option<crate::http::source_end::SourceEndGrant>>,
    source: crate::receive_resume_registry::Source,
    approved: Mutex<Option<(String, String)>>,
    receipt: Mutex<RecoveryTargetLookup>,
    pending_lease: Mutex<Option<crate::receive_resume_registry::Lease>>,
}
#[derive(Clone)]
pub struct RecoveryTargetLookup {
    pub path: Option<String>,
    pub receipt_id: String,
    pub completed_unix_ms: Option<u64>,
}
static LOOKUPS: tokio::sync::Semaphore = tokio::sync::Semaphore::const_new(8);
struct Progress {
    offset: u64,
    phase: &'static str,
    touched: Instant,
    verified_bytes: u64,
}
enum Command {
    Block(u64, Vec<u8>, oneshot::Sender<Result<(), String>>, Busy),
    Finish(oneshot::Sender<Result<(), String>>, Busy),
    Suspend(oneshot::Sender<Result<(), String>>, Busy),
}
struct Busy(Arc<Entry>);
impl Drop for Busy {
    fn drop(&mut self) {
        self.0.busy.store(false, Ordering::Release);
    }
}
impl Entry {
    fn discard_attached(&self) {
        let mut current = self.exit.load(Ordering::Acquire);
        loop {
            if current == DETACHED {
                return;
            }
            match self
                .exit
                .compare_exchange(current, ABORT, Ordering::AcqRel, Ordering::Acquire)
            {
                Ok(_) => {
                    self.cancel.cancel();
                    return;
                }
                Err(next) => current = next,
            }
        }
    }
    fn detach(&self) -> bool {
        self.exit
            .compare_exchange(SUSPEND, DETACHED, Ordering::AcqRel, Ordering::Acquire)
            .is_ok()
    }
    fn response(&self) -> Result<Response<BoxedBody>, AppError> {
        let s = self.state.lock().unwrap();
        match s.phase {
            "initializing" if self.durable.is_none() => return Err(code(StatusCode::CONFLICT)),
            "failed" | "cancelled" => return Err(code(StatusCode::GONE)),
            _ => {}
        }
        if self.cancel.is_cancelled() && !matches!(s.phase, "complete" | "suspended") {
            return Err(code(StatusCode::GONE));
        }
        let mut value = json!({"version":1,"resumeId":self.id,"blockSize":BLOCK,"offset":s.offset,"size":self.size,"sha256":self.sha,"state":if s.phase=="initializing" {"verifying"}else{s.phase},"verifiedBytes":s.verified_bytes});
        if let Some(durable) = &self.durable {
            if let Some(grant) = durable.end_grant.lock().unwrap().as_ref() {
                value["sourceEnd"] = serde_json::to_value(grant)
                    .map_err(|_| code(StatusCode::INTERNAL_SERVER_ERROR))?;
            }
        }
        response(value)
    }
    fn authenticate(&self, q: &HashMap<String, String>, client: &RequestClientInfo) -> bool {
        q.get("sessionId") == Some(&self.session)
            && q.get("fileId") == Some(&self.file)
            && q.get("token") == Some(&self.token)
            && self.peer == client.ip
            && self.cert == client.cert_fingerprint()
    }
}
pub(super) async fn supports_target(directory: String, name: String) -> anyhow::Result<bool> {
    let permit = LOOKUPS
        .try_acquire()
        .map_err(|_| anyhow::anyhow!("Recovery target lookup busy"))?;
    tokio::task::spawn_blocking(move || {
        let _permit = permit;
        crate::receive_resume_registry::supports_target(std::path::Path::new(&directory), &name)
    })
    .await?
    .map_err(Into::into)
}
impl Registry {
    pub(super) async fn lookup_target(
        &self,
        session: &str,
        file: &str,
        attempt: &str,
        approved_directory: String,
        requested_name: String,
    ) -> anyhow::Result<RecoveryTargetLookup> {
        let entry = self
            .entries
            .lock()
            .unwrap()
            .values()
            .find(|e| e.session == session && e.file == file && e.id == attempt)
            .cloned()
            .ok_or_else(|| anyhow::anyhow!("Expired recovery attempt"))?;
        let durable = entry
            .durable
            .as_ref()
            .ok_or_else(|| anyhow::anyhow!("Not a durable recovery attempt"))?;
        if entry.cancel.is_cancelled() {
            anyhow::bail!("Recovery attempt canceled");
        }
        {
            let mut approved = durable.approved.lock().unwrap();
            let value = (approved_directory.clone(), requested_name.clone());
            if approved.as_ref().is_some_and(|old| old != &value) {
                anyhow::bail!("Recovery approval target changed");
            }
            *approved = Some(value);
        }
        let source = durable.source.clone();
        let worker_entry = entry.clone();
        let permit = LOOKUPS
            .try_acquire()
            .map_err(|_| anyhow::anyhow!("Recovery target lookup busy"))?;
        let registry = crate::receive_resume_registry::current()
            .ok_or_else(|| anyhow::anyhow!("Durable recovery is not configured"))?;
        let fallback = durable.receipt.lock().unwrap().clone();
        let result =
            tokio::task::spawn_blocking(move || -> anyhow::Result<RecoveryTargetLookup> {
                let _permit = permit;
                if worker_entry.cancel.is_cancelled() {
                    anyhow::bail!("Recovery attempt canceled");
                }
                registry.retire_expired(
                    &source,
                    std::path::Path::new(&approved_directory),
                    &requested_name,
                )?;
                registry.invalidate_changed_source(
                    &source,
                    std::path::Path::new(&approved_directory),
                    &requested_name,
                )?;
                let claim = registry.claim(
                    &source,
                    std::path::Path::new(&approved_directory),
                    &requested_name,
                )?;
                let result = match &claim {
                    Some(lease) => RecoveryTargetLookup {
                        path: Some(lease.record.target.path().to_string_lossy().into_owned()),
                        receipt_id: lease.record.receipt_id.clone(),
                        completed_unix_ms: lease.completed_unix_ms(),
                    },
                    None => fallback,
                };
                let durable = worker_entry.durable.as_ref().unwrap();
                *durable.pending_lease.lock().unwrap() = claim;
                if worker_entry.cancel.is_cancelled() {
                    if let Some(mut lease) = durable.pending_lease.lock().unwrap().take() {
                        if lease.discard().is_ok() {
                            let _ = registry.retire(lease);
                        }
                    }
                    anyhow::bail!("Recovery attempt canceled");
                }
                Ok(result)
            })
            .await??;
        let current = self.entries.lock().unwrap().get(&entry.id).cloned();
        if entry.cancel.is_cancelled()
            || current
                .as_ref()
                .is_none_or(|current| !Arc::ptr_eq(current, &entry))
        {
            anyhow::bail!("Recovery attempt expired");
        }
        *entry.durable.as_ref().unwrap().receipt.lock().unwrap() = result.clone();
        Ok(result)
    }
    pub(super) fn contains_session(&self, session: &str) -> bool {
        self.entries
            .lock()
            .unwrap()
            .values()
            .any(|entry| entry.session == session)
    }
    pub(super) fn revoke(&self, session: &str, client: &RequestClientInfo) {
        self.entries.lock().unwrap().retain(|_, entry| {
            if entry.session == session
                && entry.peer == client.ip
                && entry.cert == client.cert_fingerprint()
            {
                entry.discard_attached();
                false
            } else {
                true
            }
        });
    }
    pub(super) fn revoke_session(&self, session: &str) {
        self.entries.lock().unwrap().retain(|_, entry| {
            if entry.session == session {
                entry.discard_attached();
                false
            } else {
                true
            }
        });
    }
    pub(super) fn stop(&self) {
        for (_, entry) in self.entries.lock().unwrap().drain() {
            entry.discard_attached();
        }
    }
}
fn code(status: StatusCode) -> AppError {
    AppError::Status(status)
}
fn response(value: serde_json::Value) -> Result<Response<BoxedBody>, AppError> {
    Ok(super::common::response::JsonResponse {
        status: StatusCode::OK,
        body: value,
    }
    .into_response())
}
fn digest(bytes: &[u8]) -> String {
    crate::crypto::hash::sha256_hex(bytes).to_ascii_lowercase()
}
fn strong(value: &str) -> bool {
    value.len() == 64 && value.bytes().all(|v| v.is_ascii_hexdigit())
}
async fn body(
    req: Request<Incoming>,
    max: usize,
    cancel: Option<&CancellationToken>,
) -> Result<Vec<u8>, AppError> {
    let mut stream = req.into_body();
    let mut bytes = Vec::new();
    loop {
        let frame = tokio::select! {biased;
            _=async{match cancel {Some(v)=>v.cancelled().await,None=>std::future::pending().await}}=>return Err(code(StatusCode::GONE)),
            frame=stream.frame()=>frame,
        };
        match frame {
            Some(Ok(frame)) => {
                if let Ok(data) = frame.into_data() {
                    if bytes.len().saturating_add(data.len()) > max {
                        return Err(code(StatusCode::PAYLOAD_TOO_LARGE));
                    }
                    bytes.extend_from_slice(&data);
                }
            }
            Some(Err(_)) => return Err(code(StatusCode::BAD_REQUEST)),
            None => return Ok(bytes),
        }
    }
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Open {
    size: u64,
    sha256: String,
    recovery: Option<Recovery>,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Recovery {
    version: u32,
    resume_key: String,
    source_end: Option<u32>,
}

pub(super) async fn route(
    req: Request<Incoming>,
    state: AppState,
    client: RequestClientInfo,
) -> Result<Response<BoxedBody>, AppError> {
    if req.uri().path() == format!("{PREFIX}source-end") {
        return source_end_route(req, client, state.v2.clone()).await;
    }
    let v2 = state
        .v2
        .clone()
        .ok_or_else(|| code(StatusCode::NOT_FOUND))?;
    let action = req
        .uri()
        .path()
        .strip_prefix(PREFIX)
        .unwrap_or("")
        .to_owned();
    let raw = req.uri().query().unwrap_or("");
    if raw.len() > 16 * 1024 {
        return Err(code(StatusCode::BAD_REQUEST));
    }
    let mut q = HashMap::new();
    for (key, value) in form_urlencoded::parse(raw.as_bytes()) {
        let allowed = match action.as_str() {
            "open" | "capabilities" => matches!(key.as_ref(), "sessionId" | "fileId" | "token"),
            "block" => matches!(
                key.as_ref(),
                "sessionId" | "fileId" | "token" | "resumeId" | "offset"
            ),
            _ => matches!(key.as_ref(), "sessionId" | "fileId" | "token" | "resumeId"),
        };
        if !allowed
            || value.is_empty()
            || value.len() > 4096
            || q.insert(key.into_owned(), value.into_owned()).is_some()
        {
            return Err(code(StatusCode::BAD_REQUEST));
        }
    }
    for key in ["sessionId", "fileId", "token"] {
        if !q.contains_key(key) {
            return Err(code(StatusCode::BAD_REQUEST));
        }
    }
    if action == "capabilities" && req.method() == Method::GET {
        let slot = v2.session.lock().await;
        let Some(SessionStateV2::Active(session)) = slot.as_ref() else {
            return Err(code(StatusCode::FORBIDDEN));
        };
        let file = session
            .files
            .get(&q["fileId"])
            .ok_or_else(|| code(StatusCode::FORBIDDEN))?;
        if session.session_id != q["sessionId"]
            || session.sender_ip != client.ip
            || session.sender_cert != client.cert_fingerprint()
            || file.token != q["token"]
            || session.cancel.is_cancelled()
        {
            return Err(code(StatusCode::FORBIDDEN));
        }
        if !file.resumable
            || file.dto.size < BLOCK
            || file.dto.size.div_ceil(BLOCK) > crate::download_cache::MAX_CHUNKS
        {
            return Err(code(StatusCode::NOT_FOUND));
        }
        let mut cap = json!({"version":1,"supported":true,"blockSize":BLOCK});
        if file.durable && crate::receive_resume_registry::current().is_some() {
            cap["durable"] = json!({"version":1,"sourceEnd":{"version":1}});
        }
        return response(cap);
    }
    if action == "open" && req.method() == Method::POST {
        return open(req, v2, q, client).await;
    }
    let id = q
        .get("resumeId")
        .ok_or_else(|| code(StatusCode::BAD_REQUEST))?;
    let entry = v2
        .resumes
        .entries
        .lock()
        .unwrap()
        .get(id)
        .cloned()
        .ok_or_else(|| code(StatusCode::GONE))?;
    if !entry.authenticate(&q, &client) {
        return Err(code(StatusCode::FORBIDDEN));
    }
    if v2.stopped.is_cancelled() {
        return Err(code(StatusCode::GONE));
    }
    if action == "abort" && req.method() == Method::POST {
        if entry.state.lock().unwrap().phase == "complete" {
            return entry.response();
        }
        entry.discard_attached();
        if entry.exit.load(Ordering::Acquire) == DETACHED {
            return Err(code(StatusCode::GONE));
        }
        return response(json!({"version":1,"state":"cancelling"}));
    }
    if action == "status" && req.method() == Method::GET {
        if entry.durable.is_some() {
            entry.state.lock().unwrap().touched = Instant::now();
        }
        if entry.busy.load(Ordering::Acquire) {
            return Err(code(StatusCode::CONFLICT));
        }
        return entry.response();
    }
    entry.response()?;
    let phase = entry.state.lock().unwrap().phase;
    if matches!(phase, "initializing" | "verifying") && action != "suspend" {
        return Err(code(StatusCode::CONFLICT));
    }
    if phase == "suspended" {
        return if action == "suspend" {
            entry.response()
        } else {
            Err(code(StatusCode::GONE))
        };
    }
    if entry.busy.swap(true, Ordering::AcqRel) {
        return Err(code(StatusCode::CONFLICT));
    }
    let busy = Busy(entry.clone());
    let (tx, rx) = oneshot::channel();
    let command = if action == "suspend" && req.method() == Method::POST {
        if entry.durable.is_none() {
            return Err(code(StatusCode::NOT_FOUND));
        }
        if entry.state.lock().unwrap().phase == "complete" {
            return entry.response();
        }
        entry
            .exit
            .compare_exchange(DISCARD, SUSPEND, Ordering::AcqRel, Ordering::Acquire)
            .map_err(|_| code(StatusCode::CONFLICT))?;
        Command::Suspend(tx, busy)
    } else if action == "block" && req.method() == Method::PUT {
        if entry.state.lock().unwrap().phase == "complete" {
            return Err(code(StatusCode::CONFLICT));
        }
        let offset = q
            .get("offset")
            .and_then(|v| v.parse::<u64>().ok())
            .ok_or_else(|| code(StatusCode::BAD_REQUEST))?;
        let hash = req
            .headers()
            .get("x-legnasend-block-sha256")
            .and_then(|v| v.to_str().ok())
            .filter(|s| strong(s))
            .ok_or_else(|| code(StatusCode::BAD_REQUEST))?
            .to_ascii_lowercase();
        if offset != entry.state.lock().unwrap().offset || offset >= entry.size {
            return Err(code(StatusCode::CONFLICT));
        }
        let expected = (entry.size - offset).min(BLOCK) as usize;
        let bytes = tokio::time::timeout(IDLE, body(req, expected, Some(&entry.cancel)))
            .await
            .map_err(|_| code(StatusCode::REQUEST_TIMEOUT))??;
        if bytes.len() != expected {
            entry.cancel.cancel();
            return Err(code(StatusCode::BAD_REQUEST));
        }
        if digest(&bytes) != hash {
            entry.cancel.cancel();
            return Err(code(StatusCode::UNPROCESSABLE_ENTITY));
        }
        Command::Block(offset, bytes, tx, busy)
    } else if action == "finish" && req.method() == Method::POST {
        if entry.state.lock().unwrap().phase == "complete" {
            return entry.response();
        }
        if entry.state.lock().unwrap().offset != entry.size {
            return Err(code(StatusCode::CONFLICT));
        }
        Command::Finish(tx, busy)
    } else {
        return Err(code(StatusCode::NOT_FOUND));
    };
    entry
        .tx
        .try_send(command)
        .map_err(|_| code(StatusCode::CONFLICT))?;
    let result = tokio::select! {biased;
        result=rx=>result,
        _=entry.cancel.cancelled()=>return Err(code(StatusCode::GONE)),
        _=v2.stopped.cancelled()=>return Err(code(StatusCode::GONE)),
    };
    match result {
        Ok(Ok(())) => entry.response(),
        _ => Err(code(StatusCode::INTERNAL_SERVER_ERROR)),
    }
}

async fn open(
    req: Request<Incoming>,
    v2: Arc<V2State>,
    q: HashMap<String, String>,
    client: RequestClientInfo,
) -> Result<Response<BoxedBody>, AppError> {
    // Authenticate before awaiting any peer-supplied body. Revalidate again when
    // claiming the file because the accepted session can change during this await.
    let existing = v2
        .resumes
        .entries
        .lock()
        .unwrap()
        .values()
        .find(|e| e.session == q["sessionId"] && e.file == q["fileId"])
        .cloned();
    if let Some(entry) = existing {
        if !entry.authenticate(&q, &client) {
            return Err(code(StatusCode::FORBIDDEN));
        }
    } else {
        let slot = v2.session.lock().await;
        let Some(SessionStateV2::Active(session)) = slot.as_ref() else {
            return Err(code(StatusCode::FORBIDDEN));
        };
        let file = session
            .files
            .get(&q["fileId"])
            .ok_or_else(|| code(StatusCode::FORBIDDEN))?;
        if session.session_id != q["sessionId"]
            || session.sender_ip != client.ip
            || session.sender_cert != client.cert_fingerprint()
            || file.token != q["token"]
            || session.cancel.is_cancelled()
        {
            return Err(code(StatusCode::FORBIDDEN));
        }
        if !file.resumable
            || file.dto.size < BLOCK
            || file.dto.size.div_ceil(BLOCK) > crate::download_cache::MAX_CHUNKS
        {
            return Err(code(StatusCode::NOT_FOUND));
        }
    }
    let bytes = tokio::time::timeout(Duration::from_secs(10), body(req, 1024, None))
        .await
        .map_err(|_| code(StatusCode::REQUEST_TIMEOUT))??;
    let open: Open = serde_json::from_slice(&bytes).map_err(|_| code(StatusCode::BAD_REQUEST))?;
    if !strong(&open.sha256) {
        return Err(code(StatusCode::BAD_REQUEST));
    }
    let sha = open.sha256.to_ascii_lowercase();
    if open.recovery.as_ref().is_some_and(|r| {
        r.version != 1
            || r.source_end.is_some_and(|version| version != 1)
            || !uuid::Uuid::parse_str(&r.resume_key).is_ok_and(|id| id.to_string() == r.resume_key)
    }) {
        return Err(code(StatusCode::BAD_REQUEST));
    }
    // Repeated open, including after a lost response, never dispatches a second target.
    {
        let entries = v2.resumes.entries.lock().unwrap();
        if let Some(entry) = entries
            .values()
            .find(|e| e.session == q["sessionId"] && e.file == q["fileId"])
        {
            if !entry.authenticate(&q, &client) {
                return Err(code(StatusCode::FORBIDDEN));
            }
            if entry.durable.as_ref().is_some_and(|d| d.source_end)
                != open
                    .recovery
                    .as_ref()
                    .is_some_and(|r| r.source_end == Some(1))
                || entry.size != open.size
                || entry.sha != sha
                || entry.durable.as_ref().map(|d| d.source.resume_key.as_str())
                    != open.recovery.as_ref().map(|r| r.resume_key.as_str())
            {
                return Err(code(StatusCode::CONFLICT));
            }
            return entry.response();
        }
    }
    let permit = receive_cache::ACTIVE
        .try_acquire()
        .map_err(|_| code(StatusCode::TOO_MANY_REQUESTS))?;
    let (tx, rx) = sync::sync_channel(1);
    let (entry, dto) = {
        let mut slot = v2.session.lock().await;
        let Some(SessionStateV2::Active(session)) = slot.as_mut() else {
            return Err(code(StatusCode::FORBIDDEN));
        };
        if session.session_id != q["sessionId"]
            || session.sender_ip != client.ip
            || session.sender_cert != client.cert_fingerprint()
            || session.cancel.is_cancelled()
        {
            return Err(code(StatusCode::FORBIDDEN));
        }
        let file = session
            .files
            .get_mut(&q["fileId"])
            .ok_or_else(|| code(StatusCode::FORBIDDEN))?;
        if file.token != q["token"] {
            return Err(code(StatusCode::FORBIDDEN));
        }
        if !file.resumable
            || file.dto.size < BLOCK
            || file.dto.size.div_ceil(BLOCK) > crate::download_cache::MAX_CHUNKS
        {
            return Err(code(StatusCode::NOT_FOUND));
        }
        if file.status != FileStatusV2::Pending {
            return Err(code(StatusCode::CONFLICT));
        }
        if file.dto.size != open.size
            || file
                .dto
                .sha256
                .as_ref()
                .is_some_and(|s| !s.eq_ignore_ascii_case(&sha))
        {
            return Err(code(StatusCode::CONFLICT));
        }
        if open.size.div_ceil(BLOCK) > crate::download_cache::MAX_CHUNKS {
            return Err(code(StatusCode::PAYLOAD_TOO_LARGE));
        }
        if open.recovery.is_some()
            && (!file.durable || crate::receive_resume_registry::current().is_none())
        {
            return Err(code(StatusCode::CONFLICT));
        }
        let durable = open.recovery.map(|recovery| Durable {
            source_end: recovery.source_end == Some(1),
            end_grant: Mutex::new(None),
            source: crate::receive_resume_registry::Source {
                resume_key: recovery.resume_key,
                peer: match client.cert_fingerprint() {
                    Some(sha256) => crate::receive_resume_registry::Peer::Certificate { sha256 },
                    None => crate::receive_resume_registry::Peer::Http {
                        address: client.ip.to_string(),
                    },
                },
                sha256: sha.clone(),
                size: open.size,
            },
            approved: Mutex::new(None),
            pending_lease: Mutex::new(None),
            receipt: Mutex::new(RecoveryTargetLookup {
                path: None,
                receipt_id: uuid::Uuid::new_v4().to_string(),
                completed_unix_ms: None,
            }),
        });
        let entry = Arc::new(Entry {
            id: uuid::Uuid::new_v4().to_string(),
            session: q["sessionId"].clone(),
            file: q["fileId"].clone(),
            token: q["token"].clone(),
            peer: client.ip,
            cert: client.cert_fingerprint(),
            size: open.size,
            sha,
            cancel: session.cancel.child_token(),
            busy: AtomicBool::new(false),
            state: Mutex::new(Progress {
                offset: 0,
                phase: "initializing",
                touched: Instant::now(),
                verified_bytes: 0,
            }),
            tx,
            durable,
            exit: AtomicU8::new(DISCARD),
            detached: AtomicBool::new(false),
        });
        let mut entries = v2.resumes.entries.lock().unwrap();
        // Successful receipts carry no descriptors and are bounded independently.
        entries.retain(|_, e| {
            let s = e.state.lock().unwrap();
            !(matches!(s.phase, "complete" | "failed" | "cancelled") && s.touched.elapsed() >= IDLE)
        });
        if entries.len() >= 72 {
            return Err(code(StatusCode::TOO_MANY_REQUESTS));
        }
        entries.insert(entry.id.clone(), entry.clone());
        file.status = FileStatusV2::InProgress;
        file.attempts = file.attempts.saturating_add(1);
        session.last_activity = tokio::time::Instant::now();
        v2.session_changed.notify_one();
        (entry, file.dto.clone())
    };
    let (ready_tx, mut ready_rx) = oneshot::channel();
    let owner = entry.clone();
    let state = v2.clone();
    tokio::spawn(async move {
        let (target_tx, target_rx) = oneshot::channel();
        let target = tokio::select! {biased;
            _=owner.cancel.cancelled()=>None,
            _=state.stopped.cancelled()=>None,
            target=async {
                let event=if owner.durable.is_some(){v2::ServerEventV2::FileUploadRecovery{session_id:owner.session.clone(),file_id:owner.file.clone(),attempt_id:owner.id.clone(),file:dto.clone(),target_tx}}else{v2::ServerEventV2::FileUpload{session_id:owner.session.clone(),file_id:owner.file.clone(),file:dto.clone(),target_tx}};
                state.event_tx.send(event).await.ok()?;
                target_rx.await.ok()
            }=>target,
            _=tokio::time::sleep(IDLE)=>None,
        };
        let result = match target {
            Some(FileUploadTarget::CachedPath {
                path,
                result_tx,
                progress_tx,
            }) => {
                let worker = owner.clone();
                let events = state.event_tx.clone();
                tokio::task::spawn_blocking(move || {
                    let _permit = permit;
                    let times = match &dto.metadata {
                        Some(m) => FileTimestamps {
                            modified: m.modified_time(),
                            accessed: m.accessed_time(),
                        },
                        None => FileTimestamps::default(),
                    };
                    let identity = CacheIdentity {
                        task_id: worker.id.clone(),
                        source_id: format!("legnasend-resume:{}", worker.session),
                        resource_id: digest(worker.file.as_bytes()),
                        version: worker.sha.clone(),
                        file_name: path
                            .file_name()
                            .unwrap_or_default()
                            .to_string_lossy()
                            .into_owned(),
                        size: worker.size,
                        chunk_size: BLOCK as u32,
                        created_unix_ms: std::time::SystemTime::now()
                            .duration_since(std::time::UNIX_EPOCH)
                            .unwrap_or_default()
                            .as_millis() as u64,
                        sha256: Some(worker.sha.clone()),
                    };
                    let result = if worker.durable.is_some() {
                        run_durable_worker(&worker, rx, path, times, progress_tx, ready_tx, &events)
                    } else {
                        run_worker(&worker, rx, path, identity, times, progress_tx, ready_tx)
                    };
                    let success = result.is_ok();
                    let _ = result_tx.send(result);
                    if success {
                        SaveResult::Success
                    } else {
                        SaveResult::Failed
                    }
                })
                .await
                .unwrap_or(SaveResult::Failed)
            }
            Some(FileUploadTarget::CachedOpenedFiles {
                cache,
                staging,
                transaction_id,
                result_tx,
                progress_tx,
            }) if owner.durable.is_none() => {
                let worker = owner.clone();
                let events = state.event_tx.clone();
                tokio::task::spawn_blocking(move || {
                    let _permit = permit;
                    let result = run_descriptor_worker(
                        &worker,
                        rx,
                        cache,
                        staging,
                        transaction_id,
                        progress_tx,
                        ready_tx,
                        events,
                    );
                    let success = result.is_ok();
                    let _ = result_tx.send(result);
                    if success {
                        SaveResult::Success
                    } else {
                        SaveResult::Failed
                    }
                })
                .await
                .unwrap_or(SaveResult::Failed)
            }
            _ => {
                let cleanup = owner.clone();
                tokio::task::spawn_blocking(move || {
                    let _permit = permit;
                    if let Some(durable) = &cleanup.durable {
                        if let Some(mut lease) = durable.pending_lease.lock().unwrap().take() {
                            if lease.requires_coordinated_access() {
                                // No target was admitted, so Dart may already
                                // be draining its scope. Drop ONLY private registry
                                // ownership. A new approval or coordinated expiry/
                                // source-end operation can reconcile this record.
                                // There is deliberately no provider I/O in Lease::drop.
                                return;
                            }
                            if cleanup.exit.load(Ordering::Acquire) == SUSPEND
                                && !cleanup.cancel.is_cancelled()
                            {
                                let _ = lease.suspend();
                                cleanup.detached.store(true, Ordering::Release);
                                let _ = cleanup.detach();
                            } else if lease.discard().is_ok() {
                                if let Some(registry) = crate::receive_resume_registry::current() {
                                    let _ = registry.retire(lease);
                                }
                            }
                        }
                    }
                })
                .await
                .ok();
                let _ = ready_tx.send(Err(
                    "Resume target is not an approved persistent cache path".into(),
                ));
                SaveResult::Failed
            }
        };
        {
            let mut s = owner.state.lock().unwrap();
            if result != SaveResult::Success && s.phase != "suspended" {
                s.phase = if owner.cancel.is_cancelled() {
                    "cancelled"
                } else {
                    "failed"
                };
            }
            s.touched = Instant::now();
        }
        v2::finalize_file(&state, &owner.session, &owner.file, result).await;
        // The transaction and result channel have ended. Keep only a bounded,
        // authenticated receipt for a lost finish response, never an old target.
        tokio::select! { _=tokio::time::sleep(IDLE)=>{}, _=state.stopped.cancelled()=>{} }
        state.resumes.entries.lock().unwrap().remove(&owner.id);
    });
    if entry.durable.is_some() {
        return entry.response();
    }
    let ready = loop {
        tokio::select! {biased;
            ready=&mut ready_rx=>break ready,
            _=entry.cancel.cancelled()=>return Err(code(StatusCode::GONE)),
            _=v2.stopped.cancelled()=>return Err(code(StatusCode::GONE)),
            _=tokio::time::sleep(Duration::from_millis(200))=>{
                // Large provider caches are verified on the blocking worker.
                // Return progress without publishing an unacknowledged offset.
                let verifying = entry.state.lock().unwrap().phase == "verifying";
                if verifying {return entry.response();}
            },
        }
    };
    match ready {
        Ok(Ok(())) => entry.response(),
        _ => Err(code(StatusCode::INTERNAL_SERVER_ERROR)),
    }
}

fn run_worker(
    entry: &Entry,
    rx: sync::Receiver<Command>,
    path: std::path::PathBuf,
    identity: CacheIdentity,
    times: FileTimestamps,
    progress: Option<tokio::sync::mpsc::Sender<u64>>,
    ready: oneshot::Sender<Result<(), String>>,
) -> Result<(), String> {
    let mut cache =
        match ResumableReceive::create(path, identity, times, entry.cancel.clone(), progress) {
            Ok(c) => c,
            Err(e) => {
                let message = e.to_string();
                let _ = ready.send(Err(message.clone()));
                return Err(message);
            }
        };
    entry.state.lock().unwrap().phase = "ready";
    let _ = ready.send(Ok(()));
    loop {
        if entry.cancel.is_cancelled() {
            return Err("Upload cancelled".into());
        }
        if entry.state.lock().unwrap().touched.elapsed() >= IDLE {
            entry.cancel.cancel();
            return Err("Resumable upload expired".into());
        }
        match rx.recv_timeout(Duration::from_millis(100)) {
            Ok(Command::Block(offset, bytes, reply, busy)) => {
                let result = cache.commit(offset, &bytes).map_err(|e| e.to_string());
                match result {
                    Ok(offset) => {
                        let mut s = entry.state.lock().unwrap();
                        s.offset = offset;
                        s.phase = "receiving";
                        s.touched = Instant::now();
                        drop(busy);
                        let _ = reply.send(Ok(()));
                    }
                    Err(e) => {
                        drop(busy);
                        let _ = reply.send(Err(e.clone()));
                        return Err(e);
                    }
                }
            }
            Ok(Command::Suspend(reply, busy)) => {
                drop(busy);
                let _ = reply.send(Err("Not a persistent recovery transaction".into()));
                return Err("Unsupported suspension".into());
            }
            Ok(Command::Finish(reply, busy)) => {
                let result = cache.finish().map_err(|e| e.to_string());
                if result.is_ok() {
                    let mut s = entry.state.lock().unwrap();
                    s.offset = entry.size;
                    s.phase = "complete";
                    s.touched = Instant::now();
                }
                // Cleanup owned cache/staging before reporting final success.
                drop(cache);
                drop(busy);
                let _ = reply.send(result.clone());
                return result;
            }
            Err(sync::RecvTimeoutError::Timeout) => {}
            Err(sync::RecvTimeoutError::Disconnected) => return Err("Resume owner closed".into()),
        }
    }
}

/// Same-session provider resume: the worker retains both real locks across
/// transient socket failures. Restart durability remains a separate opt-in.
#[allow(clippy::too_many_arguments)]
fn run_descriptor_worker(
    entry: &Entry,
    rx: sync::Receiver<Command>,
    cache_file: std::fs::File,
    staging: std::fs::File,
    transaction_id: String,
    progress: Option<tokio::sync::mpsc::Sender<u64>>,
    ready: oneshot::Sender<Result<(), String>>,
    events: tokio::sync::mpsc::Sender<v2::ServerEventV2>,
) -> Result<(), String> {
    // Declared before the descriptor owner, so early failures close both files
    // before notifying the platform. Native cleanup waits for this notification.
    let mut release = super::common::receive_cache_files::Release::new(
        receive_cache::Context {
            cancel: entry.cancel.clone(),
            session_id: entry.session.clone(),
            file_id: entry.file.clone(),
            attempt_id: entry.id.clone(),
            event_tx: events,
        },
        transaction_id.clone(),
    );
    let identity = CacheIdentity {
        task_id: transaction_id,
        source_id: match &entry.cert {
            Some(fingerprint) => format!("cert:{}", fingerprint.to_ascii_lowercase()),
            None => format!("http:{}", entry.peer),
        },
        resource_id: entry.sha.clone(),
        version: entry.sha.clone(),
        file_name: "received-file".into(),
        size: entry.size,
        chunk_size: BLOCK as u32,
        created_unix_ms: std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_millis() as u64,
        sha256: Some(entry.sha.clone()),
    };
    let candidate = match tokio::runtime::Handle::current()
        .block_on(release.bind_identity(&identity, &entry.cancel))
    {
        Ok(candidate) => candidate,
        Err(message) => {
            drop(cache_file);
            drop(staging);
            let _ = ready.send(Err(message.clone()));
            return Err(message);
        }
    };
    let source_id = candidate
        .as_ref()
        .map(|source| source.transaction_id.clone());
    let mut source_proof = None;
    let opened = if entry.cancel.is_cancelled() {
        drop(candidate);
        drop(cache_file);
        drop(staging);
        Err(crate::download_cache::CacheError::Cancelled)
    } else if let Some(source) = candidate {
        entry.state.lock().unwrap().phase = "verifying";
        crate::receive_descriptor::DescriptorReceive::recover_copy_as(
            source.file,
            cache_file,
            staging,
            &source.identity,
            identity,
            |bytes| {
                let mut state = entry.state.lock().unwrap();
                state.verified_bytes = state.verified_bytes.max(match bytes {
                    crate::receive_descriptor::RecoveryProgress::Verifying(bytes)
                    | crate::receive_descriptor::RecoveryProgress::Copying(bytes) => bytes,
                });
                state.touched = Instant::now();
                !entry.cancel.is_cancelled()
            },
        )
        .map(|(cache, report)| {
            source_proof = Some((report.source_length, report.source_sha256));
            cache
        })
    } else {
        crate::receive_descriptor::DescriptorReceive::create(cache_file, staging, identity)
    };
    let mut cache = match opened {
        Ok(cache) => cache,
        Err(error) => {
            let message = error.to_string();
            let _ = ready.send(Err(message.clone()));
            return Err(message);
        }
    };
    if let (Some(source_id), Some((source_length, source_sha256))) = (source_id, source_proof) {
        if let Err(error) = tokio::runtime::Handle::current().block_on(release.recovered(
            source_id,
            source_length,
            source_sha256,
            &entry.cancel,
        )) {
            drop(cache);
            let _ = ready.send(Err(error.clone()));
            return Err(error);
        }
    }
    {
        let mut state = entry.state.lock().unwrap();
        state.offset = cache.offset();
        state.phase = "ready";
    }
    let _ = ready.send(Ok(()));
    loop {
        if entry.cancel.is_cancelled() {
            return Err("Upload cancelled".into());
        }
        if entry.state.lock().unwrap().touched.elapsed() >= IDLE {
            entry.cancel.cancel();
            return Err("Resumable upload expired".into());
        }
        match rx.recv_timeout(Duration::from_millis(100)) {
            Ok(Command::Block(offset, bytes, reply, busy)) => {
                let result = cache
                    .commit(offset, &bytes)
                    .map_err(|error| error.to_string());
                match result {
                    Ok(offset) => {
                        let mut state = entry.state.lock().unwrap();
                        state.offset = offset;
                        state.phase = "receiving";
                        state.touched = Instant::now();
                        if let Some(tx) = &progress {
                            let _ = tx.try_send(offset.min(entry.size.saturating_sub(1)));
                        }
                        drop(state);
                        drop(busy);
                        let _ = reply.send(Ok(()));
                    }
                    Err(error) => {
                        drop(busy);
                        let _ = reply.send(Err(error.clone()));
                        return Err(error);
                    }
                }
            }
            Ok(Command::Suspend(reply, busy)) => {
                drop(busy);
                let _ = reply.send(Err("Provider restart recovery is not enabled".into()));
                return Err("Unsupported suspension".into());
            }
            Ok(Command::Finish(reply, busy)) => {
                let exported = cache
                    .finish(|_| !entry.cancel.is_cancelled())
                    .map_err(|error| error.to_string());
                // finish consumed/closed the files even when export failed.
                let result = match exported {
                    Ok(receipt) => tokio::runtime::Handle::current()
                        .block_on(release.publish_verified(receipt, &entry.cancel)),
                    Err(error) => Err(error),
                };
                if result.is_ok() {
                    let mut state = entry.state.lock().unwrap();
                    state.offset = entry.size;
                    state.phase = "complete";
                    state.touched = Instant::now();
                    if let Some(tx) = &progress {
                        let _ = tx.try_send(entry.size);
                    }
                }
                drop(release);
                drop(busy);
                let _ = reply.send(result.clone());
                return result;
            }
            Err(sync::RecvTimeoutError::Timeout) => {}
            Err(sync::RecvTimeoutError::Disconnected) => return Err("Resume owner closed".into()),
        }
    }
}

fn run_durable_worker(
    entry: &Entry,
    rx: sync::Receiver<Command>,
    path: std::path::PathBuf,
    times: FileTimestamps,
    progress: Option<tokio::sync::mpsc::Sender<u64>>,
    ready: oneshot::Sender<Result<(), String>>,
    events: &tokio::sync::mpsc::Sender<v2::ServerEventV2>,
) -> Result<(), String> {
    let durable = entry.durable.as_ref().unwrap();
    let Some((root, name)) = durable.approved.lock().unwrap().clone() else {
        let _ = ready.send(Err("Recovery target lookup was not approved".into()));
        return Err("Missing approved recovery target".into());
    };
    let receipt = durable.receipt.lock().unwrap().receipt_id.clone();
    entry.state.lock().unwrap().phase = "verifying";
    let mut last = Instant::now() - Duration::from_secs(1);
    let report = |bytes: u64, verifying: bool| {
        let _ = events.try_send(v2::ServerEventV2::FileVerification {
            session_id: entry.session.clone(),
            file_id: entry.file.clone(),
            attempt_id: entry.id.clone(),
            verified_bytes: bytes,
            total_bytes: entry.size,
            verifying,
        });
    };
    report(0, true);
    let opened = receive_cache::DurableReceive::open(
        path,
        durable.source.clone(),
        durable.pending_lease.lock().unwrap().take(),
        root.clone().into(),
        name.clone(),
        receipt,
        times,
        entry.cancel.clone(),
        progress,
        |bytes| {
            entry.state.lock().unwrap().verified_bytes = bytes;
            if last.elapsed() >= Duration::from_millis(200) {
                last = Instant::now();
                report(bytes, true);
            }
            !entry.cancel.is_cancelled() && entry.exit.load(Ordering::Acquire) != SUSPEND
        },
    );
    report(entry.state.lock().unwrap().verified_bytes, false);
    let mut cache = match opened {
        Ok(cache) => cache,
        Err(error) => {
            // Interrupted verification owns no writer. Retain only an explicit
            // suspension; an explicit cancellation cleans this approved reservation.
            if let Some(registry) = crate::receive_resume_registry::current() {
                if let Ok(Some(mut lease)) =
                    registry.claim(&durable.source, std::path::Path::new(&root), &name)
                {
                    if entry.exit.load(Ordering::Acquire) == SUSPEND && !entry.cancel.is_cancelled()
                    {
                        if lease.suspend().is_ok() && entry.detach() {
                            entry.detached.store(true, Ordering::Release);
                            entry.state.lock().unwrap().phase = "suspended";
                        } else if lease.discard().is_ok() {
                            let _ = registry.retire(lease);
                        }
                    } else if lease.discard().is_ok() {
                        let _ = registry.retire(lease);
                    }
                }
            }
            let message = error.to_string();
            let _ = ready.send(Err(message.clone()));
            while let Ok(command) = rx.try_recv() {
                if let Command::Suspend(reply, busy) = command {
                    drop(busy);
                    let _ = reply.send(if entry.detached.load(Ordering::Acquire) {
                        Ok(())
                    } else {
                        Err(message.clone())
                    });
                }
            }
            return Err(message);
        }
    };
    *durable.end_grant.lock().unwrap() = cache
        .source_end_grant(durable.source_end)
        .map_err(|_| "Source-end authority could not be persisted".to_string())?;
    {
        let mut state = entry.state.lock().unwrap();
        state.offset = cache.offset();
        state.phase = if cache.complete() {
            "complete"
        } else {
            "ready"
        };
        state.touched = Instant::now();
    }
    let _ = ready.send(Ok(()));
    if cache.complete() {
        return Ok(());
    }
    loop {
        if entry.cancel.is_cancelled() {
            return Err("Upload cancelled".into());
        }
        if entry.state.lock().unwrap().touched.elapsed() >= IDLE {
            if entry
                .exit
                .compare_exchange(DISCARD, SUSPEND, Ordering::AcqRel, Ordering::Acquire)
                .is_err()
            {
                return Err("Upload canceled".into());
            }
            cache.suspend().map_err(|e| e.to_string())?;
            if !entry.detach() {
                cache.discard_on_drop();
                return Err("Upload canceled".into());
            }
            drop(cache);
            entry.detached.store(true, Ordering::Release);
            let mut state = entry.state.lock().unwrap();
            state.phase = "suspended";
            state.touched = Instant::now();
            return Err("Upload suspended after connection inactivity".into());
        }
        match rx.recv_timeout(Duration::from_millis(100)) {
            Ok(Command::Block(offset, bytes, reply, busy)) => {
                let result = cache.commit(offset, &bytes).map_err(|e| e.to_string());
                match result {
                    Ok(offset) => {
                        let mut state = entry.state.lock().unwrap();
                        state.offset = offset;
                        state.phase = "receiving";
                        state.touched = Instant::now();
                        drop(busy);
                        let _ = reply.send(Ok(()));
                    }
                    Err(error) => {
                        drop(busy);
                        let _ = reply.send(Err(error.clone()));
                        return Err(error);
                    }
                }
            }
            Ok(Command::Suspend(reply, busy)) => {
                let mut result = cache.suspend().map_err(|e| e.to_string());
                if result.is_ok() && !entry.detach() {
                    cache.discard_on_drop();
                    result = Err("Upload canceled".into());
                }
                drop(cache);
                if result.is_ok() {
                    entry.detached.store(true, Ordering::Release);
                    let mut state = entry.state.lock().unwrap();
                    state.phase = "suspended";
                    state.touched = Instant::now();
                }
                drop(busy);
                let _ = reply.send(result.clone());
                return Err(result.err().unwrap_or_else(|| "Upload suspended".into()));
            }
            Ok(Command::Finish(reply, busy)) => {
                let result = cache.finish().map_err(|e| e.to_string());
                if result.is_ok() {
                    let mut state = entry.state.lock().unwrap();
                    state.offset = entry.size;
                    state.phase = "complete";
                    state.touched = Instant::now();
                }
                drop(cache);
                drop(busy);
                let _ = reply.send(result.clone());
                return result;
            }
            Err(sync::RecvTimeoutError::Timeout) => {}
            Err(sync::RecvTimeoutError::Disconnected) => return Err("Resume owner closed".into()),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn entry() -> (Arc<Entry>, sync::Receiver<Command>) {
        let (tx, rx) = sync::sync_channel(1);
        (
            Arc::new(Entry {
                id: uuid::Uuid::new_v4().to_string(),
                session: "test".into(),
                file: "file".into(),
                token: "secret".into(),
                peer: super::super::PeerIp::from_remote_addr(&"127.0.0.1:1234".parse().unwrap()),
                cert: None,
                size: BLOCK,
                sha: "0".repeat(64),
                cancel: CancellationToken::new(),
                busy: AtomicBool::new(false),
                state: Mutex::new(Progress {
                    offset: 0,
                    phase: "ready",
                    touched: Instant::now(),
                    verified_bytes: 0,
                }),
                tx,
                durable: None,
                exit: AtomicU8::new(DISCARD),
                detached: AtomicBool::new(false),
            }),
            rx,
        )
    }
    #[test]
    fn durable_detach_is_an_authority_boundary_for_late_old_session_cancel() {
        let (entry, _) = entry();
        entry.exit.store(SUSPEND, Ordering::Release);
        assert!(entry.detach());
        entry.discard_attached();
        assert_eq!(entry.exit.load(Ordering::Acquire), DETACHED);
        assert!(!entry.cancel.is_cancelled());
        let (cancelled, _) = super::tests::entry();
        cancelled.exit.store(SUSPEND, Ordering::Release);
        cancelled.discard_attached();
        assert!(!cancelled.detach());
        assert_eq!(cancelled.exit.load(Ordering::Acquire), ABORT);
        assert!(cancelled.cancel.is_cancelled());
    }
    #[test]
    fn dropped_http_response_does_not_release_dispatched_worker_ownership() {
        let (entry, rx) = entry();
        entry.busy.store(true, Ordering::Release);
        let (reply, result) = oneshot::channel();
        entry
            .tx
            .try_send(Command::Block(0, vec![], reply, Busy(entry.clone())))
            .ok()
            .unwrap();
        drop(result); // HTTP request/connection disappeared after dispatch.
        assert!(entry.busy.load(Ordering::Acquire));
        let command = rx.recv().unwrap();
        assert!(entry.busy.load(Ordering::Acquire));
        drop(command);
        assert!(!entry.busy.load(Ordering::Acquire));
    }
    #[test]
    fn expired_idle_worker_drops_only_its_owned_cache() {
        let (entry, rx) = entry();
        entry.state.lock().unwrap().touched = Instant::now() - IDLE;
        let root = std::env::temp_dir().join(format!("resume-expiry-{}", entry.id));
        std::fs::create_dir(&root).unwrap();
        std::fs::write(root.join("unrelated.ls"), b"keep").unwrap();
        let identity = CacheIdentity {
            task_id: entry.id.clone(),
            source_id: "session".into(),
            resource_id: "file".into(),
            version: entry.sha.clone(),
            file_name: "out".into(),
            size: BLOCK,
            chunk_size: BLOCK as u32,
            created_unix_ms: 1,
            sha256: Some(entry.sha.clone()),
        };
        let (ready, _) = oneshot::channel();
        assert!(
            run_worker(
                &entry,
                rx,
                root.join("out"),
                identity,
                FileTimestamps::default(),
                None,
                ready
            )
            .unwrap_err()
            .contains("expired")
        );
        assert!(entry.cancel.is_cancelled());
        assert_eq!(std::fs::read_dir(&root).unwrap().count(), 1);
        assert_eq!(std::fs::read(root.join("unrelated.ls")).unwrap(), b"keep");
        std::fs::remove_dir_all(root).unwrap();
    }
}

// Independent bounded control requests: never old session tokens, recovery keys,
// user paths, or an unbounded blocking task queue.
static SOURCE_END_WORKERS: tokio::sync::Semaphore = tokio::sync::Semaphore::const_new(4);
async fn source_end_route(
    req: Request<Incoming>,
    client: RequestClientInfo,
    v2: Option<Arc<V2State>>,
) -> Result<Response<BoxedBody>, AppError> {
    if req.method() != Method::POST || req.uri().query().is_some() {
        return Err(code(StatusCode::BAD_REQUEST));
    }
    let permit = SOURCE_END_WORKERS
        .try_acquire()
        .map_err(|_| code(StatusCode::TOO_MANY_REQUESTS))?;
    let bytes = tokio::time::timeout(Duration::from_secs(5), body(req, 4096, None))
        .await
        .map_err(|_| code(StatusCode::REQUEST_TIMEOUT))??;
    let request: crate::http::source_end::SourceEndRequest =
        serde_json::from_slice(&bytes).map_err(|_| code(StatusCode::BAD_REQUEST))?;
    if !request.valid() {
        return Err(code(StatusCode::BAD_REQUEST));
    }
    let peer = match client.cert_fingerprint() {
        Some(sha256) => crate::receive_resume_registry::Peer::Certificate { sha256 },
        None => crate::receive_resume_registry::Peer::Http {
            address: client.ip.to_string(),
        },
    };
    let registry =
        crate::receive_resume_registry::current().ok_or_else(|| code(StatusCode::NOT_FOUND))?;
    // HTTP disconnect does not cancel a provider operation already admitted.
    // The independent owner moves its permit and completion signal into the
    // actual blocking worker, never drops them merely because this reply is gone.
    let (result_tx, result_rx) = oneshot::channel();
    tokio::spawn(async move {
        let result = source_end_operation(
            registry,
            request,
            peer,
            v2.as_ref().map(|state| state.event_tx.clone()),
            v2.as_ref()
                .map(|state| state.stopped.clone())
                .unwrap_or_default(),
            permit,
        )
        .await;
        let _ = result_tx.send(result);
    });
    let outcome = result_rx.await.unwrap_or_else(|_| source_end_retained());
    response(serde_json::to_value(outcome).map_err(|_| code(StatusCode::INTERNAL_SERVER_ERROR))?)
}

fn source_end_retained() -> crate::http::source_end::SourceEndResult {
    crate::http::source_end::SourceEndResult::new(
        crate::http::source_end::SourceEndOutcome::RetainedUnknown,
    )
}

async fn source_end_operation(
    registry: Arc<crate::receive_resume_registry::Registry>,
    request: crate::http::source_end::SourceEndRequest,
    peer: crate::receive_resume_registry::Peer,
    events: Option<tokio::sync::mpsc::Sender<v2::ServerEventV2>>,
    stopped: CancellationToken,
    permit: tokio::sync::SemaphorePermit<'static>,
) -> crate::http::source_end::SourceEndResult {
    use crate::receive_resume_registry::SourceEndPreflight;
    // Request has no Clone/Debug implementation: retain ownership, never log secrets.
    let preflight = tokio::task::spawn_blocking(move || {
        let plan = registry.preflight_source_end(&request, &peer);
        (registry, request, peer, plan, permit)
    })
    .await;
    let Ok((registry, request, peer, Ok(plan), permit)) = preflight else {
        return source_end_retained();
    };
    match plan {
        SourceEndPreflight::Complete(result) => result,
        SourceEndPreflight::Ready => tokio::task::spawn_blocking(move || {
            let _permit = permit;
            registry
                .end_source(&request, &peer)
                .unwrap_or_else(|_| source_end_retained())
        })
        .await
        .unwrap_or_else(|_| source_end_retained()),
        SourceEndPreflight::Scope(directory) => {
            let Some(events) = events else {
                return source_end_retained();
            };
            source_end_scoped_worker(
                directory,
                events,
                stopped,
                Duration::from_secs(15),
                permit,
                move |scope| {
                    registry
                        .end_source_in_scope(&request, &peer, scope)
                        .unwrap_or_else(|_| source_end_retained())
                },
            )
            .await
        }
    }
}

struct SourceEndCompletion(Option<oneshot::Sender<()>>);
impl Drop for SourceEndCompletion {
    fn drop(&mut self) {
        if let Some(sender) = self.0.take() {
            let _ = sender.send(());
        }
    }
}

async fn source_end_scoped_worker(
    directory: std::path::PathBuf,
    events: tokio::sync::mpsc::Sender<v2::ServerEventV2>,
    stopped: CancellationToken,
    timeout: Duration,
    permit: tokio::sync::SemaphorePermit<'static>,
    work: impl FnOnce(
        &crate::receive_scope_policy::CoordinatedRoot,
    ) -> crate::http::source_end::SourceEndResult
    + Send
    + 'static,
) -> crate::http::source_end::SourceEndResult {
    let (decision_tx, decision_rx) = oneshot::channel();
    let (completion_tx, completion_rx) = oneshot::channel();
    let completion = SourceEndCompletion(Some(completion_tx));
    let approved = tokio::select! { biased;
        _ = stopped.cancelled() => false,
        result = tokio::time::timeout(timeout, async {
            events.send(v2::ServerEventV2::ReceiveSourceEndScope {
                directory: directory.to_string_lossy().into_owned(), decision_tx, completion_rx,
            }).await.map_err(|_| ())?;
            decision_rx.await.map_err(|_| ())
        }) => matches!(result, Ok(Ok(true))),
    };
    if !approved {
        return source_end_retained();
    }
    // No await between grant acceptance and moving completion into this worker.
    // The guard is declared before scope so it completes only after scope closes.
    tokio::task::spawn_blocking(move || {
        let _permit = permit;
        let _completion = completion;
        let Ok(scope) = crate::receive_scope_policy::CoordinatedRoot::open(&directory) else {
            return source_end_retained();
        };
        work(&scope)
    })
    .await
    .unwrap_or_else(|_| source_end_retained())
}

#[cfg(test)]
mod source_end_scope_tests {
    use super::*;
    use crate::http::source_end::{SourceEndOutcome as Outcome, SourceEndResult};
    static SLOTS: tokio::sync::Semaphore = tokio::sync::Semaphore::const_new(4);

    fn root() -> std::path::PathBuf {
        let path =
            std::env::temp_dir().join(format!("ls-source-end-scope-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir(&path).unwrap();
        std::fs::canonicalize(path).unwrap()
    }

    #[tokio::test]
    async fn denied_late_or_closed_scope_never_starts_target_work() {
        for mode in ["denied", "late", "closed"] {
            let directory = root();
            let (events, mut rx) = tokio::sync::mpsc::channel(1);
            let started = Arc::new(AtomicBool::new(false));
            let marker = started.clone();
            let path = directory.clone();
            let stopped = CancellationToken::new();
            let task = tokio::spawn(source_end_scoped_worker(
                path,
                events,
                stopped,
                Duration::from_millis(30),
                SLOTS.acquire().await.unwrap(),
                move |_| {
                    marker.store(true, Ordering::SeqCst);
                    SourceEndResult::new(Outcome::Cleared)
                },
            ));
            let event = rx.recv().await.unwrap();
            let v2::ServerEventV2::ReceiveSourceEndScope {
                directory: approved,
                decision_tx,
                completion_rx,
            } = event
            else {
                panic!("Unexpected event");
            };
            assert_eq!(approved, directory.to_str().unwrap());
            match mode {
                "denied" => {
                    decision_tx.send(false).unwrap();
                }
                "closed" => drop(decision_tx),
                _ => {
                    tokio::time::sleep(Duration::from_millis(60)).await;
                    assert!(decision_tx.send(true).is_err());
                }
            }
            assert_eq!(task.await.unwrap().outcome, Outcome::RetainedUnknown);
            completion_rx.await.unwrap();
            assert!(!started.load(Ordering::SeqCst));
            std::fs::remove_dir(directory).unwrap();
        }
    }

    #[tokio::test]
    async fn true_grant_keeps_completion_and_slot_until_worker_drains_even_if_await_is_aborted() {
        let directory = root();
        let (events, mut rx) = tokio::sync::mpsc::channel(1);
        let (started_tx, started_rx) = oneshot::channel();
        let (release_tx, release_rx) = std::sync::mpsc::channel();
        let stopped = CancellationToken::new();
        let task = tokio::spawn(source_end_scoped_worker(
            directory.clone(),
            events,
            stopped.clone(),
            Duration::from_secs(2),
            SLOTS.acquire().await.unwrap(),
            move |scope| {
                let directory = scope.open_parent(scope.path()).unwrap();
                started_tx.send(()).unwrap();
                release_rx.recv().unwrap();
                assert!(directory.dir_metadata().unwrap().is_dir());
                SourceEndResult::new(Outcome::Cleared)
            },
        ));
        let v2::ServerEventV2::ReceiveSourceEndScope {
            decision_tx,
            mut completion_rx,
            ..
        } = rx.recv().await.unwrap()
        else {
            panic!("Unexpected event");
        };
        decision_tx.send(true).unwrap();
        started_rx.await.unwrap();
        task.abort();
        stopped.cancel();
        assert!(matches!(
            completion_rx.try_recv(),
            Err(oneshot::error::TryRecvError::Empty)
        ));
        release_tx.send(()).unwrap();
        tokio::time::timeout(Duration::from_secs(2), completion_rx)
            .await
            .unwrap()
            .unwrap();
        std::fs::remove_dir(directory).unwrap();
    }

    #[tokio::test]
    async fn stopped_listener_or_invalid_root_completes_without_false_cleanup() {
        for stopped_before in [true, false] {
            let directory = root();
            let (events, mut rx) = tokio::sync::mpsc::channel(1);
            let stopped = CancellationToken::new();
            if stopped_before {
                stopped.cancel();
            }
            let task = tokio::spawn(source_end_scoped_worker(
                directory.clone(),
                events,
                stopped,
                Duration::from_secs(2),
                SLOTS.acquire().await.unwrap(),
                |_| panic!("No authorized existing root should reach cleanup"),
            ));
            if !stopped_before {
                let v2::ServerEventV2::ReceiveSourceEndScope {
                    decision_tx,
                    completion_rx,
                    ..
                } = rx.recv().await.unwrap()
                else {
                    panic!("Unexpected event");
                };
                std::fs::remove_dir(&directory).unwrap();
                decision_tx.send(true).unwrap();
                completion_rx.await.unwrap();
            }
            assert_eq!(task.await.unwrap().outcome, Outcome::RetainedUnknown);
            let _ = std::fs::remove_dir(directory);
        }
    }
}
