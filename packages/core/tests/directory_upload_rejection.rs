#![cfg(feature = "http")]
use localsend::http::server::{ServerHandle, start_with_port, web::WebConfig};
use localsend::http::state::ClientInfo;
use serde_json::json;
use std::{path::PathBuf, time::Duration};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::TcpStream,
    sync::oneshot,
};
const ID: &str = "11111111-1111-4111-8111-111111111111";
struct Fixture {
    server: ServerHandle,
    dir: PathBuf,
    stop: Option<oneshot::Sender<()>>,
}
impl Fixture {
    async fn new() -> Self {
        let dir =
            std::env::temp_dir().join(format!("legnasend-rejection-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir(&dir).unwrap();
        let (stop, rx) = oneshot::channel();
        let server = start_with_port(
            0,
            None,
            ClientInfo {
                alias: "Rejection fixture".into(),
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
        server.configure_directory_workspaces(&json!({"revision":1,"enabled":true,"workspaces":[{"id":ID,"name":"Disabled uploads","slug":"denied","root":dir,"generation":4,"visible":true,"allowUpload":false}]}).to_string()).await.unwrap();
        Self {
            server,
            dir,
            stop: Some(stop),
        }
    }
    fn headers(&self, length: u64) -> String {
        format!(
            "POST /api/legnasend/v1/workspaces/{ID}/upload?generation=4&path=denied.bin HTTP/1.1\r\nHost: 127.0.0.1:{}\r\nContent-Type: application/octet-stream\r\nX-LegnaSend-Upload: 1\r\nContent-Length: {length}\r\n\r\n",
            self.server.port()
        )
    }
    async fn socket(&self) -> TcpStream {
        let s = TcpStream::connect(("127.0.0.1", self.server.port()))
            .await
            .unwrap();
        s.set_nodelay(true).unwrap();
        s
    }
    fn no_transfer(&self) {
        assert_eq!(self.server.web_download_activity(), "[]");
        assert_eq!(std::fs::read_dir(&self.dir).unwrap().count(), 0);
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        if let Some(tx) = self.stop.take() {
            let _ = tx.send(());
        }
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

#[tokio::test]
async fn split_small_rejected_upload_retains_http_response_and_next_request() {
    let f = Fixture::new().await;
    for length in [3, 64 * 1024] {
        let mut socket = f.socket().await;
        socket
            .write_all(format!("{}a", f.headers(length)).as_bytes())
            .await
            .unwrap();
        // The body is deliberately not available in the dispatcher's first cheap drain.
        tokio::time::sleep(Duration::from_millis(10)).await;
        let mut tail = vec![b'b'; length as usize - 1];
        tail.extend_from_slice(
            format!(
                "GET /denied/ HTTP/1.1\r\nHost: 127.0.0.1:{}\r\nConnection: close\r\n\r\n",
                f.server.port()
            )
            .as_bytes(),
        );
        let write = socket.write_all(&tail).await;
        let mut bytes = Vec::new();
        let read =
            tokio::time::timeout(Duration::from_secs(2), socket.read_to_end(&mut bytes)).await;
        let response = String::from_utf8_lossy(&bytes);
        eprintln!(
            "split {length}-byte body write={write:?}; read={read:?}; statuses={:?}",
            response
                .split("HTTP/1.1 ")
                .skip(1)
                .map(|v| v.lines().next().unwrap())
                .collect::<Vec<_>>()
        );
        assert!(write.is_ok());
        assert!(
            matches!(read, Ok(Ok(_))),
            "incomplete HTTP response: {response}"
        );
        assert!(response.starts_with("HTTP/1.1 403"));
        assert!(
            response.contains("HTTP/1.1 200"),
            "early rejection destroyed keep-alive before the small body arrived: {response}"
        );
    }
    f.no_transfer();
}

#[tokio::test]
async fn withheld_small_or_large_rejected_body_does_not_hold_response_open() {
    let f = Fixture::new().await;
    for length in [3, 64 * 1024 * 1024] {
        let mut socket = f.socket().await;
        socket
            .write_all(f.headers(length).as_bytes())
            .await
            .unwrap();
        let mut bytes = Vec::new();
        tokio::time::timeout(Duration::from_millis(500), socket.read_to_end(&mut bytes))
            .await
            .unwrap()
            .unwrap();
        let response = String::from_utf8_lossy(&bytes);
        assert!(response.starts_with("HTTP/1.1 403"), "{response}");
        assert!(
            response.to_ascii_lowercase().contains("connection: close"),
            "unread body must not advertise reusable connection: {response}"
        );
    }
    f.no_transfer();
}

#[tokio::test]
async fn expect_chunked_and_oversized_bodies_close_without_waiting_for_the_sender() {
    let f = Fixture::new().await;
    for headers in [
        f.headers(3).replace(
            "Content-Length: 3\r\n",
            "Content-Length: 3\r\nExpect: 100-continue\r\n",
        ),
        f.headers(3)
            .replace("Content-Length: 3\r\n", "Transfer-Encoding: chunked\r\n"),
        f.headers(64 * 1024 + 1),
    ] {
        let mut socket = f.socket().await;
        socket.write_all(headers.as_bytes()).await.unwrap();
        let mut bytes = Vec::new();
        tokio::time::timeout(Duration::from_millis(500), socket.read_to_end(&mut bytes))
            .await
            .unwrap()
            .unwrap();
        let response = String::from_utf8_lossy(&bytes);
        assert!(response.starts_with("HTTP/1.1 403"), "{response}");
        assert!(!response.contains("100 Continue"));
        assert!(response.to_ascii_lowercase().contains("connection: close"));
        assert!(response.contains("Status code: 403 Forbidden"));
    }
    f.no_transfer();
}

#[tokio::test]
async fn http2_rejection_keeps_status_and_never_adds_connection_headers() {
    let f = Fixture::new().await;
    let client = reqwest::Client::builder()
        .no_proxy()
        .http2_prior_knowledge()
        .timeout(Duration::from_secs(2))
        .build()
        .unwrap();
    let response = client.post(format!("http://127.0.0.1:{}/api/legnasend/v1/workspaces/{ID}/upload?generation=4&path=denied.bin",f.server.port())).body(vec![1,2,3]).send().await.unwrap();
    assert_eq!(response.version(), reqwest::Version::HTTP_2);
    assert_eq!(response.status(), 403);
    assert!(response.headers().get("connection").is_none());
    assert!(
        response
            .text()
            .await
            .unwrap()
            .contains("Status code: 403 Forbidden")
    );
    assert_eq!(
        client
            .get(format!("http://127.0.0.1:{}/denied/", f.server.port()))
            .send()
            .await
            .unwrap()
            .status(),
        200
    );
    f.no_transfer();
}

#[tokio::test]
async fn keyed_api_unauthorized_upload_preserves_json_error_and_small_body_keepalive() {
    use localsend::http::server::integration::ApiConfig;
    let f = Fixture::new().await;
    let config = ApiConfig {
        revision: 1,
        enabled: true,
        ..Default::default()
    };
    f.server
        .configure_integration_api(&serde_json::to_string(&config).unwrap())
        .await
        .unwrap();
    let mut socket = f.socket().await;
    let headers = f.headers(3).replace(
        "/api/legnasend/v1/workspaces/",
        "/api/legnasend/v1/integration/workspaces/",
    );
    socket
        .write_all(format!("{headers}a").as_bytes())
        .await
        .unwrap();
    tokio::time::sleep(Duration::from_millis(10)).await;
    socket
        .write_all(
            format!(
                "bcGET /denied/ HTTP/1.1\r\nHost: 127.0.0.1:{}\r\nConnection: close\r\n\r\n",
                f.server.port()
            )
            .as_bytes(),
        )
        .await
        .unwrap();
    let mut bytes = Vec::new();
    tokio::time::timeout(Duration::from_secs(2), socket.read_to_end(&mut bytes))
        .await
        .unwrap()
        .unwrap();
    let response = String::from_utf8_lossy(&bytes);
    assert!(response.starts_with("HTTP/1.1 401"), "{response}");
    assert!(response.contains("unauthorized"), "{response}");
    assert!(response.contains("HTTP/1.1 200"), "{response}");
    f.no_transfer();
}

#[tokio::test]
async fn keyed_archive_and_preview_denials_preserve_small_body_and_bound_large_body_waits() {
    use localsend::http::server::integration::ApiConfig;
    let f = Fixture::new().await;
    f.server
        .configure_integration_api(
            &serde_json::to_string(&ApiConfig {
                revision: 1,
                enabled: true,
                ..Default::default()
            })
            .unwrap(),
        )
        .await
        .unwrap();
    for operation in [
        "prepare-archive",
        "cancel-archive",
        "prepare-preview",
        "close-preview",
    ] {
        let headers = f
            .headers(3)
            .replace(
                "/api/legnasend/v1/workspaces/",
                "/api/legnasend/v1/integration/workspaces/",
            )
            .replace("/upload?", &format!("/{operation}?"));
        let mut socket = f.socket().await;
        socket
            .write_all(format!("{headers}a").as_bytes())
            .await
            .unwrap();
        tokio::time::sleep(Duration::from_millis(10)).await;
        socket
            .write_all(
                format!(
                    "bcGET /denied/ HTTP/1.1\r\nHost: 127.0.0.1:{}\r\nConnection: close\r\n\r\n",
                    f.server.port()
                )
                .as_bytes(),
            )
            .await
            .unwrap();
        let mut bytes = Vec::new();
        tokio::time::timeout(Duration::from_secs(2), socket.read_to_end(&mut bytes))
            .await
            .unwrap()
            .unwrap();
        let response = String::from_utf8_lossy(&bytes);
        assert!(
            response.starts_with("HTTP/1.1 401"),
            "{operation}: {response}"
        );
        assert!(response.contains("unauthorized"), "{operation}: {response}");
        assert!(response.contains("HTTP/1.1 200"), "{operation}: {response}");
    }
    f.no_transfer();
    // Authentication rejection budgets are independent from request-body
    // finishing. Use a fresh listener so the four small-body probes do not
    // turn this separate large-body assertion into a rate-limit assertion.
    let f = Fixture::new().await;
    f.server
        .configure_integration_api(
            &serde_json::to_string(&ApiConfig {
                revision: 1,
                enabled: true,
                ..Default::default()
            })
            .unwrap(),
        )
        .await
        .unwrap();
    let headers = f
        .headers(2 * 1024 * 1024)
        .replace(
            "/api/legnasend/v1/workspaces/",
            "/api/legnasend/v1/integration/workspaces/",
        )
        .replace("/upload?", "/prepare-archive?");
    let mut socket = f.socket().await;
    socket.write_all(headers.as_bytes()).await.unwrap();
    let mut bytes = Vec::new();
    tokio::time::timeout(Duration::from_millis(500), socket.read_to_end(&mut bytes))
        .await
        .unwrap()
        .unwrap();
    let response = String::from_utf8_lossy(&bytes).to_ascii_lowercase();
    assert!(response.starts_with("http/1.1 401"));
    assert!(response.contains("connection: close"));
    let client = reqwest::Client::builder()
        .no_proxy()
        .http2_prior_knowledge()
        .timeout(Duration::from_secs(2))
        .build()
        .unwrap();
    let response=client.post(format!("http://127.0.0.1:{}/api/legnasend/v1/integration/workspaces/{ID}/prepare-archive?generation=4",f.server.port())).body("abc").send().await.unwrap();
    assert_eq!(response.version(), reqwest::Version::HTTP_2);
    assert_eq!(response.status(), 401);
    assert!(response.headers().get("connection").is_none());
    f.no_transfer();
}
