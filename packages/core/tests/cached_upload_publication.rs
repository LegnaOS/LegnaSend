#![cfg(feature = "http")]

use bytes::Bytes;
use futures_util::StreamExt;
use localsend::crypto::hash::sha256_hex;
use localsend::http::server::common::save::FileUploadTarget;
use localsend::http::server::v2::{PrepareUploadDecisionV2, ServerEventV2};
use localsend::http::server::web::WebConfig;
use localsend::http::server::{start_with_port, ServerConfigV2, ServerHandle};
use localsend::http::state::ClientInfo;
use serde_json::{json, Value};
use std::fs::{File, OpenOptions};
use std::path::PathBuf;
use std::time::Duration;
use tokio::sync::{mpsc, oneshot};
use tokio_stream::wrappers::ReceiverStream;

const WAIT: Duration = Duration::from_secs(5);

#[derive(Debug, Clone, PartialEq, Eq)]
struct Identity {
    session: String,
    file: String,
    attempt: String,
    transaction: String,
}
struct Publication {
    identity: Identity,
    size: u64,
    sha256: String,
    result: oneshot::Sender<Result<(), String>>,
}
#[derive(Clone, Copy)]
enum Files {
    Distinct,
    SameInode,
    HardLink,
    Nonempty,
    CacheNonempty,
    StageNonempty,
}
struct Fixture {
    dir: PathBuf,
    url: String,
    client: reqwest::Client,
    server: ServerHandle,
    stop: Option<oneshot::Sender<()>>,
    events: tokio::task::JoinHandle<()>,
    publish: mpsc::UnboundedReceiver<Publication>,
    releases: mpsc::UnboundedReceiver<(Identity, bool)>,
    results: mpsc::UnboundedReceiver<Result<(), String>>,
    progress: mpsc::UnboundedReceiver<u64>,
}
fn open(path: impl AsRef<std::path::Path>) -> File {
    OpenOptions::new()
        .read(true)
        .write(true)
        .open(path)
        .unwrap()
}
impl Fixture {
    async fn new(files: Files) -> Self {
        let dir = std::env::temp_dir().join(format!(
            "legnasend-descriptor-http-{}",
            uuid::Uuid::new_v4()
        ));
        std::fs::create_dir(&dir).unwrap();
        std::fs::write(
            dir.join("cache.ls"),
            if matches!(files, Files::Distinct | Files::StageNonempty) {
                &b""[..]
            } else {
                &b"keep cache until validated"[..]
            },
        )
        .unwrap();
        match files {
            Files::HardLink => {
                std::fs::hard_link(dir.join("cache.ls"), dir.join("staging")).unwrap()
            }
            _ => std::fs::write(
                dir.join("staging"),
                if matches!(files, Files::Distinct | Files::CacheNonempty) {
                    vec![]
                } else {
                    vec![0xee; 200_000]
                },
            )
            .unwrap(),
        }
        let (event_tx, mut event_rx) = mpsc::channel(16);
        let (publish_tx, publish) = mpsc::unbounded_channel();
        let (release_tx, releases) = mpsc::unbounded_channel();
        let (results_tx, results) = mpsc::unbounded_channel();
        let (progress_tx, progress) = mpsc::unbounded_channel();
        let target_dir = dir.clone();
        let events = tokio::spawn(async move {
            let mut attempts = 0;
            while let Some(event) = event_rx.recv().await {
                match event {
                    ServerEventV2::PrepareUpload {
                        files, decision_tx, ..
                    } => {
                        let _ = decision_tx
                            .send(PrepareUploadDecisionV2::Accept(files.into_keys().collect()));
                    }
                    ServerEventV2::FileUpload { target_tx, .. } => {
                        if matches!(files, Files::Distinct) && attempts > 0 {
                            for name in ["cache.ls", "staging"] {
                                let _ = std::fs::remove_file(target_dir.join(name));
                                OpenOptions::new()
                                    .read(true)
                                    .write(true)
                                    .create_new(true)
                                    .open(target_dir.join(name))
                                    .unwrap();
                            }
                        }
                        attempts += 1;
                        let cache = open(target_dir.join("cache.ls"));
                        let staging = match files {
                            Files::SameInode => cache.try_clone().unwrap(),
                            _ => open(target_dir.join("staging")),
                        };
                        let (result_tx, result_rx) = oneshot::channel();
                        let (tx, mut rx) = mpsc::channel(16);
                        let _ = target_tx.send(FileUploadTarget::CachedOpenedFiles {
                            cache,
                            staging,
                            transaction_id: uuid::Uuid::new_v4().to_string(),
                            result_tx,
                            progress_tx: Some(tx),
                        });
                        let results_tx = results_tx.clone();
                        tokio::spawn(async move {
                            let _ = results_tx.send(
                                result_rx
                                    .await
                                    .unwrap_or_else(|_| Err("request dropped".into())),
                            );
                        });
                        let progress_tx = progress_tx.clone();
                        tokio::spawn(async move {
                            while let Some(bytes) = rx.recv().await {
                                let _ = progress_tx.send(bytes);
                            }
                        });
                    }
                    ServerEventV2::PublishUpload {
                        session_id,
                        file_id,
                        attempt_id,
                        transaction_id,
                        size,
                        sha256,
                        result_tx,
                    } => {
                        let _ = publish_tx.send(Publication {
                            identity: Identity {
                                session: session_id,
                                file: file_id,
                                attempt: attempt_id,
                                transaction: transaction_id,
                            },
                            size,
                            sha256,
                            result: result_tx,
                        });
                    }
                    ServerEventV2::UploadCacheReleased {
                        session_id,
                        file_id,
                        attempt_id,
                        transaction_id,
                        published,
                    } => {
                        let _ = release_tx.send((
                            Identity {
                                session: session_id,
                                file: file_id,
                                attempt: attempt_id,
                                transaction: transaction_id,
                            },
                            published,
                        ));
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
                alias: "cached descriptor fixture".into(),
                version: "2.2".into(),
                device_model: None,
                device_type: None,
                token: "receiver".into(),
            },
            None,
            Some(ServerConfigV2 {
                pin: None,
                verify_checksums: true,
                event_tx,
            }),
            WebConfig::default(),
            stop_rx,
        )
        .await
        .unwrap();
        Self {
            dir,
            url: format!("http://127.0.0.1:{}", server.port()),
            client: reqwest::Client::builder()
                .no_proxy()
                .timeout(Duration::from_secs(15))
                .build()
                .unwrap(),
            server,
            stop: Some(stop),
            events,
            publish,
            releases,
            results,
            progress,
        }
    }
    async fn prepare(&self, bytes: &[u8]) -> Value {
        self.prepare_with_hash(bytes, true).await
    }
    async fn prepare_with_hash(&self, bytes: &[u8], include_hash: bool) -> Value {
        let mut body = json!({"info":{"alias":"original-v2-sender","version":"2.2","fingerprint":"sender","port":53317,"protocol":"http"},"files":{"out":{"id":"out","fileName":"original.bin","size":bytes.len(),"fileType":"application/octet-stream","sha256":sha256_hex(bytes)}}});
        if !include_hash {
            body["files"]["out"]
                .as_object_mut()
                .unwrap()
                .remove("sha256");
        }
        let response = self
            .client
            .post(format!("{}/api/localsend/v2/prepare-upload", self.url))
            .json(&body)
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
    async fn publication(&mut self) -> Publication {
        tokio::time::timeout(WAIT, self.publish.recv())
            .await
            .unwrap()
            .unwrap()
    }
    async fn result(&mut self) -> Result<(), String> {
        tokio::time::timeout(WAIT, self.results.recv())
            .await
            .unwrap()
            .unwrap()
    }
    async fn released(&mut self) -> (Identity, bool) {
        tokio::time::timeout(WAIT, self.releases.recv())
            .await
            .unwrap()
            .unwrap()
    }
    fn assert_unlocked(&self) {
        for name in ["cache.ls", "staging"] {
            let file = open(self.dir.join(name));
            file.try_lock()
                .expect("worker must release both descriptor locks before handing ownership back");
        }
    }
    async fn cancel(&self, session: &Value) {
        assert!(
            self.server
                .cancel_v2_session(session["sessionId"].as_str().unwrap())
                .await
        );
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        if let Some(stop) = self.stop.take() {
            let _ = stop.send(());
        }
        self.events.abort();
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

#[tokio::test]
async fn original_body_waits_for_publication_ack_and_exports_no_cache_header() {
    let mut f = Fixture::new(Files::Distinct).await;
    let bytes: Vec<u8> = (0..70_013u32).map(|n| n as u8).collect();
    let session = f.prepare(&bytes).await;
    let request = f.upload(&session).body(bytes.clone());
    let mut running = tokio::spawn(async move { request.send().await.unwrap() });
    let publication = f.publication().await;
    assert_eq!(publication.identity.session, session["sessionId"]);
    assert_eq!(publication.identity.file, "out");
    assert!(!publication.identity.attempt.is_empty());
    assert!(!publication.identity.transaction.is_empty());
    f.assert_unlocked();
    assert_eq!(publication.size, bytes.len() as u64);
    assert_eq!(publication.sha256, sha256_hex(&bytes));
    let header = std::fs::read(f.dir.join("cache.ls")).unwrap();
    let length = u32::from_le_bytes(header[12..16].try_into().unwrap()) as usize;
    let identity: Value = serde_json::from_slice(&header[16..16 + length]).unwrap();
    assert_eq!(identity["taskId"], publication.identity.transaction);
    assert_eq!(std::fs::read(f.dir.join("staging")).unwrap(), bytes);
    let cache = std::fs::read(f.dir.join("cache.ls")).unwrap();
    assert!(cache.starts_with(b"LEGNALS\0"));
    assert!(cache.len() > bytes.len());
    assert!(
        tokio::time::timeout(Duration::from_millis(80), &mut running)
            .await
            .is_err()
    );
    assert!(f.results.try_recv().is_err());
    assert!(f.releases.try_recv().is_err());
    std::fs::rename(f.dir.join("staging"), f.dir.join("original.bin")).unwrap();
    publication.result.send(Ok(())).unwrap();
    assert_eq!(running.await.unwrap().status(), 200);
    f.result().await.unwrap();
    assert_eq!(f.released().await, (publication.identity, true));
    assert_eq!(std::fs::read(f.dir.join("original.bin")).unwrap(), bytes);
}

#[tokio::test]
async fn checksum_failure_has_no_publication_and_original_token_retries_whole_file() {
    let mut f = Fixture::new(Files::Distinct).await;
    let session = f.prepare(b"right").await;
    assert_eq!(
        f.upload(&session)
            .body("wrong")
            .send()
            .await
            .unwrap()
            .status(),
        422
    );
    assert!(f.result().await.is_err());
    let first = f.released().await;
    assert!(!first.1);
    assert!(f.publish.try_recv().is_err());
    f.assert_unlocked();
    let request = f.upload(&session).body("right");
    let running = tokio::spawn(async move { request.send().await.unwrap() });
    let second = f.publication().await;
    assert_ne!(first.0.attempt, second.identity.attempt);
    assert_ne!(first.0.transaction, second.identity.transaction);
    assert_eq!(std::fs::read(f.dir.join("staging")).unwrap(), b"right");
    second.result.send(Ok(())).unwrap();
    assert_eq!(running.await.unwrap().status(), 200);
    f.result().await.unwrap();
    assert_eq!(f.released().await, (second.identity, true));
}

#[tokio::test]
async fn denied_or_dropped_publication_never_reports_success() {
    for deny in [true, false] {
        let mut f = Fixture::new(Files::Distinct).await;
        let session = f.prepare(b"data").await;
        let request = f.upload(&session).body("data");
        let running = tokio::spawn(async move { request.send().await.unwrap() });
        let publication = f.publication().await;
        f.assert_unlocked();
        if deny {
            publication
                .result
                .send(Err("provider declined publication".into()))
                .unwrap();
        } else {
            drop(publication.result);
        }
        assert_eq!(running.await.unwrap().status(), 500);
        assert!(f.result().await.is_err());
        assert_eq!(f.released().await, (publication.identity, false));
        assert!(!f.dir.join("original.bin").exists());
        // Non-checksum failures end the original protocol session. A fresh
        // prepare handshake is required rather than inventing token recovery.
        assert_eq!(
            f.upload(&session)
                .body("data")
                .send()
                .await
                .unwrap()
                .status(),
            403
        );
        assert!(f.publish.try_recv().is_err());
        let next = f.prepare(b"data").await;
        assert_ne!(next["sessionId"], session["sessionId"]);
        assert_ne!(next["files"]["out"], session["files"]["out"]);
        let request = f.upload(&next).body("data");
        let retry = tokio::spawn(async move { request.send().await.unwrap() });
        let publication = f.publication().await;
        assert_eq!(publication.size, 4);
        assert_eq!(publication.sha256, sha256_hex(b"data"));
        assert_eq!(std::fs::read(f.dir.join("staging")).unwrap(), b"data");
        // An old token does not consume or authorize the new session's request.
        assert_eq!(
            f.upload(&session)
                .body("data")
                .send()
                .await
                .unwrap()
                .status(),
            403
        );
        assert!(!retry.is_finished());
        publication.result.send(Ok(())).unwrap();
        assert_eq!(retry.await.unwrap().status(), 200);
        f.result().await.unwrap();
        assert_eq!(f.released().await, (publication.identity, true));
    }
}

#[tokio::test]
async fn cancelling_pending_publication_releases_only_that_attempt() {
    let mut f = Fixture::new(Files::Distinct).await;
    let session = f.prepare(b"data").await;
    let request = f.upload(&session).body("data");
    let running = tokio::spawn(async move { request.send().await });
    let publication = f.publication().await;
    f.cancel(&session).await;
    assert_eq!(f.released().await, (publication.identity, false));
    assert!(publication.result.send(Ok(())).is_err());
    assert!(f.result().await.is_err());
    f.assert_unlocked();
    let _ = running.await;
    let next = f.prepare(b"next").await;
    let request = f.upload(&next).body("next");
    let running = tokio::spawn(async move { request.send().await.unwrap() });
    f.publication().await.result.send(Ok(())).unwrap();
    assert_eq!(running.await.unwrap().status(), 200);
    f.result().await.unwrap();
    assert!(f.released().await.1);
}

#[tokio::test]
async fn full_declared_size_without_eof_cannot_publish() {
    let mut f = Fixture::new(Files::Distinct).await;
    let bytes = vec![7; 1024 * 1024];
    let session = f.prepare(&bytes).await;
    let (tx, rx) = mpsc::channel(2);
    let request = f.upload(&session).body(reqwest::Body::wrap_stream(
        ReceiverStream::new(rx).map(Ok::<Bytes, std::io::Error>),
    ));
    let running = tokio::spawn(async move { request.send().await });
    tx.send(Bytes::from(bytes)).await.unwrap();
    tokio::time::timeout(WAIT, async {
        while f.progress.recv().await.unwrap() < 1024 * 1024 - 1 {}
    })
    .await
    .unwrap();
    assert!(
        tokio::time::timeout(Duration::from_millis(80), f.publish.recv())
            .await
            .is_err()
    );
    f.cancel(&session).await;
    assert!(!f.released().await.1);
    assert!(f.result().await.is_err());
    assert!(f.publish.try_recv().is_err());
    f.assert_unlocked();
    drop(tx);
    let _ = running.await;
}

#[tokio::test]
async fn aliases_and_existing_content_fail_before_any_truncate() {
    for files in [
        Files::SameInode,
        Files::HardLink,
        Files::Nonempty,
        Files::CacheNonempty,
        Files::StageNonempty,
    ] {
        let mut f = Fixture::new(files).await;
        let original_cache = std::fs::read(f.dir.join("cache.ls")).unwrap();
        let original_staging = std::fs::read(f.dir.join("staging")).unwrap();
        let session = f.prepare(b"new bytes").await;
        assert_eq!(
            f.upload(&session)
                .body("new bytes")
                .send()
                .await
                .unwrap()
                .status(),
            500
        );
        assert!(f.result().await.is_err());
        assert!(!f.released().await.1);
        assert!(f.publish.try_recv().is_err());
        assert_eq!(
            std::fs::read(f.dir.join("cache.ls")).unwrap(),
            original_cache
        );
        assert_eq!(
            std::fs::read(f.dir.join("staging")).unwrap(),
            original_staging
        );
        f.assert_unlocked();
    }
}

#[tokio::test]
async fn short_and_oversized_bodies_never_reach_publication() {
    for bytes in ["tiny", "much too long"] {
        let mut f = Fixture::new(Files::Distinct).await;
        let session = f.prepare(b"expected").await;
        assert_eq!(
            f.upload(&session)
                .body(bytes)
                .send()
                .await
                .unwrap()
                .status(),
            500
        );
        assert!(f.result().await.is_err());
        assert!(!f.released().await.1);
        assert!(f.publish.try_recv().is_err());
        f.assert_unlocked();
    }
}

#[cfg(unix)]
#[test]
fn dropped_pending_cached_target_closes_both_descriptors() {
    use std::io::Read;
    use std::os::fd::OwnedFd;
    use std::os::unix::net::UnixStream;
    let (cache, mut cache_observer) = UnixStream::pair().unwrap();
    let (staging, mut staging_observer) = UnixStream::pair().unwrap();
    cache_observer.set_read_timeout(Some(WAIT)).unwrap();
    staging_observer.set_read_timeout(Some(WAIT)).unwrap();
    let cache: OwnedFd = cache.into();
    let staging: OwnedFd = staging.into();
    let (result_tx, _) = oneshot::channel();
    let (target_tx, target_rx) = oneshot::channel();
    target_tx
        .send(FileUploadTarget::CachedOpenedFiles {
            cache: cache.into(),
            staging: staging.into(),
            transaction_id: "pending".into(),
            result_tx,
            progress_tx: None,
        })
        .unwrap();
    drop(target_rx);
    for observer in [&mut cache_observer, &mut staging_observer] {
        assert_eq!(observer.read(&mut [0]).unwrap(), 0);
    }
}

#[tokio::test]
async fn disconnect_or_server_stop_releases_owned_descriptors_without_publication() {
    for disconnect in [true, false] {
        let mut f = Fixture::new(Files::Distinct).await;
        let session = f.prepare(&vec![9; 2 * 1024 * 1024]).await;
        let (tx, rx) = mpsc::channel(2);
        let request = f.upload(&session).body(reqwest::Body::wrap_stream(
            ReceiverStream::new(rx).map(Ok::<Bytes, std::io::Error>),
        ));
        let running = tokio::spawn(async move { request.send().await });
        tx.send(Bytes::from(vec![9; 1024 * 1024])).await.unwrap();
        tokio::time::timeout(WAIT, async {
            while f.progress.recv().await.unwrap() < 1024 * 1024 - 1 {}
        })
        .await
        .unwrap();
        if disconnect {
            running.abort();
        } else {
            f.stop.take().unwrap().send(()).unwrap();
            f.server.wait_stopped().await;
        }
        assert!(!f.released().await.1);
        assert!(f.result().await.is_err());
        assert!(f.publish.try_recv().is_err());
        f.assert_unlocked();
        drop(tx);
        let _ = running.await;
    }
}

#[tokio::test]
async fn held_cache_or_staging_lock_prevents_any_cache_header_write() {
    for name in ["cache.ls", "staging"] {
        let mut f = Fixture::new(Files::Distinct).await;
        let locked = open(f.dir.join(name));
        locked.try_lock().unwrap();
        let session = f.prepare(b"data").await;
        assert_eq!(
            f.upload(&session)
                .body("data")
                .send()
                .await
                .unwrap()
                .status(),
            500
        );
        assert!(f.result().await.is_err());
        assert!(!f.released().await.1);
        assert!(f.publish.try_recv().is_err());
        for path in ["cache.ls", "staging"] {
            assert_eq!(std::fs::metadata(f.dir.join(path)).unwrap().len(), 0);
        }
        drop(locked);
        f.assert_unlocked();
    }
}

#[tokio::test]
async fn empty_original_file_still_requires_publication_ack() {
    let mut f = Fixture::new(Files::Distinct).await;
    let session = f.prepare(b"").await;
    let request = f.upload(&session).body("");
    let running = tokio::spawn(async move { request.send().await.unwrap() });
    let publication = f.publication().await;
    f.assert_unlocked();
    assert_eq!(publication.size, 0);
    assert_eq!(publication.sha256, sha256_hex(b""));
    assert_eq!(std::fs::metadata(f.dir.join("staging")).unwrap().len(), 0);
    assert!(std::fs::read(f.dir.join("cache.ls"))
        .unwrap()
        .starts_with(b"LEGNALS\0"));
    publication.result.send(Ok(())).unwrap();
    assert_eq!(running.await.unwrap().status(), 200);
    f.result().await.unwrap();
    assert_eq!(f.released().await, (publication.identity, true));
}

#[tokio::test]
async fn verified_publication_digest_is_computed_when_sender_supplies_no_hash() {
    let mut fixture = Fixture::new(Files::Distinct).await;
    let bytes = b"actual original bytes without sender checksum";
    let session = fixture.prepare_with_hash(bytes, false).await;
    let request = fixture.upload(&session).body(bytes.to_vec());
    let upload = tokio::spawn(async move { request.send().await.unwrap() });
    let publication = fixture.publication().await;
    assert_eq!(publication.size, bytes.len() as u64);
    assert_eq!(publication.sha256, sha256_hex(bytes));
    assert_eq!(std::fs::read(fixture.dir.join("staging")).unwrap(), bytes);
    publication.result.send(Ok(())).unwrap();
    assert_eq!(upload.await.unwrap().status(), 200);
    fixture.result().await.unwrap();
    assert_eq!(fixture.released().await, (publication.identity, true));
}

#[tokio::test]
async fn sender_cancel_during_publication_cannot_approve_the_next_session() {
    let mut fixture = Fixture::new(Files::Distinct).await;
    let session = fixture.prepare(b"cancelled bytes").await;
    let request = fixture.upload(&session).body("cancelled bytes");
    let upload = tokio::spawn(async move { request.send().await.unwrap() });
    let stale = fixture.publication().await;
    assert_eq!(
        fixture
            .client
            .post(format!(
                "{}/api/localsend/v2/cancel?sessionId={}",
                fixture.url,
                session["sessionId"].as_str().unwrap()
            ))
            .send()
            .await
            .unwrap()
            .status(),
        200
    );
    assert_eq!(fixture.released().await, (stale.identity, false));
    assert!(stale.result.is_closed());
    assert!(fixture.result().await.is_err());
    assert_eq!(upload.await.unwrap().status(), 500);
    fixture.assert_unlocked();

    let next = fixture.prepare(b"next bytes").await;
    let request = fixture.upload(&next).body("next bytes");
    let mut next_upload = tokio::spawn(async move { request.send().await.unwrap() });
    let current = fixture.publication().await;
    assert_eq!(current.identity.session, next["sessionId"]);
    assert!(stale.result.send(Ok(())).is_err());
    assert!(
        tokio::time::timeout(Duration::from_millis(80), &mut next_upload)
            .await
            .is_err()
    );
    assert!(fixture.results.try_recv().is_err());
    assert!(fixture.releases.try_recv().is_err());
    assert_eq!(
        std::fs::read(fixture.dir.join("staging")).unwrap(),
        b"next bytes"
    );
    current.result.send(Ok(())).unwrap();
    assert_eq!(next_upload.await.unwrap().status(), 200);
    fixture.result().await.unwrap();
    assert_eq!(fixture.released().await, (current.identity, true));
}

#[tokio::test]
async fn empty_and_multichunk_binary_progress_reaches_completion_only_after_ack() {
    for bytes in [
        Vec::new(),
        (0..(3 * 1024 * 1024 + 17))
            .map(|n| (n % 256) as u8)
            .collect(),
    ] {
        let mut fixture = Fixture::new(Files::Distinct).await;
        let size = bytes.len() as u64;
        let session = fixture.prepare_with_hash(&bytes, false).await;
        let (body_tx, body_rx) = mpsc::channel(2);
        let request = fixture.upload(&session).body(reqwest::Body::wrap_stream(
            ReceiverStream::new(body_rx).map(Ok::<Bytes, std::io::Error>),
        ));
        let mut upload = tokio::spawn(async move { request.send().await.unwrap() });
        // Split on a non-power-of-two boundary rather than matching native cache records.
        for chunk in bytes.chunks(49_157) {
            body_tx.send(Bytes::copy_from_slice(chunk)).await.unwrap();
        }
        drop(body_tx);
        let publication = fixture.publication().await;
        assert_eq!(publication.size, size);
        assert_eq!(publication.sha256, sha256_hex(&bytes));
        assert_eq!(std::fs::read(fixture.dir.join("staging")).unwrap(), bytes);
        assert!(tokio::time::timeout(Duration::from_millis(80), &mut upload)
            .await
            .is_err());
        while let Ok(progress) = fixture.progress.try_recv() {
            assert!(
                progress < size,
                "completion progress preceded provider acknowledgement"
            );
        }
        assert!(fixture.results.try_recv().is_err());
        assert!(fixture.releases.try_recv().is_err());
        publication.result.send(Ok(())).unwrap();
        assert_eq!(upload.await.unwrap().status(), 200);
        fixture.result().await.unwrap();
        assert_eq!(fixture.released().await, (publication.identity, true));
        tokio::time::timeout(WAIT, async {
            loop {
                if fixture.progress.recv().await.unwrap() == size {
                    break;
                }
            }
        })
        .await
        .expect("publication acknowledgement must expose final progress");
    }
}
