#![cfg(feature = "http")]
//! Real HTTP and descriptor-backed .ls/staging writes; provider publication is controlled.
use localsend::http::{
    server::{
        ServerConfigV2, ServerHandle,
        directories::{DirectoryWriteResponse, DocumentResponse},
        start_with_port,
        v2::ServerEventV2,
        web::WebConfig,
    },
    state::ClientInfo,
};
use serde_json::{Value, json};
use std::{
    collections::HashMap,
    fs::OpenOptions,
    path::PathBuf,
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, Ordering},
    },
    time::Duration,
};
use tokio::sync::{Notify, mpsc, oneshot};
const WS: &str = "11111111-1111-4111-8111-111111111111";
const PARENT: &str = "22222222-2222-4222-8222-222222222222";
struct Fixture {
    server: ServerHandle,
    client: reqwest::Client,
    root: PathBuf,
    events: Arc<Mutex<Vec<Value>>>,
    accepted: Arc<AtomicBool>,
    fail: Arc<AtomicBool>,
    publishing: Arc<Notify>,
    release_publish: Arc<Notify>,
    hold: Arc<AtomicBool>,
    stop: Option<oneshot::Sender<()>>,
}
impl Fixture {
    async fn new(approval: bool) -> Self {
        Self::configured(approval, true).await
    }
    async fn configured(approval: bool, allow_upload: bool) -> Self {
        let root =
            std::env::temp_dir().join(format!("legna-document-upload-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir(&root).unwrap();
        let events = Arc::new(Mutex::new(Vec::new()));
        let seen = events.clone();
        let directory = root.clone();
        let accepted = Arc::new(AtomicBool::new(true));
        let accepted_copy = accepted.clone();
        let fail = Arc::new(AtomicBool::new(false));
        let fail_copy = fail.clone();
        let publishing = Arc::new(Notify::new());
        let entered = publishing.clone();
        let release_publish = Arc::new(Notify::new());
        let proceed = release_publish.clone();
        let hold = Arc::new(AtomicBool::new(false));
        let holding = hold.clone();
        let (tx, mut rx) = mpsc::channel(32);
        tokio::spawn(async move {
            let mut pending: HashMap<String, (String, PathBuf, PathBuf, String, bool)> =
                HashMap::new();
            while let Some(event) = rx.recv().await {
                match event {
                    ServerEventV2::DirectoryDocument { request, result_tx } => {
                        let q: Value = serde_json::from_str(&request).unwrap();
                        let _ = result_tx.send(Ok(DocumentResponse {
                            payload: json!({"version":1,"readable":true,"writable":true})
                                .to_string(),
                            file: None,
                        }));
                        seen.lock().unwrap().push(q);
                    }
                    ServerEventV2::DirectoryUploadApproval { decision_tx, .. } => {
                        let _ = decision_tx.send(accepted_copy.load(Ordering::SeqCst));
                    }
                    ServerEventV2::DirectoryDocumentWrite { request, result_tx } => {
                        let q: Value = serde_json::from_str(&request).unwrap();
                        seen.lock().unwrap().push(q.clone());
                        assert_eq!(q["workspaceId"], WS);
                        assert_eq!(q["generation"], 1);
                        assert_eq!(q["tree"], "content://fixture/tree/root");
                        assert!(uuid::Uuid::parse_str(q["owner"].as_str().unwrap()).is_ok());
                        let attempt = q["attemptId"].as_str().unwrap().to_owned();
                        let reply = match q["op"].as_str().unwrap() {
                            "begin" => {
                                if q["parent"] != PARENT && q["parent"] != "" {
                                    Err("not_found".into())
                                } else {
                                    let id = uuid::Uuid::new_v4().to_string();
                                    let cache = directory.join(format!("{id}.ls"));
                                    let stage = directory.join(format!("{id}.part"));
                                    let is_dir = q["directory"].as_bool().unwrap();
                                    let pair = if is_dir {
                                        (None, None)
                                    } else {
                                        let open = |path: &PathBuf| {
                                            OpenOptions::new()
                                                .read(true)
                                                .write(true)
                                                .create_new(true)
                                                .open(path)
                                                .unwrap()
                                        };
                                        (Some(open(&cache)), Some(open(&stage)))
                                    };
                                    pending.insert(
                                        attempt,
                                        (
                                            id.clone(),
                                            cache,
                                            stage,
                                            q["path"].as_str().unwrap().into(),
                                            is_dir,
                                        ),
                                    );
                                    Ok(DirectoryWriteResponse{payload:json!({"version":1,"transactionId":id,"lease":"fixture-lease"}).to_string(),cache:pair.0,staging:pair.1})
                                }
                            }
                            "publish" => {
                                let (id, cache, stage, name, is_dir) =
                                    pending.get(&attempt).unwrap();
                                assert_eq!(q["transactionId"], *id);
                                assert_eq!(q["coreAttemptId"], attempt);
                                // Both core descriptors must have closed before native publication.
                                if !is_dir {
                                    assert!(
                                        OpenOptions::new()
                                            .read(true)
                                            .write(true)
                                            .open(cache)
                                            .unwrap()
                                            .try_lock()
                                            .is_ok()
                                    );
                                    assert!(
                                        OpenOptions::new()
                                            .read(true)
                                            .write(true)
                                            .open(stage)
                                            .unwrap()
                                            .try_lock()
                                            .is_ok()
                                    );
                                }
                                entered.notify_one();
                                if holding.load(Ordering::SeqCst) {
                                    proceed.notified().await;
                                }
                                if fail_copy.load(Ordering::SeqCst) {
                                    Err("publication_unconfirmed".into())
                                } else {
                                    let target = directory.join("published").join(name);
                                    std::fs::create_dir_all(target.parent().unwrap()).unwrap();
                                    if *is_dir {
                                        std::fs::create_dir(&target).unwrap();
                                    } else {
                                        let bytes = std::fs::read(stage).unwrap();
                                        assert_eq!(bytes.len() as u64, q["size"].as_u64().unwrap());
                                        assert_eq!(
                                            localsend::crypto::hash::sha256_hex(&bytes),
                                            q["sha256"].as_str().unwrap()
                                        );
                                        std::fs::copy(stage, target).unwrap();
                                    }
                                    Ok(DirectoryWriteResponse {
                                        payload: json!({"version":1,"published":true}).to_string(),
                                        cache: None,
                                        staging: None,
                                    })
                                }
                            }
                            "release" => {
                                if let Some((_, cache, stage, _, is_dir)) = pending.remove(&attempt)
                                {
                                    if !is_dir {
                                        for file in [cache, stage] {
                                            let fd = OpenOptions::new()
                                                .read(true)
                                                .write(true)
                                                .open(&file)
                                                .unwrap();
                                            assert!(fd.try_lock().is_ok());
                                            drop(fd);
                                            std::fs::remove_file(file).unwrap();
                                        }
                                    }
                                }
                                Ok(DirectoryWriteResponse {
                                    payload: json!({"version":1,"released":true}).to_string(),
                                    cache: None,
                                    staging: None,
                                })
                            }
                            other => panic!("unexpected {other}"),
                        };
                        let _ = result_tx.send(reply);
                    }
                    _ => {}
                }
            }
        });
        let (stop, stop_rx) = oneshot::channel();
        let server = start_with_port(
            0,
            None,
            ClientInfo {
                alias: "document writes".into(),
                version: "2.2".into(),
                device_model: None,
                device_type: None,
                token: "fixture".into(),
            },
            None,
            Some(ServerConfigV2 {
                pin: None,
                verify_checksums: false,
                event_tx: tx,
            }),
            WebConfig::default(),
            stop_rx,
        )
        .await
        .unwrap();
        server.configure_directory_workspaces(&json!({"revision":1,"enabled":true,"workspaces":[{"id":WS,"name":"Documents","slug":"docs","root":"","documentTree":"content://fixture/tree/root","generation":1,"visible":true,"allowUpload":allow_upload,"uploadApproval":approval}]}).to_string()).await.unwrap();
        Self {
            server,
            client: reqwest::Client::builder()
                .no_proxy()
                .timeout(Duration::from_secs(8))
                .build()
                .unwrap(),
            root,
            events,
            accepted,
            fail,
            publishing,
            release_publish,
            hold,
            stop: Some(stop),
        }
    }
    fn url(&self, path: &str, parent: &str, directory: bool) -> String {
        let query = form_urlencoded::Serializer::new(String::new())
            .append_pair("generation", "1")
            .append_pair("path", path)
            .append_pair("parent", parent)
            .append_pair("directory", if directory { "true" } else { "false" })
            .finish();
        format!(
            "http://127.0.0.1:{}/api/legnasend/v1/workspaces/{WS}/upload?{query}",
            self.server.port()
        )
    }
    fn post(
        &self,
        path: &str,
        parent: &str,
        bytes: Vec<u8>,
        directory: bool,
    ) -> reqwest::RequestBuilder {
        self.client
            .post(self.url(path, parent, directory))
            .header("x-legnasend-upload", "1")
            .header("Content-Type", "application/octet-stream")
            .header("Content-Length", bytes.len())
            .body(bytes)
    }
    fn records(&self) -> Value {
        serde_json::from_str(&self.server.web_download_activity()).unwrap()
    }
    async fn approval(&self, parent: &str) -> reqwest::Response {
        self.client.post(format!("http://127.0.0.1:{}/api/legnasend/v1/workspaces/{WS}/prepare-upload",self.server.port())).header("x-legnasend-upload","1").json(&json!({"requestId":uuid::Uuid::new_v4(),"generation":1,"parent":parent,"files":[{"path":"approved.txt","size":4,"directory":false}]})).send().await.unwrap()
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        if let Some(stop) = self.stop.take() {
            let _ = stop.send(());
        }
        let _ = std::fs::remove_dir_all(&self.root);
    }
}
#[tokio::test]
async fn document_upload_writes_real_cache_publication_and_recovers_after_failure() {
    let f = Fixture::new(false).await;
    let bytes = vec![0x61; 1024 * 1024 + 17];
    let result = f
        .post("子目录/内容.txt", PARENT, bytes.clone(), false)
        .send()
        .await
        .unwrap();
    assert_eq!(result.status(), 201);
    let receipt: Value = result.json().await.unwrap();
    assert_eq!(receipt["parent"], PARENT);
    assert_eq!(
        std::fs::read(f.root.join("published/子目录/内容.txt")).unwrap(),
        bytes
    );
    assert_eq!(f.records()[0]["phase"], "succeeded");
    assert_eq!(f.records()[0]["transferred"], bytes.len());
    assert_eq!(
        f.post("空目录", PARENT, vec![], true)
            .send()
            .await
            .unwrap()
            .status(),
        201
    );
    assert!(f.root.join("published/空目录").is_dir());
    f.fail.store(true, Ordering::SeqCst);
    assert_eq!(
        f.post("failed.txt", PARENT, b"failed".to_vec(), false)
            .send()
            .await
            .unwrap()
            .status(),
        502
    );
    assert_eq!(f.records()[2]["phase"], "unconfirmed");
    assert!(!f.root.join("published/failed.txt").exists());
    f.fail.store(false, Ordering::SeqCst);
    assert_eq!(
        f.post("next.txt", PARENT, b"next".to_vec(), false)
            .send()
            .await
            .unwrap()
            .status(),
        201
    );
    assert!(std::fs::read_dir(&f.root).unwrap().all(|p| !matches!(
        p.unwrap().path().extension().and_then(|s| s.to_str()),
        Some("ls" | "part")
    )));
}
#[tokio::test]
async fn document_approval_parent_is_bound_and_denial_creates_no_transaction() {
    let f = Fixture::new(true).await;
    f.accepted.store(false, Ordering::SeqCst);
    assert_eq!(f.approval(PARENT).await.status(), 403);
    assert_eq!(f.records(), json!([]));
    assert!(!f.events.lock().unwrap().iter().any(|v| v["op"] == "begin"));
    f.accepted.store(true, Ordering::SeqCst);
    let receipt: Value = f.approval(PARENT).await.json().await.unwrap();
    let token = receipt["token"].as_str().unwrap();
    assert_eq!(
        f.post("approved.txt", "", b"data".to_vec(), false)
            .header("x-legnasend-upload-token", token)
            .send()
            .await
            .unwrap()
            .status(),
        428
    );
    assert_eq!(
        f.post("approved.txt", PARENT, b"data".to_vec(), false)
            .header("x-legnasend-upload-token", token)
            .send()
            .await
            .unwrap()
            .status(),
        201
    );
}
#[tokio::test]
async fn provider_commit_is_nonblocking_to_cancel_and_actual_publication_wins() {
    let f = Fixture::new(false).await;
    f.hold.store(true, Ordering::SeqCst);
    let request = f.post("commit.txt", PARENT, b"data".to_vec(), false);
    let response = tokio::spawn(async move { request.send().await.unwrap() });
    f.publishing.notified().await;
    let activity = f.records();
    let id = activity[0]["id"].as_str().unwrap();
    assert!(!f.server.cancel_web_download(id));
    assert_eq!(f.records()[0]["phase"], "transferring");
    f.release_publish.notify_one();
    assert_eq!(response.await.unwrap().status(), 201);
    assert_eq!(f.records()[0]["phase"], "succeeded");
    assert_eq!(
        std::fs::read(f.root.join("published/commit.txt")).unwrap(),
        b"data"
    );
}

#[tokio::test]
async fn disconnected_and_explicitly_cancelled_document_bodies_release_owned_files_only() {
    use tokio::io::AsyncWriteExt;
    let f = Fixture::new(false).await;
    for (name, explicit) in [("disconnect.txt", false), ("cancel.txt", true)] {
        let mut socket = tokio::net::TcpStream::connect(("127.0.0.1", f.server.port()))
            .await
            .unwrap();
        let url: reqwest::Url = f.url(name, PARENT, false).parse().unwrap();
        socket.write_all(format!("POST {}?{} HTTP/1.1\r\nHost: 127.0.0.1:{}\r\nX-LegnaSend-Upload: 1\r\nContent-Type: application/octet-stream\r\nContent-Length: 2097152\r\n\r\n", url.path(), url.query().unwrap(), f.server.port()).as_bytes()).await.unwrap();
        socket.write_all(&vec![42; 1048593]).await.unwrap();
        let id =
            tokio::time::timeout(Duration::from_secs(5), async {
                loop {
                    if let Some(record) =
                        f.records().as_array().unwrap().iter().find(|r| {
                            r["name"] == name && r["transferred"].as_u64().unwrap_or(0) > 0
                        })
                    {
                        break record["id"].as_str().unwrap().to_owned();
                    }
                    tokio::time::sleep(Duration::from_millis(5)).await;
                }
            })
            .await
            .unwrap();
        if explicit {
            assert!(f.server.cancel_web_download(&id));
        }
        drop(socket);
        tokio::time::timeout(Duration::from_secs(5), async {
            loop {
                let released = f
                    .events
                    .lock()
                    .unwrap()
                    .iter()
                    .filter(|v| v["op"] == "release")
                    .count();
                if released >= if explicit { 2 } else { 1 } {
                    break;
                }
                tokio::time::sleep(Duration::from_millis(5)).await;
            }
        })
        .await
        .unwrap();
        assert!(!f.root.join("published").join(name).exists());
    }
    assert_eq!(
        f.post("after.txt", PARENT, b"intact".to_vec(), false)
            .send()
            .await
            .unwrap()
            .status(),
        201
    );
    assert_eq!(
        std::fs::read(f.root.join("published/after.txt")).unwrap(),
        b"intact"
    );
}

#[tokio::test]
async fn keyed_document_upload_keeps_explicit_scope_policy_when_browser_upload_is_disabled() {
    use localsend::http::server::integration::{ApiConfig, Scope, WorkspaceGrant, create_key};
    let f = Fixture::configured(false, false).await;
    let key = create_key(
        "document writer".into(),
        WorkspaceGrant {
            scopes: vec![Scope::Upload],
            workspaces: vec![WS.into()],
        },
        None,
    )
    .unwrap();
    let reader = create_key(
        "reader".into(),
        WorkspaceGrant {
            scopes: vec![Scope::Files],
            workspaces: vec![WS.into()],
        },
        None,
    )
    .unwrap();
    let config = ApiConfig {
        revision: 1,
        enabled: true,
        keys: vec![key.record, reader.record],
        ..ApiConfig::default()
    };
    f.server
        .configure_integration_api(&serde_json::to_string(&config).unwrap())
        .await
        .unwrap();
    assert_eq!(
        f.post("keyed.txt", PARENT, b"bytes".to_vec(), false)
            .send()
            .await
            .unwrap()
            .status(),
        403
    );
    let url = f
        .url("keyed.txt", PARENT, false)
        .replace("/v1/workspaces/", "/v1/integration/workspaces/");
    let post = |token: &str| {
        f.client
            .post(&url)
            .bearer_auth(token)
            .header("Content-Type", "application/octet-stream")
            .body("bytes")
    };
    assert_eq!(post(&reader.secret).send().await.unwrap().status(), 403);
    assert_eq!(f.records(), json!([]));
    let response = post(&key.secret).send().await.unwrap();
    assert_eq!(response.status(), 201);
    let receipt: Value = response.json().await.unwrap();
    assert_eq!(receipt["parent"], PARENT);
    assert_eq!(receipt["path"], "keyed.txt");
    assert_eq!(receipt["size"], 5);
    assert_eq!(
        std::fs::read(f.root.join("published/keyed.txt")).unwrap(),
        b"bytes"
    );
    assert_eq!(f.records()[0]["origin"], "api");
    assert_eq!(f.records()[0]["peer"], "");
}
