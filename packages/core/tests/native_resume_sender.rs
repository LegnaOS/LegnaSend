#![cfg(feature = "full")]
//! Independent wire peer; deliberately does not use the product resume receiver.
use bytes::Bytes;
use http_body_util::{BodyExt, Full};
use hyper::{Request, Response, body::Incoming, service::service_fn};
use hyper_util::rt::TokioIo;
use localsend::{
    http::client::{ClientError, LsHttpClient, LsHttpClientV2},
    model::{discovery::ProtocolType, transfer::FileContent},
};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{
    collections::HashMap,
    io,
    path::PathBuf,
    sync::{Arc, Mutex},
    time::Duration,
};
use tokio::{net::TcpListener, sync::Notify};
use tokio_util::sync::CancellationToken;
const BLOCK: usize = 1024 * 1024;
fn hash(bytes: &[u8]) -> String {
    Sha256::digest(bytes)
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect()
}
const RID: &str = "11111111-1111-4111-8111-111111111111";
#[derive(Clone, Copy, PartialEq)]
enum Mode {
    Legacy,
    LegacyGone,
    DurableAuth,
    DurableMissing,
    Normal,
    DropSecond,
    WrongToken,
    InvalidOffset,
    ChangeSource,
    PauseA,
    DurableVerify,
    DurableSuspend,
    DurableSuspendLost,
}
#[derive(Default)]
struct State {
    calls: Vec<(String, String, Option<u64>)>,
    data: HashMap<String, Vec<u8>>,
    opened: HashMap<String, Value>,
    dropped: bool,
    status_busy_sent: bool,
}
struct Peer {
    port: u16,
    mode: Mode,
    state: Mutex<State>,
    source: PathBuf,
    cap_replacement: Option<Vec<u8>>,
    block_seen: Notify,
    stop: CancellationToken,
}
impl Drop for Peer {
    fn drop(&mut self) {
        self.stop.cancel();
    }
}
impl Peer {
    async fn start(mode: Mode, source: PathBuf, replacement: Option<Vec<u8>>) -> Arc<Self> {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let peer = Arc::new(Self {
            port: listener.local_addr().unwrap().port(),
            mode,
            state: Mutex::new(State::default()),
            source,
            cap_replacement: replacement,
            block_seen: Notify::new(),
            stop: CancellationToken::new(),
        });
        let weak = Arc::downgrade(&peer);
        let stop = peer.stop.clone();
        tokio::spawn(async move {
            loop {
                let socket = tokio::select! { _=stop.cancelled()=>break, result=listener.accept()=>result.unwrap().0 };
                let weak = weak.clone();
                tokio::spawn(async move {
                    let service = service_fn(move |request| {
                        let peer = weak.upgrade().unwrap();
                        async move { peer.handle(request).await }
                    });
                    let _ = hyper::server::conn::http1::Builder::new()
                        .serve_connection(TokioIo::new(socket), service)
                        .await;
                });
            }
        });
        peer
    }
    fn reply(value: Value) -> Response<Full<Bytes>> {
        Response::new(Full::new(Bytes::from(value.to_string())))
    }
    async fn handle(
        self: Arc<Self>,
        request: Request<Incoming>,
    ) -> Result<Response<Full<Bytes>>, io::Error> {
        let path = request.uri().path().to_owned();
        let query: HashMap<String, String> =
            form_urlencoded::parse(request.uri().query().unwrap_or("").as_bytes())
                .into_owned()
                .collect();
        let file = query.get("fileId").cloned().unwrap_or_default();
        let operation = path.rsplit('/').next().unwrap().to_owned();
        let offset = query.get("offset").map(|v| v.parse::<u64>().unwrap());
        assert_eq!(
            query.get("sessionId").map(String::as_str),
            Some("approved-session")
        );
        if operation != "cancel" {
            assert_eq!(query.get("token").map(String::as_str), Some("file-token"));
        }
        let block_hash = request
            .headers()
            .get("x-legnasend-block-sha256")
            .map(|v| v.to_str().unwrap().to_owned());
        let body = request
            .into_body()
            .collect()
            .await
            .map_err(io::Error::other)?
            .to_bytes();
        let mut state = self.state.lock().unwrap();
        state.calls.push((operation.clone(), file.clone(), offset));
        if operation == "capabilities" {
            if matches!(self.mode, Mode::Legacy | Mode::LegacyGone) {
                return Ok(Response::builder()
                    .status(404)
                    .body(Full::new(Bytes::new()))
                    .unwrap());
            }
            if let Some(bytes) = &self.cap_replacement {
                std::fs::write(&self.source, bytes).unwrap();
            }
            if self.mode == Mode::WrongToken {
                return Ok(Response::builder()
                    .status(403)
                    .body(Full::new(Bytes::from_static(b"invalid token")))
                    .unwrap());
            }
            let mut cap = json!({"version":1,"supported":true,"blockSize":BLOCK});
            if matches!(
                self.mode,
                Mode::DurableVerify
                    | Mode::DurableSuspend
                    | Mode::DurableSuspendLost
                    | Mode::DurableAuth
                    | Mode::DurableMissing
            ) {
                cap["durable"] = json!({"version":1});
            }
            return Ok(Self::reply(cap));
        }
        if operation == "upload" && self.mode == Mode::LegacyGone {
            return Ok(Response::builder()
                .status(410)
                .body(Full::new(Bytes::from_static(b"arbitrary legacy text")))
                .unwrap());
        }
        if operation == "upload" {
            assert_eq!(path, "/api/localsend/v2/upload");
            state.data.insert(file, body.to_vec());
            return Ok(Self::reply(json!({})));
        }
        if operation == "status" && self.mode == Mode::DropSecond && !state.status_busy_sent {
            state.status_busy_sent = true;
            return Ok(Response::builder()
                .status(409)
                .body(Full::new(Bytes::new()))
                .unwrap());
        }
        if operation == "abort" {
            return Ok(Self::reply(json!({"aborted":true})));
        }
        if operation == "cancel" {
            panic!("Sender canceled unrelated session files");
        }
        if operation == "open" {
            let value: Value = serde_json::from_slice(&body).unwrap();
            state.opened.insert(file.clone(), value);
            if self.mode == Mode::DurableVerify {
                self.block_seen.notify_one();
            }
        } else {
            assert_eq!(query.get("resumeId").map(String::as_str), Some(RID));
        }
        if matches!(self.mode, Mode::DurableSuspend | Mode::DurableSuspendLost)
            && matches!(operation.as_str(), "block" | "status")
        {
            return Err(io::Error::other("Temporary disconnected transport"));
        }
        if operation == "suspend" && self.mode == Mode::DurableSuspendLost {
            return Err(io::Error::other("Suspend committed but reply lost"));
        }
        if operation == "block" && matches!(self.mode, Mode::DurableAuth | Mode::DurableMissing) {
            return Ok(Response::builder()
                .status(if self.mode == Mode::DurableAuth {
                    403
                } else {
                    410
                })
                .body(Full::new(Bytes::from_static(
                    b"not a typed source-ended reason",
                )))
                .unwrap());
        }
        if operation == "block" {
            assert_eq!(block_hash.unwrap(), hash(&body));
            let data = state.data.entry(file.clone()).or_default();
            assert_eq!(
                offset.unwrap() as usize,
                data.len(),
                "No committed block may be sent twice"
            );
            data.extend_from_slice(&body);
            if self.mode == Mode::DropSecond && offset == Some(BLOCK as u64) && !state.dropped {
                state.dropped = true;
                return Err(io::Error::other(
                    "Commit succeeded; connection lost before receipt",
                ));
            }
            if self.mode == Mode::ChangeSource && offset == Some(0) {
                let output = std::fs::OpenOptions::new()
                    .write(true)
                    .open(&self.source)
                    .unwrap();
                output.set_len(7).unwrap();
            }
            if self.mode == Mode::PauseA && file == "a" {
                self.block_seen.notify_one();
                // Lose this file's response after commit. The test cancels
                // during reconciliation while the sibling remains independent.
                return Err(io::Error::other("Pause file a before receipt"));
            }
        }
        let open = &state.opened[&file];
        let size = open["size"].as_u64().unwrap();
        let current = state.data.get(&file).map_or(0, Vec::len) as u64;
        if operation == "finish" {
            assert_eq!(current, size);
            assert_eq!(hash(&state.data[&file]), open["sha256"].as_str().unwrap());
        }
        Ok(Self::reply(
            json!({"version":1,"resumeId":RID,"blockSize":BLOCK,"size":size,"sha256":open["sha256"],"offset":if self.mode==Mode::InvalidOffset {1} else {current},"state":if operation=="finish" {"complete"} else if operation=="suspend" {"suspended"} else if self.mode==Mode::DurableVerify && (operation=="open" || (operation=="status" && state.calls.iter().filter(|c|c.0=="status").count()<4)) {"verifying"} else {"receiving"},"verifiedBytes":0}),
        ))
    }
    fn operations(&self) -> Vec<String> {
        self.state
            .lock()
            .unwrap()
            .calls
            .iter()
            .map(|v| v.0.clone())
            .collect()
    }
}
struct Input {
    path: PathBuf,
    bytes: Vec<u8>,
}
impl Input {
    fn new(size: usize) -> Self {
        let path =
            std::env::temp_dir().join(format!("legnasend-native-resume-{}", uuid::Uuid::new_v4()));
        let bytes: Vec<_> = (0..size).map(|i| (i % 251) as u8).collect();
        std::fs::write(&path, &bytes).unwrap();
        Self { path, bytes }
    }
}
impl Drop for Input {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.path);
    }
}
async fn send(
    peer: &Peer,
    path: PathBuf,
    file: &str,
    cancel: CancellationToken,
) -> Result<(), ClientError> {
    let client = LsHttpClient::V2(LsHttpClientV2::try_new_without_cert().unwrap());
    tokio::time::timeout(
        Duration::from_secs(15),
        client.upload(
            ProtocolType::Http,
            "127.0.0.1",
            peer.port,
            None,
            "approved-session",
            file,
            "file-token",
            FileContent::Path(path),
            |_| {},
            cancel,
        ),
    )
    .await
    .expect("bounded sender completion")
}
#[tokio::test]
async fn original_404_keeps_original_v2_body_and_small_files_skip_capability() {
    for size in [32768, BLOCK + 17] {
        let input = Input::new(size);
        let peer = Peer::start(Mode::Legacy, input.path.clone(), None).await;
        send(&peer, input.path.clone(), "a", CancellationToken::new())
            .await
            .unwrap();
        assert_eq!(peer.state.lock().unwrap().data["a"], input.bytes);
        assert_eq!(
            peer.operations(),
            if size < BLOCK {
                vec!["upload"]
            } else {
                vec!["capabilities", "upload"]
            }
        );
    }
}
#[tokio::test]
async fn capability_precedes_content_hash_and_resume_open() {
    let input = Input::new(BLOCK + 17);
    let peer = Peer::start(Mode::Normal, input.path.clone(), None).await;
    send(&peer, input.path.clone(), "a", CancellationToken::new())
        .await
        .unwrap();
    let state = peer.state.lock().unwrap();
    assert_eq!(state.calls[0].0, "capabilities");
    assert_eq!(state.calls[1].0, "open");
    assert_eq!(state.opened["a"]["sha256"], hash(&input.bytes));
    assert_eq!(state.opened["a"]["size"], input.bytes.len());
    assert_eq!(state.data["a"], input.bytes);
    drop(state);
    // The metadata snapshot is held before probing. Capability cannot silently
    // rebind a previously approved source to changed bytes.
    let changed = Peer::start(
        Mode::Normal,
        input.path.clone(),
        Some(vec![191; input.bytes.len() + 1]),
    )
    .await;
    assert!(
        send(&changed, input.path.clone(), "a", CancellationToken::new())
            .await
            .is_err()
    );
    assert_eq!(changed.operations(), vec!["capabilities"]);
}
#[tokio::test]
async fn lost_second_receipt_queries_status_then_sends_only_uncommitted_bytes() {
    let input = Input::new(3 * BLOCK + 17);
    let peer = Peer::start(Mode::DropSecond, input.path.clone(), None).await;
    send(&peer, input.path.clone(), "a", CancellationToken::new())
        .await
        .unwrap();
    let state = peer.state.lock().unwrap();
    assert_eq!(state.data["a"], input.bytes);
    assert_eq!(
        state
            .calls
            .iter()
            .filter(|c| c.0 == "block")
            .map(|c| c.2.unwrap())
            .collect::<Vec<_>>(),
        vec![0, BLOCK as u64, 2 * BLOCK as u64, 3 * BLOCK as u64]
    );
    assert_eq!(state.calls.iter().filter(|c| c.0 == "status").count(), 2);
    assert!(state.status_busy_sent);
}
#[tokio::test]
async fn invalid_token_offset_and_changed_source_never_fall_back_to_whole_file() {
    for mode in [Mode::WrongToken, Mode::InvalidOffset, Mode::ChangeSource] {
        let input = Input::new(2 * BLOCK + 17);
        let peer = Peer::start(mode, input.path.clone(), None).await;
        assert!(
            send(&peer, input.path.clone(), "a", CancellationToken::new())
                .await
                .is_err()
        );
        assert!(
            !peer
                .operations()
                .iter()
                .any(|v| v == "upload" || v == "cancel")
        );
        if mode == Mode::ChangeSource {
            assert!(peer.operations().iter().any(|v| v == "abort"));
        }
    }
}
#[tokio::test]
async fn cancel_aborts_only_one_file_and_keeps_other_file_transfer_alive() {
    let input = Input::new(2 * BLOCK + 17);
    let peer = Peer::start(Mode::PauseA, input.path.clone(), None).await;
    let cancel = CancellationToken::new();
    let a = peer.clone();
    let path = input.path.clone();
    let token = cancel.clone();
    let task = tokio::spawn(async move { send(&a, path, "a", token).await });
    tokio::time::timeout(Duration::from_secs(4), peer.block_seen.notified())
        .await
        .unwrap();
    cancel.cancel();
    send(&peer, input.path.clone(), "b", CancellationToken::new())
        .await
        .unwrap();
    assert!(matches!(task.await.unwrap(), Err(ClientError::Cancelled)));
    let state = peer.state.lock().unwrap();
    assert_eq!(state.data["b"], input.bytes);
    assert_eq!(
        state
            .calls
            .iter()
            .filter(|c| c.0 == "abort")
            .map(|c| c.1.as_str())
            .collect::<Vec<_>>(),
        vec!["a"]
    );
    assert!(!state.calls.iter().any(|c| c.0 == "cancel"));
}

#[tokio::test]
async fn durable_verification_polls_independently_and_only_negotiated_open_carries_key() {
    for mode in [Mode::Normal, Mode::DurableVerify] {
        let input = Input::new(BLOCK + 13);
        let peer = Peer::start(mode, input.path.clone(), None).await;
        let client = LsHttpClient::V2(LsHttpClientV2::try_new_without_cert().unwrap());
        let checks = Arc::new(Mutex::new(Vec::new()));
        let observed = checks.clone();
        client
            .upload_with_recovery(
                ProtocolType::Http,
                "127.0.0.1",
                peer.port,
                None,
                "approved-session",
                "a",
                "file-token",
                FileContent::Path(input.path.clone()),
                Some(RID.into()),
                |_| {},
                move |verified, total| observed.lock().unwrap().push((verified, total)),
                CancellationToken::new(),
            )
            .await
            .unwrap();
        let state = peer.state.lock().unwrap();
        assert_eq!(state.data["a"], input.bytes);
        if mode == Mode::Normal {
            assert!(state.opened["a"].get("recovery").is_none());
            assert!(checks.lock().unwrap().is_empty());
        } else {
            assert_eq!(
                state.opened["a"]["recovery"],
                json!({"version":1,"resumeKey":RID})
            );
            assert!(checks.lock().unwrap().len() >= 4);
        }
        assert!(
            !state
                .calls
                .iter()
                .any(|c| c.0 == "abort" || c.0 == "cancel")
        );
    }
}

#[tokio::test]
async fn durable_transport_exhaustion_suspends_without_abort_and_reports_ack_certainty() {
    for mode in [Mode::DurableSuspend, Mode::DurableSuspendLost] {
        let input = Input::new(BLOCK + 7);
        let peer = Peer::start(mode, input.path.clone(), None).await;
        let client = LsHttpClient::V2(LsHttpClientV2::try_new_without_cert().unwrap());
        let phases = Arc::new(Mutex::new(Vec::new()));
        let observed = phases.clone();
        let result = client
            .upload_with_recovery_events(
                ProtocolType::Http,
                "127.0.0.1",
                peer.port,
                None,
                "approved-session",
                "a",
                "file-token",
                FileContent::Path(input.path.clone()),
                Some(RID.into()),
                |_| {},
                |_, _| {},
                move |phase| observed.lock().unwrap().push(phase),
                CancellationToken::new(),
            )
            .await;
        assert!(
            matches!(result,Err(ClientError::ResumeInterrupted{retained_confirmed}) if retained_confirmed == (mode==Mode::DurableSuspend))
        );
        let phases = phases.lock().unwrap();
        assert_eq!(phases.len(), 6);
        for (i, pair) in phases.chunks(2).enumerate() {
            assert!(pair[0].waiting);
            assert_eq!(pair[0].attempt, (i + 1) as u8);
            assert_eq!(pair[0].retry_after_ms, 1000u32 << i);
            assert!(!pair[1].waiting);
            assert_eq!(pair[1].attempt, (i + 1) as u8);
            assert_eq!(pair[1].retry_after_ms, 0);
        }
        assert_eq!(
            peer.operations().iter().filter(|c| *c == "suspend").count(),
            1
        );
        assert!(
            !peer
                .operations()
                .iter()
                .any(|c| c == "abort" || c == "cancel")
        );
    }
}

#[tokio::test]
async fn explicit_cancel_during_durable_verification_aborts_instead_of_suspending() {
    let input = Input::new(BLOCK + 5);
    let peer = Peer::start(Mode::DurableVerify, input.path.clone(), None).await;
    let cancel = CancellationToken::new();
    let token = cancel.clone();
    let target = peer.clone();
    let path = input.path.clone();
    let upload = tokio::spawn(async move {
        LsHttpClient::V2(LsHttpClientV2::try_new_without_cert().unwrap())
            .upload_with_recovery(
                ProtocolType::Http,
                "127.0.0.1",
                target.port,
                None,
                "approved-session",
                "a",
                "file-token",
                FileContent::Path(path),
                Some(RID.into()),
                |_| {},
                |_, _| {},
                token,
            )
            .await
    });
    tokio::time::timeout(Duration::from_secs(4), peer.block_seen.notified())
        .await
        .unwrap();
    // Wait until the open response has reached the verification loop, so the
    // client owns the returned resume identity before cancellation.
    tokio::time::sleep(Duration::from_millis(50)).await;
    cancel.cancel();
    assert!(matches!(upload.await.unwrap(), Err(ClientError::Cancelled)));
    assert!(peer.operations().iter().any(|op| op == "abort"));
    assert!(!peer.operations().iter().any(|op| op == "suspend"));
}

#[tokio::test]
async fn typed_auth_http_unknown_and_source_change_do_not_invent_remote_source_termination() {
    use localsend::http::client::{RecoveryFailureKind as Kind, RecoveryRetention as Retention};
    for (mode, kind, status) in [
        (Mode::DurableAuth, Kind::AuthorizationRequired, 403),
        (Mode::DurableMissing, Kind::Retryable, 410),
    ] {
        let input = Input::new(BLOCK + 7);
        let peer = Peer::start(mode, input.path.clone(), None).await;
        let result = LsHttpClient::V2(LsHttpClientV2::try_new_without_cert().unwrap())
            .upload_with_recovery(
                ProtocolType::Http,
                "127.0.0.1",
                peer.port,
                None,
                "approved-session",
                "a",
                "file-token",
                FileContent::Path(input.path.clone()),
                Some(RID.into()),
                |_| {},
                |_, _| {},
                CancellationToken::new(),
            )
            .await;
        assert!(
            matches!(result,Err(ClientError::Recovery{kind:k,retention:Retention::Unknown,status:Some(s)}) if k==kind && s==status)
        );
        assert!(
            !peer
                .operations()
                .iter()
                .any(|op| op == "abort" || op == "cancel")
        );
    }
    let input = Input::new(BLOCK + 7);
    let peer = Peer::start(Mode::LegacyGone, input.path.clone(), None).await;
    let result = send(&peer, input.path.clone(), "a", CancellationToken::new()).await;
    assert!(matches!(
        result,
        Err(ClientError::Recovery {
            kind: Kind::Retryable,
            retention: Retention::NotRetained,
            status: Some(410)
        })
    ));
    assert_eq!(peer.operations(), vec!["capabilities", "upload"]);
    let input = Input::new(2 * BLOCK + 7);
    let peer = Peer::start(Mode::ChangeSource, input.path.clone(), None).await;
    let result = send(&peer, input.path.clone(), "a", CancellationToken::new()).await;
    assert!(matches!(
        result,
        Err(ClientError::Recovery {
            kind: Kind::SourceChanged,
            ..
        })
    ));
    assert!(peer.operations().iter().any(|op| op == "abort"));
}

#[tokio::test]
async fn optional_source_end_negotiation_reports_legacy_without_changing_upload_wire() {
    use localsend::http::source_end::SourceEndEvent;
    let input = Input::new(BLOCK + 19);
    let peer = Peer::start(Mode::Legacy, input.path.clone(), None).await;
    let unavailable = Arc::new(std::sync::atomic::AtomicUsize::new(0));
    let observed = unavailable.clone();
    let client = LsHttpClient::V2(LsHttpClientV2::try_new_without_cert().unwrap());
    client
        .upload_with_source_end(
            ProtocolType::Http,
            "127.0.0.1",
            peer.port,
            None,
            "approved-session",
            "a",
            "file-token",
            FileContent::Path(input.path.clone()),
            Some(uuid::Uuid::new_v4().to_string()),
            |_| {},
            |_, _| {},
            |_| {},
            Some(Arc::new(move |event| match event {
                SourceEndEvent::Unavailable => {
                    observed.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
                }
                SourceEndEvent::Grant { .. } => panic!("legacy did not issue authority"),
            })),
            CancellationToken::new(),
        )
        .await
        .unwrap();
    assert_eq!(unavailable.load(std::sync::atomic::Ordering::SeqCst), 1);
    assert_eq!(peer.operations(), vec!["capabilities", "upload"]);
    assert_eq!(peer.state.lock().unwrap().data["a"], input.bytes);
}
