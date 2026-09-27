#![cfg(feature = "http")]
use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine};
use localsend::http::server::{
    start_with_port, web::WebConfig, ServerConfigV2, ServerHandle, TlsConfig,
};
use localsend::http::state::ClientInfo;
use serde_json::{json, Value};
use std::{path::PathBuf, time::Duration};
use tokio::sync::{mpsc, oneshot};

struct Fixture {
    server: ServerHandle,
    client: reqwest::Client,
    root: String,
    temp: PathBuf,
    stop: Option<oneshot::Sender<()>>,
    received: std::sync::Arc<tokio::sync::Mutex<Vec<u8>>>,
}
impl Fixture {
    async fn new(tls: bool) -> Self {
        let temp = std::env::temp_dir().join(format!(
            "legnasend-directory-upload-{}",
            uuid::Uuid::new_v4()
        ));
        std::fs::create_dir_all(temp.join("a")).unwrap();
        std::fs::create_dir_all(temp.join("b")).unwrap();
        std::fs::write(temp.join("a/hello.txt"), b"0123456789").unwrap();
        std::fs::write(temp.join("b/hello.txt"), b"unrelated").unwrap();
        let cert = tls.then(|| {
            let cert = localsend::crypto::cert::generate_self_signed().unwrap();
            TlsConfig {
                cert: cert.certificate_pem,
                private_key: cert.private_key_pem,
            }
        });
        use localsend::http::server::common::save::FileUploadTarget;
        use localsend::http::server::v2::{PrepareUploadDecisionV2, ServerEventV2};
        let received = std::sync::Arc::new(tokio::sync::Mutex::new(Vec::new()));
        let received_copy = received.clone();
        let (tx, mut rx) = mpsc::channel(16);
        tokio::spawn(async move {
            while let Some(event) = rx.recv().await {
                match event {
                    ServerEventV2::PrepareUpload {
                        files, decision_tx, ..
                    } => {
                        let _ = decision_tx.send(PrepareUploadDecisionV2::Accept(
                            files.keys().cloned().collect(),
                        ));
                    }
                    ServerEventV2::FileUpload { target_tx, .. } => {
                        let (binary_tx, mut binary_rx) = mpsc::channel(16);
                        let (result_tx, result_rx) = oneshot::channel();
                        let _ = target_tx.send(FileUploadTarget::Stream {
                            binary_tx,
                            result_rx,
                        });
                        let received = received_copy.clone();
                        tokio::spawn(async move {
                            let mut bytes = Vec::new();
                            while let Some(chunk) = binary_rx.recv().await {
                                bytes.extend_from_slice(&chunk);
                            }
                            *received.lock().await = bytes;
                            let _ = result_tx.send(Ok(()));
                        });
                    }
                    _ => {}
                }
            }
        });
        let (stop, stop_rx) = oneshot::channel();
        let server = start_with_port(
            0,
            cert,
            ClientInfo {
                alias: "directory-fixture".into(),
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
            stop_rx,
        )
        .await
        .unwrap();
        let root = format!(
            "{}://127.0.0.1:{}",
            if tls { "https" } else { "http" },
            server.port()
        );
        let client = reqwest::Client::builder()
            .no_proxy()
            .danger_accept_invalid_certs(true)
            .timeout(Duration::from_secs(10))
            .build()
            .unwrap();
        Self {
            server,
            client,
            root,
            temp,
            stop: Some(stop),
            received,
        }
    }
    fn id(name: &str) -> String {
        if name == "a" {
            "11111111-1111-4111-8111-111111111111"
        } else {
            "22222222-2222-4222-8222-222222222222"
        }
        .into()
    }
    fn config(&self, name: &str, generation: u64, visible: bool) -> Value {
        json!({"id":Self::id(name),"name":format!("Workspace {name}"),"slug":format!("workspace-{name}"),"root":self.temp.join(name),"generation":generation,"visible":visible})
    }
    async fn configure(&self, revision: u64, entries: Vec<Value>) -> anyhow::Result<String> {
        self.server
            .configure_directory_workspaces(
                &json!({"revision":revision,"enabled":true,"workspaces":entries}).to_string(),
            )
            .await
    }
    async fn get(&self, path: &str) -> reqwest::Response {
        self.client
            .get(format!("{}{path}", self.root))
            .send()
            .await
            .unwrap()
    }
    fn list(name: &str, generation: u64) -> String {
        format!(
            "/api/legnasend/v1/workspaces/{}/files?generation={generation}",
            Self::id(name)
        )
    }
    fn content(name: &str, path: &str, generation: u64) -> String {
        format!(
            "/api/legnasend/v1/workspaces/{}/files/{}/content?generation={generation}",
            Self::id(name),
            URL_SAFE_NO_PAD.encode(path)
        )
    }
    async fn finish(mut self) {
        let _ = self.stop.take().unwrap().send(());
        self.server.wait_stopped().await;
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.temp);
    }
}

fn upload(
    f: &Fixture,
    workspace: &str,
    generation: u64,
    path: &str,
    body: Vec<u8>,
    directory: bool,
) -> reqwest::RequestBuilder {
    let query = form_urlencoded::Serializer::new(String::new())
        .append_pair("generation", &generation.to_string())
        .append_pair("path", path)
        .append_pair("directory", if directory { "true" } else { "false" })
        .finish();
    f.client
        .post(format!(
            "{}/api/legnasend/v1/workspaces/{}/upload?{query}",
            f.root,
            Fixture::id(workspace)
        ))
        .header("Content-Length", body.len())
        .header("X-LegnaSend-Upload", "1")
        .header("Content-Type", "application/octet-stream")
        .body(body)
}

#[tokio::test]
async fn nested_original_bytes_and_empty_directory_publish_and_list_without_stage() {
    let f = Fixture::new(false).await;
    let mut config = f.config("a", 1, true);
    config["allowUpload"] = json!(true);
    f.configure(1, vec![config]).await.unwrap();
    let bytes = vec![73u8; 3 * 1024 * 1024 + 31];
    let response = upload(
        &f,
        "a",
        1,
        "nested/中文 %/payload.bin",
        bytes.clone(),
        false,
    )
    .send()
    .await
    .unwrap();
    assert_eq!(response.status(), 201);
    let receipt: Value = response.json().await.unwrap();
    assert_eq!(receipt["path"], "nested/中文 %/payload.bin");
    assert_eq!(receipt["size"], bytes.len());
    assert_eq!(
        receipt["sha256"],
        localsend::crypto::hash::sha256_hex(&bytes)
    );
    assert_eq!(receipt["directory"], false);
    assert_eq!(
        std::fs::read(f.temp.join("a/nested/中文 %/payload.bin")).unwrap(),
        bytes
    );
    let response = upload(&f, "a", 1, "nested/empty-dir", vec![], true)
        .send()
        .await
        .unwrap();
    assert_eq!(response.status(), 201);
    assert!(f.temp.join("a/nested/empty-dir").is_dir());
    assert_eq!(
        upload(&f, "a", 1, "nested/empty-dir", vec![], true)
            .send()
            .await
            .unwrap()
            .status(),
        409
    );
    let meta: Value = f.get("/workspace-a/?meta").await.json().await.unwrap();
    assert_eq!(meta["allowUpload"], true);
    assert_eq!(meta["readOnly"], false);
    let listed: Value = f
        .get(&format!(
            "{}&path=nested%2F%E4%B8%AD%E6%96%87%20%25",
            Fixture::list("a", 1)
        ))
        .await
        .json()
        .await
        .unwrap();
    assert_eq!(listed["entries"].as_array().unwrap().len(), 1);
    assert!(!listed.to_string().contains(".legnasend"));
    assert_eq!(
        f.get(&Fixture::content("a", "nested/中文 %/payload.bin", 1))
            .await
            .bytes()
            .await
            .unwrap()
            .as_ref(),
        bytes
    );
    f.finish().await;
}

#[tokio::test]
async fn upload_assets_tls_same_origin_and_native_protocol_coexist() {
    let f = Fixture::new(true).await;
    let mut config = f.config("a", 1, true);
    config["allowUpload"] = json!(true);
    f.configure(1, vec![config]).await.unwrap();
    for path in [
        "/assets/directory-upload.js",
        "/assets/directory-upload.css",
    ] {
        let response = f.get(path).await;
        assert_eq!(response.status(), 200);
        assert!(response.headers()["content-type"]
            .to_str()
            .unwrap()
            .contains(if path.ends_with(".js") {
                "javascript"
            } else {
                "css"
            }));
    }
    assert_eq!(
        upload(&f, "a", 1, "browser.txt", b"browser".to_vec(), false)
            .header("Origin", &f.root)
            .send()
            .await
            .unwrap()
            .status(),
        201
    );
    let native: Value = f.client.post(format!("{}/api/localsend/v2/prepare-upload", f.root)).json(&json!({
      "info":{"alias":"native-original","version":"2.2","fingerprint":"sender","port":53317,"protocol":"https"},
      "files":{"native":{"id":"native","fileName":"native.txt","size":6,"fileType":"text/plain"}}
    })).send().await.unwrap().json().await.unwrap();
    let response = f
        .client
        .post(format!(
            "{}/api/localsend/v2/upload?sessionId={}&fileId=native&token={}",
            f.root,
            native["sessionId"].as_str().unwrap(),
            native["files"]["native"].as_str().unwrap()
        ))
        .body("native")
        .send()
        .await
        .unwrap();
    assert_eq!(response.status(), 200);
    assert_eq!(*f.received.lock().await, b"native");
    f.finish().await;
}

#[tokio::test]
async fn bounded_workspace_admission_releases_after_aborted_bodies() {
    use tokio::{io::AsyncWriteExt, net::TcpStream};
    let f = Fixture::new(false).await;
    let mut config = f.config("a", 1, true);
    config["allowUpload"] = json!(true);
    f.configure(1, vec![config]).await.unwrap();
    let mut sockets = Vec::new();
    for index in 0..2 {
        let mut socket = TcpStream::connect(("127.0.0.1", f.server.port()))
            .await
            .unwrap();
        socket.write_all(format!("POST /api/legnasend/v1/workspaces/{}/upload?generation=1&path=slow{index} HTTP/1.1\r\nHost: 127.0.0.1:{}\r\nContent-Type: application/octet-stream\r\nX-LegnaSend-Upload: 1\r\nContent-Length: 100000\r\n\r\na",Fixture::id("a"),f.server.port()).as_bytes()).await.unwrap();
        sockets.push(socket);
    }
    let stages = || {
        std::fs::read_dir(f.temp.join("a"))
            .unwrap()
            .filter_map(|e| e.ok())
            .filter(|e| {
                e.file_name()
                    .to_string_lossy()
                    .starts_with(".legnasend-receive-")
            })
            .count()
    };
    for _ in 0..100 {
        if stages() == 2 {
            break;
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    assert_eq!(stages(), 2);
    assert_eq!(
        upload(&f, "a", 1, "third", b"third".to_vec(), false)
            .send()
            .await
            .unwrap()
            .status(),
        429
    );
    drop(sockets);
    for _ in 0..100 {
        if stages() == 0 {
            break;
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    assert_eq!(stages(), 0);
    assert!(!f.temp.join("a/slow0").exists());
    assert!(!f.temp.join("a/slow1").exists());
    assert_eq!(
        upload(&f, "a", 1, "third", b"third".to_vec(), false)
            .send()
            .await
            .unwrap()
            .status(),
        201
    );
    f.finish().await;
}
