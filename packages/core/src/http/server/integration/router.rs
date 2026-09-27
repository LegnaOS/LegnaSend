use super::{
    PREFIX,
    contract::{self, Operation},
    policy::{Denied, Lease, unix_time},
};
use crate::http::server::{
    AppState, RequestClientInfo,
    common::{
        error::AppError,
        response::{self, BoxedBody, JsonResponse},
    },
};
use bytes::Bytes;
use http_body_util::BodyExt;
use hyper::{
    Method, Request, Response, StatusCode,
    body::{Body, Frame, Incoming, SizeHint},
    header,
};
use serde_json::{Value, json};
use std::{
    collections::HashMap,
    pin::Pin,
    task::{Context, Poll},
    time::Duration,
};

pub(crate) async fn route(
    req: &mut Request<Incoming>,
    state: &AppState,
    client: &RequestClientInfo,
) -> Option<Response<BoxedBody>> {
    let path_owned = req.uri().path().to_owned();
    let path = path_owned.as_str();
    if !path.starts_with(PREFIX)
        || path.len() > PREFIX.len() && path.as_bytes()[PREFIX.len()] != b'/'
    {
        return None;
    }
    let rest = path
        .strip_prefix(PREFIX)
        .unwrap()
        .strip_prefix('/')
        .unwrap_or("");
    let operation = if rest.len() > 8192 {
        Operation::Unknown
    } else {
        Operation::identify(rest)
    };
    let id = uuid::Uuid::new_v4().to_string();
    let method = match *req.method() {
        Method::GET => "GET",
        Method::HEAD => "HEAD",
        Method::OPTIONS => "OPTIONS",
        Method::POST => "POST",
        _ => "OTHER",
    };
    let preflight = req.method() == Method::OPTIONS;
    let registry = &state.integration;
    let (mut lease, authentication) = match registry.admit(
        req.headers(),
        client.ip.to_string(),
        id.clone(),
        operation.id(),
        method,
        preflight,
    ) {
        Ok(value) => value,
        Err(denied) => {
            if registry.enabled() {
                registry.rejection(&id, operation.id(), method, &denied);
            }
            let mut response = error(&denied, &id);
            apply_origin(&mut response, origin(req, state));
            return Some(response);
        }
    };
    let origin = origin(req, state);
    let operation_future = async {
        origin
            .as_ref()
            .map_err(|_| Denied::new(403, "origin_denied"))?;
        if operation == Operation::Unknown {
            return Err(Denied::new(404, "not_found"));
        }
        if preflight {
            if req.headers().get(header::ORIGIN).is_none() {
                return Err(Denied::new(400, "invalid_preflight"));
            }
            let requested = req
                .headers()
                .get(header::ACCESS_CONTROL_REQUEST_METHOD)
                .and_then(|v| v.to_str().ok())
                .unwrap_or("");
            if !(requested == "POST" && operation.is_post())
                && !(!operation.is_post()
                    && (requested == "GET"
                        || requested == "HEAD"
                            && matches!(operation, Operation::Content | Operation::Archive)))
            {
                return Err(Denied::new(405, "method_not_allowed"));
            }
            let headers = req
                .headers()
                .get(header::ACCESS_CONTROL_REQUEST_HEADERS)
                .and_then(|v| v.to_str().ok())
                .unwrap_or("");
            if !headers
                .split(',')
                .filter(|v| !v.trim().is_empty())
                .all(|v| {
                    [
                        "authorization",
                        "range",
                        "if-match",
                        "accept",
                        "content-type",
                    ]
                    .contains(&v.trim().to_ascii_lowercase().as_str())
                })
            {
                return Err(Denied::new(403, "headers_denied"));
            }
            let mut response = Response::new(response::empty_body());
            *response.status_mut() = StatusCode::NO_CONTENT;
            response.headers_mut().insert(
                header::ACCESS_CONTROL_ALLOW_METHODS,
                (if operation.is_post() {
                    "POST, OPTIONS"
                } else if matches!(operation, Operation::Content | Operation::Archive) {
                    "GET, HEAD, OPTIONS"
                } else {
                    "GET, OPTIONS"
                })
                .parse()
                .unwrap(),
            );
            response.headers_mut().insert(
                header::ACCESS_CONTROL_ALLOW_HEADERS,
                "Authorization, Range, If-Match, Accept, Content-Type"
                    .parse()
                    .unwrap(),
            );
            response
                .headers_mut()
                .insert(header::ACCESS_CONTROL_MAX_AGE, "600".parse().unwrap());
            return Ok(response);
        }
        if let Some(error) = authentication {
            return Err(error);
        }
        if !(req.method() == Method::POST && operation.is_post())
            && !(!operation.is_post()
                && (req.method() == Method::GET
                    || req.method() == Method::HEAD
                        && matches!(operation, Operation::Content | Operation::Archive)))
        {
            return Err(Denied::new(405, "method_not_allowed"));
        }
        if !lease.grant.scopes.contains(&operation.scope()) {
            return Err(Denied::new(403, "insufficient_scope"));
        }
        if operation == Operation::WorkspaceSend
            && !lease.grant.scopes.contains(&super::Scope::Files)
        {
            return Err(Denied::new(403, "files_read_required"));
        }
        if operation == Operation::RetryTransfer
            && !lease.grant.scopes.contains(&super::Scope::TransfersSend)
        {
            return Err(Denied::new(403, "insufficient_scope"));
        }
        let query = query(req, operation)?;
        let response = match operation {
            Operation::Capabilities => json_response(
                json!({"product":"LegnaSend","version":"1.0.0","apiVersion":1,"operations":contract::OPERATIONS.iter().map(|op|op.id()).collect::<Vec<_>>(),"rangeDownload":true,"readOnly":false,"originalProtocol":format!("LocalSend {}",crate::model::discovery::PROTOCOL_VERSION_V2)}),
            ),
            Operation::Status => {
                let snapshot = registry.snapshot();
                json_response(
                    json!({"instanceId":snapshot["instanceId"],"enabled":snapshot["enabled"],"authRequired":snapshot["authRequired"],"port":snapshot["port"],"https":state.tls,"globalLimits":snapshot["globalLimits"],"keyLimits":snapshot["keyLimits"],"anonymousLimits":snapshot["anonymousLimits"],"activeResponses":snapshot["activeResponses"],"principal":lease.principal,"scopes":lease.grant.scopes,"fixedWindowSeconds":[1,60]}),
                )
            }
            Operation::OpenApi => {
                let language = query.get("lang").map(String::as_str).unwrap_or("en");
                if !["en", "zh-CN", "zh-TW", "zh-HK"].contains(&language) {
                    return Err(Denied::new(400, "invalid_query"));
                }
                let mut document = contract::document(language);
                let policy = registry.snapshot();
                if policy["authRequired"] == false {
                    for op in contract::OPERATIONS {
                        if policy["anonymousGrant"]["scopes"]
                            .as_array()
                            .is_some_and(|scopes| {
                                scopes.contains(&serde_json::to_value(op.scope()).unwrap())
                            })
                        {
                            for method in ["get", "head"] {
                                if let Some(value) = document["paths"][op.path()].get_mut(method) {
                                    value["security"] = json!([{"bearerAuth":[]},{}]);
                                }
                            }
                        }
                    }
                }
                json_response(document)
            }
            Operation::ClearRequests => {
                let body = super::management::read_body(req).await?;
                let input = super::request_history::ClearRequest::parse(body)
                    .map_err(|code| Denied::new(400, code))?;
                json_response(registry.clear_records(&lease, &input)?)
            }
            Operation::Requests => {
                let after = query
                    .get("after")
                    .map(|v| v.parse::<u64>())
                    .transpose()
                    .map_err(|_| Denied::new(400, "invalid_query"))?
                    .unwrap_or(0);
                let limit = query
                    .get("limit")
                    .map(|v| v.parse::<usize>())
                    .transpose()
                    .map_err(|_| Denied::new(400, "invalid_query"))?
                    .unwrap_or(50);
                if !(1..=100).contains(&limit) {
                    return Err(Denied::new(400, "invalid_query"));
                }
                json_response(registry.records(after, limit))
            }
            Operation::Workspaces
            | Operation::Workspace
            | Operation::Files
            | Operation::WorkspaceState
            | Operation::Content
            | Operation::Archive => {
                let parts: Vec<_> = rest.split('/').skip(1).collect();
                state
                    .directories
                    .integration(
                        req,
                        &parts,
                        query,
                        &lease.grant,
                        lease.principal.is_none(),
                        preview_authority(&lease),
                    )
                    .await
                    .map_err(map_error)?
            }
            Operation::PrepareArchive | Operation::CancelArchive => state
                .directories
                .integration_archive_selection(
                    req,
                    rest.split('/').nth(1).unwrap(),
                    query,
                    &lease.grant,
                    lease.principal.is_none(),
                    preview_authority(&lease),
                    operation == Operation::CancelArchive,
                )
                .await
                .map_err(map_error)?,
            Operation::PreparePreview | Operation::ClosePreview => state
                .directories
                .integration_preview(
                    req,
                    rest.split('/').nth(1).unwrap(),
                    query,
                    &lease.grant,
                    lease.principal.is_none(),
                    preview_authority(&lease),
                    operation == Operation::ClosePreview,
                )
                .await
                .map_err(map_error)?,
            Operation::Upload => {
                let workspace = rest.split('/').nth(1).unwrap();
                if !lease.grant.allows(workspace) {
                    return Err(Denied::new(403, "insufficient_workspace"));
                }
                let authority = lease
                    .upload_authority()
                    .ok_or_else(|| Denied::new(403, "upload_key_required"))?;
                state
                    .directories
                    .integration_upload(req, workspace, authority)
                    .await
                    .map_err(map_error)?
            }
            Operation::ManagedWorkspaces
            | Operation::ManageWorkspace
            | Operation::ApprovedSources
            | Operation::CreateWorkspace => {
                let payload = super::management::read_body(req).await?;
                super::management::execute(
                    state,
                    operation,
                    rest.split('/').nth(1),
                    query,
                    &lease,
                    payload,
                )
                .await?
            }
            op if op.is_transfer() || op.is_host() || op.is_keys() || op.is_native_tasks() => {
                let payload = super::management::read_body_limit(
                    req,
                    if operation == Operation::WorkspaceSend {
                        65536
                    } else {
                        8192
                    },
                )
                .await?;
                super::management::execute(
                    state,
                    operation,
                    rest.split('/').nth(
                        if matches!(
                            operation,
                            Operation::KeyReceipt | Operation::RetrySourceEndNotice
                        ) {
                            2
                        } else {
                            1
                        },
                    ),
                    query,
                    &lease,
                    payload,
                )
                .await?
            }
            _ => unreachable!(),
        };
        if !operation.is_management() && lease.cancel.is_cancelled() {
            return Err(Denied::new(401, "revoked"));
        }
        Ok(response)
    };
    let result = if operation.is_management() {
        operation_future.await
    } else {
        tokio::select! {
            biased;
            _ = lease.cancel.cancelled() => Err(Denied::new(401,"revoked")),
            _ = wait_expiry(lease.expires) => Err(Denied::new(401,"expired")),
            result = operation_future => result,
        }
    };
    let mut response = match result {
        Ok(response) => response,
        Err(denied) => {
            lease.error = Some(denied.code);
            lease.reason = denied.reason.clone();
            error(&denied, &id)
        }
    };
    lease.status = response.status().as_u16();
    let headers = response.headers_mut();
    headers.insert(header::CACHE_CONTROL, "no-store".parse().unwrap());
    headers.insert("x-content-type-options", "nosniff".parse().unwrap());
    headers.insert("x-legnasend-request-id", id.parse().unwrap());
    headers.insert(
        "x-legnasend-remaining-second",
        lease.remaining_second.into(),
    );
    headers.insert(
        "x-legnasend-remaining-minute",
        lease.remaining_minute.into(),
    );
    if response.status() == StatusCode::METHOD_NOT_ALLOWED {
        response.headers_mut().insert(
            header::ALLOW,
            (if operation.is_post() {
                "POST, OPTIONS"
            } else if matches!(operation, Operation::Content | Operation::Archive) {
                "GET, HEAD, OPTIONS"
            } else {
                "GET, OPTIONS"
            })
            .parse()
            .unwrap(),
        );
    }
    apply_origin(&mut response, origin);
    if req.method() == Method::HEAD || response.status() == StatusCode::NO_CONTENT {
        lease.outcome = "complete";
        drop(lease);
        *response.body_mut() = response::empty_body();
        return Some(response);
    }
    if lease.error.is_some() {
        lease.outcome = "complete";
        drop(lease);
        return Some(response);
    }
    let body = std::mem::replace(response.body_mut(), response::empty_body());
    let cancel = lease.cancel.clone();
    let expires = lease.expires;
    let source = response
        .extensions_mut()
        .remove::<tokio_util::sync::CancellationToken>()
        .unwrap_or_default();
    let expected = response
        .headers()
        .get(header::CONTENT_LENGTH)
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.parse::<u64>().ok());
    let shared = std::sync::Arc::new(std::sync::Mutex::new(BodyState {
        body,
        lease: Some(lease),
        eos: false,
        expected,
        waker: None,
    }));
    let weak = std::sync::Arc::downgrade(&shared);
    // A separate watcher releases file/limit permits even when a slow peer stops
    // polling the body. It never closes a shared HTTP/2 connection or native task.
    let watcher = tokio::spawn(async move {
        tokio::select! { _=cancel.cancelled()=>{}, _=source.cancelled()=>{}, _=wait_expiry(expires)=>{} }
        if let Some(shared) = weak.upgrade() {
            let mut state = shared.lock().unwrap();
            if source.is_cancelled() {
                if let Some(lease) = state.lease.as_mut() {
                    lease.outcome = "source_ended";
                }
            }
            state.eos = true;
            state.body = response::empty_body();
            state.lease.take();
            if let Some(waker) = state.waker.take() {
                waker.wake();
            }
        }
    });
    *response.body_mut() = GuardedBody { shared, watcher }.boxed();
    Some(response)
}
fn preview_authority(lease: &Lease) -> super::super::directory_auth::Grant {
    let seconds = lease
        .expires
        .map(|at| at.saturating_sub(unix_time()))
        .unwrap_or(3650 * 86400);
    let now = std::time::Instant::now();
    super::super::directory_auth::Grant {
        cancel: lease.cancel.clone(),
        expires: now
            .checked_add(Duration::from_secs(seconds))
            .unwrap_or(now + Duration::from_secs(3650 * 86400)),
    }
}
async fn wait_expiry(expires: Option<u64>) {
    if let Some(expiry) = expires {
        while unix_time() < expiry {
            tokio::time::sleep(Duration::from_secs(1)).await;
        }
    } else {
        std::future::pending::<()>().await;
    }
}
fn apply_origin(response: &mut Response<BoxedBody>, origin: Result<Option<String>, ()>) {
    if let Ok(Some(origin)) = origin {
        let headers = response.headers_mut();
        headers.insert(header::ACCESS_CONTROL_ALLOW_ORIGIN, origin.parse().unwrap());
        headers.insert(header::VARY, "Origin".parse().unwrap());
        headers.insert(header::ACCESS_CONTROL_EXPOSE_HEADERS,"ETag, Content-Range, Content-Disposition, Retry-After, X-LegnaSend-Request-Id, X-LegnaSend-Remaining-Second, X-LegnaSend-Remaining-Minute".parse().unwrap());
    }
}
fn query(req: &Request<Incoming>, operation: Operation) -> Result<HashMap<String, String>, Denied> {
    let raw = req.uri().query().unwrap_or("");
    if raw.len() > contract::query_byte_limit(operation) {
        return Err(Denied::new(400, "invalid_query"));
    }
    let mut map = HashMap::new();
    for (key, value) in form_urlencoded::parse(raw.as_bytes()) {
        if !operation.queries().contains(&key.as_ref())
            || !contract::valid_parameter_text(operation, &key, &value)
            || map.insert(key.into_owned(), value.into_owned()).is_some()
        {
            return Err(Denied::new(400, "invalid_query"));
        }
    }
    Ok(map)
}
fn origin(req: &Request<Incoming>, state: &AppState) -> Result<Option<String>, ()> {
    let Some(origin) = req.headers().get(header::ORIGIN) else {
        return if req
            .headers()
            .get("sec-fetch-site")
            .is_some_and(|v| v == "cross-site")
        {
            Err(())
        } else {
            Ok(None)
        };
    };
    if req.headers().get_all(header::ORIGIN).iter().count() != 1 {
        return Err(());
    }
    let origin = origin.to_str().map_err(|_| ())?;
    let host = req
        .uri()
        .authority()
        .map(|a| a.as_str())
        .or_else(|| {
            req.headers()
                .get(header::HOST)
                .and_then(|v| v.to_str().ok())
        })
        .unwrap_or("");
    let same = format!("{}://{host}", if state.tls { "https" } else { "http" });
    if origin == same
        || state
            .integration
            .origins()
            .iter()
            .any(|allowed| allowed == origin)
    {
        Ok(Some(origin.into()))
    } else {
        Err(())
    }
}
fn json_response(value: Value) -> Response<BoxedBody> {
    JsonResponse {
        status: StatusCode::OK,
        body: value,
    }
    .into_response()
}
fn map_error(error: AppError) -> Denied {
    let status = match error {
        AppError::Status(status) | AppError::Message(status, _) => status.as_u16(),
        AppError::BadRequest(_) => 400,
        AppError::Hyper(_) => 500,
    };
    Denied::new(
        status,
        match status {
            400 => "invalid_query",
            401 => "unauthorized",
            403 => "forbidden",
            404 => "not_found",
            409 => "source_changed",
            410 => "source_gone",
            411 => "length_required",
            412 => "source_changed",
            415 => "unsupported_media_type",
            416 => "range_unsatisfiable",
            429 => "storage_busy",
            _ => "internal_error",
        },
    )
}
fn error(denied: &Denied, id: &str) -> Response<BoxedBody> {
    let mut response =
        json_response(json!({"error":{"code":denied.code,"requestId":id,"reason":denied.reason}}));
    *response.status_mut() = StatusCode::from_u16(denied.status).unwrap();
    let headers = response.headers_mut();
    headers.insert(header::CACHE_CONTROL, "no-store".parse().unwrap());
    headers.insert("x-content-type-options", "nosniff".parse().unwrap());
    headers.insert("x-legnasend-request-id", id.parse().unwrap());
    if let Some((second, minute)) = denied.remaining {
        headers.insert("x-legnasend-remaining-second", second.into());
        headers.insert("x-legnasend-remaining-minute", minute.into());
    }
    if denied.status == 401 {
        headers.insert(
            header::WWW_AUTHENTICATE,
            "Bearer realm=\"LegnaSend\"".parse().unwrap(),
        );
    }
    if let Some(retry) = denied.retry {
        headers.insert(header::RETRY_AFTER, retry.into());
    } else if denied.status == 429 {
        headers.insert(header::RETRY_AFTER, "1".parse().unwrap());
    }
    if denied.status == 405 {
        headers.insert(header::ALLOW, "GET, HEAD, OPTIONS".parse().unwrap());
    }
    response
}
struct BodyState {
    body: BoxedBody,
    lease: Option<Lease>,
    eos: bool,
    expected: Option<u64>,
    waker: Option<std::task::Waker>,
}
struct GuardedBody {
    shared: std::sync::Arc<std::sync::Mutex<BodyState>>,
    watcher: tokio::task::JoinHandle<()>,
}
impl Drop for GuardedBody {
    fn drop(&mut self) {
        self.watcher.abort();
        let mut state = self.shared.lock().unwrap();
        state.eos = true;
        state.waker.take();
        state.body = response::empty_body();
        state.lease.take();
    }
}
impl Body for GuardedBody {
    type Data = Bytes;
    type Error = std::io::Error;
    fn poll_frame(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
    ) -> Poll<Option<Result<Frame<Bytes>, Self::Error>>> {
        let mut this = self.shared.lock().unwrap();
        if this.eos {
            return Poll::Ready(None);
        }
        this.waker = Some(cx.waker().clone());
        match Pin::new(&mut this.body).poll_frame(cx) {
            Poll::Ready(Some(Ok(frame))) => {
                if let Some(lease) = this.lease.as_mut() {
                    if let Some(data) = frame.data_ref() {
                        lease.bytes += data.len() as u64;
                    }
                }
                if this.body.is_end_stream()
                    || this.expected.is_some_and(|expected| {
                        this.lease
                            .as_ref()
                            .is_some_and(|lease| lease.bytes == expected)
                    })
                {
                    if let Some(lease) = this.lease.as_mut() {
                        lease.outcome = "complete";
                    }
                    this.lease.take();
                    this.eos = true;
                    self.watcher.abort();
                }
                Poll::Ready(Some(Ok(frame)))
            }
            Poll::Ready(Some(Err(error))) => {
                if let Some(lease) = this.lease.as_mut() {
                    lease.outcome = "stream_error";
                }
                this.lease.take();
                this.eos = true;
                this.body = response::empty_body();
                self.watcher.abort();
                Poll::Ready(Some(Err(error)))
            }
            Poll::Ready(None) => {
                if let Some(lease) = this.lease.as_mut() {
                    lease.outcome = "complete";
                }
                this.lease.take();
                this.eos = true;
                self.watcher.abort();
                Poll::Ready(None)
            }
            Poll::Pending => Poll::Pending,
        }
    }
    fn is_end_stream(&self) -> bool {
        self.shared.lock().unwrap().eos
    }
    fn size_hint(&self) -> SizeHint {
        self.shared.lock().unwrap().body.size_hint()
    }
}
