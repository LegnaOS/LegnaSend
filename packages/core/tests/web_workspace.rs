#![cfg(feature = "http")]
use localsend::http::server::common::save::FileUploadTarget;
use localsend::http::server::v2::{PrepareUploadDecisionV2, ServerEventV2};
use localsend::http::server::web::{WebConfig, WebDownloadConfig, WebDownloadEvent, WebMode};
use localsend::http::server::{ServerConfigV2, ServerHandle, start_with_port};
use localsend::http::state::ClientInfo;
use localsend::model::transfer::{FileContent, FileDto};
use serde_json::{Value, json};
use std::collections::{HashMap, HashSet};
use std::sync::Arc;
use tokio::sync::{Mutex, mpsc, oneshot};

fn file(id: &str) -> FileDto {
    FileDto {
        id: id.into(),
        file_name: format!("{id}.txt"),
        size: 3,
        file_type: "text/plain".into(),
        sha256: None,
        preview: None,
        metadata: None,
    }
}
fn payload(web: bool) -> Value {
    json!({"info":{"alias":"Fixture","version":"2.1","deviceType":if web {"web"} else {"desktop"},"fingerprint":"fixture","port":53317,"protocol":"http","download":false},
        "files":{"in":{"id":"in","fileName":"in.txt","size":3,"fileType":"text/plain"}}})
}
struct Fixture {
    server: ServerHandle,
    client: reqwest::Client,
    root: String,
    stop: oneshot::Sender<()>,
    decisions: mpsc::Receiver<oneshot::Sender<PrepareUploadDecisionV2>>,
    received: Arc<Mutex<Vec<u8>>>,
}
impl Fixture {
    async fn start() -> Self {
        let (tx, mut rx) = mpsc::channel(16);
        let (web_tx, mut web_rx) = mpsc::channel(16);
        let (decision_tx, decisions) = mpsc::channel(16);
        let received = Arc::new(Mutex::new(vec![]));
        let incoming = received.clone();
        tokio::spawn(async move {
            while let Some(event) = rx.recv().await {
                match event {
                    ServerEventV2::PrepareUpload {
                        decision_tx: decision,
                        ..
                    } => {
                        let _ = decision_tx.send(decision).await;
                    }
                    ServerEventV2::FileUpload { target_tx, .. } => {
                        let (binary_tx, mut binary_rx) = mpsc::channel::<bytes::Bytes>(16);
                        let (result_tx, result_rx) = oneshot::channel();
                        let _ = target_tx.send(FileUploadTarget::Stream {
                            binary_tx,
                            result_rx,
                        });
                        let incoming = incoming.clone();
                        tokio::spawn(async move {
                            while let Some(bytes) = binary_rx.recv().await {
                                incoming.lock().await.extend_from_slice(&bytes);
                            }
                            let _ = result_tx.send(Ok(()));
                        });
                    }
                    _ => {}
                }
            }
        });
        tokio::spawn(async move {
            while let Some(event) = web_rx.recv().await {
                match event {
                    WebDownloadEvent::PrepareDownloadAborted { .. } => {}
                    WebDownloadEvent::PrepareDownload { decision_tx, .. } => {
                        let _ = decision_tx.send(true);
                    }
                    WebDownloadEvent::FileDownload { content_tx, .. } => {
                        let (tx, rx) = mpsc::channel(1);
                        let _ = tx.send(bytes::Bytes::from_static(b"out")).await;
                        let _ = content_tx.send(FileContent::Stream(rx));
                    }
                }
            }
        });
        let (stop, stop_rx) = oneshot::channel();
        let server = start_with_port(
            0,
            None,
            ClientInfo {
                alias: "Fixture".into(),
                version: "2.1".into(),
                device_model: None,
                device_type: None,
                token: "fixture".into(),
            },
            None,
            Some(ServerConfigV2 {
                pin: Some("native-pin".into()),
                verify_checksums: true,
                event_tx: tx,
            }),
            WebConfig {
                mode: WebMode::Duplex {
                    download: WebDownloadConfig {
                        files: HashMap::new(),
                        pin: Some("web-pin".into()),
                        event_tx: web_tx,
                    },
                    allow_upload: false,
                },
                ..Default::default()
            },
            stop_rx,
        )
        .await
        .unwrap();
        let root = format!("http://127.0.0.1:{}", server.port());
        Self {
            server,
            root,
            client: reqwest::Client::builder().no_proxy().build().unwrap(),
            stop,
            decisions,
            received,
        }
    }
    fn prepare(&self, web: bool) -> reqwest::RequestBuilder {
        self.client
            .post(format!(
                "{}/api/localsend/v2/prepare-upload?{}",
                self.root,
                if web {
                    "web=1&pin=web-pin"
                } else {
                    "pin=native-pin"
                }
            ))
            .json(&payload(web))
    }
    async fn accept(&mut self) {
        self.decisions
            .recv()
            .await
            .unwrap()
            .send(PrepareUploadDecisionV2::Accept(HashSet::from(
                ["in".into()],
            )))
            .unwrap();
    }
    async fn end(self) {
        self.stop.send(()).unwrap();
        self.server.wait_stopped().await;
    }
}

#[tokio::test]
async fn duplex_append_preserves_sessions_and_native_upload_contract() {
    let mut f = Fixture::start().await;
    let page = f
        .client
        .get(&f.root)
        .send()
        .await
        .unwrap()
        .text()
        .await
        .unwrap();
    assert!(page.contains("workspace-tabs"));
    for path in [
        "/upload",
        "/download",
        "/assets/workspace.js",
        "/assets/sha256.js",
        "/assets/ls-cache.js",
        "/assets/download-registry.js",
        "/assets/persistent-downloads.js",
        "/assets/persistent-download-ui.js",
        "/assets/persistent-downloads.css",
        "/assets/image-preview.js",
        "/assets/image-preview.css",
        "/assets/diagram-preview.js",
        "/assets/diagram-frame.html",
        "/assets/diagram-config.js",
        "/assets/markdown-stream.js",
        "/assets/markdown-stream-worker.js",
        "/assets/markdown-blocks.js",
        "/assets/markdown-table-header.js",
    ] {
        assert_eq!(
            f.client
                .get(format!("{}{path}", f.root))
                .send()
                .await
                .unwrap()
                .status(),
            200
        );
    }
    let frame = f
        .client
        .get(format!("{}/assets/diagram-frame.html", f.root))
        .send()
        .await
        .unwrap();
    let policy = frame.headers()["content-security-policy"].to_str().unwrap();
    assert!(policy.contains("sandbox allow-scripts"));
    assert!(policy.contains("connect-src 'none'"));
    assert!(!policy.contains("allow-same-origin"));
    let manifest: Value =
        serde_json::from_str(include_str!("../assets/web/vendor/diagrams/manifest.json")).unwrap();
    for asset in manifest["assets"].as_array().unwrap() {
        let name = asset["file"].as_str().unwrap();
        let response = f
            .client
            .get(format!("{}/assets/vendor/diagrams/{name}", f.root))
            .send()
            .await
            .unwrap();
        assert_eq!(response.status(), 200);
        assert_eq!(response.headers()["x-content-type-options"], "nosniff");
        if name.ends_with(".js") {
            assert!(
                response.headers()["cache-control"]
                    .to_str()
                    .unwrap()
                    .contains("immutable")
            );
        }
        assert_eq!(
            response.bytes().await.unwrap().len() as u64,
            asset["bytes"].as_u64().unwrap()
        );
    }
    assert_eq!(
        f.client
            .get(format!("{}/assets/vendor/diagrams/not-a-bundle.js", f.root))
            .send()
            .await
            .unwrap()
            .status(),
        404
    );
    assert_eq!(f.prepare(true).send().await.unwrap().status(), 403);
    f.server
        .update_web_workspace(HashMap::from([("out".into(), file("out"))]), true)
        .await
        .unwrap();
    let list: Value = f
        .client
        .post(format!(
            "{}/api/localsend/v2/prepare-download?pin=web-pin",
            f.root
        ))
        .send()
        .await
        .unwrap()
        .json()
        .await
        .unwrap();
    let session = list["sessionId"].as_str().unwrap();
    assert!(list["files"]["out"].is_object());
    f.server
        .update_web_workspace(HashMap::from([("more".into(), file("more"))]), false)
        .await
        .unwrap();
    let refreshed: Value = f
        .client
        .post(format!(
            "{}/api/localsend/v2/prepare-download?sessionId={session}",
            f.root
        ))
        .send()
        .await
        .unwrap()
        .json()
        .await
        .unwrap();
    assert_eq!(refreshed["files"].as_object().unwrap().len(), 2);
    assert_eq!(refreshed["sessionId"], session);
    assert!(
        f.server
            .update_web_workspace(HashMap::from([("out".into(), file("out"))]), true)
            .await
            .is_err()
    );
    assert_eq!(f.prepare(true).send().await.unwrap().status(), 403); // rejected duplicate update is atomic
    let request = f.prepare(false);
    let response = tokio::spawn(async move { request.send().await.unwrap() });
    f.accept().await;
    let upload: Value = response.await.unwrap().json().await.unwrap();
    let upload_url = format!(
        "{}/api/localsend/v2/upload?sessionId={}&fileId=in&token={}",
        f.root,
        upload["sessionId"].as_str().unwrap(),
        upload["files"]["in"].as_str().unwrap()
    );
    let download_url = format!(
        "{}/api/localsend/v2/download?sessionId={session}&fileId=out",
        f.root
    );
    let (sent, got) = tokio::join!(
        f.client.post(upload_url).body("abc").send(),
        f.client.get(download_url).send()
    );
    assert_eq!(sent.unwrap().status(), 200);
    assert_eq!(got.unwrap().bytes().await.unwrap(), "out");
    assert_eq!(*f.received.lock().await, b"abc");
    f.end().await;
}

#[tokio::test]
async fn browser_permission_pin_and_late_decision_are_enforced_without_canceling_approved_upload() {
    let mut f = Fixture::start().await;
    f.server
        .update_web_workspace(HashMap::new(), true)
        .await
        .unwrap();
    assert_eq!(
        f.client
            .post(format!(
                "{}/api/localsend/v2/prepare-upload?web=1&pin=native-pin",
                f.root
            ))
            .json(&payload(true))
            .send()
            .await
            .unwrap()
            .status(),
        401
    );
    let request = f.prepare(true);
    let response = tokio::spawn(async move { request.send().await.unwrap() });
    let decision = f.decisions.recv().await.unwrap();
    f.server
        .update_web_workspace(HashMap::new(), false)
        .await
        .unwrap();
    f.server
        .update_web_workspace(HashMap::new(), true)
        .await
        .unwrap();
    decision
        .send(PrepareUploadDecisionV2::Accept(HashSet::from(
            ["in".into()],
        )))
        .unwrap();
    assert_eq!(response.await.unwrap().status(), 403);
    // Drop guard asynchronously frees the pending slot before retry.
    let response = tokio::time::timeout(std::time::Duration::from_secs(3), async { loop {
        let request = f.prepare(true);
        let mut response = tokio::spawn(async move { request.send().await.unwrap() });
        tokio::select! {
            decision=f.decisions.recv()=>{decision.unwrap().send(PrepareUploadDecisionV2::Accept(HashSet::from(["in".into()]))).unwrap();break response.await.unwrap();}
            result=&mut response=>{assert_eq!(result.unwrap().status(),409);tokio::task::yield_now().await;}
        }
    }}).await.expect("pending browser slot must be released");
    let upload: Value = response.json().await.unwrap();
    f.server
        .update_web_workspace(HashMap::new(), false)
        .await
        .unwrap();
    let url = format!(
        "{}/api/localsend/v2/upload?sessionId={}&fileId=in&token={}",
        f.root,
        upload["sessionId"].as_str().unwrap(),
        upload["files"]["in"].as_str().unwrap()
    );
    assert_eq!(
        f.client
            .post(url)
            .body("abc")
            .send()
            .await
            .unwrap()
            .status(),
        200
    );
    assert_eq!(f.prepare(true).send().await.unwrap().status(), 403);
    let status: Value = f
        .client
        .get(format!("{}/web-status.json", f.root))
        .send()
        .await
        .unwrap()
        .json()
        .await
        .unwrap();
    assert_eq!(status["allowUpload"], false);
    assert_eq!(status["fileCount"], 0);
    assert!(status["fileVersion"].as_str().is_some());
    f.end().await;
}

#[tokio::test]
async fn closing_temporary_share_preserves_an_approved_original_native_upload() {
    let mut f = Fixture::start().await;
    let port = f.server.port();
    let request = f.prepare(false);
    let response = tokio::spawn(async move { request.send().await.unwrap() });
    f.accept().await;
    let upload: Value = response.await.unwrap().json().await.unwrap();
    f.server.set_web_mode(WebMode::Disabled);
    let url = format!(
        "{}/api/localsend/v2/upload?sessionId={}&fileId=in&token={}",
        f.root,
        upload["sessionId"].as_str().unwrap(),
        upload["files"]["in"].as_str().unwrap()
    );
    assert_eq!(
        f.client
            .post(url)
            .body("abc")
            .send()
            .await
            .unwrap()
            .status(),
        200
    );
    assert_eq!(*f.received.lock().await, b"abc");
    assert_eq!(f.prepare(true).send().await.unwrap().status(), 403);
    assert_eq!(f.server.port(), port);
    f.end().await;
}

#[tokio::test]
async fn closing_temporary_share_cancels_its_pending_decision_only() {
    let f = Fixture::start().await;
    let (events, mut rx) = mpsc::channel(16);
    f.server.set_web_mode(WebMode::Duplex {
        download: WebDownloadConfig {
            files: HashMap::new(),
            pin: None,
            event_tx: events,
        },
        allow_upload: true,
    });
    let request = f
        .client
        .post(format!("{}/api/localsend/v2/prepare-download", f.root));
    let response = tokio::spawn(async move { request.send().await.unwrap() });
    let old_decision = rx.recv().await.unwrap();
    f.server.set_web_mode(WebMode::Disabled);
    assert_eq!(
        tokio::time::timeout(std::time::Duration::from_secs(2), response)
            .await
            .unwrap()
            .unwrap()
            .status(),
        410
    );
    drop(old_decision);
    assert_eq!(
        f.client
            .get(format!("{}/api/localsend/v2/info", f.root))
            .send()
            .await
            .unwrap()
            .status(),
        200
    );
    f.end().await;
}

#[tokio::test]
async fn closing_temporary_share_interrupts_an_inflight_stream_without_stopping_native_info() {
    let f = Fixture::start().await;
    let (events, mut rx) = mpsc::channel(16);
    let mut shared = file("slow");
    shared.size = 1024;
    f.server.set_web_mode(WebMode::Duplex {
        download: WebDownloadConfig {
            files: HashMap::from([("slow".into(), shared)]),
            pin: None,
            event_tx: events,
        },
        allow_upload: false,
    });
    let worker = tokio::spawn(async move {
        while let Some(event) = rx.recv().await {
            match event {
                WebDownloadEvent::PrepareDownloadAborted { .. } => {}
                WebDownloadEvent::PrepareDownload { decision_tx, .. } => {
                    let _ = decision_tx.send(true);
                }
                WebDownloadEvent::FileDownload { content_tx, .. } => {
                    let (tx, body) = mpsc::channel(1);
                    tx.send(bytes::Bytes::from_static(b"out")).await.unwrap();
                    let _ = content_tx.send(FileContent::Stream(body));
                    tx.closed().await;
                    break;
                }
            }
        }
    });
    let prepared: Value = f
        .client
        .post(format!("{}/api/localsend/v2/prepare-download", f.root))
        .send()
        .await
        .unwrap()
        .json()
        .await
        .unwrap();
    let url = format!(
        "{}/api/localsend/v2/download?sessionId={}&fileId=slow",
        f.root,
        prepared["sessionId"].as_str().unwrap()
    );
    let mut response = f.client.get(url).send().await.unwrap();
    assert_eq!(response.chunk().await.unwrap().unwrap(), "out");
    f.server.set_web_mode(WebMode::Disabled);
    assert!(
        tokio::time::timeout(std::time::Duration::from_secs(2), response.chunk())
            .await
            .unwrap()
            .is_err()
    );
    tokio::time::timeout(std::time::Duration::from_secs(2), worker)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(
        f.client
            .get(format!("{}/api/localsend/v2/info", f.root))
            .send()
            .await
            .unwrap()
            .status(),
        200
    );
    f.end().await;
}

#[tokio::test]
async fn file_deltas_are_atomic_versioned_and_keep_original_sessions_and_uploads() {
    let mut f = Fixture::start().await;
    f.server
        .update_web_workspace(
            HashMap::from([("old".into(), file("old")), ("keep".into(), file("keep"))]),
            true,
        )
        .await
        .unwrap();
    let port = f.server.port();
    let list = f
        .client
        .post(format!(
            "{}/api/localsend/v2/prepare-download?pin=web-pin",
            f.root
        ))
        .send()
        .await
        .unwrap();
    let version = list.headers()["x-legnasend-file-version"]
        .to_str()
        .unwrap()
        .to_owned();
    let list: Value = list.json().await.unwrap();
    assert_eq!(
        list.as_object()
            .unwrap()
            .keys()
            .map(String::as_str)
            .collect::<HashSet<_>>(),
        HashSet::from(["info", "sessionId", "files"])
    );
    let session = list["sessionId"].as_str().unwrap();
    let native = f.prepare(false);
    let native = tokio::spawn(async move { native.send().await.unwrap() });
    f.accept().await;
    let native: Value = native.await.unwrap().json().await.unwrap();
    // An invalid removal must neither publish the new ID nor revoke any valid selection.
    assert!(
        f.server
            .patch_web_workspace(
                HashMap::from([("new".into(), file("new"))]),
                vec!["old".into(), "missing".into()]
            )
            .await
            .is_err()
    );
    assert!(
        f.server
            .patch_web_workspace(HashMap::new(), vec!["old".into(), "old".into()])
            .await
            .is_err()
    );
    assert!(
        f.server
            .patch_web_workspace(
                HashMap::from([("old".into(), file("old"))]),
                vec!["old".into()]
            )
            .await
            .is_err()
    );
    let unchanged: Value = f
        .client
        .get(format!("{}/web-status.json", f.root))
        .send()
        .await
        .unwrap()
        .json()
        .await
        .unwrap();
    assert_eq!(unchanged["fileVersion"], version);
    assert_eq!(unchanged["fileCount"], 2);
    // Replace without changing count, accepted session, listener or browser upload permission.
    f.server
        .patch_web_workspace(
            HashMap::from([("new".into(), file("new"))]),
            vec!["old".into()],
        )
        .await
        .unwrap();
    let updated = f
        .client
        .post(format!(
            "{}/api/localsend/v2/prepare-download?sessionId={session}",
            f.root
        ))
        .send()
        .await
        .unwrap();
    let next_version = updated.headers()["x-legnasend-file-version"]
        .to_str()
        .unwrap()
        .to_owned();
    assert_ne!(version, next_version);
    let updated: Value = updated.json().await.unwrap();
    assert_eq!(updated["sessionId"], session);
    assert_eq!(
        updated["files"]
            .as_object()
            .unwrap()
            .keys()
            .map(String::as_str)
            .collect::<HashSet<_>>(),
        HashSet::from(["keep", "new"])
    );
    let status: Value = f
        .client
        .get(format!("{}/web-status.json", f.root))
        .send()
        .await
        .unwrap()
        .json()
        .await
        .unwrap();
    assert_eq!(
        status,
        json!({"fileVersion":next_version,"fileCount":2,"allowUpload":true})
    );
    for (id, code) in [("old", 410), ("invented", 403), ("new", 200), ("keep", 200)] {
        let response = f
            .client
            .get(format!(
                "{}/api/localsend/v2/download?sessionId={session}&fileId={id}",
                f.root
            ))
            .send()
            .await
            .unwrap();
        assert_eq!(response.status(), code, "{id}");
        if code == 200 {
            assert_eq!(response.bytes().await.unwrap().as_ref(), b"out");
        }
    }
    // Withdrawn identities may not be recycled by the pre-existing append control either.
    assert!(
        f.server
            .update_web_workspace(HashMap::from([("old".into(), file("old"))]), false)
            .await
            .is_err()
    );
    let native_url = format!(
        "{}/api/localsend/v2/upload?sessionId={}&fileId=in&token={}",
        f.root,
        native["sessionId"].as_str().unwrap(),
        native["files"]["in"].as_str().unwrap()
    );
    assert_eq!(
        f.client
            .post(native_url)
            .body("abc")
            .send()
            .await
            .unwrap()
            .status(),
        200
    );
    assert_eq!(f.received.lock().await.as_slice(), b"abc");
    f.server
        .patch_web_workspace(HashMap::new(), vec!["new".into(), "keep".into()])
        .await
        .unwrap();
    let empty: Value = f
        .client
        .post(format!(
            "{}/api/localsend/v2/prepare-download?sessionId={session}",
            f.root
        ))
        .send()
        .await
        .unwrap()
        .json()
        .await
        .unwrap();
    assert_eq!(empty["sessionId"], session);
    assert_eq!(empty["files"], json!({}));
    assert_eq!(f.server.port(), port);
    assert_eq!(
        f.client
            .get(format!("{}/api/localsend/v2/info", f.root))
            .send()
            .await
            .unwrap()
            .status(),
        200
    );
    f.end().await;
}

#[tokio::test]
async fn withdrawing_a_file_releases_pending_content_and_stalled_body_only_for_that_id() {
    use std::time::Duration;
    let (events, mut incoming) = mpsc::channel(16);
    let (stop, stopping) = oneshot::channel();
    let server = start_with_port(
        0,
        None,
        ClientInfo {
            alias: "Cancellation".into(),
            version: "2.2".into(),
            device_model: None,
            device_type: None,
            token: "test".into(),
        },
        None,
        None,
        WebConfig {
            mode: WebMode::Duplex {
                download: WebDownloadConfig {
                    files: ["pending", "slow", "keep"]
                        .into_iter()
                        .map(|id| (id.into(), file(id)))
                        .collect(),
                    pin: None,
                    event_tx: events,
                },
                allow_upload: true,
            },
            ..Default::default()
        },
        stopping,
    )
    .await
    .unwrap();
    let client = reqwest::Client::builder()
        .no_proxy()
        .timeout(Duration::from_secs(5))
        .build()
        .unwrap();
    let root = format!("http://127.0.0.1:{}", server.port());
    let prepare = client.post(format!("{root}/api/localsend/v2/prepare-download"));
    let prepare =
        tokio::spawn(async move { prepare.send().await.unwrap().json::<Value>().await.unwrap() });
    match incoming.recv().await.unwrap() {
        WebDownloadEvent::PrepareDownload { decision_tx, .. } => {
            decision_tx.send(true).unwrap();
        }
        _ => panic!("expected approval"),
    }
    let list = prepare.await.unwrap();
    let session = list["sessionId"].as_str().unwrap();
    let url =
        |id: &str| format!("{root}/api/localsend/v2/download?sessionId={session}&fileId={id}");
    let pending = client.get(url("pending"));
    let pending = tokio::spawn(async move { pending.send().await.unwrap() });
    let pending_source = match incoming.recv().await.unwrap() {
        WebDownloadEvent::FileDownload {
            file_id,
            content_tx,
            ..
        } => {
            assert_eq!(file_id, "pending");
            content_tx
        }
        _ => panic!("expected file"),
    };
    let slow = client.get(url("slow"));
    let slow = tokio::spawn(async move { slow.send().await.unwrap() });
    let (slow_source, stream) = mpsc::channel(1);
    match incoming.recv().await.unwrap() {
        WebDownloadEvent::FileDownload { content_tx, .. } => {
            assert!(content_tx.send(FileContent::Stream(stream)).is_ok());
        }
        _ => panic!("expected file"),
    };
    slow_source
        .send(bytes::Bytes::from_static(b"x"))
        .await
        .unwrap();
    let mut slow = slow.await.unwrap();
    assert_eq!(slow.chunk().await.unwrap().unwrap().as_ref(), b"x");
    server
        .patch_web_workspace(HashMap::new(), vec!["pending".into()])
        .await
        .unwrap();
    assert_eq!(
        tokio::time::timeout(Duration::from_secs(2), pending)
            .await
            .unwrap()
            .unwrap()
            .status(),
        410
    );
    assert!(pending_source.is_closed());
    assert!(!slow_source.is_closed(), "unrelated reader stays open");
    server
        .patch_web_workspace(HashMap::new(), vec!["slow".into()])
        .await
        .unwrap();
    assert!(
        tokio::time::timeout(Duration::from_secs(2), slow.bytes())
            .await
            .unwrap()
            .is_err()
    );
    tokio::time::timeout(Duration::from_secs(2), slow_source.closed())
        .await
        .unwrap();
    // Neither revocation invalidates an already accepted session for another file.
    let keep = client.get(url("keep"));
    let keep = tokio::spawn(async move { keep.send().await.unwrap().bytes().await.unwrap() });
    let (sender, stream) = mpsc::channel(1);
    sender
        .send(bytes::Bytes::from_static(b"out"))
        .await
        .unwrap();
    drop(sender);
    match incoming.recv().await.unwrap() {
        WebDownloadEvent::FileDownload { content_tx, .. } => {
            assert!(content_tx.send(FileContent::Stream(stream)).is_ok());
        }
        _ => panic!("expected file"),
    };
    assert_eq!(keep.await.unwrap().as_ref(), b"out");
    stop.send(()).unwrap();
    server.wait_stopped().await;
}

/// Real sockets: abandoned approvals, refused requests, failed file providers,
/// share replacement, and stale responders must not poison the next transfer.
#[tokio::test]
async fn ten_faulted_rounds_recover_without_stale_session_or_responder_reuse() {
    use std::time::Duration;
    use tokio::io::AsyncWriteExt;
    let f = Fixture::start().await;
    let prepare_url = format!("{}/api/localsend/v2/prepare-download", f.root);
    let download_url = |id: &str| {
        format!(
            "{}/api/localsend/v2/download?sessionId={id}&fileId=out",
            f.root
        )
    };
    let mut previous_id: Option<String> = None;
    for round in 0..10 {
        let (events, mut incoming) = mpsc::channel(16);
        f.server.set_web_mode(WebMode::Duplex {
            download: WebDownloadConfig {
                files: HashMap::from([("out".into(), file("out"))]),
                pin: None,
                event_tx: events,
            },
            allow_upload: true,
        });
        if let Some(id) = &previous_id {
            assert_eq!(
                f.client
                    .get(download_url(id))
                    .send()
                    .await
                    .unwrap()
                    .status(),
                403
            );
        }
        // An actual HTTP/1 disconnect must drop the service future and its permit.
        let mut socket = tokio::net::TcpStream::connect(("127.0.0.1", f.server.port()))
            .await
            .unwrap();
        socket.write_all(b"POST /api/localsend/v2/prepare-download HTTP/1.1\r\nHost: localhost\r\nContent-Length: 0\r\n\r\n").await.unwrap();
        let (abandoned_id, mut abandoned) = match incoming.recv().await.unwrap() {
            WebDownloadEvent::PrepareDownload {
                session_id,
                decision_tx,
                ..
            } => (session_id, decision_tx),
            _ => panic!("expected approval"),
        };
        drop(socket);
        tokio::time::timeout(Duration::from_secs(2), abandoned.closed())
            .await
            .expect("disconnection closes approval receiver");
        assert!(abandoned.send(true).is_err());
        assert!(
            matches!(incoming.recv().await.unwrap(), WebDownloadEvent::PrepareDownloadAborted { session_id } if session_id == abandoned_id)
        );

        // Both explicit rejection and a lost application answer recover.
        for denied in [true, false] {
            let request = f.client.post(&prepare_url);
            let response = tokio::spawn(async move { request.send().await.unwrap() });
            match incoming.recv().await.unwrap() {
                WebDownloadEvent::PrepareDownload { decision_tx, .. } => {
                    if denied {
                        decision_tx.send(false).unwrap();
                    } else {
                        drop(decision_tx);
                    }
                }
                _ => panic!("expected approval"),
            }
            assert_eq!(
                response.await.unwrap().status().as_u16(),
                if denied { 403 } else { 500 }
            );
            assert!(matches!(
                incoming.recv().await.unwrap(),
                WebDownloadEvent::PrepareDownloadAborted { .. }
            ));
        }
        let request = f.client.post(&prepare_url);
        let response = tokio::spawn(async move { request.send().await.unwrap() });
        let id = match incoming.recv().await.unwrap() {
            WebDownloadEvent::PrepareDownload {
                session_id,
                decision_tx,
                ..
            } => {
                decision_tx.send(true).unwrap();
                session_id
            }
            _ => panic!("expected approval"),
        };
        assert_eq!(
            response.await.unwrap().json::<Value>().await.unwrap()["sessionId"],
            id
        );
        // Provider failure does not revoke authorization; retry the same session.
        for fail in [true, false] {
            let request = f.client.get(download_url(&id));
            let response = tokio::spawn(async move { request.send().await.unwrap() });
            match incoming.recv().await.unwrap() {
                WebDownloadEvent::FileDownload {
                    content_tx,
                    session_id,
                    ..
                } => {
                    assert_eq!(session_id, id);
                    if fail {
                        drop(content_tx);
                    } else {
                        let (tx, rx) = mpsc::channel(1);
                        tx.send(bytes::Bytes::from_static(b"out")).await.unwrap();
                        drop(tx);
                        assert!(content_tx.send(FileContent::Stream(rx)).is_ok());
                    }
                }
                _ => panic!("expected download"),
            }
            let response = response.await.unwrap();
            assert_eq!(response.status().as_u16(), if fail { 500 } else { 200 });
            if !fail {
                assert_eq!(
                    response.bytes().await.unwrap().as_ref(),
                    b"out",
                    "round {round}"
                );
            }
        }
        let refresh = f
            .client
            .post(format!("{prepare_url}?sessionId={id}"))
            .send()
            .await
            .unwrap();
        assert_eq!(refresh.status(), 200);
        assert!(
            incoming.try_recv().is_err(),
            "accepted refresh requires no new decision"
        );
        let request = f.client.post(&prepare_url);
        let response = tokio::spawn(async move { request.send().await.unwrap() });
        let late = match incoming.recv().await.unwrap() {
            WebDownloadEvent::PrepareDownload { decision_tx, .. } => decision_tx,
            _ => panic!("expected approval"),
        };
        f.server.set_web_mode(WebMode::Disabled);
        assert_eq!(response.await.unwrap().status(), 410);
        assert!(late.send(true).is_err());
        previous_id = Some(id);
    }
    assert_eq!(
        f.client
            .get(format!("{}/api/localsend/v2/info", f.root))
            .send()
            .await
            .unwrap()
            .status(),
        200
    );
    f.end().await;
}

#[tokio::test]
async fn pending_approval_limit_preserves_existing_session_and_recovers_after_refusal() {
    use std::time::Duration;
    let f = Fixture::start().await;
    let (events, mut incoming) = mpsc::channel(128);
    f.server.set_web_mode(WebMode::Duplex {
        download: WebDownloadConfig {
            files: HashMap::new(),
            pin: None,
            event_tx: events,
        },
        allow_upload: true,
    });
    let url = format!("{}/api/localsend/v2/prepare-download", f.root);
    let launch = || {
        let request = f.client.post(&url);
        tokio::spawn(async move { request.send().await.unwrap() })
    };
    let accepted = launch();
    let id = match incoming.recv().await.unwrap() {
        WebDownloadEvent::PrepareDownload {
            session_id,
            decision_tx,
            ..
        } => {
            decision_tx.send(true).unwrap();
            session_id
        }
        _ => panic!("expected approval"),
    };
    assert_eq!(accepted.await.unwrap().status(), 200);
    let mut pending = vec![];
    for _ in 0..64 {
        let response = launch();
        let decision = match tokio::time::timeout(Duration::from_secs(2), incoming.recv())
            .await
            .unwrap()
            .unwrap()
        {
            WebDownloadEvent::PrepareDownload { decision_tx, .. } => decision_tx,
            _ => panic!("expected approval"),
        };
        pending.push((response, decision));
    }
    assert_eq!(launch().await.unwrap().status(), 429);
    assert_eq!(
        f.client
            .post(format!("{url}?sessionId={id}"))
            .send()
            .await
            .unwrap()
            .status(),
        200
    );
    assert!(incoming.try_recv().is_err());
    for (response, decision) in pending {
        decision.send(false).unwrap();
        assert_eq!(response.await.unwrap().status(), 403);
        assert!(matches!(
            incoming.recv().await.unwrap(),
            WebDownloadEvent::PrepareDownloadAborted { .. }
        ));
    }
    let retry = launch();
    match incoming.recv().await.unwrap() {
        WebDownloadEvent::PrepareDownload { decision_tx, .. } => decision_tx.send(true).unwrap(),
        _ => panic!("expected approval"),
    }
    assert_eq!(retry.await.unwrap().status(), 200);
    f.end().await;
}
