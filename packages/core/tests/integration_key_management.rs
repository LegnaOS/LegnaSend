#![cfg(feature = "http")]
use localsend::http::server::{
    integration::{create_key, ApiConfig, PendingManagement, Scope, WorkspaceGrant, PREFIX},
    start_with_port,
    v2::ServerEventV2,
    web::WebConfig,
    ServerConfigV2, ServerHandle,
};
use localsend::http::state::ClientInfo;
use serde_json::{json, Value};
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
                    Scope::CacheRead,
                    Scope::CacheClean,
                    Scope::SettingsRead,
                    Scope::SettingsWrite,
                    Scope::KeysManage,
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
fn receipt(request: &Value) -> Value {
    json!({"principal":request["principal"],"requestId":request["change"]["requestId"],"digest":"b".repeat(64),"action":"create","keyId":ID,"createdAt":1})
}
fn create() -> Value {
    json!({"version":"a".repeat(64),"requestId":ID,"name":"Child","grant":{"scopes":["service.read"],"workspaces":["*"]},"expiresAt":null})
}
#[tokio::test]
async fn new_scope_global_grant_and_subset_are_required_before_host_dispatch() {
    let mut f = Fixture::new(true).await;
    let other = create();
    assert_eq!(
        f.client
            .post(f.endpoint("/keys/create"))
            .json(&other)
            .send()
            .await
            .unwrap()
            .status(),
        401
    );
    let mut excessive = other.clone();
    excessive["grant"]["scopes"] = json!(["files.upload"]);
    assert_eq!(
        f.client
            .post(f.endpoint("/keys/create"))
            .bearer_auth(&f.secret)
            .json(&excessive)
            .send()
            .await
            .unwrap()
            .status(),
        403
    );
    let caller = f.config.keys[0].id.clone();
    assert_eq!(
        f.client
            .post(f.endpoint(&format!("/keys/{caller}/manage")))
            .bearer_auth(&f.secret)
            .json(&json!({"version":"a".repeat(64),"requestId":ID,"action":"revoke"}))
            .send()
            .await
            .unwrap()
            .status(),
        403
    );
    f.config.keys[0].grant.workspaces = vec![ID.into()];
    f.config.revision += 1;
    f.server
        .configure_integration_api(&serde_json::to_string(&f.config).unwrap())
        .await
        .unwrap();
    assert_eq!(
        f.client
            .get(f.endpoint("/keys"))
            .bearer_auth(&f.secret)
            .send()
            .await
            .unwrap()
            .status(),
        403
    );
    assert!(f.events.try_recv().is_err());
}
#[tokio::test]
async fn creation_secret_is_validated_and_never_in_the_request_audit_record() {
    let mut f = Fixture::new(true).await;
    let req = f
        .client
        .post(f.endpoint("/keys/create"))
        .bearer_auth(&f.secret)
        .json(&create());
    let call = tokio::spawn(async move { req.send().await.unwrap() });
    let event = f.event().await;
    let input: Value = serde_json::from_str(&event.request_json()).unwrap();
    assert_eq!(input["operation"], "keys.create");
    assert!(event.claim());
    let secret = format!("ls1.{ID}.{}", "z".repeat(43));
    let body =
        json!({"receipt":receipt(&input),"applied":true,"secretAvailable":true,"secret":secret});
    let mut bad = body.clone();
    bad["verifier"] = json!("private");
    assert!(event
        .respond(json!({"status":201,"body":bad}).to_string())
        .is_err());
    event
        .respond(json!({"status":201,"body":body}).to_string())
        .unwrap();
    let response = call.await.unwrap();
    assert_eq!(response.status(), 201);
    assert_eq!(response.json::<Value>().await.unwrap(), body);
    let snapshot = f.server.integration_api_snapshot();
    assert!(!snapshot.contains(&secret));
}
#[tokio::test]
async fn list_response_rejects_verifiers_and_broader_grants() {
    let mut f = Fixture::new(true).await;
    let req = f.client.get(f.endpoint("/keys")).bearer_auth(&f.secret);
    let call = tokio::spawn(async move { req.send().await.unwrap() });
    let event = f.event().await;
    assert!(event.claim());
    let metadata = json!({"id":ID,"name":"Child","grant":{"scopes":["service.read"],"workspaces":["*"]},"createdAt":1,"expiresAt":null,"enabled":true,"limits":null});
    let body = json!({"version":"a".repeat(64),"keys":[metadata]});
    let mut bad = body.clone();
    bad["keys"][0]["verifier"] = json!("private");
    assert!(event
        .respond(json!({"status":200,"body":bad}).to_string())
        .is_err());
    let mut bad = body.clone();
    bad["keys"][0]["grant"]["scopes"] = json!(["files.upload"]);
    assert!(event
        .respond(json!({"status":200,"body":bad}).to_string())
        .is_err());
    event
        .respond(json!({"status":200,"body":body}).to_string())
        .unwrap();
    assert_eq!(call.await.unwrap().status(), 200);
}
#[tokio::test]
async fn revoked_caller_cannot_claim_a_pending_key_mutation() {
    let mut f = Fixture::new(true).await;
    let req = f
        .client
        .post(f.endpoint("/keys/create"))
        .bearer_auth(&f.secret)
        .json(&create());
    let call = tokio::spawn(async move { req.send().await.unwrap() });
    let event = f.event().await;
    f.revoke().await;
    assert!(!event.claim());
    assert_ne!(call.await.unwrap().status(), 201);
}
