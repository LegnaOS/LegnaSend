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
                    Scope::DevicesRead,
                    Scope::DevicesScan,
                    Scope::TransfersRead,
                    Scope::TransfersSend,
                    Scope::TransfersControl,
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
fn task() -> Value {
    json!({"id":ID,"deviceId":ID,"status":"queued","fileCount":1,"totalBytes":10,"transferredBytes":0,"bytesPerSecond":0})
}
fn retry_task() -> Value {
    let mut t = task();
    t["retryOf"] = json!(ID);
    t
}
#[tokio::test]
async fn all_ten_operations_use_scoped_claimed_host_bridge() {
    let mut f = Fixture::new(true).await;
    let routes = vec![
        (
            "GET",
            "/devices".into(),
            "devices",
            None,
            json!({"devices":[],"truncated":false,"scanState":"idle"}),
            200,
        ),
        (
            "GET",
            format!("/devices/{ID}"),
            "device",
            None,
            json!({"device":{"id":ID,"alias":"Peer","deviceType":"desktop","channels":[{"id":ID,"host":"127.0.0.1","port":53317,"https":false}]}}),
            200,
        ),
        (
            "POST",
            "/devices/scan".into(),
            "scan",
            None,
            json!({"accepted":true,"coalesced":false}),
            202,
        ),
        (
            "GET",
            "/send-selection".into(),
            "selection",
            None,
            json!({"selectionVersion":ID,"totalCount":1,"totalBytes":10,"truncated":false,"files":[{"name":"file.txt","size":10}]}),
            200,
        ),
        (
            "POST",
            "/transfers/send".into(),
            "send",
            Some(json!({"deviceId":ID,"selectionVersion":ID,"requestId":ID,"channelId":ID})),
            json!({"task":task(),"replayed":false}),
            202,
        ),
        (
            "GET",
            "/transfers".into(),
            "list",
            None,
            json!({"tasks":[task()]}),
            200,
        ),
        (
            "GET",
            format!("/transfers/{ID}"),
            "get",
            None,
            json!({"task":task()}),
            200,
        ),
        (
            "POST",
            format!("/transfers/{ID}/cancel"),
            "cancel",
            None,
            json!({"task":task()}),
            200,
        ),
        (
            "POST",
            format!("/transfers/{ID}/retry"),
            "retry",
            Some(json!({"requestId":ID})),
            json!({"task":retry_task(),"replayed":true}),
            202,
        ),
        (
            "POST",
            format!("/transfers/{ID}/remove"),
            "remove",
            None,
            json!({"id":ID,"removed":true}),
            200,
        ),
    ];
    for (method, path, op, payload, result, status) in routes {
        let mut req = f
            .client
            .request(method.parse().unwrap(), f.endpoint(&path))
            .bearer_auth(&f.secret);
        if let Some(payload) = payload {
            req = req.json(&payload);
        }
        let call = tokio::spawn(async move { req.send().await.unwrap() });
        let event = f.event().await;
        let input: Value = serde_json::from_str(&event.request_json()).unwrap();
        assert_eq!(input["operation"], format!("transfer.{op}"));
        assert_eq!(input["principal"], f.config.keys[0].id);
        assert_eq!(input["workspaces"], json!(["*"]));
        assert!(
            event
                .respond(json!({"status":status,"body":result}).to_string())
                .is_err()
        );
        assert!(event.claim());
        let mut unsafe_result = result.clone();
        unsafe_result["path"] = json!("/private/user");
        assert!(
            event
                .respond(json!({"status":status,"body":unsafe_result}).to_string())
                .is_err()
        );
        event
            .respond(json!({"status":status,"body":result}).to_string())
            .unwrap();
        let response = call.await.unwrap();
        assert_eq!(response.status(), status);
        assert_eq!(response.json::<Value>().await.unwrap(), result);
    }
}
#[tokio::test]
async fn no_implicit_global_grants_and_no_anonymous_transfer_scopes() {
    let mut f = Fixture::new(true).await;
    f.config.keys[0].grant.workspaces = vec![ID.into()];
    f.config.revision += 1;
    f.server
        .configure_integration_api(&serde_json::to_string(&f.config).unwrap())
        .await
        .unwrap();
    let r = f
        .client
        .get(f.endpoint("/devices"))
        .bearer_auth(&f.secret)
        .send()
        .await
        .unwrap();
    assert_eq!(r.status(), 403);
    assert_eq!(
        r.json::<Value>().await.unwrap()["error"]["code"],
        "wildcard_transfer_required"
    );
    f.config.keys[0].grant.scopes = vec![Scope::Service];
    f.config.keys[0].grant.workspaces = vec!["*".into()];
    f.config.revision += 1;
    f.server
        .configure_integration_api(&serde_json::to_string(&f.config).unwrap())
        .await
        .unwrap();
    assert_eq!(
        f.client
            .get(f.endpoint("/devices"))
            .bearer_auth(&f.secret)
            .send()
            .await
            .unwrap()
            .status(),
        403
    );
    f.config.keys[0].grant.scopes = vec![Scope::TransfersControl];
    f.config.revision += 1;
    f.server
        .configure_integration_api(&serde_json::to_string(&f.config).unwrap())
        .await
        .unwrap();
    assert_eq!(
        f.client
            .post(f.endpoint(&format!("/transfers/{ID}/retry")))
            .bearer_auth(&f.secret)
            .json(&json!({"requestId":ID}))
            .send()
            .await
            .unwrap()
            .status(),
        403
    );
    f.config.auth_required = false;
    f.config.revision += 1;
    f.server
        .configure_integration_api(&serde_json::to_string(&f.config).unwrap())
        .await
        .unwrap();
    assert_eq!(
        f.client
            .get(f.endpoint("/devices"))
            .send()
            .await
            .unwrap()
            .status(),
        403
    );
    for scope in [
        Scope::DevicesRead,
        Scope::DevicesScan,
        Scope::TransfersRead,
        Scope::TransfersSend,
        Scope::TransfersControl,
    ] {
        f.config.anonymous_grant.scopes = vec![scope];
        f.config.revision += 1;
        assert!(
            f.server
                .configure_integration_api(&serde_json::to_string(&f.config).unwrap())
                .await
                .is_err()
        );
    }
    assert!(f.events.try_recv().is_err());
}
#[tokio::test]
async fn rejects_path_target_secret_injection_bad_ids_and_unbounded_bodies() {
    let mut f = Fixture::new(true).await;
    for (path, body, status) in [
        (
            "/transfers/send".into(),
            json!({"deviceId":ID,"selectionVersion":ID,"requestId":ID,"principal":ID}),
            400,
        ),
        (
            "/transfers/send".into(),
            json!({"deviceId":ID,"selectionVersion":ID,"requestId":ID,"path":"/private/file"}),
            400,
        ),
        (
            "/transfers/send".into(),
            json!({"deviceId":"http://remote/","selectionVersion":ID,"requestId":ID}),
            400,
        ),
        (
            "/transfers/send".into(),
            json!({"deviceId":ID,"selectionVersion":ID}),
            400,
        ),
        ("/devices/scan".into(), json!({}), 400),
        (
            format!("/transfers/{ID}/cancel"),
            json!({"requestId":ID}),
            400,
        ),
        (
            "/transfers/not-an-id/retry".into(),
            json!({"requestId":ID}),
            400,
        ),
        (
            "/transfers/send".into(),
            json!({"padding":"x".repeat(9000)}),
            413,
        ),
    ] {
        assert_eq!(
            f.client
                .post(f.endpoint(&path))
                .bearer_auth(&f.secret)
                .json(&body)
                .send()
                .await
                .unwrap()
                .status(),
            status,
            "{path}"
        );
    }
    assert_eq!(
        f.client
            .get(f.endpoint(&format!("/devices/{ID}?principal={ID}")))
            .bearer_auth(&f.secret)
            .send()
            .await
            .unwrap()
            .status(),
        400
    );
    let wrong = f
        .client
        .get(f.endpoint("/devices/scan"))
        .bearer_auth(&f.secret)
        .send()
        .await
        .unwrap();
    assert_eq!(wrong.status(), 405);
    assert_eq!(wrong.headers()["allow"], "POST, OPTIONS");
    assert!(f.events.try_recv().is_err());
}
#[tokio::test]
async fn revocation_before_claim_prevents_send_and_after_claim_reports_unknown() {
    for claim in [false, true] {
        let mut f = Fixture::new(true).await;
        let req = f
            .client
            .post(f.endpoint("/transfers/send"))
            .bearer_auth(&f.secret)
            .json(&json!({"deviceId":ID,"selectionVersion":ID,"requestId":ID}));
        let call = tokio::spawn(async move { req.send().await.unwrap() });
        let event = f.event().await;
        if claim {
            assert!(event.claim());
        }
        f.revoke().await;
        let response = call.await.unwrap();
        assert_eq!(response.status(), if claim { 503 } else { 401 });
        if claim {
            assert_eq!(
                response.json::<Value>().await.unwrap()["error"]["code"],
                "outcome_unknown"
            );
        } else {
            assert!(!event.claim());
        }
    }
}
#[tokio::test]
async fn transfer_contract_and_real_console_preserve_original_protocol() {
    let mut f = Fixture::new(true).await;
    let doc: Value = f
        .client
        .get(f.endpoint("/openapi.json?lang=zh-CN"))
        .bearer_auth(&f.secret)
        .send()
        .await
        .unwrap()
        .json()
        .await
        .unwrap();
    assert_eq!(
        doc["paths"]["/transfers/send"]["post"]["operationId"],
        "sendSelection"
    );
    assert_eq!(
        doc["paths"]["/devices"]["get"]["x-legnasend-scope"],
        "devices.read"
    );
    assert_eq!(
        doc["paths"]["/transfers/send"]["post"]["responses"]["202"]["content"]["application/json"]
            ["schema"]["$ref"],
        "#/components/schemas/TransferReceipt"
    );
    let original = f
        .client
        .get(format!(
            "http://127.0.0.1:{}/api/localsend/v2/info",
            f.server.port()
        ))
        .send()
        .await
        .unwrap();
    assert_eq!(original.status(), 200);
    let server = f.server.clone();
    let request=json!({"operation":"retryTransfer","parameters":{"transferId":ID},"token":f.secret,"body":{"requestId":ID}}).to_string();
    let call = tokio::spawn(async move { server.integration_api_request(&request).await });
    let event = f.event().await;
    assert!(event.claim());
    event
        .respond(json!({"status":202,"body":{"task":retry_task(),"replayed":false}}).to_string())
        .unwrap();
    let response = call.await.unwrap().unwrap();
    assert!(!response.contains(&f.secret));
    assert!(!response.contains("Bearer"));
}

#[tokio::test]
async fn local_route_listing_and_send_stay_on_explicit_key_scopes() {
    let mut f = Fixture::new(true).await;
    let denied = f.client.get(f.endpoint("/devices")).send().await.unwrap();
    assert_ne!(denied.status(), 200);
    let request = f.client.get(f.endpoint("/devices")).bearer_auth(&f.secret);
    let call = tokio::spawn(async move { request.send().await.unwrap() });
    let event = f.event().await;
    assert!(event.claim());
    event.respond(json!({"status":200,"body":{"devices":[],"scanState":"idle","truncated":false,"localRoutes":[{"id":ID,"interfaceName":"fixture","address":"192.0.2.1","binding":"sourceOnly"}]}}).to_string()).unwrap();
    let response = call.await.unwrap();
    assert_eq!(response.status(), 200);
    assert_eq!(
        response.json::<Value>().await.unwrap()["localRoutes"][0]["id"],
        ID
    );
    let request = f
        .client
        .post(f.endpoint("/transfers/send"))
        .bearer_auth(&f.secret)
        .json(&json!({"deviceId":ID,"selectionVersion":ID,"requestId":ID,"localRouteId":ID}));
    let call = tokio::spawn(async move { request.send().await.unwrap() });
    let event = f.event().await;
    assert_eq!(
        serde_json::from_str::<Value>(&event.request_json()).unwrap()["localRouteId"],
        ID
    );
    assert!(event.claim());
    let mut t = task();
    t["localRouteId"] = json!(ID);
    event
        .respond(json!({"status":202,"body":{"task":t,"replayed":false}}).to_string())
        .unwrap();
    assert_eq!(call.await.unwrap().status(), 202);
}
