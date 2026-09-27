//! Opt-in browser directory uploads. These routes do not alter LocalSend v2.
use super::{
    API, DirectoryRegistry, Workspace, bad, directory_auth::Grant, json_response, open_directory,
    status, validate_relative,
};
use crate::http::server::common::{error::AppError, response::BoxedBody};
use crate::http::server::integration::UploadAuthority;
use crate::http::server::web::activity::{Guard, WorkspaceActivity};
use bytes::Bytes;
use cap_fs_ext::{DirExt, FollowSymlinks, OpenOptionsFollowExt};
use cap_std::fs::{Dir, OpenOptions};
use http_body_util::BodyExt;
use hyper::{Request, Response, StatusCode, body::Incoming, header};
use serde_json::json;
use sha2::{Digest, Sha256};
use std::{
    collections::HashMap,
    fs::File,
    io::{self, Write},
    sync::Arc,
    time::Instant,
};
use tokio::sync::{Mutex, Semaphore, mpsc};
use tokio_util::sync::CancellationToken;

static ACTIVE: Semaphore = Semaphore::const_new(8);
const FRAME: usize = 64 * 1024;
pub(super) struct Control {
    pub(super) stopped: CancellationToken,
    admissions: Arc<Semaphore>,
    pub(super) publication: Mutex<()>,
    pub(super) approvals: super::approval::Approvals,
}
impl Control {
    pub(super) fn new() -> Self {
        Self {
            stopped: CancellationToken::new(),
            admissions: Arc::new(Semaphore::new(2)),
            publication: Mutex::new(()),
            approvals: super::approval::Approvals::default(),
        }
    }
    pub(super) fn successor(&self) -> Self {
        Self {
            stopped: CancellationToken::new(),
            admissions: self.admissions.clone(),
            publication: Mutex::new(()),
            approvals: super::approval::Approvals::default(),
        }
    }
    pub(super) async fn revoke(&self) {
        self.stopped.cancel();
        // On return no old writer can enter or remain in its publication commit.
        let _commit = self.publication.lock().await;
    }
}
use crate::http::server::common::receive_cache_files::Message;
type Result<T> = std::result::Result<T, StatusCode>;
fn storage(error: io::Error) -> StatusCode {
    match error.kind() {
        io::ErrorKind::AlreadyExists => StatusCode::CONFLICT,
        io::ErrorKind::PermissionDenied => StatusCode::FORBIDDEN,
        _ => StatusCode::INTERNAL_SERVER_ERROR,
    }
}
pub(super) fn check(
    ws: &Workspace,
    cancel: &CancellationToken,
    grant: &Option<Grant>,
) -> Result<()> {
    if grant
        .as_ref()
        .is_some_and(|g| g.cancel.is_cancelled() || g.expires <= Instant::now())
    {
        return Err(StatusCode::UNAUTHORIZED);
    }
    if cancel.is_cancelled() || ws.stopped.is_cancelled() || ws.uploads.stopped.is_cancelled() {
        return Err(StatusCode::CONFLICT);
    }
    Ok(())
}

pub(super) fn validate_parent(ws: &Workspace, parent: &str) -> std::result::Result<(), AppError> {
    if parent.is_empty() {
        return Ok(());
    }
    if ws.config.document_tree.is_none()
        || uuid::Uuid::parse_str(parent).is_err()
        || parent.len() != 36
    {
        return Err(bad());
    }
    Ok(())
}

pub(super) async fn handle(
    registry: &Arc<DirectoryRegistry>,
    req: &mut Request<Incoming>,
    tls: bool,
    peer: &str,
) -> std::result::Result<Response<BoxedBody>, AppError> {
    let route = req
        .uri()
        .path()
        .strip_prefix(&format!("{API}/"))
        .unwrap_or("");
    let parts: Vec<_> = route.split('/').collect();
    if parts.len() != 2 || parts[1] != "upload" {
        return Err(bad());
    }
    let ws = registry.workspace(parts[0]).await?;
    handle_workspace(registry, ws, req, tls, None, peer).await
}
pub(super) async fn integration(
    registry: &Arc<DirectoryRegistry>,
    req: &mut Request<Incoming>,
    workspace: &str,
    authority: UploadAuthority,
) -> std::result::Result<Response<BoxedBody>, AppError> {
    let ws = registry.workspace(workspace).await?;
    handle_workspace(registry, ws, req, false, Some(authority), "").await
}
async fn handle_workspace(
    registry: &Arc<DirectoryRegistry>,
    ws: Arc<Workspace>,
    req: &mut Request<Incoming>,
    tls: bool,
    authority: Option<UploadAuthority>,
    peer: &str,
) -> std::result::Result<Response<BoxedBody>, AppError> {
    let keyed = authority.is_some();
    if !keyed && !ws.config.allow_upload {
        return Err(status(StatusCode::FORBIDDEN));
    }
    for key in [
        "x-legnasend-upload",
        "x-legnasend-upload-token",
        "cookie",
        "origin",
        "host",
        "sec-fetch-site",
        "content-type",
        "content-length",
    ] {
        if req.headers().get_all(key).iter().count() > 1 {
            return Err(bad());
        }
    }
    if !keyed
        && (req
            .headers()
            .get("x-legnasend-upload")
            .is_none_or(|value| value != "1")
            || req
                .headers()
                .get("sec-fetch-site")
                .is_some_and(|value| value == "cross-site"))
    {
        return Err(status(StatusCode::FORBIDDEN));
    }
    if let Some(origin) = req.headers().get(header::ORIGIN).filter(|_| !keyed) {
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
        .and_then(|v| v.to_str().ok())
        .map(|v| {
            v.split(';')
                .next()
                .unwrap_or("")
                .trim()
                .eq_ignore_ascii_case("application/octet-stream")
        })
        != Some(true)
    {
        return Err(status(StatusCode::UNSUPPORTED_MEDIA_TYPE));
    }
    if req.headers().contains_key(header::TRANSFER_ENCODING) {
        return Err(status(StatusCode::LENGTH_REQUIRED));
    }
    let size = req
        .headers()
        .get(header::CONTENT_LENGTH)
        .and_then(|v| v.to_str().ok())
        .and_then(|v| {
            if !v.is_empty() && v.bytes().all(|b| b.is_ascii_digit()) {
                v.parse::<u64>().ok()
            } else {
                None
            }
        })
        .ok_or_else(|| status(StatusCode::LENGTH_REQUIRED))?;
    let raw = req.uri().query().unwrap_or("");
    if raw.len() > 16384 {
        return Err(bad());
    }
    let mut query = HashMap::new();
    for (key, value) in form_urlencoded::parse(raw.as_bytes()) {
        if !["generation", "path", "directory", "parent"].contains(&key.as_ref())
            || query.insert(key.into_owned(), value.into_owned()).is_some()
        {
            return Err(bad());
        }
    }
    let generation = query
        .get("generation")
        .ok_or_else(bad)?
        .parse::<u64>()
        .map_err(|_| bad())?;
    if generation != ws.config.generation {
        return Err(status(StatusCode::CONFLICT));
    }
    let parent = query.get("parent").cloned().unwrap_or_default();
    validate_parent(&ws, &parent)?;
    let path = query.get("path").ok_or_else(bad)?.clone();
    validate_relative(&path)?;
    if path.is_empty() || path.split('/').count() > 64 || path.split('/').any(|p| p.len() > 255) {
        return Err(bad());
    }
    let directory = match query.get("directory").map(String::as_str) {
        None | Some("false") => false,
        Some("true") => true,
        _ => return Err(bad()),
    };
    if directory && size != 0 {
        return Err(bad());
    }
    let grant = if keyed {
        None
    } else {
        ws.access.authorize(req.headers(), &ws.config.id)?
    };
    let global = ACTIVE
        .try_acquire()
        .map_err(|_| status(StatusCode::TOO_MANY_REQUESTS))?;
    let local = ws
        .uploads
        .admissions
        .clone()
        .try_acquire_owned()
        .map_err(|_| status(StatusCode::TOO_MANY_REQUESTS))?;
    if !keyed && ws.config.upload_approval {
        super::approval::consume(&ws, req, peer, &parent, &path, size, directory)?;
    }
    // Admission/approval failures are not transfers. Own this guard in the writer,
    // so body EOF or a dropped HTTP handler cannot report a saved file early.
    let activity = registry.activities.begin_workspace(
        peer,
        &path,
        &ws.uploads.stopped,
        WorkspaceActivity {
            id: &ws.config.id,
            name: &ws.config.name,
            direction: "receive",
            operation: if directory { "directory" } else { "upload" },
            origin: if keyed { "api" } else { "browser" },
        },
    )?;
    activity.started(size);
    let cancel = activity.cancel.clone();
    let _drop_cancels = cancel.clone().drop_guard();
    let (tx, rx) = mpsc::channel(8);
    let worker_cancel = cancel.clone();
    let worker_grant = grant.clone();
    let worker_authority = authority.clone();
    let registry = registry.clone();
    let finished = Arc::new(std::sync::atomic::AtomicBool::new(false));
    let worker_finished = finished.clone();
    let runtime = tokio::runtime::Handle::current();
    let mut worker = tokio::task::spawn_blocking(move || {
        let (_global, _local) = (global, local);
        let result = if ws.config.document_tree.is_some() {
            super::document_upload::receive(
                &registry,
                ws,
                &parent,
                &path,
                directory,
                size,
                worker_cancel,
                worker_grant,
                worker_authority,
                &activity,
                rx,
                &runtime,
            )
        } else {
            receive(
                ws,
                path,
                directory,
                size,
                worker_cancel,
                WriteAccess {
                    grant: worker_grant,
                    authority: worker_authority,
                    activity: Some(&activity),
                },
                rx,
            )
        };
        if result.is_err() {
            activity.failed();
        }
        worker_finished.store(true, std::sync::atomic::Ordering::Release);
        result
    });
    let revoked = async {
        if let Some(authority) = authority {
            let expiry = async {
                if let Some(expiry) = authority.expires {
                    loop {
                        let now = crate::http::server::integration::upload_unix_time();
                        if now >= expiry {
                            break;
                        }
                        tokio::time::sleep(std::time::Duration::from_secs((expiry - now).min(1)))
                            .await;
                    }
                } else {
                    std::future::pending::<()>().await;
                }
            };
            tokio::select! { _ = authority.cancel.cancelled() => {}, _ = expiry => {} }
        } else if let Some(grant) = grant {
            tokio::select! { _ = grant.cancel.cancelled() => {}, _ = tokio::time::sleep_until(grant.expires.into()) => {} }
        } else {
            std::future::pending::<()>().await;
        }
    };
    tokio::pin!(revoked);
    let mut early = None;
    'body: loop {
        let frame = tokio::select! {
            biased;
            _ = cancel.cancelled() => break,
            _ = &mut revoked => { cancel.cancel(); break; },
            result = &mut worker => { early = Some(result); break; },
            frame = req.body_mut().frame() => frame,
        };
        match frame {
            Some(Ok(frame)) => {
                if let Ok(data) = frame.into_data() {
                    for part in data.chunks(FRAME) {
                        let sent = tokio::select! {
                            biased;
                            _ = cancel.cancelled() => break 'body,
                            _ = &mut revoked => { cancel.cancel(); break 'body; },
                            result = tx.send(Message::Data(Bytes::copy_from_slice(part))) => result,
                        };
                        if sent.is_err() {
                            break 'body;
                        }
                    }
                }
            }
            None => {
                let _ = tx.send(Message::Finish).await;
                break;
            }
            Some(Err(_)) => break,
        }
    }
    drop(tx);
    let result = match early {
        Some(result) => result,
        None => tokio::select! {
            biased;
            result = &mut worker => result,
            _ = cancel.cancelled() => {
                // Guard drop cancels descendants even after a successful commit.
                // Preserve the actual worker result rather than racing that drop.
                if finished.load(std::sync::atomic::Ordering::Acquire) { worker.await }
                else { return Err(status(StatusCode::CONFLICT)); }
            },
            _ = &mut revoked => { cancel.cancel(); return Err(status(StatusCode::UNAUTHORIZED)); },
        },
    }
    .map_err(|_| status(StatusCode::INTERNAL_SERVER_ERROR))?
    .map_err(status)?;
    let mut response = json_response(result);
    *response.status_mut() = StatusCode::CREATED;
    Ok(response)
}

fn same_directory(a: &Dir, b: &Dir) -> io::Result<bool> {
    Ok(
        same_file::Handle::from_file(a.try_clone()?.into_std_file())?
            == same_file::Handle::from_file(b.try_clone()?.into_std_file())?,
    )
}
struct Transaction {
    parent: Arc<Dir>,
    temporary: Option<(String, File)>,
    registration: Option<crate::receive_registry::Registration>,
    created: Vec<(Arc<Dir>, String, Arc<Dir>)>,
    published: bool,
}
impl Drop for Transaction {
    fn drop(&mut self) {
        if let Some((name, file)) = &self.temporary {
            let mut options = OpenOptions::new();
            options.read(true).follow(FollowSymlinks::No);
            let mut removed = matches!(self.parent.symlink_metadata(name), Err(error) if error.kind() == io::ErrorKind::NotFound);
            if let Ok(current) = self.parent.open_with(name, &options) {
                let same = file.try_clone().and_then(|file| {
                    Ok(same_file::Handle::from_file(file)?
                        == same_file::Handle::from_file(current.into_std())?)
                });
                if matches!(same, Ok(true)) {
                    removed = self.parent.remove_file(name).is_ok();
                }
            }
            if removed {
                if let Some(registration) = &self.registration {
                    let _ = registration.retire();
                }
            }
        }
        if !self.published {
            for (parent, name, held) in self.created.iter().rev() {
                if let Ok(current) = parent.open_dir_nofollow(name) {
                    if same_directory(&current, held).unwrap_or(false) {
                        let _ = parent.remove_dir(name);
                    }
                }
            }
        }
    }
}
struct WriteAccess<'a> {
    grant: Option<Grant>,
    authority: Option<UploadAuthority>,
    activity: Option<&'a Guard>,
}
fn receive(
    ws: Arc<Workspace>,
    path: String,
    directory: bool,
    size: u64,
    cancel: CancellationToken,
    access: WriteAccess<'_>,
    mut rx: mpsc::Receiver<Message>,
) -> Result<serde_json::Value> {
    let WriteAccess {
        grant,
        authority,
        activity,
    } = access;
    if authority.as_ref().is_some_and(|a| !a.valid()) {
        return Err(StatusCode::UNAUTHORIZED);
    }
    check(&ws, &cancel, &grant)?;
    let (parent_path, name) = path.rsplit_once('/').unwrap_or(("", path.as_str()));
    let mut txn = Transaction {
        parent: ws.filesystem().map_err(|_| StatusCode::NOT_IMPLEMENTED)?,
        temporary: None,
        registration: None,
        created: Vec::new(),
        published: false,
    };
    if !parent_path.is_empty() {
        for component in parent_path.split('/') {
            check(&ws, &cancel, &grant)?;
            if authority.as_ref().is_some_and(|a| !a.valid()) {
                return Err(StatusCode::UNAUTHORIZED);
            }
            let created = match txn.parent.create_dir(component) {
                Ok(()) => true,
                Err(e) if e.kind() == io::ErrorKind::AlreadyExists => false,
                Err(e) => return Err(storage(e)),
            };
            let child = Arc::new(
                txn.parent
                    .open_dir_nofollow(component)
                    .map_err(|_| StatusCode::FORBIDDEN)?,
            );
            if created {
                txn.created
                    .push((txn.parent.clone(), component.to_owned(), child.clone()));
            }
            txn.parent = child;
        }
    }
    match txn.parent.symlink_metadata(name) {
        Ok(_) => return Err(StatusCode::CONFLICT),
        Err(e) if e.kind() == io::ErrorKind::NotFound => {}
        Err(e) => return Err(storage(e)),
    }
    if !directory {
        let id = uuid::Uuid::new_v4().to_string();
        let temporary = format!(".legnasend-receive-{id}.part");
        let mut options = OpenOptions::new();
        options
            .read(true)
            .write(true)
            .create_new(true)
            .follow(FollowSymlinks::No);
        #[cfg(unix)]
        {
            use cap_std::fs::OpenOptionsExt;
            options.mode(0o600);
        }
        let file = txn
            .parent
            .open_with(&temporary, &options)
            .map_err(storage)?
            .into_std();
        crate::file_lock::try_exclusive(&file).map_err(|_| StatusCode::CONFLICT)?;
        txn.temporary = Some((temporary, file));
        if let Some(registry) = crate::receive_registry::current() {
            let identity = crate::download_cache::CacheIdentity {
                task_id: id,
                source_id: format!("directory-upload:{}:{}", ws.config.id, ws.config.generation),
                resource_id: path.clone(),
                version: "directory-upload-v1".into(),
                file_name: name.into(),
                size,
                chunk_size: 1024 * 1024,
                created_unix_ms: 0,
                sha256: None,
            };
            // Private application journal; raw upload bytes never contain a cache header.
            txn.registration = Some(
                registry
                    .register(
                        &std::path::Path::new(&ws.config.root).join(parent_path),
                        &txn.parent,
                        &txn.temporary.as_ref().unwrap().1,
                        &identity,
                        true,
                    )
                    .map_err(storage)?,
            );
        }
    }
    let mut total = 0u64;
    let mut hash = Sha256::new();
    loop {
        if authority.as_ref().is_some_and(|a| !a.valid()) {
            return Err(StatusCode::UNAUTHORIZED);
        }
        check(&ws, &cancel, &grant)?;
        let message = rx.blocking_recv();
        // The request can be revoked while the writer waits for its next chunk.
        // Recheck before consuming queued data or interpreting channel EOF.
        if authority.as_ref().is_some_and(|a| !a.valid()) {
            return Err(StatusCode::UNAUTHORIZED);
        }
        check(&ws, &cancel, &grant)?;
        match message {
            Some(Message::Data(data)) => {
                if data.len() as u64 > size.saturating_sub(total) {
                    return Err(StatusCode::BAD_REQUEST);
                }
                if let Some((_, file)) = &mut txn.temporary {
                    let mut remaining = data.as_ref();
                    while !remaining.is_empty() {
                        let written = match file.write(remaining) {
                            Ok(0) => return Err(StatusCode::INTERNAL_SERVER_ERROR),
                            Ok(written) => written,
                            Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
                            Err(error) => return Err(storage(error)),
                        };
                        if let Some(activity) = &activity {
                            activity.advance(written as u64);
                        }
                        remaining = &remaining[written..];
                    }
                }
                total += data.len() as u64;
                hash.update(&data);
            }
            Some(Message::Finish) => break,
            None => return Err(StatusCode::BAD_REQUEST),
        }
    }
    if total != size {
        return Err(StatusCode::BAD_REQUEST);
    }
    if let Some((_, file)) = &txn.temporary {
        file.sync_all().map_err(storage)?;
    }
    let _commit = ws.uploads.publication.blocking_lock();
    if authority.as_ref().is_some_and(|a| !a.valid()) {
        return Err(StatusCode::UNAUTHORIZED);
    }
    check(&ws, &cancel, &grant)?;
    let commit = || -> Result<()> {
        // Parent creation and the body may take time: never publish into a directory
        // that was moved/replaced while its old capability remained open.
        let current = open_directory(
            ws.filesystem().map_err(|_| StatusCode::NOT_IMPLEMENTED)?,
            parent_path,
        )
        .map_err(|_| StatusCode::CONFLICT)?;
        if !same_directory(&current, &txn.parent).map_err(storage)? {
            return Err(StatusCode::CONFLICT);
        }
        if directory {
            txn.parent.create_dir(name).map_err(storage)?;
        } else {
            let (temporary, held) = txn.temporary.as_ref().unwrap();
            let mut options = OpenOptions::new();
            options.read(true).follow(FollowSymlinks::No);
            let current = txn
                .parent
                .open_with(temporary, &options)
                .map_err(storage)?
                .into_std();
            if same_file::Handle::from_file(held.try_clone().map_err(storage)?).map_err(storage)?
                != same_file::Handle::from_file(current).map_err(storage)?
            {
                return Err(StatusCode::CONFLICT);
            }
            publish(&txn.parent, temporary, name).map_err(storage)?;
        }
        Ok(())
    };
    let mut publish = || -> Result<()> {
        if let Some(authority) = &authority {
            authority.publish(commit)?;
        } else {
            commit()?;
        }
        txn.published = true;
        Ok(())
    };
    if let Some(activity) = activity {
        // Cancel can win before this gate, never between publication and success.
        // The registry lock is not held while filesystem operations run.
        activity.publish(StatusCode::CONFLICT, publish)?;
    } else {
        publish()?;
    }
    ws.content.published(parent_path);
    Ok(
        json!({"path":path,"size":size,"sha256":hash.finalize().iter().map(|byte| format!("{byte:02x}")).collect::<String>(),"directory":directory}),
    )
}
fn publish(parent: &Dir, temporary: &str, destination: &str) -> io::Result<()> {
    #[cfg(any(
        target_os = "linux",
        target_os = "android",
        target_os = "macos",
        target_os = "ios"
    ))]
    {
        use rustix::fs::{RenameFlags, renameat_with};
        use rustix::io::Errno;
        match renameat_with(
            parent,
            temporary,
            parent,
            destination,
            RenameFlags::NOREPLACE,
        ) {
            Ok(()) => return Ok(()),
            Err(Errno::NOSYS | Errno::INVAL | Errno::OPNOTSUPP) => {}
            Err(e) => return Err(e.into()),
        }
    }
    // Filesystems without rename-no-replace must support an atomic hard link;
    // never fall back to truncating/copying an existing destination.
    parent.hard_link(temporary, parent, destination)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn revocation_waits_for_publication_gate_before_acknowledging() {
        let control = Arc::new(Control::new());
        let held = control.publication.lock().await;
        let revoke = control.clone();
        let task = tokio::spawn(async move { revoke.revoke().await });
        control.stopped.cancelled().await;
        assert!(
            !task.is_finished(),
            "permission change must wait for commit barrier"
        );
        drop(held);
        task.await.unwrap();
        assert!(control.stopped.is_cancelled());
    }

    #[tokio::test]
    async fn revoked_complete_body_waiting_at_commit_does_not_publish() {
        let path =
            std::env::temp_dir().join(format!("legnasend-upload-gate-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir(&path).unwrap();
        let ws = Arc::new(Workspace {
            document_owner: uuid::Uuid::new_v4().to_string(),
            config: super::super::DirectoryConfig {
                id: uuid::Uuid::new_v4().to_string(),
                name: "test".into(),
                slug: "test".into(),
                root: path.to_string_lossy().into(),
                document_tree: None,
                generation: 1,
                visible: true,
                password_hash: None,
                allow_upload: true,
                upload_approval: false,
            },
            content: super::super::content::Observer::new(
                &super::super::DirectoryConfig {
                    id: uuid::Uuid::new_v4().to_string(),
                    name: "fixture".into(),
                    slug: "fixture".into(),
                    root: path.to_string_lossy().into_owned(),
                    document_tree: None,
                    generation: 1,
                    visible: true,
                    password_hash: None,
                    allow_upload: true,
                    upload_approval: false,
                },
                "fixture",
                CancellationToken::new(),
                None,
            ),
            root: Some(Arc::new(
                Dir::open_ambient_dir(&path, cap_std::ambient_authority()).unwrap(),
            )),
            stopped: CancellationToken::new(),
            version_stopped: CancellationToken::new(),
            event_slots: Arc::new(Semaphore::new(4)),
            downloads: Arc::new(Semaphore::new(8)),
            access: Arc::new(super::super::Access::new(None)),
            uploads: Arc::new(Control::new()),
        });
        let gate = ws.uploads.publication.lock().await;
        let (tx, rx) = mpsc::channel(2);
        tx.send(Message::Data(Bytes::from_static(b"complete")))
            .await
            .unwrap();
        tx.send(Message::Finish).await.unwrap();
        drop(tx);
        let worker_ws = ws.clone();
        let worker = tokio::task::spawn_blocking(move || {
            receive(
                worker_ws,
                "result".into(),
                false,
                8,
                CancellationToken::new(),
                WriteAccess {
                    grant: None,
                    authority: None,
                    activity: None,
                },
                rx,
            )
        });
        for _ in 0..100 {
            if std::fs::read_dir(&path)
                .unwrap()
                .any(|entry| entry.unwrap().metadata().unwrap().len() == 8)
            {
                break;
            }
            tokio::time::sleep(std::time::Duration::from_millis(5)).await;
        }
        ws.uploads.stopped.cancel();
        drop(gate);
        assert_eq!(worker.await.unwrap(), Err(StatusCode::CONFLICT));
        assert_eq!(std::fs::read_dir(&path).unwrap().count(), 0);
        std::fs::remove_dir(path).unwrap();
    }
    #[tokio::test]
    async fn activity_cancel_after_body_eof_before_publication_never_reports_saved() {
        let path =
            std::env::temp_dir().join(format!("legnasend-upload-gate-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir(&path).unwrap();
        let ws = Arc::new(Workspace {
            document_owner: uuid::Uuid::new_v4().to_string(),
            config: super::super::DirectoryConfig {
                id: uuid::Uuid::new_v4().to_string(),
                name: "test".into(),
                slug: "test".into(),
                root: path.to_string_lossy().into(),
                document_tree: None,
                generation: 1,
                visible: true,
                password_hash: None,
                allow_upload: true,
                upload_approval: false,
            },
            content: super::super::content::Observer::new(
                &super::super::DirectoryConfig {
                    id: uuid::Uuid::new_v4().to_string(),
                    name: "fixture".into(),
                    slug: "fixture".into(),
                    root: path.to_string_lossy().into_owned(),
                    document_tree: None,
                    generation: 1,
                    visible: true,
                    password_hash: None,
                    allow_upload: true,
                    upload_approval: false,
                },
                "fixture",
                CancellationToken::new(),
                None,
            ),
            root: Some(Arc::new(
                Dir::open_ambient_dir(&path, cap_std::ambient_authority()).unwrap(),
            )),
            stopped: CancellationToken::new(),
            version_stopped: CancellationToken::new(),
            event_slots: Arc::new(Semaphore::new(4)),
            downloads: Arc::new(Semaphore::new(8)),
            access: Arc::new(super::super::Access::new(None)),
            uploads: Arc::new(Control::new()),
        });
        let activities = crate::http::server::web::activity::ActivityRegistry::default();
        let activity = activities
            .begin_workspace(
                "127.0.0.1",
                "result",
                &ws.uploads.stopped,
                WorkspaceActivity {
                    id: &ws.config.id,
                    name: &ws.config.name,
                    direction: "receive",
                    operation: "upload",
                    origin: "browser",
                },
            )
            .unwrap();
        activity.started(8);
        let gate = ws.uploads.publication.lock().await;
        let (tx, rx) = mpsc::channel(2);
        tx.send(Message::Data(Bytes::from_static(b"complete")))
            .await
            .unwrap();
        tx.send(Message::Finish).await.unwrap();
        drop(tx);
        let worker_ws = ws.clone();
        let worker = tokio::task::spawn_blocking(move || {
            receive(
                worker_ws,
                "result".into(),
                false,
                8,
                activity.cancel.clone(),
                WriteAccess {
                    grant: None,
                    authority: None,
                    activity: Some(&activity),
                },
                rx,
            )
        });
        for _ in 0..100 {
            let records: serde_json::Value = serde_json::from_str(&activities.snapshot()).unwrap();
            if records[0]["transferred"] == 8 {
                break;
            }
            tokio::time::sleep(std::time::Duration::from_millis(5)).await;
        }
        let before: serde_json::Value = serde_json::from_str(&activities.snapshot()).unwrap();
        assert_eq!(before[0]["transferred"], 8);
        assert_eq!(before[0]["total"], 8);
        assert_eq!(
            before[0]["phase"], "transferring",
            "body EOF is not publication"
        );
        assert!(activities.cancel(before[0]["id"].as_str().unwrap()));
        drop(gate);
        assert_eq!(worker.await.unwrap(), Err(StatusCode::CONFLICT));
        assert_eq!(std::fs::read_dir(&path).unwrap().count(), 0);
        let after: serde_json::Value = serde_json::from_str(&activities.snapshot()).unwrap();
        assert_eq!(after[0]["phase"], "canceled");
        assert_eq!(after[0]["transferred"], 8);
        std::fs::remove_dir(path).unwrap();
    }
}
