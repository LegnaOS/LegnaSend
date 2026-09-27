#![cfg(feature = "http")]
//! Real HTTP faults, original v2 messages, registered-path saves and subsequent byte/hash recovery.
use localsend::crypto::hash::sha256_hex;
use localsend::http::server::common::save::FileUploadTarget;
use localsend::http::server::v2::{PrepareUploadDecisionV2, ServerEventV2};
use localsend::http::server::web::WebConfig;
use localsend::http::server::{ServerConfigV2, ServerHandle, start_with_port};
use localsend::http::state::ClientInfo;
use serde_json::{Value, json};
use std::{path::PathBuf, time::Duration};
use tokio::{
    io::AsyncWriteExt,
    sync::{mpsc, oneshot},
};

struct Fixture {
    handle: ServerHandle,
    client: reqwest::Client,
    events: mpsc::Receiver<ServerEventV2>,
    dir: PathBuf,
    _stop: oneshot::Sender<()>,
}
impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}
impl Fixture {
    async fn new() -> Self {
        let dir =
            std::env::temp_dir().join(format!("legnasend-v2-lifecycle-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir(&dir).unwrap();
        let (event_tx, events) = mpsc::channel(32);
        let (_stop, rx) = oneshot::channel();
        let handle = start_with_port(
            0,
            None,
            ClientInfo {
                alias: "receiver".into(),
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
            rx,
        )
        .await
        .unwrap();
        Self {
            handle,
            client: reqwest::Client::builder()
                .no_proxy()
                .timeout(Duration::from_secs(5))
                .build()
                .unwrap(),
            events,
            dir,
            _stop,
        }
    }
    fn url(&self, path: &str) -> String {
        format!(
            "http://127.0.0.1:{}/api/localsend/v2/{path}",
            self.handle.port()
        )
    }
    fn offer(id: &str, bytes: &[u8]) -> Value {
        json!({"info":{"alias":"original-v2-sender","version":"2.2","fingerprint":"sender","port":53317,"protocol":"http"},"files":{id:{"id":id,"fileName":format!("{id}.bin"),"size":bytes.len(),"fileType":"application/octet-stream","sha256":sha256_hex(bytes)}}})
    }
    async fn event(&mut self) -> ServerEventV2 {
        tokio::time::timeout(Duration::from_secs(3), self.events.recv())
            .await
            .unwrap()
            .unwrap()
    }
    async fn decision(&mut self) -> (String, oneshot::Sender<PrepareUploadDecisionV2>) {
        loop {
            if let ServerEventV2::PrepareUpload {
                session_id,
                decision_tx,
                ..
            } = self.event().await
            {
                return (session_id, decision_tx);
            }
        }
    }
    async fn target(&mut self) -> oneshot::Sender<FileUploadTarget> {
        loop {
            if let ServerEventV2::FileUpload { target_tx, .. } = self.event().await {
                return target_tx;
            }
        }
    }
    async fn aborted(&mut self, id: &str) {
        loop {
            if let ServerEventV2::PrepareUploadAborted { session_id } = self.event().await {
                assert_eq!(session_id, id);
                return;
            }
        }
    }
    async fn accepted(&mut self, id: &str, bytes: &[u8]) -> Value {
        let request = self
            .client
            .post(self.url("prepare-upload"))
            .json(&Self::offer(id, bytes));
        let response = tokio::spawn(async move { request.send().await.unwrap() });
        let (_, decision) = self.decision().await;
        decision
            .send(PrepareUploadDecisionV2::Accept([id.to_string()].into()))
            .unwrap();
        let response = response.await.unwrap();
        assert_eq!(response.status(), 200);
        response.json().await.unwrap()
    }
    fn upload_url(&self, session: &Value, id: &str) -> String {
        format!(
            "{}?sessionId={}&fileId={id}&token={}",
            self.url("upload"),
            session["sessionId"].as_str().unwrap(),
            session["files"][id].as_str().unwrap()
        )
    }
    fn save_target(
        &self,
        id: &str,
    ) -> (
        FileUploadTarget,
        oneshot::Receiver<Result<(), String>>,
        mpsc::Receiver<u64>,
    ) {
        let (result_tx, result) = oneshot::channel();
        let (progress_tx, progress) = mpsc::channel(8);
        (
            FileUploadTarget::CachedPath {
                path: self.dir.join(id),
                result_tx,
                progress_tx: Some(progress_tx),
            },
            result,
            progress,
        )
    }
    async fn invalidated(&self, session: &Value, id: &str) {
        assert_eq!(
            self.client
                .post(self.upload_url(session, id))
                .body("stale")
                .send()
                .await
                .unwrap()
                .status(),
            403
        );
    }
    async fn next_transfer(&mut self) {
        let bytes = b"next original-protocol file\0\xff stays exact";
        let session = self.accepted("next", bytes).await;
        let request = self
            .client
            .post(self.upload_url(&session, "next"))
            .body(bytes.to_vec());
        let response = tokio::spawn(async move { request.send().await.unwrap() });
        let target = self.target().await;
        let (save, result, _) = self.save_target("next");
        target.send(save).unwrap();
        assert_eq!(response.await.unwrap().status(), 200);
        assert!(result.await.unwrap().is_ok());
        let actual = std::fs::read(self.dir.join("next")).unwrap();
        assert_eq!(actual, bytes);
        assert_eq!(sha256_hex(&actual), sha256_hex(bytes));
        self.invalidated(&session, "next").await;
    }
}

#[tokio::test]
async fn pending_faults_release_slot_for_a_complete_hashed_original_transfer() {
    for mode in [
        "disconnect",
        "sender_timeout",
        "decision_dropped",
        "decline",
        "empty",
        "cancel",
    ] {
        let mut f = Fixture::new().await;
        let (id, held) = if mode == "disconnect" {
            let mut stream = tokio::net::TcpStream::connect(("127.0.0.1", f.handle.port()))
                .await
                .unwrap();
            let body = Fixture::offer("old", b"first").to_string();
            stream.write_all(format!("POST /api/localsend/v2/prepare-upload HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\nContent-Length: {}\r\n\r\n{body}",body.len()).as_bytes()).await.unwrap();
            let (id, held) = f.decision().await;
            drop(stream);
            f.aborted(&id).await;
            (id, Some(held))
        } else {
            let mut request = f
                .client
                .post(f.url("prepare-upload"))
                .json(&Fixture::offer("old", b"first"));
            if mode == "sender_timeout" {
                request = request.timeout(Duration::from_millis(250));
            }
            let response = tokio::spawn(async move { request.send().await });
            let (id, held) = f.decision().await;
            let held = match mode {
                "decision_dropped" => {
                    drop(held);
                    None
                }
                "decline" => {
                    held.send(PrepareUploadDecisionV2::Decline).unwrap();
                    None
                }
                "empty" => {
                    held.send(PrepareUploadDecisionV2::Accept(Default::default()))
                        .unwrap();
                    None
                }
                "cancel" => {
                    assert_eq!(
                        f.client
                            .post(f.url("cancel"))
                            .send()
                            .await
                            .unwrap()
                            .status(),
                        200
                    );
                    Some(held)
                }
                _ => Some(held),
            };
            let response = response.await.unwrap();
            if mode == "sender_timeout" {
                assert!(response.unwrap_err().is_timeout());
            } else {
                assert_eq!(
                    response.unwrap().status(),
                    match mode {
                        "decision_dropped" => 500,
                        "empty" => 204,
                        _ => 403,
                    }
                );
            }
            if matches!(mode, "sender_timeout" | "decision_dropped" | "cancel") {
                f.aborted(&id).await;
            }
            (id, held)
        };
        if let Some(held) = held {
            assert!(
                held.is_closed(),
                "{mode}: old decision remained live for {id}"
            );
            assert!(
                held.send(PrepareUploadDecisionV2::Accept(["old".into()].into()))
                    .is_err()
            );
        }
        f.next_transfer().await;
    }
}

#[tokio::test]
async fn cancel_while_target_resolution_is_pending_releases_old_request_and_tokens() {
    for sender_cancel in [false, true] {
        let mut f = Fixture::new().await;
        let session = f.accepted("old", b"first").await;
        let request = f.client.post(f.upload_url(&session, "old")).body("first");
        let mut response = tokio::spawn(async move { request.send().await.unwrap() });
        let target = f.target().await;
        if sender_cancel {
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
        } else {
            assert!(
                f.handle
                    .cancel_v2_session(session["sessionId"].as_str().unwrap())
                    .await
            );
        }
        let finished = tokio::time::timeout(Duration::from_millis(500), &mut response).await;
        if finished.is_err() {
            response.abort();
        }
        assert!(
            finished.is_ok(),
            "Cancellation left the old HTTP request waiting for a late target"
        );
        assert_eq!(finished.unwrap().unwrap().status(), 500);
        let (late, result, _) = f.save_target("old");
        assert!(target.send(late).is_err());
        assert!(result.await.is_err());
        assert!(!f.dir.join("old").exists());
        f.invalidated(&session, "old").await;
        f.next_transfer().await;
    }
}

#[tokio::test]
async fn partial_body_disconnect_and_cancel_clean_owned_cache_then_new_hash_transfer_succeeds() {
    for cancel in [false, true] {
        let mut f = Fixture::new().await;
        let data = vec![7u8; 2 * 1024 * 1024];
        let session = f.accepted("old", &data).await;
        let mut stream = tokio::net::TcpStream::connect(("127.0.0.1", f.handle.port()))
            .await
            .unwrap();
        let url = f.upload_url(&session, "old");
        let path = url.split_once("/api/").unwrap().1;
        stream
            .write_all(
                format!(
                    "POST /api/{path} HTTP/1.1\r\nHost: localhost\r\nContent-Length: {}\r\n\r\n",
                    data.len()
                )
                .as_bytes(),
            )
            .await
            .unwrap();
        let target = f.target().await;
        let (save, result, mut progress) = f.save_target("old");
        target.send(save).unwrap();
        stream.write_all(&data[..1024 * 1024]).await.unwrap();
        assert!(
            tokio::time::timeout(Duration::from_secs(3), progress.recv())
                .await
                .unwrap()
                .unwrap()
                > 0
        );
        if cancel {
            assert!(
                f.handle
                    .cancel_v2_session(session["sessionId"].as_str().unwrap())
                    .await
            );
        }
        drop(stream);
        assert!(
            tokio::time::timeout(Duration::from_secs(3), result)
                .await
                .unwrap()
                .unwrap_or_else(|_| Err("request dropped".into()))
                .is_err()
        );
        for _ in 0..200 {
            if std::fs::read_dir(&f.dir).unwrap().next().is_none() {
                break;
            }
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
        assert!(
            std::fs::read_dir(&f.dir).unwrap().next().is_none(),
            "Partial native cache or final output was retained unexpectedly"
        );
        f.invalidated(&session, "old").await;
        f.next_transfer().await;
    }
}

#[tokio::test]
async fn checksum_retry_limit_invalidates_old_token_and_releases_new_sender_slot() {
    let mut f = Fixture::new().await;
    let session = f.accepted("old", b"right").await;
    for _ in 0..3 {
        let request = f.client.post(f.upload_url(&session, "old")).body("wrong");
        let response = tokio::spawn(async move { request.send().await.unwrap() });
        let target = f.target().await;
        let (save, result, _) = f.save_target("old");
        target.send(save).unwrap();
        assert_eq!(response.await.unwrap().status(), 422);
        assert!(result.await.unwrap().is_err());
        assert!(!f.dir.join("old").exists());
    }
    f.invalidated(&session, "old").await;
    f.next_transfer().await;
}

/// Advance only while no network response is being awaited. Real I/O uses the
/// normal clock so a paused runtime cannot auto-advance a request timeout.
async fn advance_listener_idle(seconds: u64) {
    tokio::time::pause();
    tokio::time::advance(Duration::from_secs(seconds)).await;
    for _ in 0..5 {
        tokio::task::yield_now().await;
    }
    tokio::time::resume();
}

#[tokio::test]
async fn accepted_idle_expiry_invalidates_tokens_then_next_original_transfer_matches_hash() {
    use localsend::http::server::v2::SessionEndReasonV2;
    let mut f = Fixture::new().await;
    let session = f.accepted("old", b"right").await;
    advance_listener_idle(599).await;
    assert!(
        f.events.try_recv().is_err(),
        "Accepted session expired early"
    );
    advance_listener_idle(2).await;
    assert!(
        matches!(f.event().await, ServerEventV2::SessionEnd { session_id, reason: SessionEndReasonV2::Expired } if session_id == session["sessionId"].as_str().unwrap())
    );
    f.invalidated(&session, "old").await;
    assert!(
        !f.dir.join("old").exists(),
        "An idle session never opened a destination"
    );
    f.next_transfer().await;
}

#[tokio::test]
async fn active_target_wait_is_not_idle_and_checksum_retry_gets_a_fresh_ten_minutes() {
    use localsend::http::server::v2::SessionEndReasonV2;
    let mut f = Fixture::new().await;
    // A save picker intentionally stays open longer than the old deadline.
    // Disable the fixture client's own short test timeout for this scenario.
    f.client = reqwest::Client::builder().no_proxy().build().unwrap();
    let session = f.accepted("old", b"right").await;
    advance_listener_idle(599).await;
    let request = f.client.post(f.upload_url(&session, "old")).body("wrong");
    let response = tokio::spawn(async move { request.send().await.unwrap() });
    let target = f.target().await;
    advance_listener_idle(3600).await;
    assert!(!response.is_finished(), "Target resolution remains live");
    assert!(
        f.events.try_recv().is_err(),
        "In-progress target wait must not expire"
    );

    let (save, result, _) = f.save_target("old");
    target.send(save).unwrap();
    assert_eq!(response.await.unwrap().status(), 422);
    assert!(result.await.unwrap().is_err());
    advance_listener_idle(599).await;
    assert!(
        f.events.try_recv().is_err(),
        "Retry window must start at the actual result"
    );
    advance_listener_idle(2).await;
    assert!(
        matches!(f.event().await, ServerEventV2::SessionEnd { session_id, reason: SessionEndReasonV2::Expired } if session_id == session["sessionId"].as_str().unwrap())
    );
    f.invalidated(&session, "old").await;
    f.next_transfer().await;
}

#[tokio::test]
async fn listener_stop_joins_idle_task_and_releases_the_port_with_an_accepted_session() {
    let mut f = Fixture::new().await;
    let _session = f.accepted("old", b"right").await;
    let port = f.handle.port();
    let (replacement, _) = oneshot::channel();
    let stop = std::mem::replace(&mut f._stop, replacement);
    stop.send(()).unwrap();
    tokio::time::timeout(Duration::from_secs(2), f.handle.wait_stopped())
        .await
        .unwrap();
    let rebound = tokio::net::TcpListener::bind(("127.0.0.1", port))
        .await
        .unwrap();
    advance_listener_idle(3600).await;
    assert!(
        f.events.try_recv().is_err(),
        "Stopped listener must not emit idle expiry"
    );
    drop(rebound);
}

#[tokio::test]
async fn real_partial_body_remains_live_across_idle_deadline_and_publishes_exact_hash() {
    use localsend::http::server::v2::SessionEndReasonV2;
    let mut f = Fixture::new().await;
    let data = vec![19u8; 2 * 1024 * 1024];
    let session = f.accepted("old", &data).await;
    advance_listener_idle(599).await;
    let mut stream = tokio::net::TcpStream::connect(("127.0.0.1", f.handle.port()))
        .await
        .unwrap();
    let url = f.upload_url(&session, "old");
    let path = url.split_once("/api/").unwrap().1;
    stream.write_all(
        format!("POST /api/{path} HTTP/1.1\r\nHost: localhost\r\nContent-Length: {}\r\nConnection: close\r\n\r\n", data.len()).as_bytes(),
    ).await.unwrap();
    let target = f.target().await;
    let (save, result, mut progress) = f.save_target("old");
    target.send(save).unwrap();
    stream.write_all(&data[..1024 * 1024]).await.unwrap();
    assert!(
        tokio::time::timeout(Duration::from_secs(3), progress.recv())
            .await
            .unwrap()
            .unwrap()
            > 0
    );
    advance_listener_idle(3600).await;
    assert!(
        f.events.try_recv().is_err(),
        "Partial request body must remain in progress"
    );
    stream.write_all(&data[1024 * 1024..]).await.unwrap();
    assert!(
        tokio::time::timeout(Duration::from_secs(3), result)
            .await
            .unwrap()
            .unwrap()
            .is_ok()
    );
    assert!(matches!(
        f.event().await,
        ServerEventV2::SessionEnd {
            reason: SessionEndReasonV2::Finished,
            ..
        }
    ));
    let actual = std::fs::read(f.dir.join("old")).unwrap();
    assert_eq!(actual, data);
    assert_eq!(sha256_hex(&actual), sha256_hex(&data));
    drop(stream);
    f.invalidated(&session, "old").await;
    f.next_transfer().await;
}

#[cfg(unix)]
#[tokio::test]
async fn disconnected_target_request_drops_late_owned_fd_while_another_file_keeps_session_live() {
    disconnected_target_request_with_owned_descriptor(false).await;
}

#[cfg(unix)]
#[tokio::test]
async fn disconnected_target_owned_descriptor_closes_its_peer_without_probing_reusable_fd_number() {
    disconnected_target_request_with_owned_descriptor(true).await;
}

#[cfg(unix)]
async fn disconnected_target_request_with_owned_descriptor(observe_peer: bool) {
    use std::os::fd::OwnedFd;
    use tokio::io::AsyncReadExt;
    let mut f = Fixture::new().await;
    let remaining_bytes = b"other accepted file remains independently transferable";
    let mut offer = Fixture::offer("disconnected", b"unused");
    offer["files"]["remaining"] =
        Fixture::offer("remaining", remaining_bytes)["files"]["remaining"].clone();
    let request = f.client.post(f.url("prepare-upload")).json(&offer);
    let preparation = tokio::spawn(async move { request.send().await.unwrap() });
    let (_, decision) = f.decision().await;
    decision
        .send(PrepareUploadDecisionV2::Accept(
            ["disconnected".to_string(), "remaining".to_string()].into(),
        ))
        .unwrap();
    let response = preparation.await.unwrap();
    assert_eq!(response.status(), 200);
    let session: Value = response.json().await.unwrap();

    let mut stream = tokio::net::TcpStream::connect(("127.0.0.1", f.handle.port()))
        .await
        .unwrap();
    let url = f.upload_url(&session, "disconnected");
    let path = url.split_once("/api/").unwrap().1;
    stream
        .write_all(
            format!("POST /api/{path} HTTP/1.1\r\nHost: localhost\r\nContent-Length: 6\r\n\r\n")
                .as_bytes(),
        )
        .await
        .unwrap();
    let old_target = f.target().await;
    drop(stream);
    // The body is not consumed until a target is available. TCP EOF may stay
    // buffered in Incoming, so do not invent an immediate-disconnect guarantee.
    tokio::time::sleep(Duration::from_millis(25)).await;
    assert!(
        f.events.try_recv().is_err(),
        "A sibling pending file keeps the session alive"
    );

    // The application/provider eventually returns a freshly owned descriptor.
    // If EOF already cancelled the handler, send returns the owned target.
    // Otherwise handing it off allows body polling to observe the short body.
    // Both paths must close the owned descriptor without changing this document.
    let document = f.dir.join("late-provider-document");
    std::fs::write(&document, b"existing provider bytes").unwrap();
    let (file, mut peer) = if observe_peer {
        let (reader, writer) = std::os::unix::net::UnixStream::pair().unwrap();
        reader.set_nonblocking(true).unwrap();
        let peer = tokio::net::UnixStream::from_std(reader).unwrap();
        assert_eq!(
            peer.try_read(&mut [0u8; 1]).unwrap_err().kind(),
            std::io::ErrorKind::WouldBlock
        );
        // Move the ONLY peer-facing owner into the exact OpenedFile target path.
        // Its peer observes the underlying socket lifetime, not a reusable fd
        // integer. std::File accepts ownership without unsafe raw-fd aliases.
        (std::fs::File::from(OwnedFd::from(writer)), Some(peer))
    } else {
        (
            std::fs::OpenOptions::new()
                .write(true)
                .open(&document)
                .unwrap(),
            None,
        )
    };
    let (result_tx, result_rx) = oneshot::channel();
    let delivery = old_target.send(FileUploadTarget::OpenedFile {
        file,
        result_tx,
        progress_tx: None,
    });
    drop(delivery);
    let outcome = tokio::time::timeout(Duration::from_secs(2), result_rx)
        .await
        .expect("Late target must not wait indefinitely after the short body is observed");
    assert!(outcome.is_err() || outcome.unwrap().is_err());
    if let Some(peer) = peer.as_mut() {
        let bytes = tokio::time::timeout(Duration::from_secs(2), peer.read(&mut [0u8; 1]))
            .await
            .expect("The unique owned target must close, independently of numeric fd reuse")
            .unwrap();
        assert_eq!(
            bytes, 0,
            "Disconnected upload must drop its owner without writing any bytes"
        );
    }
    // The separate regular-file variant retains the exact provider-document
    // protection assertion. Neither variant probes a closed/reusable fd number.
    assert_eq!(
        std::fs::read(&document).unwrap(),
        b"existing provider bytes"
    );

    f.invalidated(&session, "disconnected").await;
    let request = f
        .client
        .post(f.upload_url(&session, "remaining"))
        .body(remaining_bytes.to_vec());
    let transfer = tokio::spawn(async move { request.send().await.unwrap() });
    let target = f.target().await;
    let (save, result, _) = f.save_target("remaining");
    target.send(save).unwrap();
    assert_eq!(transfer.await.unwrap().status(), 200);
    assert!(result.await.unwrap().is_ok());
    let received = std::fs::read(f.dir.join("remaining")).unwrap();
    assert_eq!(received, remaining_bytes);
    assert_eq!(sha256_hex(&received), sha256_hex(remaining_bytes));
    f.next_transfer().await;
}
