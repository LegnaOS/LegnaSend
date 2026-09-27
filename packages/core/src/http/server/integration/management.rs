//! Persisted host management. Core never edits an ephemeral directory registry
//! as a substitute for a durable application mutation.
use super::{
    contract::Operation,
    policy::{Denied, Lease, UploadAuthority},
};
use crate::http::server::{
    AppState,
    common::response::{BoxedBody, JsonResponse},
    v2::ServerEventV2,
};
use http_body_util::BodyExt;
use hyper::{Request, Response, StatusCode, body::Incoming, header};
use serde_json::{Value, json};
use std::{
    collections::HashMap,
    sync::{
        Arc, Mutex,
        atomic::{AtomicU8, Ordering},
    },
    time::Duration,
};
use tokio::sync::{Semaphore, oneshot};
static PENDING: Semaphore = Semaphore::const_new(32);
const DEADLINE: Duration = Duration::from_secs(30);

struct State {
    phase: AtomicU8, // 0 offered, 1 claimed, 2 cancelled, 3 claimed response, 4 preclaim rejection
    authority: Mutex<Option<UploadAuthority>>,
}
struct Inner {
    id: String,
    request: String,
    state: Arc<State>,
    result: Mutex<Option<oneshot::Sender<Value>>>,
}
/// An owned host request; dropping its last handle declines unsupported work.
/// `claim` is the authorization linearization point. Once claimed, the host must
/// finish or reconcile its durable mutation even when `is_closed` becomes true.
#[derive(Clone)]
pub struct PendingManagement(Arc<Inner>);
impl std::fmt::Debug for PendingManagement {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("PendingManagement")
            .field("id", &self.0.id)
            .finish_non_exhaustive()
    }
}
impl PendingManagement {
    pub fn id(&self) -> String {
        self.0.id.clone()
    }
    pub fn request_json(&self) -> String {
        self.0.request.clone()
    }
    pub fn is_claimed(&self) -> bool {
        matches!(self.0.state.phase.load(Ordering::Acquire), 1 | 3)
    }
    pub fn is_closed(&self) -> bool {
        self.0
            .result
            .lock()
            .unwrap()
            .as_ref()
            .is_none_or(|tx| tx.is_closed())
            || self.0.state.phase.load(Ordering::Acquire) == 2
    }
    pub fn claim(&self) -> bool {
        if self.is_closed() {
            return false;
        }
        let authority = self.0.state.authority.lock().unwrap();
        let Some(authority) = authority.as_ref() else {
            return false;
        };
        authority
            .claim_management(|| {
                if self.is_closed()
                    || self
                        .0
                        .state
                        .phase
                        .compare_exchange(0, 1, Ordering::AcqRel, Ordering::Acquire)
                        .is_err()
                {
                    return Ok(false);
                }
                Ok(true)
            })
            .unwrap_or(false)
    }
    pub fn respond(&self, response: String) -> Result<(), String> {
        let request: Value = serde_json::from_str(&self.0.request)
            .map_err(|_| "Invalid internal management request")?;
        let transfer = request["operation"]
            .as_str()
            .is_some_and(|s| s.starts_with("transfer."));
        let host = request["operation"]
            .as_str()
            .is_some_and(|s| s.starts_with("host."));
        let keys = request["operation"]
            .as_str()
            .is_some_and(|s| s.starts_with("keys."));
        let native_tasks = request["operation"]
            .as_str()
            .is_some_and(|s| s.starts_with("nativeTasks."));
        let value = if native_tasks {
            super::native_tasks::validate_response(&response, &request)
        } else if keys {
            super::key_management::validate_response(&response, &request)
        } else if host {
            super::host_management::validate_response(&response, &request)
        } else if transfer {
            super::transfer_management::validate_response(&response, &request)
        } else {
            validate_response(&response)
        }
        .map_err(str::to_owned)?;
        let allowed = |id: &str| {
            request["workspaces"]
                .as_array()
                .is_some_and(|ids| ids.iter().any(|value| value == "*" || value == id))
        };
        let body = &value["body"];
        if !transfer && !host && !keys && !native_tasks {
            if let Some(items) = body["workspaces"].as_array() {
                let mut seen = std::collections::HashSet::new();
                if !items.iter().all(|item| {
                    item["id"]
                        .as_str()
                        .is_some_and(|id| allowed(id) && seen.insert(id))
                }) {
                    return Err("Management response exceeds workspace grant".into());
                }
            }
            for item in [&body["workspace"]["id"], &body["id"]] {
                if let Some(id) = item.as_str() {
                    if !allowed(id)
                        || request["workspaceId"]
                            .as_str()
                            .is_some_and(|expected| expected != id)
                    {
                        return Err("Management response has wrong workspace identity".into());
                    }
                }
            }
            let operation = request["operation"].as_str().unwrap_or("");
            let shape = if value["status"] == 200 {
                let object = body.as_object().unwrap();
                match operation {
                    "list" => object.len() == 1 && body["workspaces"].is_array(),
                    "sources" => object.len() == 1 && body["sources"].is_array(),
                    "destroy" => {
                        object.len() == 2 && body["id"].is_string() && body["destroyed"] == true
                    }
                    _ => object.len() == 1 && body["workspace"].is_object(),
                }
            } else {
                body["error"].is_object()
            };
            if !shape {
                return Err("Management response shape does not match operation".into());
            }
        }
        if matches!(value["status"].as_u64(), Some(200 | 202)) && !self.is_claimed() {
            return Err("Management request was not claimed".into());
        }
        let phase = self.0.state.phase.load(Ordering::Acquire);
        if phase == 2 || phase == 3 || phase == 4 {
            return Err("Management request already closed".into());
        }
        let finished = if phase == 1 { 3 } else { 4 };
        self.0
            .state
            .phase
            .compare_exchange(phase, finished, Ordering::AcqRel, Ordering::Acquire)
            .map_err(|_| "Management request changed before response".to_owned())?;
        let sender = self
            .0
            .result
            .lock()
            .unwrap()
            .take()
            .ok_or("Management response already consumed")?;
        let result = sender.send(value).map_err(|_| {
            "Management response is no longer awaited; reconcile durable state".into()
        });
        self.0.state.authority.lock().unwrap().take();
        result
    }
}
struct CancelOnDrop(Arc<State>);
impl Drop for CancelOnDrop {
    fn drop(&mut self) {
        if self
            .0
            .phase
            .compare_exchange(0, 2, Ordering::AcqRel, Ordering::Acquire)
            .is_ok()
        {
            self.0.authority.lock().unwrap().take();
        }
    }
}
fn safe_string(value: &Value, max: usize) -> bool {
    value
        .as_str()
        .is_some_and(|s| s.len() <= max && !s.chars().any(char::is_control))
}
fn metadata(value: &Value) -> bool {
    let Some(fields) = value.as_object() else {
        return false;
    };
    fields.keys().all(|key| {
        matches!(
            key.as_str(),
            "id" | "name"
                | "slug"
                | "generation"
                | "enabled"
                | "visible"
                | "allowUpload"
                | "passwordProtected"
                | "invalidReason"
        )
    }) && fields.iter().all(|(key, value)| match key.as_str() {
        "id" => value
            .as_str()
            .is_some_and(|v| uuid::Uuid::parse_str(v).is_ok()),
        "name" => safe_string(value, 480),
        "slug" => safe_string(value, 48),
        "generation" => value.as_u64().is_some_and(|v| v > 0),
        "invalidReason" => {
            value.is_null()
                || value.as_str().is_some_and(|v| {
                    [
                        "missing",
                        "notDirectory",
                        "permissionDenied",
                        "grantUnavailable",
                        "ioError",
                        "timeout",
                    ]
                    .contains(&v)
                })
        }
        _ => value.is_boolean(),
    }) && [
        "id",
        "name",
        "slug",
        "generation",
        "enabled",
        "visible",
        "allowUpload",
        "passwordProtected",
        "invalidReason",
    ]
    .iter()
    .all(|key| fields.contains_key(*key))
}
pub(super) fn stable_code(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 80
        && value
            .bytes()
            .all(|c| c.is_ascii_lowercase() || c == b'_' || c.is_ascii_digit())
}
fn validate_response(raw: &str) -> Result<Value, &'static str> {
    if raw.len() > 256 * 1024 {
        return Err("Management response too large");
    }
    let value: Value = serde_json::from_str(raw).map_err(|_| "Invalid management response")?;
    let Some(envelope) = value.as_object() else {
        return Err("Invalid management envelope");
    };
    if envelope.len() != 2
        || !matches!(
            value["status"].as_u64(),
            Some(200 | 400 | 404 | 409 | 422 | 500 | 503)
        )
    {
        return Err("Invalid management status");
    }
    let Some(body) = value["body"].as_object() else {
        return Err("Invalid management body");
    };
    let valid = body.iter().all(|(key, value)| match key.as_str() {
        "sources" => value.as_array().is_some_and(|items| {
            items.len() <= 64
                && items.iter().all(|item| {
                    item.as_object().is_some_and(|row| {
                        row.len() == 3
                            && row
                                .get("id")
                                .and_then(Value::as_str)
                                .is_some_and(|id| uuid::Uuid::parse_str(id).is_ok())
                            && row.get("name").is_some_and(|name| safe_string(name, 480))
                            && row.get("kind").and_then(Value::as_str).is_some_and(|kind| {
                                ["directory", "androidTree", "appleBookmark"].contains(&kind)
                            })
                    })
                })
        }),
        "workspaces" => value
            .as_array()
            .is_some_and(|items| items.len() <= 256 && items.iter().all(metadata)),
        "workspace" => metadata(value),
        "id" => value
            .as_str()
            .is_some_and(|v| uuid::Uuid::parse_str(v).is_ok()),
        "destroyed" => value == true,
        "error" => value.as_object().is_some_and(|v| {
            v.len() == 1
                && v.get("code")
                    .and_then(Value::as_str)
                    .is_some_and(stable_code)
        }),
        _ => false,
    });
    if !valid || body.is_empty() {
        return Err("Unsafe management response fields");
    }
    Ok(value)
}
fn request(
    operation: Operation,
    workspace: Option<&str>,
    query: &HashMap<String, String>,
    lease: &Lease,
    payload: Option<Value>,
) -> Result<Value, Denied> {
    let mut value = json!({"operation":"list","workspaces":lease.grant.workspaces});
    if matches!(
        operation,
        Operation::ManagedWorkspaces | Operation::ApprovedSources
    ) {
        if payload.is_some() {
            return Err(Denied::new(400, "unexpected_body"));
        }
        if operation == Operation::ApprovedSources {
            if !lease.grant.workspaces.iter().any(|id| id == "*") {
                return Err(Denied::new(403, "wildcard_management_required"));
            }
            value["operation"] = json!("sources");
        }
        return Ok(value);
    }
    if operation == Operation::CreateWorkspace {
        if !lease.grant.workspaces.iter().any(|id| id == "*") {
            return Err(Denied::new(403, "wildcard_management_required"));
        }
        let body = payload
            .and_then(|v| v.as_object().cloned())
            .ok_or_else(|| Denied::new(400, "invalid_body"))?;
        if body.keys().any(|key| {
            !["sourceId", "name", "slug", "visible", "allowUpload"].contains(&key.as_str())
        }) || !body
            .get("sourceId")
            .and_then(Value::as_str)
            .is_some_and(|id| uuid::Uuid::parse_str(id).is_ok())
            || !body.get("name").is_some_and(|v| {
                safe_string(v, 480) && v.as_str().is_some_and(|v| !v.trim().is_empty())
            })
            || !body
                .get("slug")
                .is_some_and(|v| safe_string(v, 48) && v.as_str().is_some_and(|v| !v.is_empty()))
            || ["visible", "allowUpload"]
                .iter()
                .any(|key| body.get(*key).is_some_and(|v| !v.is_boolean()))
        {
            return Err(Denied::new(400, "invalid_body"));
        }
        value["operation"] = json!("create");
        value.as_object_mut().unwrap().extend(body);
        return Ok(value);
    }
    let id = workspace.ok_or_else(|| Denied::new(400, "invalid_query"))?;
    if uuid::Uuid::parse_str(id).is_err() {
        return Err(Denied::new(400, "invalid_query"));
    }
    if !lease.grant.allows(id) {
        return Err(Denied::new(403, "insufficient_workspace"));
    }
    let generation = query
        .get("generation")
        .and_then(|s| s.parse::<u64>().ok())
        .filter(|v| *v > 0)
        .ok_or_else(|| Denied::new(400, "invalid_query"))?;
    let action = query
        .get("action")
        .map(String::as_str)
        .ok_or_else(|| Denied::new(400, "invalid_query"))?;
    if ![
        "update",
        "enable",
        "disable",
        "validate",
        "destroy",
        "configure",
        "password",
    ]
    .contains(&action)
    {
        return Err(Denied::new(400, "invalid_query"));
    }
    value["operation"] = json!(action);
    value["workspaceId"] = json!(id);
    value["generation"] = json!(generation);
    let mut changed = false;
    for name in ["name", "visible", "allowUpload"] {
        if let Some(text) = query.get(name) {
            if action != "update" {
                return Err(Denied::new(400, "invalid_query"));
            }
            value[name] = if name == "name" {
                if text.trim().is_empty() || text.len() > 480 || text.chars().any(char::is_control)
                {
                    return Err(Denied::new(400, "invalid_query"));
                }
                json!(text)
            } else {
                match text.as_str() {
                    "true" => json!(true),
                    "false" => json!(false),
                    _ => return Err(Denied::new(400, "invalid_query")),
                }
            };
            changed = true;
        }
    }
    if matches!(action, "configure" | "password") {
        let body = payload
            .and_then(|v| v.as_object().cloned())
            .ok_or_else(|| Denied::new(400, "invalid_body"))?;
        if action == "configure" {
            if body.is_empty()
                || body
                    .keys()
                    .any(|key| !["sourceId", "slug"].contains(&key.as_str()))
                || body.get("sourceId").is_some_and(|v| {
                    !v.as_str()
                        .is_some_and(|id| uuid::Uuid::parse_str(id).is_ok())
                })
                || body
                    .get("slug")
                    .is_some_and(|v| !safe_string(v, 48) || v == "")
            {
                return Err(Denied::new(400, "invalid_body"));
            }
        } else {
            let set = body.len() == 1
                && body.get("password").is_some_and(|v| {
                    safe_string(v, 1024)
                        && v.as_str()
                            .is_some_and(|v| (4..=128).contains(&v.chars().count()))
                });
            let clear = body.len() == 1 && body.get("clear") == Some(&json!(true));
            if !set && !clear {
                return Err(Denied::new(400, "invalid_body"));
            }
        }
        value.as_object_mut().unwrap().extend(body);
    } else if payload.is_some() {
        return Err(Denied::new(400, "unexpected_body"));
    }
    if action == "update" && !changed {
        return Err(Denied::new(400, "invalid_query"));
    }
    Ok(value)
}
pub(super) async fn read_body(req: &mut Request<Incoming>) -> Result<Option<Value>, Denied> {
    read_body_limit(req, 8192).await
}
pub(super) async fn read_body_limit(
    req: &mut Request<Incoming>,
    limit: usize,
) -> Result<Option<Value>, Denied> {
    if req.headers().get_all(header::CONTENT_TYPE).iter().count() > 1 {
        return Err(Denied::new(400, "invalid_body"));
    }
    let mut bytes = Vec::new();
    tokio::time::timeout(Duration::from_secs(5), async {
        while let Some(frame) = req.body_mut().frame().await {
            let frame = frame.map_err(|_| Denied::new(400, "invalid_body"))?;
            if let Some(data) = frame.data_ref() {
                if bytes.len() + data.len() > limit {
                    return Err(Denied::new(413, "body_too_large"));
                }
                bytes.extend_from_slice(data);
            }
        }
        Ok(())
    })
    .await
    .map_err(|_| Denied::new(408, "body_timeout"))??;
    if bytes.is_empty() {
        return Ok(None);
    }
    if req
        .headers()
        .get(header::CONTENT_TYPE)
        .and_then(|v| v.to_str().ok())
        .map(|v| v.split(';').next().unwrap_or("").trim())
        != Some("application/json")
    {
        return Err(Denied::new(415, "unsupported_media_type"));
    }
    serde_json::from_slice(&bytes)
        .map(Some)
        .map_err(|_| Denied::new(400, "invalid_body"))
}

pub(super) async fn execute(
    state: &AppState,
    operation: Operation,
    workspace: Option<&str>,
    query: HashMap<String, String>,
    lease: &Lease,
    payload: Option<Value>,
) -> Result<Response<BoxedBody>, Denied> {
    if operation == Operation::WorkspaceSend
        && payload.as_ref().and_then(|b| b["instanceId"].as_str())
            != Some(state.integration.instance_id.as_str())
    {
        return Err(Denied::new(409, "service_instance_changed"));
    }
    let request = if operation.is_native_tasks() {
        super::native_tasks::request(operation, workspace, lease, payload)?
    } else if operation.is_keys() {
        super::key_management::request(operation, workspace, lease, payload)?
    } else if operation.is_host() {
        super::host_management::request(operation, lease, payload)?
    } else if operation.is_transfer() {
        super::transfer_management::request(operation, workspace, lease, payload)?
    } else {
        request(operation, workspace, &query, lease, payload)?
    };
    let authority = (if operation.is_transfer()
        || operation.is_host()
        || operation.is_keys()
        || operation.is_native_tasks()
    {
        lease.transfer_authority(operation.scope())
    } else {
        lease.management_authority()
    })
    .ok_or_else(|| Denied::new(403, "management_key_required"))?;
    if !state
        .integration
        .management_available
        .load(Ordering::Acquire)
    {
        return Err(Denied::new(503, "host_unavailable"));
    }
    let v2 = state
        .v2
        .as_ref()
        .ok_or_else(|| Denied::new(503, "host_unavailable"))?;
    let _permit = PENDING
        .try_acquire()
        .map_err(|_| Denied::new(429, "management_busy"))?;
    let (tx, rx) = oneshot::channel();
    let phase = Arc::new(State {
        phase: AtomicU8::new(0),
        authority: Mutex::new(Some(authority.clone())),
    });
    let _cancel_on_drop = CancelOnDrop(phase.clone());
    let event = ServerEventV2::WorkspaceManagement {
        request: PendingManagement(Arc::new(Inner {
            id: lease.id.clone(),
            request: request.to_string(),
            state: phase.clone(),
            result: Mutex::new(Some(tx)),
        })),
    };
    let cancelled = async {
        let expiry = async {
            if let Some(expiry) = authority.expires {
                loop {
                    let now = super::policy::unix_time();
                    if now >= expiry {
                        break;
                    }
                    tokio::time::sleep(Duration::from_secs((expiry - now).min(1))).await
                }
            } else {
                std::future::pending::<()>().await
            }
        };
        tokio::select! {_=authority.cancel.cancelled()=>{},_=expiry=>{}}
    };
    let work = async {
        v2.event_tx
            .send(event)
            .await
            .map_err(|_| Denied::new(503, "host_unavailable"))?;
        rx.await.map_err(|_| {
            Denied::new(
                503,
                if matches!(phase.phase.load(Ordering::Acquire), 1 | 3) {
                    "outcome_unknown"
                } else {
                    "host_unavailable"
                },
            )
        })
    };
    let result = tokio::select! {biased;_=cancelled=>Err(Denied::new(if matches!(phase.phase.load(Ordering::Acquire),1|3){503}else{401},if matches!(phase.phase.load(Ordering::Acquire),1|3){"outcome_unknown"}else{"revoked"})), result=tokio::time::timeout(DEADLINE,work)=>result.unwrap_or_else(|_|Err(Denied::new(504,if matches!(phase.phase.load(Ordering::Acquire),1|3){"outcome_unknown"}else{"host_timeout"})))}?;
    let mut body = result["body"].clone();
    if let Some(error) = body.get_mut("error").and_then(Value::as_object_mut) {
        error.insert("requestId".into(), json!(lease.id));
    }
    Ok(JsonResponse {
        status: StatusCode::from_u16(result["status"].as_u64().unwrap() as u16).unwrap(),
        body,
    }
    .into_response())
}

#[cfg(test)]
mod tests {
    use super::super::policy::{ApiConfig, Scope, WorkspaceGrant, create_key};
    use super::*;
    use crate::http::server::{ServerConfigV2, web::WebConfig};
    use crate::http::state::ClientInfo;
    fn fixture() -> (AppState, Lease, tokio::sync::mpsc::Receiver<ServerEventV2>) {
        let (tx, rx) = tokio::sync::mpsc::channel(1);
        let state = AppState::new(
            Arc::new(tokio::sync::Mutex::new(ClientInfo {
                alias: "test".into(),
                version: "2.2".into(),
                device_model: None,
                device_type: None,
                token: "fixture".into(),
            })),
            None,
            Some(ServerConfigV2 {
                pin: None,
                verify_checksums: false,
                event_tx: tx,
            }),
            WebConfig::default(),
            false,
            crate::http::server::WebActivityHistory::default(),
        );
        state
            .integration
            .management_available
            .store(true, Ordering::Release);
        let key = create_key(
            "test".into(),
            WorkspaceGrant {
                scopes: vec![Scope::Manage],
                workspaces: vec!["*".into()],
            },
            None,
        )
        .unwrap();
        let config = ApiConfig {
            revision: 1,
            enabled: true,
            keys: vec![key.record],
            ..ApiConfig::default()
        };
        state
            .integration
            .configure(&serde_json::to_string(&config).unwrap())
            .unwrap();
        let mut headers = hyper::HeaderMap::new();
        headers.insert(
            hyper::header::AUTHORIZATION,
            format!("Bearer {}", key.secret).parse().unwrap(),
        );
        let (lease, error) = state
            .integration
            .admit(
                &headers,
                "127.0.0.1".into(),
                uuid::Uuid::new_v4().to_string(),
                "listManagedWorkspaces",
                "GET",
                false,
            )
            .unwrap_or_else(|_| panic!("admission failed"));
        assert!(error.is_none());
        (state, lease, rx)
    }
    #[tokio::test(start_paused = true)]
    async fn timeout_releases_unclaimed_quota_even_when_host_keeps_stale_handle() {
        let (state, lease, mut events) = fixture();
        let registry = state.integration.clone();
        let task = tokio::spawn(async move {
            execute(
                &state,
                Operation::ManagedWorkspaces,
                None,
                HashMap::new(),
                &lease,
                None,
            )
            .await
        });
        let Some(ServerEventV2::WorkspaceManagement { request }) = events.recv().await else {
            panic!("missing host request")
        };
        tokio::time::advance(Duration::from_secs(31)).await;
        let result = task.await.unwrap();
        assert!(matches!(
            result,
            Err(Denied {
                status: 504,
                code: "host_timeout",
                ..
            })
        ));
        assert!(request.is_closed());
        assert!(!request.claim());
        assert_eq!(registry.snapshot()["activeResponses"], 0);
    }
    #[tokio::test(start_paused = true)]
    async fn claimed_timeout_is_unknown_and_keeps_quota_until_host_finishes() {
        let (state, lease, mut events) = fixture();
        let registry = state.integration.clone();
        let task = tokio::spawn(async move {
            execute(
                &state,
                Operation::ManagedWorkspaces,
                None,
                HashMap::new(),
                &lease,
                None,
            )
            .await
        });
        let Some(ServerEventV2::WorkspaceManagement { request }) = events.recv().await else {
            panic!("missing host request")
        };
        assert!(request.claim());
        tokio::time::advance(Duration::from_secs(31)).await;
        let result = task.await.unwrap();
        assert!(matches!(
            result,
            Err(Denied {
                status: 504,
                code: "outcome_unknown",
                ..
            })
        ));
        assert!(request.is_closed());
        assert!(request.is_claimed());
        assert_eq!(registry.snapshot()["activeResponses"], 1);
        assert!(
            request
                .respond(json!({"status":200,"body":{"workspaces":[]}}).to_string())
                .is_err()
        );
        assert_eq!(registry.snapshot()["activeResponses"], 0);
    }
    #[tokio::test(start_paused = true)]
    async fn host_deadline_includes_event_queue_backpressure() {
        let (state, lease, mut events) = fixture();
        state
            .v2
            .as_ref()
            .unwrap()
            .event_tx
            .send(ServerEventV2::ListenerFailed {
                error: "occupy".into(),
            })
            .await
            .unwrap();
        let task = tokio::spawn(async move {
            execute(
                &state,
                Operation::ManagedWorkspaces,
                None,
                HashMap::new(),
                &lease,
                None,
            )
            .await
        });
        tokio::task::yield_now().await;
        tokio::time::advance(Duration::from_secs(31)).await;
        assert!(matches!(
            task.await.unwrap(),
            Err(Denied {
                status: 504,
                code: "host_timeout",
                ..
            })
        ));
        assert!(matches!(
            events.recv().await,
            Some(ServerEventV2::ListenerFailed { .. })
        ));
        assert!(events.try_recv().is_err());
    }
}
