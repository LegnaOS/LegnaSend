//! Private host-side source capture. Never opens a path supplied by an API caller.
use super::{Workspace, open_regular, validate_relative};
use crate::http::server::common::download::file_stamp;
use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
use cap_fs_ext::{FollowSymlinks, OpenOptionsFollowExt};
use cap_std::{
    ambient_authority,
    fs::{Dir, OpenOptions},
};
use serde::Deserialize;
use serde_json::json;
use std::{
    collections::HashSet,
    io::{Read, Write},
    sync::Arc,
};
use tokio::sync::Semaphore;
use tokio_util::sync::CancellationToken;
static CAPTURES: Semaphore = Semaphore::const_new(2);
pub(super) fn acquire_capture() -> anyhow::Result<tokio::sync::SemaphorePermit<'static>> {
    CAPTURES
        .try_acquire()
        .map_err(|_| anyhow::anyhow!("source_capture_busy"))
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Selection {
    id: String,
    version: String,
}

pub(super) async fn capture(
    ws: Arc<Workspace>,
    input: &str,
    destination: String,
    server_stopped: CancellationToken,
) -> anyhow::Result<String> {
    anyhow::ensure!(!server_stopped.is_cancelled(), "server_stopped");
    anyhow::ensure!(input.len() <= 64 * 1024, "selection_too_large");
    let selected: Vec<Selection> =
        serde_json::from_str(input).map_err(|_| anyhow::anyhow!("invalid_selection"))?;
    anyhow::ensure!(
        !selected.is_empty() && selected.len() <= 128,
        "invalid_selection"
    );
    let permit = acquire_capture()?;
    let mut seen = HashSet::new();
    let mut entries = Vec::new();
    for item in selected {
        let path = String::from_utf8(
            URL_SAFE_NO_PAD
                .decode(&item.id)
                .map_err(|_| anyhow::anyhow!("invalid_file_id"))?,
        )
        .map_err(|_| anyhow::anyhow!("invalid_file_id"))?;
        anyhow::ensure!(
            URL_SAFE_NO_PAD.encode(path.as_bytes()) == item.id
                && !path.is_empty()
                && path.len() <= 4096
                && seen.insert(path.clone()),
            "invalid_file_id"
        );
        validate_relative(&path).map_err(|_| anyhow::anyhow!("invalid_file_id"))?;
        anyhow::ensure!(
            item.version.len() == 66
                && item.version.starts_with('"')
                && item.version.ends_with('"')
                && item.version[1..65].bytes().all(|v| v.is_ascii_hexdigit()),
            "invalid_version"
        );
        entries.push((item, path));
    }
    // Await the blocking writer to completion before the owner may delete its
    // private stage; cancellation of a workspace is observed between buffers.
    tokio::task::spawn_blocking(move || -> anyhow::Result<String> {
        let _permit = permit;
        anyhow::ensure!(!server_stopped.is_cancelled(), "server_stopped");
        let output = Dir::open_ambient_dir(&destination, ambient_authority())
            .map_err(|_| anyhow::anyhow!("capture_storage"))?;
        let mut result = Vec::new();
        let mut buffer = vec![0u8; 256 * 1024];
        for (index, (item, path)) in entries.into_iter().enumerate() {
            anyhow::ensure!(!server_stopped.is_cancelled(), "server_stopped");
            anyhow::ensure!(
                !ws.stopped.is_cancelled() && !ws.version_stopped.is_cancelled(),
                "workspace_changed"
            );
            let mut source = open_regular(
                ws.filesystem()
                    .map_err(|_| anyhow::anyhow!("document_capture_unsupported"))?,
                &path,
            )
            .map_err(|_| anyhow::anyhow!("source_unavailable"))?;
            let id = format!("{}:{}:{}", ws.config.id, ws.config.generation, item.id);
            let metadata = source
                .metadata()
                .map_err(|_| anyhow::anyhow!("source_unavailable"))?;
            anyhow::ensure!(file_stamp(&metadata, &id) == item.version, "source_changed");
            let size = metadata.len();
            let name = format!("source-{index}");
            let mut options = OpenOptions::new();
            options
                .write(true)
                .create_new(true)
                .follow(FollowSymlinks::No);
            let mut target = output
                .open_with(&name, &options)
                .map_err(|_| anyhow::anyhow!("capture_storage"))?;
            let mut copied = 0u64;
            loop {
                anyhow::ensure!(!server_stopped.is_cancelled(), "server_stopped");
                anyhow::ensure!(
                    !ws.stopped.is_cancelled() && !ws.version_stopped.is_cancelled(),
                    "workspace_changed"
                );
                let n = source
                    .read(&mut buffer)
                    .map_err(|_| anyhow::anyhow!("source_unavailable"))?;
                if n == 0 {
                    break;
                }
                copied = copied
                    .checked_add(n as u64)
                    .ok_or_else(|| anyhow::anyhow!("source_changed"))?;
                anyhow::ensure!(copied <= size, "source_changed");
                anyhow::ensure!(!server_stopped.is_cancelled(), "server_stopped");
                target
                    .write_all(&buffer[..n])
                    .map_err(|_| anyhow::anyhow!("capture_storage"))?;
            }
            target
                .sync_all()
                .map_err(|_| anyhow::anyhow!("capture_storage"))?;
            anyhow::ensure!(
                copied == size
                    && file_stamp(
                        &source
                            .metadata()
                            .map_err(|_| anyhow::anyhow!("source_unavailable"))?,
                        &id
                    ) == item.version,
                "source_changed"
            );
            result.push(json!({"name":path,"size":size,"source":name}));
        }
        anyhow::ensure!(
            !ws.stopped.is_cancelled() && !ws.version_stopped.is_cancelled(),
            "workspace_changed"
        );
        anyhow::ensure!(!server_stopped.is_cancelled(), "server_stopped");
        Ok(json!({"files":result}).to_string())
    })
    .await
    .map_err(|_| anyhow::anyhow!("capture_storage"))?
}
