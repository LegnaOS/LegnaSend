//! Test-only blocking syscall-completion gates, keyed by unique fixture paths.
use super::*;
use crate::http::server::{
    start_with_port,
    v2::{PrepareUploadDecisionV2, ServerEventV2},
    web::WebConfig,
    ServerConfigV2, ServerHandle,
};
use crate::http::state::ClientInfo;
use serde_json::{json, Value};
use std::{
    collections::HashMap,
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc, Condvar, Mutex, OnceLock, Weak,
    },
    time::Duration,
};
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Point {
    WorkerStarted,
    DescriptorsReady,
    WorkerReleased,
    Opened,
    CacheCreated,
    Write,
    BeforePublish,
    Published,
}
struct Gate {
    point: Point,
    used: AtomicBool,
    entered: tokio::sync::Notify,
    released: Mutex<bool>,
    wake: Condvar,
    seen: Mutex<Vec<Point>>,
}
static HOOKS: OnceLock<Mutex<HashMap<PathBuf, Weak<Gate>>>> = OnceLock::new();
pub(crate) fn checkpoint(path: &std::path::Path, point: Point) {
    let gate = HOOKS
        .get_or_init(Default::default)
        .lock()
        .unwrap()
        .get(path)
        .and_then(Weak::upgrade);
    if let Some(gate) = gate {
        gate.seen.lock().unwrap().push(point);
        if point == gate.point && !gate.used.swap(true, Ordering::SeqCst) {
            gate.entered.notify_one();
            let mut released = gate.released.lock().unwrap();
            while !*released {
                released = gate.wake.wait(released).unwrap();
            }
        }
    }
}
struct Hold {
    path: PathBuf,
    gate: Arc<Gate>,
}
impl Hold {
    fn new(path: PathBuf, point: Point) -> Self {
        let gate = Arc::new(Gate {
            point,
            used: AtomicBool::new(false),
            entered: tokio::sync::Notify::new(),
            released: Mutex::new(false),
            wake: Condvar::new(),
            seen: Mutex::new(vec![]),
        });
        HOOKS
            .get_or_init(Default::default)
            .lock()
            .unwrap()
            .insert(path.clone(), Arc::downgrade(&gate));
        Self { path, gate }
    }
    async fn entered(&self) {
        tokio::time::timeout(Duration::from_secs(2), self.gate.entered.notified())
            .await
            .unwrap();
    }
    fn release(&self) {
        *self.gate.released.lock().unwrap() = true;
        self.gate.wake.notify_all();
    }
    fn seen(&self) -> Vec<Point> {
        self.gate.seen.lock().unwrap().clone()
    }
}
impl Drop for Hold {
    fn drop(&mut self) {
        self.release();
        HOOKS.get().unwrap().lock().unwrap().remove(&self.path);
    }
}
struct Fixture {
    handle: ServerHandle,
    events: mpsc::Receiver<ServerEventV2>,
    client: reqwest::Client,
    dir: PathBuf,
    stop: Option<oneshot::Sender<()>>,
}
impl Fixture {
    async fn new() -> Self {
        let dir = std::env::temp_dir().join(format!(
            "legnasend-blocked-receive-{}",
            uuid::Uuid::new_v4()
        ));
        std::fs::create_dir(&dir).unwrap();
        let (event_tx, events) = mpsc::channel(32);
        let (stop, rx) = oneshot::channel();
        let handle = start_with_port(
            0,
            None,
            ClientInfo {
                alias: "Blocked fixture".into(),
                version: "2.2".into(),
                device_model: None,
                device_type: None,
                token: "fixture".into(),
            },
            None,
            Some(ServerConfigV2 {
                pin: None,
                verify_checksums: true,
                event_tx,
            }),
            WebConfig::default(),
            rx,
        )
        .await
        .unwrap();
        Self {
            handle,
            events,
            client: reqwest::Client::builder()
                .no_proxy()
                .timeout(Duration::from_secs(4))
                .build()
                .unwrap(),
            dir,
            stop: Some(stop),
        }
    }
    fn url(&self, path: &str) -> String {
        format!(
            "http://127.0.0.1:{}/api/localsend/v2/{path}",
            self.handle.port()
        )
    }
    async fn prepare(&mut self, data: &[u8]) -> Value {
        let request=self.client.post(self.url("prepare-upload")).json(&json!({"info":{"alias":"sender","version":"2.2","fingerprint":"sender","port":53317,"protocol":"http"},"files":{"f":{"id":"f","fileName":"fixture.bin","size":data.len(),"fileType":"application/octet-stream","sha256":crate::crypto::hash::sha256_hex(data)}}}));
        let response = tokio::spawn(async move { request.send().await.unwrap() });
        loop {
            if let ServerEventV2::PrepareUpload { decision_tx, .. } =
                self.events.recv().await.unwrap()
            {
                decision_tx
                    .send(PrepareUploadDecisionV2::Accept(["f".into()].into()))
                    .unwrap();
                break;
            }
        }
        let response = response.await.unwrap();
        assert_eq!(response.status(), 200);
        response.json().await.unwrap()
    }
    async fn upload(
        &mut self,
        session: &Value,
        data: Vec<u8>,
        name: &str,
    ) -> (
        tokio::task::JoinHandle<reqwest::Response>,
        oneshot::Receiver<Result<(), String>>,
    ) {
        let request = self
            .client
            .post(format!(
                "{}?sessionId={}&fileId=f&token={}",
                self.url("upload"),
                session["sessionId"].as_str().unwrap(),
                session["files"]["f"].as_str().unwrap()
            ))
            .body(data);
        let response = tokio::spawn(async move { request.send().await.unwrap() });
        let (result_tx, result) = oneshot::channel();
        loop {
            if let ServerEventV2::FileUpload { target_tx, .. } = self.events.recv().await.unwrap() {
                target_tx
                    .send(
                        crate::http::server::common::save::FileUploadTarget::CachedPath {
                            path: self.dir.join(name),
                            result_tx,
                            progress_tx: None,
                        },
                    )
                    .unwrap();
                break;
            }
        }
        (response, result)
    }
    async fn cancel(&self, session: &Value) {
        assert!(
            self.handle
                .cancel_v2_session(session["sessionId"].as_str().unwrap())
                .await
        );
    }
    async fn next(&mut self) {
        let bytes = b"next original-v2 transfer";
        let session = self.prepare(bytes).await;
        let (http, receipt) = self.upload(&session, bytes.to_vec(), "next.bin").await;
        assert_eq!(http.await.unwrap().status(), 200);
        assert_eq!(receipt.await.unwrap(), Ok(()));
        assert_eq!(
            crate::crypto::hash::sha256_hex(&std::fs::read(self.dir.join("next.bin")).unwrap()),
            crate::crypto::hash::sha256_hex(bytes)
        );
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        if let Some(stop) = self.stop.take() {
            let _ = stop.send(());
        }
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

#[tokio::test]
async fn cancel_open_wait_ends_http_before_syscall_returns_and_never_creates_late_cache() {
    let mut f = Fixture::new().await;
    let hold = Hold::new(f.dir.join("old.bin"), Point::Opened);
    let data = b"canceled before target directory open returned";
    let session = f.prepare(data).await;
    let (mut http, mut receipt) = f.upload(&session, data.to_vec(), "old.bin").await;
    hold.entered().await;
    f.cancel(&session).await;
    let response = tokio::time::timeout(Duration::from_millis(250), &mut http).await;
    assert!(
        response.is_ok(),
        "HTTP cancellation still waited for blocked open"
    );
    assert_eq!(response.unwrap().unwrap().status(), 500);
    assert!(
        matches!(receipt.try_recv(), Err(oneshot::error::TryRecvError::Empty)),
        "Result must belong to actual worker, not the early HTTP exit"
    );
    f.next().await;
    hold.release();
    assert!(receipt.await.unwrap().is_err());
    assert_eq!(
        hold.seen(),
        vec![Point::WorkerStarted, Point::Opened, Point::WorkerReleased]
    );
    assert!(!f.dir.join("old.bin").exists());
    assert_eq!(std::fs::read_dir(&f.dir).unwrap().count(), 1);
}

#[tokio::test]
async fn cancellation_during_open_never_starts_cache_creation_after_open_returns() {
    let f = Fixture::new().await;
    let path = f.dir.join("old.bin");
    let hold = Hold::new(path.clone(), Point::Opened);
    let cancel = CancellationToken::new();
    let token = cancel.clone();
    let id = identity(
        &path,
        3,
        None,
        &Context {
            cancel: cancel.clone(),
            session_id: "test".into(),
            file_id: "f".into(),
            attempt_id: "a".into(),
            event_tx: mpsc::channel(1).0,
        },
    );
    let worker = tokio::task::spawn_blocking(move || {
        receive(
            path,
            id,
            FileTimestamps::default(),
            {
                let (tx, rx) = mpsc::channel(2);
                tx.try_send(Message::Data(Bytes::from_static(b"abc")))
                    .unwrap();
                tx.try_send(Message::Finish).unwrap();
                rx
            },
            token,
            None,
        )
    });
    hold.entered().await;
    cancel.cancel();
    hold.release();
    assert!(matches!(worker.await.unwrap(), Err(CacheError::Cancelled)));
    assert_eq!(
        hold.seen(),
        vec![Point::Opened],
        "Cancellation must stop the first cache creation, not merely remove it later"
    );
    assert_eq!(std::fs::read_dir(&f.dir).unwrap().count(), 0);
}

#[tokio::test]
async fn cancel_blocked_write_returns_http_then_cleans_owned_cache_without_publication() {
    let mut f = Fixture::new().await;
    std::fs::write(f.dir.join("user.ls"), b"unrelated").unwrap();
    let hold = Hold::new(f.dir.join("old.bin"), Point::Write);
    let data = vec![7; 2 * 1024 * 1024];
    let session = f.prepare(&data).await;
    let (mut http, mut receipt) = f.upload(&session, data, "old.bin").await;
    hold.entered().await;
    assert!(std::fs::read_dir(&f.dir).unwrap().any(|e| {
        e.unwrap()
            .file_name()
            .to_string_lossy()
            .starts_with(".legnasend-receive-")
    }));
    assert_eq!(
        f.client
            .post(format!(
                "{}?sessionId={}",
                f.url("cancel"),
                session["sessionId"].as_str().unwrap()
            ))
            .send()
            .await
            .unwrap()
            .status(),
        200
    );
    assert_eq!(
        tokio::time::timeout(Duration::from_millis(250), &mut http)
            .await
            .unwrap()
            .unwrap()
            .status(),
        500
    );
    assert!(matches!(
        receipt.try_recv(),
        Err(oneshot::error::TryRecvError::Empty)
    ));
    assert!(!f.dir.join("old.bin").exists());
    hold.release();
    assert!(receipt.await.unwrap().is_err());
    assert!(!hold.seen().contains(&Point::BeforePublish));
    assert!(!hold.seen().contains(&Point::Published));
    assert_eq!(std::fs::read_dir(&f.dir).unwrap().count(), 1);
    assert_eq!(std::fs::read(f.dir.join("user.ls")).unwrap(), b"unrelated");
    f.next().await;
}

#[tokio::test]
async fn cancel_before_publication_never_creates_final_file() {
    let mut f = Fixture::new().await;
    let hold = Hold::new(f.dir.join("old.bin"), Point::BeforePublish);
    let data = b"verified but not published";
    let session = f.prepare(data).await;
    let (mut http, receipt) = f.upload(&session, data.to_vec(), "old.bin").await;
    hold.entered().await;
    f.cancel(&session).await;
    assert_eq!(
        tokio::time::timeout(Duration::from_millis(250), &mut http)
            .await
            .unwrap()
            .unwrap()
            .status(),
        500
    );
    hold.release();
    assert!(receipt.await.unwrap().is_err());
    assert!(!hold.seen().contains(&Point::Published));
    assert_eq!(std::fs::read_dir(&f.dir).unwrap().count(), 0);
}

#[tokio::test]
async fn actual_publication_wins_and_late_receipt_is_not_stolen_by_early_http_cancel() {
    let mut f = Fixture::new().await;
    let hold = Hold::new(f.dir.join("old.bin"), Point::Published);
    let data = b"actual published bytes survive cancellation";
    let session = f.prepare(data).await;
    let (mut http, mut receipt) = f.upload(&session, data.to_vec(), "old.bin").await;
    hold.entered().await;
    assert_eq!(std::fs::read(f.dir.join("old.bin")).unwrap(), data);
    f.cancel(&session).await;
    assert_eq!(
        tokio::time::timeout(Duration::from_millis(250), &mut http)
            .await
            .unwrap()
            .unwrap()
            .status(),
        500
    );
    assert!(matches!(
        receipt.try_recv(),
        Err(oneshot::error::TryRecvError::Empty)
    ));
    hold.release();
    assert_eq!(receipt.await.unwrap(), Ok(()));
    assert_eq!(std::fs::read(f.dir.join("old.bin")).unwrap(), data);
    assert_eq!(std::fs::read_dir(&f.dir).unwrap().count(), 1);
    f.next().await;
}

#[tokio::test]
async fn canceled_detached_open_retains_its_worker_budget_until_real_cleanup() {
    // Observe this worker's permit lifetime only. Other lib tests legitimately
    // share the production eight-worker budget; never reserve their capacity.
    let mut f = Fixture::new().await;
    let hold = Hold::new(f.dir.join("old.bin"), Point::Opened);
    let data = b"owned budget";
    let session = f.prepare(data).await;
    let (mut http, receipt) = f.upload(&session, data.to_vec(), "old.bin").await;
    hold.entered().await;
    f.cancel(&session).await;
    assert_eq!(
        tokio::time::timeout(Duration::from_millis(250), &mut http)
            .await
            .unwrap()
            .unwrap()
            .status(),
        500
    );
    assert_eq!(hold.seen(), vec![Point::WorkerStarted, Point::Opened]);
    f.next().await;
    assert!(!hold.seen().contains(&Point::WorkerReleased));
    hold.release();
    assert!(receipt.await.unwrap().is_err());
    assert_eq!(
        hold.seen(),
        vec![Point::WorkerStarted, Point::Opened, Point::WorkerReleased]
    );
    assert!(!f.dir.join("old.bin").exists());
}

#[cfg(unix)]
#[tokio::test]
async fn descriptor_cancel_returns_before_blocked_io_and_releases_only_after_real_close() {
    use std::os::{fd::AsRawFd, unix::fs::MetadataExt};
    fn is_original(fd: i32, expected: &std::fs::Metadata) -> bool {
        let mut actual = std::mem::MaybeUninit::<libc::stat>::uninit();
        if unsafe { libc::fstat(fd, actual.as_mut_ptr()) } != 0 {
            return false;
        }
        let actual = unsafe { actual.assume_init() };
        actual.st_dev as u64 == expected.dev() && actual.st_ino as u64 == expected.ino()
    }
    for point in [Point::DescriptorsReady, Point::Write] {
        let mut f = Fixture::new().await;
        let transaction = uuid::Uuid::new_v4().to_string();
        let hold = Hold::new(PathBuf::from(&transaction), point);
        let data = vec![9; 2 * 1024 * 1024];
        let session = f.prepare(&data).await;
        let request = f
            .client
            .post(format!(
                "{}?sessionId={}&fileId=f&token={}",
                f.url("upload"),
                session["sessionId"].as_str().unwrap(),
                session["files"]["f"].as_str().unwrap()
            ))
            .body(data);
        let mut http = tokio::spawn(async move { request.send().await.unwrap() });
        let open = |name: &str| {
            std::fs::OpenOptions::new()
                .create_new(true)
                .read(true)
                .write(true)
                .open(f.dir.join(name))
                .unwrap()
        };
        let cache = open("provider-cache.ls");
        let stage = open("provider-stage.part");
        let cache_fd = cache.as_raw_fd();
        let stage_fd = stage.as_raw_fd();
        let cache_identity = cache.metadata().unwrap();
        let stage_identity = stage.metadata().unwrap();
        let (result_tx, receipt) = oneshot::channel();
        loop {
            if let ServerEventV2::FileUpload { target_tx, .. } = f.events.recv().await.unwrap() {
                target_tx
                    .send(
                        crate::http::server::common::save::FileUploadTarget::CachedOpenedFiles {
                            cache,
                            staging: stage,
                            transaction_id: transaction.clone(),
                            result_tx,
                            progress_tx: None,
                        },
                    )
                    .unwrap();
                break;
            }
        }
        hold.entered().await;
        f.cancel(&session).await;
        let response = tokio::time::timeout(Duration::from_millis(250), &mut http).await;
        assert!(
            response.is_ok(),
            "Descriptor upload cancel waited for its blocked worker at {point:?}"
        );
        assert_eq!(response.unwrap().unwrap().status(), 500);
        assert!(receipt.await.unwrap().is_err());
        assert!(is_original(cache_fd, &cache_identity));
        assert!(is_original(stage_fd, &stage_identity));
        assert!(!hold.seen().contains(&Point::WorkerReleased));
        while let Ok(event) = f.events.try_recv() {
            assert!(
                !matches!(
                    event,
                    ServerEventV2::PublishUpload { .. } | ServerEventV2::UploadCacheReleased { .. }
                ),
                "No provider publication or release before descriptor closure"
            );
        }
        hold.release();
        let event = tokio::time::timeout(Duration::from_secs(2), f.events.recv())
            .await
            .unwrap()
            .unwrap();
        match event {
            ServerEventV2::UploadCacheReleased {
                transaction_id,
                published,
                ..
            } => {
                assert_eq!(transaction_id, transaction);
                assert!(!published);
            }
            other => panic!("Unexpected event: {other:?}"),
        }
        // Other parallel tests may reuse a closed numeric fd. It must no longer
        // refer to either of our uniquely named provider documents.
        assert!(!is_original(cache_fd, &cache_identity));
        assert!(!is_original(stage_fd, &stage_identity));
        assert!(hold.seen().contains(&Point::WorkerReleased));
        assert!(!std::fs::read_dir(&f.dir)
            .unwrap()
            .any(|e| e.unwrap().file_name() == "old.bin"));
        // Provider documents remain its journal's responsibility; core closes
        // handles but never guesses which provider entries to delete.
        assert!(f.dir.join("provider-cache.ls").exists());
        assert!(f.dir.join("provider-stage.part").exists());
        f.next().await;
    }
}
