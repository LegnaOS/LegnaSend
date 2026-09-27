#![cfg(feature = "http")]
use localsend::http::server::{
    integration::{create_key, ApiConfig, Limits, Scope, WorkspaceGrant},
    start_with_port,
    web::WebConfig,
    ServerHandle,
};
use localsend::http::state::ClientInfo;
use serde_json::{json, Value};
use std::{path::PathBuf, time::Duration};
use tokio::sync::oneshot;
const A: &str = "11111111-1111-4111-8111-111111111111";
const B: &str = "22222222-2222-4222-8222-222222222222";
struct Fixture {
    server: ServerHandle,
    client: reqwest::Client,
    root: PathBuf,
    token: String,
    read_token: String,
    config: ApiConfig,
    stop: Option<oneshot::Sender<()>>,
}
impl Fixture {
    async fn new() -> Self {
        let root = std::env::temp_dir().join(format!(
            "legnasend-api-write-contract-{}",
            uuid::Uuid::new_v4()
        ));
        std::fs::create_dir_all(root.join("a")).unwrap();
        std::fs::create_dir_all(root.join("b")).unwrap();
        let (stop, rx) = oneshot::channel();
        let server = start_with_port(
            0,
            None,
            ClientInfo {
                alias: "write contract".into(),
                version: "2.2".into(),
                device_model: None,
                device_type: None,
                token: "fixture".into(),
            },
            None,
            None,
            WebConfig::default(),
            rx,
        )
        .await
        .unwrap();
        server.configure_directory_workspaces(&json!({"revision":1,"enabled":true,"workspaces":[
   {"id":A,"name":"A","slug":"aa","root":root.join("a"),"generation":1,"visible":false},
   {"id":B,"name":"B","slug":"bb","root":root.join("b"),"generation":1,"visible":true,"allowUpload":true}]}).to_string()).await.unwrap();
        let write = create_key(
            "explicit writer".into(),
            WorkspaceGrant {
                scopes: vec![Scope::Upload, Scope::Service, Scope::Requests],
                workspaces: vec![A.into()],
            },
            None,
        )
        .unwrap();
        let read = create_key(
            "old reader".into(),
            WorkspaceGrant {
                scopes: vec![Scope::Files, Scope::Service],
                workspaces: vec!["*".into()],
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
                concurrent: 4,
            },
            keys: vec![write.record, read.record],
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
            root,
            token: write.secret,
            read_token: read.secret,
            config,
            stop: Some(stop),
        }
    }
    fn url(&self, tail: &str) -> String {
        format!(
            "http://127.0.0.1:{}/api/legnasend/v1/integration{tail}",
            self.server.port()
        )
    }
    fn upload(&self, id: &str, path: &str) -> reqwest::RequestBuilder {
        self.client
            .post(self.url(&format!(
                "/workspaces/{id}/upload?generation=1&path={}",
                percent_encoding::utf8_percent_encode(path, percent_encoding::NON_ALPHANUMERIC)
            )))
            .header("Content-Type", "application/octet-stream")
    }
    async fn config(&mut self) {
        self.config.revision += 1;
        self.server
            .configure_integration_api(&serde_json::to_string(&self.config).unwrap())
            .await
            .unwrap();
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        if let Some(stop) = self.stop.take() {
            let _ = stop.send(());
        }
        let _ = std::fs::remove_dir_all(&self.root);
    }
}
#[tokio::test]
async fn explicit_key_writes_hidden_readonly_browser_workspace_but_not_other_workspace() {
    let f = Fixture::new().await;
    let bytes = vec![0, 255, 128, 10];
    let response = f
        .upload(A, "nested/中文 %.bin")
        .bearer_auth(&f.token)
        .body(bytes.clone())
        .send()
        .await
        .unwrap();
    assert_eq!(response.status(), 201);
    let receipt: Value = response.json().await.unwrap();
    assert_eq!(receipt["size"], 4);
    assert_eq!(receipt["directory"], false);
    assert_eq!(
        std::fs::read(f.root.join("a/nested/中文 %.bin")).unwrap(),
        bytes
    );
    assert_eq!(
        f.upload(B, "blocked.txt")
            .bearer_auth(&f.token)
            .body("denied")
            .send()
            .await
            .unwrap()
            .status(),
        403
    );
    assert!(!f.root.join("b/blocked.txt").exists());
    let response = f
        .upload(A, "nested/中文 %.bin")
        .bearer_auth(&f.token)
        .body("overwrite")
        .send()
        .await
        .unwrap();
    assert_eq!(response.status(), 409);
    assert_eq!(
        std::fs::read(f.root.join("a/nested/中文 %.bin")).unwrap(),
        bytes
    );
}
#[tokio::test]
async fn browser_permission_and_anonymous_mode_never_grant_api_write() {
    let mut f = Fixture::new().await;
    assert_eq!(
        f.upload(B, "read-key.txt")
            .bearer_auth(&f.read_token)
            .body("denied")
            .send()
            .await
            .unwrap()
            .status(),
        403
    );
    assert_eq!(
        f.upload(B, "no-key.txt")
            .body("denied")
            .send()
            .await
            .unwrap()
            .status(),
        401
    );
    f.config.auth_required = false;
    f.config().await;
    assert_eq!(
        f.upload(B, "anonymous.txt")
            .body("denied")
            .send()
            .await
            .unwrap()
            .status(),
        403
    );
    f.config.anonymous_grant.scopes.push(Scope::Upload);
    f.config.revision += 1;
    assert!(f
        .server
        .configure_integration_api(&serde_json::to_string(&f.config).unwrap())
        .await
        .is_err());
    assert_eq!(std::fs::read_dir(f.root.join("b")).unwrap().count(), 0);
}
#[tokio::test]
async fn upload_contract_describes_post_and_history_redacts_source_names() {
    let f = Fixture::new().await;
    let result = f
        .upload(A, "PRIVATE-file.txt")
        .bearer_auth(&f.token)
        .body("SECRET CONTENT")
        .send()
        .await
        .unwrap();
    assert_eq!(result.status(), 201);
    let _ = result.bytes().await.unwrap();
    let response = f
        .client
        .get(f.url("/openapi.json"))
        .bearer_auth(&f.token)
        .send()
        .await
        .unwrap();
    let schema: Value = response.json().await.unwrap();
    let op = &schema["paths"]["/workspaces/{workspaceId}/upload"]["post"];
    assert_eq!(op["operationId"], "uploadFile");
    assert_eq!(op["x-legnasend-scope"], "files.upload");
    assert!(op["requestBody"]["content"]["application/octet-stream"].is_object());
    assert!(op["responses"]["201"].is_object());
    let history = f
        .client
        .get(f.url("/requests"))
        .bearer_auth(&f.token)
        .send()
        .await
        .unwrap()
        .text()
        .await
        .unwrap();
    assert!(history.contains("uploadFile"));
    for secret in [&f.token, "PRIVATE-file.txt", "SECRET CONTENT"] {
        assert!(!history.contains(secret));
    }
}
#[tokio::test]
async fn no_overwrite_empty_directory_and_api_disable_are_enforced() {
    let mut f = Fixture::new().await;
    let response = f
        .client
        .post(f.url(&format!(
            "/workspaces/{A}/upload?generation=1&path=empty&directory=true"
        )))
        .header("Content-Type", "application/octet-stream")
        .bearer_auth(&f.token)
        .header("Content-Length", "0")
        .body("")
        .send()
        .await
        .unwrap();
    assert_eq!(response.status(), 201);
    assert!(f.root.join("a/empty").is_dir());
    for path in ["../outside", ".legnasend-private.part", "sub/.private.ls"] {
        assert_eq!(
            f.upload(A, path)
                .bearer_auth(&f.token)
                .body("denied")
                .send()
                .await
                .unwrap()
                .status(),
            400
        );
    }
    f.config.enabled = false;
    f.config().await;
    assert_ne!(
        f.upload(A, "disabled.txt")
            .bearer_auth(&f.token)
            .body("denied")
            .send()
            .await
            .unwrap()
            .status(),
        201
    );
    assert!(!f.root.join("a/disabled.txt").exists());
}

#[tokio::test]
async fn revoking_a_key_stops_an_incomplete_upload_and_releases_its_budget() {
    use tokio::io::AsyncWriteExt;
    let mut f = Fixture::new().await;
    let mut stream = tokio::net::TcpStream::connect(("127.0.0.1", f.server.port()))
        .await
        .unwrap();
    stream.write_all(format!("POST /api/legnasend/v1/integration/workspaces/{A}/upload?generation=1&path=inflight.bin HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer {}\r\nContent-Type: application/octet-stream\r\nContent-Length: 1000000\r\n\r\npartial",f.token).as_bytes()).await.unwrap();
    tokio::time::timeout(Duration::from_secs(3), async {
        loop {
            if std::fs::read_dir(f.root.join("a")).unwrap().any(|e| {
                e.unwrap()
                    .file_name()
                    .to_string_lossy()
                    .starts_with(".legnasend-receive-")
            }) {
                break;
            }
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
    })
    .await
    .unwrap();
    f.config.keys.remove(0);
    f.config().await;
    tokio::time::timeout(Duration::from_secs(3), async {
        loop {
            if std::fs::read_dir(f.root.join("a"))
                .unwrap()
                .next()
                .is_none()
            {
                break;
            }
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
    })
    .await
    .unwrap();
    assert!(!f.root.join("a/inflight.bin").exists());
    let denied = f
        .upload(A, "after-revoke.txt")
        .bearer_auth(&f.token)
        .body("bad")
        .send()
        .await
        .unwrap();
    assert_eq!(denied.status(), 401);
    // Consume the error response before checking server lifetime accounting.
    // Dropping a response immediately after its headers can leave its producer
    // scheduled for cleanup while the next status request counts itself too.
    let denied_body: Value = denied.json().await.unwrap();
    assert_eq!(denied_body["error"]["code"], "unauthorized");
    // Removing the temporary occurs inside the blocking transaction destructor;
    // its upload authority/quota is released afterwards. Poll the local snapshot
    // instead of racing that final drop or adding a new /status request lease.
    // Keep the original incomplete TCP socket OPEN: revocation, not client
    // disconnection, must release the server's entire response/write budget.
    tokio::time::timeout(Duration::from_secs(3), async {
        loop {
            let snapshot: Value =
                serde_json::from_str(&f.server.integration_api_snapshot()).unwrap();
            if snapshot["activeResponses"].as_u64() == Some(0) {
                break;
            }
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
    })
    .await
    .expect("revoked upload and consumed denial response must release every quota");
    drop(stream);
}
