#![cfg(feature = "http")]
use localsend::http::server::{
    integration::{create_key, ApiConfig, Limits, Scope, WorkspaceGrant, PREFIX},
    start_with_port,
    web::WebConfig,
    ServerHandle,
};
use localsend::http::state::ClientInfo;
use serde_json::{json, Value};
use std::time::Duration;
use tokio::sync::oneshot;

struct Fixture {
    server: ServerHandle,
    client: reqwest::Client,
    secret: String,
    config: ApiConfig,
    stop: Option<oneshot::Sender<()>>,
}
impl Fixture {
    async fn new() -> Self {
        let (stop, rx) = oneshot::channel();
        let server = start_with_port(
            0,
            None,
            ClientInfo {
                alias: "History fixture".into(),
                version: "2.2".into(),
                device_model: None,
                device_type: None,
                token: "history".into(),
            },
            None,
            None,
            WebConfig::default(),
            rx,
        )
        .await
        .unwrap();
        let key = create_key(
            "history owner".into(),
            WorkspaceGrant {
                scopes: vec![Scope::Service, Scope::Requests, Scope::RequestsManage],
                workspaces: vec!["*".into()],
            },
            None,
        )
        .unwrap();
        let config = ApiConfig {
            revision: 1,
            enabled: true,
            keys: vec![key.record],
            global_limits: Limits {
                per_second: 0,
                per_minute: 0,
                concurrent: 16,
            },
            key_limits: Limits {
                per_second: 0,
                per_minute: 0,
                concurrent: 8,
            },
            ..ApiConfig::default()
        };
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
            secret: key.secret,
            config,
            stop: Some(stop),
        }
    }
    fn url(&self, path: &str) -> String {
        format!("http://127.0.0.1:{}{PREFIX}{path}", self.server.port())
    }
    async fn get(&self, path: &str) -> Value {
        let response = self
            .client
            .get(self.url(path))
            .bearer_auth(&self.secret)
            .send()
            .await
            .unwrap();
        assert_eq!(response.status(), 200);
        response.json().await.unwrap()
    }
    fn clear_body(page: &Value) -> Value {
        json!({"instanceId":page["instanceId"],"expectedGeneration":page["generation"],"throughSequence":page["latest"]})
    }
    async fn close(mut self) {
        let _ = self.stop.take().unwrap().send(());
        self.server.wait_stopped().await;
    }
}
#[tokio::test]
async fn clear_through_snapshot_preserves_later_records_identity_sequence_and_audit_marker() {
    let f = Fixture::new().await;
    for _ in 0..3 {
        f.get("/status").await;
    }
    let before = f.get("/requests?limit=100").await;
    let captured = before["latest"].as_u64().unwrap();
    f.get("/capabilities").await;
    let result = f
        .client
        .post(f.url("/requests/clear"))
        .bearer_auth(&f.secret)
        .json(&Fixture::clear_body(&before))
        .send()
        .await
        .unwrap();
    assert_eq!(result.status(), 200);
    let result: Value = result.json().await.unwrap();
    assert_eq!(result["instanceId"], before["instanceId"]);
    assert_eq!(result["generation"], 2);
    assert_eq!(result["removed"], captured);
    let after = f.get("/requests?limit=100").await;
    assert_eq!(after["clearedThrough"], captured);
    assert!(after["latest"].as_u64().unwrap() > captured);
    let entries = after["entries"].as_array().unwrap();
    assert!(entries
        .iter()
        .all(|entry| entry["sequence"].as_u64().unwrap() > captured));
    assert!(entries
        .iter()
        .any(|entry| entry["operation"] == "getCapabilities"));
    assert!(entries
        .iter()
        .any(|entry| entry["outcome"] == "historyCleared"
            && entry["principal"] == f.config.keys[0].id));
    assert!(!after.to_string().contains(&f.secret));
    let conflict = f
        .client
        .post(f.url("/requests/clear"))
        .bearer_auth(&f.secret)
        .json(&Fixture::clear_body(&before))
        .send()
        .await
        .unwrap();
    assert_eq!(conflict.status(), 409);
    assert_eq!(f.get("/requests").await["generation"], 2);
    f.close().await;
}
#[tokio::test]
async fn clear_requires_explicit_global_key_grant_and_rejects_invalid_body_without_mutation() {
    let mut f = Fixture::new().await;
    f.get("/status").await;
    let page = f.get("/requests").await;
    let body = Fixture::clear_body(&page);
    for (scopes, workspaces) in [
        (vec![Scope::Requests], vec!["*".into()]),
        (
            vec![Scope::RequestsManage],
            vec!["11111111-1111-4111-8111-111111111111".into()],
        ),
    ] {
        let key = create_key(
            "limited".into(),
            WorkspaceGrant { scopes, workspaces },
            None,
        )
        .unwrap();
        f.config.revision += 1;
        f.config.keys.push(key.record);
        f.server
            .configure_integration_api(&serde_json::to_string(&f.config).unwrap())
            .await
            .unwrap();
        let response = f
            .client
            .post(f.url("/requests/clear"))
            .bearer_auth(&key.secret)
            .json(&body)
            .send()
            .await
            .unwrap();
        assert_eq!(response.status(), 403);
    }
    let anonymous = f
        .client
        .post(f.url("/requests/clear"))
        .json(&body)
        .send()
        .await
        .unwrap();
    assert_eq!(anonymous.status(), 401);
    for invalid in [
        json!({}),
        json!({"instanceId":page["instanceId"],"expectedGeneration":1,"throughSequence":page["latest"],"token":"not-stored"}),
        json!({"instanceId":page["instanceId"],"expectedGeneration":1,"throughSequence":999999}),
    ] {
        let response = f
            .client
            .post(f.url("/requests/clear"))
            .bearer_auth(&f.secret)
            .json(&invalid)
            .send()
            .await
            .unwrap();
        assert_eq!(response.status(), 400);
    }
    let fresh = f.get("/requests").await;
    assert_eq!(fresh["generation"], 1);
    assert_eq!(fresh["clearedThrough"], 0);
    assert!(!fresh.to_string().contains("not-stored"));
    f.close().await;
}
#[tokio::test]
async fn native_console_executes_real_clear_and_requires_a_fresh_confirmation_after_conflict() {
    let f = Fixture::new().await;
    f.get("/status").await;
    let page = f.get("/requests").await;
    let request=json!({"operation":"clearRequests","token":f.secret,"parameters":{},"body":Fixture::clear_body(&page)}).to_string();
    let result: Value =
        serde_json::from_str(&f.server.integration_api_request(&request).await.unwrap()).unwrap();
    assert_eq!(result["status"], 200);
    let data: Value = serde_json::from_str(result["body"].as_str().unwrap()).unwrap();
    assert_eq!(data["generation"], 2);
    let result: Value =
        serde_json::from_str(&f.server.integration_api_request(&request).await.unwrap()).unwrap();
    assert_eq!(result["status"], 409);
    f.close().await;
}
#[tokio::test]
async fn clear_does_not_reset_rate_limit_windows() {
    let mut f = Fixture::new().await;
    f.get("/status").await;
    let page = f.get("/requests").await;
    // Admission consumes existing windows before policy replacement; choose a
    // new scoped key with its own fresh minute budget and unlimited global.
    let mut key = create_key(
        "two credits".into(),
        WorkspaceGrant {
            scopes: vec![Scope::RequestsManage, Scope::Service],
            workspaces: vec!["*".into()],
        },
        None,
    )
    .unwrap();
    key.record.limits = Some(Limits {
        per_second: 0,
        per_minute: 2,
        concurrent: 8,
    });
    f.config.keys.push(key.record);
    f.config.revision += 1;
    f.server
        .configure_integration_api(&serde_json::to_string(&f.config).unwrap())
        .await
        .unwrap();
    let clear = f
        .client
        .post(f.url("/requests/clear"))
        .bearer_auth(&key.secret)
        .json(&Fixture::clear_body(&page))
        .send()
        .await
        .unwrap();
    assert_eq!(clear.status(), 200);
    let _: Value = clear.json().await.unwrap();
    let first = f
        .client
        .get(f.url("/status"))
        .bearer_auth(&key.secret)
        .send()
        .await
        .unwrap();
    assert_eq!(first.status(), 200);
    let _: Value = first.json().await.unwrap();
    let second = f
        .client
        .get(f.url("/status"))
        .bearer_auth(&key.secret)
        .send()
        .await
        .unwrap();
    assert_eq!(second.status(), 429);
    f.close().await;
}

#[tokio::test]
async fn clearing_records_keeps_an_active_download_and_records_its_late_completion() {
    use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine};
    use futures_util::StreamExt;
    let mut f = Fixture::new().await;
    let root =
        std::env::temp_dir().join(format!("legnasend-history-active-{}", uuid::Uuid::new_v4()));
    std::fs::create_dir(&root).unwrap();
    let size = 64 * 1024 * 1024;
    std::fs::File::create(root.join("active.bin"))
        .unwrap()
        .set_len(size)
        .unwrap();
    let workspace = "11111111-1111-4111-8111-111111111111";
    f.server.configure_directory_workspaces(&json!({"revision":1,"enabled":true,"workspaces":[{"id":workspace,"name":"Active","slug":"active","root":root,"generation":1,"visible":true}]}).to_string()).await.unwrap();
    f.config.keys[0].grant.scopes.push(Scope::Files);
    f.config.revision += 1;
    f.server
        .configure_integration_api(&serde_json::to_string(&f.config).unwrap())
        .await
        .unwrap();
    let file = URL_SAFE_NO_PAD.encode("active.bin");
    let response = f
        .client
        .get(f.url(&format!(
            "/workspaces/{workspace}/files/{file}/content?generation=1"
        )))
        .bearer_auth(&f.secret)
        .send()
        .await
        .unwrap();
    assert_eq!(response.status(), 200);
    let id = response.headers()["x-legnasend-request-id"]
        .to_str()
        .unwrap()
        .to_owned();
    let mut stream = response.bytes_stream();
    let mut received = stream.next().await.unwrap().unwrap().len() as u64;
    let page = f.get("/requests").await;
    let active_before: Value = serde_json::from_str(&f.server.integration_api_snapshot()).unwrap();
    assert!(active_before["activeResponses"].as_u64().unwrap() >= 1);
    let clear = f
        .client
        .post(f.url("/requests/clear"))
        .bearer_auth(&f.secret)
        .json(&Fixture::clear_body(&page))
        .send()
        .await
        .unwrap();
    assert_eq!(clear.status(), 200);
    let _: Value = clear.json().await.unwrap();
    let active_after: Value = serde_json::from_str(&f.server.integration_api_snapshot()).unwrap();
    assert!(active_after["activeResponses"].as_u64().unwrap() >= 1);
    while let Some(chunk) = stream.next().await {
        received += chunk.unwrap().len() as u64;
    }
    assert_eq!(received, size);
    let after = f.get("/requests?limit=100").await;
    assert!(after["entries"]
        .as_array()
        .unwrap()
        .iter()
        .any(|r| r["requestId"] == id && r["bytes"] == size && r["outcome"] == "complete"));
    f.close().await;
    std::fs::remove_dir_all(root).unwrap();
}

#[tokio::test]
async fn key_revoked_while_clear_body_is_pending_cannot_mutate_history() {
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    let mut f = Fixture::new().await;
    f.get("/status").await;
    let page = f.get("/requests").await;
    let limited = create_key(
        "revoked clearer".into(),
        WorkspaceGrant {
            scopes: vec![Scope::RequestsManage],
            workspaces: vec!["*".into()],
        },
        None,
    )
    .unwrap();
    let key_id = limited.record.id.clone();
    f.config.keys.push(limited.record);
    f.config.revision += 1;
    f.server
        .configure_integration_api(&serde_json::to_string(&f.config).unwrap())
        .await
        .unwrap();
    let mut stream = tokio::net::TcpStream::connect(("127.0.0.1", f.server.port()))
        .await
        .unwrap();
    let body = Fixture::clear_body(&page).to_string();
    let request=format!("POST {PREFIX}/requests/clear HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer {}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",limited.secret,body.len());
    stream.write_all(request.as_bytes()).await.unwrap();
    stream.write_all(&body.as_bytes()[..1]).await.unwrap();
    for _ in 0..100 {
        let state: Value = serde_json::from_str(&f.server.integration_api_snapshot()).unwrap();
        if state["activeResponses"].as_u64().unwrap() > 0 {
            break;
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    f.config.keys.retain(|key| key.id != key_id);
    f.config.revision += 1;
    f.server
        .configure_integration_api(&serde_json::to_string(&f.config).unwrap())
        .await
        .unwrap();
    let _ = stream.write_all(&body.as_bytes()[1..]).await;
    let mut response = vec![];
    let _ = tokio::time::timeout(Duration::from_secs(2), stream.read_to_end(&mut response)).await;
    assert_eq!(f.get("/requests").await["generation"], 1);
    f.close().await;
}
