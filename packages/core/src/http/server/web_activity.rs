//! Bounded host-side response accounting. Bytes mean handed to the HTTP body,
//! never a claim that a browser persisted the file. No public protocol changes.
use super::super::common::{error::AppError, response::BoxedBody};
use http_body_util::{BodyExt, StreamBody};
use hyper::{Response, StatusCode};
use serde::Serialize;
use std::{
    collections::BTreeMap,
    sync::{Arc, Mutex},
};
use tokio_util::sync::CancellationToken;

const MAX_ACTIVE: usize = 128;
const MAX_HISTORY: usize = 128;
#[derive(Clone, Default)]
pub(crate) struct ActivityRegistry(Arc<Mutex<State>>);
/// Bounded host-only activity history shared explicitly across listener lifetimes.
/// Default server constructors create independent histories. This object owns no
/// sockets, filesystem handles, workspace catalog, or listener event channels.
#[derive(Clone, Default)]
pub struct WebActivityHistory(pub(crate) ActivityRegistry);

impl WebActivityHistory {
    /// Read at most 128 active and 128 recently completed records without waiting
    /// for a filesystem publication. Safe after all listeners have stopped.
    pub fn snapshot(&self) -> String {
        self.0.snapshot()
    }
}
#[derive(Default)]
struct State {
    next: u64,
    next_completion: u64,
    entries: BTreeMap<u64, Entry>,
}
struct Entry {
    data: Record,
    cancel: CancellationToken,
    publication: Arc<Mutex<()>>,
    in_commit: bool,
    completion: Option<u64>,
}
#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct Record {
    id: String,
    session_id: String,
    peer: String,
    name: String,
    total: Option<u64>,
    transferred: u64,
    phase: &'static str,
    direction: &'static str,
    operation: &'static str,
    origin: &'static str,
    #[serde(skip_serializing_if = "Option::is_none")]
    workspace_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    workspace_name: Option<String>,
}
/// Host-only metadata, never a peer-provided destination path or protocol field.
pub(crate) struct WorkspaceActivity<'a> {
    pub(crate) id: &'a str,
    pub(crate) name: &'a str,
    pub(crate) direction: &'static str,
    pub(crate) operation: &'static str,
    pub(crate) origin: &'static str,
}
fn active(phase: &str) -> bool {
    matches!(phase, "preparing" | "transferring")
}
fn trim_history(state: &mut State) {
    // Creation order is not completion order: a slow publication may finish
    // after hundreds of newer requests. It must enter the newest history slot.
    for entry in state.entries.values_mut() {
        if !active(entry.data.phase) && entry.completion.is_none() {
            state.next_completion += 1;
            entry.completion = Some(state.next_completion);
        }
    }
    while state
        .entries
        .values()
        .filter(|entry| entry.completion.is_some())
        .count()
        > MAX_HISTORY
    {
        let index = *state
            .entries
            .iter()
            .filter(|(_, entry)| entry.completion.is_some())
            .min_by_key(|(_, entry)| entry.completion.unwrap())
            .unwrap()
            .0;
        state.entries.remove(&index);
    }
}
impl ActivityRegistry {
    pub(crate) fn snapshot(&self) -> String {
        let mut state = self.0.lock().unwrap();
        for entry in state.entries.values_mut() {
            if active(entry.data.phase) && !entry.in_commit && entry.cancel.is_cancelled() {
                entry.data.phase = "canceled";
            }
        }
        trim_history(&mut state);
        serde_json::to_string(&state.entries.values().map(|e| &e.data).collect::<Vec<_>>()).unwrap()
    }
    pub(crate) fn cancel(&self, id: &str) -> bool {
        // Publication may perform filesystem I/O. Never wait on its commit gate
        // on a runtime worker: irreversible publication has already started and
        // cancellation cannot promise to undo it. The snapshot reports outcome.
        let gate = {
            let state = self.0.lock().unwrap();
            state
                .entries
                .values()
                .find(|e| e.data.id == id && active(e.data.phase))
                .map(|e| e.publication.clone())
        };
        let Some(gate) = gate else {
            return false;
        };
        let Ok(_publication) = gate.try_lock() else {
            return false;
        };
        let mut state = self.0.lock().unwrap();
        let Some(entry) = state
            .entries
            .values_mut()
            .find(|e| e.data.id == id && active(e.data.phase))
        else {
            return false;
        };
        if entry.in_commit {
            return false;
        }
        entry.data.phase = "canceled";
        let cancel = entry.cancel.clone();
        trim_history(&mut state);
        drop(state);
        cancel.cancel();
        true
    }
    pub(crate) fn begin(
        &self,
        session: &str,
        peer: &str,
        name: &str,
        parent: &CancellationToken,
    ) -> Result<Guard, AppError> {
        self.begin_context(session, peer, name, parent, None)
    }
    pub(crate) fn begin_workspace(
        &self,
        peer: &str,
        name: &str,
        parent: &CancellationToken,
        context: WorkspaceActivity<'_>,
    ) -> Result<Guard, AppError> {
        self.begin_context("", peer, name, parent, Some(context))
    }
    fn begin_context(
        &self,
        session: &str,
        peer: &str,
        name: &str,
        parent: &CancellationToken,
        context: Option<WorkspaceActivity<'_>>,
    ) -> Result<Guard, AppError> {
        let mut state = self.0.lock().unwrap();
        if state
            .entries
            .values()
            .filter(|e| active(e.data.phase))
            .count()
            >= MAX_ACTIVE
        {
            return Err(AppError::Status(StatusCode::TOO_MANY_REQUESTS));
        }
        trim_history(&mut state);
        state.next += 1;
        let index = state.next;
        let cancel = parent.child_token();
        let publication = Arc::new(Mutex::new(()));
        state.entries.insert(
            index,
            Entry {
                data: Record {
                    id: uuid::Uuid::new_v4().to_string(),
                    session_id: session.into(),
                    peer: peer.into(),
                    name: name
                        .chars()
                        .filter(|c| !c.is_control())
                        .take(4096)
                        .collect(),
                    total: None,
                    transferred: 0,
                    phase: "preparing",
                    direction: context.as_ref().map_or("send", |c| c.direction),
                    operation: context.as_ref().map_or("download", |c| c.operation),
                    origin: context.as_ref().map_or("browser", |c| c.origin),
                    workspace_id: context.as_ref().map(|c| c.id.to_owned()),
                    workspace_name: context.as_ref().map(|c| {
                        c.name
                            .chars()
                            .filter(|c| !c.is_control())
                            .take(4096)
                            .collect()
                    }),
                },
                cancel: cancel.clone(),
                publication: publication.clone(),
                in_commit: false,
                completion: None,
            },
        );
        Ok(Guard {
            registry: self.clone(),
            index,
            cancel,
            publication,
        })
    }
}
pub(crate) struct Guard {
    registry: ActivityRegistry,
    index: u64,
    pub(crate) cancel: CancellationToken,
    publication: Arc<Mutex<()>>,
}
impl Guard {
    fn update(&self, update: impl FnOnce(&mut Record)) {
        let mut state = self.registry.0.lock().unwrap();
        if let Some(entry) = state.entries.get_mut(&self.index) {
            if active(entry.data.phase) {
                if self.cancel.is_cancelled() {
                    entry.data.phase = "canceled";
                } else {
                    update(&mut entry.data);
                }
                trim_history(&mut state);
            }
        }
    }
    pub(crate) fn started(&self, total: u64) {
        self.update(|r| {
            r.total = Some(total);
            r.phase = "transferring";
        });
    }
    /// Upload callers advance only after writing bytes, and explicitly succeed after publication.
    pub(crate) fn advance(&self, bytes: u64) {
        self.update(|r| r.transferred = r.transferred.saturating_add(bytes));
    }
    pub(crate) fn succeeded(&self) {
        self.update(|r| {
            r.phase = if r.total.is_none_or(|total| total == r.transferred) {
                "succeeded"
            } else {
                "failed"
            }
        });
    }
    /// Enter a provider commit without keeping a synchronous mutex across native I/O.
    /// The caller must retain this Guard and finish even after its HTTP waiter drops.
    pub(crate) fn begin_provider_publication(&self) -> bool {
        let _gate = self.publication.lock().unwrap();
        let mut state = self.registry.0.lock().unwrap();
        let Some(entry) = state.entries.get_mut(&self.index) else {
            return false;
        };
        if !active(entry.data.phase) || entry.in_commit || self.cancel.is_cancelled() {
            return false;
        }
        entry.in_commit = true;
        true
    }
    pub(crate) fn finish_provider_publication(&self, succeeded: bool) {
        let mut state = self.registry.0.lock().unwrap();
        if let Some(entry) = state.entries.get_mut(&self.index) {
            if entry.in_commit {
                entry.data.phase = if succeeded {
                    "succeeded"
                } else {
                    "unconfirmed"
                };
                entry.in_commit = false;
            }
        }
        trim_history(&mut state);
    }
    /// Serialize irreversible upload publication against explicit single-task
    /// cancellation. A completed commit is success even if a parent was revoked
    /// concurrently; never tell the host a published file was canceled.
    pub(crate) fn publish<T, E>(
        &self,
        cancelled: E,
        commit: impl FnOnce() -> Result<T, E>,
    ) -> Result<T, E> {
        let _publication = self.publication.lock().unwrap();
        {
            let mut state = self.registry.0.lock().unwrap();
            let Some(entry) = state.entries.get_mut(&self.index) else {
                return Err(cancelled);
            };
            if !active(entry.data.phase) {
                return Err(cancelled);
            }
            if self.cancel.is_cancelled() {
                entry.data.phase = "canceled";
                trim_history(&mut state);
                return Err(cancelled);
            }
            entry.in_commit = true;
        }
        match commit() {
            Ok(value) => {
                let mut state = self.registry.0.lock().unwrap();
                if let Some(entry) = state.entries.get_mut(&self.index) {
                    entry.data.phase = "succeeded";
                    entry.in_commit = false;
                }
                trim_history(&mut state);
                Ok(value)
            }
            Err(error) => {
                {
                    let mut state = self.registry.0.lock().unwrap();
                    if let Some(entry) = state.entries.get_mut(&self.index) {
                        entry.in_commit = false;
                        entry.data.phase = "failed";
                    }
                    trim_history(&mut state);
                }
                Err(error)
            }
        }
    }
    pub(crate) fn failed(&self) {
        self.update(|r| r.phase = "failed");
    }
    pub(crate) fn body(self, response: Response<BoxedBody>) -> Response<BoxedBody> {
        if !response.status().is_success() {
            self.failed();
            return response;
        }
        let total = response
            .headers()
            .get("content-length")
            .and_then(|v| v.to_str().ok())
            .and_then(|v| v.parse::<u64>().ok());
        self.update(|r| {
            r.total = total;
            r.phase = if total == Some(0) {
                "succeeded"
            } else {
                "transferring"
            };
        });
        let (parts, body) = response.into_parts();
        let frames = futures_util::stream::unfold(Some((body, self)), |state| async move {
            let (mut body, guard) = state?;
            tokio::select! {
                biased;
                _ = guard.cancel.cancelled() => {
                    guard.update(|r| r.phase = "canceled");
                    Some((Err(std::io::Error::other("Download response canceled")), None))
                }
                frame = body.frame() => match frame {
                    Some(Ok(frame)) => {
                        if let Some(data) = frame.data_ref() {
                            guard.update(|r| {
                                r.transferred = r.transferred.saturating_add(data.len() as u64);
                                if r.total == Some(r.transferred) { r.phase = "succeeded"; }
                            });
                        }
                        Some((Ok(frame), Some((body, guard))))
                    }
                    Some(Err(error)) => { guard.failed(); Some((Err(error), None)) }
                    None => { guard.succeeded(); None }
                }
            }
        });
        Response::from_parts(parts, StreamBody::new(frames).boxed())
    }
}
impl Drop for Guard {
    fn drop(&mut self) {
        self.finish_provider_publication(false);
        self.update(|r| r.phase = "canceled");
        // A dropped request also stops work (such as a blocking ZIP scan) that
        // holds a clone. This token is a child, never the whole workspace.
        self.cancel.cancel();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use bytes::Bytes;
    use http_body_util::Full;
    fn records(r: &ActivityRegistry) -> serde_json::Value {
        serde_json::from_str(&r.snapshot()).unwrap()
    }
    #[test]
    fn shared_history_late_publication_survives_newer_completions_and_isolation() {
        let history = WebActivityHistory::default();
        let old_listener = history.0.clone();
        let new_listener = history.0.clone();
        let isolated = WebActivityHistory::default();
        let parent = CancellationToken::new();
        let guard = old_listener.begin("old", "ip", "late", &parent).unwrap();
        guard.started(3);
        guard.advance(3);
        let id = records(&old_listener)[0]["id"].as_str().unwrap().to_owned();
        let (entered_tx, entered_rx) = std::sync::mpsc::channel();
        let (release_tx, release_rx) = std::sync::mpsc::channel();
        let worker = std::thread::spawn(move || {
            guard.publish((), || {
                entered_tx.send(()).unwrap();
                release_rx.recv().unwrap();
                Ok::<_, ()>(())
            })
        });
        entered_rx.recv().unwrap();
        parent.cancel();
        let next_parent = CancellationToken::new();
        for _ in 0..300 {
            let next = new_listener
                .begin("new", "ip", "fast", &next_parent)
                .unwrap();
            next.started(0);
            next.succeeded();
        }
        let before = records(&new_listener);
        assert_eq!(before.as_array().unwrap().len(), MAX_HISTORY + 1);
        assert_eq!(before[0]["phase"], "transferring");
        assert_eq!(isolated.snapshot(), "[]");
        release_tx.send(()).unwrap();
        assert_eq!(worker.join().unwrap(), Ok(()));
        let after = records(&new_listener);
        assert_eq!(after.as_array().unwrap().len(), MAX_HISTORY);
        assert_eq!(
            after
                .as_array()
                .unwrap()
                .iter()
                .find(|r| r["id"] == id)
                .unwrap()["phase"],
            "succeeded"
        );
        assert!(!new_listener.cancel(&id));
        assert_eq!(history.snapshot(), old_listener.snapshot());
        let ids: std::collections::HashSet<_> = after
            .as_array()
            .unwrap()
            .iter()
            .map(|r| r["id"].as_str().unwrap())
            .collect();
        assert_eq!(ids.len(), MAX_HISTORY);
    }

    #[tokio::test]
    async fn real_listener_stop_and_restart_observe_late_filesystem_publication() {
        use crate::http::server::{
            start_with_port_or_available_with_activity_history, web::WebConfig,
        };
        use crate::http::state::ClientInfo;
        let history = WebActivityHistory::default();
        let info = || ClientInfo {
            alias: "activity-fixture".into(),
            version: "2.2".into(),
            device_model: None,
            device_type: None,
            token: "fixture".into(),
        };
        let (stop_first, stopped_first) = tokio::sync::oneshot::channel();
        let first = start_with_port_or_available_with_activity_history(
            0,
            None,
            info(),
            None,
            None,
            WebConfig::default(),
            stopped_first,
            history.clone(),
        )
        .await
        .unwrap();
        let (stop_isolated, stopped_isolated) = tokio::sync::oneshot::channel();
        let isolated = crate::http::server::start_with_port(
            0,
            None,
            info(),
            None,
            None,
            WebConfig::default(),
            stopped_isolated,
        )
        .await
        .unwrap();
        let directory =
            std::env::temp_dir().join(format!("legna-activity-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir(&directory).unwrap();
        let temporary = directory.join("pending.ls");
        let published = directory.join("published.txt");
        std::fs::write(&temporary, b"late outcome").unwrap();
        let guard = first
            .web
            .activities
            .begin("old", "ip", "published.txt", &first.cancel)
            .unwrap();
        guard.started(12);
        guard.advance(12);
        let id = records(&history.0)[0]["id"].as_str().unwrap().to_owned();
        let (entered_tx, entered_rx) = std::sync::mpsc::channel();
        let (release_tx, release_rx) = std::sync::mpsc::channel();
        let destination = published.clone();
        let worker = std::thread::spawn(move || {
            guard.publish(std::io::Error::other("canceled"), || {
                entered_tx.send(()).unwrap();
                release_rx.recv().unwrap();
                std::fs::rename(temporary, destination)
            })
        });
        entered_rx.recv().unwrap();
        stop_first.send(()).unwrap();
        first.wait_stopped().await;
        assert!(!published.exists());
        assert_eq!(
            serde_json::from_str::<serde_json::Value>(&first.web_download_activity()).unwrap()[0]["phase"],
            "transferring"
        );
        let (stop_second, stopped_second) = tokio::sync::oneshot::channel();
        let second = start_with_port_or_available_with_activity_history(
            0,
            None,
            info(),
            None,
            None,
            WebConfig::default(),
            stopped_second,
            history.clone(),
        )
        .await
        .unwrap();
        assert_eq!(
            second.web_download_activity(),
            first.web_download_activity()
        );
        assert_eq!(isolated.web_download_activity(), "[]");
        release_tx.send(()).unwrap();
        worker.join().unwrap().unwrap();
        assert_eq!(std::fs::read(&published).unwrap(), b"late outcome");
        assert_eq!(
            serde_json::from_str::<serde_json::Value>(&second.web_download_activity()).unwrap()[0]
                ["phase"],
            "succeeded"
        );
        assert!(!second.cancel_web_download(&id));
        stop_second.send(()).unwrap();
        second.wait_stopped().await;
        stop_isolated.send(()).unwrap();
        isolated.wait_stopped().await;
        std::fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn cancel_during_publication_never_waits_for_disk_or_blocks_other_activity() {
        for fail in [false, true] {
            let history = WebActivityHistory::default();
            let parent = CancellationToken::new();
            let guard = history.0.begin("s", "ip", "blocked", &parent).unwrap();
            guard.started(1);
            guard.advance(1);
            let id = records(&history.0)[0]["id"].as_str().unwrap().to_owned();
            let (entered_tx, entered_rx) = std::sync::mpsc::channel();
            let (release_tx, release_rx) = std::sync::mpsc::channel();
            let worker = std::thread::spawn(move || {
                guard.publish((), || {
                    entered_tx.send(()).unwrap();
                    release_rx.recv().unwrap();
                    if fail { Err(()) } else { Ok(()) }
                })
            });
            entered_rx.recv().unwrap();
            let registry = history.0.clone();
            let (result_tx, result_rx) = std::sync::mpsc::channel();
            let cancel = std::thread::spawn(move || result_tx.send(registry.cancel(&id)).unwrap());
            let before_release = result_rx.recv_timeout(std::time::Duration::from_millis(300));
            let sibling = history.0.begin("s", "ip", "sibling", &parent).unwrap();
            sibling.started(0);
            sibling.succeeded();
            assert_eq!(records(&history.0)[1]["phase"], "succeeded");
            assert_eq!(records(&history.0)[0]["phase"], "transferring");
            release_tx.send(()).unwrap();
            assert_eq!(worker.join().unwrap().is_err(), fail);
            cancel.join().unwrap();
            assert_eq!(
                before_release.unwrap(),
                false,
                "cancel must return before the publication is released"
            );
            assert_eq!(
                records(&history.0)[0]["phase"],
                if fail { "failed" } else { "succeeded" }
            );
        }
    }

    #[test]
    fn publication_failure_after_listener_stop_is_actual_failure() {
        let history = WebActivityHistory::default();
        let parent = CancellationToken::new();
        let guard = history.0.begin("s", "ip", "f", &parent).unwrap();
        guard.started(1);
        guard.advance(1);
        assert_eq!(
            guard.publish("cancel", || {
                parent.cancel();
                Err::<(), _>("disk failure")
            }),
            Err("disk failure")
        );
        assert_eq!(records(&history.0)[0]["phase"], "failed");
    }

    #[test]
    fn publication_commit_wins_late_cancel_without_blocking_other_snapshots() {
        let r = ActivityRegistry::default();
        let parent = CancellationToken::new();
        let guard = r.begin("s", "ip", "upload", &parent).unwrap();
        guard.started(3);
        guard.advance(3);
        let id = records(&r)[0]["id"].as_str().unwrap().to_owned();
        let (entered_tx, entered_rx) = std::sync::mpsc::channel();
        let (release_tx, release_rx) = std::sync::mpsc::channel();
        let worker = std::thread::spawn(move || {
            guard.publish((), || {
                entered_tx.send(()).unwrap();
                release_rx.recv().unwrap();
                Ok::<_, ()>(())
            })
        });
        entered_rx.recv().unwrap();
        parent.cancel();
        // Parent revoke while the real commit is in progress must not transiently
        // announce cancellation or prevent unrelated host state inspection.
        assert_eq!(records(&r)[0]["phase"], "transferring");
        let copy = r.clone();
        let cancel = std::thread::spawn(move || copy.cancel(&id));
        release_tx.send(()).unwrap();
        assert_eq!(worker.join().unwrap(), Ok(()));
        assert!(!cancel.join().unwrap());
        assert_eq!(records(&r)[0]["phase"], "succeeded");
    }
    #[test]
    fn cancel_before_publication_never_runs_commit() {
        let r = ActivityRegistry::default();
        let parent = CancellationToken::new();
        let guard = r.begin("s", "ip", "upload", &parent).unwrap();
        let id = records(&r)[0]["id"].as_str().unwrap().to_owned();
        assert!(r.cancel(&id));
        assert_eq!(
            guard.publish("canceled", || panic!("canceled commit ran")),
            Err::<(), _>("canceled")
        );
        assert_eq!(records(&r)[0]["phase"], "canceled");
    }
    #[test]
    fn workspace_upload_requires_publication_and_preserves_metadata() {
        let r = ActivityRegistry::default();
        let parent = CancellationToken::new();
        let g = r
            .begin_workspace(
                "",
                "x",
                &parent,
                WorkspaceActivity {
                    id: "workspace",
                    name: "Workspace",
                    direction: "receive",
                    operation: "upload",
                    origin: "api",
                },
            )
            .unwrap();
        g.started(3);
        g.advance(3);
        assert_eq!(records(&r)[0]["phase"], "transferring");
        g.succeeded();
        drop(g);
        let result = records(&r);
        assert_eq!(result[0]["phase"], "succeeded");
        assert_eq!(result[0]["direction"], "receive");
        assert_eq!(result[0]["workspaceId"], "workspace");
        assert_eq!(result[0]["operation"], "upload");
        assert_eq!(result[0]["origin"], "api");
        assert!(!parent.is_cancelled());
    }
    #[test]
    fn dropped_preparing_guard_stops_its_background_clone_not_its_sibling() {
        let r = ActivityRegistry::default();
        let parent = CancellationToken::new();
        let first = r.begin("s", "ip", "f", &parent).unwrap();
        let worker_cancel = first.cancel.clone();
        let sibling = r.begin("s", "ip", "g", &parent).unwrap();
        drop(first);
        assert!(worker_cancel.is_cancelled());
        assert!(!sibling.cancel.is_cancelled());
        assert!(!parent.is_cancelled());
        assert_eq!(records(&r)[0]["phase"], "canceled");
        parent.cancel();
        // No polling of either HTTP body is required to make closure visible.
        assert_eq!(records(&r)[1]["phase"], "canceled");
    }
    #[tokio::test]
    async fn truncated_response_never_succeeds() {
        let r = ActivityRegistry::default();
        let parent = CancellationToken::new();
        let g = r.begin("s", "ip", "f", &parent).unwrap();
        let response = g.body(
            Response::builder()
                .header("content-length", "4")
                .body(
                    Full::new(Bytes::from_static(b"abc"))
                        .map_err(|e| match e {})
                        .boxed(),
                )
                .unwrap(),
        );
        response.into_body().collect().await.unwrap();
        assert_eq!(records(&r)[0]["transferred"], 3);
        assert_eq!(records(&r)[0]["phase"], "failed");
    }
    #[tokio::test]
    async fn counts_response_range_bytes_and_marks_only_consumed_body_complete() {
        let r = ActivityRegistry::default();
        let parent = CancellationToken::new();
        let g = r.begin("s", "127.0.0.1", "f", &parent).unwrap();
        let response = g.body(
            Response::builder()
                .header("content-length", "3")
                .body(
                    Full::new(Bytes::from_static(b"abc"))
                        .map_err(|e| match e {})
                        .boxed(),
                )
                .unwrap(),
        );
        assert_eq!(records(&r)[0]["phase"], "transferring");
        response.into_body().collect().await.unwrap();
        assert_eq!(records(&r)[0]["phase"], "succeeded");
        assert_eq!(records(&r)[0]["transferred"], 3);
    }
    #[tokio::test]
    async fn dropping_unread_body_never_claims_completion_and_cancel_is_scoped() {
        let r = ActivityRegistry::default();
        let parent = CancellationToken::new();
        let first = r.begin("same", "ip", "f", &parent).unwrap();
        let second = r.begin("same", "ip", "f", &parent).unwrap();
        let id = records(&r)[0]["id"].as_str().unwrap().to_owned();
        assert!(r.cancel(&id));
        assert!(first.cancel.is_cancelled());
        assert!(!second.cancel.is_cancelled());
        assert!(!r.cancel(&id));
        drop(second);
        assert_eq!(records(&r)[1]["phase"], "canceled");
    }
    #[test]
    fn active_capacity_and_terminal_history_are_bounded() {
        let r = ActivityRegistry::default();
        let parent = CancellationToken::new();
        let guards: Vec<_> = (0..MAX_ACTIVE)
            .map(|_| r.begin("s", "ip", "f", &parent).unwrap())
            .collect();
        assert!(r.begin("s", "ip", "f", &parent).is_err());
        drop(guards);
        for _ in 0..400 {
            drop(r.begin("s", "ip", "f", &parent).unwrap());
        }
        assert_eq!(records(&r).as_array().unwrap().len(), MAX_HISTORY);
    }
    #[test]
    fn simultaneous_terminal_transitions_trim_history_without_another_request() {
        let registry = ActivityRegistry::default();
        let parent = CancellationToken::new();
        for _ in 0..MAX_HISTORY {
            drop(registry.begin("old", "ip", "old", &parent).unwrap());
        }
        let guards: Vec<_> = (0..MAX_ACTIVE)
            .map(|_| registry.begin("live", "ip", "new", &parent).unwrap())
            .collect();
        assert_eq!(
            records(&registry).as_array().unwrap().len(),
            MAX_ACTIVE + MAX_HISTORY
        );
        drop(guards);
        let result = records(&registry);
        assert_eq!(result.as_array().unwrap().len(), MAX_HISTORY);
        assert!(
            result
                .as_array()
                .unwrap()
                .iter()
                .all(|entry| entry["sessionId"] == "live" && entry["phase"] == "canceled")
        );
    }
}
