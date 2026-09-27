#![cfg(feature = "http")]
// Compiles the independent registry before the post-freeze router seam lands.
#[allow(dead_code)]
#[path = "../src/http/server/directory_archive_selection.rs"]
mod registry;

use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
use localsend::http::{
    server::{ServerHandle, start_with_port, web::WebConfig},
    state::ClientInfo,
};
use serde_json::{Value, json};
use std::{path::PathBuf, time::Duration};
use tokio::sync::oneshot;
const WS: &str = "91919191-9191-4191-8191-919191919191";
struct Fixture {
    server: ServerHandle,
    client: reqwest::Client,
    url: String,
    temp: PathBuf,
    stop: Option<oneshot::Sender<()>>,
}
impl Fixture {
    async fn new() -> Self {
        let temp =
            std::env::temp_dir().join(format!("legna-archive-ticket-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir(&temp).unwrap();
        let (tx, rx) = oneshot::channel();
        let server = start_with_port(
            0,
            None,
            ClientInfo {
                alias: "ticket-fixture".into(),
                version: "2.2".into(),
                device_model: None,
                device_type: None,
                token: "ticket".into(),
            },
            None,
            None,
            WebConfig::default(),
            rx,
        )
        .await
        .unwrap();
        let f = Self {
            url: format!("http://127.0.0.1:{}", server.port()),
            server,
            client: reqwest::Client::builder()
                .no_proxy()
                .timeout(Duration::from_secs(30))
                .build()
                .unwrap(),
            temp,
            stop: Some(tx),
        };
        f.configure(1).await;
        f
    }
    async fn configure(&self, generation: u64) {
        self.server.configure_directory_workspaces(&json!({"revision":generation,"enabled":true,"workspaces":[{"id":WS,"name":"Ticket files","slug":"ticket-files","root":self.temp,"generation":generation,"visible":true,"allowUpload":false}]}).to_string()).await.unwrap();
    }
    fn path(&self, suffix: &str) -> String {
        format!("{}/api/legnasend/v1/workspaces/{WS}/{suffix}", self.url)
    }
    async fn prepare(&self, ids: Vec<String>) -> Value {
        let response = self
            .client
            .post(self.path("prepare-archive?generation=1"))
            .json(&json!({"path":"","ids":ids}))
            .send()
            .await
            .unwrap();
        assert_eq!(response.status(), 200);
        response.json().await.unwrap()
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        self.stop.take();
        let _ = std::fs::remove_dir_all(&self.temp);
    }
}
#[tokio::test]
async fn real_http_5001_selected_files_use_short_ticket_without_changing_legacy_get() {
    let f = Fixture::new().await;
    let mut ids = Vec::new();
    for i in 0..5001 {
        let name = format!("文件-{i:04}.txt");
        std::fs::write(f.temp.join(&name), [i as u8]).unwrap();
        ids.push(URL_SAFE_NO_PAD.encode(name));
    }
    std::fs::write(f.temp.join("unselected.txt"), b"not selected").unwrap();
    let ticket = f.prepare(ids.clone()).await;
    assert_eq!(ticket["selectedEntries"], 5001);
    assert!(ticket["expiresIn"].as_u64().unwrap() <= 120);
    let path = ticket["downloadUrl"].as_str().unwrap();
    assert!(path.len() < 180);
    assert!(!path.contains("ids="));
    let response = f
        .client
        .get(format!("{}{path}", f.url))
        .send()
        .await
        .unwrap();
    assert_eq!(response.status(), 200);
    let bytes = response.bytes().await.unwrap();
    assert!(
        !bytes
            .windows(b"unselected.txt".len())
            .any(|w| w == b"unselected.txt")
    );
    let end = bytes.windows(4).rposition(|w| w == b"PK\x06\x06").unwrap();
    assert_eq!(
        u64::from_le_bytes(bytes[end + 32..end + 40].try_into().unwrap()),
        5002
    ); // files/ plus selected files.
    for suffix in ["&path=other", "&ids=%5B%5D"] {
        assert_eq!(
            f.client
                .get(format!("{}{path}{suffix}", f.url))
                .send()
                .await
                .unwrap()
                .status(),
            400
        );
    }
    let old = form_urlencoded::Serializer::new(String::new())
        .append_pair("generation", "1")
        .append_pair("ids", &serde_json::to_string(&ids[..129]).unwrap())
        .finish();
    assert_eq!(
        f.client
            .get(f.path(&format!("archive?{old}")))
            .send()
            .await
            .unwrap()
            .status(),
        400
    );
    f.client
        .post(f.path("cancel-archive?generation=1"))
        .json(&json!({"selection":ticket["selection"]}))
        .send()
        .await
        .unwrap()
        .error_for_status()
        .unwrap();
    assert_eq!(
        f.client
            .get(format!("{}{path}", f.url))
            .send()
            .await
            .unwrap()
            .status(),
        410
    );
}
#[tokio::test]
async fn real_http_cancel_stops_own_active_zip_and_next_ticket_works() {
    let f = Fixture::new().await;
    std::fs::File::create(f.temp.join("large.bin"))
        .unwrap()
        .set_len(64 * 1024 * 1024)
        .unwrap();
    std::fs::write(f.temp.join("next.txt"), b"next").unwrap();
    let ticket = f.prepare(vec![URL_SAFE_NO_PAD.encode("large.bin")]).await;
    let response = f
        .client
        .get(format!(
            "{}{}",
            f.url,
            ticket["downloadUrl"].as_str().unwrap()
        ))
        .send()
        .await
        .unwrap();
    assert_eq!(response.status(), 200);
    assert_eq!(
        f.client
            .post(f.path("cancel-archive?generation=1"))
            .json(&json!({"selection":ticket["selection"]}))
            .send()
            .await
            .unwrap()
            .status(),
        200
    );
    match response.bytes().await {
        Err(_) => {}
        Ok(bytes) => assert!(bytes.len() < 64 * 1024 * 1024),
    };
    let next = f.prepare(vec![URL_SAFE_NO_PAD.encode("next.txt")]).await;
    let url = format!("{}{}", f.url, next["downloadUrl"].as_str().unwrap());
    for _ in 0..2 {
        assert_eq!(f.client.head(&url).send().await.unwrap().status(), 200);
    }
    assert!(
        f.client
            .get(&url)
            .send()
            .await
            .unwrap()
            .bytes()
            .await
            .unwrap()
            .windows(4)
            .any(|w| w == b"next")
    );
    f.configure(2).await;
    let old = url.replace("generation=1", "generation=2");
    assert_eq!(f.client.get(old).send().await.unwrap().status(), 410);
    assert!(f.temp.join("large.bin").exists());
}
