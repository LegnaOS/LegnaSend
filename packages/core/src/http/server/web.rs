use crate::http::dto_v2::{InfoResponseDtoV2, PrepareDownloadResponseDtoV2};
use crate::http::server::PeerIp;
use crate::http::server::common::error::AppError;
use crate::http::server::common::pin::check_pin;
use crate::http::server::common::query::parse_query;
use crate::http::server::common::response::{BoxedBody, JsonResponse, full_body};
use crate::http::server::{AppState, RequestClientInfo};
use crate::model::discovery::PROTOCOL_VERSION_V2;
use crate::model::transfer::{FileContent, FileDto};
use http_body_util::{BodyExt, StreamBody};
use hyper::body::Incoming;
use hyper::{Request, Response, StatusCode, http};
use lru::LruCache;
use percent_encoding::{AsciiSet, NON_ALPHANUMERIC, utf8_percent_encode};
use serde::Serialize;
use std::collections::{HashMap, HashSet};
use std::net::IpAddr;
use std::num::NonZeroUsize;
use std::sync::{Arc, RwLock as SyncRwLock};
use tokio::sync::{Mutex, RwLock, Semaphore, mpsc, oneshot};
use tokio_util::sync::CancellationToken;
use uuid::Uuid;

#[path = "web_activity.rs"]
pub(crate) mod activity;

/// Events emitted by the web download (download API) endpoints that must be handled
/// by the application. Web download can be enabled independently of the v2 endpoints.
#[derive(Debug)]
pub enum WebDownloadEvent {
    /// A web client requests to download the shared files
    /// via `POST /api/localsend/v2/prepare-download`.
    ///
    /// The application must answer on `decision_tx`.
    /// Dropping `decision_tx` results in a 500 response. The queue and decision
    /// together have a 120-second deadline; a late answer is discarded.
    PrepareDownload {
        /// The IP address of the web client.
        ip: PeerIp,

        /// The ID of the download session that is created when accepted.
        session_id: String,

        /// The `User-Agent` header of the web client.
        user_agent: Option<String>,

        /// Channel to send the decision (`true` to accept, `false` to decline).
        decision_tx: oneshot::Sender<bool>,
    },

    /// A request ended before approval (decline, timeout, disconnect, or share closure).
    /// Consumers must remove only the UI entry with this exact session ID,
    /// including a local approval acknowledgement racing this abort.
    /// Delivery is best effort on a full queue; bridge consumers also reconcile
    /// closed decision responders whenever the queue makes progress.
    PrepareDownloadAborted { session_id: String },

    /// An accepted web client downloads a file via `GET /api/localsend/v2/download`.
    ///
    /// The application must respond on `content_tx` with the file content. The
    /// source represents the complete file. Seekable sources support byte ranges;
    /// opaque streams must provide exactly `file.size` bytes and use full responses.
    /// Closing a stream early aborts the download.
    /// Dropping `content_tx` results in a 500 response. Queueing and source
    /// resolution share a 30-second deadline; file body streaming has no such limit.
    FileDownload {
        /// The ID of the download session.
        session_id: String,

        /// The ID of the file being downloaded.
        file_id: String,

        /// The metadata of the file being downloaded.
        file: FileDto,

        /// Channel to provide the content of the file being downloaded.
        content_tx: oneshot::Sender<FileContent>,
    },
}

const DOWNLOAD_HTML: &str = include_str!("../../../assets/web/download.html");
const TEXT_SEARCH_JS: &str = include_str!("../../../assets/web/text-search.js");
const MARKDOWN_PREVIEW_JS: &str = include_str!("../../../assets/web/markdown-preview.js");
const MARKDOWN_WORKER_JS: &str = include_str!("../../../assets/web/markdown-worker.js");
const MARKED_LICENSE: &str = include_str!("../../../assets/web/vendor/marked-LICENSE.txt");
const MARKED_JS: &str = include_str!("../../../assets/web/vendor/marked.umd.js");
const TEXT_PREVIEW_JS: &str = include_str!("../../../assets/web/text-preview.js");
const WEB_UI_JS: &str = include_str!("../../../assets/web/web-ui.js");
const WEB_UI_CSS: &str = include_str!("../../../assets/web/web-ui.css");
const WEB_I18N_JS: &str = include_str!("../../../assets/web/web-i18n.js");
const WEB_UPLOAD_JS: &str = include_str!("../../../assets/web/web-upload.js");
const UPLOAD_HTML: &str = include_str!("../../../assets/web/upload.html");
const ERROR_403_HTML: &str = include_str!("../../../assets/web/error-403.html");

/// Characters that are percent-encoded in the content-disposition file name.
/// Matches the component encoding of RFC 2396 (letters, digits and marks are kept).
const FILE_NAME_ENCODE_SET: &AsciiSet = &NON_ALPHANUMERIC
    .remove(b'-')
    .remove(b'_')
    .remove(b'.')
    .remove(b'!')
    .remove(b'~')
    .remove(b'*')
    .remove(b'\'')
    .remove(b'(')
    .remove(b')');

/// Configuration for the pages served to browsers.
#[derive(Default)]
pub struct WebConfig {
    /// What is served at `/` and which browser-facing API is active.
    pub mode: WebMode,

    /// Translations for the web pages, served via `/i18n.json`.
    pub i18n: WebI18n,

    /// The HTML pages served to browsers.
    /// Pages left unset fall back to the assets embedded at compile time.
    pub pages: WebPages,
}

/// What is served at `/` and which browser-facing API is active.
/// Duplex serves a persistent workspace at `/` with both directions.
#[derive(Default)]
pub enum WebMode {
    /// No web share active: `/` serves the 403 page and client certificates
    /// are mandatory under TLS, so the 403 page is effectively only reachable
    /// when encryption is off.
    #[default]
    Disabled,

    /// Web download: the download page and the download API,
    /// offering the configured files for download by web browsers.
    Download(WebDownloadConfig),

    /// Both browser directions; permission changes and appended files are live.
    Duplex {
        download: WebDownloadConfig,
        allow_upload: bool,
    },

    /// The upload page: web browsers upload files
    /// via the v2 `prepare-upload`/`upload` endpoints.
    Upload,
}

/// The HTML pages served to browsers.
///
/// Each page is optional: a `None` page is served from the corresponding
/// asset embedded at compile time, so applications only provide the pages
/// they customize.
#[derive(Clone, Debug, Default)]
pub struct WebPages {
    /// The download page served at `/` while web download is active.
    pub download_html: Option<String>,

    /// The upload page served at `/` while the upload page is enabled.
    pub upload_html: Option<String>,

    /// The error page served at `/` in [`WebMode::Disabled`].
    pub error_403_html: Option<String>,
}

/// Configuration for web download (download API): files offered for download by web browsers.
///
/// Web download can be enabled independently of the v2/v3 protocol endpoints.
pub struct WebDownloadConfig {
    /// The metadata of the files offered for download, mapped by file ID.
    ///
    /// The content is requested from the application per download
    /// via [`WebDownloadEvent::FileDownload`].
    pub files: HashMap<String, FileDto>,

    /// Optional PIN that web clients must provide via the `pin` query parameter.
    pub pin: Option<String>,

    /// Channel on which the server emits events that must be handled by the application.
    pub event_tx: mpsc::Sender<WebDownloadEvent>,
}

/// Translations for the web pages, served via `/i18n.json`.
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct WebI18n {
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
    #[serde(skip_serializing_if = "Option::is_none")]
    pub text_preview: Option<HashMap<String, String>>,
}

impl Default for WebI18n {
    fn default() -> Self {
        Self {
            waiting: "Waiting for response…".to_string(),
            enter_pin: "Enter PIN".to_string(),
            invalid_pin: "Invalid PIN".to_string(),
            too_many_attempts: "Too many attempts".to_string(),
            rejected: "Rejected".to_string(),
            upload_rejected: "The recipient has rejected the request.".to_string(),
            busy: "The recipient is busy with another request.".to_string(),
            files: "Files".to_string(),
            file_name: "File name".to_string(),
            size: "Size".to_string(),
            drop_hint: "Place items to share.".to_string(),
            preview: Some("Preview".to_string()),
            close_preview: Some("Close preview".to_string()),
            download_original: Some("Download original".to_string()),
            preview_loading: Some("Loading preview…".to_string()),
            preview_error: Some(
                "Preview failed. Download the original file to open it.".to_string(),
            ),
            preview_unsupported: Some(
                "This browser or file format does not support preview.".to_string(),
            ),
            text_preview: None,
        }
    }
}

// Browser archive preparation retains metadata only, never ZIP/file bytes.
// Tickets supplement (not replace) the approved session and client-IP check.
const ARCHIVE_SELECTION_TTL: std::time::Duration = std::time::Duration::from_secs(120);
#[derive(Clone)]
struct ArchiveSelection {
    session: String,
    version: String,
    ids: Vec<String>,
    prefix: String,
    created: tokio::time::Instant,
}
impl ArchiveSelection {
    fn usable(&self, session: &str) -> bool {
        self.session == session && self.created.elapsed() < ARCHIVE_SELECTION_TTL
    }
}

/// Runtime state of the web download (download API) endpoints.
pub(crate) struct WebDownloadState {
    pub(crate) cancelled: CancellationToken,
    /// The metadata of the files offered for download, mapped by file ID.
    pub(crate) files: RwLock<SharedFiles>,

    /// Optional PIN required for prepare-download requests.
    pub(crate) pin: Option<String>,

    /// Channel on which server events are emitted to the application.
    pub(crate) event_tx: mpsc::Sender<WebDownloadEvent>,

    /// Download sessions, keyed by a unique request ID; IP remains an access constraint.
    pub(crate) sessions: Mutex<HashMap<String, WebDownloadSession>>,
    // Bound only undecided requests. Approved sessions remain valid for retries.
    pending_approvals: Semaphore,

    /// Maps client IPs to the number of failed PIN attempts.
    pub(crate) pin_attempts: Mutex<LruCache<IpAddr, u32>>,
    archive_selections: Mutex<LruCache<String, ArchiveSelection>>,
}

#[derive(Clone)]
pub(crate) struct SharedFile {
    file: FileDto,
    cancelled: CancellationToken,
}
pub(crate) struct SharedFiles {
    active: HashMap<String, SharedFile>,
    issued: HashSet<String>,
    version: String,
}

impl WebDownloadState {
    pub(crate) fn new(config: WebDownloadConfig) -> Self {
        let cancelled = CancellationToken::new();
        let issued = config.files.keys().cloned().collect();
        let active = config
            .files
            .into_iter()
            .map(|(id, file)| {
                (
                    id,
                    SharedFile {
                        file,
                        cancelled: cancelled.child_token(),
                    },
                )
            })
            .collect();
        Self {
            cancelled,
            files: RwLock::new(SharedFiles {
                active,
                issued,
                version: Uuid::new_v4().to_string(),
            }),
            pin: config.pin,
            event_tx: config.event_tx,
            sessions: Mutex::new(HashMap::new()),
            pending_approvals: Semaphore::new(MAX_PENDING_WEB_APPROVALS),
            pin_attempts: Mutex::new(LruCache::new(NonZeroUsize::new(200).unwrap())),
            archive_selections: Mutex::new(LruCache::new(NonZeroUsize::new(8).unwrap())),
        }
    }
}

/// Runtime counterpart of [`WebConfig`].
pub(crate) struct WebState {
    pub(crate) activities: activity::ActivityRegistry,
    runtime: SyncRwLock<WebRuntime>,
    pub(crate) upload_permission: SyncRwLock<(bool, u64)>,
    /// Which web share is active, holding the runtime state for web download.

    /// Translations for the web pages, served via `/i18n.json`.
    pub(crate) i18n: WebI18n,

    /// The HTML pages served to browsers, falling back to the embedded assets.
    pub(crate) pages: WebPages,
}

impl From<WebConfig> for WebState {
    fn from(config: WebConfig) -> Self {
        Self::with_activity_history(config, activity::WebActivityHistory::default())
    }
}

impl WebState {
    pub(crate) fn with_activity_history(
        config: WebConfig,
        history: activity::WebActivityHistory,
    ) -> Self {
        let duplex = matches!(&config.mode, WebMode::Duplex { .. });
        let allow_upload = matches!(
            &config.mode,
            WebMode::Upload
                | WebMode::Duplex {
                    allow_upload: true,
                    ..
                }
        );
        Self {
            activities: history.0,
            runtime: SyncRwLock::new(WebRuntime {
                duplex,
                share: config.mode.into(),
            }),
            upload_permission: SyncRwLock::new((allow_upload, 0)),
            i18n: config.i18n,
            pages: config.pages,
        }
    }
}

struct WebRuntime {
    duplex: bool,
    share: WebShare,
}

impl WebState {
    pub(crate) fn share(&self) -> WebShare {
        self.runtime.read().unwrap().share.clone()
    }
    pub(crate) fn duplex(&self) -> bool {
        self.runtime.read().unwrap().duplex
    }
    pub(crate) async fn append_files(
        &self,
        files: HashMap<String, FileDto>,
        allow_upload: bool,
    ) -> anyhow::Result<()> {
        self.patch_files(files, vec![], Some(allow_upload)).await
    }

    pub(crate) async fn patch_files(
        &self,
        files: HashMap<String, FileDto>,
        remove_ids: Vec<String>,
        allow_upload: Option<bool>,
    ) -> anyhow::Result<()> {
        let web = {
            let runtime = self.runtime.read().unwrap();
            anyhow::ensure!(runtime.duplex, "Duplex workspace is not active");
            runtime
                .share
                .download()
                .cloned()
                .ok_or_else(|| anyhow::anyhow!("Temporary share changed"))?
        };
        let mut current = web.files.write().await;
        let runtime = self.runtime.read().unwrap();
        anyhow::ensure!(
            runtime.duplex
                && runtime
                    .share
                    .download()
                    .is_some_and(|live| Arc::ptr_eq(live, &web)),
            "Temporary share changed"
        );
        anyhow::ensure!(
            files.keys().all(|id| !current.issued.contains(id)),
            "Shared file IDs are immutable"
        );
        let removed: HashSet<_> = remove_ids.iter().collect();
        anyhow::ensure!(
            removed.len() == remove_ids.len()
                && remove_ids.iter().all(|id| current.active.contains_key(id)),
            "Shared file selection changed"
        );
        // Bound lifetime tombstones. Closing/reopening creates a fresh share identity.
        anyhow::ensure!(
            files.is_empty() || current.issued.len().saturating_add(files.len()) <= 100_000,
            "Temporary share ID budget exhausted"
        );
        if !files.is_empty() || !remove_ids.is_empty() {
            for id in remove_ids {
                current.active.remove(&id).unwrap().cancelled.cancel();
            }
            for (id, file) in files {
                current.issued.insert(id.clone());
                current.active.insert(
                    id,
                    SharedFile {
                        file,
                        cancelled: web.cancelled.child_token(),
                    },
                );
            }
            current.version = Uuid::new_v4().to_string();
        }
        if let Some(allowed) = allow_upload {
            let mut permission = self.upload_permission.write().unwrap();
            if permission.0 != allowed {
                *permission = (allowed, permission.1.wrapping_add(1));
            }
        }
        Ok(())
    }

    pub(crate) fn set_mode(&self, mode: WebMode) {
        let duplex = matches!(&mode, WebMode::Duplex { .. });
        let allowed = matches!(
            &mode,
            WebMode::Upload
                | WebMode::Duplex {
                    allow_upload: true,
                    ..
                }
        );
        let mut runtime = self.runtime.write().unwrap();
        // Closing the temporary share affects only its pending/active downloads.
        if let Some(old) = runtime.share.download() {
            old.cancelled.cancel();
        }
        let mut permission = self.upload_permission.write().unwrap();
        *permission = (allowed, permission.1.wrapping_add(1));
        *runtime = WebRuntime {
            duplex,
            share: mode.into(),
        };
    }
}

/// Which web share is active, mirroring [`WebMode`] with the runtime state
/// for web download attached.
#[derive(Clone)]
pub(crate) enum WebShare {
    /// No web share active: `/` serves the 403 page.
    Disabled,

    /// Web download: the download page, with its runtime session state.
    Download(Arc<WebDownloadState>),

    /// The upload page.
    Upload,
}

impl WebShare {
    /// The web-download runtime state, when web download is active.
    pub(crate) fn download(&self) -> Option<&Arc<WebDownloadState>> {
        match self {
            WebShare::Download(download) => Some(download),
            WebShare::Disabled | WebShare::Upload => None,
        }
    }
}

impl From<WebMode> for WebShare {
    fn from(mode: WebMode) -> Self {
        match mode {
            WebMode::Disabled => WebShare::Disabled,
            WebMode::Download(download) | WebMode::Duplex { download, .. } => {
                WebShare::Download(Arc::new(WebDownloadState::new(download)))
            }
            WebMode::Upload => WebShare::Upload,
        }
    }
}

/// A download session of a single web client.
pub(crate) struct WebDownloadSession {
    /// The IP address of the web client. Downloads are only allowed from this address.
    ip: PeerIp,

    /// `false` while the prepare-download request is waiting for the application's decision.
    accepted: bool,
}

pub(crate) fn index(state: &AppState) -> Response<BoxedBody> {
    let pages = &state.web.pages;
    if state.web.duplex() {
        return html_response(
            StatusCode::OK,
            include_str!("../../../assets/web/workspace.html"),
            "text/html; charset=utf-8",
        );
    }
    match &state.web.share() {
        WebShare::Download(_) => html_response(
            StatusCode::OK,
            pages.download_html.as_deref().unwrap_or(DOWNLOAD_HTML),
            "text/html; charset=utf-8",
        ),
        WebShare::Upload => html_response(
            StatusCode::OK,
            pages.upload_html.as_deref().unwrap_or(UPLOAD_HTML),
            "text/html; charset=utf-8",
        ),
        WebShare::Disabled => error_403_page(pages),
    }
}

/// Optional workspace pages; legacy modes and protocol routes retain their behavior.
pub(crate) fn direction_page(state: &AppState, upload: bool) -> Response<BoxedBody> {
    if !state.web.duplex() {
        return error_403_page(&state.web.pages);
    }
    let html = if upload {
        state
            .web
            .pages
            .upload_html
            .as_deref()
            .unwrap_or(UPLOAD_HTML)
    } else {
        state
            .web
            .pages
            .download_html
            .as_deref()
            .unwrap_or(DOWNLOAD_HTML)
    };
    html_response(StatusCode::OK, html, "text/html; charset=utf-8")
}

pub(crate) async fn workspace_status(state: &AppState) -> Result<Response<BoxedBody>, AppError> {
    if !state.web.duplex() {
        return Err(AppError::Status(StatusCode::NOT_FOUND));
    }
    let web = require_web(state)?;
    let files = web.files.read().await;
    let mut response = JsonResponse {
        status: StatusCode::OK,
        body: serde_json::json!({
            "allowUpload": state.web.upload_permission.read().unwrap().0, "fileCount": files.active.len(), "fileVersion": files.version
        }),
    }
    .into_response();
    response
        .headers_mut()
        .insert("Cache-Control", http::HeaderValue::from_static("no-store"));
    Ok(response)
}

impl WebState {
    pub(crate) fn upload_permission(&self) -> Result<u64, AppError> {
        let duplex = self.duplex();
        let (allowed, epoch) = *self.upload_permission.read().unwrap();
        if duplex && !allowed {
            return Err(AppError::Message(
                StatusCode::FORBIDDEN,
                "Web uploads disabled".into(),
            ));
        }
        Ok(epoch)
    }
}

pub(crate) fn i18n(state: &AppState) -> Result<Response<BoxedBody>, AppError> {
    Ok(JsonResponse {
        status: StatusCode::OK,
        body: &state.web.i18n,
    }
    .into_response())
}

pub(crate) fn text_preview_script(state: &AppState) -> Result<Response<BoxedBody>, AppError> {
    require_web(state)?;
    Ok(Response::builder()
        .header("Content-Type", "text/javascript; charset=utf-8")
        .header("Cache-Control", "no-store")
        .header("X-Content-Type-Options", "nosniff")
        .body(full_body(TEXT_PREVIEW_JS))
        .unwrap())
}

/// Fixed public UI assets only; transfer data still requires the original session/PIN flow.
pub(crate) fn ui_asset(path: &str) -> Result<Response<BoxedBody>, AppError> {
    let (body, mime) = match path {
        "/assets/theme.js" => (
            include_str!("../../../assets/web/theme.js"),
            "text/javascript; charset=utf-8",
        ),
        "/assets/theme.css" => (
            include_str!("../../../assets/web/theme.css"),
            "text/css; charset=utf-8",
        ),
        "/assets/diagram-preview.js" => (
            include_str!("../../../assets/web/diagram-preview.js"),
            "text/javascript; charset=utf-8",
        ),
        "/assets/diagram-preview.css" => (
            include_str!("../../../assets/web/diagram-preview.css"),
            "text/css; charset=utf-8",
        ),
        "/assets/diagram-frame.html" => (
            include_str!("../../../assets/web/diagram-frame.html"),
            "text/html; charset=utf-8",
        ),
        "/assets/diagram-frame.js" => (
            include_str!("../../../assets/web/diagram-frame.js"),
            "text/javascript; charset=utf-8",
        ),
        "/assets/diagram-frame.css" => (
            include_str!("../../../assets/web/diagram-frame.css"),
            "text/css; charset=utf-8",
        ),
        "/assets/diagram-config.js" => (
            include_str!("../../../assets/web/diagram-config.js"),
            "text/javascript; charset=utf-8",
        ),
        "/assets/sha256.js" => (
            include_str!("../../../assets/web/sha256.js"),
            "text/javascript; charset=utf-8",
        ),
        "/assets/ls-cache.js" => (
            include_str!("../../../assets/web/ls-cache.js"),
            "text/javascript; charset=utf-8",
        ),
        "/assets/download-registry.js" => (
            include_str!("../../../assets/web/download-registry.js"),
            "text/javascript; charset=utf-8",
        ),
        "/assets/batch-downloads.js" => (
            include_str!("../../../assets/web/batch-downloads.js"),
            "text/javascript; charset=utf-8",
        ),
        "/assets/persistent-downloads.js" => (
            include_str!("../../../assets/web/persistent-downloads.js"),
            "text/javascript; charset=utf-8",
        ),
        "/assets/persistent-download-ui.js" => (
            include_str!("../../../assets/web/persistent-download-ui.js"),
            "text/javascript; charset=utf-8",
        ),
        "/assets/persistent-downloads.css" => (
            include_str!("../../../assets/web/persistent-downloads.css"),
            "text/css; charset=utf-8",
        ),
        "/assets/download-engine.js" => (
            include_str!("../../../assets/web/download-engine.js"),
            "text/javascript; charset=utf-8",
        ),
        "/assets/download-ui.js" => (
            include_str!("../../../assets/web/download-ui.js"),
            "text/javascript; charset=utf-8",
        ),
        "/assets/text-search.js" => (TEXT_SEARCH_JS, "text/javascript; charset=utf-8"),
        "/assets/text-reader.css" => (
            include_str!("../../../assets/web/text-reader.css"),
            "text/css; charset=utf-8",
        ),
        "/assets/markdown-preview.js" => (MARKDOWN_PREVIEW_JS, "text/javascript; charset=utf-8"),
        "/assets/markdown-worker.js" => (MARKDOWN_WORKER_JS, "text/javascript; charset=utf-8"),
        "/assets/preview-support.js" => (
            include_str!("../../../assets/web/preview-support.js"),
            "text/javascript; charset=utf-8",
        ),
        "/assets/media-preview.js" => (
            include_str!("../../../assets/web/media-preview.js"),
            "text/javascript; charset=utf-8",
        ),
        "/assets/media-preview.css" => (
            include_str!("../../../assets/web/media-preview.css"),
            "text/css; charset=utf-8",
        ),
        "/assets/image-source.js" => (
            include_str!("../../../assets/web/image-source.js"),
            "application/javascript; charset=utf-8",
        ),
        "/assets/image-preview.js" => (
            include_str!("../../../assets/web/image-preview.js"),
            "text/javascript; charset=utf-8",
        ),
        "/assets/image-preview.css" => (
            include_str!("../../../assets/web/image-preview.css"),
            "text/css; charset=utf-8",
        ),
        "/assets/markdown-stream.js" => (
            include_str!("../../../assets/web/markdown-stream.js"),
            "text/javascript; charset=utf-8",
        ),
        "/assets/markdown-stream-worker.js" => (
            include_str!("../../../assets/web/markdown-stream-worker.js"),
            "text/javascript; charset=utf-8",
        ),
        "/assets/markdown-table-header.js" => (
            include_str!("../../../assets/web/markdown-table-header.js"),
            "text/javascript; charset=utf-8",
        ),
        "/assets/markdown-inline-window.js" => (
            include_str!("../../../assets/web/markdown-inline-window.js"),
            "text/javascript; charset=utf-8",
        ),
        "/assets/markdown-blocks.js" => (
            include_str!("../../../assets/web/markdown-blocks.js"),
            "text/javascript; charset=utf-8",
        ),
        "/assets/vendor/marked-LICENSE.txt" => (MARKED_LICENSE, "text/plain; charset=utf-8"),
        "/assets/vendor/marked.umd.js" => (MARKED_JS, "text/javascript; charset=utf-8"),
        "/assets/workspace.js" => (
            include_str!("../../../assets/web/workspace.js"),
            "text/javascript; charset=utf-8",
        ),
        "/assets/web-ui.js" => (WEB_UI_JS, "text/javascript; charset=utf-8"),
        "/assets/web-ui.css" => (WEB_UI_CSS, "text/css; charset=utf-8"),
        "/assets/web-i18n.js" => (WEB_I18N_JS, "text/javascript; charset=utf-8"),
        "/assets/web-upload.js" => (WEB_UPLOAD_JS, "text/javascript; charset=utf-8"),
        _ => return Err(AppError::Status(StatusCode::NOT_FOUND)),
    };
    let mut builder = Response::builder()
        .header("Content-Type", mime)
        .header("Cache-Control", "no-store")
        .header("X-Content-Type-Options", "nosniff");
    if path == "/assets/diagram-frame.html" {
        builder = builder.header("Content-Security-Policy", "sandbox allow-scripts; default-src 'none'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src data:; font-src data:; connect-src 'none'; base-uri 'none'; form-action 'none'; frame-src 'none'").header("Referrer-Policy", "no-referrer");
    }
    Ok(builder.body(full_body(body)).unwrap())
}

/// Only generated, hashed offline dependencies; no filesystem path lookup.
pub(crate) fn diagram_asset(path: &str) -> Result<Response<BoxedBody>, AppError> {
    let (body, mime) =
        super::diagram_assets::asset(path).ok_or(AppError::Status(StatusCode::NOT_FOUND))?;
    let hashed = path.ends_with(".js");
    Ok(Response::builder()
        .header("Content-Type", mime)
        .header(
            "Cache-Control",
            if hashed {
                "public, max-age=31536000, immutable"
            } else {
                "no-store"
            },
        )
        .header("X-Content-Type-Options", "nosniff")
        .body(full_body(body))
        .unwrap())
}

const MAX_PENDING_WEB_APPROVALS: usize = 64;
const WEB_APPROVAL_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(120);
const WEB_CONTENT_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(30);

/// Bound the entire app round trip, including waiting for room in its event queue.
/// Dropping this future also closes the responder so a late decision/content reply
/// cannot affect a subsequent request. Never apply these deadlines to file bodies
/// or already-approved download sessions.
async fn web_event_response<T>(
    web: &WebDownloadState,
    cancelled: &CancellationToken,
    event: WebDownloadEvent,
    response: oneshot::Receiver<T>,
    timeout: std::time::Duration,
) -> Result<T, AppError> {
    let round_trip = async {
        web.event_tx
            .send(event)
            .await
            .map_err(|_| AppError::Status(StatusCode::INTERNAL_SERVER_ERROR))?;
        response
            .await
            .map_err(|_| AppError::Status(StatusCode::INTERNAL_SERVER_ERROR))
    };
    tokio::select! {
        biased;
        _ = cancelled.cancelled() => Err(AppError::Status(StatusCode::GONE)),
        result = tokio::time::timeout(timeout, round_trip) => result
            .map_err(|_| AppError::Status(StatusCode::GATEWAY_TIMEOUT))?,
    }
}

pub(crate) async fn prepare_download(
    req: Request<Incoming>,
    state: AppState,
    client_info: RequestClientInfo,
) -> Result<Response<BoxedBody>, AppError> {
    let web = require_web(&state)?;
    let query = parse_query(req.uri().query());

    // An accepted client can re-fetch the file list (e.g. page reload).
    if let Some(session_id) = query.get("sessionId") {
        let sessions = web.sessions.lock().await;
        let valid = sessions
            .get(session_id)
            .is_some_and(|session| session.accepted && session.ip == client_info.ip);
        if valid {
            drop(sessions);
            return Ok(file_list_response(&state, &web, session_id.clone()).await);
        }
    }

    check_pin(
        web.pin.as_deref(),
        &web.pin_attempts,
        &query,
        client_info.ip.ip,
    )
    .await?;

    // A stalled application or many abandoned tabs must not retain an unlimited
    // number of pending sessions. Session-list refresh bypasses this admission gate.
    let _pending = web
        .pending_approvals
        .try_acquire()
        .map_err(|_| AppError::Status(StatusCode::TOO_MANY_REQUESTS))?;

    let user_agent = req
        .headers()
        .get(http::header::USER_AGENT)
        .and_then(|value| value.to_str().ok())
        .map(str::to_string);

    // Tabs and repeated requests from one client must not replace each other.
    // In particular, declining/cancelling an old request must only remove its
    // own pending session, never a newer request from the same IP.
    let session_id = Uuid::new_v4().to_string();
    {
        let mut sessions = web.sessions.lock().await;
        sessions.insert(
            session_id.clone(),
            WebDownloadSession {
                ip: client_info.ip,
                accepted: false,
            },
        );
    }

    // Removes the pending session again if this request is declined or aborted
    // before the application accepted it.
    let mut pending_guard = PendingWebSessionGuard::new(web.clone(), session_id.clone());

    let (decision_tx, decision_rx) = oneshot::channel();
    let event = WebDownloadEvent::PrepareDownload {
        ip: client_info.ip,
        session_id: session_id.clone(),
        user_agent,
        decision_tx,
    };
    let accepted = match web_event_response(
        &web,
        &web.cancelled,
        event,
        decision_rx,
        WEB_APPROVAL_TIMEOUT,
    )
    .await
    {
        Ok(accepted) => accepted,
        Err(error) => {
            pending_guard.clear().await;
            return Err(error);
        }
    };

    if !accepted {
        pending_guard.clear().await;
        return Err(AppError::Message(
            StatusCode::FORBIDDEN,
            "File transfer rejected.".to_string(),
        ));
    }

    {
        let mut sessions = web.sessions.lock().await;
        if let Some(session) = sessions.get_mut(&session_id) {
            session.accepted = true;
        }
    }
    pending_guard.disarm();

    tracing::info!("Download session created: {session_id}");

    Ok(file_list_response(&state, &web, session_id).await)
}

pub(crate) async fn download<B>(
    req: Request<B>,
    state: AppState,
    client_info: RequestClientInfo,
) -> Result<Response<BoxedBody>, AppError> {
    download_inner(req, state, client_info, true).await
}

async fn download_inner<B>(
    req: Request<B>,
    state: AppState,
    client_info: RequestClientInfo,
    track: bool,
) -> Result<Response<BoxedBody>, AppError> {
    let web = require_web(&state)?;
    let query = parse_query(req.uri().query());

    let Some(session_id) = query.get("sessionId") else {
        return Err(AppError::BadRequest("Missing sessionId.".to_string()));
    };

    {
        let sessions = web.sessions.lock().await;
        let valid = sessions
            .get(session_id)
            .is_some_and(|session| session.accepted && session.ip == client_info.ip);
        if !valid {
            return Err(AppError::Message(
                StatusCode::FORBIDDEN,
                "Invalid sessionId.".to_string(),
            ));
        }
    }

    let Some(file_id) = query.get("fileId") else {
        return Err(AppError::BadRequest("Missing fileId.".to_string()));
    };

    let shared = {
        let files = web.files.read().await;
        files.active.get(file_id).cloned().ok_or_else(|| {
            if files.issued.contains(file_id) {
                AppError::Status(StatusCode::GONE)
            } else {
                AppError::Message(StatusCode::FORBIDDEN, "Invalid fileId.".to_string())
            }
        })?
    };
    let file = shared.file;
    let cancelled = shared.cancelled;

    let activity = if track
        && req.method() != hyper::Method::HEAD
        && !query.get("preview").is_some_and(|v| v == "1")
    {
        Some(state.web.activities.begin(
            session_id,
            &client_info.ip.to_string(),
            &file.file_name,
            &cancelled,
        )?)
    } else {
        None
    };
    let cancelled = activity
        .as_ref()
        .map(|a| a.cancel.clone())
        .unwrap_or(cancelled);

    // The application provides the file content as a stream of bytes.
    let (content_tx, content_rx) = oneshot::channel::<FileContent>();
    let event = WebDownloadEvent::FileDownload {
        session_id: session_id.clone(),
        file_id: file_id.clone(),
        file: file.clone(),
        content_tx,
    };
    let content =
        match web_event_response(&web, &cancelled, event, content_rx, WEB_CONTENT_TIMEOUT).await {
            Ok(content) => content,
            Err(error) => {
                if let Some(a) = &activity {
                    if !a.cancel.is_cancelled() {
                        a.failed();
                    }
                }
                return Err(error);
            }
        };

    // Browser media/image elements cannot attach If-Match. A preview-only
    // version query carries the HEAD identity through every native Range read.
    let mut download_headers = req.headers().clone();
    if query.get("preview").is_some_and(|value| value == "1") {
        if let Some(version) = query.get("version") {
            let value = hyper::header::HeaderValue::from_str(version)
                .map_err(|_| AppError::Status(StatusCode::BAD_REQUEST))?;
            if download_headers.get(hyper::header::IF_MATCH).is_some_and(|existing| existing != &value) {
                return Err(AppError::Status(StatusCode::PRECONDITION_FAILED));
            }
            download_headers.insert(hyper::header::IF_MATCH, value);
        }
    }

    let file_name = file.file_name.replace('/', "-");
    let encoded_file_name = utf8_percent_encode(&file_name, FILE_NAME_ENCODE_SET).to_string();
    let response = tokio::select! {
        biased;
        _ = cancelled.cancelled() => return Err(AppError::Status(StatusCode::GONE)),
        result = crate::http::server::common::download::response(
        content,
        &file,
        &download_headers,
        req.method() == hyper::Method::HEAD,
        query.get("preview").is_some_and(|value| value == "1"),
        &encoded_file_name,
        ) => match result { Ok(response) => response, Err(error) => { if let Some(a) = &activity { a.failed(); } return Err(error); } },
    };
    if let Some(activity) = activity {
        return Ok(activity.body(response));
    }
    let (parts, body) = response.into_parts();
    let frames = futures_util::stream::unfold(Some((body, cancelled)), |state| async move {
        let (mut body, cancel) = state?;
        tokio::select! {
            biased;
            _ = cancel.cancelled() => Some((Err(std::io::Error::other("Shared file withdrawn")), None)),
            frame = body.frame() => frame.map(|frame| (frame, Some((body, cancel)))),
        }
    });
    Ok(Response::from_parts(parts, StreamBody::new(frames).boxed()))
}

/// Optional browser batch endpoint; original single-file download stays unchanged.
pub(crate) async fn archive(
    mut req: Request<Incoming>,
    state: AppState,
    client: RequestClientInfo,
) -> Result<Response<BoxedBody>, AppError> {
    use super::archive::{self, Entry, Plan};
    let permit = archive::permit()?;
    let web = require_web(&state)?;
    let query = parse_query(req.uri().query());
    let mut params: Vec<(String, String)> = Vec::new();
    if req.method() == hyper::Method::POST {
        if req
            .headers()
            .get("sec-fetch-site")
            .is_some_and(|v| v == "cross-site")
        {
            return Err(AppError::Status(StatusCode::FORBIDDEN));
        }
        if let Some(origin) = req.headers().get("origin") {
            let expected = format!(
                "{}://{}",
                if state.tls { "https" } else { "http" },
                req.headers()
                    .get("host")
                    .and_then(|v| v.to_str().ok())
                    .unwrap_or("")
            );
            if origin.as_bytes() != expected.as_bytes() {
                return Err(AppError::Status(StatusCode::FORBIDDEN));
            }
        }
        if !req
            .headers()
            .get("content-type")
            .and_then(|v| v.to_str().ok())
            .is_some_and(|v| v.split(';').next() == Some("application/x-www-form-urlencoded"))
        {
            return Err(AppError::Status(StatusCode::UNSUPPORTED_MEDIA_TYPE));
        }
        let body = tokio::time::timeout(
            std::time::Duration::from_secs(10),
            http_body_util::Limited::new(req.body_mut(), 1024 * 1024).collect(),
        )
        .await
        .map_err(|_| AppError::Status(StatusCode::REQUEST_TIMEOUT))?
        .map_err(|_| AppError::Status(StatusCode::PAYLOAD_TOO_LARGE))?
        .to_bytes();
        params = form_urlencoded::parse(&body)
            .map(|(k, v)| (k.into_owned(), v.into_owned()))
            .collect();
    } else {
        if req.uri().query().unwrap_or("").len() > 8192 {
            return Err(AppError::BadRequest("Query too long".into()));
        }
        params.extend(
            form_urlencoded::parse(req.uri().query().unwrap_or("").as_bytes())
                .map(|(k, v)| (k.into_owned(), v.into_owned())),
        );
    }
    let sessions: Vec<_> = params.iter().filter(|(k, _)| k == "sessionId").collect();
    if sessions.len() != 1 {
        return Err(AppError::BadRequest("Missing or repeated sessionId".into()));
    }
    let session = sessions[0].1.clone();
    if !web
        .sessions
        .lock()
        .await
        .get(&session)
        .is_some_and(|s| s.accepted && s.ip == client.ip)
    {
        return Err(AppError::Status(StatusCode::FORBIDDEN));
    }
    let prepare = query.get("prepare").is_some_and(|v| v == "1");
    if prepare && req.method() != hyper::Method::POST {
        return Err(AppError::BadRequest("Preparation requires POST".into()));
    }
    let tickets: Vec<_> = params.iter().filter(|(k, _)| k == "selection").collect();
    let saved = if !tickets.is_empty() {
        if tickets.len() != 1
            || req.method() == hyper::Method::POST
            || params.iter().any(|(k, _)| k == "fileId" || k == "prefix")
        {
            return Err(AppError::BadRequest("Invalid selection ticket".into()));
        }
        let mut selections = web.archive_selections.lock().await;
        let saved = selections
            .get(&tickets[0].1)
            .filter(|s| s.usable(&session))
            .cloned()
            .ok_or(AppError::Status(StatusCode::GONE))?;
        Some(saved)
    } else {
        None
    };
    if let Some(saved) = &saved {
        params.extend(saved.ids.iter().map(|id| ("fileId".into(), id.clone())));
        if !saved.prefix.is_empty() {
            params.push(("prefix".into(), saved.prefix.clone()));
        }
    }
    let selected: HashSet<_> = params
        .iter()
        .filter(|(k, _)| k == "fileId")
        .map(|(_, v)| v.as_str())
        .collect();
    let prefixes: Vec<_> = params.iter().filter(|(k, _)| k == "prefix").collect();
    if prefixes.len() > 1 || !selected.is_empty() && !prefixes.is_empty() {
        return Err(AppError::BadRequest("Invalid selection".into()));
    }
    let prefix = prefixes.first().map(|p| p.1.as_str()).unwrap_or("");
    if !prefix.is_empty() {
        archive::valid_name(prefix)?;
        if !prefix.ends_with('/') {
            return Err(AppError::BadRequest("Invalid folder".into()));
        }
    }
    let mut plan = Plan::new();
    let version;
    {
        let files = web.files.read().await;
        version = files.version.clone();
        if saved.as_ref().is_some_and(|s| s.version != version) {
            return Err(AppError::Status(StatusCode::GONE));
        }
        if selected.iter().any(|id| !files.active.contains_key(*id)) {
            return Err(AppError::Status(StatusCode::GONE));
        }
        for (id, shared) in &files.active {
            if !selected.is_empty() && !selected.contains(id.as_str())
                || !shared.file.file_name.starts_with(prefix)
            {
                continue;
            }
            plan.push(Entry {
                name: shared.file.file_name.clone(),
                size: shared.file.size,
                source: id.clone(),
            })?;
        }
    }
    let entries = plan.finish()?;
    if entries.is_empty() {
        return Err(AppError::Status(StatusCode::NOT_FOUND));
    }
    if prepare {
        let id = Uuid::new_v4().to_string();
        web.archive_selections.lock().await.put(
            id.clone(),
            ArchiveSelection {
                session: session.clone(),
                version,
                ids: selected.iter().map(|id| (*id).to_owned()).collect(),
                prefix: prefix.to_owned(),
                created: tokio::time::Instant::now(),
            },
        );
        let query = form_urlencoded::Serializer::new(String::new())
            .append_pair("sessionId", &session)
            .append_pair("selection", &id)
            .finish();
        let mut response = JsonResponse {
            status: StatusCode::OK,
            body: serde_json::json!({"entries":entries.len(),
                "downloadUrl":format!("/api/legnasend/v1/web/archive?{query}")}),
        }
        .into_response();
        response
            .headers_mut()
            .insert("cache-control", "no-store".parse().unwrap());
        return Ok(response);
    }
    if query.get("check").is_some_and(|v| v == "1") {
        return Ok(JsonResponse {
            status: StatusCode::OK,
            body: serde_json::json!({"entries":entries.len()}),
        }
        .into_response());
    }
    let head = req.method() == hyper::Method::HEAD;
    let name = if prefix.is_empty() {
        "LegnaSend.zip".into()
    } else {
        format!(
            "{}.zip",
            prefix.trim_end_matches('/').rsplit('/').next().unwrap()
        )
    };
    let activity = if head {
        None
    } else {
        Some(
            state
                .web
                .activities
                .begin(&session, &client.ip.to_string(), &name, &web.cancelled)?,
        )
    };
    let response = archive::response(entries, &name, head, permit, move |id| {
        let state = state.clone();
        let client = client.clone();
        let session = session.clone();
        async move {
            let query = form_urlencoded::Serializer::new(String::new())
                .append_pair("sessionId", &session)
                .append_pair("fileId", &id)
                .finish();
            let req = Request::builder()
                .uri(format!("/api/localsend/v2/download?{query}"))
                .body(())
                .unwrap();
            let response = download_inner(req, state, client, false).await?;
            if response.status() != StatusCode::OK {
                return Err(AppError::Status(response.status()));
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

fn require_web(state: &AppState) -> Result<Arc<WebDownloadState>, AppError> {
    state
        .web
        .share()
        .download()
        .cloned()
        .ok_or(AppError::Message(
            StatusCode::FORBIDDEN,
            "Web download not initialized.".to_string(),
        ))
}

fn html_response(
    status: StatusCode,
    content: &str,
    content_type: &'static str,
) -> Response<BoxedBody> {
    let mut response = Response::new(full_body(content.to_owned()));
    *response.status_mut() = status;
    response.headers_mut().insert(
        http::header::CONTENT_TYPE,
        http::HeaderValue::from_static(content_type),
    );
    response
}

fn error_403_page(pages: &WebPages) -> Response<BoxedBody> {
    html_response(
        StatusCode::FORBIDDEN,
        pages.error_403_html.as_deref().unwrap_or(ERROR_403_HTML),
        "text/html; charset=utf-8",
    )
}

async fn file_list_response(
    state: &AppState,
    web: &WebDownloadState,
    session_id: String,
) -> Response<BoxedBody> {
    let info = state.info.lock().await.clone();

    let files = web.files.read().await;
    let mut response = JsonResponse {
        status: StatusCode::OK,
        body: PrepareDownloadResponseDtoV2 {
            info: InfoResponseDtoV2 {
                alias: info.alias,
                version: PROTOCOL_VERSION_V2.to_string(),
                device_model: info.device_model,
                device_type: info.device_type,
                fingerprint: info.token,
                download: true,
            },
            session_id,
            files: files
                .active
                .iter()
                .map(|(id, entry)| (id.clone(), entry.file.clone()))
                .collect(),
        },
    }
    .into_response();
    response
        .headers_mut()
        .insert("x-legnasend-file-version", files.version.parse().unwrap());
    response
        .headers_mut()
        .insert("cache-control", http::HeaderValue::from_static("no-store"));
    response
}

/// Removes a pending download session unless it was accepted.
///
/// The cleanup also runs on drop so the session is not leaked
/// when the request future is cancelled (e.g. the web client disconnected
/// while the application was still deciding).
struct PendingWebSessionGuard {
    web: Arc<WebDownloadState>,
    session_id: String,
    armed: bool,
}

impl PendingWebSessionGuard {
    fn new(web: Arc<WebDownloadState>, session_id: String) -> Self {
        Self {
            web,
            session_id,
            armed: true,
        }
    }

    /// Disarms the guard after the session was accepted.
    fn disarm(&mut self) {
        self.armed = false;
    }

    /// Removes the pending session immediately.
    async fn clear(&mut self) {
        self.armed = false;
        clear_pending_session(&self.web, &self.session_id).await;
    }
}

impl Drop for PendingWebSessionGuard {
    fn drop(&mut self) {
        if !self.armed {
            return;
        }
        let web = self.web.clone();
        let session_id = std::mem::take(&mut self.session_id);
        tokio::spawn(async move {
            clear_pending_session(&web, &session_id).await;
        });
    }
}

async fn clear_pending_session(web: &WebDownloadState, session_id: &str) {
    let mut sessions = web.sessions.lock().await;
    if sessions
        .get(session_id)
        .is_some_and(|session| !session.accepted)
    {
        sessions.remove(session_id);
        // Cleanup is never held hostage by a blocked UI/event queue. A bridge
        // that stores responders reconciles closed ones when consuming events,
        // including when this notification cannot enter a full queue.
        let _ = web
            .event_tx
            .try_send(WebDownloadEvent::PrepareDownloadAborted {
                session_id: session_id.to_owned(),
            });
    }
}

#[cfg(test)]
mod archive_selection_tests {
    use super::*;
    #[test]
    fn selection_is_bound_to_session_and_expires_without_extending_on_read() {
        let mut selection = ArchiveSelection {
            session: "approved".into(),
            version: "version".into(),
            ids: vec![],
            prefix: String::new(),
            created: tokio::time::Instant::now(),
        };
        assert!(selection.usable("approved"));
        assert!(!selection.usable("other"));
        selection.created -= ARCHIVE_SELECTION_TTL;
        assert!(!selection.usable("approved"));
    }
}

#[cfg(test)]
mod pending_event_tests {
    use super::*;
    use std::time::Duration;

    fn fixture() -> (Arc<WebDownloadState>, mpsc::Receiver<WebDownloadEvent>) {
        let (event_tx, event_rx) = mpsc::channel(1);
        (
            Arc::new(WebDownloadState::new(WebDownloadConfig {
                files: HashMap::new(),
                pin: None,
                event_tx,
            })),
            event_rx,
        )
    }

    fn request(id: &str) -> (WebDownloadEvent, oneshot::Receiver<bool>) {
        let (decision_tx, decision_rx) = oneshot::channel();
        (
            WebDownloadEvent::PrepareDownload {
                ip: PeerIp {
                    ip: "127.0.0.1".parse().unwrap(),
                    scope_id: None,
                },
                session_id: id.into(),
                user_agent: None,
                decision_tx,
            },
            decision_rx,
        )
    }

    #[tokio::test]
    async fn full_event_queue_is_included_in_timeout_and_does_not_enqueue_late_event() {
        let (web, mut events) = fixture();
        let (first, _first_response) = request("already queued");
        web.event_tx.send(first).await.unwrap();
        let (event, response) = request("timed out before enqueue");
        let result = web_event_response(
            &web,
            &web.cancelled,
            event,
            response,
            Duration::from_millis(5),
        )
        .await;
        assert!(matches!(
            result,
            Err(AppError::Status(StatusCode::GATEWAY_TIMEOUT))
        ));
        assert!(events.recv().await.is_some());
        assert!(events.try_recv().is_err());
    }

    #[tokio::test]
    async fn unanswered_event_times_out_closes_late_reply_and_releases_only_its_session() {
        let (web, mut events) = fixture();
        let ip = PeerIp {
            ip: "127.0.0.1".parse().unwrap(),
            scope_id: None,
        };
        web.sessions.lock().await.insert(
            "expired".into(),
            WebDownloadSession {
                ip,
                accepted: false,
            },
        );
        web.sessions
            .lock()
            .await
            .insert("approved".into(), WebDownloadSession { ip, accepted: true });
        let _permit = web.pending_approvals.try_acquire().unwrap();
        let mut guard = PendingWebSessionGuard::new(web.clone(), "expired".into());
        let (event, response) = request("expired");
        let result = web_event_response(
            &web,
            &web.cancelled,
            event,
            response,
            Duration::from_millis(5),
        )
        .await;
        assert!(matches!(
            result,
            Err(AppError::Status(StatusCode::GATEWAY_TIMEOUT))
        ));
        guard.clear().await;
        match events.recv().await.unwrap() {
            WebDownloadEvent::PrepareDownload { decision_tx, .. } => {
                assert!(decision_tx.send(true).is_err())
            }
            _ => panic!("expected approval"),
        }
        let sessions = web.sessions.lock().await;
        assert!(!sessions.contains_key("expired"));
        assert!(sessions["approved"].accepted);
    }

    #[tokio::test]
    async fn unanswered_content_expires_without_revoking_approved_session() {
        let (web, mut events) = fixture();
        web.sessions.lock().await.insert(
            "approved".into(),
            WebDownloadSession {
                ip: PeerIp {
                    ip: "127.0.0.1".parse().unwrap(),
                    scope_id: None,
                },
                accepted: true,
            },
        );
        let (content_tx, content_rx) = oneshot::channel();
        let event = WebDownloadEvent::FileDownload {
            session_id: "approved".into(),
            file_id: "file".into(),
            file: FileDto {
                id: "file".into(),
                file_name: "file.txt".into(),
                size: 1,
                file_type: "text/plain".into(),
                sha256: None,
                preview: None,
                metadata: None,
            },
            content_tx,
        };
        let result = web_event_response(
            &web,
            &web.cancelled,
            event,
            content_rx,
            Duration::from_millis(5),
        )
        .await;
        assert!(matches!(
            result,
            Err(AppError::Status(StatusCode::GATEWAY_TIMEOUT))
        ));
        match events.recv().await.unwrap() {
            WebDownloadEvent::FileDownload { content_tx, .. } => assert!(content_tx.is_closed()),
            _ => panic!("expected content request"),
        }
        assert!(web.sessions.lock().await["approved"].accepted);
    }

    #[tokio::test]
    async fn closed_share_wins_over_ready_late_decision() {
        let (web, _events) = fixture();
        let (event, response) = request("closed share");
        if let WebDownloadEvent::PrepareDownload { decision_tx, .. } = event {
            decision_tx.send(true).unwrap();
        }
        let (other, _) = request("unused");
        web.cancelled.cancel();
        let result = web_event_response(
            &web,
            &web.cancelled,
            other,
            response,
            Duration::from_secs(1),
        )
        .await;
        assert!(matches!(result, Err(AppError::Status(StatusCode::GONE))));
    }
}
