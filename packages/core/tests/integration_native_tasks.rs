#![cfg(feature = "http")]
use localsend::http::server::{
    ServerConfigV2, ServerHandle,
    integration::{ApiConfig, PREFIX, PendingManagement, Scope, WorkspaceGrant, create_key},
    start_with_port,
    v2::ServerEventV2,
    web::WebConfig,
};
use localsend::http::state::ClientInfo;
use serde_json::{Value, json};
use std::time::Duration;
use tokio::sync::{mpsc, oneshot};
const ID: &str = "11111111-1111-4111-8111-111111111111";
struct Fixture {
    server: std::sync::Arc<ServerHandle>,
    client: reqwest::Client,
    events: mpsc::Receiver<PendingManagement>,
    secret: String,
    config: ApiConfig,
    _stop: oneshot::Sender<()>,
}
impl Fixture {
    async fn new(available: bool) -> Self {
        let (stop, rx) = oneshot::channel();
        let (tx, mut events) = mpsc::channel(16);
        let (host, events_rx) = mpsc::channel(16);
        tokio::spawn(async move {
            while let Some(event) = events.recv().await {
                if let ServerEventV2::WorkspaceManagement { request } = event {
                    let _ = host.send(request).await;
                }
            }
        });
        let server = start_with_port(
            0,
            None,
            ClientInfo {
                alias: "management fixture".into(),
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
        server.set_workspace_management_available(available);
        let key = create_key(
            "manager".into(),
            WorkspaceGrant {
                scopes: vec![
                    Scope::Service,
                    Scope::NativeTasksRead,
                    Scope::NativeTasksControl,
                    Scope::TransfersSend,
                    Scope::Files,
                ],
                workspaces: vec!["*".into()],
            },
            None,
        )
        .unwrap();
        let mut config = ApiConfig {
            revision: 1,
            enabled: true,
            keys: vec![key.record],
            ..ApiConfig::default()
        };
        config.global_limits.per_second = 100;
        config.key_limits.per_second = 100;
        server
            .configure_integration_api(&serde_json::to_string(&config).unwrap())
            .await
            .unwrap();
        Self {
            server: std::sync::Arc::new(server),
            client: reqwest::Client::builder()
                .no_proxy()
                .timeout(Duration::from_secs(5))
                .build()
                .unwrap(),
            events: events_rx,
            secret: key.secret,
            config,
            _stop: stop,
        }
    }
    fn endpoint(&self, path: &str) -> String {
        format!("http://127.0.0.1:{}{PREFIX}{path}", self.server.port())
    }
    async fn event(&mut self) -> PendingManagement {
        tokio::time::timeout(Duration::from_secs(2), self.events.recv())
            .await
            .unwrap()
            .unwrap()
    }
    async fn revoke(&mut self) {
        self.config.revision += 1;
        self.config.keys.clear();
        self.server
            .configure_integration_api(&serde_json::to_string(&self.config).unwrap())
            .await
            .unwrap();
    }
}
fn snapshot() -> Value {
    json!({"epoch":ID,"tasks":[{"id":ID,"version":ID,"direction":"receive","phase":"waiting","fileCount":5000,"totalBytes":5000,"transferredBytes":0,"bytesPerSecond":0,"actions":["accept","reject"]}],"truncated":false})
}
#[tokio::test]
async fn native_tasks_http_uses_claimed_global_scope_and_redacted_response() {
    let mut f = Fixture::new(true).await;
    let req = f
        .client
        .get(f.endpoint("/native-tasks"))
        .bearer_auth(&f.secret);
    let call = tokio::spawn(async move { req.send().await.unwrap() });
    let event = f.event().await;
    let input: Value = serde_json::from_str(&event.request_json()).unwrap();
    assert_eq!(input["operation"], "nativeTasks.list");
    assert!(event.claim());
    let mut unsafe_body = snapshot();
    unsafe_body["tasks"][0]["sourcePath"] = json!("/private/name");
    assert!(
        event
            .respond(json!({"status":200,"body":unsafe_body}).to_string())
            .is_err()
    );
    event
        .respond(json!({"status":200,"body":snapshot()}).to_string())
        .unwrap();
    let response = call.await.unwrap();
    assert_eq!(response.status(), 200);
    assert_eq!(response.json::<Value>().await.unwrap(), snapshot());
    for action in ["cancel", "accept", "reject", "remove"] {
        let req = f
            .client
            .post(f.endpoint(&format!("/native-tasks/{ID}/control")))
            .bearer_auth(&f.secret)
            .json(&json!({"epoch":ID,"version":ID,"action":action}));
        let call = tokio::spawn(async move { req.send().await.unwrap() });
        let event = f.event().await;
        let input: Value = serde_json::from_str(&event.request_json()).unwrap();
        assert_eq!(input["taskId"], ID);
        assert_eq!(input["change"]["action"], action);
        assert!(event.claim());
        event
            .respond(
                json!({"status":200,"body":{"epoch":ID,"id":ID,"action":action,"dispatched":true}})
                    .to_string(),
            )
            .unwrap();
        assert_eq!(call.await.unwrap().status(), 200);
    }
}
#[tokio::test]
async fn invalid_native_controls_never_reach_host_and_read_is_not_control() {
    let mut f = Fixture::new(true).await;
    for body in [
        json!({"epoch":ID,"version":ID,"action":"pause"}),
        json!({"epoch":ID,"action":"cancel"}),
        json!({"epoch":ID,"version":ID,"action":"accept","path":"/tmp"}),
    ] {
        assert_eq!(
            f.client
                .post(f.endpoint(&format!("/native-tasks/{ID}/control")))
                .bearer_auth(&f.secret)
                .json(&body)
                .send()
                .await
                .unwrap()
                .status(),
            400
        );
    }
    f.config.revision += 1;
    f.config.keys[0].grant.scopes = vec![Scope::NativeTasksRead];
    f.server
        .configure_integration_api(&serde_json::to_string(&f.config).unwrap())
        .await
        .unwrap();
    assert_eq!(
        f.client
            .post(f.endpoint(&format!("/native-tasks/{ID}/control")))
            .bearer_auth(&f.secret)
            .json(&json!({"epoch":ID,"version":ID,"action":"cancel"}))
            .send()
            .await
            .unwrap()
            .status(),
        403
    );
    assert!(f.events.try_recv().is_err());
}
#[tokio::test]
async fn native_control_revocation_cancels_before_claim_and_single_workspace_is_not_global() {
    let mut f = Fixture::new(true).await;
    let req = f
        .client
        .get(f.endpoint("/native-tasks"))
        .bearer_auth(&f.secret);
    let call = tokio::spawn(async move { req.send().await.unwrap() });
    let event = f.event().await;
    f.revoke().await;
    assert_eq!(call.await.unwrap().status(), 401);
    assert!(!event.claim());
    let mut f = Fixture::new(true).await;
    f.config.revision += 1;
    f.config.keys[0].grant.workspaces = vec![ID.into()];
    f.server
        .configure_integration_api(&serde_json::to_string(&f.config).unwrap())
        .await
        .unwrap();
    assert_eq!(
        f.client
            .get(f.endpoint("/native-tasks"))
            .bearer_auth(&f.secret)
            .send()
            .await
            .unwrap()
            .status(),
        403
    );
    let mut anonymous = ApiConfig::default();
    anonymous
        .anonymous_grant
        .scopes
        .push(Scope::NativeTasksRead);
    assert!(
        f.server
            .configure_integration_api(&serde_json::to_string(&anonymous).unwrap())
            .await
            .is_err()
    );
}
#[tokio::test]
async fn workspace_send_requires_files_read_current_instance_and_strict_file_manifest() {
    let mut f = Fixture::new(true).await;
    let status: Value = f
        .client
        .get(f.endpoint("/status"))
        .bearer_auth(&f.secret)
        .send()
        .await
        .unwrap()
        .json()
        .await
        .unwrap();
    let valid = json!({"instanceId":status["instanceId"],"generation":1,"deviceId":ID,"requestId":ID,"files":[{"id":"ZmlsZS50eHQ","version":"\"abc\""}]});
    let mut stale = valid.clone();
    stale["instanceId"] = json!(ID);
    assert_eq!(
        f.client
            .post(f.endpoint(&format!("/workspaces/{ID}/send")))
            .bearer_auth(&f.secret)
            .json(&stale)
            .send()
            .await
            .unwrap()
            .status(),
        409
    );
    for bad in [
        json!([]),
        json!([{ "id":"../file","version":"\"abc\"" }]),
        json!([{ "id":"ZmlsZS50eHQ","version":"abc" }]),
        json!([{ "id":"ZmlsZS50eHQ","version":"\"abc\"" },{ "id":"ZmlsZS50eHQ","version":"\"abc\"" }]),
    ] {
        let mut body = valid.clone();
        body["files"] = bad;
        assert_eq!(
            f.client
                .post(f.endpoint(&format!("/workspaces/{ID}/send")))
                .bearer_auth(&f.secret)
                .json(&body)
                .send()
                .await
                .unwrap()
                .status(),
            400
        );
    }
    let req = f
        .client
        .post(f.endpoint(&format!("/workspaces/{ID}/send")))
        .bearer_auth(&f.secret)
        .json(&valid);
    let call = tokio::spawn(async move { req.send().await.unwrap() });
    let event = f.event().await;
    let input: Value = serde_json::from_str(&event.request_json()).unwrap();
    assert_eq!(input["operation"], "transfer.workspaceSend");
    assert_eq!(input["workspaceId"], ID);
    assert!(event.claim());
    event.respond(json!({"status":202,"body":{"task":{"id":ID,"deviceId":ID,"status":"queued","fileCount":1,"totalBytes":3,"transferredBytes":0,"bytesPerSecond":0},"replayed":false}}).to_string()).unwrap();
    assert_eq!(call.await.unwrap().status(), 202);
    f.config.revision += 1;
    f.config.keys[0].grant.scopes.retain(|s| *s != Scope::Files);
    f.server
        .configure_integration_api(&serde_json::to_string(&f.config).unwrap())
        .await
        .unwrap();
    assert_eq!(
        f.client
            .post(f.endpoint(&format!("/workspaces/{ID}/send")))
            .bearer_auth(&f.secret)
            .json(&valid)
            .send()
            .await
            .unwrap()
            .status(),
        403
    );
}

fn source_notice() -> Value {
    json!({"id":ID,"version":ID,"peerLabel":"Phone","name":"a.txt","state":"waitingPeer","attempts":1,"updatedAtUnixMs":1})
}
#[tokio::test]
async fn source_end_api_is_redacted_claimed_and_routes_exact_notice_id() {
    let mut f = Fixture::new(true).await;
    let req = f
        .client
        .get(f.endpoint("/native-tasks/source-end"))
        .bearer_auth(&f.secret);
    let call = tokio::spawn(async move { req.send().await.unwrap() });
    let event = f.event().await;
    let input: Value = serde_json::from_str(&event.request_json()).unwrap();
    assert_eq!(input["operation"], "nativeTasks.sourceEndList");
    assert!(event.claim());
    let mut bad = source_notice();
    bad["token"] = json!("private");
    assert!(
        event
            .respond(json!({"status":200,"body":{"notices":[bad],"truncated":false}}).to_string())
            .is_err()
    );
    event
        .respond(
            json!({"status":200,"body":{"notices":[source_notice()],"truncated":false}})
                .to_string(),
        )
        .unwrap();
    assert_eq!(call.await.unwrap().status(), 200);
    let body = json!({"version":ID,"requestId":ID});
    let req = f
        .client
        .post(f.endpoint(&format!("/native-tasks/source-end/{ID}/retry")))
        .bearer_auth(&f.secret)
        .json(&body);
    let call = tokio::spawn(async move { req.send().await.unwrap() });
    let event = f.event().await;
    let input: Value = serde_json::from_str(&event.request_json()).unwrap();
    assert_eq!(input["operation"], "nativeTasks.sourceEndRetry");
    assert_eq!(input["noticeId"], ID);
    assert_eq!(input["body"], body);
    assert!(event.claim());
    event
        .respond(
            json!({"status":200,"body":{"notice":source_notice(),"accepted":true}}).to_string(),
        )
        .unwrap();
    assert_eq!(call.await.unwrap().status(), 200);
    for body in [
        json!({"version":ID}),
        json!({"version":ID,"requestId":ID,"token":"secret"}),
        json!({"version":"old","requestId":ID}),
    ] {
        assert_eq!(
            f.client
                .post(f.endpoint(&format!("/native-tasks/source-end/{ID}/retry")))
                .bearer_auth(&f.secret)
                .json(&body)
                .send()
                .await
                .unwrap()
                .status(),
            400
        );
    }
    assert!(f.events.try_recv().is_err());
    f.config.revision += 1;
    f.config.keys[0]
        .grant
        .scopes
        .retain(|scope| *scope != Scope::NativeTasksControl);
    f.server
        .configure_integration_api(&serde_json::to_string(&f.config).unwrap())
        .await
        .unwrap();
    assert_eq!(
        f.client
            .post(f.endpoint(&format!("/native-tasks/source-end/{ID}/retry")))
            .bearer_auth(&f.secret)
            .json(&json!({"version":ID,"requestId":ID}))
            .send()
            .await
            .unwrap()
            .status(),
        403
    );
    assert!(f.events.try_recv().is_err());
}

#[tokio::test]
async fn source_end_console_delivers_the_real_retry_body() {
    let mut f = Fixture::new(true).await;
    let server = f.server.clone();
    let body = json!({"version":ID,"requestId":ID});
    let input = json!({"operation":"retrySourceEndNotice","token":f.secret,"parameters":{"noticeId":ID},"body":body});
    let call = tokio::spawn(async move {
        server
            .integration_api_request(&input.to_string())
            .await
            .unwrap()
    });
    let event = f.event().await;
    let input: Value = serde_json::from_str(&event.request_json()).unwrap();
    assert_eq!(input["operation"], "nativeTasks.sourceEndRetry");
    assert_eq!(input["body"], body);
    assert_eq!(input["noticeId"], ID);
    assert!(event.claim());
    event
        .respond(
            json!({"status":200,"body":{"notice":source_notice(),"accepted":true}}).to_string(),
        )
        .unwrap();
    let result: Value = serde_json::from_str(&call.await.unwrap()).unwrap();
    assert_eq!(result["status"], 200);
}
