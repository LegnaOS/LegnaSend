//! Read-only document-provider backend. Locators never enter filesystem APIs.
use super::*;
use std::io::{Seek, SeekFrom};
use tokio::sync::oneshot;

const TIMEOUT: Duration = Duration::from_secs(10);
fn error(value: &str) -> AppError {
    status(match value {
        "permission" => StatusCode::FORBIDDEN,
        "not_found" => StatusCode::NOT_FOUND,
        "expired" => StatusCode::CONFLICT,
        "busy" | "loading" => StatusCode::SERVICE_UNAVAILABLE,
        "invalid" => StatusCode::BAD_REQUEST,
        "unsupported" => StatusCode::NOT_IMPLEMENTED,
        "cancelled" => StatusCode::GONE,
        _ => StatusCode::BAD_GATEWAY,
    })
}
fn request(config: &DirectoryConfig, op: &str) -> serde_json::Value {
    json!({"version":1,"requestId":uuid::Uuid::new_v4().to_string(),"workspaceId":config.id,"generation":config.generation,"tree":config.document_tree,"op":op})
}
async fn call(
    registry: &DirectoryRegistry,
    value: serde_json::Value,
    cancel: Option<&CancellationToken>,
) -> Result<DocumentResponse, AppError> {
    let events = registry
        .events
        .as_ref()
        .ok_or_else(|| status(StatusCode::NOT_IMPLEMENTED))?;
    let (result_tx, rx) = oneshot::channel();
    let operation = async {
        events
            .send(super::super::v2::ServerEventV2::DirectoryDocument {
                request: value.to_string(),
                result_tx,
            })
            .await
            .map_err(|_| status(StatusCode::SERVICE_UNAVAILABLE))?;
        rx.await
            .map_err(|_| status(StatusCode::SERVICE_UNAVAILABLE))?
            .map_err(|e| error(&e))
    };
    // Dropping the receiver is observed by the bridge's bounded pending-owner
    // cleanup, which sends requestId cancellation to the provider.
    let reply = tokio::select! {biased;
        _=async{match cancel{Some(c)=>c.cancelled().await,None=>std::future::pending().await}}=>return Err(status(StatusCode::GONE)),
        reply=tokio::time::timeout(TIMEOUT,operation)=>reply.map_err(|_|status(StatusCode::GATEWAY_TIMEOUT))??,
    };
    if reply.payload.len() > 256 * 1024 {
        return Err(status(StatusCode::BAD_GATEWAY));
    }
    Ok(reply)
}
pub(super) async fn probe(
    registry: &DirectoryRegistry,
    config: &DirectoryConfig,
) -> Result<(), AppError> {
    let mut value = request(config, "probe");
    value["requireWritable"] = json!(config.allow_upload);
    value["owner"] = json!(uuid::Uuid::new_v4().to_string());
    let reply = call(registry, value, None).await?;
    let value: serde_json::Value =
        serde_json::from_str(&reply.payload).map_err(|_| error("provider_error"))?;
    if reply.file.is_some()
        || value["version"] != 1
        || value["readable"] != true
        || (config.allow_upload && value["writable"] != true)
    {
        return Err(error("permission"));
    }
    Ok(())
}
pub(super) fn close(registry: &DirectoryRegistry, workspace: &Workspace) {
    let config = &workspace.config;
    if config.document_tree.is_none() {
        return;
    }
    let Some(events) = registry.events.clone() else {
        return;
    };
    let mut value = request(config, "close");
    value["owner"] = json!(workspace.document_owner);
    tokio::spawn(async move {
        let (result_tx, rx) = oneshot::channel();
        let _ = tokio::time::timeout(TIMEOUT, async {
            if events
                .send(super::super::v2::ServerEventV2::DirectoryDocument {
                    request: value.to_string(),
                    result_tx,
                })
                .await
                .is_ok()
            {
                let _ = rx.await;
            }
        })
        .await;
    });
}
pub(super) fn opaque(value: &str) -> bool {
    uuid::Uuid::parse_str(value).is_ok_and(|id| id.to_string() == value)
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct DocumentEntry {
    pub(super) id: String,
    pub(super) name: String,
    pub(super) directory: bool,
    pub(super) size: Option<u64>,
    #[serde(default)]
    pub(super) downloadable: bool,
}
#[derive(Deserialize)]
pub(super) struct Listing {
    pub(super) version: u32,
    pub(super) entries: Vec<DocumentEntry>,
    pub(super) cursor: Option<String>,
    pub(super) offset: u64,
    pub(super) scanned: u64,
}
pub(super) async fn list_page(
    registry: &DirectoryRegistry,
    ws: &Workspace,
    path: &str,
    cursor: Option<&str>,
    filter: &str,
    cancel: Option<&CancellationToken>,
) -> Result<Listing, AppError> {
    let _permit = registry
        .io
        .clone()
        .try_acquire_owned()
        .map_err(|_| status(StatusCode::TOO_MANY_REQUESTS))?;
    let mut value = request(&ws.config, "list");
    value["owner"] = json!(ws.document_owner);
    value["documentId"] = json!(path);
    value["cursor"] = json!(cursor);
    value["filter"] = json!(filter);
    value["limit"] = json!(PAGE_SIZE);
    let reply = call(registry, value, cancel).await?;
    if reply.file.is_some() {
        return Err(error("provider_error"));
    }
    let page: Listing =
        serde_json::from_str(&reply.payload).map_err(|_| error("provider_error"))?;
    if page.version != 1
        || page.entries.len() > PAGE_SIZE
        || page.scanned > PAGE_SIZE as u64
        || page.offset > 9_007_199_254_740_991
        || page
            .cursor
            .as_ref()
            .is_some_and(|v| v.is_empty() || v.len() > 256 || v.chars().any(char::is_control))
    {
        return Err(error("provider_error"));
    }
    let mut seen = HashSet::new();
    for entry in &page.entries {
        if !opaque(&entry.id)
            || !seen.insert(entry.id.clone())
            || entry.name.is_empty()
            || entry.name.len() > 4096
            || entry.name.contains('\0')
            || entry.size.is_some_and(|v| v > 9_007_199_254_740_991)
        {
            return Err(error("provider_error"));
        }
    }
    Ok(page)
}
pub(super) async fn page(
    registry: &Arc<DirectoryRegistry>,
    ws: Arc<Workspace>,
    query: HashMap<String, String>,
) -> Result<Response<BoxedBody>, AppError> {
    if query.keys().any(|k| {
        !matches!(
            k.as_str(),
            "generation" | "path" | "cursor" | "filter" | "anchor"
        )
    }) {
        return Err(bad());
    }
    let path = query.get("path").cloned().unwrap_or_default();
    if !path.is_empty() && !opaque(&path) {
        return Err(bad());
    }
    let filter = query.get("filter").cloned().unwrap_or_default();
    if filter.chars().count() > 256 || filter.chars().any(char::is_control) {
        return Err(bad());
    }
    if query
        .get("cursor")
        .is_some_and(|v| v.len() > 256 || v.is_empty() || v.chars().any(char::is_control))
    {
        return Err(bad());
    }
    let observation_ticket = ws.content.ticket();
    let page = list_page(
        registry,
        &ws,
        &path,
        query.get("cursor").map(String::as_str),
        &filter,
        Some(&ws.stopped),
    )
    .await?;
    let mut seen = HashSet::new();
    let mut entries = Vec::new();
    for entry in page.entries {
        if !opaque(&entry.id)
            || !seen.insert(entry.id.clone())
            || entry.name.is_empty()
            || entry.name.len() > 4096
            || entry.name.contains('\0')
            || entry.size.is_some_and(|v| v > 9_007_199_254_740_991)
        {
            return Err(error("provider_error"));
        }
        entries.push(json!({"id":entry.id,"name":entry.name,"directory":entry.directory,"size":entry.size,"downloadable":entry.downloadable&&!entry.directory&&entry.size.is_some()}));
    }
    // Provider IDs identify this live owner only. Compare stable page contents
    // at an identical directory/filter/offset, never cursor or watcher tokens.
    let fingerprint = crate::crypto::hash::sha256_hex(
        json!({"entries":entries,"scanned":page.scanned})
            .to_string()
            .as_bytes(),
    );
    ws.content.observe(
        &path,
        format!("documents-page:{path}:{filter}:{}", page.offset),
        fingerprint,
        observation_ticket,
    );
    let mut value = json!({"entries":entries,"cursor":page.cursor,"generation":ws.config.generation,"path":path,"filter":filter,"scanned":page.scanned,"offset":page.offset,"anchorPending":false,"anchorMissing":query.contains_key("anchor"),"stamp":format!("documents:{}",ws.config.generation)});
    ws.content.fields(&mut value);
    Ok(json_response(value))
}
#[derive(Deserialize)]
struct Opened {
    version: u32,
    id: String,
    name: String,
    size: u64,
    seekable: bool,
    mime: String,
}
pub(super) struct DocumentMetadata {
    pub name: String,
    pub size: u64,
    pub mime: String,
}
pub(super) async fn open_file(
    registry: &DirectoryRegistry,
    ws: &Workspace,
    id: &str,
    cancel: Option<&CancellationToken>,
) -> Result<(std::fs::File, DocumentMetadata), AppError> {
    if !opaque(id) {
        return Err(bad());
    }
    let _io = registry
        .io
        .clone()
        .try_acquire_owned()
        .map_err(|_| status(StatusCode::TOO_MANY_REQUESTS))?;
    let mut value = request(&ws.config, "open");
    value["owner"] = json!(ws.document_owner);
    value["documentId"] = json!(id);
    let reply = call(registry, value, cancel).await?;
    let opened: Opened =
        serde_json::from_str(&reply.payload).map_err(|_| error("provider_error"))?;
    if opened.version != 1
        || opened.id != id
        || !opened.seekable
        || opened.name.is_empty()
        || opened.name.len() > 4096
        || opened.name.contains('\0')
        || opened.mime.len() > 256
    {
        return Err(error("unsupported"));
    }
    let file = reply.file.ok_or_else(|| error("unsupported"))?;
    let size = opened.size;
    let file = tokio::task::spawn_blocking(move || {
        let _io = _io;
        let mut file = file;
        let metadata = file.metadata()?;
        if !metadata.is_file() || metadata.len() != size {
            return Err(std::io::Error::other("Unsupported document descriptor"));
        }
        file.seek(SeekFrom::Start(0))?;
        Ok(file)
    })
    .await
    .map_err(|_| error("provider_error"))?
    .map_err(|_| error("unsupported"))?;
    Ok((
        file,
        DocumentMetadata {
            name: opened.name,
            size: opened.size,
            mime: opened.mime,
        },
    ))
}
pub(super) async fn content<B>(
    registry: &Arc<DirectoryRegistry>,
    ws: Arc<Workspace>,
    id: &str,
    req: &Request<B>,
    grant: Option<Grant>,
    query: &HashMap<String, String>,
    activity: Option<(&str, &'static str)>,
) -> Result<Response<BoxedBody>, AppError> {
    if !opaque(id) || query.keys().any(|k| k != "generation") {
        return Err(bad());
    }
    let global = registry
        .downloads
        .clone()
        .try_acquire_owned()
        .map_err(|_| status(StatusCode::TOO_MANY_REQUESTS))?;
    let local = ws
        .downloads
        .clone()
        .try_acquire_owned()
        .map_err(|_| status(StatusCode::TOO_MANY_REQUESTS))?;
    let (file, opened) = open_file(registry, &ws, id, Some(&ws.stopped)).await?;
    let size = opened.size;
    if ws.stopped.is_cancelled()
        || grant
            .as_ref()
            .is_some_and(|g| g.cancel.is_cancelled() || g.expires <= Instant::now())
    {
        return Err(status(StatusCode::UNAUTHORIZED));
    }
    let dto = FileDto {
        id: format!("{}:{}:{id}", ws.config.id, ws.config.generation),
        file_name: opened.name.clone(),
        size,
        file_type: opened.mime,
        sha256: None,
        preview: None,
        metadata: None,
    };
    let encoded =
        percent_encoding::utf8_percent_encode(&opened.name, percent_encoding::NON_ALPHANUMERIC)
            .to_string();
    let mut response = download::response_unversioned(
        FileContent::OpenedFile(file),
        &dto,
        req.headers(),
        req.method() == Method::HEAD,
        &encoded,
    )
    .await?;
    let body = std::mem::replace(response.body_mut(), response::empty_body());
    let stream=body.into_data_stream().take_until(ws.stopped.clone().cancelled_owned()).take_until(async move{
        if let Some(grant)=grant {tokio::select!{_=grant.cancel.cancelled()=>{},_=tokio::time::sleep_until(grant.expires.into())=>{}}}else{std::future::pending::<()>().await;}
    }).map(move|item|{let _=(&global,&local);item.map(Frame::data)});
    *response.body_mut() = BodyExt::boxed(StreamBody::new(stream));
    if req.method() != Method::HEAD && response.status().is_success() {
        if let Some((peer, origin)) = activity {
            let activity = registry.activities.begin_workspace(
                peer,
                &opened.name,
                &ws.stopped,
                super::super::web::activity::WorkspaceActivity {
                    id: &ws.config.id,
                    name: &ws.config.name,
                    direction: "send",
                    operation: "download",
                    origin,
                },
            )?;
            return Ok(activity.body(response));
        }
    }
    Ok(response)
}

/// A foreground directory notification lease. This is an invalidation hint,
/// never a strong content version or a recursive filesystem snapshot.
pub(super) async fn state(
    registry: &DirectoryRegistry,
    ws: &Workspace,
    query: &HashMap<String, String>,
) -> Result<Response<BoxedBody>, AppError> {
    if query
        .keys()
        .any(|key| !matches!(key.as_str(), "generation" | "path"))
    {
        return Err(bad());
    }
    let path = query.get("path").map(String::as_str).unwrap_or("");
    if !path.is_empty() && !opaque(path) {
        return Err(bad());
    }
    let _permit = registry
        .io
        .clone()
        .try_acquire_owned()
        .map_err(|_| status(StatusCode::TOO_MANY_REQUESTS))?;
    let mut value = request(&ws.config, "state");
    value["owner"] = json!(ws.document_owner);
    value["documentId"] = json!(path);
    let reply = call(registry, value, Some(&ws.version_stopped)).await?;
    #[derive(Deserialize)]
    #[serde(rename_all = "camelCase", deny_unknown_fields)]
    struct State {
        version: u32,
        watch_id: String,
        revision: u64,
        observing: bool,
    }
    let state: State = serde_json::from_str(&reply.payload).map_err(|_| error("provider_error"))?;
    if reply.file.is_some()
        || state.version != 1
        || !opaque(&state.watch_id)
        || state.revision > 9_007_199_254_740_991
    {
        return Err(error("provider_error"));
    }
    ws.content.watch_hint(
        path,
        format!("{}:{}", state.watch_id, state.revision),
        state.observing,
    );
    let mut value = json!({"generation":ws.config.generation,"path":path,
        "refreshFromStart":true,"watchId":state.watch_id,
        "stamp":format!("{}:{}",state.watch_id,state.revision),"observing":state.observing});
    ws.content.fields(&mut value);
    Ok(json_response(value))
}
