#![cfg(feature = "http")]
use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine};
use localsend::http::server::{
    integration::{create_key, ApiConfig, KeyCreation, Limits, Scope, WorkspaceGrant, PREFIX},
    start_with_port,
    web::WebConfig,
    ServerConfigV2, ServerHandle, TlsConfig,
};
use localsend::http::state::ClientInfo;
use serde_json::{json, Value};
use std::{path::PathBuf, time::Duration};
use tokio::sync::{mpsc, oneshot};
const A: &str = "11111111-1111-4111-8111-111111111111";
const B: &str = "22222222-2222-4222-8222-222222222222";
struct Fixture {
    server: ServerHandle,
    client: reqwest::Client,
    root: String,
    temp: PathBuf,
    stop: Option<oneshot::Sender<()>>,
    config: ApiConfig,
    key: KeyCreation,
}
impl Fixture {
    async fn new() -> Self {
        Self::start(false, true).await
    }
    async fn start(tls: bool, directories: bool) -> Self {
        let temp = std::env::temp_dir().join(format!("legnasend-api-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(temp.join("a")).unwrap();
        std::fs::create_dir_all(temp.join("b")).unwrap();
        std::fs::write(temp.join("a/hello.txt"), b"0123456789").unwrap();
        std::fs::write(temp.join("b/secret.txt"), b"other-workspace").unwrap();
        let (stop, rx) = oneshot::channel();
        let (tx, mut events) = mpsc::channel(16);
        tokio::spawn(async move { while events.recv().await.is_some() {} });
        let certificate = tls.then(|| {
            let identity = localsend::crypto::cert::generate_self_signed().unwrap();
            TlsConfig {
                cert: identity.certificate_pem,
                private_key: identity.private_key_pem,
            }
        });
        let server = start_with_port(
            0,
            certificate,
            ClientInfo {
                alias: "API fixture".into(),
                version: "2.2".into(),
                device_model: None,
                device_type: None,
                token: "test-fingerprint".into(),
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
        if directories {
            server.configure_directory_workspaces(&json!({"revision":1,"enabled":true,"workspaces":[{"id":A,"name":"Public","slug":"public","root":temp.join("a"),"generation":1,"visible":true},{"id":B,"name":"Hidden","slug":"hidden","root":temp.join("b"),"generation":1,"visible":false}]}).to_string()).await.unwrap();
        }
        let client = reqwest::Client::builder()
            .no_proxy()
            .danger_accept_invalid_certs(true)
            .timeout(Duration::from_secs(5))
            .build()
            .unwrap();
        let root = format!(
            "{}://127.0.0.1:{}",
            if tls { "https" } else { "http" },
            server.port()
        );
        let key = create_key(
            "Fixture key".into(),
            WorkspaceGrant {
                scopes: vec![
                    Scope::Service,
                    Scope::Workspaces,
                    Scope::Files,
                    Scope::Requests,
                ],
                workspaces: vec![A.into()],
            },
            None,
        )
        .unwrap();
        let config = ApiConfig {
            revision: 1,
            enabled: true,
            global_limits: Limits {
                per_second: 1000,
                per_minute: 60000,
                concurrent: 16,
            },
            key_limits: Limits {
                per_second: 1000,
                per_minute: 60000,
                concurrent: 8,
            },
            anonymous_limits: Limits {
                per_second: 1000,
                per_minute: 60000,
                concurrent: 4,
            },
            keys: vec![key.record.clone()],
            ..ApiConfig::default()
        };
        server
            .configure_integration_api(&serde_json::to_string(&config).unwrap())
            .await
            .unwrap();
        Self {
            server,
            client,
            root,
            temp,
            stop: Some(stop),
            config,
            key,
        }
    }
    fn get(&self, path: &str) -> reqwest::RequestBuilder {
        self.client
            .get(format!("{}{PREFIX}{path}", self.root))
            .bearer_auth(&self.key.secret)
    }
    async fn apply(&mut self) {
        self.config.revision += 1;
        self.server
            .configure_integration_api(&serde_json::to_string(&self.config).unwrap())
            .await
            .unwrap();
    }
    async fn active(&self, wanted: u64) {
        for _ in 0..200 {
            let snapshot: Value =
                serde_json::from_str(&self.server.integration_api_snapshot()).unwrap();
            if snapshot["activeResponses"] == wanted {
                return;
            }
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
        panic!("active snapshot {}", self.server.integration_api_snapshot());
    }
    fn content(&self, name: &str) -> String {
        format!(
            "/workspaces/{A}/files/{}/content?generation=1",
            URL_SAFE_NO_PAD.encode(name)
        )
    }
    async fn stop(mut self) {
        if let Some(stop) = self.stop.take() {
            let _ = stop.send(());
        }
        self.server.wait_stopped().await;
        std::fs::remove_dir_all(&self.temp).unwrap();
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        if let Some(stop) = self.stop.take() {
            let _ = stop.send(());
        }
        let _ = std::fs::remove_dir_all(&self.temp);
    }
}
async fn body(response: reqwest::Response, status: u16) -> Value {
    assert_eq!(response.status().as_u16(), status);
    response.json().await.unwrap()
}
#[tokio::test]
async fn authenticated_service_and_redacted_management_snapshot() {
    let f = Fixture::new().await;
    let value = body(f.get("/status").send().await.unwrap(), 200).await;
    assert_eq!(value["port"], f.server.port());
    assert_eq!(value["principal"], f.key.record.id);
    assert_eq!(value["fixedWindowSeconds"], json!([1, 60]));
    let snapshot = f.server.integration_api_snapshot();
    assert!(!snapshot.contains(&f.key.secret));
    assert!(!snapshot.contains(&f.key.record.verifier));
    assert!(!snapshot.contains(&f.temp.display().to_string()));
    let value = body(f.get("/capabilities").send().await.unwrap(), 200).await;
    assert_eq!(value["readOnly"], false);
    assert_eq!(value["operations"].as_array().unwrap().len(), 41);
    f.active(0).await;
    f.stop().await;
}
#[tokio::test]
async fn keys_are_action_and_workspace_scoped_and_invalid_tokens_never_downgrade() {
    let mut f = Fixture::new().await;
    let index = body(f.get("/workspaces").send().await.unwrap(), 200).await;
    assert_eq!(index["workspaces"].as_array().unwrap().len(), 1);
    assert_eq!(index["workspaces"][0]["id"], A);
    body(
        f.get(&format!("/workspaces/{B}")).send().await.unwrap(),
        404,
    )
    .await;
    f.config.keys[0].grant.scopes = vec![Scope::Service];
    f.apply().await;
    body(f.get("/workspaces").send().await.unwrap(), 403).await;
    f.config.auth_required = false;
    f.apply().await;
    body(
        f.client
            .get(format!("{}{PREFIX}/status", f.root))
            .send()
            .await
            .unwrap(),
        200,
    )
    .await;
    for value in [
        "Bearer broken",
        "Basic x",
        &format!("Bearer {}x", f.key.secret),
    ] {
        let r = f
            .client
            .get(format!("{}{PREFIX}/status", f.root))
            .header("Authorization", value)
            .send()
            .await
            .unwrap();
        assert!(r.headers().contains_key("www-authenticate"));
        body(r, 401).await;
    }
    f.stop().await;
}
#[tokio::test]
async fn anonymous_switch_preserves_hidden_and_password_protection() {
    let mut f = Fixture::new().await;
    body(
        f.client
            .get(format!("{}{PREFIX}/status", f.root))
            .send()
            .await
            .unwrap(),
        401,
    )
    .await;
    let hash = localsend::http::server::directory_auth::hash_password("fixture-password".into())
        .await
        .unwrap();
    f.server.configure_directory_workspaces(&json!({"revision":2,"enabled":true,"workspaces":[{"id":A,"name":"Protected","slug":"public","root":f.temp.join("a"),"generation":2,"visible":true,"passwordHash":hash},{"id":B,"name":"Hidden","slug":"hidden","root":f.temp.join("b"),"generation":1,"visible":false}]}).to_string()).await.unwrap();
    f.config.auth_required = false;
    f.apply().await;
    let index = body(
        f.client
            .get(format!("{}{PREFIX}/workspaces", f.root))
            .send()
            .await
            .unwrap(),
        200,
    )
    .await;
    assert_eq!(index["workspaces"], json!([]));
    for id in [A, B] {
        assert_eq!(
            f.client
                .get(format!(
                    "{}{PREFIX}/workspaces/{id}/state?generation=2",
                    f.root
                ))
                .send()
                .await
                .unwrap()
                .status(),
            404
        );
        body(
            f.client
                .get(format!("{}{PREFIX}/workspaces/{id}", f.root))
                .send()
                .await
                .unwrap(),
            404,
        )
        .await;
    }
    let index = body(f.get("/workspaces").send().await.unwrap(), 200).await;
    assert_eq!(index["workspaces"][0]["protected"], true);
    let response = f
        .get(
            &f.content("hello.txt")
                .replace("generation=1", "generation=2"),
        )
        .send()
        .await
        .unwrap();
    assert_eq!(response.bytes().await.unwrap().as_ref(), b"0123456789");
    let browser = f
        .client
        .get(format!(
            "{}/api/legnasend/v1/workspaces/{A}/files?generation=2",
            f.root
        ))
        .send()
        .await
        .unwrap();
    assert_eq!(browser.status(), 401);
    f.stop().await;
}
#[tokio::test]
async fn original_bytes_ranges_generation_and_traversal_are_preserved() {
    let f = Fixture::new().await;
    let page = body(
        f.get(&format!("/workspaces/{A}/files?generation=1"))
            .send()
            .await
            .unwrap(),
        200,
    )
    .await;
    assert_eq!(page["entries"][0]["name"], "hello.txt");
    let url = f.content("hello.txt");
    let head = f
        .client
        .head(format!("{}{PREFIX}{url}", f.root))
        .bearer_auth(&f.key.secret)
        .send()
        .await
        .unwrap();
    assert_eq!(head.status(), 200);
    assert_eq!(head.headers()["content-length"], "10");
    let etag = head.headers()["etag"].to_str().unwrap().to_owned();
    assert!(head.bytes().await.unwrap().is_empty());
    let response = f
        .get(&url)
        .header("Range", "bytes=3-6")
        .header("If-Match", &etag)
        .send()
        .await
        .unwrap();
    assert_eq!(response.status(), 206);
    assert_eq!(response.headers()["content-range"], "bytes 3-6/10");
    assert_eq!(response.bytes().await.unwrap().as_ref(), b"3456");
    body(
        f.get(&url.replace("generation=1", "generation=999"))
            .send()
            .await
            .unwrap(),
        409,
    )
    .await;
    body(
        f.get(&f.content("../outside.txt")).send().await.unwrap(),
        400,
    )
    .await;
    for query in ["generation=1&generation=1", "generation=1&token=SECRET"] {
        body(
            f.get(&format!("/workspaces/{A}/files?{query}"))
                .send()
                .await
                .unwrap(),
            400,
        )
        .await;
    }
    f.active(0).await;
    f.stop().await;
}
#[tokio::test]
async fn per_second_and_minute_limits_are_independent_and_native_routes_unaffected() {
    let mut f = Fixture::new().await;
    f.config.key_limits.per_second = 1;
    f.config.key_limits.per_minute = 1;
    f.apply().await;
    body(f.get("/status").send().await.unwrap(), 200).await;
    let response = f.get("/status").send().await.unwrap();
    assert!(
        response.headers()["retry-after"]
            .to_str()
            .unwrap()
            .parse::<u64>()
            .unwrap()
            > 0
    );
    let limited = body(response, 429).await;
    assert_eq!(limited["error"]["reason"], "key.minute");
    let native = f
        .client
        .get(format!("{}/api/localsend/v2/info", f.root))
        .send()
        .await
        .unwrap();
    assert_eq!(native.status(), 200);
    assert_eq!(
        f.client
            .get(format!("{}/api/legnasend/v1/workspaces", f.root))
            .send()
            .await
            .unwrap()
            .status(),
        200
    );
    f.config.global_limits.per_second = 1;
    f.config.global_limits.per_minute = 1;
    f.config.key_limits.per_second = 100;
    f.config.key_limits.per_minute = 100;
    f.apply().await;
    let limited = body(f.get("/status").send().await.unwrap(), 429).await;
    assert_eq!(limited["error"]["reason"], "global.minute");
    f.stop().await;
}
#[tokio::test]
async fn burst_admission_is_atomic_across_parallel_connections() {
    let mut f = Fixture::new().await;
    f.config.global_limits.per_minute = 7;
    f.apply().await;
    let tasks = (0..40)
        .map(|_| {
            let request = f.get("/status");
            tokio::spawn(async move {
                let r = request.send().await.unwrap();
                let status = r.status();
                let _ = r.bytes().await;
                status
            })
        })
        .collect::<Vec<_>>();
    let mut ok = 0;
    for task in tasks {
        let status = task.await.unwrap();
        if status == 200 {
            ok += 1;
        } else {
            assert_eq!(status, 429);
        }
    }
    assert_eq!(ok, 7);
    f.active(0).await;
    f.stop().await;
}
#[tokio::test]
async fn cors_is_allowlisted_and_preflight_does_not_need_a_key() {
    let mut f = Fixture::new().await;
    f.config.allowed_origins = vec!["https://client.example".into()];
    f.apply().await;
    let response = f
        .client
        .request(
            reqwest::Method::OPTIONS,
            format!("{}{PREFIX}/status", f.root),
        )
        .header("Origin", "https://client.example")
        .header("Access-Control-Request-Method", "GET")
        .header("Access-Control-Request-Headers", "authorization")
        .send()
        .await
        .unwrap();
    assert_eq!(response.status(), 204);
    assert_eq!(
        response.headers()["access-control-allow-origin"],
        "https://client.example"
    );
    assert!(!response
        .headers()
        .contains_key("access-control-allow-credentials"));
    let response = f
        .get("/status")
        .header("Origin", "https://untrusted.example")
        .send()
        .await
        .unwrap();
    assert!(!response
        .headers()
        .contains_key("access-control-allow-origin"));
    body(response, 403).await;
    let response = f
        .client
        .get(format!("{}{PREFIX}/status", f.root))
        .header("Origin", "https://client.example")
        .send()
        .await
        .unwrap();
    assert_eq!(
        response.headers()["access-control-allow-origin"],
        "https://client.example"
    );
    body(response, 401).await;
    f.stop().await;
}
#[tokio::test]
async fn openapi_describes_only_real_routes_and_localizes_human_text() {
    let mut f = Fixture::new().await;
    let en = body(f.get("/openapi.json").send().await.unwrap(), 200).await;
    let zh = body(f.get("/openapi.json?lang=zh-TW").send().await.unwrap(), 200).await;
    assert_eq!(en["openapi"], "3.1.0");
    let workspace_properties = &en["components"]["schemas"]["Workspace"]["properties"];
    assert_eq!(workspace_properties["readOnly"]["type"], "boolean");
    assert_eq!(workspace_properties["allowUpload"]["type"], "boolean");
    assert!(workspace_properties["readOnly"].get("const").is_none());
    assert_eq!(workspace_properties["backend"]["enum"], json!(["filesystem", "documents"]));
    assert_eq!(workspace_properties["capabilities"]["properties"]["preview"]["type"], "boolean");
    assert_eq!(en["components"]["schemas"]["Entry"]["properties"]["size"]["type"], json!(["integer", "null"]));
    assert_eq!(en["servers"][0]["url"], PREFIX);
    assert_eq!(en["paths"].as_object().unwrap().len(), 41);
    assert_ne!(
        en["paths"]["/status"]["get"]["summary"],
        zh["paths"]["/status"]["get"]["summary"]
    );
    assert_eq!(
        en["paths"]["/workspaces/{workspaceId}/files/{fileId}/content"]["head"]["operationId"],
        "headContent"
    );
    f.config.auth_required = false;
    f.apply().await;
    let open = body(f.get("/openapi.json").send().await.unwrap(), 200).await;
    assert_eq!(
        open["paths"]["/status"]["get"]["security"],
        json!([{"bearerAuth":[]},{}])
    );
    assert!(open["paths"]["/requests"]["get"]["security"].is_null());
    body(
        f.get("/openapi.json?lang=invalid").send().await.unwrap(),
        400,
    )
    .await;
    f.stop().await;
}
#[tokio::test]
async fn audit_is_bounded_paginated_and_does_not_record_credentials_or_raw_urls() {
    let f = Fixture::new().await;
    for _ in 0..205 {
        let response = f
            .get("/status?token=VERY-SECRET&path=PRIVATE")
            .send()
            .await
            .unwrap();
        assert_eq!(response.status(), 400);
        let _ = response.bytes().await;
    }
    let first = body(f.get("/requests?limit=100").send().await.unwrap(), 200).await;
    assert_eq!(first["entries"].as_array().unwrap().len(), 100);
    let text = first.to_string();
    for secret in [
        "VERY-SECRET",
        "PRIVATE",
        &f.key.secret,
        &f.key.record.verifier,
        &f.temp.display().to_string(),
    ] {
        assert!(!text.contains(secret));
    }
    let second = body(
        f.get(&format!("/requests?after={}&limit=100", first["next"]))
            .send()
            .await
            .unwrap(),
        200,
    )
    .await;
    assert!(second["next"].as_u64().unwrap() > first["next"].as_u64().unwrap());
    let snapshot: Value = serde_json::from_str(&f.server.integration_api_snapshot()).unwrap();
    assert_eq!(snapshot["recordCount"], 200);
    f.stop().await;
}
#[tokio::test]
async fn config_validation_is_atomic_and_does_not_echo_unknown_secret_fields() {
    let f = Fixture::new().await;
    let previous = f.server.integration_api_snapshot();
    let mut bad = serde_json::to_value(&f.config).unwrap();
    bad["revision"] = json!(2);
    bad["keys"][0]["token"] = json!("SECRET");
    let error = f
        .server
        .configure_integration_api(&bad.to_string())
        .await
        .unwrap_err();
    assert!(!error.to_string().contains("SECRET"));
    assert_eq!(f.server.integration_api_snapshot(), previous);
    assert!(f
        .server
        .configure_integration_api(&serde_json::to_string(&f.config).unwrap())
        .await
        .is_err());
    bad = serde_json::to_value(&f.config).unwrap();
    bad["revision"] = json!(2);
    bad["globalLimits"]["perSecond"] = json!(1001);
    assert!(f
        .server
        .configure_integration_api(&bad.to_string())
        .await
        .is_err());
    f.stop().await;
}
#[tokio::test]
async fn revoking_one_key_releases_stalled_stream_permits_without_stopping_other_keys() {
    let mut f = Fixture::new().await;
    std::fs::File::create(f.temp.join("a/big.bin"))
        .unwrap()
        .set_len(64 * 1024 * 1024)
        .unwrap();
    let other = create_key("Second".into(), f.key.record.grant.clone(), None).unwrap();
    f.config.keys.push(other.record.clone());
    f.config.key_limits.concurrent = 1;
    f.apply().await;
    let response = f.get(&f.content("big.bin")).send().await.unwrap();
    assert_eq!(response.status(), 200);
    f.active(1).await;
    let limited = body(f.get("/status").send().await.unwrap(), 429).await;
    assert_eq!(limited["error"]["reason"], "key.concurrent");
    f.config.keys.retain(|key| key.id != f.key.record.id);
    f.apply().await;
    f.active(0).await; // peer has not consumed/dropped its response
    assert!(response.bytes().await.is_err());
    body(f.get("/status").send().await.unwrap(), 401).await;
    let response = f
        .client
        .get(format!("{}{PREFIX}{}", f.root, f.content("hello.txt")))
        .bearer_auth(&other.secret)
        .send()
        .await
        .unwrap();
    assert_eq!(response.bytes().await.unwrap().as_ref(), b"0123456789");
    f.stop().await;
}
#[tokio::test]
async fn closing_source_or_disabling_api_releases_streams_but_not_native_info() {
    let mut f = Fixture::new().await;
    std::fs::File::create(f.temp.join("a/big.bin"))
        .unwrap()
        .set_len(64 * 1024 * 1024)
        .unwrap();
    let response = f.get(&f.content("big.bin")).send().await.unwrap();
    f.active(1).await;
    f.server
        .configure_directory_workspaces(
            &json!({"revision":2,"enabled":true,"workspaces":[]}).to_string(),
        )
        .await
        .unwrap();
    f.active(0).await;
    assert!(response.bytes().await.is_err());
    f.config.enabled = false;
    f.apply().await;
    body(f.get("/status").send().await.unwrap(), 404).await;
    assert_eq!(
        f.client
            .get(format!("{}/api/localsend/v2/info", f.root))
            .send()
            .await
            .unwrap()
            .status(),
        200
    );
    f.stop().await;
}
#[tokio::test]
async fn tls_client_certificate_policy_is_not_changed_by_api_enablement() {
    let f = Fixture::start(true, false).await;
    assert!(f.get("/status").send().await.is_err());
    assert!(f
        .client
        .get(format!("{}/api/localsend/v2/info", f.root))
        .send()
        .await
        .is_err());
    f.stop().await;
    let f = Fixture::start(true, true).await;
    body(f.get("/status").send().await.unwrap(), 200).await;
    f.stop().await;
}

#[tokio::test]
async fn expiry_releases_a_stalled_producer_and_rename_preserves_budget() {
    let mut f = Fixture::new().await;
    f.config.key_limits.per_minute = 1;
    f.apply().await;
    body(f.get("/status").send().await.unwrap(), 200).await;
    f.config.keys[0].name = "Renamed".into();
    f.apply().await;
    let limited = body(f.get("/status").send().await.unwrap(), 429).await;
    assert_eq!(limited["error"]["reason"], "key.minute");
    f.config.key_limits.per_minute = 100;
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_secs();
    f.config.keys[0].expires_at = Some(now + 2);
    f.apply().await;
    std::fs::File::create(f.temp.join("a/big.bin"))
        .unwrap()
        .set_len(64 * 1024 * 1024)
        .unwrap();
    let response = f.get(&f.content("big.bin")).send().await.unwrap();
    assert_eq!(response.status(), 200);
    tokio::time::sleep(Duration::from_secs(3)).await;
    f.active(0).await;
    assert!(response.bytes().await.is_err());
    body(f.get("/status").send().await.unwrap(), 401).await;
    f.stop().await;
}
#[tokio::test]
async fn anonymous_budget_and_allowed_origin_errors_expose_precise_remaining_counts() {
    let mut f = Fixture::new().await;
    f.config.auth_required = false;
    f.config.anonymous_limits.per_minute = 1;
    f.config.allowed_origins = vec!["https://client.example".into()];
    f.apply().await;
    body(
        f.client
            .get(format!("{}{PREFIX}/status", f.root))
            .send()
            .await
            .unwrap(),
        200,
    )
    .await;
    let response = f
        .client
        .get(format!("{}{PREFIX}/status", f.root))
        .header("Origin", "https://client.example")
        .send()
        .await
        .unwrap();
    assert_eq!(
        response.headers()["access-control-allow-origin"],
        "https://client.example"
    );
    assert_eq!(response.headers()["x-legnasend-remaining-minute"], "0");
    assert_eq!(
        body(response, 429).await["error"]["reason"],
        "anonymous.minute"
    );
    body(f.get("/status").send().await.unwrap(), 200).await;
    f.stop().await;
}
#[tokio::test]
async fn enabled_defaults_off_and_dropping_a_consumer_releases_its_slot() {
    let mut f = Fixture::new().await;
    f.config.enabled = false;
    f.apply().await;
    body(f.get("/status").send().await.unwrap(), 404).await;
    f.config.enabled = true;
    f.config.key_limits.concurrent = 1;
    f.apply().await;
    std::fs::File::create(f.temp.join("a/big.bin"))
        .unwrap()
        .set_len(64 * 1024 * 1024)
        .unwrap();
    let response = f.get(&f.content("big.bin")).send().await.unwrap();
    f.active(1).await;
    drop(response);
    f.active(0).await;
    body(f.get("/status").send().await.unwrap(), 200).await;
    f.stop().await;
    assert!(!ApiConfig::default().enabled);
    assert!(ApiConfig::default().auth_required);
}

#[tokio::test]
async fn disabling_api_releases_an_active_body_and_reenable_keeps_original_service() {
    let mut f = Fixture::new().await;
    std::fs::File::create(f.temp.join("a/big.bin"))
        .unwrap()
        .set_len(64 * 1024 * 1024)
        .unwrap();
    let response = f.get(&f.content("big.bin")).send().await.unwrap();
    f.active(1).await;
    f.config.enabled = false;
    f.apply().await;
    f.active(0).await;
    assert!(response.bytes().await.is_err());
    body(f.get("/status").send().await.unwrap(), 404).await;
    assert_eq!(
        f.client
            .get(format!("{}/api/localsend/v2/info", f.root))
            .send()
            .await
            .unwrap()
            .status(),
        200
    );
    f.config.enabled = true;
    f.apply().await;
    body(f.get("/status").send().await.unwrap(), 200).await;
    f.stop().await;
}

#[tokio::test]
async fn stopping_listener_drops_stalled_producers_and_releases_all_permits() {
    let mut f = Fixture::new().await;
    std::fs::File::create(f.temp.join("a/big.bin"))
        .unwrap()
        .set_len(64 * 1024 * 1024)
        .unwrap();
    let response = f.get(&f.content("big.bin")).send().await.unwrap();
    f.active(1).await;
    f.stop.take().unwrap().send(()).unwrap();
    tokio::time::timeout(Duration::from_secs(3), f.server.wait_stopped())
        .await
        .unwrap();
    f.active(0).await;
    assert!(response.bytes().await.is_err());
    assert!(f.get("/status").send().await.is_err());
    f.stop().await;
}

#[tokio::test]
async fn local_console_uses_real_auth_ranges_history_and_pinned_mtls() {
    for tls in [false, true] {
        let mut f = Fixture::start(tls, false).await;
        let call = |value: Value| value.to_string();
        let status: Value = serde_json::from_str(
            &f.server
                .integration_api_request(&call(
                    json!({"operation":"getStatus","token":f.key.secret}),
                ))
                .await
                .unwrap(),
        )
        .unwrap();
        assert_eq!(status["status"], 200);
        assert_eq!(
            serde_json::from_str::<Value>(status["body"].as_str().unwrap()).unwrap()["https"],
            tls
        );
        let denied: Value = serde_json::from_str(
            &f.server
                .integration_api_request(&call(json!({"operation":"getStatus"})))
                .await
                .unwrap(),
        )
        .unwrap();
        assert_eq!(denied["status"], 401);
        f.server.configure_directory_workspaces(&json!({"revision":1,"enabled":true,"workspaces":[{"id":A,"name":"Public","slug":"public","root":f.temp.join("a"),"generation":1,"visible":true}]}).to_string()).await.unwrap();
        let params =
            json!({"workspaceId":A,"fileId":URL_SAFE_NO_PAD.encode("hello.txt"),"generation":"1"});
        let sample: Value = serde_json::from_str(
            &f.server
                .integration_api_request(&call(
                    json!({"operation":"getContent","token":f.key.secret,"parameters":params}),
                ))
                .await
                .unwrap(),
        )
        .unwrap();
        assert_eq!(sample["status"], 206);
        assert_eq!(sample["binary"], true);
        assert_eq!(sample["body"], "30313233343536373839");
        assert_eq!(sample["bytes"], 10);
        let head: Value=serde_json::from_str(&f.server.integration_api_request(&call(json!({"operation":"getContent","head":true,"token":f.key.secret,"parameters":params}))).await.unwrap()).unwrap();
        assert_eq!(head["status"], 200);
        assert_eq!(head["body"], "");
        assert_eq!(head["headers"]["content-length"], "10");
        let history = f
            .server
            .integration_api_request(&call(
                json!({"operation":"listRequests","token":f.key.secret}),
            ))
            .await
            .unwrap();
        assert!(!history.contains(&f.key.secret));
        assert!(!history.contains(&f.key.record.verifier));
        let history: Value = serde_json::from_str(&history).unwrap();
        assert_eq!(history["status"], 200);
        assert!(
            serde_json::from_str::<Value>(history["body"].as_str().unwrap()).unwrap()["entries"]
                .as_array()
                .unwrap()
                .len()
                >= 4
        );
        f.config.keys.clear();
        f.apply().await;
        let revoked: Value = serde_json::from_str(
            &f.server
                .integration_api_request(&call(
                    json!({"operation":"getStatus","token":f.key.secret}),
                ))
                .await
                .unwrap(),
        )
        .unwrap();
        assert_eq!(revoked["status"], 401);
        f.stop().await;
    }
}

#[tokio::test]
async fn console_caps_binary_output_rejects_arbitrary_urls_and_stops_with_listener() {
    let mut f = Fixture::new().await;
    std::fs::write(f.temp.join("a/large.bin"), vec![65u8; 128 * 1024]).unwrap();
    let result=f.server.integration_api_request(&json!({"operation":"getContent","token":f.key.secret,"range":"bytes=0-65535","parameters":{"workspaceId":A,"fileId":URL_SAFE_NO_PAD.encode("large.bin"),"generation":"1"}}).to_string()).await.unwrap();
    let result: Value = serde_json::from_str(&result).unwrap();
    assert_eq!(result["status"], 206);
    assert_eq!(result["bytes"], 4096);
    assert_eq!(result["truncated"], true);
    assert_eq!(result["body"].as_str().unwrap().len(), 8192);
    assert!(f
        .server
        .integration_api_request(r#"{"operation":"getStatus","url":"http://elsewhere/"}"#)
        .await
        .is_err());
    let _ = f.stop.take().unwrap().send(());
    f.server.wait_stopped().await;
    assert!(f
        .server
        .integration_api_request(r#"{"operation":"getStatus"}"#)
        .await
        .is_err());
    f.stop().await;
}

#[tokio::test]
async fn local_console_streams_picked_file_over_real_http_and_pinned_tls_without_source_leaks() {
    for tls in [false, true] {
        let mut f = Fixture::start(tls, true).await;
        let upload = create_key(
            "Console upload".into(),
            WorkspaceGrant {
                scopes: vec![Scope::Upload],
                workspaces: vec![A.into()],
            },
            None,
        )
        .unwrap();
        f.config.keys.push(upload.record.clone());
        f.apply().await;
        let source = f.temp.join("private-local-source-name.bin");
        let bytes: Vec<u8> = (0..(3 * 64 * 1024 + 27)).map(|i| (i % 251) as u8).collect();
        std::fs::write(&source, &bytes).unwrap();
        let request = json!({"operation":"uploadFile","token":upload.secret,"uploadPath":source,"uploadSize":bytes.len(),"parameters":{"workspaceId":A,"generation":"1","path":"from-console/nested.bin"}});
        let result: Value = serde_json::from_str(
            &f.server
                .integration_api_request(&request.to_string())
                .await
                .unwrap(),
        )
        .unwrap();
        assert_eq!(result["status"], 201, "{result}");
        assert_eq!(result["binary"], false);
        assert_eq!(
            std::fs::read(f.temp.join("a/from-console/nested.bin")).unwrap(),
            bytes
        );
        // A peer may close while rejecting a still-streaming body. Preserve
        // either its real conflict status or a generic transport failure, never
        // synthesize success or overwrite the published file.
        match f.server.integration_api_request(&request.to_string()).await {
            Ok(value) => assert_eq!(
                serde_json::from_str::<Value>(&value).unwrap()["status"],
                409
            ),
            Err(error) => assert_eq!(error.to_string(), "Console request failed"),
        }
        assert_eq!(
            std::fs::read(f.temp.join("a/from-console/nested.bin")).unwrap(),
            bytes
        );
        // Zero-length source isolates HTTP rejection status from a transport
        // reset when a server rejects a streaming body before consuming it.
        let empty_source = f.temp.join("private-empty-source.bin");
        std::fs::write(&empty_source, []).unwrap();
        let mut rejection_request = request.clone();
        rejection_request["uploadPath"] = json!(empty_source);
        rejection_request["uploadSize"] = json!(0);
        let conflict: Value = serde_json::from_str(
            &f.server
                .integration_api_request(&rejection_request.to_string())
                .await
                .unwrap(),
        )
        .unwrap();
        assert_eq!(conflict["status"], 409);
        let mut denied = rejection_request.clone();
        denied["token"] = json!(f.key.secret);
        denied["parameters"]["path"] = json!("denied.bin");
        let denied: Value = serde_json::from_str(
            &f.server
                .integration_api_request(&denied.to_string())
                .await
                .unwrap(),
        )
        .unwrap();
        assert_eq!(denied["status"], 403);
        assert!(!f.temp.join("a/denied.bin").exists());
        f.config.keys.retain(|key| key.id != upload.record.id);
        f.apply().await;
        let revoked: Value = serde_json::from_str(
            &f.server
                .integration_api_request(&rejection_request.to_string())
                .await
                .unwrap(),
        )
        .unwrap();
        assert_eq!(revoked["status"], 401);
        let history = f
            .get("/requests")
            .send()
            .await
            .unwrap()
            .text()
            .await
            .unwrap();
        for output in [
            result.to_string(),
            history,
            f.server.integration_api_snapshot(),
        ] {
            assert!(!output.contains(source.to_str().unwrap()));
            assert!(!output.contains("private-local-source-name.bin"));
            assert!(!output.contains(&upload.secret));
        }
        let mut missing = request;
        missing["uploadPath"] = json!(f.temp.join("private-missing-source.bin"));
        let error = f
            .server
            .integration_api_request(&missing.to_string())
            .await
            .unwrap_err()
            .to_string();
        assert_eq!(error, "Invalid upload source");
        f.stop().await;
    }
}

#[tokio::test]
async fn local_console_owned_descriptor_upload_and_empty_directory_are_real_requests() {
    let mut f = Fixture::new().await;
    let upload = create_key(
        "Descriptor upload".into(),
        WorkspaceGrant {
            scopes: vec![Scope::Upload],
            workspaces: vec![A.into()],
        },
        None,
    )
    .unwrap();
    f.config.keys.push(upload.record.clone());
    f.apply().await;
    let source = f.temp.join("private-descriptor-source.txt");
    std::fs::write(&source, b"descriptor bytes").unwrap();
    let request = json!({"operation":"uploadFile","token":upload.secret,"uploadSize":16,"parameters":{"workspaceId":A,"generation":"1","path":"descriptor.txt"}});
    let result: Value = serde_json::from_str(
        &f.server
            .integration_api_request_with_file(
                &request.to_string(),
                Some(std::fs::File::open(&source).unwrap()),
            )
            .await
            .unwrap(),
    )
    .unwrap();
    assert_eq!(result["status"], 201, "{result}");
    assert_eq!(
        std::fs::read(f.temp.join("a/descriptor.txt")).unwrap(),
        b"descriptor bytes"
    );
    let directory = json!({"operation":"uploadFile","token":upload.secret,"parameters":{"workspaceId":A,"generation":"1","path":"empty-created","directory":"true"}});
    let result: Value = serde_json::from_str(
        &f.server
            .integration_api_request(&directory.to_string())
            .await
            .unwrap(),
    )
    .unwrap();
    assert_eq!(result["status"], 201, "{result}");
    assert!(f.temp.join("a/empty-created").is_dir());
    f.stop().await;
}

#[cfg(unix)]
#[tokio::test]
async fn local_console_streams_known_length_sequential_descriptor() {
    use std::io::Write;
    use std::os::fd::OwnedFd;
    let mut f = Fixture::new().await;
    let upload = create_key(
        "Sequential upload".into(),
        WorkspaceGrant {
            scopes: vec![Scope::Upload],
            workspaces: vec![A.into()],
        },
        None,
    )
    .unwrap();
    f.config.keys.push(upload.record.clone());
    f.apply().await;
    let (reader, mut writer) = std::os::unix::net::UnixStream::pair().unwrap();
    writer.write_all(b"sequential bytes").unwrap();
    drop(writer);
    let descriptor: OwnedFd = reader.into();
    let request = json!({"operation":"uploadFile","token":upload.secret,"uploadSize":16,"parameters":{"workspaceId":A,"generation":"1","path":"sequential.txt"}});
    let response = f
        .server
        .integration_api_request_with_file(&request.to_string(), Some(descriptor.into()))
        .await
        .unwrap();
    assert_eq!(
        serde_json::from_str::<Value>(&response).unwrap()["status"],
        201
    );
    assert_eq!(
        std::fs::read(f.temp.join("a/sequential.txt")).unwrap(),
        b"sequential bytes"
    );
    f.stop().await;
}

#[tokio::test]
async fn bearer_directory_filter_matches_shared_cookie_listing_contract() {
    let f = Fixture::new().await;
    std::fs::write(f.temp.join("a/NEEDLE-中文.txt"), b"visible").unwrap();
    std::fs::write(f.temp.join("a/other.txt"), b"not matching").unwrap();
    let query = form_urlencoded::Serializer::new(String::new())
        .append_pair("generation", "1")
        .append_pair("filter", "needle-中文")
        .finish();
    let response = f
        .get(&format!("/workspaces/{A}/files?{query}"))
        .send()
        .await
        .unwrap();
    let page = body(response, 200).await;
    assert_eq!(page["filter"], "needle-中文");
    assert_eq!(page["entries"].as_array().unwrap().len(), 1);
    assert_eq!(page["entries"][0]["name"], "NEEDLE-中文.txt");
    let cookie = f
        .client
        .get(format!(
            "{}/api/legnasend/v1/workspaces/{A}/files?{query}",
            f.root
        ))
        .send()
        .await
        .unwrap();
    assert_eq!(cookie.status(), 200);
    assert_eq!(cookie.json::<Value>().await.unwrap(), page);
    let denied = f
        .client
        .get(format!("{}{PREFIX}/workspaces/{A}/files?{query}", f.root))
        .send()
        .await
        .unwrap();
    assert_eq!(denied.status(), 401);
    f.stop().await;
}

#[tokio::test]
async fn workspace_state_is_scoped_bounded_and_reports_content_versions() {
    let mut f = Fixture::new().await;
    let id = URL_SAFE_NO_PAD.encode("hello.txt");
    let state = format!("/workspaces/{A}/state?generation=1&ids={id}");
    let head = f.get(&f.content("hello.txt")).send().await.unwrap();
    let version = head.headers()["etag"].to_str().unwrap().to_owned();
    let console: Value = serde_json::from_str(&f.server.integration_api_request(&json!({"operation":"getWorkspaceState","token":f.key.secret,"parameters":{"workspaceId":A,"generation":"1","ids":id}}).to_string()).await.unwrap()).unwrap();
    assert_eq!(console["status"], 200);
    f.config.auth_required = false;
    f.apply().await;
    assert_eq!(
        f.client
            .get(format!("{}{PREFIX}{state}", f.root))
            .send()
            .await
            .unwrap()
            .status(),
        200
    );
    let value: Value = f.get(&state).send().await.unwrap().json().await.unwrap();
    assert_eq!(value["entries"][0]["version"], version);
    assert!(!value.to_string().contains(f.temp.to_str().unwrap()));
    tokio::time::sleep(Duration::from_millis(10)).await;
    std::fs::write(f.temp.join("a/hello.txt"), b"abcdefghij").unwrap();
    let changed: Value = f.get(&state).send().await.unwrap().json().await.unwrap();
    assert_ne!(changed["entries"][0]["version"], version);
    assert_eq!(changed["entries"][0]["size"], 10);
    std::fs::remove_file(f.temp.join("a/hello.txt")).unwrap();
    let missing: Value = f.get(&state).send().await.unwrap().json().await.unwrap();
    assert_eq!(missing["missing"][0], id);
    for ids in [
        format!("{id},{id}"),
        URL_SAFE_NO_PAD.encode("sub/file"),
        URL_SAFE_NO_PAD.encode("../outside"),
        (0..65)
            .map(|i| URL_SAFE_NO_PAD.encode(format!("file{i}")))
            .collect::<Vec<_>>()
            .join(","),
    ] {
        assert_eq!(
            f.get(&format!("/workspaces/{A}/state?generation=1&ids={ids}"))
                .send()
                .await
                .unwrap()
                .status(),
            400
        );
    }
    assert_eq!(
        f.get(&format!("/workspaces/{A}/state?generation=2"))
            .send()
            .await
            .unwrap()
            .status(),
        409
    );
    assert_eq!(
        f.get(&format!("/workspaces/{B}/state?generation=1"))
            .send()
            .await
            .unwrap()
            .status(),
        404
    );
    f.config.keys[0].grant.scopes.retain(|s| *s != Scope::Files);
    f.apply().await;
    assert_eq!(f.get(&state).send().await.unwrap().status(), 403);
    f.stop().await;
}

#[tokio::test]
async fn workspace_state_console_and_wire_accept_full_ids_budget_only_on_that_read() {
    let f = Fixture::new().await;
    fn ids(total: usize) -> String {
        let sizes = if total == 4096 {
            vec![48; 62].into_iter().chain([23, 25]).collect::<Vec<_>>()
        } else {
            vec![96; 62].into_iter().chain([71, 73]).collect::<Vec<_>>()
        };
        let result = sizes
            .into_iter()
            .enumerate()
            .map(|(i, n)| URL_SAFE_NO_PAD.encode(format!("{i:02}{}", "a".repeat(n - 2))))
            .collect::<Vec<_>>()
            .join(",");
        assert_eq!(result.len(), total);
        result
    }
    for size in [4096, 8192] {
        let ids = ids(size);
        let query = form_urlencoded::Serializer::new(String::new())
            .append_pair("generation", "1")
            .append_pair("ids", &ids)
            .finish();
        if size == 8192 {
            assert!(query.len() > 8192);
        }
        let direct = body(
            f.get(&format!("/workspaces/{A}/state?{query}"))
                .send()
                .await
                .unwrap(),
            200,
        )
        .await;
        assert_eq!(direct["missing"].as_array().unwrap().len(), 64);
        let raw=json!({"operation":"getWorkspaceState","token":f.key.secret,"parameters":{"workspaceId":A,"generation":"1","ids":ids}}).to_string();
        let console: Value =
            serde_json::from_str(&f.server.integration_api_request(&raw).await.unwrap()).unwrap();
        assert_eq!(console["status"], 200);
        let actual: Value = serde_json::from_str(console["body"].as_str().unwrap()).unwrap();
        assert_eq!(actual, direct);
    }
    let too_long = format!("{}a", ids(8192));
    assert_eq!(
        f.get(&format!(
            "/workspaces/{A}/state?generation=1&ids={too_long}"
        ))
        .send()
        .await
        .unwrap()
        .status(),
        400
    );
    let bad=json!({"operation":"getWorkspaceState","token":f.key.secret,"parameters":{"workspaceId":A,"generation":"1","ids":too_long}}).to_string();
    assert!(f.server.integration_api_request(&bad).await.is_err());
    // The larger allowance does not enlarge ordinary listing query budgets.
    assert_eq!(
        f.get(&format!(
            "/workspaces/{A}/files?generation=1&cursor={}",
            "a".repeat(8192)
        ))
        .send()
        .await
        .unwrap()
        .status(),
        400
    );
    for invalid in [
        "/private",
        "../private",
        "https://example.invalid",
        "C:\\private",
    ] {
        let query = form_urlencoded::Serializer::new(String::new())
            .append_pair("generation", "1")
            .append_pair("path", invalid)
            .finish();
        assert_eq!(
            f.get(&format!("/workspaces/{A}/state?{query}"))
                .send()
                .await
                .unwrap()
                .status(),
            400
        );
    }
    assert_eq!(
        f.client
            .post(format!(
                "{}{PREFIX}/workspaces/{A}/state?generation=1",
                f.root
            ))
            .bearer_auth(&f.key.secret)
            .send()
            .await
            .unwrap()
            .status(),
        405
    );
    f.stop().await;
}

#[tokio::test]
async fn bearer_anchor_relocation_uses_scoped_directory_contract() {
    let f = Fixture::new().await;
    let file = URL_SAFE_NO_PAD.encode("hello.txt");
    let response = f
        .get(&format!("/workspaces/{A}/files?generation=1&anchor={file}"))
        .send().await.unwrap();
    assert_eq!(response.status(), 200);
    let page: Value = response.json().await.unwrap();
    assert_eq!(page["entries"][0]["id"], file);
    assert_eq!(page["offset"], 0);
    assert_eq!(page["anchorPending"], false);
    assert_eq!(page["anchorMissing"], false);
    let absent = URL_SAFE_NO_PAD.encode("absent.txt");
    let page: Value = f
        .get(&format!(
            "/workspaces/{A}/files?generation=1&anchor={absent}"
        ))
        .send().await.unwrap()
        .json()
        .await
        .unwrap();
    assert_eq!(page["anchorMissing"], true);
    assert!(page["entries"].as_array().unwrap().is_empty());
    let outside = URL_SAFE_NO_PAD.encode("other/hello.txt");
    assert_eq!(
        f.get(&format!(
            "/workspaces/{A}/files?generation=1&anchor={outside}"
        ))
        .send().await.unwrap()
        .status(),
        400
    );
    let denied = f
        .client
        .get(format!(
            "{}{PREFIX}/workspaces/{A}/files?generation=1&anchor={file}",
            f.root
        ))
        .send()
        .await
        .unwrap();
    assert_eq!(denied.status(), 401);
    f.stop().await;
}
