#![cfg(feature = "http")]
use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
use localsend::http::server::{
    ServerConfigV2, ServerHandle, TlsConfig, start_with_port, web::WebConfig,
};
use localsend::http::state::ClientInfo;
use serde_json::{Value, json};
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
        let temp =
            std::env::temp_dir().join(format!("legnasend-directories-{}", uuid::Uuid::new_v4()));
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

#[tokio::test]
async fn independent_routes_hidden_index_and_original_info_survive_updates() {
    let f = Fixture::new(false).await;
    let port = f.server.port();
    f.configure(1, vec![f.config("a", 1, true), f.config("b", 1, false)])
        .await
        .unwrap();
    let index: Value = f
        .get("/api/legnasend/v1/workspaces")
        .await
        .json()
        .await
        .unwrap();
    assert_eq!(index["workspaces"].as_array().unwrap().len(), 1);
    assert_eq!(index["workspaces"][0]["slug"], "workspace-a");
    assert!(!index.to_string().contains(f.temp.to_str().unwrap()));
    assert_eq!(f.get("/workspace-b/?meta").await.status(), 200);
    assert_eq!(f.get("/workspace-a/").await.status(), 200);
    assert_eq!(f.get("/api/localsend/v2/info").await.status(), 200);
    f.configure(2, vec![f.config("b", 1, false)]).await.unwrap();
    assert_eq!(f.server.port(), port);
    assert_eq!(f.get("/workspace-a/").await.status(), 404);
    assert_eq!(
        f.get(&Fixture::content("a", "hello.txt", 1)).await.status(),
        404
    );
    assert_eq!(
        f.get(&Fixture::content("b", "hello.txt", 1))
            .await
            .text()
            .await
            .unwrap(),
        "unrelated"
    );
    assert_eq!(
        std::fs::read(f.temp.join("a/hello.txt")).unwrap(),
        b"0123456789"
    );
    assert_eq!(f.get("/api/localsend/v1/info").await.status(), 200);
    f.finish().await;
}

#[tokio::test]
async fn directory_pages_are_bounded_idempotent_and_complete() {
    let f = Fixture::new(false).await;
    for i in 0..550 {
        std::fs::write(f.temp.join(format!("a/file-{i}.txt")), b"x").unwrap();
    }
    f.configure(1, vec![f.config("a", 1, true)]).await.unwrap();
    let first: Value = f.get(&Fixture::list("a", 1)).await.json().await.unwrap();
    assert_eq!(first["entries"].as_array().unwrap().len(), 100);
    assert!(first["scanned"].as_u64().unwrap() <= 512);
    let mut names: std::collections::HashSet<String> = first["entries"]
        .as_array()
        .unwrap()
        .iter()
        .map(|v| v["name"].as_str().unwrap().into())
        .collect();
    let mut cursor = first["cursor"].as_str().map(str::to_owned);
    while let Some(token) = cursor {
        let url = format!("{}&cursor={token}", Fixture::list("a", 1));
        let page: Value = f.get(&url).await.json().await.unwrap();
        let retry: Value = f.get(&url).await.json().await.unwrap();
        assert_eq!(page, retry);
        for entry in page["entries"].as_array().unwrap() {
            assert!(names.insert(entry["name"].as_str().unwrap().into()));
        }
        cursor = page["cursor"].as_str().map(str::to_owned);
    }
    assert_eq!(names.len(), 551);
    f.finish().await;
}

#[tokio::test]
async fn mutations_invalidate_old_pages_and_refresh_reads_current_directory() {
    let f = Fixture::new(false).await;
    for i in 0..110 {
        std::fs::write(f.temp.join(format!("a/{i}")), b"x").unwrap();
    }
    f.configure(1, vec![f.config("a", 1, true)]).await.unwrap();
    let first: Value = f.get(&Fixture::list("a", 1)).await.json().await.unwrap();
    tokio::time::sleep(Duration::from_millis(10)).await;
    std::fs::write(f.temp.join("a/new.txt"), b"new").unwrap();
    assert_eq!(
        f.get(&format!(
            "{}&cursor={}",
            Fixture::list("a", 1),
            first["cursor"].as_str().unwrap()
        ))
        .await
        .status(),
        409
    );
    assert_eq!(f.get(&Fixture::list("a", 1)).await.status(), 200);
    f.finish().await;
}

#[tokio::test]
async fn ranges_etags_and_stale_generations_are_enforced() {
    let f = Fixture::new(false).await;
    f.configure(1, vec![f.config("a", 1, true)]).await.unwrap();
    let url = format!("{}{}", f.root, Fixture::content("a", "hello.txt", 1));
    let head = f.client.head(&url).send().await.unwrap();
    assert_eq!(head.headers()["content-length"], "10");
    let tag = head.headers()["etag"].clone();
    let range = f
        .client
        .get(&url)
        .header("range", "bytes=2-5")
        .header("if-match", tag.clone())
        .send()
        .await
        .unwrap();
    assert_eq!(range.status(), 206);
    assert_eq!(range.headers()["content-range"], "bytes 2-5/10");
    assert_eq!(range.text().await.unwrap(), "2345");
    assert_eq!(
        f.client
            .get(&url)
            .header("range", "bytes=999-")
            .send()
            .await
            .unwrap()
            .status(),
        416
    );
    std::fs::write(f.temp.join("a/hello.txt"), b"modified!!").unwrap();
    assert_eq!(
        f.client
            .get(&url)
            .header("if-match", tag)
            .send()
            .await
            .unwrap()
            .status(),
        412
    );
    f.configure(2, vec![f.config("a", 2, true)]).await.unwrap();
    assert_eq!(
        f.get(&Fixture::content("a", "hello.txt", 1)).await.status(),
        409
    );
    f.finish().await;
}

#[tokio::test]
async fn invalid_updates_are_atomic_and_do_not_replace_live_routes() {
    let f = Fixture::new(false).await;
    f.configure(3, vec![f.config("a", 1, true)]).await.unwrap();
    assert!(f.configure(2, vec![]).await.is_err());
    let mut bad = f.config("b", 1, true);
    bad["slug"] = json!("api");
    assert!(f.configure(4, vec![bad]).await.is_err());
    assert!(
        f.configure(4, vec![f.config("a", 1, true), f.config("a", 1, true)])
            .await
            .is_err()
    );
    let mut missing = f.config("b", 1, true);
    missing["root"] = json!("/nonexistent-legnasend-fixture");
    assert!(f.configure(4, vec![missing]).await.is_err());
    assert_eq!(f.get("/workspace-a/").await.status(), 200);
    let mut changed = f.config("a", 1, false);
    changed["name"] = json!("changed");
    assert!(f.configure(4, vec![changed]).await.is_err());
    f.configure(4, vec![]).await.unwrap();
    assert_eq!(f.get("/").await.status(), 200);
    f.finish().await;
}

#[tokio::test]
async fn unsafe_paths_internal_caches_and_cross_workspace_cursors_are_rejected() {
    let f = Fixture::new(false).await;
    std::fs::write(f.temp.join("a/cache.ls"), b"private").unwrap();
    std::fs::create_dir(f.temp.join("a/.legnasend-private")).unwrap();
    for i in 0..101 {
        std::fs::write(f.temp.join(format!("a/{i}.txt")), b"x").unwrap();
    }
    f.configure(1, vec![f.config("a", 1, true), f.config("b", 1, true)])
        .await
        .unwrap();
    for path in [
        "../b/hello.txt",
        "/etc/passwd",
        "a\\b",
        "a:b",
        "CON",
        "hello.txt/../x",
        "cache.ls",
        ".legnasend-private/x",
    ] {
        assert!(
            !f.get(&Fixture::content("a", path, 1))
                .await
                .status()
                .is_success(),
            "{path}"
        );
    }
    let page: Value = f.get(&Fixture::list("a", 1)).await.json().await.unwrap();
    assert!(!page.to_string().contains("cache.ls"));
    let token = page["cursor"].as_str().unwrap();
    assert_eq!(
        f.get(&format!("{}&cursor={token}", Fixture::list("b", 1)))
            .await
            .status(),
        400
    );
    assert_eq!(
        f.get(&format!("{}&path=..%2Fb", Fixture::list("a", 1)))
            .await
            .status(),
        400
    );
    assert_eq!(
        f.get(&format!("{}&generation=2", Fixture::list("a", 1)))
            .await
            .status(),
        400
    );
    let response = f
        .client
        .post(format!("{}/api/legnasend/v1/workspaces", f.root))
        .send()
        .await
        .unwrap();
    assert_eq!(response.status(), 405);
    f.finish().await;
}

#[tokio::test]
async fn native_roots_and_wire_paths_preserve_unicode_spaces_and_literal_url_characters() {
    let f = Fixture::new(false).await;
    let native_root = f.temp.join("资料 %20 # root");
    let directory = "nested 目录 # + %";
    let name = "%2e%2e 用户 + #.txt";
    std::fs::create_dir_all(native_root.join(directory)).unwrap();
    std::fs::write(native_root.join(directory).join(name), b"0123456789").unwrap();
    let mut config = f.config("a", 1, true);
    config["root"] = json!(native_root);
    f.configure(1, vec![config]).await.unwrap();
    let query =
        percent_encoding::utf8_percent_encode(directory, percent_encoding::NON_ALPHANUMERIC);
    let page: Value = f
        .get(&format!("{}&path={query}", Fixture::list("a", 1)))
        .await
        .json()
        .await
        .unwrap();
    assert_eq!(page["entries"][0]["name"], name);
    let relative = format!("{directory}/{name}");
    assert_eq!(page["entries"][0]["id"], URL_SAFE_NO_PAD.encode(&relative));
    assert!(!page.to_string().contains(native_root.to_str().unwrap()));
    let response = f
        .client
        .get(format!("{}{}", f.root, Fixture::content("a", &relative, 1)))
        .header("Range", "bytes=2-5")
        .send()
        .await
        .unwrap();
    assert_eq!(response.status(), 206);
    assert_eq!(response.headers()["content-range"], "bytes 2-5/10");
    assert_eq!(response.bytes().await.unwrap().as_ref(), b"2345");
    f.finish().await;
}

#[cfg(unix)]
#[tokio::test]
async fn capability_root_blocks_escaping_symlinks_and_special_files() {
    use std::os::unix::fs::symlink;
    let f = Fixture::new(false).await;
    symlink(f.temp.join("b"), f.temp.join("a/outside")).unwrap();
    symlink("../b/hello.txt", f.temp.join("a/escape.txt")).unwrap();
    std::fs::write(f.temp.join("a/hidden.LS"), b"partial cache").unwrap();
    std::fs::create_dir(f.temp.join("a/.legnasend-cache")).unwrap();
    std::fs::write(f.temp.join("a/.legnasend-cache/metadata.json"), b"internal").unwrap();
    symlink("hidden.LS", f.temp.join("a/alias.txt")).unwrap();
    symlink(".legnasend-cache", f.temp.join("a/alias-dir")).unwrap();
    f.configure(1, vec![f.config("a", 1, true)]).await.unwrap();
    assert_eq!(
        f.get(&Fixture::content("a", "escape.txt", 1))
            .await
            .status(),
        404
    );
    assert_eq!(
        f.get(&Fixture::content("a", "outside/hello.txt", 1))
            .await
            .status(),
        404
    );
    for relative in ["alias.txt", "alias-dir/metadata.json"] {
        assert_eq!(
            f.get(&Fixture::content("a", relative, 1)).await.status(),
            404
        );
    }
    assert_eq!(
        f.get(&format!("{}&path=alias-dir", Fixture::list("a", 1)))
            .await
            .status(),
        404
    );
    let page: Value = f.get(&Fixture::list("a", 1)).await.json().await.unwrap();
    assert_eq!(page["entries"].as_array().unwrap().len(), 1);
    f.finish().await;
}

#[tokio::test]
async fn closing_one_workspace_cancels_its_stream_but_not_other_routes() {
    use futures_util::StreamExt;
    let f = Fixture::new(false).await;
    let file = std::fs::File::create(f.temp.join("a/large.bin")).unwrap();
    file.set_len(512 * 1024 * 1024).unwrap();
    f.configure(1, vec![f.config("a", 1, true), f.config("b", 1, true)])
        .await
        .unwrap();
    let mut stream = f
        .get(&Fixture::content("a", "large.bin", 1))
        .await
        .bytes_stream();
    assert!(stream.next().await.unwrap().is_ok());
    f.configure(2, vec![f.config("b", 1, true)]).await.unwrap();
    let mut received = 0;
    let mut aborted = false;
    while let Some(chunk) = stream.next().await {
        match chunk {
            Ok(bytes) => received += bytes.len(),
            Err(_) => {
                aborted = true;
                break;
            }
        }
    }
    assert!(aborted);
    assert!(received < 512 * 1024 * 1024);
    assert_eq!(
        f.get(&Fixture::content("b", "hello.txt", 1))
            .await
            .text()
            .await
            .unwrap(),
        "unrelated"
    );
    f.finish().await;
}

#[tokio::test]
async fn tls_browser_access_can_be_enabled_without_rebinding_the_port() {
    let f = Fixture::new(true).await;
    let port = f.server.port();
    assert!(f.client.get(format!("{}/", f.root)).send().await.is_err());
    f.configure(1, vec![f.config("a", 1, true)]).await.unwrap();
    assert_eq!(f.get("/workspace-a/").await.status(), 200);
    assert_eq!(f.server.port(), port);
    assert_eq!(
        f.get(&Fixture::content("a", "hello.txt", 1))
            .await
            .text()
            .await
            .unwrap(),
        "0123456789"
    );
    f.finish().await;
}

#[tokio::test]
async fn metadata_edits_preserve_active_streams_and_other_workspace_cursors() {
    use futures_util::StreamExt;
    let f = Fixture::new(false).await;
    let size = 64 * 1024 * 1024;
    std::fs::File::create(f.temp.join("a/large.bin"))
        .unwrap()
        .set_len(size)
        .unwrap();
    for i in 0..120 {
        std::fs::write(f.temp.join(format!("b/{i}.txt")), b"x").unwrap();
    }
    f.configure(1, vec![f.config("a", 1, true), f.config("b", 1, true)])
        .await
        .unwrap();
    let page: Value = f.get(&Fixture::list("b", 1)).await.json().await.unwrap();
    let cursor = page["cursor"].as_str().unwrap();
    let mut stream = f
        .get(&Fixture::content("a", "large.bin", 1))
        .await
        .bytes_stream();
    let mut received = stream.next().await.unwrap().unwrap().len() as u64;
    let mut changed = f.config("a", 2, false);
    changed["name"] = json!("Renamed");
    f.configure(2, vec![changed, f.config("b", 1, true)])
        .await
        .unwrap();
    while let Some(chunk) = stream.next().await {
        received += chunk.unwrap().len() as u64;
    }
    assert_eq!(received, size);
    assert_eq!(
        f.get(&format!("{}&cursor={cursor}", Fixture::list("b", 1)))
            .await
            .status(),
        200
    );
    assert_eq!(
        f.get(&Fixture::content("a", "hello.txt", 1)).await.status(),
        409
    );
    assert_eq!(
        f.get(&Fixture::content("a", "hello.txt", 2)).await.status(),
        200
    );
    f.finish().await;
}

#[tokio::test]
async fn original_native_upload_session_survives_directory_removal() {
    let f = Fixture::new(false).await;
    let bytes = b"original LocalSend body; no archive or custom envelope";
    f.configure(1, vec![f.config("a", 1, true)]).await.unwrap();
    let info = json!({"alias":"Original peer", "version":"2.2", "fingerprint":"peer", "port":53317, "protocol":"http"});
    let registered = f
        .client
        .post(format!("{}/api/localsend/v2/register", f.root))
        .json(&info)
        .send()
        .await
        .unwrap();
    assert_eq!(registered.status(), 200);
    let request = json!({"info":info, "files":{"file":{"id":"file", "fileName":"source.txt", "size":bytes.len(), "fileType":"text/plain"}}});
    let prepared = f
        .client
        .post(format!("{}/api/localsend/v2/prepare-upload", f.root))
        .json(&request)
        .send()
        .await
        .unwrap();
    assert_eq!(prepared.status(), 200);
    let session: Value = prepared.json().await.unwrap();
    f.configure(2, vec![]).await.unwrap();
    assert_eq!(f.get("/workspace-a/").await.status(), 404);
    let query = form_urlencoded::Serializer::new(String::new())
        .extend_pairs([
            ("sessionId", session["sessionId"].as_str().unwrap()),
            ("fileId", "file"),
            ("token", session["files"]["file"].as_str().unwrap()),
        ])
        .finish();
    let uploaded = f
        .client
        .post(format!("{}/api/localsend/v2/upload?{query}", f.root))
        .body(bytes.as_slice())
        .send()
        .await
        .unwrap();
    assert_eq!(uploaded.status(), 200);
    assert_eq!(*f.received.lock().await, bytes);
    f.finish().await;
}

static AUTH_TEST_LOCK: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());
async fn login(f: &Fixture, name: &str, generation: u64, password: &str) -> reqwest::Response {
    f.client
        .post(format!(
            "{}/api/legnasend/v1/workspaces/{}/unlock",
            f.root,
            Fixture::id(name)
        ))
        .json(&json!({"generation":generation,"password":password}))
        .send()
        .await
        .unwrap()
}
fn cookie(response: &reqwest::Response) -> String {
    response.headers()["set-cookie"]
        .to_str()
        .unwrap()
        .split(';')
        .next()
        .unwrap()
        .into()
}
async fn protected(
    f: &Fixture,
    name: &str,
    generation: u64,
    visible: bool,
    password: &str,
) -> Value {
    let mut config = f.config(name, generation, visible);
    config["passwordHash"] = json!(
        localsend::http::server::directory_auth::hash_password(password.into())
            .await
            .unwrap()
    );
    config
}

#[tokio::test]
async fn visibility_and_password_are_independent_and_content_never_leaks_without_grants() {
    let _serial = AUTH_TEST_LOCK.lock().await;
    let f = Fixture::new(false).await;
    let a = protected(&f, "a", 1, true, "1234").await;
    f.configure(1, vec![a.clone(), f.config("b", 1, false)])
        .await
        .unwrap();
    let index: Value = f
        .get("/api/legnasend/v1/workspaces")
        .await
        .json()
        .await
        .unwrap();
    assert_eq!(index["workspaces"].as_array().unwrap().len(), 1);
    assert_eq!(index["workspaces"][0]["protected"], true);
    let meta = f.get("/workspace-a/?meta").await.text().await.unwrap();
    assert!(!meta.contains("pbkdf2") && !meta.contains("passwordHash"));
    for path in [Fixture::list("a", 1), Fixture::content("a", "hello.txt", 1)] {
        let rejected = f.get(&path).await;
        assert_eq!(rejected.status(), 401);
        assert!(!rejected.text().await.unwrap().contains("hello.txt"));
        assert_eq!(
            f.client
                .head(format!("{}{path}", f.root))
                .send()
                .await
                .unwrap()
                .status(),
            401
        );
    }
    let rejected = login(&f, "a", 1, "wrong").await;
    assert_eq!(rejected.status(), 401);
    assert!(rejected.headers().get("set-cookie").is_none());
    let accepted = login(&f, "a", 1, "1234").await;
    assert_eq!(accepted.status(), 200);
    let grant = cookie(&accepted);
    let options = accepted.headers()["set-cookie"].to_str().unwrap();
    assert!(
        options.contains("HttpOnly")
            && options.contains("SameSite=Strict")
            && options.contains("Max-Age=3600")
    );
    assert!(!accepted.text().await.unwrap().contains(&grant));
    let bytes = f
        .client
        .get(format!(
            "{}{}",
            f.root,
            Fixture::content("a", "hello.txt", 1)
        ))
        .header("cookie", &grant)
        .header("range", "bytes=2-5")
        .send()
        .await
        .unwrap();
    assert_eq!(bytes.status(), 206);
    assert_eq!(bytes.text().await.unwrap(), "2345");
    let b = protected(&f, "b", 2, true, "5678").await;
    let mut hidden = a;
    hidden["visible"] = json!(false);
    hidden["generation"] = json!(2);
    f.configure(2, vec![hidden, b]).await.unwrap();
    assert_eq!(f.get("/workspace-a/?meta").await.status(), 200);
    assert_eq!(
        f.client
            .get(format!("{}{}", f.root, Fixture::list("b", 2)))
            .header("cookie", &grant)
            .send()
            .await
            .unwrap()
            .status(),
        401
    );
    // A hide/rename is not a password change; a valid cookie remains usable.
    assert_eq!(
        f.client
            .get(format!("{}{}", f.root, Fixture::list("a", 2)))
            .header("cookie", &grant)
            .send()
            .await
            .unwrap()
            .status(),
        200
    );
    f.finish().await;
}

#[tokio::test]
async fn changing_password_revokes_old_cookies_streams_and_late_generations_only_for_that_workspace()
 {
    use futures_util::StreamExt;
    let _serial = AUTH_TEST_LOCK.lock().await;
    let f = Fixture::new(false).await;
    std::fs::File::create(f.temp.join("a/large.bin"))
        .unwrap()
        .set_len(512 * 1024 * 1024)
        .unwrap();
    f.configure(
        1,
        vec![
            protected(&f, "a", 1, true, "old-password").await,
            f.config("b", 1, true),
        ],
    )
    .await
    .unwrap();
    let grant = cookie(&login(&f, "a", 1, "old-password").await);
    let mut stream = f
        .client
        .get(format!(
            "{}{}",
            f.root,
            Fixture::content("a", "large.bin", 1)
        ))
        .header("cookie", &grant)
        .send()
        .await
        .unwrap()
        .bytes_stream();
    assert!(stream.next().await.unwrap().is_ok());
    f.configure(
        2,
        vec![
            protected(&f, "a", 2, true, "new-password").await,
            f.config("b", 1, true),
        ],
    )
    .await
    .unwrap();
    let mut aborted = false;
    while let Some(chunk) = stream.next().await {
        if chunk.is_err() {
            aborted = true;
            break;
        }
    }
    assert!(aborted);
    assert_eq!(
        f.client
            .get(format!("{}{}", f.root, Fixture::list("a", 2)))
            .header("cookie", &grant)
            .send()
            .await
            .unwrap()
            .status(),
        401
    );
    assert_eq!(login(&f, "a", 1, "old-password").await.status(), 409);
    assert_eq!(login(&f, "a", 2, "old-password").await.status(), 401);
    assert_eq!(login(&f, "a", 2, "new-password").await.status(), 200);
    assert_eq!(
        f.get(&Fixture::content("b", "hello.txt", 1))
            .await
            .text()
            .await
            .unwrap(),
        "unrelated"
    );
    f.configure(3, vec![f.config("a", 3, true), f.config("b", 1, true)])
        .await
        .unwrap();
    assert_eq!(f.get(&Fixture::list("a", 3)).await.status(), 200);
    f.finish().await;
}

#[tokio::test]
async fn logout_is_scoped_and_cookies_do_not_appear_in_urls_or_api_bodies() {
    let _serial = AUTH_TEST_LOCK.lock().await;
    let f = Fixture::new(false).await;
    use futures_util::StreamExt;
    std::fs::File::create(f.temp.join("a/logout.bin"))
        .unwrap()
        .set_len(512 * 1024 * 1024)
        .unwrap();
    f.configure(1, vec![protected(&f, "a", 1, true, "1234").await])
        .await
        .unwrap();
    let first = cookie(&login(&f, "a", 1, "1234").await);
    let second = cookie(&login(&f, "a", 1, "1234").await);
    assert_ne!(first, second);
    let mut active = f
        .client
        .get(format!(
            "{}{}",
            f.root,
            Fixture::content("a", "logout.bin", 1)
        ))
        .header("cookie", &first)
        .send()
        .await
        .unwrap()
        .bytes_stream();
    assert!(active.next().await.unwrap().is_ok());
    let logout = f
        .client
        .post(format!(
            "{}/api/legnasend/v1/workspaces/{}/logout",
            f.root,
            Fixture::id("a")
        ))
        .header("cookie", &first)
        .json(&json!({}))
        .send()
        .await
        .unwrap();
    assert_eq!(logout.status(), 200);
    assert!(
        logout.headers()["set-cookie"]
            .to_str()
            .unwrap()
            .contains("Max-Age=0")
    );
    let mut aborted = false;
    while let Some(chunk) = active.next().await {
        if chunk.is_err() {
            aborted = true;
            break;
        }
    }
    assert!(aborted);
    for (grant, expected) in [(&first, 401), (&second, 200)] {
        assert_eq!(
            f.client
                .get(format!("{}{}", f.root, Fixture::list("a", 1)))
                .header("cookie", grant)
                .send()
                .await
                .unwrap()
                .status(),
            expected
        );
    }
    assert_eq!(
        f.get(&format!(
            "{}&token={}",
            Fixture::list("a", 1),
            second.split_once('=').unwrap().1
        ))
        .await
        .status(),
        401
    );
    f.finish().await;
}

#[tokio::test]
async fn unlock_enforces_origin_body_budget_attempt_budget_and_secure_tls_cookie() {
    let _serial = AUTH_TEST_LOCK.lock().await;
    let f = Fixture::new(true).await;
    f.configure(1, vec![protected(&f, "a", 1, true, "1234").await])
        .await
        .unwrap();
    let url = format!(
        "{}/api/legnasend/v1/workspaces/{}/unlock",
        f.root,
        Fixture::id("a")
    );
    assert_eq!(
        f.client
            .post(&url)
            .header("origin", "https://different.invalid")
            .json(&json!({"password":"1234","generation":1}))
            .send()
            .await
            .unwrap()
            .status(),
        403
    );
    assert_eq!(
        f.client
            .post(&url)
            .header("sec-fetch-site", "cross-site")
            .json(&json!({}))
            .send()
            .await
            .unwrap()
            .status(),
        403
    );
    assert_eq!(
        f.client
            .post(&url)
            .body("password=1234")
            .send()
            .await
            .unwrap()
            .status(),
        415
    );
    assert_eq!(
        f.client
            .post(&url)
            .header("content-type", "application/json")
            .body("x".repeat(4097))
            .send()
            .await
            .unwrap()
            .status(),
        413
    );
    let grant = login(&f, "a", 1, "1234").await;
    assert_eq!(grant.status(), 200);
    assert!(
        grant.headers()["set-cookie"]
            .to_str()
            .unwrap()
            .contains("; Secure")
    );
    for _ in 0..3 {
        assert_eq!(login(&f, "a", 1, "wrong").await.status(), 401);
    }
    let limited = login(&f, "a", 1, "1234").await;
    assert_eq!(limited.status(), 429);
    assert!(limited.headers().contains_key("retry-after"));
    assert_eq!(f.get("/api/localsend/v2/info").await.status(), 200);
    f.finish().await;
}

#[tokio::test]
async fn directory_preview_assets_and_inline_types_work_without_temporary_sharing() {
    let f = Fixture::new(false).await;
    f.configure(1, vec![f.config("a", 1, true)]).await.unwrap();
    for asset in [
        "directory-preview.js",
        "directory-preview.css",
        "text-preview.js",
        "text-reader.css",
        "text-search.js",
        "markdown-preview.js",
        "markdown-worker.js",
        "web-i18n.js",
        "vendor/marked.umd.js",
    ] {
        let response = f.get(&format!("/assets/{asset}")).await;
        assert_eq!(response.status(), 200, "{asset}");
        assert_eq!(response.headers()["x-content-type-options"], "nosniff");
    }
    // Directory assets do not implicitly enable the legacy download flow.
    assert_eq!(
        f.get("/api/localsend/v2/download?sessionId=absent&fileId=absent")
            .await
            .status(),
        403
    );
    for (name, mime) in [
        ("sample.MP4", "video/mp4"),
        ("sample.mov", "video/quicktime"),
        ("sample.WAV", "audio/wav"),
        ("sample.opus", "audio/ogg"),
        ("sample.m4a", "audio/mp4"),
        ("sample.webp", "image/webp"),
        ("sample.avif", "image/avif"),
        ("sample.md", "text/plain; charset=utf-8"),
        ("sample.txt", "text/plain; charset=utf-8"),
    ] {
        std::fs::write(f.temp.join("a").join(name), b"0123456789").unwrap();
        let path = Fixture::content("a", name, 1);
        let plain = f.get(&path).await;
        assert_eq!(plain.headers()["content-type"], "application/octet-stream");
        assert!(
            plain.headers()["content-disposition"]
                .to_str()
                .unwrap()
                .starts_with("attachment;")
        );
        let response = f
            .client
            .get(format!("{}{path}&preview=1", f.root))
            .header("Range", "bytes=2-5")
            .send()
            .await
            .unwrap();
        assert_eq!(response.status(), 206);
        assert_eq!(response.headers()["content-type"], mime);
        assert_eq!(response.headers()["x-content-type-options"], "nosniff");
        assert!(
            response.headers()["content-disposition"]
                .to_str()
                .unwrap()
                .starts_with("inline;")
        );
        assert_eq!(response.bytes().await.unwrap().as_ref(), b"2345");
    }
    for name in ["active.svg", "active.html", "active.js", "unknown.bin"] {
        std::fs::write(f.temp.join("a").join(name), b"<script>test</script>").unwrap();
        let response = f
            .get(&format!("{}&preview=1", Fixture::content("a", name, 1)))
            .await;
        assert_eq!(
            response.headers()["content-type"],
            "application/octet-stream"
        );
        assert!(
            response.headers()["content-disposition"]
                .to_str()
                .unwrap()
                .starts_with("attachment;")
        );
    }
    assert_eq!(
        f.get(&format!(
            "{}&preview=yes",
            Fixture::content("a", "hello.txt", 1)
        ))
        .await
        .status(),
        400
    );
    f.finish().await;
}

#[tokio::test]
async fn preview_versions_never_replace_passwords_and_changed_resources_reject_old_media_urls() {
    let _serial = AUTH_TEST_LOCK.lock().await;
    let f = Fixture::new(false).await;
    let config = protected(&f, "a", 1, true, "preview-password").await;
    f.configure(1, vec![config]).await.unwrap();
    let path = format!("{}&preview=1", Fixture::content("a", "hello.txt", 1));
    assert_eq!(f.get(&path).await.status(), 401);
    let grant = cookie(&login(&f, "a", 1, "preview-password").await);
    let head = f
        .client
        .head(format!("{}{path}", f.root))
        .header("Cookie", &grant)
        .send()
        .await
        .unwrap();
    assert_eq!(head.status(), 200);
    let tag = head.headers()["etag"].to_str().unwrap();
    let version = percent_encoding::utf8_percent_encode(tag, percent_encoding::NON_ALPHANUMERIC);
    let pinned = format!("{}{path}&version={version}", f.root);
    assert_eq!(f.client.get(&pinned).send().await.unwrap().status(), 401);
    let response = f
        .client
        .get(&pinned)
        .header("Cookie", &grant)
        .header("Range", "bytes=4-6")
        .send()
        .await
        .unwrap();
    assert_eq!(response.status(), 206);
    assert_eq!(response.bytes().await.unwrap().as_ref(), b"456");
    assert_eq!(
        f.client
            .get(&pinned)
            .header("Cookie", &grant)
            .header("If-Match", "\"different\"")
            .send()
            .await
            .unwrap()
            .status(),
        412
    );
    for invalid in ["*", "weak", "%22bad%22", "%22%22"] {
        assert_eq!(
            f.client
                .get(format!("{}{path}&version={invalid}", f.root))
                .header("Cookie", &grant)
                .send()
                .await
                .unwrap()
                .status(),
            400
        );
    }
    std::fs::write(f.temp.join("a/hello.txt"), b"changed file content").unwrap();
    for method in [reqwest::Method::GET, reqwest::Method::HEAD] {
        assert_eq!(
            f.client
                .request(method, &pinned)
                .header("Cookie", &grant)
                .send()
                .await
                .unwrap()
                .status(),
            412
        );
    }
    // An explicit fresh preview can discover the new metadata, but not with a revoked grant.
    assert_eq!(
        f.client
            .head(format!("{}{path}", f.root))
            .header("Cookie", &grant)
            .send()
            .await
            .unwrap()
            .status(),
        200
    );
    let changed = protected(&f, "a", 2, true, "rotated-password").await;
    f.configure(2, vec![changed]).await.unwrap();
    assert_eq!(
        f.client
            .get(format!(
                "{}{}&preview=1",
                f.root,
                Fixture::content("a", "hello.txt", 2)
            ))
            .header("Cookie", &grant)
            .send()
            .await
            .unwrap()
            .status(),
        401
    );
    f.finish().await;
}

#[tokio::test]
async fn temporary_share_is_a_child_of_the_listener_not_a_replacement_for_directories() {
    use localsend::http::server::web::{WebDownloadConfig, WebDownloadEvent, WebMode};
    use localsend::model::transfer::{FileContent, FileDto};
    use std::collections::HashMap;
    for tls in [false, true] {
        let f = Fixture::new(tls).await;
        let port = f.server.port();
        f.configure(1, vec![f.config("a", 1, true)]).await.unwrap();
        let (events, mut rx) = mpsc::channel(16);
        let worker = tokio::spawn(async move {
            while let Some(event) = rx.recv().await {
                match event {
                    WebDownloadEvent::PrepareDownloadAborted { .. } => {}
                    WebDownloadEvent::PrepareDownload { decision_tx, .. } => {
                        let _ = decision_tx.send(true);
                    }
                    WebDownloadEvent::FileDownload { content_tx, .. } => {
                        let (tx, body) = mpsc::channel(1);
                        tx.send(bytes::Bytes::from_static(b"temp")).await.unwrap();
                        let _ = content_tx.send(FileContent::Stream(body));
                    }
                }
            }
        });
        for _ in 0..3 {
            f.server.set_web_mode(WebMode::Duplex {
                download: WebDownloadConfig {
                    files: HashMap::from([(
                        "temp".into(),
                        FileDto {
                            id: "temp".into(),
                            file_name: "temporary.txt".into(),
                            size: 4,
                            file_type: "text/plain".into(),
                            sha256: None,
                            preview: None,
                            metadata: None,
                        },
                    )]),
                    pin: None,
                    event_tx: events.clone(),
                },
                allow_upload: true,
            });
            assert!(f.get("/").await.text().await.unwrap().contains("directory"));
            assert!(
                f.get("/share")
                    .await
                    .text()
                    .await
                    .unwrap()
                    .contains("workspace-tabs")
            );
            let index: Value = f
                .get("/api/legnasend/v1/workspaces")
                .await
                .json()
                .await
                .unwrap();
            assert_eq!(index["temporary"], true);
            assert_eq!(index["workspaces"].as_array().unwrap().len(), 1);
            let prepared: Value = f
                .client
                .post(format!("{}/api/localsend/v2/prepare-download", f.root))
                .send()
                .await
                .unwrap()
                .json()
                .await
                .unwrap();
            let session = prepared["sessionId"].as_str().unwrap();
            assert_eq!(
                f.get(&format!(
                    "/api/localsend/v2/download?sessionId={session}&fileId=temp"
                ))
                .await
                .bytes()
                .await
                .unwrap(),
                "temp"
            );
            f.server.set_web_mode(WebMode::Disabled);
            assert_eq!(f.get("/share").await.status(), 403);
            let index: Value = f
                .get("/api/legnasend/v1/workspaces")
                .await
                .json()
                .await
                .unwrap();
            assert_eq!(index["temporary"], false);
            assert_eq!(
                f.get(&Fixture::content("a", "hello.txt", 1))
                    .await
                    .bytes()
                    .await
                    .unwrap(),
                "0123456789"
            );
            assert_eq!(f.get("/api/localsend/v2/info").await.status(), 200);
            assert_eq!(f.server.port(), port);
        }
        worker.abort();
        f.finish().await;
    }
}

#[tokio::test]
async fn foreground_directory_state_is_bounded_root_confined_and_tracks_mutations() {
    let f = Fixture::new(false).await;
    f.configure(1, vec![f.config("a", 1, true)]).await.unwrap();
    let first: Value = f.get(&Fixture::list("a", 1)).await.json().await.unwrap();
    let id = URL_SAFE_NO_PAD.encode("hello.txt");
    let base = format!(
        "/api/legnasend/v1/workspaces/{}/state?generation=1",
        Fixture::id("a")
    );
    let state: Value = f
        .get(&format!("{base}&ids={id}"))
        .await
        .json()
        .await
        .unwrap();
    assert_eq!(state["stamp"], first["stamp"]);
    assert_eq!(state["stamp"].as_str().unwrap().len(), 64);
    assert_eq!(state["entries"][0]["size"], 10);
    assert_eq!(state["missing"], json!([]));
    std::fs::write(f.temp.join("a/hello.txt"), b"updated and longer").unwrap();
    let updated: Value = f
        .get(&format!("{base}&ids={id}"))
        .await
        .json()
        .await
        .unwrap();
    assert_eq!(updated["entries"][0]["size"], 18);
    // Directory timestamp checks are distinct from visible-file metadata checks.
    tokio::time::sleep(Duration::from_millis(20)).await;
    std::fs::rename(f.temp.join("a/hello.txt"), f.temp.join("a/renamed.txt")).unwrap();
    let renamed: Value = f
        .get(&format!("{base}&ids={id}"))
        .await
        .json()
        .await
        .unwrap();
    assert_ne!(renamed["stamp"], state["stamp"]);
    assert_eq!(renamed["missing"], json!([id]));
    for value in ["../hello.txt", "sub/hello.txt", ".ls", ".legnasend-private"] {
        assert_eq!(
            f.get(&format!("{base}&ids={}", URL_SAFE_NO_PAD.encode(value)))
                .await
                .status(),
            400
        );
    }
    assert_eq!(f.get(&format!("{base}&ids={id},{id}")).await.status(), 400);
    let too_many = (0..65)
        .map(|i| URL_SAFE_NO_PAD.encode(format!("{i}.txt")))
        .collect::<Vec<_>>()
        .join(",");
    assert_eq!(f.get(&format!("{base}&ids={too_many}")).await.status(), 400);
    assert_eq!(
        f.get(&base.replace("generation=1", "generation=2"))
            .await
            .status(),
        409
    );
    assert_eq!(f.get("/api/localsend/v2/info").await.status(), 200);
    f.finish().await;
}

#[tokio::test]
async fn foreground_state_uses_workspace_cookie_and_revokes_with_source() {
    let _serial = AUTH_TEST_LOCK.lock().await;
    let f = Fixture::new(true).await;
    f.configure(1, vec![protected(&f, "a", 1, true, "probe-password").await])
        .await
        .unwrap();
    let route = format!(
        "/api/legnasend/v1/workspaces/{}/state?generation=1&ids={}",
        Fixture::id("a"),
        URL_SAFE_NO_PAD.encode("hello.txt")
    );
    assert_eq!(f.get(&route).await.status(), 401);
    let grant = cookie(&login(&f, "a", 1, "probe-password").await);
    assert_eq!(
        f.client
            .get(format!("{}{route}", f.root))
            .header("Cookie", &grant)
            .send()
            .await
            .unwrap()
            .status(),
        200
    );
    let logout = f
        .client
        .post(format!(
            "{}/api/legnasend/v1/workspaces/{}/logout",
            f.root,
            Fixture::id("a")
        ))
        .header("Cookie", &grant)
        .header("Content-Type", "application/json")
        .body("{}")
        .send()
        .await
        .unwrap();
    assert_eq!(logout.status(), 200);
    assert_eq!(
        f.client
            .get(format!("{}{route}", f.root))
            .header("Cookie", &grant)
            .send()
            .await
            .unwrap()
            .status(),
        401
    );
    f.configure(2, vec![]).await.unwrap();
    assert_eq!(f.get(&route).await.status(), 404);
    f.finish().await;
}

#[tokio::test]
async fn name_filter_scans_ten_thousand_entries_with_exact_bounded_idempotent_pages() {
    let f = Fixture::new(false).await;
    for i in 0..10_000 {
        let name = if i % 2 == 0 {
            format!("NEEDLE-甲-{i:05}.TXT")
        } else {
            format!("other-{i:05}.txt")
        };
        std::fs::write(f.temp.join("a").join(name), b"x").unwrap();
    }
    let nested = f.temp.join("a/child");
    std::fs::create_dir(&nested).unwrap();
    std::fs::write(nested.join("NEEDLE-甲-hidden.txt"), b"not recursive").unwrap();
    f.configure(1, vec![f.config("a", 1, true)]).await.unwrap();
    let filter = form_urlencoded::Serializer::new(String::new())
        .append_pair("filter", "needle-甲")
        .finish();
    let base = format!("{}&{filter}", Fixture::list("a", 1));
    let mut next = base.clone();
    let mut names = std::collections::HashSet::new();
    let mut pages = 0;
    loop {
        let response = f.get(&next).await;
        assert_eq!(response.status(), 200);
        let page: Value = response.json().await.unwrap();
        assert_eq!(page["filter"], "needle-甲");
        assert!(page["entries"].as_array().unwrap().len() <= 100);
        assert!(page["scanned"].as_u64().unwrap() <= 512);
        for entry in page["entries"].as_array().unwrap() {
            let name = entry["name"].as_str().unwrap();
            assert!(name.starts_with("NEEDLE-甲-"));
            assert!(names.insert(name.to_string()), "duplicate {name}");
        }
        pages += 1;
        let Some(cursor) = page["cursor"].as_str() else {
            break;
        };
        if pages == 1 {
            let mismatch = format!("{}&filter=other&cursor={cursor}", Fixture::list("a", 1));
            assert_eq!(f.get(&mismatch).await.status(), 400);
            let omitted = format!("{}&cursor={cursor}", Fixture::list("a", 1));
            assert_eq!(f.get(&omitted).await.status(), 400);
        }
        next = format!("{base}&cursor={cursor}");
        let repeated: Value = f.get(&next).await.json().await.unwrap();
        assert_eq!(repeated, f.get(&next).await.json::<Value>().await.unwrap());
    }
    assert_eq!(names.len(), 5000);
    assert!(pages >= 50);
    assert!(!names.contains("NEEDLE-甲-hidden.txt"));
    f.finish().await;
}

#[tokio::test]
async fn filter_is_literal_bounded_and_its_empty_pages_continue_until_exhaustion() {
    let f = Fixture::new(false).await;
    for i in 0..5000 {
        std::fs::write(f.temp.join(format!("a/ordinary-{i}.txt")), b"x").unwrap();
    }
    std::fs::write(f.temp.join("a/[literal]*.txt"), b"match").unwrap();
    f.configure(1, vec![f.config("a", 1, true)]).await.unwrap();
    let encoded = form_urlencoded::Serializer::new(String::new())
        .append_pair("filter", "[literal]*")
        .finish();
    let base = format!("{}&{encoded}", Fixture::list("a", 1));
    let mut next = base.clone();
    let mut names = vec![];
    let mut pages = 0;
    loop {
        let page: Value = f.get(&next).await.json().await.unwrap();
        pages += 1;
        assert!(page["scanned"].as_u64().unwrap() <= 512);
        names.extend(
            page["entries"]
                .as_array()
                .unwrap()
                .iter()
                .map(|entry| entry["name"].as_str().unwrap().to_string()),
        );
        let Some(cursor) = page["cursor"].as_str() else {
            break;
        };
        next = format!("{base}&cursor={cursor}");
    }
    assert!(pages >= 10);
    assert_eq!(names, ["[literal]*.txt"]);
    for filter in ["x".repeat(257), "bad\nfilter".into(), "bad\0filter".into()] {
        let encoded = form_urlencoded::Serializer::new(String::new())
            .append_pair("filter", &filter)
            .finish();
        assert_eq!(
            f.get(&format!("{}&{encoded}", Fixture::list("a", 1)))
                .await
                .status(),
            400
        );
    }
    f.finish().await;
}

#[tokio::test]
async fn changed_listing_relocates_anchor_in_bounded_pages_without_reordering() {
    let f = Fixture::new(false).await;
    for index in 0..900 {
        std::fs::write(f.temp.join("a").join(format!("file-{index:04}.txt")), b"x").unwrap();
    }
    f.configure(1, vec![f.config("a", 1, true)]).await.unwrap();
    let list = Fixture::list("a", 1);
    let mut url = list.clone();
    let mut ids = Vec::new();
    loop {
        let page: Value = f.get(&url).await.json().await.unwrap();
        ids.extend(
            page["entries"]
                .as_array()
                .unwrap()
                .iter()
                .map(|entry| entry["id"].as_str().unwrap().to_owned()),
        );
        let Some(cursor) = page["cursor"].as_str() else {
            break;
        };
        url = format!("{list}&cursor={cursor}");
    }
    let anchor = &ids[700];
    url = format!("{list}&anchor={anchor}");
    let mut calls = 0;
    loop {
        let page: Value = f.get(&url).await.json().await.unwrap();
        calls += 1;
        assert!(page["scanned"].as_u64().unwrap() <= 512);
        assert!(page["entries"].as_array().unwrap().len() <= 100);
        if page["anchorPending"] == true {
            assert!(page["entries"].as_array().unwrap().is_empty());
            url = format!("{list}&cursor={}", page["cursor"].as_str().unwrap());
        } else {
            assert_eq!(page["offset"], 700);
            let returned: Vec<_> = page["entries"]
                .as_array()
                .unwrap()
                .iter()
                .map(|entry| entry["id"].as_str().unwrap())
                .collect();
            assert_eq!(
                returned,
                ids[700..800].iter().map(String::as_str).collect::<Vec<_>>()
            );
            break;
        }
    }
    assert_eq!(calls, 2);
    let mut url = format!("{list}&anchor={}", URL_SAFE_NO_PAD.encode("deleted.txt"));
    loop {
        let page: Value = f.get(&url).await.json().await.unwrap();
        assert!(page["entries"].as_array().unwrap().is_empty());
        if page["anchorMissing"] == true {
            assert!(page["cursor"].is_null());
            break;
        }
        url = format!("{list}&cursor={}", page["cursor"].as_str().unwrap());
    }
    assert_eq!(
        f.get(&format!(
            "{list}&anchor={}",
            URL_SAFE_NO_PAD.encode("other/file.txt")
        ))
        .await
        .status(),
        400
    );
    f.finish().await;
}
