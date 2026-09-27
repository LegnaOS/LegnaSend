//! Optional directory sharing on the existing listener. This is NOT a new
//! LocalSend wire protocol: all legacy handlers and message bodies stay intact.
use super::common::{
    download,
    error::AppError,
    response::{self, BoxedBody},
};
use super::directory_auth::{self, Access, Grant, LoginBudget};
use super::{AppState, RequestClientInfo};
use crate::model::transfer::{FileContent, FileDto};
use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
use cap_fs_ext::{DirExt, FollowSymlinks, OpenOptionsFollowExt};
use cap_std::{
    ambient_authority,
    fs::{Dir, ReadDir},
};
use futures_util::StreamExt;
use http_body_util::{BodyExt, StreamBody};
use hyper::{
    Method, Request, Response, StatusCode,
    body::{Frame, Incoming},
    header,
};
use lru::LruCache;
use serde::{Deserialize, Serialize};
use serde_json::json;
use std::{
    collections::{HashMap, HashSet},
    num::NonZeroUsize,
    path::Path,
    sync::{
        Arc, Mutex as StdMutex,
        atomic::{AtomicBool, Ordering},
    },
    time::{Duration, Instant},
};
use tokio::sync::{Mutex, RwLock, Semaphore};
use tokio_util::sync::CancellationToken;

#[path = "directory_archive_routes.rs"]
mod archive_routes;
#[path = "directory_archive_selection.rs"]
mod archive_selections;

#[path = "directory_document_snapshot.rs"]
mod document_snapshot;
#[path = "directory_snapshot.rs"]
mod snapshot;

#[path = "directory_approval.rs"]
mod approval;
#[path = "directory_content.rs"]
mod content;
#[path = "directory_document_archive.rs"]
mod document_archive;
#[path = "directory_document_preview.rs"]
mod document_preview;
#[path = "directory_document_upload.rs"]
mod document_upload;
#[path = "directory_documents.rs"]
mod documents;
#[path = "directory_events.rs"]
mod events;
#[path = "directory_upload.rs"]
mod upload;

const API: &str = "/api/legnasend/v1/workspaces";
const PAGE_SIZE: usize = 100;
const CURSOR_TTL: Duration = Duration::from_secs(120);

#[derive(Clone, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct DirectoryConfig {
    pub id: String,
    pub name: String,
    pub slug: String,
    pub root: String,
    #[serde(default)]
    pub document_tree: Option<String>,
    pub generation: u64,
    pub visible: bool,
    #[serde(default)]
    pub allow_upload: bool,
    #[serde(default)]
    pub upload_approval: bool,
    #[serde(default)]
    pub password_hash: Option<String>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Update {
    revision: u64,
    enabled: bool,
    workspaces: Vec<DirectoryConfig>,
}

struct Workspace {
    config: DirectoryConfig,
    document_owner: String,
    content: Arc<content::Observer>,
    root: Option<Arc<Dir>>,
    stopped: CancellationToken,
    downloads: Arc<Semaphore>,
    access: Arc<Access>,
    uploads: Arc<upload::Control>,
    event_slots: Arc<Semaphore>,
    version_stopped: CancellationToken,
}

/// Internal provider response. Ownership closes unused or late descriptors.
#[derive(Debug)]
pub struct DocumentResponse {
    pub payload: String,
    pub file: Option<std::fs::File>,
}
/// Private workspace writer response; both transferred descriptors are owned.
#[derive(Debug)]
pub struct DirectoryWriteResponse {
    pub payload: String,
    pub cache: Option<std::fs::File>,
    pub staging: Option<std::fs::File>,
}
impl Workspace {
    fn filesystem(&self) -> Result<Arc<Dir>, AppError> {
        self.root
            .clone()
            .ok_or_else(|| status(StatusCode::NOT_IMPLEMENTED))
    }
}

pub(crate) struct DirectoryRegistry {
    pub(crate) enabled: AtomicBool,
    pub(super) activities: super::web::activity::ActivityRegistry,
    preview: document_preview::PreviewRegistry,
    archive_selections: archive_selections::Registry,
    archive_preparations: Arc<Semaphore>,
    events: Option<tokio::sync::mpsc::Sender<super::v2::ServerEventV2>>,
    update: Mutex<u64>,
    login_budget: StdMutex<LoginBudget>,
    workspaces: RwLock<HashMap<String, Arc<Workspace>>>,
    cursors: StdMutex<LruCache<String, Arc<StdMutex<Cursor>>>>,
    io: Arc<Semaphore>,
    downloads: Arc<Semaphore>,
}

struct Cursor {
    workspace: String,
    generation: u64,
    path: String,
    filter: String,
    stamp: String,
    directory: Arc<Dir>,
    iterator: Option<ReadDir>,
    cached: Option<Page>,
    anchor: Option<String>,
    anchor_scanned: usize,
    offset: usize,
    expires: Instant,
}

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct Entry {
    id: String,
    name: String,
    directory: bool,
    size: u64,
}
#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct Page {
    entries: Vec<Entry>,
    cursor: Option<String>,
    generation: u64,
    path: String,
    filter: String,
    scanned: usize,
    offset: usize,
    anchor_pending: bool,
    anchor_missing: bool,
    stamp: String,
}

fn archive_selection(query: &HashMap<String, String>) -> Result<Option<Vec<String>>, AppError> {
    let Some(raw) = query.get("ids") else {
        return Ok(None);
    };
    if raw.len() > 8192 {
        return Err(bad());
    }
    let ids: Vec<String> = serde_json::from_str(raw).map_err(|_| bad())?;
    let mut unique = HashSet::new();
    if ids.is_empty()
        || ids.len() > 128
        || ids
            .iter()
            .any(|id| id.is_empty() || id.len() > 4096 || !unique.insert(id))
    {
        return Err(bad());
    }
    Ok(Some(ids))
}

fn status(code: StatusCode) -> AppError {
    AppError::Status(code)
}
fn bad() -> AppError {
    status(StatusCode::BAD_REQUEST)
}
fn io_error(_: std::io::Error) -> AppError {
    status(StatusCode::NOT_FOUND)
}

impl DirectoryRegistry {
    pub(crate) fn new(
        activities: super::web::activity::ActivityRegistry,
        events: Option<tokio::sync::mpsc::Sender<super::v2::ServerEventV2>>,
    ) -> Self {
        Self {
            enabled: AtomicBool::new(false),
            activities,
            preview: document_preview::PreviewRegistry::new(),
            archive_selections: archive_selections::Registry::new(),
            archive_preparations: Arc::new(Semaphore::new(8)),
            events,
            update: Mutex::new(0),
            login_budget: StdMutex::new(LoginBudget::new()),
            workspaces: RwLock::new(HashMap::new()),
            cursors: StdMutex::new(LruCache::new(NonZeroUsize::new(128).unwrap())),
            io: Arc::new(Semaphore::new(8)),
            downloads: Arc::new(Semaphore::new(32)),
        }
    }

    pub(crate) async fn stop(&self) {
        self.enabled.store(false, Ordering::Release);
        for (_, workspace) in self.workspaces.write().await.drain() {
            workspace.stopped.cancel();
            workspace.version_stopped.cancel();
            self.preview.revoke_owner(&workspace.document_owner);
            self.archive_selections
                .revoke_owner(&workspace.document_owner);
            documents::close(self, &workspace);
        }
        self.cursors.lock().unwrap().clear();
    }

    /// Application control only, never exposed as an unauthenticated HTTP write.
    /// Validate the entire replacement before committing; unchanged workspaces
    /// keep their handles, cursors and active downloads when another is removed.
    pub(crate) async fn configure(&self, value: &str) -> anyhow::Result<String> {
        anyhow::ensure!(
            value.len() <= 2 * 1024 * 1024,
            "Directory configuration too large"
        );
        let update: Update = serde_json::from_str(value)
            .map_err(|_| anyhow::anyhow!("Invalid directory configuration"))?;
        anyhow::ensure!(update.workspaces.len() <= 256, "Too many workspaces");
        anyhow::ensure!(
            update.enabled || update.workspaces.is_empty(),
            "Disabled catalog contains workspaces"
        );
        let mut revision = self.update.lock().await;
        anyhow::ensure!(update.revision > *revision, "Stale directory configuration");
        let mut ids = HashSet::new();
        let mut slugs = HashSet::new();
        let old = self.workspaces.read().await.clone();
        let mut next = HashMap::new();
        for config in update.workspaces {
            validate_config(&config)?;
            anyhow::ensure!(
                ids.insert(config.id.clone()) && slugs.insert(config.slug.clone()),
                "Duplicate workspace"
            );
            if let Some(previous) = old.get(&config.id) {
                if previous.config == config {
                    next.insert(config.id.clone(), previous.clone());
                    continue;
                }
                anyhow::ensure!(
                    config.generation > previous.config.generation,
                    "Stale workspace generation"
                );
            }
            // Display-name/visibility edits invalidate future generation-bound
            // requests but keep already-started file streams on the same root.
            if let Some(previous) = old.get(&config.id).filter(|w| {
                w.config.root == config.root
                    && w.config.document_tree == config.document_tree
                    && w.config.password_hash == config.password_hash
            }) {
                let owner = uuid::Uuid::new_v4().to_string();
                let version_stopped = CancellationToken::new();
                let content = content::Observer::new(
                    &config,
                    &owner,
                    version_stopped.clone(),
                    self.events.clone(),
                );
                next.insert(
                    config.id.clone(),
                    Arc::new(Workspace {
                        document_owner: owner,
                        content,
                        config,
                        access: previous.access.clone(),
                        root: previous.root.clone(),
                        stopped: previous.stopped.clone(),
                        downloads: previous.downloads.clone(),
                        uploads: Arc::new(previous.uploads.successor()),
                        event_slots: previous.event_slots.clone(),
                        version_stopped,
                    }),
                );
                continue;
            }
            let root = if config.document_tree.is_some() {
                documents::probe(self, &config)
                    .await
                    .map_err(|_| anyhow::anyhow!("Document tree is unavailable"))?;
                None
            } else {
                let root_path = config.root.clone();
                let root = tokio::task::spawn_blocking(move || {
                    Dir::open_ambient_dir(root_path, ambient_authority())
                })
                .await?
                .map_err(|_| anyhow::anyhow!("Workspace root is unavailable"))?;
                // Ensure enumeration is permitted before exposing the route.
                let root = Arc::new(root);
                let check = root.clone();
                tokio::task::spawn_blocking(move || check.entries()?.next().transpose())
                    .await?
                    .map_err(|_| anyhow::anyhow!("Workspace root is unreadable"))?;
                Some(root)
            };
            let uploads = Arc::new(
                old.get(&config.id)
                    .map_or_else(upload::Control::new, |previous| {
                        previous.uploads.successor()
                    }),
            );
            let owner = uuid::Uuid::new_v4().to_string();
            let version_stopped = CancellationToken::new();
            let content = content::Observer::new(
                &config,
                &owner,
                version_stopped.clone(),
                self.events.clone(),
            );
            next.insert(
                config.id.clone(),
                Arc::new(Workspace {
                    document_owner: owner,
                    content,
                    access: Arc::new(Access::new(config.password_hash.clone())),
                    config,
                    root,
                    stopped: CancellationToken::new(),
                    downloads: Arc::new(Semaphore::new(8)),
                    uploads,
                    event_slots: Arc::new(Semaphore::new(4)),
                    version_stopped,
                }),
            );
        }
        let mut live = self.workspaces.write().await;
        let mut removed = HashSet::new();
        for (id, previous) in live.iter() {
            if !next
                .get(id)
                .is_some_and(|current| Arc::ptr_eq(current, previous))
            {
                // A generation change invalidates every old upload, but not an
                // unrelated already-started download. Wait out its commit point.
                previous.version_stopped.cancel();
                self.preview.revoke_owner(&previous.document_owner);
                self.archive_selections
                    .revoke_owner(&previous.document_owner);
                documents::close(self, previous);
                previous.uploads.revoke().await;
                if !next.get(id).is_some_and(|current| {
                    current.config.root == previous.config.root
                        && current.config.document_tree == previous.config.document_tree
                        && current.config.password_hash == previous.config.password_hash
                }) {
                    previous.stopped.cancel();
                }
                removed.insert(id.clone());
            }
        }
        if !removed.is_empty() {
            // Snapshot under the registry lock, then inspect cursor locks outside it.
            // Page reads lock cursor -> registry while publishing a continuation.
            let snapshots: Vec<_> = self
                .cursors
                .lock()
                .unwrap()
                .iter()
                .map(|(key, cursor)| (key.clone(), cursor.clone()))
                .collect();
            let keys: Vec<_> = snapshots
                .into_iter()
                .filter_map(|(key, cursor)| {
                    removed
                        .contains(&cursor.lock().unwrap().workspace)
                        .then_some(key)
                })
                .collect();
            let mut cursors = self.cursors.lock().unwrap();
            for key in keys {
                cursors.pop(&key);
            }
        }
        *live = next;
        for workspace in live.values() {
            workspace.content.start();
        }
        *revision = update.revision;
        self.enabled.store(update.enabled, Ordering::Release);
        Ok(json!({"revision": *revision, "workspaces": live.values().map(|w| json!({"id": w.config.id, "generation": w.config.generation})).collect::<Vec<_>>()}).to_string())
    }

    async fn document_preview_request(
        self: &Arc<Self>,
        req: &mut Request<Incoming>,
    ) -> Result<Response<BoxedBody>, AppError> {
        let parts: Vec<_> = req
            .uri()
            .path()
            .strip_prefix(&format!("{API}/"))
            .unwrap_or("")
            .split('/')
            .collect();
        if parts.len() != 2 {
            return Err(bad());
        }
        let ws = self.workspace(parts[0]).await?;
        if ws.config.document_tree.is_none() {
            return Err(status(StatusCode::NOT_IMPLEMENTED));
        }
        let op = parts[1].to_owned();
        let mut query = HashMap::new();
        let raw = req.uri().query().unwrap_or("");
        if raw.len() > 128 {
            return Err(bad());
        }
        for (k, v) in form_urlencoded::parse(raw.as_bytes()) {
            if k != "generation" || query.insert(k.into_owned(), v.into_owned()).is_some() {
                return Err(bad());
            }
        }
        if query.get("generation").and_then(|v| v.parse::<u64>().ok()) != Some(ws.config.generation)
        {
            return Err(status(StatusCode::CONFLICT));
        }
        let grant = ws.access.authorize(req.headers(), &ws.config.id)?;
        if req
            .headers()
            .get("sec-fetch-site")
            .is_some_and(|v| v == "cross-site")
        {
            return Err(status(StatusCode::FORBIDDEN));
        }
        if req
            .headers()
            .get(header::CONTENT_TYPE)
            .and_then(|v| v.to_str().ok())
            .and_then(|v| v.split(';').next())
            != Some("application/json")
        {
            return Err(status(StatusCode::UNSUPPORTED_MEDIA_TYPE));
        }
        let mut bytes = Vec::new();
        let read = async {
            while let Some(frame) = req.body_mut().frame().await {
                let frame = frame.map_err(|_| bad())?;
                if let Ok(data) = frame.into_data() {
                    if bytes.len().saturating_add(data.len()) > 1024 {
                        return Err(status(StatusCode::PAYLOAD_TOO_LARGE));
                    }
                    bytes.extend_from_slice(&data);
                }
            }
            Ok::<_, AppError>(())
        };
        tokio::time::timeout(Duration::from_secs(10), read)
            .await
            .map_err(|_| status(StatusCode::REQUEST_TIMEOUT))??;
        let body: HashMap<String, String> = serde_json::from_slice(&bytes).map_err(|_| bad())?;
        if body.len() != 1 {
            return Err(bad());
        }
        if op == "prepare-preview" {
            let id = body.get("id").ok_or_else(bad)?;
            document_preview::prepare(self, ws, id, grant).await
        } else {
            let lease = body.get("lease").ok_or_else(bad)?;
            document_preview::close(self, &ws, grant.as_ref(), lease)
        }
    }

    async fn session(
        self: &Arc<Self>,
        req: &mut Request<Incoming>,
        tls: bool,
        peer: &str,
    ) -> Result<Response<BoxedBody>, AppError> {
        let path = req.uri().path().to_owned();
        let parts: Vec<_> = path
            .strip_prefix(&format!("{API}/"))
            .unwrap_or("")
            .split('/')
            .collect();
        if parts.len() != 2 || req.uri().query().is_some() {
            return Err(bad());
        }
        let ws = self.workspace(parts[0]).await?;
        // JSON-only + exact same-origin checks prevent form/login CSRF. CLI clients
        // without Origin remain supported; forwarded headers are never trusted.
        if req
            .headers()
            .get("sec-fetch-site")
            .is_some_and(|h| h == "cross-site")
        {
            return Err(status(StatusCode::FORBIDDEN));
        }
        if let Some(origin) = req.headers().get(header::ORIGIN) {
            let host = req
                .headers()
                .get(header::HOST)
                .and_then(|h| h.to_str().ok())
                .unwrap_or("");
            let expected = format!("{}://{host}", if tls { "https" } else { "http" });
            if origin.to_str().ok() != Some(expected.as_str()) {
                return Err(status(StatusCode::FORBIDDEN));
            }
        }
        if req
            .headers()
            .get(header::CONTENT_TYPE)
            .and_then(|h| h.to_str().ok())
            .map(|h| h.split(';').next().unwrap_or("").trim())
            != Some("application/json")
        {
            return Err(status(StatusCode::UNSUPPORTED_MEDIA_TYPE));
        }
        let cookie_path = format!("{API}/{}/", ws.config.id);
        let secure = if tls { "; Secure" } else { "" };
        if parts[1] == "logout" {
            let _publication = ws.uploads.publication.lock().await;
            ws.access.logout(req.headers(), &ws.config.id);
            let mut response = json_response(json!({"unlocked":false}));
            response.headers_mut().insert(
                header::SET_COOKIE,
                format!(
                    "{}=; Path={cookie_path}; HttpOnly; SameSite=Strict; Max-Age=0{secure}",
                    directory_auth::cookie_name(&ws.config.id)
                )
                .parse()
                .unwrap(),
            );
            return Ok(response);
        }
        let retry = self
            .login_budget
            .lock()
            .unwrap()
            .consume(format!("{}:{peer}", ws.config.id));
        if let Err(seconds) = retry {
            return Ok(rate_limited(seconds));
        }
        let body = tokio::time::timeout(Duration::from_secs(5), async {
            let mut bytes = Vec::new();
            while let Some(frame) = req.body_mut().frame().await {
                let frame = frame.map_err(|_| bad())?;
                if let Some(data) = frame.data_ref() {
                    if bytes.len() + data.len() > 4096 {
                        return Err(status(StatusCode::PAYLOAD_TOO_LARGE));
                    }
                    bytes.extend_from_slice(data);
                }
            }
            Ok(bytes)
        })
        .await
        .map_err(|_| status(StatusCode::REQUEST_TIMEOUT))??;
        #[derive(Deserialize)]
        #[serde(deny_unknown_fields)]
        struct Unlock {
            password: String,
            generation: u64,
        }
        let input: Unlock = serde_json::from_slice(&body).map_err(|_| bad())?;
        if input.generation != ws.config.generation {
            return Err(status(StatusCode::CONFLICT));
        }
        let verified = match ws.access.verify(input.password).await {
            Err(AppError::Status(StatusCode::TOO_MANY_REQUESTS)) => return Ok(rate_limited(1)),
            result => result?,
        };
        if !verified {
            return Err(status(StatusCode::UNAUTHORIZED));
        }
        // A password change/close during expensive verification must not issue a grant.
        let current = self.workspaces.read().await;
        if !current
            .get(&ws.config.id)
            .is_some_and(|value| Arc::ptr_eq(value, &ws))
            || ws.stopped.is_cancelled()
        {
            return Err(status(StatusCode::CONFLICT));
        }
        // Rotate a presented grant on re-authentication, rather than leaving an
        // unreachable old grant downloading until its absolute expiry.
        let _publication = ws.uploads.publication.lock().await;
        ws.access.logout(req.headers(), &ws.config.id);
        let token = ws.access.issue()?;
        let mut response =
            json_response(json!({"unlocked":true,"expiresIn":directory_auth::SESSION_SECONDS}));
        response.headers_mut().insert(
            header::SET_COOKIE,
            format!(
                "{}={token}; Path={cookie_path}; HttpOnly; SameSite=Strict; Max-Age={}{secure}",
                directory_auth::cookie_name(&ws.config.id),
                directory_auth::SESSION_SECONDS
            )
            .parse()
            .unwrap(),
        );
        Ok(response)
    }

    async fn workspace(&self, id: &str) -> Result<Arc<Workspace>, AppError> {
        self.workspaces
            .read()
            .await
            .get(id)
            .cloned()
            .ok_or_else(|| status(StatusCode::NOT_FOUND))
    }

    /// Host-only export into a freshly owned application staging directory.
    pub(crate) async fn capture_sources(
        self: &Arc<Self>,
        id: &str,
        generation: u64,
        files: &str,
        destination: String,
        server_stopped: CancellationToken,
    ) -> anyhow::Result<String> {
        anyhow::ensure!(!server_stopped.is_cancelled(), "server_stopped");
        let workspace = self
            .workspace(id)
            .await
            .map_err(|_| anyhow::anyhow!("workspace_unavailable"))?;
        anyhow::ensure!(
            workspace.config.generation == generation,
            "workspace_changed"
        );
        if workspace.config.document_tree.is_some() {
            document_snapshot::capture(self.clone(), workspace, files, destination, server_stopped)
                .await
        } else {
            snapshot::capture(workspace, files, destination, server_stopped).await
        }
    }

    pub(crate) async fn integration_upload(
        self: &Arc<Self>,
        req: &mut Request<Incoming>,
        workspace: &str,
        authority: super::integration::UploadAuthority,
    ) -> Result<Response<BoxedBody>, AppError> {
        upload::integration(self, req, workspace, authority).await
    }

    /// Integration grants are explicit application-issued rights, not browser cookies.
    /// Anonymous API policy never unlocks a hidden or password-protected workspace.
    pub(in crate::http::server) async fn integration(
        self: &Arc<Self>,
        req: &Request<Incoming>,
        parts: &[&str],
        query: HashMap<String, String>,
        grant: &super::integration::WorkspaceGrant,
        anonymous: bool,
        authority: Grant,
    ) -> Result<Response<BoxedBody>, AppError> {
        if parts.is_empty() {
            let values = self.workspaces.read().await;
            let mut entries: Vec<_> = values
                .values()
                .filter(|w| {
                    grant.allows(&w.config.id)
                        && (!anonymous || w.config.visible && !w.access.protected())
                })
                .map(|w| descriptor(w))
                .collect();
            entries.sort_by_key(|v| v["id"].as_str().unwrap_or("").to_owned());
            return Ok(json_response(json!({"workspaces":entries})));
        }
        if !grant.allows(parts[0]) {
            return Err(status(StatusCode::NOT_FOUND));
        }
        let ws = self.workspace(parts[0]).await?;
        if anonymous && (!ws.config.visible || ws.access.protected()) {
            return Err(status(StatusCode::NOT_FOUND));
        }
        if parts.len() == 1 {
            return Ok(json_response(descriptor(&ws)));
        }
        if query.get("generation").and_then(|v| v.parse::<u64>().ok()) != Some(ws.config.generation)
        {
            return Err(status(if query.contains_key("generation") {
                StatusCode::CONFLICT
            } else {
                StatusCode::BAD_REQUEST
            }));
        }
        match parts {
            [_, "files"] => self.page(ws, query).await,
            [_, "state"] => self.directory_state(ws, query).await,
            [_, "archive"] => {
                let stopped = ws.stopped.clone();
                let mut response = self
                    .archive(ws, req, Some(authority.clone()), &query, "", "api")
                    .await?;
                response.extensions_mut().insert(stopped);
                Ok(response)
            }
            [_, "files", id, "content"] => {
                let stopped = ws.stopped.clone();
                let mut response = self
                    .content(
                        ws,
                        id,
                        req,
                        Some(authority.clone()),
                        &query,
                        Some(("", "api")),
                    )
                    .await?;
                response.extensions_mut().insert(stopped);
                Ok(response)
            }
            _ => Err(status(StatusCode::NOT_FOUND)),
        }
    }

    async fn index(&self, temporary: bool) -> Result<Response<BoxedBody>, AppError> {
        let values = self.workspaces.read().await;
        let mut entries: Vec<_> = values
            .values()
            .filter(|w| w.config.visible)
            .map(|w| descriptor(w))
            .collect();
        entries.sort_by_key(|entry| entry["name"].as_str().unwrap_or("").to_owned());
        Ok(json_response(
            json!({"workspaces": entries, "temporary": temporary}),
        ))
    }

    async fn page(
        self: &Arc<Self>,
        ws: Arc<Workspace>,
        query: HashMap<String, String>,
    ) -> Result<Response<BoxedBody>, AppError> {
        if ws.config.document_tree.is_some() {
            return documents::page(self, ws, query).await;
        }
        let path = query.get("path").cloned().unwrap_or_default();
        validate_relative(&path)?;
        let filter = query.get("filter").cloned().unwrap_or_default();
        if filter.chars().count() > 256 || filter.chars().any(char::is_control) {
            return Err(bad());
        }
        let folded_filter = filter.to_lowercase();
        let anchor = query.get("anchor").cloned();
        if let Some(anchor) = &anchor {
            if anchor.len() > 8192 {
                return Err(bad());
            }
            let relative = String::from_utf8(URL_SAFE_NO_PAD.decode(anchor).map_err(|_| bad())?)
                .map_err(|_| bad())?;
            validate_relative(&relative)?;
            let parent = relative
                .rsplit_once('/')
                .map(|(parent, _)| parent)
                .unwrap_or("");
            if parent != path {
                return Err(bad());
            }
        }
        let permit = self
            .io
            .clone()
            .try_acquire_owned()
            .map_err(|_| status(StatusCode::TOO_MANY_REQUESTS))?;
        let observer = ws.content.clone();
        let observation_ticket = observer.ticket();
        let registry = self.clone();
        let result = tokio::task::spawn_blocking(move || {
            let _permit = permit;
            if ws.stopped.is_cancelled() {
                return Err(status(StatusCode::GONE));
            }
            let cursor = if let Some(key) = query.get("cursor") {
                registry
                    .cursors
                    .lock()
                    .unwrap()
                    .get(key)
                    .cloned()
                    .ok_or_else(|| status(StatusCode::GONE))?
            } else {
                let directory = open_directory(ws.filesystem()?, &path).map_err(io_error)?;
                let stamp = directory_stamp(&directory)?;
                let iterator = directory.entries().map_err(io_error)?;
                Arc::new(StdMutex::new(Cursor {
                    workspace: ws.config.id.clone(),
                    generation: ws.config.generation,
                    path: path.clone(),
                    filter: filter.clone(),
                    stamp,
                    directory,
                    iterator: Some(iterator),
                    cached: None,
                    anchor,
                    anchor_scanned: 0,
                    offset: 0,
                    expires: Instant::now() + CURSOR_TTL,
                }))
            };
            let mut current = cursor.lock().unwrap();
            if current.workspace != ws.config.id
                || current.generation != ws.config.generation
                || current.path != path
                || current.filter != filter
            {
                return Err(bad());
            }
            if current.expires < Instant::now() {
                return Err(status(StatusCode::GONE));
            }
            if directory_stamp(&current.directory)? != current.stamp {
                return Err(status(StatusCode::CONFLICT));
            }
            if let Some(page) = &current.cached {
                return Ok(page.clone());
            }
            let mut iterator = current
                .iterator
                .take()
                .ok_or_else(|| status(StatusCode::GONE))?;
            let mut entries = vec![];
            let mut exhausted = false;
            let mut scanned = 0;
            let mut page_offset = current.offset;
            // Bound work even if a directory consists almost entirely of excluded entries.
            while entries.len() < PAGE_SIZE && scanned < 512 {
                if current.anchor.is_some() && current.anchor_scanned >= 32768 {
                    exhausted = true;
                    break;
                }
                let Some(entry) = iterator.next() else {
                    exhausted = true;
                    break;
                };
                scanned += 1;
                if current.anchor.is_some() {
                    current.anchor_scanned += 1;
                }
                let entry = entry.map_err(io_error)?;
                let Ok(name) = entry.file_name().into_string() else {
                    continue;
                };
                if !folded_filter.is_empty() && !name.to_lowercase().contains(&folded_filter) {
                    continue;
                }
                let relative = if path.is_empty() {
                    name.clone()
                } else {
                    format!("{path}/{name}")
                };
                if validate_relative(&relative).is_err() {
                    continue;
                }
                let kind = entry.file_type().map_err(io_error)?;
                if !kind.is_file() && !kind.is_dir() {
                    continue;
                } // no symlink/special file entries
                let id = URL_SAFE_NO_PAD.encode(relative.as_bytes());
                if let Some(anchor) = &current.anchor {
                    if anchor != &id {
                        current.offset += 1;
                        page_offset = current.offset;
                        continue;
                    }
                    current.anchor = None;
                }
                let metadata = entry.metadata().map_err(io_error)?;
                entries.push(Entry {
                    id: URL_SAFE_NO_PAD.encode(relative.as_bytes()),
                    name,
                    directory: kind.is_dir(),
                    size: metadata.len(),
                });
            }
            if ws.stopped.is_cancelled() {
                return Err(status(StatusCode::GONE));
            }
            if directory_stamp(&current.directory)? != current.stamp {
                return Err(status(StatusCode::CONFLICT));
            }
            let next = if exhausted {
                None
            } else {
                let key = uuid::Uuid::new_v4().to_string();
                let continuation = Cursor {
                    workspace: current.workspace.clone(),
                    generation: current.generation,
                    path: current.path.clone(),
                    filter: current.filter.clone(),
                    stamp: current.stamp.clone(),
                    directory: current.directory.clone(),
                    iterator: Some(iterator),
                    cached: None,
                    anchor: current.anchor.clone(),
                    anchor_scanned: current.anchor_scanned,
                    offset: current.offset + entries.len(),
                    expires: Instant::now() + CURSOR_TTL,
                };
                // Do not lock a cursor while holding the registry lock elsewhere.
                registry
                    .cursors
                    .lock()
                    .unwrap()
                    .put(key.clone(), Arc::new(StdMutex::new(continuation)));
                Some(key)
            };
            let page = Page {
                entries,
                cursor: next,
                generation: current.generation,
                path,
                filter,
                scanned,
                offset: page_offset,
                anchor_pending: current.anchor.is_some() && !exhausted,
                anchor_missing: current.anchor.is_some() && exhausted,
                stamp: public_stamp(&current.stamp),
            };
            current.cached = Some(page.clone());
            Ok(page)
        })
        .await
        .map_err(|_| status(StatusCode::INTERNAL_SERVER_ERROR))??;
        observer.observe(
            &result.path,
            format!("fs-directory:{}", result.path),
            result.stamp.clone(),
            observation_ticket,
        );
        let mut value =
            serde_json::to_value(result).map_err(|_| status(StatusCode::INTERNAL_SERVER_ERROR))?;
        observer.fields(&mut value);
        Ok(json_response(value))
    }

    // Lightweight foreground validation, not a filesystem watcher or recursive scan.
    async fn directory_state(
        self: &Arc<Self>,
        ws: Arc<Workspace>,
        query: HashMap<String, String>,
    ) -> Result<Response<BoxedBody>, AppError> {
        if ws.config.document_tree.is_some() {
            return documents::state(self, &ws, &query).await;
        }
        let path = query.get("path").cloned().unwrap_or_default();
        validate_relative(&path)?;
        if query.get("ids").is_some_and(|v| v.len() > 8192) {
            return Err(bad());
        }
        let ids: Vec<String> = query
            .get("ids")
            .map(|s| {
                s.split(',')
                    .filter(|v| !v.is_empty())
                    .map(str::to_owned)
                    .collect()
            })
            .unwrap_or_default();
        if ids.len() > 64 {
            return Err(bad());
        }
        let mut names = Vec::new();
        let mut unique = HashSet::new();
        for id in ids {
            if !unique.insert(id.clone()) {
                return Err(bad());
            }
            let decoded = URL_SAFE_NO_PAD.decode(&id).map_err(|_| bad())?;
            if URL_SAFE_NO_PAD.encode(&decoded) != id {
                return Err(bad());
            }
            let relative = String::from_utf8(decoded).map_err(|_| bad())?;
            validate_relative(&relative)?;
            let (parent, name) = relative.rsplit_once('/').unwrap_or(("", &relative));
            if parent != path || name.is_empty() {
                return Err(bad());
            }
            names.push((id, name.to_owned()));
        }
        let permit = self
            .io
            .clone()
            .try_acquire_owned()
            .map_err(|_| status(StatusCode::TOO_MANY_REQUESTS))?;
        let observer = ws.content.clone();
        let observation_ticket = observer.ticket();
        let selection = names
            .iter()
            .map(|(id, _)| id.as_str())
            .collect::<Vec<_>>()
            .join(",");
        let observe_path = path.clone();
        let result = tokio::task::spawn_blocking(move || {
            let _permit = permit;
            if ws.stopped.is_cancelled() { return Err(status(StatusCode::GONE)); }
            let directory = open_directory(ws.filesystem()?, &path).map_err(io_error)?;
            let stamp = directory_stamp(&directory)?;
            let mut entries = Vec::new();
            let mut missing = Vec::new();
            for (id, name) in names {
                match directory.symlink_metadata(&name) {
                    Ok(meta) if meta.is_file() => {
                        // Open through the retained capability root; never follow a replaced symlink.
                        let relative = if path.is_empty() { name } else { format!("{path}/{name}") };
                        match open_regular(ws.filesystem()?, &relative).and_then(|f| f.metadata()) {
                            Ok(metadata) => {
                                let version = download::file_stamp(&metadata, &format!("{}:{}:{id}", ws.config.id, ws.config.generation));
                                entries.push(json!({"id":id,"size":metadata.len(),"directory":false,"version":version}));
                            }
                            Err(_) => missing.push(id),
                        }
                    }
                    Ok(meta) if meta.is_dir() => entries.push(json!({"id":id,"size":meta.len(),"directory":true,"version":null})),
                    _ => missing.push(id),
                }
            }
            if ws.stopped.is_cancelled() { return Err(status(StatusCode::GONE)); }
            if directory_stamp(&directory)? != stamp { return Err(status(StatusCode::CONFLICT)); }
            Ok(json!({"generation":ws.config.generation,"path":path,"stamp":public_stamp(&stamp),"entries":entries,"missing":missing}))
        }).await.map_err(|_| status(StatusCode::INTERNAL_SERVER_ERROR))??;
        let mut result = result;
        observer.observe(
            &observe_path,
            format!("fs-state:{observe_path}:{selection}"),
            crate::crypto::hash::sha256_hex(result.to_string().as_bytes()),
            observation_ticket,
        );
        observer.fields(&mut result);
        Ok(json_response(result))
    }

    async fn archive_inner(
        self: &Arc<Self>,
        ws: Arc<Workspace>,
        req: &Request<Incoming>,
        grant: Option<Grant>,
        query: &HashMap<String, String>,
        peer: &str,
        origin: &'static str,
        selection_owner: Option<Arc<archive_selections::Ticket>>,
    ) -> Result<Response<BoxedBody>, AppError> {
        if query
            .keys()
            .any(|key| !matches!(key.as_str(), "generation" | "path" | "ids"))
        {
            return Err(bad());
        }
        let selected_ids = match &selection_owner {
            Some(ticket) => Some(ticket.selection.ids.clone()),
            None => archive_selection(query)?,
        };
        if ws.config.document_tree.is_some() {
            return document_archive::response(
                self,
                ws,
                req,
                grant,
                query,
                peer,
                origin,
                selected_ids,
                selection_owner,
            )
            .await;
        }
        use super::archive::{self, Entry as ZipEntry, Plan};
        let permit = archive::permit()?;
        let path = query.get("path").cloned().unwrap_or_default();
        validate_relative(&path)?;
        let selected = selected_ids
            .map(|ids| {
                ids.into_iter()
                    .map(|id| {
                        let relative =
                            String::from_utf8(URL_SAFE_NO_PAD.decode(&id).map_err(|_| bad())?)
                                .map_err(|_| bad())?;
                        if URL_SAFE_NO_PAD.encode(relative.as_bytes()) != id || relative.is_empty()
                        {
                            return Err(bad());
                        }
                        validate_relative(&relative)?;
                        if relative.rsplit_once('/').map_or("", |(parent, _)| parent) != path {
                            return Err(bad());
                        }
                        Ok(relative)
                    })
                    .collect::<Result<HashSet<_>, AppError>>()
            })
            .transpose()?;
        let head = req.method() == Method::HEAD;
        let filename = format!(
            "{}.zip",
            if path.is_empty() {
                ws.config.name.as_str()
            } else {
                path.rsplit('/').next().unwrap()
            }
        );
        let activity = if head {
            None
        } else {
            Some(
                self.activities.begin_workspace(
                    peer,
                    &filename,
                    selection_owner
                        .as_ref()
                        .map_or(&ws.stopped, |ticket| &ticket.cancel),
                    super::web::activity::WorkspaceActivity {
                        id: &ws.config.id,
                        name: &ws.config.name,
                        direction: "send",
                        operation: "archive",
                        origin,
                    },
                )?,
            )
        };
        let root = ws.filesystem()?;
        let stopped = activity.as_ref().map_or_else(
            || {
                selection_owner
                    .as_ref()
                    .map_or_else(|| ws.stopped.clone(), |ticket| ticket.cancel.clone())
            },
            |g| g.cancel.clone(),
        );
        let scan_grant = grant.clone();
        let scan_path = path.clone();
        let identity_prefix = format!("{}:{}:", ws.config.id, ws.config.generation);
        let scan = tokio::task::spawn_blocking(move || {
            let _selection_owner = selection_owner;
            let deadline = archive::scan_deadline();
            let mut scanned = 0usize;
            let mut unmatched = selected.clone().unwrap_or_default();
            let dir = open_directory(root.clone(), &scan_path).map_err(io_error)?;
            let mut plan = Plan::new();
            let top = if selected.is_some() {
                "files"
            } else {
                scan_path
                    .rsplit('/')
                    .next()
                    .filter(|s| !s.is_empty())
                    .unwrap_or("files")
            }
            .to_string();
            plan.push(ZipEntry {
                name: format!("{top}/"),
                size: 0,
                source: None,
            })?;
            let mut stack = vec![(
                dir.entries().map_err(io_error)?,
                scan_path.clone(),
                top,
                0usize,
            )];
            while let Some((iter, relative, name, depth)) = stack.last_mut() {
                if stopped.is_cancelled() {
                    return Err(status(StatusCode::GONE));
                }
                if scan_grant
                    .as_ref()
                    .is_some_and(|g| g.cancel.is_cancelled() || g.expires <= Instant::now())
                {
                    return Err(status(StatusCode::UNAUTHORIZED));
                }
                if Instant::now() > deadline {
                    return Err(status(StatusCode::GATEWAY_TIMEOUT));
                }
                let Some(next) = iter.next() else {
                    stack.pop();
                    continue;
                };
                scanned += 1;
                if scanned > archive::MAX_ENTRIES {
                    return Err(status(StatusCode::PAYLOAD_TOO_LARGE));
                }
                let next = next.map_err(io_error)?;
                let Some(component) = next.file_name().to_str().map(str::to_owned) else {
                    return Err(bad());
                };
                if component.to_ascii_lowercase().starts_with(".legnasend")
                    || component.to_ascii_lowercase().ends_with(".ls")
                {
                    continue;
                }
                let child = if relative.is_empty() {
                    component.clone()
                } else {
                    format!("{relative}/{component}")
                };
                validate_relative(&child)?;
                if *depth == 0 && selected.as_ref().is_some_and(|ids| !ids.contains(&child)) {
                    continue;
                }
                let zip_name = format!("{name}/{component}");
                let kind = next.file_type().map_err(io_error)?;
                if kind.is_symlink() {
                    continue;
                }
                if kind.is_dir() {
                    unmatched.remove(&child);
                    if *depth >= 63 {
                        return Err(status(StatusCode::PAYLOAD_TOO_LARGE));
                    }
                    plan.push(ZipEntry {
                        name: format!("{zip_name}/"),
                        size: 0,
                        source: None,
                    })?;
                    let next_depth = *depth + 1;
                    stack.push((
                        open_directory(root.clone(), &child)
                            .map_err(io_error)?
                            .entries()
                            .map_err(io_error)?,
                        child,
                        zip_name,
                        next_depth,
                    ));
                } else if kind.is_file() {
                    unmatched.remove(&child);
                    let file = open_regular(root.clone(), &child).map_err(io_error)?;
                    let meta = file.metadata().map_err(io_error)?;
                    let id = URL_SAFE_NO_PAD.encode(child.as_bytes());
                    let stamp = download::file_stamp(&meta, &format!("{identity_prefix}{id}"));
                    plan.push(ZipEntry {
                        name: zip_name,
                        size: meta.len(),
                        source: Some((id, stamp)),
                    })?;
                }
            }
            if !unmatched.is_empty() {
                return Err(status(StatusCode::NOT_FOUND));
            }
            Ok((plan.finish()?, permit))
        })
        .await
        .map_err(|_| status(StatusCode::INTERNAL_SERVER_ERROR))
        .and_then(|result| result);
        let (entries, permit) = match scan {
            Ok(value) => value,
            Err(error) => {
                if let Some(activity) = &activity {
                    activity.failed();
                }
                return Err(error);
            }
        };
        if ws.stopped.is_cancelled()
            || activity.as_ref().is_some_and(|g| g.cancel.is_cancelled())
            || grant
                .as_ref()
                .is_some_and(|g| g.cancel.is_cancelled() || g.expires <= Instant::now())
        {
            return Err(status(StatusCode::UNAUTHORIZED));
        }
        let registry = self.clone();
        let response = archive::response(entries, &filename, head, permit, move |id| {
            let registry = registry.clone();
            let ws = ws.clone();
            let grant = grant.clone();
            async move {
                if ws.stopped.is_cancelled()
                    || grant
                        .as_ref()
                        .is_some_and(|g| g.cancel.is_cancelled() || g.expires <= Instant::now())
                {
                    return Err(status(StatusCode::UNAUTHORIZED));
                }
                let Some((id, stamp)) = id else {
                    return Ok(response::empty_body());
                };
                let req = Request::builder()
                    .header(header::IF_MATCH, stamp)
                    .body(())
                    .map_err(|_| bad())?;
                let response = registry
                    .content(ws, &id, &req, grant, &HashMap::new(), None)
                    .await?;
                if response.status() != StatusCode::OK {
                    return Err(status(response.status()));
                }
                Ok(response.into_body())
            }
        });
        match response {
            Ok(response) => Ok(match activity {
                Some(activity) => activity.body(response),
                None => response,
            }),
            Err(error) => {
                if let Some(activity) = activity {
                    activity.failed();
                }
                Err(error)
            }
        }
    }

    async fn content<B>(
        self: &Arc<Self>,
        ws: Arc<Workspace>,
        file_id: &str,
        req: &Request<B>,
        grant: Option<Grant>,
        query: &HashMap<String, String>,
        activity: Option<(&str, &'static str)>,
    ) -> Result<Response<BoxedBody>, AppError> {
        if ws.config.document_tree.is_some() {
            if query.get("preview").is_some_and(|value| value == "1") {
                if query.keys().any(|key| {
                    !matches!(key.as_str(), "generation" | "preview" | "lease" | "version")
                }) {
                    return Err(bad());
                }
                let lease = query.get("lease").ok_or_else(bad)?;
                return document_preview::content(self, ws, file_id, req, grant, lease).await;
            }
            return documents::content(self, ws, file_id, req, grant, query, activity).await;
        }
        let preview = match query.get("preview").map(String::as_str) {
            None | Some("0") => false,
            Some("1") => true,
            _ => return Err(bad()),
        };
        let mut headers = req.headers().clone();
        // Native media elements cannot send If-Match. Pin their URL to the
        // metadata validator obtained by an authenticated HEAD request instead.
        // This value is a resource version, never an authorization credential.
        if let Some(version) = query.get("version") {
            if version.len() != 66
                || !version.starts_with('"')
                || !version.ends_with('"')
                || !version.as_bytes()[1..65].iter().all(u8::is_ascii_hexdigit)
            {
                return Err(bad());
            }
            if headers
                .get(header::IF_MATCH)
                .is_some_and(|tag| tag.as_bytes() != version.as_bytes())
            {
                return Err(status(StatusCode::PRECONDITION_FAILED));
            }
            headers.insert(header::IF_MATCH, version.parse().map_err(|_| bad())?);
        }
        let relative = String::from_utf8(URL_SAFE_NO_PAD.decode(file_id).map_err(|_| bad())?)
            .map_err(|_| bad())?;
        if URL_SAFE_NO_PAD.encode(relative.as_bytes()) != file_id || relative.is_empty() {
            return Err(bad());
        }
        validate_relative(&relative)?;
        let global = self
            .downloads
            .clone()
            .try_acquire_owned()
            .map_err(|_| status(StatusCode::TOO_MANY_REQUESTS))?;
        let local = ws
            .downloads
            .clone()
            .try_acquire_owned()
            .map_err(|_| status(StatusCode::TOO_MANY_REQUESTS))?;
        let root = ws.filesystem()?;
        let path = relative.clone();
        let opened = tokio::task::spawn_blocking(move || open_regular(root, &path))
            .await
            .map_err(|_| status(StatusCode::INTERNAL_SERVER_ERROR))?
            .map_err(io_error)?;
        if ws.stopped.is_cancelled() {
            return Err(status(StatusCode::GONE));
        }
        let name = relative.rsplit('/').next().unwrap();
        let file = FileDto {
            id: format!("{}:{}:{file_id}", ws.config.id, ws.config.generation),
            file_name: name.into(),
            size: opened.metadata().map_err(io_error)?.len(),
            file_type: mime(name).into(),
            sha256: None,
            preview: None,
            metadata: None,
        };
        let encoded =
            percent_encoding::utf8_percent_encode(name, percent_encoding::NON_ALPHANUMERIC)
                .to_string();
        let mut response = download::response(
            FileContent::OpenedFile(opened),
            &file,
            &headers,
            req.method() == Method::HEAD,
            preview,
            &encoded,
        )
        .await?;
        let body = std::mem::replace(response.body_mut(), response::empty_body());
        let stream = body
            .into_data_stream()
            .take_until(ws.stopped.clone().cancelled_owned())
            .take_until(async move {
                if let Some(grant) = grant {
                    tokio::select! { _ = grant.cancel.cancelled() => {}, _ = tokio::time::sleep_until(grant.expires.into()) => {} }
                } else { std::future::pending::<()>().await; }
            })
            .map(move |item| {
                // Permits stay alive until the HTTP body is consumed or dropped.
                let _ = (&global, &local);
                item.map(Frame::data)
            });
        *response.body_mut() = BodyExt::boxed(StreamBody::new(stream));
        if !preview && req.method() != Method::HEAD && response.status().is_success() {
            if let Some((peer, origin)) = activity {
                let activity = self.activities.begin_workspace(
                    peer,
                    name,
                    &ws.stopped,
                    super::web::activity::WorkspaceActivity {
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
}

// Open each individual component without following links. A lexical check or
// a canonicalize-then-open sequence alone leaves a symlink replacement race.
fn open_directory(mut root: Arc<Dir>, path: &str) -> std::io::Result<Arc<Dir>> {
    if !path.is_empty() {
        for component in path.split('/') {
            root = Arc::new(root.open_dir_nofollow(component)?);
        }
    }
    Ok(root)
}

fn open_regular(root: Arc<Dir>, path: &str) -> std::io::Result<std::fs::File> {
    let mut options = cap_std::fs::OpenOptions::new();
    options.read(true).follow(FollowSymlinks::No);
    #[cfg(unix)]
    {
        use cap_std::fs::OpenOptionsExt;
        options.custom_flags(libc::O_NONBLOCK);
    }
    let (parent, name) = path.rsplit_once('/').unwrap_or(("", path));
    let directory = open_directory(root, parent)?;
    let file = directory.open_with(name, &options)?;
    if !file.metadata()?.is_file() {
        return Err(std::io::Error::other("Not a regular file"));
    }
    Ok(file.into_std())
}

fn descriptor(w: &Workspace) -> serde_json::Value {
    let mut value = json!({"id": w.config.id, "name": w.config.name, "slug": w.config.slug, "generation": w.config.generation, "readOnly": !w.config.allow_upload, "allowUpload": w.config.allow_upload, "uploadApproval": w.config.upload_approval, "protected": w.access.protected(),"backend":if w.config.document_tree.is_some(){"documents"}else{"filesystem"},"capabilities":{"archive":true,"archiveSelection":true,"capture":true,"events":w.root.is_some(),"preview":true,"resume":w.root.is_some(),"state":true}});
    w.content.fields(&mut value);
    value
}
fn validate_config(c: &DirectoryConfig) -> anyhow::Result<()> {
    if let Some(hash) = &c.password_hash {
        directory_auth::parse_verifier(hash)?;
    }
    anyhow::ensure!(
        uuid::Uuid::parse_str(&c.id).is_ok() && c.generation > 0,
        "Invalid workspace identity"
    );
    anyhow::ensure!(
        !c.name.trim().is_empty() && c.name.len() <= 480 && !c.name.chars().any(char::is_control),
        "Invalid workspace name"
    );
    anyhow::ensure!(valid_slug(&c.slug), "Invalid workspace route");
    if let Some(tree) = &c.document_tree {
        anyhow::ensure!(
            c.root.is_empty()
                && tree.starts_with("content://")
                && tree.len() <= 8192
                && !tree.chars().any(char::is_control),
            "Invalid document tree locator"
        );
    } else {
        anyhow::ensure!(Path::new(&c.root).is_absolute(), "Root must be absolute");
    }
    Ok(())
}
fn valid_slug(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 48
        && value.as_bytes()[0].is_ascii_lowercase()
        && !value.ends_with('-')
        && value
            .bytes()
            .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-')
        && ![
            "api",
            "assets",
            "i18n",
            "upload",
            "download",
            "share",
            "internal",
            "favicon",
            "robots",
            "workspace",
        ]
        .contains(&value)
}
fn validate_relative(value: &str) -> Result<(), AppError> {
    if value.len() > 4096 || value.contains(['\\', ':']) || value.chars().any(char::is_control) {
        return Err(bad());
    }
    if value.is_empty() {
        return Ok(());
    }
    for part in value.split('/') {
        let upper = part.split('.').next().unwrap().to_ascii_uppercase();
        if part.is_empty()
            || part == "."
            || part == ".."
            || part.ends_with([' ', '.'])
            || part.to_ascii_lowercase().starts_with(".legnasend")
            || part.to_ascii_lowercase().ends_with(".ls")
            || [
                "CON", "PRN", "AUX", "NUL", "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7",
                "COM8", "COM9", "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8",
                "LPT9",
            ]
            .contains(&upper.as_str())
        {
            return Err(bad());
        }
    }
    Ok(())
}
fn directory_stamp(dir: &Dir) -> Result<String, AppError> {
    let metadata = dir.dir_metadata().map_err(io_error)?;
    Ok(format!(
        "{:?}:{:?}",
        metadata.modified(),
        metadata.created()
    ))
}
fn public_stamp(value: &str) -> String {
    crate::crypto::hash::sha256_hex(value.as_bytes())
}
fn mime(name: &str) -> &'static str {
    match name
        .rsplit('.')
        .next()
        .unwrap_or("")
        .to_ascii_lowercase()
        .as_str()
    {
        "txt" | "log" => "text/plain",
        "md" | "markdown" => "text/markdown",
        "mp4" | "m4v" => "video/mp4",
        "mov" => "video/quicktime",
        "ogv" => "video/ogg",
        "mp3" => "audio/mpeg",
        "m4a" => "audio/mp4",
        "ogg" | "oga" | "opus" => "audio/ogg",
        "weba" => "audio/webm",
        "flac" => "audio/flac",
        "aac" => "audio/aac",
        "png" => "image/png",
        "jpg" | "jpeg" => "image/jpeg",
        "gif" => "image/gif",
        "webp" => "image/webp",
        "avif" => "image/avif",
        "bmp" => "image/bmp",
        "webm" => "video/webm",
        "wav" => "audio/wav",
        _ => "application/octet-stream",
    }
}
fn rate_limited(seconds: u64) -> Response<BoxedBody> {
    let mut response = json_response(json!({"error":"rate_limited"}));
    *response.status_mut() = StatusCode::TOO_MANY_REQUESTS;
    response.headers_mut().insert(
        header::RETRY_AFTER,
        seconds.max(1).to_string().parse().unwrap(),
    );
    response
}

fn json_response(value: impl Serialize) -> Response<BoxedBody> {
    let mut result = response::JsonResponse {
        status: StatusCode::OK,
        body: value,
    }
    .into_response();
    result
        .headers_mut()
        .insert(header::CACHE_CONTROL, "no-store".parse().unwrap());
    result
        .headers_mut()
        .insert("x-content-type-options", "nosniff".parse().unwrap());
    result
}
fn asset(value: &'static str, mime: &'static str) -> Response<BoxedBody> {
    let mut result = Response::new(response::full_body(value));
    let headers = result.headers_mut();
    headers.insert(header::CONTENT_TYPE, mime.parse().unwrap());
    headers.insert(header::CACHE_CONTROL, "no-store".parse().unwrap());
    headers.insert("x-content-type-options", "nosniff".parse().unwrap());
    headers.insert("content-security-policy", "default-src 'self'; script-src 'self'; style-src 'self'; object-src 'none'; base-uri 'none'; frame-ancestors 'none'".parse().unwrap());
    result
}

pub(crate) async fn route(
    req: &mut Request<Incoming>,
    state: &AppState,
    client: &RequestClientInfo,
) -> Option<Result<Response<BoxedBody>, AppError>> {
    let registry = &state.directories;
    if !registry.enabled.load(Ordering::Acquire) {
        return None;
    }
    let path = req.uri().path().to_owned();
    if req.method() == Method::POST
        && path.starts_with(&format!("{API}/"))
        && (path.ends_with("/prepare-archive") || path.ends_with("/cancel-archive"))
    {
        return Some(
            registry
                .browser_archive_selection(req, &client.ip.to_string())
                .await,
        );
    }
    if req.method() == Method::POST
        && path.starts_with(&format!("{API}/"))
        && (path.ends_with("/prepare-preview") || path.ends_with("/close-preview"))
    {
        return Some(registry.document_preview_request(req).await);
    }
    if req.method() == Method::POST
        && path.starts_with(&format!("{API}/"))
        && (path.ends_with("/unlock") || path.ends_with("/logout"))
    {
        return Some(
            registry
                .session(req, state.tls, &client.ip.to_string())
                .await,
        );
    }
    if req.method() == Method::POST
        && path.starts_with(&format!("{API}/"))
        && (path.ends_with("/prepare-upload") || path.ends_with("/cancel-upload-approval"))
    {
        return Some(approval::handle(registry, req, state.tls, &client.ip.to_string()).await);
    }
    if req.method() == Method::POST
        && path.starts_with(&format!("{API}/"))
        && path.ends_with("/upload")
    {
        return Some(upload::handle(registry, req, state.tls, &client.ip.to_string()).await);
    }
    if ![Method::GET, Method::HEAD].contains(req.method()) {
        return path
            .starts_with(API)
            .then(|| Err(status(StatusCode::METHOD_NOT_ALLOWED)));
    }
    let outcome = async {
        match path.as_str() {
            "/" => {
                return Ok(asset(
                    include_str!("../../../assets/web/directories.html"),
                    "text/html; charset=utf-8",
                ));
            }
            "/assets/directories.js" => {
                return Ok(asset(
                    include_str!("../../../assets/web/directories.js"),
                    "text/javascript; charset=utf-8",
                ));
            }
            "/assets/directory-upload.js" => {
                return Ok(asset(
                    include_str!("../../../assets/web/directory-upload.js"),
                    "text/javascript; charset=utf-8",
                ));
            }
            "/assets/directory-upload.css" => {
                return Ok(asset(
                    include_str!("../../../assets/web/directory-upload.css"),
                    "text/css; charset=utf-8",
                ));
            }
            "/assets/directory-events.js" => {
                return Ok(asset(
                    include_str!("../../../assets/web/directory-events.js"),
                    "text/javascript; charset=utf-8",
                ));
            }
            "/assets/directory-archive-selection.js" => {
                return Ok(asset(
                    include_str!("../../../assets/web/directory-archive-selection.js"),
                    "text/javascript; charset=utf-8",
                ));
            }
            "/assets/directory-window.js" => {
                return Ok(asset(
                    include_str!("../../../assets/web/directory-window.js"),
                    "text/javascript; charset=utf-8",
                ));
            }
            "/assets/directories.css" => {
                return Ok(asset(
                    include_str!("../../../assets/web/directories.css"),
                    "text/css; charset=utf-8",
                ));
            }
            "/assets/directory-preview.js" => {
                return Ok(asset(
                    include_str!("../../../assets/web/directory-preview.js"),
                    "text/javascript; charset=utf-8",
                ));
            }
            "/assets/directory-preview.css" => {
                return Ok(asset(
                    include_str!("../../../assets/web/directory-preview.css"),
                    "text/css; charset=utf-8",
                ));
            }
            "/assets/text-preview.js" => {
                return Ok(asset(
                    include_str!("../../../assets/web/text-preview.js"),
                    "text/javascript; charset=utf-8",
                ));
            }
            "/api/legnasend/v1/workspaces" => {
                return registry
                    .index(!matches!(state.web.share(), super::web::WebShare::Disabled))
                    .await;
            }
            _ => {}
        }
        if let Some(rest) = path.strip_prefix(&format!("{API}/")) {
            let segments: Vec<_> = rest.split('/').collect();
            let ws = registry.workspace(segments[0]).await?;
            let query_str = req.uri().query().unwrap_or("");
            if query_str.len() > 8192 {
                return Err(bad());
            }
            let mut query = HashMap::new();
            for (key, value) in form_urlencoded::parse(query_str.as_bytes()) {
                if query.insert(key.into_owned(), value.into_owned()).is_some() {
                    return Err(bad());
                }
            }
            if let Some(expected) = query.get("generation") {
                if expected.parse::<u64>().ok() != Some(ws.config.generation) {
                    return Err(status(StatusCode::CONFLICT));
                }
            } else {
                return Err(bad());
            }
            let grant = ws.access.authorize(req.headers(), &ws.config.id)?;
            return match segments.as_slice() {
                [_, "files"] | [_, "state"] => {
                    let response = if segments[1] == "state" {
                        registry.directory_state(ws.clone(), query).await?
                    } else {
                        registry.page(ws.clone(), query).await?
                    };
                    if ws.stopped.is_cancelled()
                        || grant
                            .as_ref()
                            .is_some_and(|g| g.cancel.is_cancelled() || g.expires <= Instant::now())
                    {
                        return Err(status(StatusCode::UNAUTHORIZED));
                    }
                    Ok(response)
                }
                [_, "events"] => events::subscribe(ws, grant, query).await,
                [_, "archive"] => {
                    registry
                        .archive(ws, req, grant, &query, &client.ip.to_string(), "browser")
                        .await
                }
                [_, "files", id, "content"] => {
                    registry
                        .content(
                            ws,
                            id,
                            req,
                            grant,
                            &query,
                            Some((&client.ip.to_string(), "browser")),
                        )
                        .await
                }
                _ => Err(status(StatusCode::NOT_FOUND)),
            };
        }
        let slug = path.trim_matches('/');
        if valid_slug(slug) && path.matches('/').count() <= 2 {
            let values = registry.workspaces.read().await;
            let Some(ws) = values.values().find(|w| w.config.slug == slug) else {
                return Err(status(StatusCode::NOT_FOUND));
            };
            if req.uri().query() == Some("meta") {
                return Ok(json_response(descriptor(ws)));
            }
            return Ok(asset(
                include_str!("../../../assets/web/directories.html"),
                "text/html; charset=utf-8",
            ));
        }
        Err(status(StatusCode::NOT_FOUND))
    };
    // Do not capture legacy data endpoints. The fixed reader script is also
    // available in directory-only mode; it contains no session or file data.
    let claimed = path == "/"
        || path.starts_with(API)
        || path.starts_with("/assets/directories.")
        || matches!(
            path.as_str(),
            "/assets/directory-archive-selection.js"
                | "/assets/directory-window.js"
                | "/assets/directory-upload.js"
                | "/assets/directory-upload.css"
                | "/assets/directory-preview.js"
                | "/assets/directory-preview.css"
                | "/assets/text-preview.js"
        )
        || (valid_slug(path.trim_matches('/')) && path.matches('/').count() <= 2);
    if claimed { Some(outcome.await) } else { None }
}
