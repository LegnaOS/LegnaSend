#![cfg(feature = "http")]
use futures_util::StreamExt;
use localsend::http::{
    server::{start_with_port, web::WebConfig, ServerHandle},
    state::ClientInfo,
};
use serde_json::json;
use std::{path::PathBuf, time::Duration};
use tokio::sync::oneshot;
const ID: &str = "11111111-1111-4111-8111-111111111111";
struct Fixture {
    server: ServerHandle,
    client: reqwest::Client,
    root: PathBuf,
    stop: Option<oneshot::Sender<()>>,
}
impl Fixture {
    async fn new() -> Self {
        let root = std::env::temp_dir().join(format!("legnasend-events-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(root.join("sub")).unwrap();
        let (stop, rx) = oneshot::channel();
        let server = start_with_port(
            0,
            None,
            ClientInfo {
                alias: "events".into(),
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
        let f = Self {
            server,
            client: reqwest::Client::builder().no_proxy().build().unwrap(),
            root,
            stop: Some(stop),
        };
        f.configure(1, 1, true, None).await;
        f
    }
    async fn configure(
        &self,
        revision: u64,
        generation: u64,
        enabled: bool,
        password: Option<&str>,
    ) {
        self.server.configure_directory_workspaces(&json!({"revision":revision,"enabled":true,"workspaces":if enabled{vec![json!({"id":ID,"name":"Events","slug":"events","root":self.root,"generation":generation,"visible":true,"passwordHash":password})]}else{vec![]}}).to_string()).await.unwrap();
    }
    fn url(&self, query: &str) -> String {
        format!(
            "http://127.0.0.1:{}/api/legnasend/v1/workspaces/{ID}/events?{query}",
            self.server.port()
        )
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
async fn real_filesystem_changes_invalidate_without_exposing_names_and_generation_closes() {
    let f = Fixture::new().await;
    let response = f
        .client
        .get(f.url("generation=1&path=sub"))
        .send()
        .await
        .unwrap();
    assert_eq!(response.status(), 200);
    assert_eq!(response.headers()["content-type"], "text/event-stream");
    let mut stream = response.bytes_stream();
    let ready = tokio::time::timeout(Duration::from_secs(5), stream.next())
        .await
        .unwrap()
        .unwrap()
        .unwrap();
    assert!(String::from_utf8_lossy(&ready).contains("event: ready"));
    std::fs::write(f.root.join("sub/secret-name.txt"), b"private bytes").unwrap();
    let changed = tokio::time::timeout(Duration::from_secs(8), stream.next())
        .await
        .unwrap()
        .unwrap()
        .unwrap();
    let changed = String::from_utf8_lossy(&changed);
    assert!(changed.contains("event: invalidate"));
    assert!(!changed.contains("secret-name"));
    assert!(!changed.contains("private bytes"));
    f.configure(2, 2, true, None).await;
    let ended = tokio::time::timeout(Duration::from_secs(3), stream.next())
        .await
        .unwrap();
    assert!(ended.is_none() || ended.unwrap().is_err());
    assert_eq!(
        f.client
            .get(f.url("generation=1"))
            .send()
            .await
            .unwrap()
            .status(),
        409
    );
}
#[tokio::test]
async fn events_require_workspace_password_and_reject_traversal_unknown_fields() {
    let f = Fixture::new().await;
    for query in [
        "generation=1&path=..",
        "generation=1&path=.legnasend-private",
        "generation=1&unknown=x",
    ] {
        assert_eq!(
            f.client.get(f.url(query)).send().await.unwrap().status(),
            400
        );
    }
    let salt = base64::Engine::encode(&base64::engine::general_purpose::URL_SAFE_NO_PAD, [1u8; 16]);
    let hash = base64::Engine::encode(&base64::engine::general_purpose::URL_SAFE_NO_PAD, [2u8; 32]);
    let verifier = format!("pbkdf2-sha256$600000${salt}${hash}");
    f.configure(2, 2, true, Some(&verifier)).await;
    assert_eq!(
        f.client
            .get(f.url("generation=2"))
            .send()
            .await
            .unwrap()
            .status(),
        401
    );
}
#[tokio::test]
async fn active_watchers_are_bounded_and_dropping_responses_restores_capacity() {
    let f = Fixture::new().await;
    let mut held = Vec::new();
    for _ in 0..4 {
        let mut r = f.client.get(f.url("generation=1")).send().await.unwrap();
        assert_eq!(r.status(), 200);
        assert!(r.chunk().await.unwrap().is_some());
        held.push(r);
    }
    assert_eq!(
        f.client
            .get(f.url("generation=1"))
            .send()
            .await
            .unwrap()
            .status(),
        429
    );
    drop(held);
    tokio::time::timeout(Duration::from_secs(5), async {
        loop {
            let r = f.client.get(f.url("generation=1")).send().await.unwrap();
            if r.status() == 200 {
                break;
            }
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
    })
    .await
    .unwrap();
    f.configure(2, 2, false, None).await;
    assert_eq!(
        f.client
            .get(f.url("generation=2"))
            .send()
            .await
            .unwrap()
            .status(),
        404
    );
}
#[tokio::test]
async fn authenticated_stream_is_revoked_by_logout_without_disclosing_events() {
    let f = Fixture::new().await;
    let verifier = localsend::http::server::directory_auth::hash_password("1234".into())
        .await
        .unwrap();
    f.configure(2, 2, true, Some(&verifier)).await;
    let base = format!(
        "http://127.0.0.1:{}/api/legnasend/v1/workspaces/{ID}",
        f.server.port()
    );
    let login = f
        .client
        .post(format!("{base}/unlock"))
        .json(&json!({"generation":2,"password":"1234"}))
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
    let response = f
        .client
        .get(f.url("generation=2"))
        .header("cookie", &cookie)
        .send()
        .await
        .unwrap();
    assert_eq!(response.status(), 200);
    let mut stream = response.bytes_stream();
    assert!(stream.next().await.unwrap().is_ok());
    let logout = f
        .client
        .post(format!("{base}/logout"))
        .header("cookie", &cookie)
        .json(&json!({}))
        .send()
        .await
        .unwrap();
    assert_eq!(logout.status(), 200);
    let ended = tokio::time::timeout(Duration::from_secs(3), stream.next())
        .await
        .unwrap();
    assert!(ended.is_none() || ended.unwrap().is_err());
    assert_eq!(
        f.client
            .get(f.url("generation=2"))
            .header("cookie", &cookie)
            .send()
            .await
            .unwrap()
            .status(),
        401
    );
}
