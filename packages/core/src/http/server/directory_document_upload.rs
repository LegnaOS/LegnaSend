//! Private document-workspace upload adapter. Public admission remains in upload.rs.
//! Blocking writers own descriptors and permits through publication and release.
use super::{DirectoryRegistry, DirectoryWriteResponse, Workspace, directory_auth::Grant};
use crate::download_cache::{CacheError, CacheIdentity, ExportReceipt, MAX_CHUNK_SIZE, MAX_CHUNKS};
use crate::http::server::{
    common::{
        receive_cache_files::{self, Message},
        save::FileTimestamps,
    },
    integration::UploadAuthority,
    v2::ServerEventV2,
    web::activity::Guard,
};
use hyper::StatusCode;
use serde_json::{Value, json};
use std::{
    sync::Arc,
    time::{Duration, SystemTime, UNIX_EPOCH},
};
use tokio::sync::{mpsc, oneshot};
use tokio_util::sync::CancellationToken;

type Result<T> = std::result::Result<T, StatusCode>;
const CONTROL: Duration = Duration::from_secs(30);
fn status(error: &str) -> StatusCode {
    match error {
        "permission" => StatusCode::FORBIDDEN,
        "not_found" => StatusCode::NOT_FOUND,
        "conflict" | "cancelled" | "expired" => StatusCode::CONFLICT,
        "unsupported" => StatusCode::NOT_IMPLEMENTED,
        "busy" => StatusCode::TOO_MANY_REQUESTS,
        _ => StatusCode::BAD_GATEWAY,
    }
}
fn cache_status(error: &CacheError) -> StatusCode {
    match error {
        CacheError::Busy
        | CacheError::IdentityMismatch
        | CacheError::NotEmpty
        | CacheError::Cancelled => StatusCode::CONFLICT,
        CacheError::Incomplete | CacheError::Chunk => StatusCode::BAD_REQUEST,
        CacheError::Checksum => StatusCode::UNPROCESSABLE_ENTITY,
        CacheError::Io(error) => match error.kind() {
            std::io::ErrorKind::PermissionDenied => StatusCode::FORBIDDEN,
            std::io::ErrorKind::Unsupported | std::io::ErrorKind::InvalidInput => {
                StatusCode::NOT_IMPLEMENTED
            }
            std::io::ErrorKind::StorageFull => StatusCode::INSUFFICIENT_STORAGE,
            std::io::ErrorKind::AlreadyExists | std::io::ErrorKind::WouldBlock => {
                StatusCode::CONFLICT
            }
            _ => StatusCode::INTERNAL_SERVER_ERROR,
        },
        CacheError::Identity
        | CacheError::Format
        | CacheError::Corrupt
        | CacheError::ReopenRequired => StatusCode::INTERNAL_SERVER_ERROR,
    }
}
async fn call(
    events: &mpsc::Sender<ServerEventV2>,
    mut request: Value,
    timeout: Duration,
) -> Result<DirectoryWriteResponse> {
    request["requestId"] = json!(uuid::Uuid::new_v4().to_string());
    let (result_tx, rx) = oneshot::channel();
    tokio::time::timeout(timeout, async {
        events
            .send(ServerEventV2::DirectoryDocumentWrite {
                request: request.to_string(),
                result_tx,
            })
            .await
            .map_err(|_| StatusCode::SERVICE_UNAVAILABLE)?;
        let reply = rx
            .await
            .map_err(|_| StatusCode::BAD_GATEWAY)?
            .map_err(|error| status(&error))?;
        Ok(reply)
    })
    .await
    .map_err(|_| StatusCode::GATEWAY_TIMEOUT)?
}
struct Release<'a> {
    events: mpsc::Sender<ServerEventV2>,
    request: Value,
    runtime: &'a tokio::runtime::Handle,
    cache: Option<std::fs::File>,
    staging: Option<std::fs::File>,
}
impl Drop for Release<'_> {
    fn drop(&mut self) {
        drop(self.cache.take());
        drop(self.staging.take());
        self.request["op"] = json!("release");
        // This guard is outside the descriptor writer. No provider release may
        // precede the real closes, even when the HTTP task was dropped earlier.
        let _ = self
            .runtime
            .block_on(call(&self.events, self.request.clone(), CONTROL));
    }
}
#[allow(clippy::too_many_arguments)]
pub(super) fn receive(
    registry: &DirectoryRegistry,
    ws: Arc<Workspace>,
    parent: &str,
    path: &str,
    directory: bool,
    size: u64,
    cancel: CancellationToken,
    grant: Option<Grant>,
    authority: Option<UploadAuthority>,
    activity: &Guard,
    mut rx: mpsc::Receiver<Message>,
    runtime: &tokio::runtime::Handle,
) -> Result<Value> {
    let check = || {
        super::upload::check(&ws, &cancel, &grant)?;
        if authority.as_ref().is_some_and(|a| !a.valid()) {
            return Err(StatusCode::UNAUTHORIZED);
        }
        Ok(())
    };
    check()?;
    let events = registry
        .events
        .clone()
        .ok_or(StatusCode::SERVICE_UNAVAILABLE)?;
    let attempt = uuid::Uuid::new_v4().to_string();
    let base = json!({"version":1,"owner":ws.document_owner,"workspaceId":ws.config.id,
        "generation":ws.config.generation,"tree":ws.config.document_tree,"attemptId":attempt});
    let mut begin = base.clone();
    begin["op"] = json!("begin");
    begin["parent"] = json!(parent);
    begin["path"] = json!(path);
    begin["size"] = json!(size);
    begin["directory"] = json!(directory);
    let reply = runtime.block_on(call(&events, begin, CONTROL))?;
    let metadata: Value = if reply.payload.len() <= 16384 {
        serde_json::from_str(&reply.payload).unwrap_or(Value::Null)
    } else {
        Value::Null
    };
    // Set up cleanup before parsing the provider's response. Attempt identity is
    // sufficient to retire malformed replies without trusting arbitrary URIs.
    let mut release_request = base.clone();
    release_request["transactionId"] = metadata["transactionId"].clone();
    release_request["lease"] = metadata["lease"].clone();
    let mut release = Release {
        events,
        request: release_request,
        runtime,
        cache: reply.cache,
        staging: reply.staging,
    };
    let id = metadata["transactionId"]
        .as_str()
        .ok_or(StatusCode::BAD_GATEWAY)?;
    let lease = metadata["lease"].as_str().ok_or(StatusCode::BAD_GATEWAY)?;
    if metadata["version"] != 1
        || uuid::Uuid::parse_str(id).is_err()
        || lease.is_empty()
        || lease.len() > 256
        || lease.chars().any(char::is_control)
    {
        // Ensure descriptor drop happens before release, including bad responses.
        return Err(StatusCode::BAD_GATEWAY);
    }
    // The owned pair is dropped within receive() before its publication receipt.
    let receipt = if directory {
        if release.cache.is_some() || release.staging.is_some() {
            return Err(StatusCode::BAD_GATEWAY);
        }
        loop {
            check()?;
            match rx.blocking_recv() {
                Some(Message::Data(bytes)) if bytes.is_empty() => {}
                Some(Message::Finish) => break,
                _ => return Err(StatusCode::BAD_REQUEST),
            }
        }
        ExportReceipt {
            bytes: 0,
            sha256: String::new(),
        }
    } else {
        if release.cache.is_none() || release.staging.is_none() {
            return Err(StatusCode::BAD_GATEWAY);
        }
        let cache = release.cache.take().unwrap();
        let staging = release.staging.take().unwrap();
        let identity = CacheIdentity {
            task_id: id.to_owned(),
            source_id: format!("legnasend-workspace:{}", ws.document_owner),
            resource_id: crate::crypto::hash::sha256_hex(format!("{parent}\0{path}").as_bytes()),
            version: attempt.clone(),
            file_name: path.rsplit('/').next().unwrap().to_owned(),
            size,
            chunk_size: size
                .div_ceil(MAX_CHUNKS)
                .max(size.clamp(64 * 1024, 1024 * 1024))
                .min(u64::from(MAX_CHUNK_SIZE)) as u32,
            created_unix_ms: SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap_or_default()
                .as_millis() as u64,
            sha256: None,
        };
        receive_cache_files::receive(
            cache,
            staging,
            identity,
            FileTimestamps::default(),
            rx,
            cancel.clone(),
            None,
            Some(&|bytes| activity.advance(bytes)),
        )
        .map_err(|error| cache_status(&error))?
    };
    check()?;
    {
        // Only the short transition is serialized with workspace/key revocation.
        // Never keep a workspace/global registry lock over native publication.
        let _workspace_gate = ws.uploads.publication.blocking_lock();
        check()?;
        let enter = || {
            if activity.begin_provider_publication() {
                Ok(())
            } else {
                Err(StatusCode::CONFLICT)
            }
        };
        if let Some(authority) = &authority {
            authority.publish(enter)?;
        } else {
            enter()?;
        }
    }
    let mut publish = release.request.clone();
    publish["op"] = json!("publish");
    publish["coreAttemptId"] = json!(attempt);
    publish["size"] = json!(receipt.bytes);
    publish["sha256"] = json!(receipt.sha256);
    let deadline =
        Duration::from_secs((60u64.saturating_add(size.div_ceil(1024 * 1024))).min(6 * 60 * 60));
    let published = runtime.block_on(call(&release.events, publish, deadline));
    let success = published.as_ref().is_ok_and(|reply| {
        reply.payload.len() <= 16384
            && reply.cache.is_none()
            && reply.staging.is_none()
            && serde_json::from_str::<Value>(&reply.payload)
                .is_ok_and(|v| v["version"] == 1 && v["published"] == true)
    });
    activity.finish_provider_publication(success);
    drop(release);
    if !success {
        return Err(published.err().unwrap_or(StatusCode::BAD_GATEWAY));
    }
    ws.content.published(parent);
    let sha256 = if directory {
        crate::crypto::hash::sha256_hex(b"")
    } else {
        receipt.sha256
    };
    Ok(json!({"path":path,"parent":parent,"size":size,"sha256":sha256,"directory":directory}))
}

#[cfg(test)]
mod cache_diagnostic_tests {
    use super::*;
    #[test]
    fn storage_failures_do_not_masquerade_as_conflicts_or_expose_error_text() {
        assert_eq!(cache_status(&CacheError::Busy), StatusCode::CONFLICT);
        assert_eq!(cache_status(&CacheError::NotEmpty), StatusCode::CONFLICT);
        assert_eq!(
            cache_status(&CacheError::Incomplete),
            StatusCode::BAD_REQUEST
        );
        assert_eq!(
            cache_status(&CacheError::Checksum),
            StatusCode::UNPROCESSABLE_ENTITY
        );
        assert_eq!(
            cache_status(&CacheError::Identity),
            StatusCode::INTERNAL_SERVER_ERROR
        );
        for (kind, status) in [
            (std::io::ErrorKind::PermissionDenied, 403),
            (std::io::ErrorKind::Unsupported, 501),
            (std::io::ErrorKind::StorageFull, 507),
            (std::io::ErrorKind::Other, 500),
        ] {
            let error =
                CacheError::Io(std::io::Error::new(kind, "private-provider-path-and-token"));
            assert_eq!(cache_status(&error).as_u16(), status);
            assert_eq!(receive_cache_files::failure_category(&error), "io");
        }
    }
}
