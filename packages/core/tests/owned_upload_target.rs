#![cfg(feature = "http")]

use localsend::crypto::hash::sha256_hex;
use localsend::http::client::LsHttpClientV2;
use localsend::http::dto_v2::{PrepareUploadRequestDtoV2, RegisterDtoV2};
use localsend::http::server::common::save::FileUploadTarget;
use localsend::http::server::v2::{PrepareUploadDecisionV2, ServerEventV2};
use localsend::http::server::web::WebConfig;
use localsend::http::server::{start_with_port, ServerConfigV2};
use localsend::http::state::ClientInfo;
use localsend::model::discovery::ProtocolType;
use localsend::model::transfer::FileDto;
use std::fs::{File, OpenOptions};
use std::path::PathBuf;
use std::time::Duration;
use tokio::sync::{mpsc, oneshot};
use tokio_util::sync::CancellationToken;

// Socket EOF verifies closure without querying a raw descriptor number that a
// concurrently running test could already have reused.
#[cfg(unix)]
fn pending_target() -> (FileUploadTarget, std::os::unix::net::UnixStream) {
    let (owned, observer) = std::os::unix::net::UnixStream::pair().unwrap();
    observer
        .set_read_timeout(Some(Duration::from_secs(2)))
        .unwrap();
    let descriptor: std::os::fd::OwnedFd = owned.into();
    let (result_tx, _) = oneshot::channel();
    (
        FileUploadTarget::OpenedFile {
            file: File::from(descriptor),
            result_tx,
            progress_tx: None,
        },
        observer,
    )
}

#[cfg(unix)]
fn assert_closed(mut observer: std::os::unix::net::UnixStream) {
    use std::io::Read;
    assert_eq!(observer.read(&mut [0]).unwrap(), 0, "owned handle leaked");
}

#[cfg(unix)]
#[test]
fn dropping_pending_target_closes_owned_handle() {
    let (target, observer) = pending_target();
    drop(target);
    assert_closed(observer);
}

#[cfg(unix)]
#[test]
fn dropping_unconsumed_oneshot_target_closes_owned_handle() {
    let (target, observer) = pending_target();
    let (tx, rx) = oneshot::channel();
    tx.send(target).unwrap();
    drop(rx);
    assert_closed(observer);
}

#[cfg(unix)]
#[test]
fn rejected_oneshot_send_returns_ownership_until_error_is_dropped() {
    use std::io::Read;
    let (target, mut observer) = pending_target();
    let (tx, rx) = oneshot::channel();
    drop(rx);
    let rejected = tx.send(target).unwrap_err();
    observer.set_nonblocking(true).unwrap();
    assert_eq!(
        observer.read(&mut [0]).unwrap_err().kind(),
        std::io::ErrorKind::WouldBlock,
        "send error must retain ownership until dropped"
    );
    observer.set_nonblocking(false).unwrap();
    drop(rejected);
    assert_closed(observer);
}

struct Fixture {
    port: u16,
    dir: PathBuf,
    results: mpsc::Receiver<Result<(), String>>,
    stop: Option<oneshot::Sender<()>>,
    events: tokio::task::JoinHandle<()>,
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

impl Fixture {
    async fn start() -> Self {
        let dir =
            std::env::temp_dir().join(format!("legnasend-owned-target-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir(&dir).unwrap();
        // Simulate a document provider ignoring its requested truncate mode.
        std::fs::write(dir.join("received.bin"), vec![0xee; 200_000]).unwrap();
        let (event_tx, mut event_rx) = mpsc::channel(16);
        let (completed_tx, results) = mpsc::channel(8);
        let output = dir.join("received.bin");
        let events = tokio::spawn(async move {
            while let Some(event) = event_rx.recv().await {
                match event {
                    ServerEventV2::PrepareUpload {
                        files, decision_tx, ..
                    } => {
                        let _ = decision_tx
                            .send(PrepareUploadDecisionV2::Accept(files.into_keys().collect()));
                    }
                    ServerEventV2::FileUpload { target_tx, .. } => {
                        // Reopen from offset zero on every whole-file attempt.
                        let file = OpenOptions::new().write(true).open(&output).unwrap();
                        let (result_tx, result_rx) = oneshot::channel();
                        let _ = target_tx.send(FileUploadTarget::OpenedFile {
                            file,
                            result_tx,
                            progress_tx: None,
                        });
                        let completed_tx = completed_tx.clone();
                        tokio::spawn(async move {
                            let result =
                                result_rx.await.expect("target must report a final outcome");
                            let _ = completed_tx.send(result).await;
                        });
                    }
                    _ => {}
                }
            }
        });
        let (stop_tx, stop_rx) = oneshot::channel();
        let server = start_with_port(
            0,
            None,
            ClientInfo {
                alias: "Owned target fixture".into(),
                version: "2.2".into(),
                device_model: None,
                device_type: None,
                token: "receiver-fingerprint".into(),
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
            port: server.port(),
            dir,
            results,
            stop: Some(stop_tx),
            events,
        }
    }

    async fn prepare(&self, expected: &[u8]) -> (String, String) {
        let file = FileDto {
            id: "file-a".into(),
            file_name: "original.bin".into(),
            size: expected.len() as u64,
            file_type: "application/octet-stream".into(),
            sha256: Some(sha256_hex(expected)),
            preview: None,
            metadata: None,
        };
        let prepared = LsHttpClientV2::try_new_without_cert()
            .unwrap()
            .prepare_upload(
                ProtocolType::Http,
                "127.0.0.1",
                self.port,
                None,
                PrepareUploadRequestDtoV2 {
                    info: RegisterDtoV2 {
                        alias: "Original protocol sender".into(),
                        version: "2.2".into(),
                        device_model: None,
                        device_type: None,
                        fingerprint: "sender-fingerprint".into(),
                        port: 53317,
                        protocol: ProtocolType::Http,
                        download: false,
                    },
                    files: [(file.id.clone(), file)].into_iter().collect(),
                },
                None,
                CancellationToken::new(),
            )
            .await
            .unwrap()
            .response
            .unwrap();
        (prepared.session_id, prepared.files["file-a"].clone())
    }

    async fn upload(
        &mut self,
        session: &str,
        token: &str,
        bytes: Vec<u8>,
    ) -> (u16, Result<(), String>) {
        let query = form_urlencoded::Serializer::new(String::new())
            .append_pair("sessionId", session)
            .append_pair("fileId", "file-a")
            .append_pair("token", token)
            .finish();
        let response = localsend::reqwest::Client::builder()
            .no_proxy()
            .build()
            .unwrap()
            .post(format!(
                "http://127.0.0.1:{}/api/localsend/v2/upload?{query}",
                self.port
            ))
            .timeout(Duration::from_secs(10))
            .body(bytes)
            .send()
            .await
            .unwrap();
        let result = tokio::time::timeout(Duration::from_secs(5), self.results.recv())
            .await
            .unwrap()
            .unwrap();
        (response.status().as_u16(), result)
    }
}

#[tokio::test]
async fn opened_target_writes_exact_original_bytes_and_removes_old_tail() {
    let mut fixture = Fixture::start().await;
    let bytes: Vec<u8> = (0..70_013u32).map(|i| i as u8).collect();
    let (session, token) = fixture.prepare(&bytes).await;
    let (status, result) = fixture.upload(&session, &token, bytes.clone()).await;
    assert_eq!(status, 200);
    result.unwrap();
    let received = std::fs::read(fixture.dir.join("received.bin")).unwrap();
    assert_eq!(received, bytes);
    assert_eq!(std::fs::read_dir(&fixture.dir).unwrap().count(), 1);
}

#[tokio::test]
async fn opened_target_hash_mismatch_allows_same_token_whole_file_retry() {
    let mut fixture = Fixture::start().await;
    let bytes: Vec<u8> = (0..50_003u32).map(|i| i as u8).collect();
    let (session, token) = fixture.prepare(&bytes).await;
    let mut corrupted = bytes.clone();
    *corrupted.last_mut().unwrap() ^= 0xff;
    let (status, result) = fixture.upload(&session, &token, corrupted).await;
    assert_eq!(status, 422);
    assert!(result.unwrap_err().contains("Checksum mismatch"));
    let (status, result) = fixture.upload(&session, &token, bytes.clone()).await;
    assert_eq!(status, 200);
    result.unwrap();
    assert_eq!(
        std::fs::read(fixture.dir.join("received.bin")).unwrap(),
        bytes
    );
    assert_eq!(std::fs::read_dir(&fixture.dir).unwrap().count(), 1);
}

#[tokio::test]
async fn opened_target_rejects_short_and_oversized_bodies() {
    for body in [vec![7; 3], vec![7; 5]] {
        let mut fixture = Fixture::start().await;
        let (session, token) = fixture.prepare(&[7; 4]).await;
        let (status, result) = fixture.upload(&session, &token, body).await;
        assert_eq!(status, 500);
        assert!(result.unwrap_err().contains("Expected 4 bytes"));
    }
}
