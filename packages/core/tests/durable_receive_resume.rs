#![cfg(feature = "full")]
//! Fresh original-v2 approvals around a real persistent receiver and sender.
use localsend::{
    http::{
        client::{LsHttpClient, LsHttpClientV2},
        server::{
            ServerConfigV2, ServerHandle,
            common::save::FileUploadTarget,
            start_with_port,
            v2::{PrepareUploadDecisionV2, ServerEventV2},
            web::WebConfig,
        },
        state::ClientInfo,
    },
    model::{discovery::ProtocolType, transfer::FileContent},
};
use serde_json::{Value, json};
use std::{
    collections::HashSet,
    path::PathBuf,
    sync::{Arc, Mutex},
    time::Duration,
};
use tokio::sync::{mpsc, oneshot};
use tokio_util::sync::CancellationToken;
const BLOCK: usize = 1024 * 1024;

struct Fixture {
    server: Arc<ServerHandle>,
    stop: Option<oneshot::Sender<()>>,
    client: reqwest::Client,
    targets: Arc<Mutex<Vec<(String, Option<u64>)>>>,
    results: mpsc::UnboundedReceiver<Result<(), String>>,
}
impl Fixture {
    async fn new(root: PathBuf) -> Self {
        std::fs::create_dir_all(root.join("received")).unwrap();
        let (events, mut rx) = mpsc::channel(64);
        let (stop, stopped) = oneshot::channel();
        let server = Arc::new(
            start_with_port(
                0,
                None,
                ClientInfo {
                    alias: "durable receiver".into(),
                    version: "2.2".into(),
                    device_model: None,
                    device_type: None,
                    token: "durable-receiver".into(),
                },
                None,
                Some(ServerConfigV2 {
                    pin: None,
                    verify_checksums: true,
                    event_tx: events,
                }),
                WebConfig::default(),
                stopped,
            )
            .await
            .unwrap(),
        );
        let weak = Arc::downgrade(&server);
        let destination = root.join("received");
        let targets = Arc::new(Mutex::new(Vec::new()));
        let receipts = targets.clone();
        let (result_tx, results) = mpsc::unbounded_channel();
        tokio::spawn(async move {
            while let Some(event) = rx.recv().await {
                match event {
                    ServerEventV2::PrepareUpload {
                        files, decision_tx, ..
                    } => {
                        let ids: HashSet<String> = files.keys().cloned().collect();
                        let _ = decision_tx.send(PrepareUploadDecisionV2::AcceptDurable {
                            file_ids: ids.clone(),
                            resumable_file_ids: ids.clone(),
                            durable_file_ids: ids,
                        });
                    }
                    ServerEventV2::FileUploadRecovery {
                        session_id,
                        file_id,
                        attempt_id,
                        file,
                        target_tx,
                    } => {
                        let handle = weak.upgrade().unwrap();
                        let lookup = handle
                            .lookup_receive_recovery_target(
                                &session_id,
                                &file_id,
                                &attempt_id,
                                destination.to_string_lossy().into_owned(),
                                file.file_name.clone(),
                            )
                            .await
                            .unwrap();
                        receipts
                            .lock()
                            .unwrap()
                            .push((lookup.receipt_id, lookup.completed_unix_ms));
                        let path = lookup
                            .path
                            .map(PathBuf::from)
                            .unwrap_or_else(|| destination.join(file.file_name));
                        let (tx, result) = oneshot::channel();
                        let _ = target_tx.send(FileUploadTarget::CachedPath {
                            path,
                            result_tx: tx,
                            progress_tx: None,
                        });
                        let result_tx = result_tx.clone();
                        tokio::spawn(async move {
                            let _ = result_tx.send(
                                result
                                    .await
                                    .unwrap_or_else(|_| Err("target dropped".into())),
                            );
                        });
                    }
                    ServerEventV2::FileUpload { .. } => {
                        panic!("durable source unexpectedly used ordinary upload")
                    }
                    _ => {}
                }
            }
        });
        Self {
            server,
            stop: Some(stop),
            client: reqwest::Client::builder()
                .no_proxy()
                .timeout(Duration::from_secs(10))
                .build()
                .unwrap(),
            targets,
            results,
        }
    }
    fn base(&self) -> String {
        format!("http://127.0.0.1:{}", self.server.port())
    }
    async fn prepare(&self, bytes: &[u8]) -> Value {
        let r = self.client.post(format!("{}/api/localsend/v2/prepare-upload", self.base())).json(&json!({
            "info": {"alias":"durable sender","version":"2.2","fingerprint":"sender","port":53317,"protocol":"http"},
            "files":{"f":{"id":"f","fileName":"output.bin","size":bytes.len(),"fileType":"application/octet-stream","sha256":sha(bytes)}}
        })).send().await.unwrap();
        assert_eq!(r.status(), 200);
        r.json().await.unwrap()
    }
    fn url(&self, op: &str, session: &Value, receipt: Option<&Value>) -> String {
        let mut q = form_urlencoded::Serializer::new(String::new());
        q.append_pair("sessionId", session["sessionId"].as_str().unwrap())
            .append_pair("fileId", "f")
            .append_pair("token", session["files"]["f"].as_str().unwrap());
        if let Some(r) = receipt {
            q.append_pair("resumeId", r["resumeId"].as_str().unwrap());
        }
        format!(
            "{}/api/legnasend/v1/receive-resume/{op}?{}",
            self.base(),
            q.finish()
        )
    }
    async fn open(&self, session: &Value, bytes: &[u8], key: &str) -> Value {
        let cap: Value = self
            .client
            .get(self.url("capabilities", session, None))
            .send()
            .await
            .unwrap()
            .json()
            .await
            .unwrap();
        assert_eq!(cap["durable"]["version"], 1);
        let r = self.client.post(self.url("open",session,None)).json(&json!({"size":bytes.len(),"sha256":sha(bytes),"recovery":{"version":1,"resumeKey":key}})).send().await.unwrap();
        assert_eq!(r.status(), 200);
        r.json().await.unwrap()
    }
    async fn ready(&self, session: &Value, mut r: Value) -> Value {
        for _ in 0..500 {
            if r["state"] != "verifying" {
                return r;
            }
            assert_eq!(
                r["offset"], 0,
                "unverified cache must not become wire progress"
            );
            tokio::time::sleep(Duration::from_millis(10)).await;
            let response = self
                .client
                .get(self.url("status", session, Some(&r)))
                .send()
                .await
                .unwrap();
            assert_eq!(response.status(), 200);
            r = response.json().await.unwrap();
        }
        panic!("verification did not finish");
    }
    async fn block(&self, s: &Value, r: &Value, offset: usize, bytes: &[u8]) {
        let response = self
            .client
            .put(format!("{}&offset={offset}", self.url("block", s, Some(r))))
            .header("X-LegnaSend-Block-Sha256", sha(bytes))
            .body(bytes.to_vec())
            .send()
            .await
            .unwrap();
        assert_eq!(response.status(), 200);
    }
    async fn suspend(&self, s: &Value, r: &Value) {
        let response = self
            .client
            .post(self.url("suspend", s, Some(r)))
            .send()
            .await
            .unwrap();
        assert_eq!(response.status(), 200);
    }
    async fn cancel(&self, s: &Value) {
        let response = self
            .client
            .post(format!(
                "{}/api/localsend/v2/cancel?sessionId={}",
                self.base(),
                s["sessionId"].as_str().unwrap()
            ))
            .send()
            .await
            .unwrap();
        assert!(response.status().is_success());
    }
    async fn result(&mut self) -> Result<(), String> {
        tokio::time::timeout(Duration::from_secs(5), self.results.recv())
            .await
            .unwrap()
            .unwrap()
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        self.stop.take();
    }
}
fn sha(bytes: &[u8]) -> String {
    localsend::crypto::hash::sha256_hex(bytes).to_ascii_lowercase()
}

#[tokio::test]
async fn fresh_approval_reuses_verified_prefix_and_completed_receipt_without_duplicate_output() {
    let root =
        std::env::temp_dir().join(format!("legnasend-durable-chain-{}", uuid::Uuid::new_v4()));
    std::fs::create_dir(&root).unwrap();
    localsend::receive_registry::configure(root.join("private-registry")).unwrap();
    let mut f = Fixture::new(root.clone()).await;
    assert!(
        f.server
            .supports_receive_recovery_target(
                root.join("received").to_string_lossy().into_owned(),
                "output.bin".into()
            )
            .await
            .unwrap()
    );
    let bytes = (0..BLOCK * 3 + 317)
        .map(|i| (i % 251) as u8)
        .collect::<Vec<_>>();
    let key = uuid::Uuid::new_v4().to_string();
    let a = f.prepare(&bytes).await;
    let opened = f.open(&a, &bytes, &key).await;
    let first = f.ready(&a, opened).await;
    assert_eq!(first["offset"], 0);
    f.block(&a, &first, 0, &bytes[..BLOCK]).await;
    f.suspend(&a, &first).await;
    // Releasing an obsolete original session must not delete its detached lease.
    let old_abort = f
        .client
        .post(f.url("abort", &a, Some(&first)))
        .send()
        .await
        .unwrap();
    assert_eq!(old_abort.status(), 410);
    f.cancel(&a).await;
    let _ = f.result().await;
    let b = f.prepare(&bytes).await;
    assert_ne!(a["sessionId"], b["sessionId"]);
    assert_ne!(a["files"]["f"], b["files"]["f"]);
    let reopened = f.open(&b, &bytes, &key).await;
    assert_ne!(first["resumeId"], reopened["resumeId"]);
    let second = f.ready(&b, reopened).await;
    assert_eq!(second["offset"], BLOCK as u64);
    let mut wrong = b.clone();
    wrong["files"]["f"] = a["files"]["f"].clone();
    assert!(
        !f.client
            .get(f.url("status", &wrong, Some(&second)))
            .send()
            .await
            .unwrap()
            .status()
            .is_success()
    );
    f.suspend(&b, &second).await;
    f.cancel(&b).await;
    let _ = f.result().await;
    let stable_receipt = f.targets.lock().unwrap()[0].0.clone();
    assert_eq!(f.targets.lock().unwrap()[1].0, stable_receipt);
    // Drop the HTTP server and instantiate another over the same on-disk registry.
    f.stop.take();
    f.server.wait_stopped().await;
    drop(f);
    let mut f = Fixture::new(root.clone()).await;
    let c = f.prepare(&bytes).await;
    let source = root.join("source.bin");
    std::fs::write(&source, &bytes).unwrap();
    let progress = Arc::new(Mutex::new(Vec::new()));
    let observed = progress.clone();
    let client = LsHttpClient::V2(LsHttpClientV2::try_new_without_cert().unwrap());
    client
        .upload_with_recovery(
            ProtocolType::Http,
            "127.0.0.1",
            f.server.port(),
            None,
            c["sessionId"].as_str().unwrap(),
            "f",
            c["files"]["f"].as_str().unwrap(),
            FileContent::Path(source),
            Some(key.clone()),
            move |n| observed.lock().unwrap().push(n),
            |_, _| {},
            CancellationToken::new(),
        )
        .await
        .unwrap();
    f.result().await.unwrap();
    assert_eq!(
        std::fs::read(root.join("received/output.bin")).unwrap(),
        bytes
    );
    assert_eq!(f.targets.lock().unwrap()[0].0, stable_receipt);
    assert!(progress.lock().unwrap().iter().all(|&n| n >= BLOCK as u64));
    // Lost final ACK/new task: reuse one publication receipt, never output (1).
    let d = f.prepare(&bytes).await;
    let receipt = f.open(&d, &bytes, &key).await;
    let complete = f.ready(&d, receipt).await;
    assert_eq!(complete["state"], "complete");
    assert_eq!(complete["offset"], bytes.len() as u64);
    f.result().await.unwrap();
    let records = f.targets.lock().unwrap();
    assert_eq!(records[1].0, stable_receipt);
    assert!(records[1].1.is_some());
    drop(records);
    let names = std::fs::read_dir(root.join("received"))
        .unwrap()
        .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
        .collect::<Vec<_>>();
    assert_eq!(names, vec!["output.bin"]);
    f.stop.take();
    f.server.wait_stopped().await;
    drop(f);
    changed_source_and_abort(&root).await;
    crash_recovery(&root).await;
    std::fs::remove_dir_all(root).unwrap();
}

fn crash_bytes() -> Vec<u8> {
    (0..BLOCK * 2 + 37).map(|i| (i % 239) as u8).collect()
}

// Launched explicitly in a separate process. The parent kills only this child
// after a confirmed block; no Rust Drop or graceful server cleanup can run.
#[tokio::test]
#[ignore = "subprocess helper invoked by the end-to-end test"]
async fn durable_crash_child() {
    let root = PathBuf::from(std::env::var_os("LEGNASEND_CRASH_FIXTURE").expect("owned test root"));
    localsend::receive_registry::configure(root.join("private-registry")).unwrap();
    let child_root = root.join("crash-case");
    let f = Fixture::new(child_root.clone()).await;
    let bytes = crash_bytes();
    let key = uuid::Uuid::new_v4().to_string();
    let session = f.prepare(&bytes).await;
    let receipt = f.open(&session, &bytes, &key).await;
    let ready = f.ready(&session, receipt).await;
    f.block(&session, &ready, 0, &bytes[..BLOCK]).await;
    let id = f.targets.lock().unwrap()[0].0.clone();
    std::fs::write(
        child_root.join("ready.json.pending"),
        json!({"key":key,"receipt":id}).to_string(),
    )
    .unwrap();
    std::fs::rename(
        child_root.join("ready.json.pending"),
        child_root.join("ready.json"),
    )
    .unwrap();
    loop {
        tokio::time::sleep(Duration::from_secs(60)).await;
    }
}

struct ChildGuard(std::process::Child);
impl Drop for ChildGuard {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}
async fn crash_recovery(root: &std::path::Path) {
    let child_root = root.join("crash-case");
    std::fs::create_dir(&child_root).unwrap();
    let log = std::fs::File::create(child_root.join("child.log")).unwrap();
    let mut child = ChildGuard(
        std::process::Command::new(std::env::current_exe().unwrap())
            .args(["--exact", "durable_crash_child", "--ignored", "--nocapture"])
            .env("LEGNASEND_CRASH_FIXTURE", root)
            .stdout(log.try_clone().unwrap())
            .stderr(log)
            .spawn()
            .unwrap(),
    );
    let ready = child_root.join("ready.json");
    for _ in 0..1000 {
        if ready.exists() {
            break;
        }
        assert!(
            child.0.try_wait().unwrap().is_none(),
            "child exited before checkpoint: {}",
            std::fs::read_to_string(child_root.join("child.log")).unwrap()
        );
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    assert!(ready.exists(), "child never confirmed a durable block");
    let record: Value = serde_json::from_slice(&std::fs::read(&ready).unwrap()).unwrap();
    child.0.kill().unwrap();
    assert!(!child.0.wait().unwrap().success());
    drop(child);
    let bytes = crash_bytes();
    let mut f = Fixture::new(child_root.clone()).await;
    let session = f.prepare(&bytes).await;
    let receipt = f
        .open(&session, &bytes, record["key"].as_str().unwrap())
        .await;
    let resumed = f.ready(&session, receipt).await;
    assert_eq!(resumed["offset"], BLOCK as u64);
    assert_eq!(
        f.targets.lock().unwrap()[0].0,
        record["receipt"].as_str().unwrap()
    );
    f.block(&session, &resumed, BLOCK, &bytes[BLOCK..BLOCK * 2])
        .await;
    f.block(&session, &resumed, BLOCK * 2, &bytes[BLOCK * 2..])
        .await;
    let finish = f
        .client
        .post(f.url("finish", &session, Some(&resumed)))
        .send()
        .await
        .unwrap();
    assert_eq!(finish.status(), 200);
    f.result().await.unwrap();
    assert_eq!(
        std::fs::read(child_root.join("received/output.bin")).unwrap(),
        bytes
    );
    f.stop.take();
    f.server.wait_stopped().await;
}

async fn changed_source_and_abort(root: &std::path::Path) {
    let root = root.join("changed-source");
    let mut f = Fixture::new(root.clone()).await;
    let old = vec![17u8; BLOCK * 2 + 19];
    let changed = vec![23u8; old.len()];
    let key = uuid::Uuid::new_v4().to_string();
    let a = f.prepare(&old).await;
    let r = f.open(&a, &old, &key).await;
    let r = f.ready(&a, r).await;
    f.block(&a, &r, 0, &old[..BLOCK]).await;
    f.suspend(&a, &r).await;
    f.cancel(&a).await;
    assert!(f.result().await.is_err());
    let before = std::fs::read_dir(root.join("received"))
        .unwrap()
        .map(|e| e.unwrap().file_name())
        .collect::<Vec<_>>();
    assert_eq!(
        before.len(),
        1,
        "exactly one owned .ls before source replacement"
    );
    let b = f.prepare(&changed).await;
    let r = f.open(&b, &changed, &key).await;
    let r = f.ready(&b, r).await;
    assert_eq!(
        r["offset"], 0,
        "a matching resumeKey cannot mix different source SHA"
    );
    assert!(
        !root.join("received").join(&before[0]).exists(),
        "old owned cache was not invalidated"
    );
    f.block(&b, &r, 0, &changed[..BLOCK]).await;
    let response = f
        .client
        .post(f.url("abort", &b, Some(&r)))
        .send()
        .await
        .unwrap();
    assert_eq!(response.status(), 200);
    assert!(f.result().await.is_err());
    assert_eq!(
        std::fs::read_dir(root.join("received")).unwrap().count(),
        0,
        "explicit abort must remove its own partial cache"
    );
    f.cancel(&b).await;
    f.stop.take();
    f.server.wait_stopped().await;
}
