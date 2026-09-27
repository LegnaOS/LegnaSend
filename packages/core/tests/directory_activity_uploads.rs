#![cfg(feature = "http")]
//! Actual loopback HTTP bodies and capability-scoped publication, not mocked progress.
use localsend::http::{
    server::{
        ServerConfigV2, ServerHandle,
        integration::{ApiConfig, Scope, WorkspaceGrant, create_key},
        start_with_port,
        v2::ServerEventV2,
        web::WebConfig,
    },
    state::ClientInfo,
};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{cell::Cell, path::PathBuf, time::Duration};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::TcpStream,
    sync::{mpsc, oneshot},
};
static TEST_SLOTS: tokio::sync::Semaphore = tokio::sync::Semaphore::const_new(4);
const ID: &str = "11111111-1111-4111-8111-111111111111";
struct Fixture {
    _slot: tokio::sync::SemaphorePermit<'static>,
    generation: Cell<u64>,
    server: ServerHandle,
    client: reqwest::Client,
    root: PathBuf,
    stop: Option<oneshot::Sender<()>>,
    events: mpsc::Receiver<ServerEventV2>,
}
impl Fixture {
    async fn new() -> Self {
        let slot = TEST_SLOTS.acquire().await.unwrap();
        let root = std::env::temp_dir().join(format!(
            "legnasend-activity-upload-{}",
            uuid::Uuid::new_v4()
        ));
        std::fs::create_dir(&root).unwrap();
        let (stop, rx) = oneshot::channel();
        let (tx, events) = mpsc::channel(16);
        let server = start_with_port(
            0,
            None,
            ClientInfo {
                alias: "activity-upload".into(),
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
            _slot: slot,
            generation: Cell::new(1),
            server,
            root,
            stop: Some(stop),
            events,
            client: reqwest::Client::builder()
                .no_proxy()
                .timeout(Duration::from_secs(8))
                .build()
                .unwrap(),
        };
        f.configure(1, Some(f.config())).await;
        f
    }
    fn config(&self) -> Value {
        json!({"id":ID,"name":"Incoming workspace","slug":"uploads","root":self.root,"generation":1,"visible":true,"allowUpload":true})
    }
    async fn configure(&self, revision: u64, config: Option<Value>) {
        if let Some(config) = &config {
            self.generation.set(config["generation"].as_u64().unwrap());
        }
        self.server.configure_directory_workspaces(&json!({"revision":revision,"enabled":true,"workspaces":config.into_iter().collect::<Vec<_>>()}).to_string()).await.unwrap();
    }
    fn base(&self) -> String {
        format!("http://127.0.0.1:{}", self.server.port())
    }
    fn endpoint(&self, path: &str, api: bool) -> String {
        format!(
            "{}/api/legnasend/v1/{}workspaces/{ID}/upload?generation={}&path={}",
            self.base(),
            if api { "integration/" } else { "" },
            self.generation.get(),
            percent_encoding::utf8_percent_encode(path, percent_encoding::NON_ALPHANUMERIC)
        )
    }
    fn post(&self, path: &str, bytes: &[u8]) -> reqwest::RequestBuilder {
        self.client
            .post(self.endpoint(path, false))
            .header("x-legnasend-upload", "1")
            .header("Content-Type", "application/octet-stream")
            .header("Content-Length", bytes.len())
            .body(bytes.to_vec())
    }
    fn records(&self) -> Vec<Value> {
        serde_json::from_str(&self.server.web_download_activity()).unwrap()
    }
    async fn record(&self, name: &str, phase: &str) -> Value {
        tokio::time::timeout(Duration::from_secs(5), async {
            loop {
                if let Some(r) = self
                    .records()
                    .into_iter()
                    .find(|r| r["name"] == name && r["phase"] == phase)
                {
                    return r;
                }
                tokio::time::sleep(Duration::from_millis(5)).await;
            }
        })
        .await
        .unwrap_or_else(|_| panic!("missing {name}/{phase}: {:?}", self.records()))
    }
    async fn partial(
        &self,
        name: &str,
        total: usize,
        bytes: &[u8],
        api: bool,
        extra: &str,
    ) -> TcpStream {
        let url = reqwest::Url::parse(&self.endpoint(name, api)).unwrap();
        let mut stream = TcpStream::connect(("127.0.0.1", self.server.port()))
            .await
            .unwrap();
        stream.write_all(format!("POST {}?{} HTTP/1.1\r\nHost: 127.0.0.1:{}\r\nConnection: close\r\nX-LegnaSend-Upload: 1\r\nContent-Type: application/octet-stream\r\nContent-Length: {total}\r\n{extra}\r\n",url.path(),url.query().unwrap(),self.server.port()).as_bytes()).await.unwrap();
        stream.write_all(bytes).await.unwrap();
        tokio::time::timeout(Duration::from_secs(5), async {
            loop {
                if self
                    .records()
                    .iter()
                    .any(|r| r["name"] == name && r["transferred"] == bytes.len())
                {
                    return;
                }
                tokio::time::sleep(Duration::from_millis(5)).await;
            }
        })
        .await
        .unwrap();
        stream
    }
    async fn clean(&self, sub: &str) {
        tokio::time::timeout(Duration::from_secs(5), async {
            while self.root.join(sub).exists() {
                tokio::time::sleep(Duration::from_millis(5)).await;
            }
        })
        .await
        .unwrap_or_else(|_| panic!("owned staging directory remained: {sub}"));
    }
    async fn next(&self, name: &str) {
        let data = "后续原始字节\n".as_bytes();
        let response = self.post(name, data).send().await.unwrap();
        assert_eq!(response.status(), 201);
        let receipt: Value = response.json().await.unwrap();
        assert_eq!(
            receipt["sha256"],
            Sha256::digest(data)
                .iter()
                .map(|b| format!("{b:02x}"))
                .collect::<String>()
        );
        assert_eq!(std::fs::read(self.root.join(name)).unwrap(), data);
        let r = self.record(name, "succeeded").await;
        assert_eq!(r["transferred"], data.len());
        assert_eq!(r["total"], data.len());
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
async fn response(mut stream: TcpStream) -> String {
    let mut bytes = Vec::new();
    tokio::time::timeout(Duration::from_secs(5), stream.read_to_end(&mut bytes))
        .await
        .unwrap()
        .unwrap();
    String::from_utf8_lossy(&bytes).into()
}

#[tokio::test]
async fn written_bytes_are_visible_before_eof_and_success_requires_publication() {
    let f = Fixture::new().await;
    let mut socket = f.partial("nested/中文.bin", 8, b"first", false, "").await;
    let r = f.record("nested/中文.bin", "transferring").await;
    assert_eq!(r["total"], 8);
    assert_eq!(r["transferred"], 5);
    assert_eq!(r["direction"], "receive");
    assert_eq!(r["operation"], "upload");
    assert_eq!(r["origin"], "browser");
    assert_eq!(r["workspaceId"], ID);
    assert_eq!(r["workspaceName"], "Incoming workspace");
    assert_eq!(r["peer"], "127.0.0.1");
    assert!(!f.root.join("nested/中文.bin").exists());
    let part = std::fs::read_dir(f.root.join("nested"))
        .unwrap()
        .next()
        .unwrap()
        .unwrap()
        .path();
    assert_eq!(std::fs::read(&part).unwrap(), b"first");
    socket.write_all(b"end").await.unwrap();
    assert!(response(socket).await.starts_with("HTTP/1.1 201"));
    assert_eq!(
        f.record("nested/中文.bin", "succeeded").await["transferred"],
        8
    );
    assert_eq!(
        std::fs::read(f.root.join("nested/中文.bin")).unwrap(),
        b"firstend"
    );
    assert!(!part.exists());
    let r = f
        .client
        .post(format!(
            "{}&directory=true",
            f.endpoint("empty/folder", false)
        ))
        .header("x-legnasend-upload", "1")
        .header("content-type", "application/octet-stream")
        .header("content-length", 0)
        .body("")
        .send()
        .await
        .unwrap();
    assert_eq!(r.status(), 201);
    let r = f.record("empty/folder", "succeeded").await;
    assert_eq!(r["operation"], "directory");
    assert_eq!(r["transferred"], 0);
    assert_eq!(r["total"], 0);
    assert!(f.root.join("empty/folder").is_dir());
}
#[tokio::test]
async fn full_body_publication_conflict_is_failed_not_saved_and_next_succeeds() {
    let f = Fixture::new().await;
    let mut socket = f.partial("race/result", 8, b"first", false, "").await;
    std::fs::write(f.root.join("race/result"), b"existing owner").unwrap();
    socket.write_all(b"end").await.unwrap();
    assert!(response(socket).await.starts_with("HTTP/1.1 409"));
    let r = f.record("race/result", "failed").await;
    assert_eq!(r["transferred"], 8);
    assert_eq!(r["total"], 8);
    assert_eq!(
        std::fs::read(f.root.join("race/result")).unwrap(),
        b"existing owner"
    );
    assert_eq!(std::fs::read_dir(f.root.join("race")).unwrap().count(), 1);
    f.next("after-publication-conflict").await;
}
#[tokio::test]
async fn dropped_body_is_failed_partial_cleaned_and_next_succeeds() {
    let f = Fixture::new().await;
    let socket = f.partial("drop/file", 1024, b"partial", false, "").await;
    drop(socket);
    let r = f.record("drop/file", "failed").await;
    assert_eq!(r["transferred"], 7);
    assert_eq!(r["total"], 1024);
    f.clean("drop").await;
    f.next("after-disconnect").await;
}
#[tokio::test]
async fn explicit_cancel_is_single_request_and_does_not_cancel_parallel_upload() {
    let f = Fixture::new().await;
    let canceled = f.partial("canceled/file", 8, b"first", false, "").await;
    let mut survivor = f.partial("survivor/file", 8, b"first", false, "").await;
    // Both admitted requests already occupy the workspace's two slots.
    assert_eq!(
        f.post("not-admitted", b"data")
            .send()
            .await
            .unwrap()
            .status(),
        429
    );
    assert_eq!(
        f.records().len(),
        2,
        "admission rejection is not a third transfer"
    );
    let r = f.record("canceled/file", "transferring").await;
    assert!(f.server.cancel_web_download(r["id"].as_str().unwrap()));
    assert!(response(canceled).await.starts_with("HTTP/1.1 409"));
    f.clean("canceled").await;
    assert_eq!(
        f.record("canceled/file", "canceled").await["transferred"],
        5
    );
    survivor.write_all(b"end").await.unwrap();
    assert!(response(survivor).await.starts_with("HTTP/1.1 201"));
    f.record("survivor/file", "succeeded").await;
    f.next("after-cancel").await;
}
#[tokio::test]
async fn workspace_close_cancels_and_cleans_then_reopen_accepts_next() {
    let f = Fixture::new().await;
    let socket = f.partial("closed/file", 1024, b"partial", false, "").await;
    f.configure(2, None).await;
    f.record("closed/file", "canceled").await;
    f.clean("closed").await;
    drop(socket);
    f.configure(3, Some(f.config())).await;
    f.next("after-reopen").await;
}
#[tokio::test]
async fn denied_parameters_and_approval_do_not_register_upload_activity() {
    let mut f = Fixture::new().await;
    let mut config = f.config();
    config["uploadApproval"] = json!(true);
    config["generation"] = json!(2);
    f.configure(2, Some(config)).await;
    assert_eq!(
        f.post("../outside", b"no").send().await.unwrap().status(),
        400
    );
    assert_eq!(f.post("file", b"data").send().await.unwrap().status(), 428);
    let request=f.client.post(format!("{}/api/legnasend/v1/workspaces/{ID}/prepare-upload",f.base())).header("x-legnasend-upload","1").json(&json!({"requestId":uuid::Uuid::new_v4().to_string(),"generation":2,"files":[{"path":"file","size":4,"directory":false}]}));
    let pending = tokio::spawn(async move { request.send().await.unwrap() });
    let event = tokio::time::timeout(Duration::from_secs(5), f.events.recv())
        .await
        .unwrap()
        .unwrap();
    let ServerEventV2::DirectoryUploadApproval { decision_tx, .. } = event else {
        panic!("expected approval")
    };
    assert!(f.records().is_empty());
    decision_tx.send(false).unwrap();
    assert_eq!(pending.await.unwrap().status(), 403);
    assert!(f.records().is_empty());
    assert_eq!(std::fs::read_dir(&f.root).unwrap().count(), 0);
}
#[tokio::test]
async fn revoked_api_key_preserves_real_origin_and_unknown_peer_then_new_key_succeeds() {
    let f = Fixture::new().await;
    let key = create_key(
        "writer".into(),
        WorkspaceGrant {
            scopes: vec![Scope::Upload],
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
    f.server
        .configure_integration_api(&serde_json::to_string(&config).unwrap())
        .await
        .unwrap();
    let socket = f
        .partial(
            "api/file",
            1024,
            b"partial",
            true,
            &format!("Authorization: Bearer {}\r\n", key.secret),
        )
        .await;
    let r = f.record("api/file", "transferring").await;
    assert_eq!(r["origin"], "api");
    assert_eq!(r["peer"], "");
    config.revision = 2;
    config.keys.clear();
    f.server
        .configure_integration_api(&serde_json::to_string(&config).unwrap())
        .await
        .unwrap();
    f.record("api/file", "canceled").await;
    f.clean("api").await;
    drop(socket);
    let key = create_key(
        "next".into(),
        WorkspaceGrant {
            scopes: vec![Scope::Upload],
            workspaces: vec![ID.into()],
        },
        None,
    )
    .unwrap();
    config.revision = 3;
    config.keys.push(key.record);
    f.server
        .configure_integration_api(&serde_json::to_string(&config).unwrap())
        .await
        .unwrap();
    let result = f
        .client
        .post(f.endpoint("api-next", true))
        .bearer_auth(key.secret)
        .header("content-type", "application/octet-stream")
        .body("saved")
        .send()
        .await
        .unwrap();
    assert_eq!(result.status(), 201);
    assert_eq!(f.record("api-next", "succeeded").await["transferred"], 5);
    assert_eq!(std::fs::read(f.root.join("api-next")).unwrap(), b"saved");
}
#[tokio::test]
async fn logout_revokes_grant_and_cleans_its_upload_without_a_success_receipt() {
    let f = Fixture::new().await;
    let mut config = f.config();
    config["generation"] = json!(2);
    config["passwordHash"] = json!(
        localsend::http::server::directory_auth::hash_password("fixture-password".into())
            .await
            .unwrap()
    );
    f.configure(2, Some(config)).await;
    assert_eq!(
        f.post("unauthorized", b"data")
            .send()
            .await
            .unwrap()
            .status(),
        401
    );
    assert!(
        f.records().is_empty(),
        "authorization rejection is not a transfer"
    );
    let login = f
        .client
        .post(format!(
            "{}/api/legnasend/v1/workspaces/{ID}/unlock",
            f.base()
        ))
        .json(&json!({"password":"fixture-password","generation":2}))
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
    let socket = f
        .partial(
            "grant/file",
            1024,
            b"partial",
            false,
            &format!("Cookie: {cookie}\r\n"),
        )
        .await;
    let result = f
        .client
        .post(format!(
            "{}/api/legnasend/v1/workspaces/{ID}/logout",
            f.base()
        ))
        .header("Cookie", cookie)
        .json(&json!({}))
        .send()
        .await
        .unwrap();
    assert_eq!(result.status(), 200);
    f.record("grant/file", "canceled").await;
    f.clean("grant").await;
    drop(socket);
}
