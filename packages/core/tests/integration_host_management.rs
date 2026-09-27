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
fn settings() -> Value {
    json!({"version":"a".repeat(64),"pendingRestart":[],"receiveCacheRetention":{"effectiveDays":0,"automaticCleanupPaused":false,"busy":false,"error":null},"settings":{"receiveCacheRetentionDays":0,"alias":"Legna","theme":"system","locale":"system","enableAnimations":true,"autoFinish":false,"createChecksums":true,"verifyChecksums":true}})
}
fn cache() -> Value {
    json!({"examined":1,"removedFiles":0,"removedRecords":0,"plannedBytes":32,"unlinkedBytes":0,"active":0,"retained":1,"failed":0,"budgetReached":false,"interrupted":false,"entriesTruncated":false,"entries":[{"id":"b".repeat(64),"sourceKind":"nativeReceive","disposition":"candidate","reason":"owned_inactive","plannedBytes":32,"unlinkedBytes":0}]})
}
#[tokio::test]
async fn cache_and_settings_use_claimed_global_host_bridge_with_strict_redaction() {
    let mut f = Fixture::new(true).await;
    for (method, path, op, payload, result) in [
        ("GET", "/cache", "cache.inspect", None, cache()),
        ("POST", "/cache/cleanup", "cache.cleanup", None, cache()),
        ("GET", "/settings", "settings.read", None, settings()),
        (
            "POST",
            "/settings/update",
            "settings.update",
            Some(json!({"version":"a".repeat(64),"field":"theme","value":"dark"})),
            settings(),
        ),
    ] {
        let mut req = f
            .client
            .request(method.parse().unwrap(), f.endpoint(path))
            .bearer_auth(&f.secret);
        if let Some(payload) = payload {
            req = req.json(&payload);
        }
        let call = tokio::spawn(async move { req.send().await.unwrap() });
        let event = f.event().await;
        let input: Value = serde_json::from_str(&event.request_json()).unwrap();
        assert_eq!(input["operation"], format!("host.{op}"));
        assert!(event
            .respond(json!({"status":200,"body":result}).to_string())
            .is_err());
        assert!(event.claim());
        let mut bad = result.clone();
        bad["path"] = json!("/private/user");
        assert!(event
            .respond(json!({"status":200,"body":bad}).to_string())
            .is_err());
        if op.starts_with("cache") {
            let mut bad = result.clone();
            bad["entries"][0]["fileName"] = json!("private.txt");
            assert!(event
                .respond(json!({"status":200,"body":bad}).to_string())
                .is_err());
        }
        event
            .respond(json!({"status":200,"body":result}).to_string())
            .unwrap();
        let response = call.await.unwrap();
        assert_eq!(response.status(), 200);
        assert_eq!(response.json::<Value>().await.unwrap(), result);
    }
}
#[tokio::test]
async fn unsupported_paths_settings_and_query_bodies_are_rejected_before_host() {
    let f = Fixture::new(true).await;
    for body in [
        json!({"version":"a".repeat(64),"field":"destination","value":"/private"}),
        json!({"version":"a".repeat(64),"field":"theme","value":"pink"}),
        json!({"version":"a".repeat(64),"field":"verifyChecksums","value":"true"}),
        json!({"version":"invalid","field":"alias","value":"name"}),
        json!({"version":"a".repeat(64),"field":"alias","value":"name","path":"/x"}),
    ] {
        assert_eq!(
            f.client
                .post(f.endpoint("/settings/update"))
                .bearer_auth(&f.secret)
                .json(&body)
                .send()
                .await
                .unwrap()
                .status(),
            400
        );
    }
    assert_eq!(
        f.client
            .post(f.endpoint("/cache/cleanup"))
            .bearer_auth(&f.secret)
            .json(&json!({"path":"/private"}))
            .send()
            .await
            .unwrap()
            .status(),
        400
    );
    assert_eq!(
        f.client
            .get(f.endpoint("/cache?path=x"))
            .bearer_auth(&f.secret)
            .send()
            .await
            .unwrap()
            .status(),
        400
    );
}
#[tokio::test]
async fn host_scopes_never_become_anonymous_or_implicitly_global() {
    let mut f = Fixture::new(true).await;
    for scope in [
        Scope::CacheRead,
        Scope::CacheClean,
        Scope::SettingsRead,
        Scope::SettingsWrite,
    ] {
        let mut invalid = f.config.clone();
        invalid.anonymous_grant.scopes.push(scope);
        assert!(f
            .server
            .configure_integration_api(&serde_json::to_string(&invalid).unwrap())
            .await
            .is_err());
    }
    f.config.keys[0].grant.workspaces = vec![ID.into()];
    f.config.revision += 1;
    f.server
        .configure_integration_api(&serde_json::to_string(&f.config).unwrap())
        .await
        .unwrap();
    assert_eq!(
        f.client
            .get(f.endpoint("/cache"))
            .bearer_auth(&f.secret)
            .send()
            .await
            .unwrap()
            .status(),
        403
    );
    f.config.keys[0].grant.workspaces = vec!["*".into()];
    f.config.keys[0].grant.scopes = vec![Scope::Service];
    f.config.revision += 1;
    f.server
        .configure_integration_api(&serde_json::to_string(&f.config).unwrap())
        .await
        .unwrap();
    assert_eq!(
        f.client
            .get(f.endpoint("/settings"))
            .bearer_auth(&f.secret)
            .send()
            .await
            .unwrap()
            .status(),
        403
    );
}
#[tokio::test]
async fn revocation_before_claim_prevents_host_changes_and_rejects_success() {
    let mut f = Fixture::new(true).await;
    let req = f
        .client
        .post(f.endpoint("/cache/cleanup"))
        .bearer_auth(&f.secret);
    let call = tokio::spawn(async move { req.send().await.unwrap() });
    let event = f.event().await;
    f.revoke().await;
    assert!(!event.claim());
    assert!(event
        .respond(json!({"status":200,"body":cache()}).to_string())
        .is_err());
    assert_ne!(call.await.unwrap().status(), 200);
}

#[tokio::test]
async fn exported_contracts_match_live_server_and_describe_supported_host_fields() {
    let f = Fixture::new(true).await;
    for language in ["en", "zh-CN", "zh-TW", "zh-HK"] {
        let response: Value = f
            .client
            .get(f.endpoint(&format!("/openapi.json?lang={language}")))
            .bearer_auth(&f.secret)
            .send()
            .await
            .unwrap()
            .json()
            .await
            .unwrap();
        let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join(format!(
            "../../docs/api/integration-openapi-{language}.json"
        ));
        if std::env::var("LEGNASEND_UPDATE_CONTRACT").as_deref() == Ok("1") {
            std::fs::write(
                &path,
                format!("{}\n", serde_json::to_string_pretty(&response).unwrap()),
            )
            .unwrap();
        }
        let saved: Value = serde_json::from_slice(&std::fs::read(path).unwrap()).unwrap();
        assert_eq!(saved, response);
        assert_eq!(
            response["paths"]["/cache"]["get"]["x-legnasend-scope"],
            "cache.read"
        );
        assert_eq!(
            response["paths"]["/settings/update"]["post"]["requestBody"]["content"]
                ["application/json"]["schema"]["required"],
            json!(["version", "field", "value"])
        );
    }
}

#[tokio::test]
async fn retention_setting_boundaries_and_live_state_are_strict_and_path_free() {
    let mut f = Fixture::new(true).await;
    for days in [-2, -1, 0, 1, 7, 30, 3650] {
        let request = f
            .client
            .post(f.endpoint("/settings/update"))
            .bearer_auth(&f.secret)
            .json(
                &json!({"version":"a".repeat(64),"field":"receiveCacheRetentionDays","value":days}),
            );
        let call = tokio::spawn(async move { request.send().await.unwrap() });
        let event = f.event().await;
        assert!(event.claim());
        let input: Value = serde_json::from_str(&event.request_json()).unwrap();
        assert_eq!(input["operation"], "host.settings.update");
        assert_eq!(input["change"]["value"], days);
        let mut body = settings();
        body["settings"]["receiveCacheRetentionDays"] = json!(days);
        body["receiveCacheRetention"]["effectiveDays"] = json!(days);
        if days == -1 {
            for value in [
                json!(-3),
                json!(3651),
                json!(1.5),
                json!(1.0),
                json!("7"),
                json!(true),
                Value::Null,
            ] {
                let mut invalid = body.clone();
                invalid["settings"]["receiveCacheRetentionDays"] = value;
                assert!(
                    event
                        .respond(json!({"status":200,"body":invalid}).to_string())
                        .is_err()
                );
            }
            for value in [json!(-3), json!(3651), json!(1.5), json!("7"), json!(false)] {
                let mut invalid = body.clone();
                invalid["receiveCacheRetention"]["effectiveDays"] = value;
                assert!(
                    event
                        .respond(json!({"status":200,"body":invalid}).to_string())
                        .is_err()
                );
            }
            for field in ["effectiveDays", "automaticCleanupPaused", "busy", "error"] {
                let mut invalid = body.clone();
                invalid["receiveCacheRetention"]
                    .as_object_mut()
                    .unwrap()
                    .remove(field);
                assert!(
                    event
                        .respond(json!({"status":200,"body":invalid}).to_string())
                        .is_err()
                );
            }
            for (field, value) in [
                ("automaticCleanupPaused", json!(0)),
                ("busy", json!("false")),
                ("error", json!("/private/native.log")),
                ("path", json!("/private/cache")),
            ] {
                let mut invalid = body.clone();
                invalid["receiveCacheRetention"][field] = value;
                assert!(
                    event
                        .respond(json!({"status":200,"body":invalid}).to_string())
                        .is_err()
                );
            }
            let mut old = body.clone();
            old.as_object_mut().unwrap().remove("receiveCacheRetention");
            assert!(
                event
                    .respond(json!({"status":200,"body":old}).to_string())
                    .is_err(),
                "Never invent effective state for an old bridge response"
            );
            let mut old = body.clone();
            old["settings"]
                .as_object_mut()
                .unwrap()
                .remove("receiveCacheRetentionDays");
            assert!(
                event
                    .respond(json!({"status":200,"body":old}).to_string())
                    .is_err()
            );
            for (field, value) in [("effectiveDays", Value::Null), ("busy", json!(true))] {
                let mut unsafe_state = body.clone();
                unsafe_state["receiveCacheRetention"][field] = value;
                assert!(
                    event
                        .respond(json!({"status":200,"body":unsafe_state}).to_string())
                        .is_err(),
                    "Unknown/busy native policy requires paused cleanup"
                );
            }
        }
        event
            .respond(json!({"status":200,"body":body}).to_string())
            .unwrap();
        let response = call.await.unwrap();
        assert_eq!(response.status(), 200);
        assert_eq!(response.json::<Value>().await.unwrap(), body);
    }
    // Persistence, effective native policy and synchronization are separate facts.
    for (effective, paused, busy, error) in [
        (Value::Null, true, false, json!("apply")),
        (json!(7), true, true, Value::Null),
        (json!(-1), false, false, json!("save")),
        (json!(0), true, false, json!("restore")),
        (json!(3650), false, false, json!("invalid")),
    ] {
        let request = f.client.get(f.endpoint("/settings")).bearer_auth(&f.secret);
        let call = tokio::spawn(async move { request.send().await.unwrap() });
        let event = f.event().await;
        assert!(event.claim());
        let mut body = settings();
        body["receiveCacheRetention"] = json!({"effectiveDays":effective,"automaticCleanupPaused":paused,"busy":busy,"error":error});
        event
            .respond(json!({"status":200,"body":body}).to_string())
            .unwrap();
        assert_eq!(call.await.unwrap().json::<Value>().await.unwrap(), body);
    }
}

#[tokio::test]
async fn retention_invalid_requests_are_rejected_before_dispatch_and_errors_stay_stable() {
    let mut f = Fixture::new(true).await;
    for value in [
        json!(-3),
        json!(3651),
        json!(1.5),
        json!(1.0),
        json!("7"),
        json!(true),
        Value::Null,
        json!({"days":7}),
        json!([7]),
    ] {
        let response = f.client.post(f.endpoint("/settings/update")).bearer_auth(&f.secret)
            .json(&json!({"version":"a".repeat(64),"field":"receiveCacheRetentionDays","value":value}))
            .send().await.unwrap();
        assert_eq!(response.status(), 400, "Rejected value {value}");
    }
    assert!(f.events.try_recv().is_err());
    for (status, code) in [(409, "settings_busy"), (503, "host_operation_failed")] {
        let request = f
            .client
            .post(f.endpoint("/settings/update"))
            .bearer_auth(&f.secret)
            .json(&json!({"version":"a".repeat(64),"field":"receiveCacheRetentionDays","value":7}));
        let call = tokio::spawn(async move { request.send().await.unwrap() });
        let event = f.event().await;
        assert!(event.claim());
        let body = json!({"error":{"code":code}});
        assert!(
            event
                .respond(
                    json!({"status":status,"body":{"error":{"code":code,"path":"/private"}}})
                        .to_string()
                )
                .is_err()
        );
        event
            .respond(json!({"status":status,"body":body}).to_string())
            .unwrap();
        let response = call.await.unwrap();
        assert_eq!(response.status(), status);
        let output = response.json::<Value>().await.unwrap();
        assert_eq!(output["error"]["code"], body["error"]["code"]);
        assert!(uuid::Uuid::parse_str(output["error"]["requestId"].as_str().unwrap()).is_ok());
        assert_eq!(output["error"].as_object().unwrap().len(), 2);
    }
    // Both settings permissions still require a global key, not a workspace grant.
    f.config.keys[0].grant.workspaces = vec![ID.into()];
    f.config.revision += 1;
    f.server
        .configure_integration_api(&serde_json::to_string(&f.config).unwrap())
        .await
        .unwrap();
    for read in [true, false] {
        let request = if read {
            f.client.get(f.endpoint("/settings"))
        } else {
            f.client.post(f.endpoint("/settings/update")).json(
                &json!({"version":"a".repeat(64),"field":"receiveCacheRetentionDays","value":7}),
            )
        };
        assert_eq!(
            request
                .bearer_auth(&f.secret)
                .send()
                .await
                .unwrap()
                .status(),
            403
        );
    }
    assert!(f.events.try_recv().is_err());
}

#[tokio::test]
async fn retention_contract_is_localized_required_and_not_overwritten_by_workspace_contract() {
    let f = Fixture::new(true).await;
    for language in ["en", "zh-CN", "zh-TW", "zh-HK"] {
        let contract: Value = f
            .client
            .get(f.endpoint(&format!("/openapi.json?lang={language}")))
            .bearer_auth(&f.secret)
            .send()
            .await
            .unwrap()
            .json()
            .await
            .unwrap();
        for (path, method, scope) in [
            ("/settings", "get", "settings.read"),
            ("/settings/update", "post", "settings.write"),
        ] {
            let operation = &contract["paths"][path][method];
            assert_eq!(operation["x-legnasend-scope"], scope);
            assert_eq!(operation["x-legnasend-key-only"], true);
            assert_eq!(operation["x-legnasend-workspace-grant"], "*");
            assert_eq!(
                operation["responses"]["200"]["content"]["application/json"]["schema"]["$ref"],
                "#/components/schemas/HostSettings"
            );
            assert!(
                !operation["description"]
                    .as_str()
                    .unwrap()
                    .contains("workspaces.manage")
            );
        }
        let settings = &contract["components"]["schemas"]["HostSettings"];
        assert!(
            settings["required"]
                .as_array()
                .unwrap()
                .contains(&json!("receiveCacheRetention"))
        );
        assert!(
            settings["properties"]["settings"]["required"]
                .as_array()
                .unwrap()
                .contains(&json!("receiveCacheRetentionDays"))
        );
        let days = &settings["properties"]["settings"]["properties"]["receiveCacheRetentionDays"];
        assert_eq!(days["minimum"], -2);
        assert_eq!(days["maximum"], 3650);
        assert_eq!(days["type"], "integer");
        let description = days["description"].as_str().unwrap();
        assert!(description.contains(if language == "en" {
            "crash-residue"
        } else if language == "zh-CN" {
            "崩溃"
        } else {
            "崩潰"
        }));
        let state = &contract["components"]["schemas"]["ReceiveCacheRetention"];
        assert_eq!(state["additionalProperties"], false);
        assert_eq!(
            state["required"],
            json!(["effectiveDays", "automaticCleanupPaused", "busy", "error"])
        );
        assert_eq!(
            state["properties"]["error"]["enum"],
            json!([null, "invalid", "save", "apply", "restore"])
        );
        assert_eq!(state["allOf"].as_array().unwrap().len(), 2);
        for property in ["effectiveDays", "automaticCleanupPaused", "busy", "error"] {
            assert!(
                !state["properties"][property]["description"]
                    .as_str()
                    .unwrap()
                    .is_empty()
            );
        }
        let update = &contract["paths"]["/settings/update"]["post"];
        let request = &update["requestBody"]["content"]["application/json"]["schema"];
        assert!(
            request["properties"]["field"]["enum"]
                .as_array()
                .unwrap()
                .contains(&json!("receiveCacheRetentionDays"))
        );
        assert_eq!(request["allOf"][0]["then"]["properties"]["value"], *days);
        assert!(
            update["responses"]["409"]["description"]
                .as_str()
                .unwrap()
                .contains("settings_busy")
        );
        assert!(
            update["responses"]["503"]["description"]
                .as_str()
                .unwrap()
                .contains("host_operation_failed")
        );
        assert_eq!(
            contract["paths"]["/cache"]["get"]["responses"]["200"]["content"]["application/json"]["schema"]
                ["$ref"],
            "#/components/schemas/CacheReport"
        );
    }
}

#[tokio::test]
async fn key_contract_models_scopes_and_localized_errors_survive_workspace_metadata() {
    let f = Fixture::new(true).await;
    for language in ["en", "zh-CN", "zh-TW", "zh-HK"] {
        let contract: Value = f
            .client
            .get(f.endpoint(&format!("/openapi.json?lang={language}")))
            .bearer_auth(&f.secret)
            .send()
            .await
            .unwrap()
            .json()
            .await
            .unwrap();
        for (path, method, model) in [
            ("/keys", "get", "KeyList"),
            ("/keys/create", "post", "KeyResult"),
            ("/keys/requests/{requestId}", "get", "KeyResult"),
            ("/keys/{keyId}/manage", "post", "KeyResult"),
        ] {
            let operation = &contract["paths"][path][method];
            assert_eq!(
                operation["responses"]["200"]["content"]["application/json"]["schema"]["$ref"],
                format!("#/components/schemas/{model}")
            );
            assert_eq!(operation["x-legnasend-scope"], "keys.manage");
            assert_eq!(operation["x-legnasend-key-only"], true);
            assert_eq!(operation["x-legnasend-workspace-grant"], "*");
            let description = operation["description"].as_str().unwrap();
            assert!(description.contains("keys.manage"));
            assert!(!description.contains("workspaces.manage"));
            for status in [
                "400", "401", "403", "404", "409", "422", "500", "503", "504",
            ] {
                let error = &operation["responses"][status];
                assert_eq!(
                    error["content"]["application/json"]["schema"]["$ref"],
                    "#/components/schemas/Error"
                );
                let description = error["description"].as_str().unwrap();
                assert!(description.contains(if language == "en" {
                    "Key lifecycle"
                } else if language == "zh-CN" {
                    "密钥生命周期"
                } else {
                    "密鑰生命週期"
                }));
                assert_ne!(description, "成功");
            }
        }
        let created = &contract["paths"]["/keys/create"]["post"]["responses"]["201"];
        assert_eq!(
            created["content"]["application/json"]["schema"]["$ref"],
            "#/components/schemas/KeyResult"
        );
        assert!(
            created["description"]
                .as_str()
                .unwrap()
                .contains(if language == "en" {
                    "one-time"
                } else {
                    "一次"
                })
        );
        for operation in contract["paths"]
            .as_object()
            .unwrap()
            .values()
            .flat_map(|path| path.as_object().unwrap().values())
        {
            for (status, response) in operation["responses"].as_object().unwrap() {
                if status.parse::<u16>().is_ok_and(|status| status >= 400) {
                    assert!(
                        !response["description"].as_str().unwrap().contains("成功"),
                        "{language}: error {status} mislabeled success"
                    );
                }
            }
        }
        let description = contract["info"]["description"].as_str().unwrap();
        for stale in ["read-only", "首批只读", "首批唯讀", "写接口继续开发", "寫入接口繼續開發"] {
            assert!(!description.contains(stale), "Stale top-level contract metadata: {description}");
        }
        assert!(description.contains("LocalSend"));
        assert!(description.contains(if language == "en" { "native-task controls" } else if language == "zh-CN" { "原生任务控制" } else { "原生任務控制" }));
        assert_eq!(contract["paths"].as_object().unwrap().len(), 41);
        for (path, method, model) in [
            ("/managed-workspaces", "get", "ManagedWorkspaceList"),
            ("/approved-workspace-sources", "get", "ApprovedSourceList"),
            ("/managed-workspaces/create", "post", "ManagementResult"),
            (
                "/workspaces/{workspaceId}/manage",
                "post",
                "ManagementResult",
            ),
        ] {
            let operation = &contract["paths"][path][method];
            assert_eq!(
                operation["responses"]["200"]["content"]["application/json"]["schema"]["$ref"],
                format!("#/components/schemas/{model}")
            );
            assert!(
                operation["description"]
                    .as_str()
                    .unwrap()
                    .contains("workspaces.manage")
            );
        }
    }
}
