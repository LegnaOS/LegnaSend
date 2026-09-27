//! A bounded metadata plan plus sequential provider descriptors, never a directory mirror.
use super::super::archive::{self, Entry as ZipEntry, Plan};
use super::*;

#[derive(Clone)]
struct Source {
    id: String,
    name: String,
    size: u64,
}
struct Directory {
    id: String,
    prefix: String,
    cursor: Option<String>,
    offset: u64,
    depth: usize,
    selection: Option<HashSet<String>>,
}
fn authorized(
    ws: &Workspace,
    grant: Option<&Grant>,
    cancel: &CancellationToken,
) -> Result<(), AppError> {
    if ws.stopped.is_cancelled() || cancel.is_cancelled() {
        return Err(status(StatusCode::GONE));
    }
    if grant.is_some_and(|g| g.cancel.is_cancelled() || g.expires <= Instant::now()) {
        return Err(status(StatusCode::UNAUTHORIZED));
    }
    Ok(())
}
async fn revoked(grant: Option<&Grant>) {
    if let Some(grant) = grant {
        tokio::select! {_=grant.cancel.cancelled()=>{},_=tokio::time::sleep_until(grant.expires.into())=>{}}
    } else {
        std::future::pending::<()>().await;
    }
}
async fn scan(
    registry: &DirectoryRegistry,
    ws: &Workspace,
    path: &str,
    selection: Option<Vec<String>>,
    grant: Option<&Grant>,
    cancel: &CancellationToken,
) -> Result<Vec<ZipEntry<Option<Source>>>, AppError> {
    if !path.is_empty() && !documents::opaque(path) {
        return Err(bad());
    }
    if selection
        .as_ref()
        .is_some_and(|ids| ids.iter().any(|id| !documents::opaque(id)))
    {
        return Err(bad());
    }
    let mut plan = Plan::new();
    plan.push(ZipEntry {
        name: "files/".into(),
        size: 0,
        source: None,
    })?;
    let mut stack = vec![Directory {
        id: path.into(),
        prefix: "files".into(),
        cursor: None,
        offset: 0,
        depth: 0,
        selection: selection.map(|ids| ids.into_iter().collect()),
    }];
    let mut visited = HashSet::new();
    visited.insert(path.to_owned());
    let deadline = archive::scan_deadline();
    let mut scanned = 0usize;
    while let Some(mut directory) = stack.pop() {
        authorized(ws, grant, cancel)?;
        if Instant::now() >= deadline {
            return Err(status(StatusCode::GATEWAY_TIMEOUT));
        }
        let page = tokio::select! {biased;
            _=revoked(grant)=>return Err(status(StatusCode::UNAUTHORIZED)),
            value=documents::list_page(registry,ws,&directory.id,directory.cursor.as_deref(),"",Some(cancel))=>value?,
        };
        if page.offset != directory.offset || (page.cursor.is_some() && page.scanned == 0) {
            return Err(status(StatusCode::CONFLICT));
        }
        scanned = scanned.checked_add(page.scanned as usize).ok_or_else(bad)?;
        if scanned > archive::MAX_ENTRIES {
            return Err(status(StatusCode::PAYLOAD_TOO_LARGE));
        }
        directory.offset = directory.offset.checked_add(page.scanned).ok_or_else(bad)?;
        let mut children = Vec::new();
        for entry in page.entries {
            if entry.name.to_ascii_lowercase().starts_with(".legnasend")
                || entry.name.to_ascii_lowercase().ends_with(".ls")
            {
                continue;
            }
            if let Some(selected) = &mut directory.selection {
                if !selected.remove(&entry.id) {
                    continue;
                }
            }
            if !visited.insert(entry.id.clone()) {
                return Err(status(StatusCode::CONFLICT));
            }
            // Provider display names are single ZIP components, not paths.
            if entry.name.contains('/') || entry.name.contains('\\') {
                return Err(bad());
            }
            archive::valid_name(&entry.name)?;
            let name = format!("{}/{}", directory.prefix, entry.name);
            if entry.directory {
                if directory.depth >= 63 {
                    return Err(status(StatusCode::PAYLOAD_TOO_LARGE));
                }
                plan.push(ZipEntry {
                    name: format!("{name}/"),
                    size: 0,
                    source: None,
                })?;
                children.push(Directory {
                    id: entry.id,
                    prefix: name,
                    cursor: None,
                    offset: 0,
                    depth: directory.depth + 1,
                    selection: None,
                });
            } else {
                if !entry.downloadable {
                    return Err(status(StatusCode::NOT_IMPLEMENTED));
                }
                let size = entry
                    .size
                    .ok_or_else(|| status(StatusCode::NOT_IMPLEMENTED))?;
                plan.push(ZipEntry {
                    name,
                    size,
                    source: Some(Source {
                        id: entry.id,
                        name: entry.name,
                        size,
                    }),
                })?;
            }
        }
        if let Some(cursor) = page.cursor {
            if directory.cursor.as_ref() == Some(&cursor) {
                return Err(status(StatusCode::CONFLICT));
            }
            directory.cursor = Some(cursor);
            stack.push(directory);
        } else if directory
            .selection
            .as_ref()
            .is_some_and(|ids| !ids.is_empty())
        {
            return Err(status(StatusCode::NOT_FOUND));
        }
        // Depth-first traversal retains at most one provider cursor per level,
        // never one open cursor per queued sibling (depth is capped at 64).
        stack.extend(children.into_iter().rev());
        if stack.len() > archive::MAX_ENTRIES {
            return Err(status(StatusCode::PAYLOAD_TOO_LARGE));
        }
    }
    authorized(ws, grant, cancel)?;
    plan.finish()
}

pub(super) async fn response(
    registry: &Arc<DirectoryRegistry>,
    ws: Arc<Workspace>,
    req: &Request<Incoming>,
    grant: Option<Grant>,
    query: &HashMap<String, String>,
    peer: &str,
    origin: &'static str,
    selection: Option<Vec<String>>,
    selection_owner: Option<Arc<archive_selections::Ticket>>,
) -> Result<Response<BoxedBody>, AppError> {
    let permit = archive::permit()?;
    let path = query.get("path").map(String::as_str).unwrap_or("");
    let filename = format!("{}.zip", ws.config.name);
    let head = req.method() == Method::HEAD;
    let activity = if head {
        None
    } else {
        Some(
            registry.activities.begin_workspace(
                peer,
                &filename,
                selection_owner
                    .as_ref()
                    .map_or(&ws.stopped, |ticket| &ticket.cancel),
                super::super::web::activity::WorkspaceActivity {
                    id: &ws.config.id,
                    name: &ws.config.name,
                    direction: "send",
                    operation: "archive",
                    origin,
                },
            )?,
        )
    };
    let cancel = activity.as_ref().map_or_else(
        || {
            selection_owner
                .as_ref()
                .map_or_else(|| ws.stopped.clone(), |ticket| ticket.cancel.clone())
        },
        |activity| activity.cancel.clone(),
    );
    let entries = match scan(registry, &ws, path, selection, grant.as_ref(), &cancel).await {
        Ok(entries) => entries,
        Err(error) => {
            if let Some(activity) = &activity {
                activity.failed();
            }
            return Err(error);
        }
    };
    let registry = registry.clone();
    let stop = cancel.clone();
    let body_grant = grant.clone();
    let body_ws = ws.clone();
    let mut response = archive::response(entries, &filename, head, permit, move |source| {
        let registry = registry.clone();
        let ws = ws.clone();
        let grant = grant.clone();
        let cancel = cancel.clone();
        async move {
            authorized(&ws, grant.as_ref(), &cancel)?;
            let Some(source) = source else {
                return Ok(response::empty_body());
            };
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
            let (file, metadata) = tokio::select! {biased;
                _=revoked(grant.as_ref())=>return Err(status(StatusCode::UNAUTHORIZED)),
                opened=documents::open_file(&registry,&ws,&source.id,Some(&cancel))=>opened?,
            };
            if metadata.name != source.name || metadata.size != source.size {
                return Err(status(StatusCode::CONFLICT));
            }
            authorized(&ws, grant.as_ref(), &cancel)?;
            let dto = FileDto {
                id: format!("{}:{}:{}", ws.config.id, ws.config.generation, source.id),
                file_name: metadata.name.clone(),
                size: metadata.size,
                file_type: metadata.mime,
                sha256: None,
                preview: None,
                metadata: None,
            };
            let response = download::response_unversioned(
                FileContent::OpenedFile(file),
                &dto,
                &hyper::HeaderMap::new(),
                false,
                "file",
            )
            .await?;
            let stream = response.into_body().into_data_stream().map(move |item| {
                let _ = (&global, &local);
                item.map(Frame::data)
            });
            Ok(BodyExt::boxed(StreamBody::new(stream)))
        }
    })?;
    let body = std::mem::replace(response.body_mut(), response::empty_body());
    let stream = body
        .into_data_stream()
        .take_until(stop.cancelled_owned())
        .take_until(body_ws.stopped.clone().cancelled_owned())
        .take_until(async move { revoked(body_grant.as_ref()).await })
        .map(|item| item.map(Frame::data));
    *response.body_mut() = BodyExt::boxed(StreamBody::new(stream));
    Ok(match activity {
        Some(activity) => activity.body(response),
        None => response,
    })
}
