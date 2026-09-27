//! Persisted, scoped observations, not a recursive content hash or file validator.
//! One coalescing owner per workspace; persistence is acknowledged by the host.
use super::super::v2::ServerEventV2;
use super::DirectoryConfig;
use lru::LruCache;
use serde::Deserialize;
use serde_json::{Value, json};
use std::{
    collections::HashMap,
    num::NonZeroUsize,
    sync::{Arc, Mutex},
    time::{Duration, SystemTime, UNIX_EPOCH},
};
use tokio::sync::{mpsc, oneshot};
use tokio_util::sync::CancellationToken;

const MAX_SAFE: u64 = 9_007_199_254_740_991;
#[derive(Clone, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Snapshot {
    content_epoch: String,
    content_revision: u64,
    content_knowledge: String,
    last_observed_at: Option<u64>,
    dirty: bool,
}
impl Snapshot {
    fn valid(&self) -> bool {
        uuid::Uuid::parse_str(&self.content_epoch)
            .is_ok_and(|id| id.to_string() == self.content_epoch)
            && self.content_revision <= MAX_SAFE
            && matches!(self.content_knowledge.as_str(), "observed" | "unknown")
            && self.last_observed_at.is_none_or(|n| n <= MAX_SAFE)
            && !(self.dirty && self.content_knowledge == "observed")
    }
}
#[derive(Clone)]
struct Pending {
    sequence: u64,
    kind: &'static str,
    scope: String,
    changed: bool,
    dirty: bool,
    at: u64,
}
struct State {
    snapshot: Option<Snapshot>,
    sequence: u64,
    pending: Option<Pending>,
    running: bool,
    started: bool,
    attached: bool,
    uncertain: bool,
    // A bounded selection/directory metadata baseline. Never full-tree coverage.
    baselines: LruCache<String, String>,
    watches: LruCache<String, String>,
    hints: HashMap<String, u64>,
    hint_revision: u64,
    hint_overflow: bool,
}
pub(super) struct Observer {
    config: DirectoryConfig,
    owner: String,
    stopped: CancellationToken,
    events: Option<mpsc::Sender<ServerEventV2>>,
    state: Mutex<State>,
    runtime: Option<tokio::runtime::Handle>,
}
impl Observer {
    pub(super) fn new(
        config: &DirectoryConfig,
        owner: &str,
        stopped: CancellationToken,
        events: Option<mpsc::Sender<ServerEventV2>>,
    ) -> Arc<Self> {
        Arc::new(Self {
            config: config.clone(),
            owner: owner.to_owned(),
            stopped,
            events,
            runtime: tokio::runtime::Handle::try_current().ok(),
            state: Mutex::new(State {
                snapshot: None,
                sequence: 0,
                pending: None,
                running: false,
                started: false,
                attached: false,
                uncertain: true,
                baselines: LruCache::new(NonZeroUsize::new(128).unwrap()),
                watches: LruCache::new(NonZeroUsize::new(128).unwrap()),
                hints: HashMap::new(),
                hint_revision: 0,
                hint_overflow: false,
            }),
        })
    }
    /// Start only once the new catalog has been committed in core.
    pub(super) fn start(self: &Arc<Self>) {
        if self.events.is_none() || self.stopped.is_cancelled() {
            return;
        }
        let Some(runtime) = &self.runtime else {
            return;
        };
        let mut state = self.state.lock().unwrap();
        if state.started {
            return;
        }
        state.started = true;
        if state.running {
            return;
        }
        state.running = true;
        let this = self.clone();
        runtime.spawn(async move {
            this.run().await;
        });
    }
    pub(super) fn fields(&self, value: &mut Value) {
        let state = self.state.lock().unwrap();
        let pending = state.pending.is_some() || state.uncertain;
        let snapshot = state.snapshot.as_ref();
        value["contentEpoch"] = snapshot.map_or(Value::Null, |s| json!(s.content_epoch));
        value["contentRevision"] = json!(snapshot.map_or(0, |s| s.content_revision));
        value["contentKnowledge"] = json!(if pending {
            "unknown"
        } else {
            snapshot.map_or("unknown", |s| s.content_knowledge.as_str())
        });
        value["lastObservedAt"] = snapshot.map_or(Value::Null, |s| json!(s.last_observed_at));
        value["dirty"] = json!(pending || snapshot.is_some_and(|s| s.dirty));
    }
    /// Capture before reading metadata. A later watcher hint cannot be cleared
    /// by a check whose I/O had already started before that hint arrived.
    pub(super) fn ticket(&self) -> u64 {
        self.state.lock().unwrap().hint_revision
    }
    /// `key` binds a stable bounded selection, `fingerprint` contains metadata only.
    pub(super) fn observe(
        self: &Arc<Self>,
        scope: &str,
        key: String,
        fingerprint: String,
        ticket: u64,
    ) {
        let (changed, needed) = {
            let mut state = self.state.lock().unwrap();
            let scope_key = crate::crypto::hash::sha256_hex(scope.as_bytes());
            if state
                .hints
                .get(&scope_key)
                .is_some_and(|revision| *revision <= ticket)
            {
                state.hints.remove(&scope_key);
            }
            let key = crate::crypto::hash::sha256_hex(key.as_bytes());
            let previous = state.baselines.put(key, fingerprint.clone());
            let changed = previous.as_ref().is_some_and(|old| old != &fingerprint);
            let needed = previous.is_none()
                || changed
                || state.uncertain
                || state
                    .snapshot
                    .as_ref()
                    .is_none_or(|s| s.content_knowledge != "observed" || s.dirty);
            (changed, needed)
        };
        if needed {
            self.schedule("observe", scope, changed, false);
        }
    }
    /// Provider lease revisions and watcher events only invalidate; they are not evidence of changed bytes.
    pub(super) fn watch_hint(self: &Arc<Self>, scope: &str, stamp: String, observing: bool) {
        let changed = {
            let mut state = self.state.lock().unwrap();
            let old = state.watches.put(
                crate::crypto::hash::sha256_hex(scope.as_bytes()),
                stamp.clone(),
            );
            !observing || old.is_some_and(|old| old != stamp)
        };
        if changed {
            self.hint(scope);
        }
    }
    pub(super) fn hint(self: &Arc<Self>, scope: &str) {
        self.schedule("hint", scope, false, true);
    }
    pub(super) fn published(self: &Arc<Self>, scope: &str) {
        self.schedule("published", scope, true, false);
    }
    fn schedule(self: &Arc<Self>, kind: &'static str, scope: &str, changed: bool, dirty: bool) {
        if self.stopped.is_cancelled() || self.events.is_none() {
            return;
        }
        let Some(runtime) = &self.runtime else {
            return;
        };
        let mut state = self.state.lock().unwrap();
        state.sequence = state.sequence.saturating_add(1).min(MAX_SAFE);
        let sequence = state.sequence;
        if kind == "hint" {
            state.hint_revision = state.hint_revision.saturating_add(1);
            let revision = state.hint_revision;
            let key = crate::crypto::hash::sha256_hex(scope.as_bytes());
            if state.hints.len() < 128 || state.hints.contains_key(&key) {
                state.hints.insert(key, revision);
            } else {
                state.hint_overflow = true;
            }
        }
        let dirty = dirty || !state.hints.is_empty() || state.hint_overflow;
        let at = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_millis()
            .min(MAX_SAFE as u128) as u64;
        let mut next = Pending {
            sequence,
            kind,
            scope: scope.to_owned(),
            changed,
            dirty,
            at,
        };
        if let Some(previous) = state.pending.take() {
            next.changed |= previous.changed;
            // A later hint must not erase an already-confirmed observation or
            // manufacture a later real-observation timestamp for that change.
            if next.kind == "hint" && matches!(previous.kind, "observe" | "published") {
                next.kind = previous.kind;
                next.at = previous.at;
            }
            if previous.kind == "published" {
                next.kind = "published";
            }
            if previous.scope != next.scope {
                next.scope.clear();
                next.dirty |= previous.dirty;
            }
        }
        state.pending = Some(next);
        state.uncertain = true;
        if state.running {
            return;
        }
        state.running = true;
        let this = self.clone();
        runtime.spawn(async move {
            this.run().await;
        });
    }
    async fn request(&self, pending: &Pending) -> Option<Snapshot> {
        let (result_tx, rx) = oneshot::channel();
        let request = json!({"version":1,"workspaceId":self.config.id,"generation":self.config.generation,
            "owner":self.owner,"source":{"root":self.config.root,"documentTree":self.config.document_tree},
            "sequence":pending.sequence,"kind":pending.kind,"scope":pending.scope,"changed":pending.changed,
            "dirty":pending.dirty,"observedAtUnixMs":pending.at}).to_string();
        let operation = async {
            self.events
                .as_ref()?
                .send(ServerEventV2::DirectoryContent { request, result_tx })
                .await
                .ok()?;
            let reply = rx.await.ok()?.ok()?;
            if reply.len() > 4096 {
                return None;
            }
            let value: Snapshot = serde_json::from_str(&reply).ok()?;
            value.valid().then_some(value)
        };
        tokio::select! { biased;
            _ = self.stopped.cancelled() => None,
            value = tokio::time::timeout(Duration::from_secs(10), operation) => value.ok().flatten(),
        }
    }
    async fn run(self: Arc<Self>) {
        loop {
            if self.stopped.is_cancelled() {
                return;
            }
            // A fixed window merges a burst without allocating a per-file queue.
            tokio::select! { _ = self.stopped.cancelled() => return, _ = tokio::time::sleep(Duration::from_millis(250)) => {} }
            let pending = {
                let mut state = self.state.lock().unwrap();
                if !state.attached {
                    Pending {
                        sequence: 0,
                        kind: "attach",
                        scope: String::new(),
                        changed: false,
                        dirty: true,
                        at: 0,
                    }
                } else if let Some(pending) = state.pending.take() {
                    pending
                } else {
                    state.running = false;
                    return;
                }
            };
            // Freeze this payload while awaiting acknowledgement. New observations
            // have a separate single pending slot, so a lost reply cannot merge an
            // already-committed change into a new sequence and count it twice.
            let mut delay = 1u64;
            loop {
                if self.stopped.is_cancelled() {
                    return;
                }
                if let Some(reply) = self.request(&pending).await {
                    let mut state = self.state.lock().unwrap();
                    let monotonic = state.snapshot.as_ref().is_none_or(|old| {
                        old.content_epoch == reply.content_epoch
                            && old.content_revision <= reply.content_revision
                    });
                    if monotonic {
                        state.snapshot = Some(reply);
                        if pending.kind == "attach" {
                            state.attached = true;
                        }
                        state.uncertain = state.pending.is_some();
                        break;
                    }
                }
                // The host deduplicates the unchanged sequence after a lost ACK.
                tokio::select! { _ = self.stopped.cancelled() => return, _ = tokio::time::sleep(Duration::from_secs(delay)) => {} }
                delay = (delay * 2).min(30);
            }
        }
    }
}
