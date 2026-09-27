//! Bounded invalidation stream. No file names, paths or event payloads leave the
//! filesystem watcher; clients must re-read through the ordinary authorized API.
use super::{Grant, Workspace, bad, open_directory, status, validate_relative};
use crate::http::server::common::{error::AppError, response::BoxedBody};
use bytes::Bytes;
use cap_std::fs::Dir;
use http_body_util::{BodyExt, StreamBody};
use hyper::{Response, StatusCode, body::Frame, header};
use notify::{
    EventKind, RecommendedWatcher, RecursiveMode, Watcher,
    event::{MetadataKind, ModifyKind},
};
use std::{
    collections::HashMap,
    path::PathBuf,
    sync::{Arc, Mutex},
    time::{Duration, Instant},
};
use tokio::sync::{OwnedSemaphorePermit, Semaphore, watch};
static SLOTS: Semaphore = Semaphore::const_new(16);

struct Subscription {
    _watcher: Mutex<RecommendedWatcher>,
    _slot: OwnedSemaphorePermit,
    _global: tokio::sync::SemaphorePermit<'static>,
    _directory: Arc<Dir>,
    workspace: Arc<Workspace>,
    grant: Option<Grant>,
    changes: watch::Receiver<()>,
    expires: Instant,
    ready: bool,
    last: Instant,
}
fn same_directory(dir: &Dir, path: &std::path::Path) -> bool {
    let Ok(a) = dir
        .try_clone()
        .and_then(|d| same_file::Handle::from_file(d.into_std_file()))
    else {
        return false;
    };
    same_file::Handle::from_path(path).is_ok_and(|b| a == b)
}
pub(super) async fn subscribe(
    ws: Arc<Workspace>,
    grant: Option<Grant>,
    query: HashMap<String, String>,
) -> Result<Response<BoxedBody>, AppError> {
    if query
        .keys()
        .any(|k| !["generation", "path"].contains(&k.as_str()))
    {
        return Err(bad());
    }
    let relative = query.get("path").cloned().unwrap_or_default();
    validate_relative(&relative)?;
    let global = SLOTS
        .try_acquire()
        .map_err(|_| status(StatusCode::TOO_MANY_REQUESTS))?;
    let slot = ws
        .event_slots
        .clone()
        .try_acquire_owned()
        .map_err(|_| status(StatusCode::TOO_MANY_REQUESTS))?;
    let (tx, rx) = watch::channel(());
    let root = ws.filesystem()?;
    let path = PathBuf::from(&ws.config.root).join(&relative);
    let observer = ws.content.clone();
    let observe_scope = relative.clone();
    // Setup retains both budgets inside the blocking worker: canceling HTTP
    // must not release credits while filesystem watcher setup is still running.
    let (directory, watcher, global, slot) =
        tokio::task::spawn_blocking(move || -> Result<_, AppError> {
            let dir = open_directory(root, &relative).map_err(|_| status(StatusCode::NOT_FOUND))?;
            if !same_directory(&dir, &path) {
                return Err(status(StatusCode::CONFLICT));
            }
            let mut watcher =
                notify::recommended_watcher(move |event: notify::Result<notify::Event>| {
                    let changed = match event {
                        Ok(event) => {
                            !matches!(
                                event.kind,
                                EventKind::Access(_)
                                    | EventKind::Modify(ModifyKind::Metadata(
                                        MetadataKind::AccessTime
                                    ))
                            ) && (event.paths.is_empty()
                                || event.paths.iter().any(|path| {
                                    path.file_name()
                                        .and_then(|n| n.to_str())
                                        .is_none_or(|name| validate_relative(name).is_ok())
                                }))
                        }
                        Err(_) => true,
                    };
                    if changed {
                        observer.hint(&observe_scope);
                        let _ = tx.send(());
                    }
                })
                .map_err(|_| status(StatusCode::SERVICE_UNAVAILABLE))?;
            watcher
                .watch(&path, RecursiveMode::NonRecursive)
                .map_err(|_| status(StatusCode::SERVICE_UNAVAILABLE))?;
            if !same_directory(&dir, &path) {
                return Err(status(StatusCode::CONFLICT));
            }
            Ok((dir, watcher, global, slot))
        })
        .await
        .map_err(|_| status(StatusCode::INTERNAL_SERVER_ERROR))??;
    let state = Subscription {
        _watcher: Mutex::new(watcher),
        _slot: slot,
        _global: global,
        _directory: directory,
        workspace: ws,
        grant,
        changes: rx,
        expires: Instant::now() + Duration::from_secs(90),
        ready: false,
        last: Instant::now(),
    };
    let stream = futures_util::stream::unfold(state, |mut state| async move {
        loop {
            if state.workspace.stopped.is_cancelled()
                || state.workspace.version_stopped.is_cancelled()
                || Instant::now() >= state.expires
                || state
                    .grant
                    .as_ref()
                    .is_some_and(|g| g.cancel.is_cancelled() || Instant::now() >= g.expires)
            {
                return None;
            }
            let event = if !state.ready {
                state.ready = true;
                "ready"
            } else {
                let grant_cancel = async {
                    if let Some(g) = &state.grant {
                        g.cancel.cancelled().await
                    } else {
                        std::future::pending::<()>().await
                    }
                };
                tokio::select! {
                    biased;
                    _=state.workspace.stopped.cancelled()=>return None,
                    _=state.workspace.version_stopped.cancelled()=>return None,
                    _=grant_cancel=>return None,
                    change=state.changes.changed()=>{if change.is_err(){return None;}"invalidate"},
                    _=tokio::time::sleep(Duration::from_secs(1))=>{
                        if state.last.elapsed()<Duration::from_secs(15){continue;} "heartbeat"
                    },
                }
            };
            if event == "invalidate" {
                tokio::time::sleep(Duration::from_millis(500)).await;
                state.changes.borrow_and_update();
            }
            if state.workspace.stopped.is_cancelled()
                || state.workspace.version_stopped.is_cancelled()
                || state
                    .grant
                    .as_ref()
                    .is_some_and(|g| g.cancel.is_cancelled() || Instant::now() >= g.expires)
            {
                return None;
            }
            state.last = Instant::now();
            let mut value = serde_json::json!({"generation":state.workspace.config.generation});
            state.workspace.content.fields(&mut value);
            let data = format!("event: {event}\ndata: {value}\n\n");
            return Some((
                Ok::<_, std::io::Error>(Frame::data(Bytes::from(data))),
                state,
            ));
        }
    });
    let mut response = Response::new(StreamBody::new(stream).boxed());
    response
        .headers_mut()
        .insert(header::CONTENT_TYPE, "text/event-stream".parse().unwrap());
    response
        .headers_mut()
        .insert(header::CACHE_CONTROL, "no-store".parse().unwrap());
    response
        .headers_mut()
        .insert("x-accel-buffering", "no".parse().unwrap());
    Ok(response)
}
