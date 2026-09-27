#![cfg(feature = "http")]
use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
use localsend::http::server::{
    ServerConfigV2, ServerHandle,
    integration::{ApiConfig, PREFIX, Scope, WorkspaceGrant, create_key},
    start_with_port,
    web::{WebConfig, WebDownloadConfig, WebDownloadEvent, WebMode},
};
use localsend::http::state::ClientInfo;
use localsend::model::transfer::{FileContent, FileDto};
use serde_json::{Value, json};
use std::{collections::HashMap, path::PathBuf, time::Duration};
use tokio::sync::{mpsc, oneshot};
const ID: &str = "11111111-1111-4111-8111-111111111111";
static SERIAL: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());
const PAYLOAD: &[u8] = b"actual directory response bytes";
struct Fixture {
    server: ServerHandle,
    client: reqwest::Client,
    base: String,
    dir: PathBuf,
    stop: Option<oneshot::Sender<()>>,
}
impl Fixture {
    async fn new() -> Self {
        let dir = std::env::temp_dir().join(format!(
            "legnasend-directory-activity-{}",
            uuid::Uuid::new_v4()
        ));
        std::fs::create_dir(&dir).unwrap();
        std::fs::write(dir.join("small.txt"), PAYLOAD).unwrap();
        let path = dir.join("small.txt");
        let (events, mut rx) = mpsc::channel(16);
        tokio::spawn(async move {
            while let Some(event) = rx.recv().await {
                match event {
                    WebDownloadEvent::PrepareDownload { decision_tx, .. } => {
                        let _ = decision_tx.send(true);
                    }
                    WebDownloadEvent::FileDownload { content_tx, .. } => {
                        let _ = content_tx.send(FileContent::Path(path.clone()));
                    }
                    _ => {}
                }
            }
        });
        let file = FileDto {
            id: "small".into(),
            file_name: "temporary.txt".into(),
            size: PAYLOAD.len() as u64,
            file_type: "text/plain".into(),
            sha256: None,
            preview: None,
            metadata: None,
        };
        let (v2, mut rx) = mpsc::channel(16);
        tokio::spawn(async move { while rx.recv().await.is_some() {} });
        let (stop, stopped) = oneshot::channel();
        let server = start_with_port(
            0,
            None,
            ClientInfo {
                alias: "Activity fixture".into(),
                version: "2.2".into(),
                device_model: None,
                device_type: None,
                token: "fixture".into(),
            },
            None,
            Some(ServerConfigV2 {
                pin: None,
                verify_checksums: false,
                event_tx: v2,
            }),
            WebConfig {
                mode: WebMode::Download(WebDownloadConfig {
                    files: HashMap::from([("small".into(), file)]),
                    pin: None,
                    event_tx: events,
                }),
                ..Default::default()
            },
            stopped,
        )
        .await
        .unwrap();
        server.configure_directory_workspaces(&json!({"revision":1,"enabled":true,"workspaces":[{"id":ID,"name":"Workspace α","slug":"activity-share","root":dir,"generation":1,"visible":true}]}).to_string()).await.unwrap();
        let base = format!("http://127.0.0.1:{}", server.port());
        Self {
            server,
            client: reqwest::Client::builder()
                .no_proxy()
                .timeout(Duration::from_secs(15))
                .build()
                .unwrap(),
            base,
            dir,
            stop: Some(stop),
        }
    }
    fn url(&self, name: &str) -> String {
        format!(
            "{}/api/legnasend/v1/workspaces/{ID}/files/{}/content?generation=1",
            self.base,
            URL_SAFE_NO_PAD.encode(name)
        )
    }
    fn archive(&self, path: &str) -> String {
        format!(
            "{}/api/legnasend/v1/workspaces/{ID}/archive?generation=1&path={path}",
            self.base
        )
    }
    fn records(&self) -> Vec<Value> {
        serde_json::from_str(&self.server.web_download_activity()).unwrap()
    }
    async fn temporary(&self) {
        let prepared: Value = self
            .client
            .post(format!("{}/api/localsend/v2/prepare-download", self.base))
            .send()
            .await
            .unwrap()
            .json()
            .await
            .unwrap();
        let response = self
            .client
            .get(format!(
                "{}/api/localsend/v2/download?sessionId={}&fileId=small",
                self.base,
                prepared["sessionId"].as_str().unwrap()
            ))
            .send()
            .await
            .unwrap();
        assert_eq!(response.bytes().await.unwrap().as_ref(), PAYLOAD);
    }
    async fn terminal(&self, id: &str) -> Value {
        tokio::time::timeout(Duration::from_secs(3), async {
            loop {
                let record = self.records().into_iter().find(|r| r["id"] == id).unwrap();
                if !matches!(record["phase"].as_str(), Some("preparing" | "transferring")) {
                    return record;
                }
                tokio::time::sleep(Duration::from_millis(5)).await;
            }
        })
        .await
        .unwrap()
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        if let Some(stop) = self.stop.take() {
            let _ = stop.send(());
        }
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

#[tokio::test]
async fn downloads_ranges_zip_head_preview_rejections_and_temporary_are_counted_once() {
    let _serial = SERIAL.lock().await;
    let f = Fixture::new().await;
    assert_eq!(
        f.client
            .head(f.url("small.txt"))
            .send()
            .await
            .unwrap()
            .status(),
        200
    );
    assert_eq!(
        f.client.head(f.archive("")).send().await.unwrap().status(),
        200
    );
    assert_eq!(
        f.client
            .get(format!("{}&preview=1", f.url("small.txt")))
            .send()
            .await
            .unwrap()
            .bytes()
            .await
            .unwrap()
            .as_ref(),
        PAYLOAD
    );
    assert_eq!(
        f.client
            .get(f.url("missing"))
            .send()
            .await
            .unwrap()
            .status(),
        404
    );
    assert_eq!(
        f.client
            .get(f.url("small.txt"))
            .header("range", "bytes=999-1000")
            .send()
            .await
            .unwrap()
            .status(),
        416
    );
    assert!(f.records().is_empty());
    let range = f
        .client
        .get(f.url("small.txt"))
        .header("range", "bytes=2-8")
        .send()
        .await
        .unwrap();
    assert_eq!(range.status(), 206);
    assert_eq!(range.bytes().await.unwrap().as_ref(), &PAYLOAD[2..9]);
    let r = &f.records()[0];
    assert_eq!(r["direction"], "send");
    assert_eq!(r["operation"], "download");
    assert_eq!(r["origin"], "browser");
    assert_eq!(r["workspaceId"], ID);
    assert_eq!(r["workspaceName"], "Workspace α");
    assert_eq!(r["name"], "small.txt");
    assert_eq!(r["peer"], "127.0.0.1");
    assert_eq!(r["total"], 7);
    assert_eq!(r["transferred"], 7);
    assert_eq!(r["phase"], "succeeded");
    let zip = f.client.get(f.archive("")).send().await.unwrap();
    assert_eq!(zip.status(), 200);
    let bytes = zip.bytes().await.unwrap();
    assert_eq!(&bytes[..4], b"PK\x03\x04");
    assert_eq!(f.records().len(), 2);
    let r = &f.records()[1];
    assert_eq!(r["operation"], "archive");
    assert_eq!(r["transferred"], bytes.len());
    assert_eq!(r["phase"], "succeeded");
    f.temporary().await;
    assert_eq!(f.records().len(), 3);
    let r = &f.records()[2];
    assert!(r.get("workspaceId").is_none());
    assert_eq!(r["direction"], "send");
    assert_eq!(r["origin"], "browser");
    assert_eq!(r["phase"], "succeeded");
    assert!(
        !f.server
            .web_download_activity()
            .contains(f.dir.to_str().unwrap())
    );
}

#[tokio::test]
async fn cancel_only_one_response_and_close_workspace_without_stopping_temporary_service() {
    let _serial = SERIAL.lock().await;
    let f = Fixture::new().await;
    std::fs::File::create(f.dir.join("large.bin"))
        .unwrap()
        .set_len(64 * 1024 * 1024)
        .unwrap();
    let first = f.client.get(f.url("large.bin")).send().await.unwrap();
    let second = f.client.get(f.url("large.bin")).send().await.unwrap();
    let records = f.records();
    assert_eq!(records.len(), 2);
    let id = records[0]["id"].as_str().unwrap();
    let other = records[1]["id"].as_str().unwrap();
    assert!(f.server.cancel_web_download(id));
    assert!(!f.server.cancel_web_download(id));
    assert_eq!(f.terminal(id).await["phase"], "canceled");
    assert_eq!(f.records()[1]["phase"], "transferring");
    assert!(first.bytes().await.is_err());
    // A distinct request to the same workspace is still allowed after single-response cancellation.
    assert_eq!(
        f.client
            .get(f.url("small.txt"))
            .send()
            .await
            .unwrap()
            .bytes()
            .await
            .unwrap()
            .as_ref(),
        PAYLOAD
    );
    f.server
        .configure_directory_workspaces(
            &json!({"revision":2,"enabled":true,"workspaces":[]}).to_string(),
        )
        .await
        .unwrap();
    assert_eq!(f.terminal(other).await["phase"], "canceled");
    assert!(second.bytes().await.is_err());
    f.temporary().await;
    assert_eq!(
        f.client
            .get(format!("{}/api/localsend/v2/info", f.base))
            .send()
            .await
            .unwrap()
            .status(),
        200
    );
}

#[tokio::test]
async fn api_content_has_explicit_origin_and_revoked_key_ends_only_its_response() {
    let _serial = SERIAL.lock().await;
    let f = Fixture::new().await;
    let key = create_key(
        "Downloads".into(),
        WorkspaceGrant {
            scopes: vec![Scope::Files],
            workspaces: vec![ID.into()],
        },
        None,
    )
    .unwrap();
    let mut config = ApiConfig {
        revision: 1,
        enabled: true,
        keys: vec![key.record.clone()],
        ..Default::default()
    };
    f.server
        .configure_integration_api(&serde_json::to_string(&config).unwrap())
        .await
        .unwrap();
    let url = format!(
        "{}{PREFIX}/workspaces/{ID}/files/{}/content?generation=1",
        f.base,
        URL_SAFE_NO_PAD.encode("small.txt")
    );
    assert_eq!(f.client.get(&url).send().await.unwrap().status(), 401);
    assert!(f.records().is_empty());
    assert_eq!(
        f.client
            .head(&url)
            .bearer_auth(&key.secret)
            .send()
            .await
            .unwrap()
            .status(),
        200
    );
    assert!(f.records().is_empty());
    assert_eq!(
        f.client
            .get(&url)
            .bearer_auth(&key.secret)
            .send()
            .await
            .unwrap()
            .bytes()
            .await
            .unwrap()
            .as_ref(),
        PAYLOAD
    );
    let r = &f.records()[0];
    assert_eq!(r["origin"], "api");
    assert_eq!(r["peer"], "");
    assert_eq!(r["phase"], "succeeded");
    std::fs::File::create(f.dir.join("large.bin"))
        .unwrap()
        .set_len(64 * 1024 * 1024)
        .unwrap();
    let large = url.replace(
        &URL_SAFE_NO_PAD.encode("small.txt"),
        &URL_SAFE_NO_PAD.encode("large.bin"),
    );
    let response = f
        .client
        .get(&large)
        .bearer_auth(&key.secret)
        .send()
        .await
        .unwrap();
    assert_eq!(response.status(), 200);
    // Let the spawned download task resolve the key reference and start
    // streaming before revoking the key, so the cancel token path fires
    // rather than the "key not found" path.
    tokio::time::sleep(std::time::Duration::from_millis(100)).await;
    let id = f.records()[1]["id"].as_str().unwrap().to_owned();
    config.revision = 2;
    config.keys.clear();
    f.server
        .configure_integration_api(&serde_json::to_string(&config).unwrap())
        .await
        .unwrap();
    assert_eq!(f.terminal(&id).await["phase"], "canceled");
    assert!(response.bytes().await.is_err());
    assert_eq!(
        f.client
            .get(f.url("small.txt"))
            .send()
            .await
            .unwrap()
            .bytes()
            .await
            .unwrap()
            .as_ref(),
        PAYLOAD
    );
}

#[tokio::test]
async fn zip_preparing_can_be_canceled_before_any_response_bytes() {
    let _serial = SERIAL.lock().await;
    let f = Fixture::new().await;
    std::fs::create_dir(f.dir.join("many")).unwrap();
    for n in 0..5000 {
        std::fs::write(f.dir.join(format!("many/f{n}.txt")), b"x").unwrap();
    }
    let client = f.client.clone();
    let url = f.archive("many");
    let request = tokio::spawn(async move { client.get(url).send().await });
    let record = tokio::time::timeout(Duration::from_secs(5), async {
        loop {
            if let Some(record) = f
                .records()
                .into_iter()
                .find(|r| r["operation"] == "archive")
            {
                break record;
            }
            tokio::task::yield_now().await;
        }
    })
    .await
    .unwrap();
    assert_eq!(record["phase"], "preparing");
    let id = record["id"].as_str().unwrap();
    assert!(f.server.cancel_web_download(id));
    let response = request.await.unwrap().unwrap();
    assert!(matches!(response.status().as_u16(), 401 | 410));
    let end = f.terminal(id).await;
    assert_eq!(end["phase"], "canceled");
    assert_eq!(end["transferred"], 0);
    assert_eq!(
        f.client
            .get(f.url("small.txt"))
            .send()
            .await
            .unwrap()
            .bytes()
            .await
            .unwrap()
            .as_ref(),
        PAYLOAD
    );
}

#[tokio::test]
async fn zip_midstream_cancel_is_terminal_and_does_not_count_internal_sources() {
    let _serial = SERIAL.lock().await;
    let f = Fixture::new().await;
    std::fs::File::create(f.dir.join("large.bin"))
        .unwrap()
        .set_len(64 * 1024 * 1024)
        .unwrap();
    let response = f.client.get(f.archive("")).send().await.unwrap();
    assert_eq!(response.status(), 200);
    let records = f.records();
    assert_eq!(records.len(), 1);
    let record = &records[0];
    assert_eq!(record["operation"], "archive");
    assert_eq!(record["phase"], "transferring");
    assert!(record["transferred"].as_u64().unwrap() < record["total"].as_u64().unwrap());
    let id = record["id"].as_str().unwrap();
    assert!(f.server.cancel_web_download(id));
    assert!(response.bytes().await.is_err());
    assert_eq!(f.terminal(id).await["phase"], "canceled");
    assert_eq!(f.records().len(), 1);
    f.temporary().await;
}

#[tokio::test]
async fn browser_logout_ends_active_archive_without_success_or_extra_file_records() {
    let _serial = SERIAL.lock().await;
    let f = Fixture::new().await;
    let verifier =
        localsend::http::server::directory_auth::hash_password("fixture-password".into())
            .await
            .unwrap();
    f.server.configure_directory_workspaces(&json!({"revision":2,"enabled":true,"workspaces":[{"id":ID,"name":"Protected","slug":"activity-share","root":f.dir,"generation":2,"visible":true,"passwordHash":verifier}]}).to_string()).await.unwrap();
    let archive = f.archive("").replace("generation=1", "generation=2");
    assert_eq!(f.client.get(&archive).send().await.unwrap().status(), 401);
    assert!(f.records().is_empty());
    let unlock = f
        .client
        .post(format!(
            "{}/api/legnasend/v1/workspaces/{ID}/unlock",
            f.base
        ))
        .json(&json!({"generation":2,"password":"fixture-password"}))
        .send()
        .await
        .unwrap();
    assert_eq!(unlock.status(), 200);
    let cookie = unlock.headers()["set-cookie"]
        .to_str()
        .unwrap()
        .split(';')
        .next()
        .unwrap()
        .to_owned();
    std::fs::File::create(f.dir.join("large.bin"))
        .unwrap()
        .set_len(64 * 1024 * 1024)
        .unwrap();
    let response = f
        .client
        .get(&archive)
        .header("cookie", &cookie)
        .send()
        .await
        .unwrap();
    assert_eq!(response.status(), 200);
    let id = f.records()[0]["id"].as_str().unwrap().to_owned();
    let logout = f
        .client
        .post(format!(
            "{}/api/legnasend/v1/workspaces/{ID}/logout",
            f.base
        ))
        .header("cookie", &cookie)
        .json(&json!({"generation":2}))
        .send()
        .await
        .unwrap();
    assert_eq!(logout.status(), 200);
    assert!(response.bytes().await.is_err());
    let end = f.terminal(&id).await;
    assert!(matches!(end["phase"].as_str(), Some("failed" | "canceled")));
    assert!(end["transferred"].as_u64().unwrap() < end["total"].as_u64().unwrap());
    assert_eq!(f.records().len(), 1);
    assert_eq!(
        f.client
            .get(archive)
            .header("cookie", &cookie)
            .send()
            .await
            .unwrap()
            .status(),
        401
    );
    assert_eq!(f.records().len(), 1);
}
