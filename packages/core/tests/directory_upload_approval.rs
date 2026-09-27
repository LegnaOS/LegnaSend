#![cfg(feature = "http")]
use localsend::http::{
    server::{start_with_port, v2::ServerEventV2, web::WebConfig, ServerConfigV2, ServerHandle},
    state::ClientInfo,
};
use serde_json::{json, Value};
use std::{path::PathBuf, time::Duration};
use tokio::sync::{mpsc, oneshot};
const ID: &str = "11111111-1111-4111-8111-111111111111";
struct Fixture {
    server: ServerHandle,
    client: reqwest::Client,
    temp: PathBuf,
    events: mpsc::Receiver<ServerEventV2>,
    stop: Option<oneshot::Sender<()>>,
}
impl Fixture {
    async fn new() -> Self {
        let temp =
            std::env::temp_dir().join(format!("legnasend-approval-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&temp).unwrap();
        let (tx, events) = mpsc::channel(32);
        let (stop, rx) = oneshot::channel();
        let server = start_with_port(
            0,
            None,
            ClientInfo {
                alias: "approval".into(),
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
            rx,
        )
        .await
        .unwrap();
        let f = Self {
            server,
            client: reqwest::Client::builder()
                .no_proxy()
                .timeout(Duration::from_secs(30))
                .build()
                .unwrap(),
            temp,
            events,
            stop: Some(stop),
        };
        f.configure(1, true).await;
        f
    }
    async fn configure(&self, generation: u64, allow: bool) {
        self.server.configure_directory_workspaces(&json!({"revision":generation,"enabled":true,"workspaces":[{"id":ID,"name":"Approval","slug":"approval","root":self.temp,"visible":true,"generation":generation,"allowUpload":allow,"uploadApproval":true}]}).to_string()).await.unwrap();
    }
    fn url(&self, path: &str) -> String {
        format!(
            "http://127.0.0.1:{}/api/legnasend/v1/workspaces/{ID}/{path}",
            self.server.port()
        )
    }
    fn prepare(&self, id: &str, files: Value) -> reqwest::RequestBuilder {
        self.client
            .post(self.url("prepare-upload"))
            .header("x-legnasend-upload", "1")
            .json(&json!({"requestId":id,"generation":1,"files":files}))
    }
    fn upload(&self, path: &str, bytes: &str, token: Option<&str>) -> reqwest::RequestBuilder {
        let q = form_urlencoded::Serializer::new(String::new())
            .append_pair("generation", "1")
            .append_pair("path", path)
            .append_pair("directory", "false")
            .finish();
        let mut r = self
            .client
            .post(self.url(&format!("upload?{q}")))
            .header("x-legnasend-upload", "1")
            .header("content-type", "application/octet-stream")
            .body(bytes.to_owned());
        if let Some(t) = token {
            r = r.header("x-legnasend-upload-token", t)
        }
        r
    }
    async fn decision(&mut self) -> (String, Value, oneshot::Sender<bool>) {
        loop {
            match tokio::time::timeout(Duration::from_secs(3), self.events.recv())
                .await
                .unwrap()
                .unwrap()
            {
                ServerEventV2::DirectoryUploadApproval {
                    request_id,
                    request,
                    decision_tx,
                } => {
                    return (
                        request_id,
                        serde_json::from_str(&request).unwrap(),
                        decision_tx,
                    )
                }
                _ => {}
            }
        }
    }
    async fn finish(mut self) {
        let _ = self.stop.take().unwrap().send(());
        self.server.wait_stopped().await;
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.temp);
    }
}
fn manifest(path: &str) -> Value {
    json!([{"path":path,"size":4,"directory":false}])
}
#[tokio::test]
async fn exact_batch_acceptance_is_required_and_token_is_single_use() {
    let mut f = Fixture::new().await;
    assert_eq!(
        f.upload("folder/file.txt", "data", None)
            .send()
            .await
            .unwrap()
            .status(),
        428
    );
    let id = uuid::Uuid::new_v4().to_string();
    let req = f.prepare(&id, manifest("folder/file.txt"));
    let pending = tokio::spawn(async move { req.send().await.unwrap() });
    let (actual, detail, decision) = f.decision().await;
    assert_ne!(actual, id);
    assert_eq!(detail["requestId"], actual);
    assert!(uuid::Uuid::parse_str(&actual).is_ok());
    assert_eq!(detail["files"], manifest("folder/file.txt"));
    assert_eq!(detail["workspaceName"], "Approval");
    assert!(!detail.to_string().contains(f.temp.to_str().unwrap()));
    assert!(!f.temp.join("folder/file.txt").exists());
    decision.send(true).unwrap();
    let response = pending.await.unwrap();
    assert_eq!(response.status(), 200);
    let body: Value = response.json().await.unwrap();
    let token = body["token"].as_str().unwrap();
    assert_eq!(token.len(), 64);
    assert_eq!(
        f.upload("folder/other.txt", "data", Some(token))
            .send()
            .await
            .unwrap()
            .status(),
        428
    );
    assert_eq!(
        f.upload("folder/file.txt", "bad", Some(token))
            .send()
            .await
            .unwrap()
            .status(),
        428
    );
    assert_eq!(
        f.upload("folder/file.txt", "data", Some(token))
            .header("cookie", "changed=1")
            .send()
            .await
            .unwrap()
            .status(),
        428
    );
    assert!(f
        .upload("folder/file.txt", "data", Some(token))
        .send()
        .await
        .unwrap()
        .status()
        .is_success());
    assert_eq!(
        std::fs::read(f.temp.join("folder/file.txt")).unwrap(),
        b"data"
    );
    assert_eq!(
        f.upload("folder/file.txt", "data", Some(token))
            .send()
            .await
            .unwrap()
            .status(),
        428
    );
    f.finish().await;
}
#[tokio::test]
async fn rejection_cancel_and_workspace_change_prevent_writes_and_late_decisions() {
    let mut f = Fixture::new().await;
    for mode in ["reject", "cancel", "change"] {
        let id = uuid::Uuid::new_v4().to_string();
        let req = f.prepare(&id, manifest("x"));
        let pending = tokio::spawn(async move { req.send().await.unwrap() });
        let (_, _, decision) = f.decision().await;
        let expected = match mode {
            "reject" => {
                decision.send(false).unwrap();
                403
            }
            "cancel" => {
                assert_eq!(
                    f.client
                        .post(f.url("cancel-upload-approval"))
                        .header("x-legnasend-upload", "1")
                        .json(&json!({"requestId":id,"generation":1}))
                        .send()
                        .await
                        .unwrap()
                        .status(),
                    200
                );
                tokio::time::timeout(Duration::from_secs(2), async {
                    while !decision.is_closed() {
                        tokio::task::yield_now().await;
                    }
                })
                .await
                .unwrap();
                assert!(decision.send(true).is_err());
                409
            }
            _ => {
                f.configure(2, false).await;
                tokio::time::timeout(Duration::from_secs(2), async {
                    while !decision.is_closed() {
                        tokio::task::yield_now().await;
                    }
                })
                .await
                .unwrap();
                assert!(decision.send(true).is_err());
                409
            }
        };
        assert_eq!(pending.await.unwrap().status(), expected);
        assert!(!f.temp.join("x").exists());
    }
    f.finish().await;
}
#[tokio::test]
async fn five_thousand_files_need_one_decision_and_cancellation_revokes_approved_remainder() {
    let mut f = Fixture::new().await;
    let id = uuid::Uuid::new_v4().to_string();
    let files: Vec<_> = (0..5000)
        .map(|i| json!({"path":format!("tree/{i}"),"size":4,"directory":false}))
        .collect();
    let req = f.prepare(&id, json!(files));
    let pending = tokio::spawn(async move { req.send().await.unwrap() });
    let (_, detail, decision) = f.decision().await;
    assert_eq!(detail["files"].as_array().unwrap().len(), 5000);
    decision.send(true).unwrap();
    let body: Value = pending.await.unwrap().json().await.unwrap();
    assert_eq!(body["fileCount"], 5000);
    assert_eq!(body["totalBytes"], 20000);
    let token = body["token"].as_str().unwrap();
    assert!(f
        .upload("tree/0", "data", Some(token))
        .send()
        .await
        .unwrap()
        .status()
        .is_success());
    assert_eq!(
        f.client
            .post(f.url("cancel-upload-approval"))
            .header("x-legnasend-upload", "1")
            .json(&json!({"requestId":id,"generation":1}))
            .send()
            .await
            .unwrap()
            .status(),
        200
    );
    assert_eq!(
        f.upload("tree/1", "data", Some(token))
            .send()
            .await
            .unwrap()
            .status(),
        428
    );
    assert!(!f.temp.join("tree/1").exists());
    f.finish().await;
}
#[tokio::test]
async fn malformed_manifests_and_cross_origin_requests_never_reach_host() {
    let mut f = Fixture::new().await;
    for files in [
        json!([]),
        json!([{"path":"../escape","size":4,"directory":false}]),
        json!([{"path":"x","size":4,"directory":true}]),
        json!([{"path":"x","size":4,"directory":false},{"path":"x","size":4,"directory":false}]),
        json!([{"path":"x","size":9007199254740992u64,"directory":false}]),
    ] {
        assert_eq!(
            f.prepare(&uuid::Uuid::new_v4().to_string(), files)
                .send()
                .await
                .unwrap()
                .status(),
            400
        );
    }
    assert_eq!(
        f.prepare(&uuid::Uuid::new_v4().to_string(), manifest("x"))
            .header("origin", "http://foreign.invalid")
            .send()
            .await
            .unwrap()
            .status(),
        403
    );
    assert!(f.events.try_recv().is_err());
    f.finish().await;
}
#[tokio::test]
async fn changing_generation_revokes_existing_approval_without_disabling_native_info() {
    let mut f = Fixture::new().await;
    let req = f.prepare(&uuid::Uuid::new_v4().to_string(), manifest("x"));
    let pending = tokio::spawn(async move { req.send().await.unwrap() });
    let (_, _, decision) = f.decision().await;
    decision.send(true).unwrap();
    let body: Value = pending.await.unwrap().json().await.unwrap();
    f.configure(2, true).await;
    let req = f
        .client
        .post(f.url("upload?generation=2&path=x&directory=false"))
        .header("x-legnasend-upload", "1")
        .header("x-legnasend-upload-token", body["token"].as_str().unwrap())
        .header("content-type", "application/octet-stream")
        .body("data");
    assert_eq!(req.send().await.unwrap().status(), 428);
    assert_eq!(
        f.client
            .get(format!(
                "http://127.0.0.1:{}/api/localsend/v2/info",
                f.server.port()
            ))
            .send()
            .await
            .unwrap()
            .status(),
        200
    );
    assert!(!f.temp.join("x").exists());
    f.finish().await;
}

#[tokio::test]
async fn original_sixty_second_approval_deadline_expires_and_releases_the_slot() {
    let mut f = Fixture::new().await;
    f.client = reqwest::Client::builder()
        .no_proxy()
        .timeout(Duration::from_secs(90))
        .build()
        .unwrap();
    let id = uuid::Uuid::new_v4().to_string();
    let request = f.prepare(&id, manifest("deadline.txt"));
    let pending = tokio::spawn(async move { request.send().await.unwrap() });
    let (_, detail, decision) = f.decision().await;
    let expires = detail["expiresAt"].as_u64().unwrap();
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_millis() as u64;
    assert!(expires >= now + 50_000 && expires <= now + 60_000);
    tokio::time::pause();
    tokio::time::advance(Duration::from_secs(61)).await;
    for _ in 0..10 {
        tokio::task::yield_now().await;
    }
    tokio::time::resume();
    assert_eq!(pending.await.unwrap().status(), 408);
    assert!(decision.send(true).is_err());
    assert!(!f.temp.join("deadline.txt").exists());
    let request = f.prepare(
        &uuid::Uuid::new_v4().to_string(),
        manifest("after-deadline.txt"),
    );
    let next = tokio::spawn(async move { request.send().await.unwrap() });
    let (_, _, decision) = f.decision().await;
    decision.send(false).unwrap();
    assert_eq!(next.await.unwrap().status(), 403);
    f.finish().await;
}

#[tokio::test]
async fn full_pending_workspace_still_accepts_cancellation_and_recovers_capacity() {
    let mut f = Fixture::new().await;
    let mut pending = vec![];
    let mut decisions = vec![];
    let mut ids = vec![];
    for n in 0..2 {
        let id = uuid::Uuid::new_v4().to_string();
        let request = f.prepare(&id, manifest(&format!("file{n}")));
        pending.push(tokio::spawn(async move { request.send().await.unwrap() }));
        let (_, _, decision) = f.decision().await;
        decisions.push(decision);
        ids.push(id);
    }
    assert_eq!(
        f.prepare(&uuid::Uuid::new_v4().to_string(), manifest("overflow"))
            .send()
            .await
            .unwrap()
            .status(),
        429
    );
    let cancel = f
        .client
        .post(f.url("cancel-upload-approval"))
        .header("x-legnasend-upload", "1")
        .json(&json!({"requestId":ids[0],"generation":1}))
        .send()
        .await
        .unwrap();
    assert_eq!(cancel.status(), 200);
    assert_eq!(pending.remove(0).await.unwrap().status(), 409);
    assert!(decisions.remove(0).send(true).is_err());
    let request = f.prepare(&uuid::Uuid::new_v4().to_string(), manifest("replacement"));
    let replacement = tokio::spawn(async move { request.send().await.unwrap() });
    let (_, _, decision) = f.decision().await;
    decision.send(false).unwrap();
    assert_eq!(replacement.await.unwrap().status(), 403);
    decisions.remove(0).send(false).unwrap();
    assert_eq!(pending.remove(0).await.unwrap().status(), 403);
    assert_eq!(std::fs::read_dir(&f.temp).unwrap().count(), 0);
    f.finish().await;
}

#[tokio::test]
async fn missing_host_responder_and_closed_event_receiver_fail_without_stuck_pending() {
    let mut f = Fixture::new().await;
    for _ in 0..3 {
        let request = f.prepare(&uuid::Uuid::new_v4().to_string(), manifest("no-host"));
        let pending = tokio::spawn(async move { request.send().await.unwrap() });
        let (_, _, decision) = f.decision().await;
        drop(decision);
        assert_eq!(pending.await.unwrap().status(), 503);
    }
    f.events.close();
    for _ in 0..3 {
        assert_eq!(
            f.prepare(
                &uuid::Uuid::new_v4().to_string(),
                manifest("closed-channel")
            )
            .send()
            .await
            .unwrap()
            .status(),
            503
        );
    }
    assert_eq!(std::fs::read_dir(&f.temp).unwrap().count(), 0);
    f.finish().await;
}

#[tokio::test]
async fn removing_workspace_aborts_pending_approval_and_late_acceptance_cannot_republish() {
    let mut f = Fixture::new().await;
    let request = f.prepare(&uuid::Uuid::new_v4().to_string(), manifest("removed"));
    let pending = tokio::spawn(async move { request.send().await.unwrap() });
    let (_, _, decision) = f.decision().await;
    f.server
        .configure_directory_workspaces(
            &json!({"revision":2,"enabled":true,"workspaces":[]}).to_string(),
        )
        .await
        .unwrap();
    assert_eq!(pending.await.unwrap().status(), 409);
    assert!(decision.send(true).is_err());
    assert_eq!(
        f.upload("removed", "data", None)
            .send()
            .await
            .unwrap()
            .status(),
        404
    );
    assert_eq!(std::fs::read_dir(&f.temp).unwrap().count(), 0);
    f.finish().await;
}

#[tokio::test]
async fn password_logout_revokes_pending_and_previously_approved_browser_batches() {
    let mut f = Fixture::new().await;
    let hash =
        localsend::http::server::directory_auth::hash_password("password-for-approval".into())
            .await
            .unwrap();
    f.server.configure_directory_workspaces(&json!({"revision":2,"enabled":true,"workspaces":[{"id":ID,"name":"Approval","slug":"approval","root":f.temp,"visible":true,"generation":2,"allowUpload":true,"uploadApproval":true,"passwordHash":hash}]}).to_string()).await.unwrap();
    let login = f
        .client
        .post(f.url("unlock"))
        .json(&json!({"generation":2,"password":"password-for-approval"}))
        .send()
        .await
        .unwrap();
    assert_eq!(login.status(), 200);
    let cookie = login.headers()["set-cookie"]
        .to_str()
        .unwrap()
        .split(';')
        .next()
        .unwrap()
        .to_owned();
    let prepare = |id: String, path: &str| {
        f.client
            .post(f.url("prepare-upload"))
            .header("x-legnasend-upload", "1")
            .header("cookie", &cookie)
            .json(&json!({"requestId":id,"generation":2,"files":manifest(path)}))
    };
    let request = prepare(uuid::Uuid::new_v4().to_string(), "approved");
    let approved = tokio::spawn(async move { request.send().await.unwrap() });
    let (_, _, decision) = f.decision().await;
    decision.send(true).unwrap();
    let token: Value = approved.await.unwrap().json().await.unwrap();
    let request=f.client.post(f.url("prepare-upload")).header("x-legnasend-upload","1").header("cookie",&cookie)
        .json(&json!({"requestId":uuid::Uuid::new_v4().to_string(),"generation":2,"files":manifest("pending")}));
    let pending = tokio::spawn(async move { request.send().await.unwrap() });
    let (_, _, decision) = f.decision().await;
    let logout = f
        .client
        .post(f.url("logout"))
        .header("cookie", &cookie)
        .json(&json!({}))
        .send()
        .await
        .unwrap();
    assert_eq!(logout.status(), 200);
    assert_eq!(pending.await.unwrap().status(), 401);
    assert!(decision.send(true).is_err());
    let upload = f
        .client
        .post(f.url("upload?generation=2&path=approved&directory=false"))
        .header("x-legnasend-upload", "1")
        .header("cookie", &cookie)
        .header("x-legnasend-upload-token", token["token"].as_str().unwrap())
        .header("content-type", "application/octet-stream")
        .body("data")
        .send()
        .await
        .unwrap();
    assert_eq!(upload.status(), 401);
    assert_eq!(std::fs::read_dir(&f.temp).unwrap().count(), 0);
    f.finish().await;
}

#[tokio::test]
async fn disconnected_prepare_drops_prompt_and_late_decision_without_consuming_capacity() {
    use tokio::io::AsyncWriteExt;
    let mut f = Fixture::new().await;
    let id = uuid::Uuid::new_v4().to_string();
    let payload =
        json!({"requestId":id,"generation":1,"files":manifest("disconnected")}).to_string();
    let mut socket = tokio::net::TcpStream::connect(("127.0.0.1", f.server.port()))
        .await
        .unwrap();
    let request=format!("POST /api/legnasend/v1/workspaces/{ID}/prepare-upload HTTP/1.1\r\nHost: 127.0.0.1:{}\r\nX-LegnaSend-Upload: 1\r\nContent-Type: application/json\r\nContent-Length: {}\r\n\r\n{payload}",f.server.port(),payload.len());
    socket.write_all(request.as_bytes()).await.unwrap();
    let (_, _, decision) = f.decision().await;
    drop(socket);
    tokio::time::timeout(Duration::from_secs(2), async {
        while !decision.is_closed() {
            tokio::task::yield_now().await;
        }
    })
    .await
    .unwrap();
    assert!(decision.send(true).is_err());
    let request = f.prepare(&uuid::Uuid::new_v4().to_string(), manifest("later"));
    let pending = tokio::spawn(async move { request.send().await.unwrap() });
    let (_, _, decision) = f.decision().await;
    decision.send(false).unwrap();
    assert_eq!(pending.await.unwrap().status(), 403);
    assert_eq!(std::fs::read_dir(&f.temp).unwrap().count(), 0);
    f.finish().await;
}

#[tokio::test]
async fn equal_client_request_ids_in_different_workspaces_have_isolated_host_prompts() {
    const SECOND: &str = "22222222-2222-4222-8222-222222222222";
    let mut f = Fixture::new().await;
    f.server.configure_directory_workspaces(&json!({"revision":2,"enabled":true,"workspaces":[
        {"id":ID,"name":"Approval","slug":"approval","root":f.temp,"visible":true,"generation":1,"allowUpload":true,"uploadApproval":true},
        {"id":SECOND,"name":"Second","slug":"second","root":f.temp,"visible":true,"generation":1,"allowUpload":true,"uploadApproval":true}
    ]}).to_string()).await.unwrap();
    let client_id = uuid::Uuid::new_v4().to_string();
    let request = f.prepare(&client_id, manifest("first-file"));
    let first = tokio::spawn(async move { request.send().await.unwrap() });
    let (first_host, first_detail, first_decision) = f.decision().await;
    let request = f
        .client
        .post(f.url("prepare-upload").replace(ID, SECOND))
        .header("x-legnasend-upload", "1")
        .json(&json!({"requestId":client_id,"generation":1,"files":manifest("second-file")}));
    let second = tokio::spawn(async move { request.send().await.unwrap() });
    let (second_host, second_detail, second_decision) = f.decision().await;
    assert_ne!(first_host, second_host);
    assert_ne!(first_host, client_id);
    assert_ne!(second_host, client_id);
    assert_eq!(first_detail["requestId"], first_host);
    assert_eq!(second_detail["requestId"], second_host);
    let response = f
        .client
        .post(f.url("cancel-upload-approval"))
        .header("x-legnasend-upload", "1")
        .json(&json!({"requestId":client_id,"generation":1}))
        .send()
        .await
        .unwrap();
    assert_eq!(response.status(), 200);
    assert_eq!(first.await.unwrap().status(), 409);
    assert!(first_decision.send(true).is_err());
    let aborted = tokio::time::timeout(Duration::from_secs(2), async {
        loop {
            if let Some(ServerEventV2::DirectoryUploadApprovalAborted { request_id }) =
                f.events.recv().await
            {
                break request_id;
            }
        }
    })
    .await
    .unwrap();
    assert_eq!(aborted, first_host);
    assert!(!second_decision.is_closed());
    second_decision.send(true).unwrap();
    let response = second.await.unwrap();
    assert_eq!(response.status(), 200);
    let token: Value = response.json().await.unwrap();
    let upload = f
        .client
        .post(
            f.url("upload?generation=1&path=second-file&directory=false")
                .replace(ID, SECOND),
        )
        .header("x-legnasend-upload", "1")
        .header("x-legnasend-upload-token", token["token"].as_str().unwrap())
        .header("content-type", "application/octet-stream")
        .body("data")
        .send()
        .await
        .unwrap();
    assert!(upload.status().is_success());
    assert_eq!(std::fs::read(f.temp.join("second-file")).unwrap(), b"data");
    assert!(!f.temp.join("first-file").exists());
    f.finish().await;
}

#[tokio::test]
async fn incomplete_manifest_body_times_out_without_a_prompt_and_releases_parse_admission() {
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    let mut f = Fixture::new().await;
    let mut socket = tokio::net::TcpStream::connect(("127.0.0.1", f.server.port()))
        .await
        .unwrap();
    let request=format!("POST /api/legnasend/v1/workspaces/{ID}/prepare-upload HTTP/1.1\r\nHost: 127.0.0.1:{}\r\nX-LegnaSend-Upload: 1\r\nContent-Type: application/json\r\nContent-Length: 1024\r\nConnection: close\r\n\r\n{{",f.server.port());
    socket.write_all(request.as_bytes()).await.unwrap();
    // Let actual socket readiness enter the parser before advancing Tokio time.
    tokio::time::sleep(Duration::from_millis(50)).await;
    tokio::time::pause();
    tokio::time::advance(Duration::from_secs(11)).await;
    for _ in 0..10 {
        tokio::task::yield_now().await;
    }
    tokio::time::resume();
    let mut response = vec![0; 4096];
    let received = tokio::time::timeout(Duration::from_secs(2), socket.read(&mut response))
        .await
        .unwrap()
        .unwrap();
    assert!(String::from_utf8_lossy(&response[..received]).starts_with("HTTP/1.1 408"));
    assert!(f.events.try_recv().is_err());
    drop(socket);
    let request = f.prepare(
        &uuid::Uuid::new_v4().to_string(),
        manifest("after-body-timeout"),
    );
    let pending = tokio::spawn(async move { request.send().await.unwrap() });
    let (_, _, decision) = f.decision().await;
    decision.send(false).unwrap();
    assert_eq!(pending.await.unwrap().status(), 403);
    f.finish().await;
}
