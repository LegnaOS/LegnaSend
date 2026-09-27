#![cfg(feature = "http")]
//! Independent HTTP and filesystem adversarial coverage for opt-in directory uploads.
use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine};
use localsend::http::server::{start_with_port, web::WebConfig, ServerHandle};
use localsend::http::state::ClientInfo;
use serde_json::{json, Value};
use std::{path::PathBuf, time::Duration};
use tokio::{io::AsyncWriteExt, net::TcpStream, sync::oneshot};

const ID: &str = "11111111-1111-4111-8111-111111111111";
struct Fixture {
    server: ServerHandle,
    client: reqwest::Client,
    temp: PathBuf,
    stop: Option<oneshot::Sender<()>>,
}
impl Fixture {
    async fn new() -> Self {
        let temp = std::env::temp_dir().join(format!(
            "legnasend-upload-adversarial-{}",
            uuid::Uuid::new_v4()
        ));
        std::fs::create_dir_all(temp.join("root")).unwrap();
        let (stop, rx) = oneshot::channel();
        let server = start_with_port(
            0,
            None,
            ClientInfo {
                alias: "upload-adversarial".into(),
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
        let client = reqwest::Client::builder()
            .no_proxy()
            .timeout(Duration::from_secs(10))
            .build()
            .unwrap();
        Self {
            server,
            client,
            temp,
            stop: Some(stop),
        }
    }
    fn config(&self, generation: u64, allow: bool) -> Value {
        json!({"id":ID,"name":"Uploads","slug":"uploads","root":self.temp.join("root"),"generation":generation,"visible":true,"allowUpload":allow})
    }
    async fn configure(&self, revision: u64, config: Option<Value>) {
        self.server.configure_directory_workspaces(&json!({"revision":revision,"enabled":true,"workspaces":config.into_iter().collect::<Vec<_>>()}).to_string()).await.unwrap();
    }
    fn base(&self) -> String {
        format!("http://127.0.0.1:{}", self.server.port())
    }
    fn endpoint(&self, path: &str, generation: u64) -> String {
        let query = form_urlencoded::Serializer::new(String::new())
            .append_pair("generation", &generation.to_string())
            .append_pair("path", path)
            .finish();
        format!(
            "{}/api/legnasend/v1/workspaces/{ID}/upload?{query}",
            self.base()
        )
    }
    fn post(&self, path: &str, generation: u64, bytes: &[u8]) -> reqwest::RequestBuilder {
        self.client
            .post(self.endpoint(path, generation))
            .header("X-LegnaSend-Upload", "1")
            .header("Content-Type", "application/octet-stream")
            .header("Content-Length", bytes.len())
            .body(bytes.to_vec())
    }
    async fn login(&self, password: &str, generation: u64) -> String {
        let response = self
            .client
            .post(format!(
                "{}/api/legnasend/v1/workspaces/{ID}/unlock",
                self.base()
            ))
            .json(&json!({"password":password,"generation":generation}))
            .send()
            .await
            .unwrap();
        assert_eq!(response.status(), 200);
        response.headers()["set-cookie"]
            .to_str()
            .unwrap()
            .split(';')
            .next()
            .unwrap()
            .to_owned()
    }
    async fn partial(&self, path: &str, cookie: Option<&str>) -> TcpStream {
        let url = reqwest::Url::parse(&self.endpoint(path, 1)).unwrap();
        let mut socket = TcpStream::connect(("127.0.0.1", self.server.port()))
            .await
            .unwrap();
        let cookie = cookie
            .map(|s| format!("Cookie: {s}\r\n"))
            .unwrap_or_default();
        socket.write_all(format!("POST {}?{} HTTP/1.1\r\nHost: 127.0.0.1:{}\r\nX-LegnaSend-Upload: 1\r\nContent-Type: application/octet-stream\r\nContent-Length: 1048576\r\n{cookie}\r\npartial", url.path(), url.query().unwrap(), self.server.port()).as_bytes()).await.unwrap();
        socket
    }
    async fn wait_staging(&self) {
        for _ in 0..100 {
            if all_files(&self.temp.join("root")).iter().any(|p| {
                p.file_name()
                    .unwrap()
                    .to_string_lossy()
                    .starts_with(".legnasend")
            }) {
                return;
            }
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
        panic!("Upload did not create its owned staging file");
    }
    async fn wait_clean(&self) {
        for _ in 0..100 {
            if all_files(&self.temp.join("root")).is_empty() {
                return;
            }
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
        panic!(
            "Unexpected partial or published files: {:?}",
            all_files(&self.temp.join("root"))
        );
    }
    async fn finish(mut self) {
        let _ = self.stop.take().unwrap().send(());
        self.server.wait_stopped().await;
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
fn all_files(root: &std::path::Path) -> Vec<PathBuf> {
    let mut files = Vec::new();
    let entries = match std::fs::read_dir(root) {
        Ok(entries) => entries,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return files,
        Err(error) => panic!("Failed to inspect fixture directory: {error}"),
    };
    for entry in entries {
        let path = entry.unwrap().path();
        if path.is_dir() && !path.is_symlink() {
            files.extend(all_files(&path));
        } else {
            files.push(path);
        }
    }
    files
}

#[tokio::test]
async fn default_read_only_missing_or_stale_generation_and_cross_site_never_write() {
    let f = Fixture::new().await;
    let mut config = f.config(1, false);
    config.as_object_mut().unwrap().remove("allowUpload");
    f.configure(1, Some(config)).await;
    assert_eq!(
        f.post("file.txt", 1, b"body")
            .send()
            .await
            .unwrap()
            .status(),
        403
    );
    f.configure(2, Some(f.config(2, true))).await;
    assert_eq!(
        f.post("file.txt", 1, b"body")
            .send()
            .await
            .unwrap()
            .status(),
        409
    );
    let url = f.endpoint("file.txt", 2).replace("generation=2&", "");
    assert_eq!(
        f.client
            .post(url)
            .header("X-LegnaSend-Upload", "1")
            .header("Content-Type", "application/octet-stream")
            .body("body")
            .send()
            .await
            .unwrap()
            .status(),
        400
    );
    assert_eq!(
        f.post("file.txt", 2, b"body")
            .header("Origin", "https://attacker.invalid")
            .send()
            .await
            .unwrap()
            .status(),
        403
    );
    assert_eq!(
        f.post("file.txt", 2, b"body")
            .header("Sec-Fetch-Site", "cross-site")
            .send()
            .await
            .unwrap()
            .status(),
        403
    );
    assert!(!f
        .client
        .post(f.endpoint("file.txt", 2))
        .header("Content-Type", "application/octet-stream")
        .body("body")
        .send()
        .await
        .unwrap()
        .status()
        .is_success());
    assert!(all_files(&f.temp.join("root")).is_empty());
    f.finish().await;
}

#[tokio::test]
async fn malformed_requests_and_nonempty_directory_bodies_never_publish() {
    let f = Fixture::new().await;
    f.configure(1, Some(f.config(1, true))).await;
    assert!(!f
        .client
        .post(f.endpoint("bad-type.txt", 1))
        .header("X-LegnaSend-Upload", "1")
        .header("Content-Type", "text/plain")
        .body("body")
        .send()
        .await
        .unwrap()
        .status()
        .is_success());
    assert!(!f
        .client
        .post(f.endpoint("wrong-marker.txt", 1))
        .header("Content-Type", "application/octet-stream")
        .header("X-LegnaSend-Upload", "0")
        .body("body")
        .send()
        .await
        .unwrap()
        .status()
        .is_success());
    assert!(!f
        .client
        .post(format!("{}&directory=true", f.endpoint("folder", 1)))
        .header("X-LegnaSend-Upload", "1")
        .header("Content-Type", "application/octet-stream")
        .body("not empty")
        .send()
        .await
        .unwrap()
        .status()
        .is_success());
    assert!(!f
        .client
        .post(format!("{}&path=second.txt", f.endpoint("first.txt", 1)))
        .header("X-LegnaSend-Upload", "1")
        .header("Content-Type", "application/octet-stream")
        .body("body")
        .send()
        .await
        .unwrap()
        .status()
        .is_success());
    assert!(std::fs::read_dir(f.temp.join("root"))
        .unwrap()
        .next()
        .is_none());
    f.finish().await;
}

#[tokio::test]
async fn password_required_and_logout_revokes_active_and_future_uploads() {
    let f = Fixture::new().await;
    let mut config = f.config(1, true);
    config["passwordHash"] = json!(localsend::http::server::directory_auth::hash_password(
        "fixture-password".into()
    )
    .await
    .unwrap());
    f.configure(1, Some(config)).await;
    assert_eq!(
        f.post("file.txt", 1, b"body")
            .send()
            .await
            .unwrap()
            .status(),
        401
    );
    let cookie = f.login("fixture-password", 1).await;
    let socket = f.partial("incomplete.txt", Some(&cookie)).await;
    f.wait_staging().await;
    assert_eq!(
        f.client
            .post(format!(
                "{}/api/legnasend/v1/workspaces/{ID}/logout",
                f.base()
            ))
            .header("Cookie", &cookie)
            .json(&json!({}))
            .send()
            .await
            .unwrap()
            .status(),
        200
    );
    f.wait_clean().await;
    drop(socket);
    assert_eq!(
        f.post("file.txt", 1, b"body")
            .header("Cookie", cookie)
            .send()
            .await
            .unwrap()
            .status(),
        401
    );
    f.finish().await;
}

#[tokio::test]
async fn traversal_reserved_names_hidden_caches_and_encoded_slashes_stay_confined() {
    let f = Fixture::new().await;
    f.configure(1, Some(f.config(1, true))).await;
    for path in [
        "../escape",
        "/absolute",
        "nested/../../escape",
        "back\\slash",
        "drive:C",
        "a\0b",
        ".legnasend-private",
        "nested/cache.LS",
        "CON.txt",
        "trailing.",
        "double//slash",
    ] {
        let response = f.post(path, 1, b"bad").send().await.unwrap();
        assert!(!response.status().is_success(), "accepted {path:?}");
    }
    for raw in [
        "..%2Fescape",
        "%2Fabsolute",
        "a%2F..%2Fescape",
        "%2e%2e%5cescape",
    ] {
        let response = f
            .client
            .post(format!(
                "{}/api/legnasend/v1/workspaces/{ID}/upload?generation=1&path={raw}",
                f.base()
            ))
            .header("X-LegnaSend-Upload", "1")
            .header("Content-Type", "application/octet-stream")
            .body("bad")
            .send()
            .await
            .unwrap();
        assert!(!response.status().is_success(), "accepted raw {raw}");
    }
    for path in ["x".repeat(256), "界".repeat(86), vec!["a"; 65].join("/")] {
        assert!(!f
            .post(&path, 1, b"bad")
            .send()
            .await
            .unwrap()
            .status()
            .is_success());
    }
    assert!(all_files(&f.temp.join("root")).is_empty());
    assert!(
        std::fs::read_dir(f.temp.join("root"))
            .unwrap()
            .next()
            .is_none(),
        "Invalid paths must not create partial parent directories"
    );
    // Literal percent sequences must not be decoded a second time into traversal.
    let literal = "%2e%2e%2fescape.txt";
    assert!(f
        .post(literal, 1, b"literal")
        .send()
        .await
        .unwrap()
        .status()
        .is_success());
    assert_eq!(
        std::fs::read(f.temp.join("root").join(literal)).unwrap(),
        b"literal"
    );
    assert!(!f.temp.join("escape.txt").exists());
    f.finish().await;
}

#[tokio::test]
async fn disconnected_partial_body_has_no_final_file_and_staging_is_not_listed() {
    let f = Fixture::new().await;
    f.configure(1, Some(f.config(1, true))).await;
    let socket = f.partial("nested/unfinished.txt", None).await;
    f.wait_staging().await;
    let page: Value = f
        .client
        .get(format!(
            "{}/api/legnasend/v1/workspaces/{ID}/files?generation=1&path=nested",
            f.base()
        ))
        .send()
        .await
        .unwrap()
        .json()
        .await
        .unwrap();
    assert!(!page.to_string().contains(".legnasend"));
    for staging in all_files(&f.temp.join("root")) {
        let relative = staging
            .strip_prefix(f.temp.join("root"))
            .unwrap()
            .to_str()
            .unwrap();
        let response = f
            .client
            .get(format!(
                "{}/api/legnasend/v1/workspaces/{ID}/files/{}/content?generation=1",
                f.base(),
                URL_SAFE_NO_PAD.encode(relative)
            ))
            .send()
            .await
            .unwrap();
        assert!(
            !response.status().is_success(),
            "Managed upload bytes must not be directly downloadable"
        );
    }
    assert!(!f.temp.join("root/nested/unfinished.txt").exists());
    drop(socket);
    f.wait_clean().await;
    f.finish().await;
}

#[tokio::test]
async fn disabling_or_removing_workspace_revokes_inflight_upload_without_publication() {
    for remove in [false, true] {
        let f = Fixture::new().await;
        f.configure(1, Some(f.config(1, true))).await;
        let socket = f.partial("pending.txt", None).await;
        f.wait_staging().await;
        f.configure(
            2,
            if remove {
                None
            } else {
                Some(f.config(2, false))
            },
        )
        .await;
        f.wait_clean().await;
        drop(socket);
        assert!(!f
            .post("late.txt", 1, b"late")
            .send()
            .await
            .unwrap()
            .status()
            .is_success());
        f.finish().await;
    }
}

#[tokio::test]
async fn replaced_parent_before_publication_never_receives_new_content() {
    let f = Fixture::new().await;
    f.configure(1, Some(f.config(1, true))).await;
    let url = reqwest::Url::parse(&f.endpoint("nested/final.txt", 1)).unwrap();
    let mut socket = TcpStream::connect(("127.0.0.1", f.server.port()))
        .await
        .unwrap();
    socket.write_all(format!("POST {}?{} HTTP/1.1\r\nHost: 127.0.0.1:{}\r\nX-LegnaSend-Upload: 1\r\nContent-Type: application/octet-stream\r\nContent-Length: 8\r\n\r\n1234", url.path(), url.query().unwrap(), f.server.port()).as_bytes()).await.unwrap();
    f.wait_staging().await;
    std::fs::rename(f.temp.join("root/nested"), f.temp.join("root/old-parent")).unwrap();
    std::fs::create_dir(f.temp.join("root/nested")).unwrap();
    std::fs::write(f.temp.join("root/nested/user.txt"), b"preserve").unwrap();
    socket.write_all(b"5678").await.unwrap();
    for _ in 0..100 {
        if all_files(&f.temp.join("root/old-parent")).is_empty() {
            break;
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    assert!(all_files(&f.temp.join("root/old-parent")).is_empty());
    assert!(!f.temp.join("root/nested/final.txt").exists());
    assert_eq!(
        std::fs::read(f.temp.join("root/nested/user.txt")).unwrap(),
        b"preserve"
    );
    drop(socket);
    f.finish().await;
}

#[tokio::test]
async fn concurrent_conflicts_never_overwrite_a_file_or_directory() {
    let f = Fixture::new().await;
    f.configure(1, Some(f.config(1, true))).await;
    std::fs::write(f.temp.join("root/existing.txt"), b"original").unwrap();
    std::fs::create_dir(f.temp.join("root/existing-directory")).unwrap();
    for path in [
        "existing.txt",
        "existing-directory",
        "existing.txt/nested.txt",
    ] {
        assert!(!f
            .post(path, 1, b"replacement")
            .send()
            .await
            .unwrap()
            .status()
            .is_success());
    }
    assert_eq!(
        std::fs::read(f.temp.join("root/existing.txt")).unwrap(),
        b"original"
    );
    let (one, two) = tokio::join!(
        f.post("race.txt", 1, b"first").send(),
        f.post("race.txt", 1, b"second").send()
    );
    let one = one.unwrap();
    let two = two.unwrap();
    assert!(one.status().is_success() ^ two.status().is_success());
    assert_eq!(
        if one.status().is_success() {
            two.status()
        } else {
            one.status()
        },
        409
    );
    let bytes = std::fs::read(f.temp.join("root/race.txt")).unwrap();
    assert!(bytes == b"first" || bytes == b"second");
    assert!(!all_files(&f.temp.join("root")).iter().any(|p| p
        .file_name()
        .unwrap()
        .to_string_lossy()
        .starts_with(".legnasend")));
    f.finish().await;
}

#[cfg(unix)]
#[tokio::test]
async fn symlink_parents_and_final_symlinks_never_modify_outside_files() {
    let f = Fixture::new().await;
    f.configure(1, Some(f.config(1, true))).await;
    std::fs::create_dir(f.temp.join("outside")).unwrap();
    std::fs::write(f.temp.join("outside/keep.txt"), b"original").unwrap();
    std::os::unix::fs::symlink(f.temp.join("outside"), f.temp.join("root/link")).unwrap();
    std::os::unix::fs::symlink(
        f.temp.join("outside/keep.txt"),
        f.temp.join("root/final.txt"),
    )
    .unwrap();
    for path in ["link/new.txt", "link/keep.txt", "final.txt"] {
        assert!(!f
            .post(path, 1, b"replacement")
            .send()
            .await
            .unwrap()
            .status()
            .is_success());
    }
    assert!(!f.temp.join("outside/new.txt").exists());
    assert_eq!(
        std::fs::read(f.temp.join("outside/keep.txt")).unwrap(),
        b"original"
    );
    f.finish().await;
}
