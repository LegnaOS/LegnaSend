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
    server: ServerHandle,
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
                scopes: vec![Scope::Service, Scope::Manage],
                workspaces: vec![ID.into()],
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
            server,
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
    fn manage(&self, query: &str) -> reqwest::RequestBuilder {
        self.client
            .post(self.endpoint(&format!("/workspaces/{ID}/manage?{query}")))
            .bearer_auth(&self.secret)
            .header("Content-Length", "0")
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
fn metadata() -> Value {
    json!({"id":ID,"name":"Host catalog","slug":"host-catalog","generation":8,"enabled":false,"visible":false,"allowUpload":false,"passwordProtected":true,"invalidReason":"grantUnavailable"})
}
#[tokio::test]
async fn unavailable_host_is_explicit_and_original_info_still_responds() {
    let f = Fixture::new(false).await;
    let r = f
        .manage("generation=7&action=disable")
        .send()
        .await
        .unwrap();
    assert_eq!(r.status(), 503);
    assert_eq!(
        r.json::<Value>().await.unwrap()["error"]["code"],
        "host_unavailable"
    );
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
}
#[tokio::test]
async fn persisted_list_and_mutation_are_host_claimed_and_response_sanitized() {
    let mut f = Fixture::new(true).await;
    let req = f
        .client
        .get(f.endpoint("/managed-workspaces"))
        .bearer_auth(&f.secret);
    let task = tokio::spawn(async move { req.send().await.unwrap() });
    let event = f.event().await;
    let body: Value = serde_json::from_str(&event.request_json()).unwrap();
    assert_eq!(body, json!({"operation":"list","workspaces":[ID]}));
    assert!(event
        .respond(json!({"status":200,"body":{"workspaces":[]}}).to_string())
        .is_err());
    assert!(event.claim());
    assert!(!event.claim());
    let mut unsafe_metadata = metadata();
    unsafe_metadata["root"] = json!("/private/secret");
    assert!(event
        .respond(json!({"status":200,"body":{"workspaces":[unsafe_metadata]}}).to_string())
        .is_err());
    event
        .respond(json!({"status":200,"body":{"workspaces":[metadata()]}}).to_string())
        .unwrap();
    let response = task.await.unwrap();
    assert_eq!(response.status(), 200);
    assert_eq!(
        response.json::<Value>().await.unwrap()["workspaces"][0],
        metadata()
    );
    let req = f.manage("generation=7&action=update&name=Renamed&visible=true&allowUpload=false");
    let task = tokio::spawn(async move { req.send().await.unwrap() });
    let event = f.event().await;
    let body: Value = serde_json::from_str(&event.request_json()).unwrap();
    assert_eq!(body["generation"], 7);
    assert_eq!(body["name"], "Renamed");
    assert_eq!(body["allowUpload"], false);
    assert!(event.claim());
    event.respond(json!({"status":503,"body":{"error":{"code":"config_saved_sync_pending"},"workspace":metadata()}}).to_string()).unwrap();
    assert_eq!(task.await.unwrap().status(), 503);
}
#[tokio::test]
async fn stale_host_cas_rejects_before_claim_and_prevents_late_claim() {
    let mut f = Fixture::new(true).await;
    let req = f.manage("generation=6&action=destroy");
    let task = tokio::spawn(async move { req.send().await.unwrap() });
    let event = f.event().await;
    event.respond(json!({"status":409,"body":{"error":{"code":"stale_generation"},"workspace":metadata()}}).to_string()).unwrap();
    assert!(!event.claim());
    assert!(!event.is_claimed());
    assert_eq!(task.await.unwrap().status(), 409);
}
#[tokio::test]
async fn revocation_before_claim_cancels_but_after_claim_reports_unknown_outcome() {
    for claimed in [false, true] {
        let mut f = Fixture::new(true).await;
        let req = f.manage("generation=7&action=disable");
        let task = tokio::spawn(async move { req.send().await.unwrap() });
        let event = f.event().await;
        if claimed {
            assert!(event.claim());
        }
        f.revoke().await;
        let response = task.await.unwrap();
        assert_eq!(response.status(), if claimed { 503 } else { 401 });
        let error = response.json::<Value>().await.unwrap();
        assert_eq!(
            error["error"]["code"],
            if claimed {
                "outcome_unknown"
            } else {
                "revoked"
            }
        );
        assert_eq!(event.is_claimed(), claimed);
        assert!(event.is_closed());
        if !claimed {
            assert!(!event.claim());
        } else {
            assert!(event
                .respond(json!({"status":200,"body":{"workspace":metadata()}}).to_string())
                .is_err());
        }
    }
}
#[tokio::test]
async fn invalid_actions_scope_and_bodies_never_reach_host() {
    let mut f = Fixture::new(true).await;
    for query in [
        "generation=7&action=update",
        "generation=7&action=create",
        "generation=0&action=disable",
        "generation=7&action=destroy&name=nope",
        "generation=7&action=update&visible=yes",
    ] {
        assert_eq!(f.manage(query).send().await.unwrap().status(), 400);
    }
    assert!(f.events.try_recv().is_err());
    let response = f
        .client
        .post(f.endpoint(
            "/workspaces/22222222-2222-4222-8222-222222222222/manage?generation=7&action=destroy",
        ))
        .bearer_auth(&f.secret)
        .send()
        .await
        .unwrap();
    assert_eq!(response.status(), 403);
    let response = f
        .manage("generation=7&action=disable")
        .header("Content-Length", "1")
        .header("Content-Type", "application/json")
        .body("x")
        .send()
        .await
        .unwrap();
    assert_eq!(response.status(), 400);
}
#[tokio::test]
async fn dropped_unsupported_event_is_503_without_thirty_second_wait() {
    let mut f = Fixture::new(true).await;
    let req = f.manage("generation=7&action=disable");
    let task = tokio::spawn(async move { req.send().await.unwrap() });
    let event = f.event().await;
    drop(event);
    assert_eq!(
        tokio::time::timeout(Duration::from_secs(2), task)
            .await
            .unwrap()
            .unwrap()
            .status(),
        503
    );
}
#[tokio::test]
async fn console_uses_post_for_management_and_openapi_lists_both_routes() {
    let mut f = Fixture::new(true).await;
    let request=json!({"operation":"manageWorkspace","token":f.secret,"parameters":{"workspaceId":ID,"generation":"7","action":"destroy"}}).to_string();
    let server = f.server.integration_api_request(&request);
    tokio::pin!(server);
    let event = tokio::select! {_= &mut server=>panic!("console ended beforehost"),event=f.events.recv()=>event.unwrap()};
    assert!(event.claim());
    event
        .respond(json!({"status":200,"body":{"id":ID,"destroyed":true}}).to_string())
        .unwrap();
    let output: Value = serde_json::from_str(&server.await.unwrap()).unwrap();
    assert_eq!(output["status"], 200);
    for locale in ["en", "zh-CN", "zh-TW", "zh-HK"] {
        let doc: Value = f
            .client
            .get(f.endpoint(&format!("/openapi.json?lang={locale}")))
            .bearer_auth(&f.secret)
            .send()
            .await
            .unwrap()
            .json()
            .await
            .unwrap();
        assert_eq!(
            doc["paths"]["/managed-workspaces"]["get"]["operationId"],
            "listManagedWorkspaces"
        );
        assert_eq!(
            doc["paths"]["/workspaces/{workspaceId}/manage"]["post"]["operationId"],
            "manageWorkspace"
        );
    }
}

#[tokio::test]
async fn console_management_waits_beyond_read_only_ten_second_client_deadline() {
    let mut f = Fixture::new(true).await;
    let request=json!({"operation":"manageWorkspace","token":f.secret,"parameters":{"workspaceId":ID,"generation":"7","action":"destroy"}}).to_string();
    let result = f.server.integration_api_request(&request);
    tokio::pin!(result);
    let event = tokio::select! {_= &mut result=>panic!("premature console result"),event=f.events.recv()=>event.unwrap()};
    assert!(event.claim());
    let delay = tokio::time::sleep(Duration::from_millis(10500));
    tokio::pin!(delay);
    tokio::select! {_= &mut result=>panic!("management inherited read-only client timeout"),_= &mut delay=>{}}
    event
        .respond(json!({"status":200,"body":{"id":ID,"destroyed":true}}).to_string())
        .unwrap();
    let response: Value = serde_json::from_str(&result.await.unwrap()).unwrap();
    assert_eq!(response["status"], 200);
}

#[tokio::test]
async fn approved_source_operations_require_wildcard_and_never_expose_locators() {
    let mut f = Fixture::new(true).await;
    let create = json!({"sourceId":ID,"name":"Created","slug":"created"});
    for endpoint in ["/approved-workspace-sources", "/managed-workspaces/create"] {
        let req = if endpoint.ends_with("create") {
            f.client.post(f.endpoint(endpoint)).json(&create)
        } else {
            f.client.get(f.endpoint(endpoint))
        };
        assert_eq!(
            req.bearer_auth(&f.secret).send().await.unwrap().status(),
            403
        );
    }
    assert!(f.events.try_recv().is_err());
    f.config.revision += 1;
    f.config.keys[0].grant.workspaces = vec!["*".into()];
    f.server
        .configure_integration_api(&serde_json::to_string(&f.config).unwrap())
        .await
        .unwrap();
    let req = f
        .client
        .get(f.endpoint("/approved-workspace-sources"))
        .bearer_auth(&f.secret);
    let task = tokio::spawn(async move { req.send().await.unwrap() });
    let event = f.event().await;
    assert_eq!(
        serde_json::from_str::<Value>(&event.request_json()).unwrap()["operation"],
        "sources"
    );
    assert!(event.claim());
    assert!(event.respond(json!({"status":200,"body":{"sources":[{"id":ID,"name":"Approved","kind":"directory","locator":"/private"}]}}).to_string()).is_err());
    event.respond(json!({"status":200,"body":{"sources":[{"id":ID,"name":"Approved","kind":"directory"}]}}).to_string()).unwrap();
    let response = task.await.unwrap();
    assert_eq!(response.status(), 200);
    assert!(!response.text().await.unwrap().contains("private"));
    let req = f
        .client
        .post(f.endpoint("/managed-workspaces/create"))
        .bearer_auth(&f.secret)
        .json(&create);
    let task = tokio::spawn(async move { req.send().await.unwrap() });
    let event = f.event().await;
    let request: Value = serde_json::from_str(&event.request_json()).unwrap();
    assert_eq!(request["operation"], "create");
    assert_eq!(request["sourceId"], ID);
    assert!(event.claim());
    event
        .respond(json!({"status":200,"body":{"workspace":metadata()}}).to_string())
        .unwrap();
    assert_eq!(task.await.unwrap().status(), 200);
}

#[tokio::test]
async fn configure_and_password_use_strict_bounded_bodies_and_safe_history() {
    let mut f = Fixture::new(true).await;
    for (action, payload) in [
        ("configure", json!({"sourceId":ID,"slug":"new-route"})),
        ("password", json!({"password":"Secret-9381"})),
        ("password", json!({"clear":true})),
    ] {
        let req = f
            .client
            .post(f.endpoint(&format!(
                "/workspaces/{ID}/manage?generation=7&action={action}"
            )))
            .bearer_auth(&f.secret)
            .json(&payload);
        let task = tokio::spawn(async move { req.send().await.unwrap() });
        let event = f.event().await;
        let request: Value = serde_json::from_str(&event.request_json()).unwrap();
        assert_eq!(request["operation"], action);
        for (key, value) in payload.as_object().unwrap() {
            assert_eq!(&request[key], value);
        }
        assert!(!format!("{event:?}").contains("Secret-9381"));
        assert!(event.claim());
        event
            .respond(json!({"status":200,"body":{"workspace":metadata()}}).to_string())
            .unwrap();
        assert_eq!(task.await.unwrap().status(), 200);
    }
    for (query, payload, status) in [
        (
            "action=password&generation=7&password=Secret-9381",
            json!({"password":"Secret-9381"}),
            400,
        ),
        (
            "action=configure&generation=7&sourceId=bad",
            json!({"slug":"new-route"}),
            400,
        ),
        (
            "action=password&generation=7",
            json!({"password":"Secret-9381","clear":true}),
            400,
        ),
        (
            "action=password&generation=7",
            json!({"password":"abc"}),
            400,
        ),
        (
            "action=configure&generation=7",
            json!({"root":"/private"}),
            400,
        ),
        ("action=configure&generation=7", json!({}), 400),
        (
            "action=password&generation=7",
            json!({"password":"x".repeat(9000)}),
            413,
        ),
    ] {
        let response = f
            .client
            .post(f.endpoint(&format!("/workspaces/{ID}/manage?{query}")))
            .bearer_auth(&f.secret)
            .json(&payload)
            .send()
            .await
            .unwrap();
        assert_eq!(response.status(), status, "{query}");
    }
    assert!(f.events.try_recv().is_err());
    assert!(!f.server.integration_api_snapshot().contains("Secret-9381"));
}
