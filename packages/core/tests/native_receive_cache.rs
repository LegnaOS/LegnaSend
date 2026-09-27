#![cfg(feature = "http")]
use bytes::Bytes;
use futures_util::StreamExt;
use localsend::http::server::{start_with_port, ServerConfigV2, ServerHandle};
use localsend::http::server::common::save::FileUploadTarget;
use localsend::http::server::v2::{PrepareUploadDecisionV2, ServerEventV2};
use localsend::http::server::web::WebConfig;
use localsend::http::state::ClientInfo;
use serde_json::{json, Value};
use std::{path::PathBuf, time::Duration};
use tokio::sync::{mpsc, oneshot};
use tokio_stream::wrappers::ReceiverStream;

struct Fixture {
    dir: PathBuf,
    url: String,
    server: ServerHandle,
    stop: Option<oneshot::Sender<()>>,
    client: reqwest::Client,
    results: mpsc::UnboundedReceiver<Result<(), String>>,
    progress: mpsc::UnboundedReceiver<u64>,
}
impl Fixture {
    async fn new() -> Self {
        let dir =
            std::env::temp_dir().join(format!("legnasend-cache-http-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir(&dir).unwrap();
        let (events, mut rx) = mpsc::channel(16);
        let (results, results_rx) = mpsc::unbounded_channel();
        let (progress, progress_rx) = mpsc::unbounded_channel();
        let dest = dir.clone();
        tokio::spawn(async move {
            while let Some(event) = rx.recv().await {
                match event {
                    ServerEventV2::PrepareUpload {
                        files, decision_tx, ..
                    } => {
                        let _ = decision_tx.send(PrepareUploadDecisionV2::Accept(
                            files.keys().cloned().collect(),
                        ));
                    }
                    ServerEventV2::FileUpload {
                        file_id, target_tx, ..
                    } => {
                        let (result_tx, result_rx) = oneshot::channel();
                        let (progress_tx, mut progress_rx) = mpsc::channel(16);
                        let _ = target_tx.send(FileUploadTarget::CachedPath {
                            path: dest.join(file_id),
                            result_tx,
                            progress_tx: Some(progress_tx),
                        });
                        let results = results.clone();
                        let progress = progress.clone();
                        tokio::spawn(async move {
                            let _ = results.send(
                                result_rx
                                    .await
                                    .unwrap_or_else(|_| Err("request dropped".into())),
                            );
                        });
                        tokio::spawn(async move {
                            while let Some(n) = progress_rx.recv().await {
                                let _ = progress.send(n);
                            }
                        });
                    }
                    _ => {}
                }
            }
        });
        let (tx, rx) = oneshot::channel();
        let server = start_with_port(
            0,
            None,
            ClientInfo {
                alias: "cache receiver".into(),
                version: "2.2".into(),
                device_model: None,
                device_type: None,
                token: "receiver".into(),
            },
            None,
            Some(ServerConfigV2 {
                pin: None,
                verify_checksums: true,
                event_tx: events,
            }),
            WebConfig::default(),
            rx,
        )
        .await
        .unwrap();
        Self {
            dir,
            url: format!("http://127.0.0.1:{}", server.port()),
            server,
            stop: Some(tx),
            client: reqwest::Client::builder()
                .no_proxy()
                .timeout(Duration::from_secs(10))
                .build()
                .unwrap(),
            results: results_rx,
            progress: progress_rx,
        }
    }
    async fn prepare(&self, size: u64, hash: Option<String>) -> Value {
        let request = json!({"info":{"alias":"original-v2-sender","version":"2.2","fingerprint":"sender","port":53317,"protocol":"http"},
            "files":{"out":{"id":"out","fileName":"out","size":size,"fileType":"application/octet-stream","sha256":hash}}});
        let response = self
            .client
            .post(format!("{}/api/localsend/v2/prepare-upload", self.url))
            .json(&request)
            .send()
            .await
            .unwrap();
        assert_eq!(response.status(), 200);
        response.json().await.unwrap()
    }
    fn upload(&self, session: &Value) -> reqwest::RequestBuilder {
        let query = form_urlencoded::Serializer::new(String::new())
            .append_pair("sessionId", session["sessionId"].as_str().unwrap())
            .append_pair("fileId", "out")
            .append_pair("token", session["files"]["out"].as_str().unwrap())
            .finish();
        self.client
            .post(format!("{}/api/localsend/v2/upload?{query}", self.url))
    }
    async fn clean(&self) {
        for _ in 0..200 {
            if std::fs::read_dir(&self.dir).unwrap().all(|e| {
                !e.unwrap()
                    .file_name()
                    .to_string_lossy()
                    .starts_with(".legnasend-receive-")
            }) {
                return;
            }
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
        panic!("Owned receive files were not cleaned");
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
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

#[tokio::test]
async fn v2_cached_path_hash_retry_keeps_same_token_and_original_bytes() {
    let mut f = Fixture::new().await;
    let session = f
        .prepare(5, Some(localsend::crypto::hash::sha256_hex(b"right")))
        .await;
    let bad = f.upload(&session).body("wrong").send().await.unwrap();
    assert_eq!(bad.status(), 422);
    assert!(f.result().await.is_err());
    assert!(!f.dir.join("out").exists());
    f.clean().await;
    let good = f.upload(&session).body("right").send().await.unwrap();
    assert_eq!(good.status(), 200);
    assert!(f.result().await.is_ok());
    assert_eq!(std::fs::read(f.dir.join("out")).unwrap(), b"right");
    f.clean().await;
}

#[tokio::test]
async fn short_overlong_disconnect_and_stop_do_not_leave_partial_final_files() {
    for mode in ["short", "long", "disconnect", "stop"] {
        let mut f = Fixture::new().await;
        let session = f.prepare(2 * 1024 * 1024, None).await;
        if mode == "short" || mode == "long" {
            let size = if mode == "short" { 3 } else { 3 * 1024 * 1024 };
            let response = f.upload(&session).body(vec![1; size]).send().await.unwrap();
            assert_eq!(response.status(), 500);
            assert!(f.result().await.is_err());
        } else {
            let (tx, rx) = mpsc::channel(2);
            let body = reqwest::Body::wrap_stream(
                ReceiverStream::new(rx).map(Ok::<Bytes, std::io::Error>),
            );
            let request = f.upload(&session).body(body);
            let running = tokio::spawn(async move { request.send().await });
            tx.send(Bytes::from(vec![1; 1024 * 1024])).await.unwrap();
            assert_eq!(
                tokio::time::timeout(Duration::from_secs(5), f.progress.recv())
                    .await
                    .unwrap(),
                Some(1024 * 1024)
            );
            assert!(!f.dir.join("out").exists());
            if mode == "disconnect" {
                running.abort();
                let _ = running.await;
            } else {
                f.stop.take().unwrap().send(()).unwrap();
                f.server.wait_stopped().await;
                let _ = running.await;
            }
            drop(tx);
            assert!(f.result().await.is_err());
        }
        f.clean().await;
        assert!(!f.dir.join("out").exists());
    }
}

#[tokio::test]
async fn sender_and_receiver_cancel_stalled_body_then_accept_another_session() {
    for sender_cancel in [true, false] {
        let mut f = Fixture::new().await;
        let session = f.prepare(4 * 1024 * 1024, None).await;
        let (tx, rx) = mpsc::channel(2);
        let request = f.upload(&session).body(reqwest::Body::wrap_stream(
            ReceiverStream::new(rx).map(Ok::<Bytes, std::io::Error>),
        ));
        let running = tokio::spawn(async move { request.send().await });
        tx.send(Bytes::from(vec![1; 1024 * 1024])).await.unwrap();
        assert_eq!(
            tokio::time::timeout(Duration::from_secs(5), f.progress.recv())
                .await
                .unwrap(),
            Some(1024 * 1024)
        );
        if sender_cancel {
            assert_eq!(
                f.client
                    .post(format!(
                        "{}/api/localsend/v2/cancel?sessionId={}",
                        f.url,
                        session["sessionId"].as_str().unwrap()
                    ))
                    .send()
                    .await
                    .unwrap()
                    .status(),
                200
            );
        } else {
            assert!(
                f.server
                    .cancel_v2_session(session["sessionId"].as_str().unwrap())
                    .await
            );
        }
        // No additional body bytes or sender disconnect are required for cleanup.
        assert!(f.result().await.is_err());
        f.clean().await;
        assert!(!f.dir.join("out").exists());
        drop(tx);
        let _ = running.await;
        let next = f.prepare(3, None).await;
        assert_eq!(
            f.upload(&next).body("new").send().await.unwrap().status(),
            200
        );
        assert!(f.result().await.is_ok());
        assert_eq!(std::fs::read(f.dir.join("out")).unwrap(), b"new");
        f.clean().await;
    }
}

#[tokio::test]
async fn early_destination_failure_returns_without_waiting_for_body_eof() {
    let mut f = Fixture::new().await;
    std::fs::write(f.dir.join("out"), b"keep user bytes").unwrap();
    let session = f.prepare(4096, None).await;
    let (tx, rx) = mpsc::channel(2);
    tx.send(Bytes::from_static(b"first byte")).await.unwrap();
    let request = f.upload(&session).body(reqwest::Body::wrap_stream(
        ReceiverStream::new(rx).map(Ok::<Bytes, std::io::Error>),
    ));
    let response = tokio::time::timeout(Duration::from_secs(3), request.send())
        .await
        .unwrap()
        .unwrap();
    assert_eq!(response.status(), 500);
    assert!(f.result().await.is_err());
    assert_eq!(
        std::fs::read(f.dir.join("out")).unwrap(),
        b"keep user bytes"
    );
    f.clean().await;
    drop(tx);
}
