#![cfg(feature = "full")]
#![allow(dead_code)]
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
async fn persisted_grant_barrier_cleanup_replay_and_published_preservation_are_real() {
    use localsend::http::{
        client::ClientError,
        source_end::{SourceEndEvent, SourceEndOutcome},
    };
    let root = std::env::temp_dir().join(format!(
        "legnasend-source-end-chain-{}",
        uuid::Uuid::new_v4()
    ));
    std::fs::create_dir(&root).unwrap();
    localsend::receive_registry::configure(root.join("private-registry")).unwrap();
    let mut fixture = Fixture::new(root.clone()).await;
    let bytes: Vec<_> = (0..BLOCK + 73).map(|n| (n % 251) as u8).collect();
    let path = root.join("source.bin");
    std::fs::write(&path, &bytes).unwrap();
    let client = LsHttpClient::V2(LsHttpClientV2::try_new_without_cert().unwrap());
    let session = fixture.prepare(&bytes).await;
    let key = uuid::Uuid::new_v4().to_string();
    let captured = Arc::new(Mutex::new(None));
    let copy = captured.clone();
    let result = client
        .upload_with_source_end(
            ProtocolType::Http,
            "127.0.0.1",
            fixture.server.port(),
            None,
            session["sessionId"].as_str().unwrap(),
            "f",
            session["files"]["f"].as_str().unwrap(),
            FileContent::Path(path.clone()),
            Some(key.clone()),
            |_| {},
            |_, _| {},
            |_| {},
            Some(Arc::new(move |event| match event {
                SourceEndEvent::Grant { grant, persisted } => {
                    *copy.lock().unwrap() = Some(grant);
                    let _ = persisted.send(false);
                }
                SourceEndEvent::Unavailable => panic!("actual receiver advertises capability"),
            })),
            CancellationToken::new(),
        )
        .await;
    assert!(matches!(
        result,
        Err(ClientError::ResumeInterrupted {
            retained_confirmed: true
        })
    ));
    assert!(fixture.result().await.is_err());
    let same=fixture.client.post(fixture.url("open",&session,None)).json(&json!({"size":bytes.len(),"sha256":sha(&bytes),"recovery":{"version":1,"resumeKey":key,"sourceEnd":1}})).send().await.unwrap();
    assert_eq!(same.status(), 200);
    let same: Value = same.json().await.unwrap();
    assert_eq!(same["state"], "suspended");
    assert_eq!(same["offset"], 0, "ack false must send no first block");
    assert!(!root.join("received/output.bin").exists());
    fixture.cancel(&session).await;
    fixture.stop.take();
    fixture.server.wait_stopped().await;
    drop(fixture);
    let mut fixture = Fixture::new(root.clone()).await;
    let grant = captured.lock().unwrap().clone().unwrap();
    let cleared = client
        .end_source(
            ProtocolType::Http,
            "127.0.0.1",
            fixture.server.port(),
            None,
            grant.clone(),
            uuid::Uuid::new_v4().to_string(),
            CancellationToken::new(),
        )
        .await
        .unwrap();
    assert_eq!(cleared.outcome, SourceEndOutcome::Cleared);
    assert_eq!(cleared.removed_files, 1);
    assert!(cleared.unlinked_bytes > 0);
    let repeated = client
        .end_source(
            ProtocolType::Http,
            "127.0.0.1",
            fixture.server.port(),
            None,
            grant,
            uuid::Uuid::new_v4().to_string(),
            CancellationToken::new(),
        )
        .await
        .unwrap();
    assert_eq!(cleared.receipt_id, repeated.receipt_id);
    assert_eq!(cleared.unlinked_bytes, repeated.unlinked_bytes);
    assert_eq!(std::fs::read_dir(root.join("received")).unwrap().count(), 0);
    let session = fixture.prepare(&bytes).await;
    let captured = Arc::new(Mutex::new(None));
    let copy = captured.clone();
    client
        .upload_with_source_end(
            ProtocolType::Http,
            "127.0.0.1",
            fixture.server.port(),
            None,
            session["sessionId"].as_str().unwrap(),
            "f",
            session["files"]["f"].as_str().unwrap(),
            FileContent::Path(path),
            Some(uuid::Uuid::new_v4().to_string()),
            |_| {},
            |_, _| {},
            |_| {},
            Some(Arc::new(move |event| match event {
                SourceEndEvent::Grant { grant, persisted } => {
                    *copy.lock().unwrap() = Some(grant);
                    let _ = persisted.send(true);
                }
                SourceEndEvent::Unavailable => panic!("actual receiver advertises capability"),
            })),
            CancellationToken::new(),
        )
        .await
        .unwrap();
    fixture.result().await.unwrap();
    assert_eq!(
        std::fs::read(root.join("received/output.bin")).unwrap(),
        bytes
    );
    let grant = captured.lock().unwrap().clone().unwrap();
    let preserved = client
        .end_source(
            ProtocolType::Http,
            "127.0.0.1",
            fixture.server.port(),
            None,
            grant,
            uuid::Uuid::new_v4().to_string(),
            CancellationToken::new(),
        )
        .await
        .unwrap();
    assert_eq!(preserved.outcome, SourceEndOutcome::PublishedPreserved);
    assert_eq!(
        std::fs::read(root.join("received/output.bin")).unwrap(),
        bytes
    );
    fixture.stop.take();
    fixture.server.wait_stopped().await;
    drop(fixture);
    std::fs::remove_dir_all(root).unwrap();
}
