//! Browser batch approval. Tokens never enter URLs and cannot expand a manifest.
use super::{API, DirectoryRegistry, Workspace, bad, json_response, status, validate_relative};
use crate::http::server::{
    common::{error::AppError, response::BoxedBody},
    v2::ServerEventV2,
};
use http_body_util::BodyExt;
use hyper::{Request, Response, StatusCode, body::Incoming, header};
use serde::Deserialize;
use serde_json::json;
use std::{
    collections::{HashMap, HashSet},
    sync::{Arc, Mutex},
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};
use tokio::sync::{Semaphore, mpsc, oneshot};
use tokio_util::sync::CancellationToken;
const DEADLINE: Duration = Duration::from_secs(60);
const TOKEN_TTL: Duration = Duration::from_secs(30 * 60);
const MAX_BODY: usize = 1024 * 1024;
static PENDING: Semaphore = Semaphore::const_new(16);
// Parsing capacity is independent of long-lived host decisions: a full prompt
// queue must still permit cancellation, while slow JSON bodies stay bounded.
static BODY: Semaphore = Semaphore::const_new(16);
#[derive(Clone, Deserialize)]
#[serde(deny_unknown_fields)]
struct File {
    path: String,
    size: u64,
    directory: bool,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Prepare {
    request_id: String,
    generation: u64,
    files: Vec<File>,
    #[serde(default)]
    parent: String,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Cancel {
    request_id: String,
    generation: u64,
}
struct Pending {
    peer: String,
    cookie: String,
    cancel: CancellationToken,
}
struct Approved {
    parent: String,
    request_id: String,
    peer: String,
    cookie: String,
    files: HashMap<String, (u64, bool)>,
    expires: Instant,
}
impl Approved {
    fn permits(
        &self,
        peer: &str,
        parent: &str,
        cookie: &str,
        path: &str,
        size: u64,
        directory: bool,
        now: Instant,
    ) -> bool {
        self.expires > now
            && self.parent == parent
            && self.peer == peer
            && self.cookie == cookie
            && self.files.get(path) == Some(&(size, directory))
    }
}
#[derive(Default)]
pub(super) struct Approvals {
    pending: Mutex<HashMap<String, Pending>>,
    approved: Mutex<HashMap<String, Approved>>,
}
fn cookie(req: &Request<Incoming>) -> String {
    crate::crypto::hash::sha256_hex(
        req.headers()
            .get(header::COOKIE)
            .map(|v| v.as_bytes())
            .unwrap_or(b""),
    )
}
fn identifier(id: &str) -> bool {
    uuid::Uuid::parse_str(id).is_ok_and(|v| v.get_version_num() == 4 && v.to_string() == id)
}
fn csrf(req: &Request<Incoming>, tls: bool) -> Result<(), AppError> {
    for key in [
        "x-legnasend-upload",
        "origin",
        "host",
        "sec-fetch-site",
        "content-type",
        "cookie",
    ] {
        if req.headers().get_all(key).iter().count() > 1 {
            return Err(bad());
        }
    }
    if req
        .headers()
        .get("x-legnasend-upload")
        .is_none_or(|v| v != "1")
        || req
            .headers()
            .get("sec-fetch-site")
            .is_some_and(|v| v == "cross-site")
    {
        return Err(status(StatusCode::FORBIDDEN));
    }
    if let Some(origin) = req.headers().get(header::ORIGIN) {
        let expected = format!(
            "{}://{}",
            if tls { "https" } else { "http" },
            req.headers()
                .get(header::HOST)
                .and_then(|v| v.to_str().ok())
                .unwrap_or("")
        );
        if origin.to_str().ok() != Some(expected.as_str()) {
            return Err(status(StatusCode::FORBIDDEN));
        }
    }
    if req
        .headers()
        .get(header::CONTENT_TYPE)
        .and_then(|v| v.to_str().ok())
        .is_none_or(|v| v.split(';').next().unwrap_or("").trim() != "application/json")
    {
        return Err(status(StatusCode::UNSUPPORTED_MEDIA_TYPE));
    }
    Ok(())
}
async fn body(req: &mut Request<Incoming>) -> Result<Vec<u8>, AppError> {
    let mut bytes = Vec::new();
    while let Some(frame) = req.body_mut().frame().await {
        let frame = frame.map_err(|_| bad())?;
        if let Ok(data) = frame.into_data() {
            if bytes.len() + data.len() > MAX_BODY {
                return Err(status(StatusCode::PAYLOAD_TOO_LARGE));
            }
            bytes.extend_from_slice(&data);
        }
    }
    Ok(bytes)
}
struct Guard {
    ws: Arc<Workspace>,
    id: String,
    host_id: String,
    events: mpsc::Sender<ServerEventV2>,
    armed: bool,
}
impl Drop for Guard {
    fn drop(&mut self) {
        self.ws
            .uploads
            .approvals
            .pending
            .lock()
            .unwrap()
            .remove(&self.id);
        if self.armed {
            let _ = self
                .events
                .try_send(ServerEventV2::DirectoryUploadApprovalAborted {
                    request_id: self.host_id.clone(),
                });
        }
    }
}
pub(super) async fn handle(
    registry: &Arc<DirectoryRegistry>,
    req: &mut Request<Incoming>,
    tls: bool,
    peer: &str,
) -> Result<Response<BoxedBody>, AppError> {
    let path = req
        .uri()
        .path()
        .strip_prefix(&format!("{API}/"))
        .unwrap_or("")
        .to_string();
    let parts: Vec<_> = path.split('/').collect();
    if parts.len() != 2 || req.uri().query().is_some() {
        return Err(bad());
    }
    let ws = registry.workspace(parts[0]).await?;
    csrf(req, tls)?;
    if !ws.config.allow_upload {
        return Err(status(StatusCode::FORBIDDEN));
    }
    let grant = ws.access.authorize(req.headers(), &ws.config.id)?;
    let fingerprint = cookie(req);

    let began = Instant::now();
    let body_permit = BODY
        .try_acquire()
        .map_err(|_| status(StatusCode::TOO_MANY_REQUESTS))?;
    let bytes = tokio::time::timeout(Duration::from_secs(10), body(req))
        .await
        .map_err(|_| status(StatusCode::REQUEST_TIMEOUT))??;
    drop(body_permit);
    if parts[1] == "cancel-upload-approval" {
        let payload: Cancel = serde_json::from_slice(&bytes).map_err(|_| bad())?;
        if !identifier(&payload.request_id) || payload.generation != ws.config.generation {
            return Err(bad());
        }
        if let Some(p) = ws
            .uploads
            .approvals
            .pending
            .lock()
            .unwrap()
            .get(&payload.request_id)
        {
            if p.peer == peer && p.cookie == fingerprint {
                p.cancel.cancel();
            }
        }
        ws.uploads
            .approvals
            .approved
            .lock()
            .unwrap()
            .retain(|_, p| {
                p.request_id != payload.request_id || p.peer != peer || p.cookie != fingerprint
            });
        return Ok(json_response(json!({"cancelled":true})));
    }
    let _permit = PENDING
        .try_acquire()
        .map_err(|_| status(StatusCode::TOO_MANY_REQUESTS))?;
    let payload: Prepare = serde_json::from_slice(&bytes).map_err(|_| bad())?;
    if !identifier(&payload.request_id) || payload.files.is_empty() || payload.files.len() > 10000 {
        return Err(bad());
    }
    if payload.generation != ws.config.generation {
        return Err(status(StatusCode::CONFLICT));
    }
    if !ws.config.upload_approval {
        return Err(status(StatusCode::CONFLICT));
    }
    super::upload::validate_parent(&ws, &payload.parent)?;
    let mut names = HashSet::new();
    let mut total = 0u64;
    for f in &payload.files {
        validate_relative(&f.path)?;
        if f.path.is_empty()
            || f.path.split('/').count() > 64
            || f.path.split('/').any(|v| v.len() > 255)
            || !names.insert(&f.path)
            || f.size > 9_007_199_254_740_991
            || f.directory && f.size != 0
        {
            return Err(bad());
        }
        total = total
            .checked_add(f.size)
            .filter(|n| *n <= 9_007_199_254_740_991)
            .ok_or_else(bad)?;
    }
    let file_count = names.len();
    drop(names);
    let events = registry
        .events
        .clone()
        .ok_or_else(|| status(StatusCode::SERVICE_UNAVAILABLE))?;
    let cancel = ws.uploads.stopped.child_token();
    {
        let mut pending = ws.uploads.approvals.pending.lock().unwrap();
        if pending.len() >= 2 {
            return Err(status(StatusCode::TOO_MANY_REQUESTS));
        }
        if pending.contains_key(&payload.request_id) {
            return Err(status(StatusCode::CONFLICT));
        }
        pending.insert(
            payload.request_id.clone(),
            Pending {
                peer: peer.into(),
                cookie: fingerprint.clone(),
                cancel: cancel.clone(),
            },
        );
    }
    // Client request IDs are scoped to a workspace. The host event bridge uses
    // one process-wide map, so it needs its own non-client-controlled identity.
    let host_id = uuid::Uuid::new_v4().to_string();
    let mut guard = Guard {
        ws: ws.clone(),
        id: payload.request_id.clone(),
        host_id: host_id.clone(),
        events: events.clone(),
        armed: true,
    };
    {
        let mut approved = ws.uploads.approvals.approved.lock().unwrap();
        approved.retain(|_, p| p.expires > Instant::now() && !p.files.is_empty());
        if approved.len() >= 16 {
            return Err(status(StatusCode::TOO_MANY_REQUESTS));
        }
        if approved
            .values()
            .any(|v| v.request_id == payload.request_id)
        {
            return Err(status(StatusCode::CONFLICT));
        }
    }
    let (tx, rx) = oneshot::channel();
    let expires_at = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis()
        + DEADLINE.saturating_sub(began.elapsed()).as_millis();
    let detail = json!({"requestId":host_id,"workspaceId":ws.config.id,"workspaceName":ws.config.name,"parent":payload.parent,"peerIp":peer,"expiresAt":expires_at as u64,"files":payload.files.iter().map(|f|json!({"path":f.path,"size":f.size,"directory":f.directory})).collect::<Vec<_>>()});
    events
        .try_send(ServerEventV2::DirectoryUploadApproval {
            request_id: host_id,
            request: detail.to_string(),
            decision_tx: tx,
        })
        .map_err(|_| status(StatusCode::SERVICE_UNAVAILABLE))?;
    let revoked = async {
        if let Some(grant) = &grant {
            tokio::select! {_=grant.cancel.cancelled()=>{},_=tokio::time::sleep_until(grant.expires.into())=>{}}
        } else {
            std::future::pending::<()>().await;
        }
    };
    let accepted = tokio::select! {biased;_=cancel.cancelled()=>return Err(status(StatusCode::CONFLICT)),_=ws.stopped.cancelled()=>return Err(status(StatusCode::CONFLICT)),_=revoked=>return Err(status(StatusCode::UNAUTHORIZED)),_=tokio::time::sleep(DEADLINE.saturating_sub(began.elapsed()))=>return Err(status(StatusCode::REQUEST_TIMEOUT)),decision=rx=>decision.map_err(|_|status(StatusCode::SERVICE_UNAVAILABLE))?};
    if !accepted {
        return Err(status(StatusCode::FORBIDDEN));
    }
    if cancel.is_cancelled() || ws.stopped.is_cancelled() {
        return Err(status(StatusCode::CONFLICT));
    }
    let token = format!(
        "{}{}",
        uuid::Uuid::new_v4().simple(),
        uuid::Uuid::new_v4().simple()
    );
    let mut approved = ws.uploads.approvals.approved.lock().unwrap();
    approved.retain(|_, p| p.expires > Instant::now() && !p.files.is_empty());
    if approved.len() >= 16 {
        return Err(status(StatusCode::TOO_MANY_REQUESTS));
    }
    if cancel.is_cancelled() || ws.stopped.is_cancelled() {
        return Err(status(StatusCode::CONFLICT));
    }
    if grant
        .as_ref()
        .is_some_and(|g| g.cancel.is_cancelled() || g.expires <= Instant::now())
    {
        return Err(status(StatusCode::UNAUTHORIZED));
    }
    approved.insert(
        token.clone(),
        Approved {
            parent: payload.parent,
            request_id: payload.request_id,
            peer: peer.into(),
            cookie: fingerprint,
            files: payload
                .files
                .into_iter()
                .map(|f| (f.path, (f.size, f.directory)))
                .collect(),
            expires: Instant::now() + TOKEN_TTL,
        },
    );
    drop(approved);
    guard.armed = false;
    Ok(json_response(
        json!({"token":token,"expiresIn":TOKEN_TTL.as_secs(),"fileCount":file_count,"totalBytes":total}),
    ))
}
pub(super) fn consume(
    ws: &Workspace,
    req: &Request<Incoming>,
    peer: &str,
    parent: &str,
    path: &str,
    size: u64,
    directory: bool,
) -> Result<(), AppError> {
    let token = req
        .headers()
        .get("x-legnasend-upload-token")
        .and_then(|v| v.to_str().ok())
        .ok_or_else(|| status(StatusCode::PRECONDITION_REQUIRED))?;
    let mut approved = ws.uploads.approvals.approved.lock().unwrap();
    let record = approved
        .get_mut(token)
        .ok_or_else(|| status(StatusCode::PRECONDITION_REQUIRED))?;
    if !record.permits(
        peer,
        parent,
        &cookie(req),
        path,
        size,
        directory,
        Instant::now(),
    ) {
        return Err(status(StatusCode::PRECONDITION_REQUIRED));
    }
    record.files.remove(path);
    if record.files.is_empty() {
        approved.remove(token);
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn body_admission_is_bounded_and_independent_of_pending_host_capacity() {
        let pending: Vec<_> = (0..16).map(|_| PENDING.try_acquire().unwrap()).collect();
        let bodies: Vec<_> = (0..16).map(|_| BODY.try_acquire().unwrap()).collect();
        assert!(BODY.try_acquire().is_err());
        drop(bodies);
        // A full host queue must not prevent parsing its cancellation requests.
        let cancel_body = BODY.try_acquire().unwrap();
        drop(cancel_body);
        drop(pending);
        assert_eq!(BODY.available_permits(), 16);
        assert_eq!(PENDING.available_permits(), 16);
    }
    #[test]
    fn upload_token_is_bound_to_peer_cookie_exact_manifest_and_deadline() {
        let now = Instant::now();
        let record = Approved {
            parent: String::new(),
            request_id: uuid::Uuid::new_v4().to_string(),
            peer: "192.0.2.10".into(),
            cookie: "cookie-digest".into(),
            files: HashMap::from([
                ("folder/你好.txt".into(), (4, false)),
                ("empty".into(), (0, true)),
            ]),
            expires: now + TOKEN_TTL,
        };
        assert!(record.permits(
            "192.0.2.10",
            "",
            "cookie-digest",
            "folder/你好.txt",
            4,
            false,
            now
        ));
        assert!(!record.permits(
            "192.0.2.11",
            "",
            "cookie-digest",
            "folder/你好.txt",
            4,
            false,
            now
        ));
        assert!(!record.permits(
            "192.0.2.10",
            "",
            "different",
            "folder/你好.txt",
            4,
            false,
            now
        ));
        assert!(!record.permits(
            "192.0.2.10",
            "",
            "cookie-digest",
            "other.txt",
            4,
            false,
            now
        ));
        assert!(!record.permits(
            "192.0.2.10",
            "",
            "cookie-digest",
            "folder/你好.txt",
            5,
            false,
            now
        ));
        assert!(!record.permits("192.0.2.10", "", "cookie-digest", "empty", 0, false, now));
        assert!(record.permits("192.0.2.10", "", "cookie-digest", "empty", 0, true, now));
        assert!(!record.permits(
            "192.0.2.10",
            "",
            "cookie-digest",
            "folder/你好.txt",
            4,
            false,
            now + TOKEN_TTL
        ));
        assert!(!record.permits(
            "192.0.2.10",
            "",
            "cookie-digest",
            "folder/你好.txt",
            4,
            false,
            now + TOKEN_TTL + Duration::from_secs(1)
        ));
        assert!(!record.permits(
            "192.0.2.10",
            "22222222-2222-4222-8222-222222222222",
            "cookie-digest",
            "empty",
            0,
            true,
            now
        ));
        assert_eq!(record.files.len(), 2); // failed probes never consume a legitimate manifest entry
    }
}
