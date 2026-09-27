//! Short-lived previews pin one provider descriptor. The validator is lease +
//! descriptor metadata, never a content hash or a promise about a later open.
use super::*;
use bytes::Bytes;
use std::io::{self, Read, Seek, SeekFrom};
use tokio::sync::{Notify, OwnedSemaphorePermit};

const LEASE_IDLE: Duration = Duration::from_secs(120);
const CHUNK: usize = 64 * 1024;

pub(super) struct PreviewRegistry {
    inner: Arc<PreviewInner>,
}
struct PreviewInner {
    leases: StdMutex<HashMap<String, Arc<Lease>>>,
    slots: Arc<Semaphore>,
}
struct Lease {
    id: String,
    owner: String,
    file_id: String,
    file: StdMutex<std::fs::File>,
    name: String,
    mime: String,
    size: u64,
    etag: String,
    grant: Option<Grant>,
    cancel: CancellationToken,
    invalid: AtomicBool,
    expires: StdMutex<Instant>,
    changed: Arc<Notify>,
    // Retained by real metadata/read workers, even after cancellation removes
    // the public lease. No ninth FD appears while eight syscalls still block.
    _slot: OwnedSemaphorePermit,
}
impl PreviewRegistry {
    pub(super) fn revoke_owner(&self, owner: &str) {
        self.inner.leases.lock().unwrap().retain(|_, lease| {
            if lease.owner != owner {
                return true;
            }
            lease.cancel.cancel();
            false
        });
    }
    pub(super) fn new() -> Self {
        Self {
            inner: Arc::new(PreviewInner {
                leases: StdMutex::new(HashMap::new()),
                slots: Arc::new(Semaphore::new(8)),
            }),
        }
    }
}
impl Drop for PreviewInner {
    fn drop(&mut self) {
        for lease in self.leases.get_mut().unwrap().values() {
            lease.cancel.cancel();
        }
    }
}
fn valid_id(value: &str) -> bool {
    uuid::Uuid::parse_str(value).is_ok_and(|id| id.to_string() == value)
}
fn allowed_mime(value: &str, name: &str) -> Option<String> {
    let value = value.split(';').next()?.trim().to_ascii_lowercase();
    let value = if value == "application/octet-stream" {
        super::mime(name)
    } else {
        &value
    };
    download::preview_mime(value).map(|_| value.to_owned())
}
fn active(lease: &Lease) -> bool {
    !lease.cancel.is_cancelled()
        && *lease.expires.lock().unwrap() > Instant::now()
        && lease
            .grant
            .as_ref()
            .is_none_or(|g| !g.cancel.is_cancelled() && g.expires > Instant::now())
}
fn authorized(lease: &Lease, ws: &Workspace, grant: Option<&Grant>) -> bool {
    lease.owner == ws.document_owner
        && match (&lease.grant, grant) {
            (None, None) => true,
            (Some(old), Some(current)) => old.cancel == current.cancel,
            _ => false,
        }
}
async fn grant_ended(grant: Option<&Grant>) {
    if let Some(grant) = grant {
        tokio::select! {
            _ = grant.cancel.cancelled() => {},
            _ = tokio::time::sleep_until(grant.expires.into()) => {},
        }
    } else {
        std::future::pending::<()>().await;
    }
}
fn touch(lease: &Lease) {
    *lease.expires.lock().unwrap() = Instant::now() + LEASE_IDLE;
    lease.changed.notify_one();
}
fn watch(inner: &Arc<PreviewInner>, lease: &Arc<Lease>) {
    let inner = Arc::downgrade(inner);
    let weak = Arc::downgrade(lease);
    let id = lease.id.clone();
    let cancel = lease.cancel.clone();
    let grant = lease.grant.clone();
    let changed = lease.changed.clone();
    tokio::spawn(async move {
        loop {
            let Some(lease) = weak.upgrade() else { return };
            let expires = *lease.expires.lock().unwrap();
            drop(lease);
            tokio::select! {
                biased;
                _ = cancel.cancelled() => break,
                _ = async {
                    if let Some(grant) = &grant {
                        tokio::select! {
                            _ = grant.cancel.cancelled() => {},
                            _ = tokio::time::sleep_until(grant.expires.into()) => {},
                        }
                    } else { std::future::pending::<()>().await; }
                } => break,
                _ = changed.notified() => continue,
                _ = tokio::time::sleep_until(expires.into()) => {
                    // A concurrent successful read may have refreshed the lease.
                    if weak.upgrade().is_some_and(|l| *l.expires.lock().unwrap() > Instant::now()) { continue; }
                    break;
                }
            }
        }
        cancel.cancel();
        if let Some(inner) = inner.upgrade() {
            inner.leases.lock().unwrap().remove(&id);
        }
    });
}

pub(super) async fn prepare(
    registry: &Arc<DirectoryRegistry>,
    ws: Arc<Workspace>,
    id: &str,
    grant: Option<Grant>,
) -> Result<Response<BoxedBody>, AppError> {
    prepare_at(registry, ws, id, grant, API).await
}

async fn prepare_at(
    registry: &Arc<DirectoryRegistry>,
    ws: Arc<Workspace>,
    id: &str,
    grant: Option<Grant>,
    prefix: &str,
) -> Result<Response<BoxedBody>, AppError> {
    if !valid_id(id) || ws.config.document_tree.is_none() {
        return Err(bad());
    }
    let slot = registry
        .preview
        .inner
        .slots
        .clone()
        .try_acquire_owned()
        .map_err(|_| status(StatusCode::TOO_MANY_REQUESTS))?;
    let (file, metadata) = tokio::select! {biased;
        _ = grant_ended(grant.as_ref()) => return Err(status(StatusCode::UNAUTHORIZED)),
        result = documents::open_file(registry, &ws, id, Some(&ws.version_stopped)) => result?,
    };
    let mime = allowed_mime(&metadata.mime, &metadata.name)
        .ok_or_else(|| status(StatusCode::UNSUPPORTED_MEDIA_TYPE))?;
    if metadata.size > 9_007_199_254_740_991 {
        return Err(status(StatusCode::NOT_IMPLEMENTED));
    }
    let io = registry
        .io
        .clone()
        .try_acquire_owned()
        .map_err(|_| status(StatusCode::TOO_MANY_REQUESTS))?;
    let owner = ws.document_owner.clone();
    let file_id = id.to_owned();
    let cancel = ws.version_stopped.child_token();
    let stopped = cancel.clone();
    let requested_grant = grant.clone();
    let worker = tokio::task::spawn_blocking(move || {
        let _io = io;
        if cancel.is_cancelled()
            || grant
                .as_ref()
                .is_some_and(|g| g.cancel.is_cancelled() || g.expires <= Instant::now())
        {
            return Err(status(StatusCode::GONE));
        }
        let stat = file
            .metadata()
            .map_err(|_| status(StatusCode::BAD_GATEWAY))?;
        if !stat.is_file() || stat.len() != metadata.size {
            return Err(status(StatusCode::CONFLICT));
        }
        let id = uuid::Uuid::new_v4().to_string();
        let etag = download::file_stamp(&stat, &id);
        Ok(Arc::new(Lease {
            id,
            owner,
            file_id,
            file: StdMutex::new(file),
            name: metadata.name,
            mime,
            size: metadata.size,
            etag,
            grant,
            cancel,
            invalid: AtomicBool::new(false),
            expires: StdMutex::new(Instant::now() + LEASE_IDLE),
            changed: Arc::new(Notify::new()),
            _slot: slot,
        }))
    });
    let lease = tokio::select! {biased;
        _ = stopped.cancelled() => return Err(status(StatusCode::GONE)),
        _ = grant_ended(requested_grant.as_ref()) => return Err(status(StatusCode::UNAUTHORIZED)),
        result = worker => result.map_err(|_| status(StatusCode::BAD_GATEWAY))??,
    };
    if !active(&lease) {
        return Err(status(StatusCode::GONE));
    }
    let url = format!(
        "{prefix}/{}/files/{}/content?generation={}&preview=1&lease={}",
        ws.config.id, id, ws.config.generation, lease.id
    );
    let response = json_response(
        json!({"url":url,"size":lease.size,"etag":lease.etag,"mime":download::preview_mime(&lease.mime).unwrap().split(';').next().unwrap(),"lease":lease.id}),
    );
    registry
        .preview
        .inner
        .leases
        .lock()
        .unwrap()
        .insert(lease.id.clone(), lease.clone());
    watch(&registry.preview.inner, &lease);
    Ok(response)
}

pub(super) fn close(
    registry: &DirectoryRegistry,
    ws: &Workspace,
    grant: Option<&Grant>,
    id: &str,
) -> Result<Response<BoxedBody>, AppError> {
    if !valid_id(id) {
        return Err(bad());
    }
    let mut leases = registry.preview.inner.leases.lock().unwrap();
    if let Some(lease) = leases.get(id) {
        if !authorized(lease, ws, grant) {
            return Err(status(StatusCode::FORBIDDEN));
        }
        lease.cancel.cancel();
        leases.remove(id);
    }
    Ok(json_response(json!({"closed":true})))
}

fn verify_locked(lease: &Lease, file: &std::fs::File) -> io::Result<()> {
    if !active(lease) {
        return Err(io::Error::new(
            io::ErrorKind::Interrupted,
            "Preview lease ended",
        ));
    }
    let metadata = file.metadata()?;
    if !metadata.is_file()
        || metadata.len() != lease.size
        || download::file_stamp(&metadata, &lease.id) != lease.etag
    {
        lease.invalid.store(true, Ordering::Release);
        lease.cancel.cancel();
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "Preview source changed",
        ));
    }
    Ok(())
}
async fn verify(registry: &DirectoryRegistry, lease: Arc<Lease>) -> Result<(), AppError> {
    let io = registry
        .io
        .clone()
        .try_acquire_owned()
        .map_err(|_| status(StatusCode::TOO_MANY_REQUESTS))?;
    let cancelled = lease.cancel.clone();
    let cause = lease.clone();
    let worker = tokio::task::spawn_blocking(move || {
        let _io = io;
        let file = lease.file.lock().unwrap();
        verify_locked(&lease, &file)
    });
    tokio::select! {biased;
        _ = cancelled.cancelled() => Err(status(if cause.invalid.load(Ordering::Acquire) {StatusCode::PRECONDITION_FAILED} else {StatusCode::GONE})),
        result = worker => result.map_err(|_| status(StatusCode::BAD_GATEWAY))?
            .map_err(|e|status(if e.kind()==io::ErrorKind::InvalidData {StatusCode::PRECONDITION_FAILED} else {StatusCode::GONE})),
    }
}
async fn read_piece(
    lease: Arc<Lease>,
    io: Arc<Semaphore>,
    offset: u64,
    len: usize,
) -> io::Result<Bytes> {
    let cancelled = lease.cancel.clone();
    let permit = tokio::select! {biased;
        _ = cancelled.cancelled() => return Err(io::Error::new(io::ErrorKind::Interrupted,"Preview ended")),
        permit = io.acquire_owned() => permit.map_err(|_| io::Error::other("Preview reader stopped"))?,
    };
    let worker = tokio::task::spawn_blocking(move || {
        let _permit = permit;
        let mut file = lease.file.lock().unwrap();
        verify_locked(&lease, &file)?;
        let mut bytes = vec![0; len];
        file.seek(SeekFrom::Start(offset))?;
        file.read_exact(&mut bytes)?;
        verify_locked(&lease, &file)?;
        touch(&lease);
        Ok(Bytes::from(bytes))
    });
    tokio::select! {biased;
        _ = cancelled.cancelled() => Err(io::Error::new(io::ErrorKind::Interrupted,"Preview ended")),
        result = worker => result.map_err(io::Error::other)?,
    }
}

pub(super) async fn content<B>(
    registry: &Arc<DirectoryRegistry>,
    ws: Arc<Workspace>,
    file_id: &str,
    req: &Request<B>,
    grant: Option<Grant>,
    lease_id: &str,
) -> Result<Response<BoxedBody>, AppError> {
    if !valid_id(lease_id) {
        return Err(bad());
    }
    let lease = registry
        .preview
        .inner
        .leases
        .lock()
        .unwrap()
        .get(lease_id)
        .cloned()
        .ok_or_else(|| status(StatusCode::GONE))?;
    if lease.file_id != file_id || !authorized(&lease, &ws, grant.as_ref()) {
        return Err(status(StatusCode::FORBIDDEN));
    }
    if !active(&lease) {
        return Err(status(StatusCode::GONE));
    }
    let query: HashMap<_, _> = form_urlencoded::parse(req.uri().query().unwrap_or("").as_bytes())
        .into_owned()
        .collect();
    if query.get("version").is_some_and(|v| v != &lease.etag) {
        return Err(status(StatusCode::PRECONDITION_FAILED));
    }
    if req.headers().get(header::IF_MATCH).is_some_and(|h| {
        !h.to_str()
            .ok()
            .is_some_and(|v| v.trim() == "*" || v.split(',').any(|v| v.trim() == lease.etag))
    }) {
        return Err(status(StatusCode::PRECONDITION_FAILED));
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
    verify(registry, lease.clone()).await?;
    touch(&lease);
    let head = req.method() == Method::HEAD;
    let range = if !head
        && req.headers().get_all(header::RANGE).iter().count() <= 1
        && req
            .headers()
            .get(header::IF_RANGE)
            .is_none_or(|v| v.to_str().ok() == Some(&lease.etag))
    {
        req.headers()
            .get(header::RANGE)
            .and_then(|v| v.to_str().ok())
            .map(|v| download::select_range(v, lease.size))
            .unwrap_or(download::RangeSelection::Full)
    } else {
        download::RangeSelection::Full
    };
    let (status_code, start, len) = match range {
        download::RangeSelection::Full => (StatusCode::OK, 0, lease.size),
        download::RangeSelection::Partial { start, len } => {
            (StatusCode::PARTIAL_CONTENT, start, len)
        }
        download::RangeSelection::Unsatisfiable => (StatusCode::RANGE_NOT_SATISFIABLE, 0, 0),
    };
    let body = if head || len == 0 {
        response::empty_body()
    } else {
        let io = registry.io.clone();
        let state = (lease.clone(), io, start, len, global, local);
        let stream = futures_util::stream::try_unfold(
            state,
            |(lease, io, offset, remaining, global, local)| async move {
                if remaining == 0 {
                    return Ok::<_, io::Error>(None);
                }
                let len = remaining.min(CHUNK as u64) as usize;
                let bytes = read_piece(lease.clone(), io.clone(), offset, len).await?;
                Ok(Some((
                    Frame::data(bytes),
                    (
                        lease,
                        io,
                        offset + len as u64,
                        remaining - len as u64,
                        global,
                        local,
                    ),
                )))
            },
        );
        BodyExt::boxed(StreamBody::new(stream))
    };
    let mut response = Response::new(body);
    *response.status_mut() = status_code;
    let headers = response.headers_mut();
    headers.insert(header::CONTENT_LENGTH, len.into());
    headers.insert(header::ACCEPT_RANGES, "bytes".parse().unwrap());
    headers.insert(header::ETAG, lease.etag.parse().unwrap());
    headers.insert(header::CACHE_CONTROL, "private, no-store".parse().unwrap());
    headers.insert("x-content-type-options", "nosniff".parse().unwrap());
    headers.insert(
        header::CONTENT_TYPE,
        download::preview_mime(&lease.mime)
            .unwrap()
            .parse()
            .unwrap(),
    );
    headers.insert(
        "content-security-policy",
        "default-src 'none'; sandbox".parse().unwrap(),
    );
    let encoded =
        percent_encoding::utf8_percent_encode(&lease.name, percent_encoding::NON_ALPHANUMERIC);
    headers.insert(
        header::CONTENT_DISPOSITION,
        format!("inline; filename=\"{encoded}\"; filename*=UTF-8''{encoded}")
            .parse()
            .map_err(|_| status(StatusCode::BAD_GATEWAY))?,
    );
    if status_code == StatusCode::PARTIAL_CONTENT {
        headers.insert(
            header::CONTENT_RANGE,
            format!("bytes {start}-{}/{}", start + len - 1, lease.size)
                .parse()
                .unwrap(),
        );
    } else if status_code == StatusCode::RANGE_NOT_SATISFIABLE {
        headers.insert(
            header::CONTENT_RANGE,
            format!("bytes */{}", lease.size).parse().unwrap(),
        );
    }
    Ok(response)
}

impl DirectoryRegistry {
    /// Integration route enters only after the shared API middleware checks its
    /// files.read scope, rate budgets and current actor cancellation lifetime.
    pub(in crate::http::server) async fn integration_preview(
        self: &Arc<Self>,
        req: &mut Request<Incoming>,
        workspace: &str,
        query: HashMap<String, String>,
        scope: &super::super::integration::WorkspaceGrant,
        anonymous: bool,
        authority: Grant,
        closing: bool,
    ) -> Result<Response<BoxedBody>, AppError> {
        if !scope.allows(workspace) {
            return Err(status(StatusCode::NOT_FOUND));
        }
        let ws = self.workspace(workspace).await?;
        if anonymous && (!ws.config.visible || ws.access.protected()) {
            return Err(status(StatusCode::NOT_FOUND));
        }
        if ws.config.document_tree.is_none() {
            return Err(status(StatusCode::NOT_IMPLEMENTED));
        }
        if query.len() != 1
            || query.get("generation").and_then(|v| v.parse::<u64>().ok())
                != Some(ws.config.generation)
        {
            return Err(status(StatusCode::CONFLICT));
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
        let mut data = Vec::new();
        let read = async {
            while let Some(frame) = req.body_mut().frame().await {
                let frame = frame.map_err(|_| bad())?;
                if let Ok(bytes) = frame.into_data() {
                    if data.len() + bytes.len() > 1024 {
                        return Err(status(StatusCode::PAYLOAD_TOO_LARGE));
                    }
                    data.extend_from_slice(&bytes);
                }
            }
            Ok::<_, AppError>(())
        };
        tokio::time::timeout(Duration::from_secs(10), read)
            .await
            .map_err(|_| status(StatusCode::REQUEST_TIMEOUT))??;
        let body: HashMap<String, String> = serde_json::from_slice(&data).map_err(|_| bad())?;
        if body.len() != 1 {
            return Err(bad());
        }
        if closing {
            close(
                self,
                &ws,
                Some(&authority),
                body.get("lease").ok_or_else(bad)?,
            )
        } else {
            let prefix = format!("{}/workspaces", super::super::integration::PREFIX);
            prepare_at(
                self,
                ws,
                body.get("id").ok_or_else(bad)?,
                Some(authority),
                &prefix,
            )
            .await
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    struct OwnedSource {
        path: std::path::PathBuf,
        file: Option<std::fs::File>,
    }
    impl OwnedSource {
        fn as_file_mut(&mut self) -> &mut std::fs::File {
            self.file.as_mut().unwrap()
        }
    }
    impl Drop for OwnedSource {
        fn drop(&mut self) {
            self.file.take();
            let _ = std::fs::remove_file(&self.path);
        }
    }
    fn fixture(bytes: &[u8]) -> (OwnedSource, Arc<Lease>, Arc<Semaphore>) {
        let path = std::env::temp_dir().join(format!("legna-preview-{}", uuid::Uuid::new_v4()));
        let mut source = OwnedSource {
            file: Some(
                std::fs::OpenOptions::new()
                    .write(true)
                    .create_new(true)
                    .open(&path)
                    .unwrap(),
            ),
            path,
        };
        source.as_file_mut().write_all(bytes).unwrap();
        source.as_file_mut().flush().unwrap();
        let file = std::fs::File::open(&source.path).unwrap();
        let id = uuid::Uuid::new_v4().to_string();
        let slots = Arc::new(Semaphore::new(1));
        let lease = Arc::new(Lease {
            etag: download::file_stamp(&file.metadata().unwrap(), &id),
            id,
            owner: "owner".into(),
            file_id: uuid::Uuid::new_v4().to_string(),
            file: StdMutex::new(file),
            name: "fixture.txt".into(),
            mime: "text/plain".into(),
            size: bytes.len() as u64,
            grant: None,
            cancel: CancellationToken::new(),
            invalid: AtomicBool::new(false),
            expires: StdMutex::new(Instant::now() + LEASE_IDLE),
            changed: Arc::new(Notify::new()),
            _slot: slots.clone().try_acquire_owned().unwrap(),
        });
        (source, lease, slots)
    }

    #[tokio::test]
    async fn concurrent_ranges_share_descriptor_without_sharing_position() {
        let content: Vec<u8> = (0..200_000).map(|n| (n % 251) as u8).collect();
        let (_source, lease, _slots) = fixture(&content);
        let io = Arc::new(Semaphore::new(8));
        let (a, b, c) = tokio::join!(
            read_piece(lease.clone(), io.clone(), 117, 32768),
            read_piece(lease.clone(), io.clone(), 100_001, 65536),
            read_piece(lease.clone(), io, 70_000, 173),
        );
        assert_eq!(a.unwrap().as_ref(), &content[117..117 + 32768]);
        assert_eq!(b.unwrap().as_ref(), &content[100_001..100_001 + 65536]);
        assert_eq!(c.unwrap().as_ref(), &content[70_000..70_000 + 173]);
    }

    #[tokio::test]
    async fn mutation_invalidates_the_pinned_lease_instead_of_reopening() {
        let (mut source, lease, _slots) = fixture(b"original");
        assert_eq!(
            read_piece(lease.clone(), Arc::new(Semaphore::new(1)), 0, 8)
                .await
                .unwrap(),
            &b"original"[..]
        );
        source.as_file_mut().set_len(9).unwrap();
        assert!(
            read_piece(lease.clone(), Arc::new(Semaphore::new(1)), 0, 8)
                .await
                .is_err()
        );
        assert!(lease.cancel.is_cancelled());
    }

    #[tokio::test]
    async fn expiry_removes_registry_owner_and_releases_actual_descriptor() {
        let (_source, lease, slots) = fixture(b"x");
        let registry = PreviewRegistry::new();
        registry
            .inner
            .leases
            .lock()
            .unwrap()
            .insert(lease.id.clone(), lease.clone());
        watch(&registry.inner, &lease);
        *lease.expires.lock().unwrap() = Instant::now() - Duration::from_secs(1);
        lease.changed.notify_one();
        let weak = Arc::downgrade(&lease);
        drop(lease);
        tokio::time::timeout(Duration::from_secs(1), async {
            while weak.upgrade().is_some() {
                tokio::task::yield_now().await;
            }
        })
        .await
        .unwrap();
        assert!(registry.inner.leases.lock().unwrap().is_empty());
        assert_eq!(slots.available_permits(), 1);
    }

    #[tokio::test]
    async fn cancelled_blocked_worker_retains_slot_until_real_read_returns() {
        let (_source, lease, slots) = fixture(b"x");
        let held = lease.file.lock().unwrap();
        let pending_lease = lease.clone();
        let io = Arc::new(Semaphore::new(1));
        let pending_io = io.clone();
        let task = tokio::spawn(async move { read_piece(pending_lease, pending_io, 0, 1).await });
        tokio::time::timeout(Duration::from_secs(1), async {
            while io.available_permits() != 0 {
                tokio::task::yield_now().await;
            }
        })
        .await
        .unwrap();
        lease.cancel.cancel();
        assert!(task.await.unwrap().is_err());
        assert_eq!(slots.available_permits(), 0);
        assert_eq!(io.available_permits(), 0);
        drop(held);
        drop(lease);
        tokio::time::timeout(Duration::from_secs(1), async {
            while slots.available_permits() != 1 || io.available_permits() != 1 {
                tokio::task::yield_now().await;
            }
        })
        .await
        .unwrap();
    }

    #[test]
    fn mime_allows_reader_media_but_never_active_html() {
        assert_eq!(
            allowed_mime("application/octet-stream", "notes.md").as_deref(),
            Some("text/markdown")
        );
        assert!(allowed_mime("text/html", "unsafe.html").is_none());
        assert!(allowed_mime("image/svg+xml", "unsafe.svg").is_none());
        assert!(allowed_mime("application/javascript", "unsafe.js").is_none());
        assert_eq!(
            allowed_mime("video/mp4", "clip.mp4").as_deref(),
            Some("video/mp4")
        );
    }
}
