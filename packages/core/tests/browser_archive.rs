#![cfg(feature = "http")]
use bytes::Bytes;
use localsend::http::server::{
    start_with_port,
    web::{WebConfig, WebDownloadConfig, WebDownloadEvent, WebMode},
    ServerHandle,
};
use localsend::http::state::ClientInfo;
use localsend::model::transfer::{FileContent, FileDto};
use serde_json::json;
use std::{
    collections::HashMap,
    path::PathBuf,
    sync::{
        atomic::{AtomicUsize, Ordering},
        Arc,
    },
    time::Duration,
};
use tokio::sync::{mpsc, oneshot};

fn zip_files(bytes: &[u8]) -> HashMap<String, Vec<u8>> {
    fn u16(b: &[u8], i: usize) -> usize {
        u16::from_le_bytes(b[i..i + 2].try_into().unwrap()) as usize
    }
    fn u32(b: &[u8], i: usize) -> u32 {
        u32::from_le_bytes(b[i..i + 4].try_into().unwrap())
    }
    fn u64(b: &[u8], i: usize) -> u64 {
        u64::from_le_bytes(b[i..i + 8].try_into().unwrap())
    }
    let mut offset = 0;
    let mut result = HashMap::new();
    let mut starts = HashMap::new();
    while u32(bytes, offset) == 0x04034b50 {
        let n = u16(bytes, offset + 26);
        let extra = u16(bytes, offset + 28);
        assert_eq!(u16(bytes, offset + 8), 0);
        assert_eq!(u16(bytes, offset + 6), 0x808);
        let name = String::from_utf8(bytes[offset + 30..offset + 30 + n].to_vec()).unwrap();
        let size = u64(bytes, offset + 30 + n + 4) as usize;
        starts.insert(name.clone(), offset as u64);
        offset += 30 + n + extra;
        let content = bytes[offset..offset + size].to_vec();
        offset += size;
        assert_eq!(u32(bytes, offset), 0x08074b50);
        assert_eq!(u32(bytes, offset + 4), crc32fast::hash(&content));
        assert_eq!(u64(bytes, offset + 8), size as u64);
        assert_eq!(u64(bytes, offset + 16), size as u64);
        offset += 24;
        assert!(result.insert(name, content).is_none());
    }
    let central_start = offset;
    let mut count = 0;
    while u32(bytes, offset) == 0x02014b50 {
        let n = u16(bytes, offset + 28);
        let extra = u16(bytes, offset + 30);
        let name = String::from_utf8(bytes[offset + 46..offset + 46 + n].to_vec()).unwrap();
        assert_eq!(u32(bytes, offset + 16), crc32fast::hash(&result[&name]));
        assert_eq!(u64(bytes, offset + 46 + n + 20), starts[&name]);
        offset += 46 + n + extra;
        count += 1;
    }
    assert_eq!(count, result.len());
    assert_eq!(u32(bytes, offset), 0x06064b50);
    assert_eq!(u64(bytes, offset + 32), count as u64);
    assert_eq!(u64(bytes, offset + 40), (offset - central_start) as u64);
    assert_eq!(u64(bytes, offset + 48), central_start as u64);
    assert_eq!(u32(bytes, offset + 56), 0x07064b50);
    assert_eq!(u32(bytes, offset + 76), 0x06054b50);
    assert_eq!(offset + 98, bytes.len());
    result
}
struct Fixture {
    handle: ServerHandle,
    url: String,
    client: reqwest::Client,
    temp: PathBuf,
    stop: Option<oneshot::Sender<()>>,
    reads: Arc<AtomicUsize>,
}
impl Fixture {
    async fn new(count: usize) -> Self {
        let temp = std::env::temp_dir().join(format!("legnasend-batch-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(temp.join("nested/empty")).unwrap();
        std::fs::write(temp.join("nested/中文 %.txt"), b"unicode content").unwrap();
        std::fs::write(temp.join("private.ls"), b"cache").unwrap();
        #[cfg(unix)]
        std::os::unix::fs::symlink("/etc", temp.join("escape")).unwrap();
        let (tx, mut rx) = mpsc::channel(16);
        let reads = Arc::new(AtomicUsize::new(0));
        let observed = reads.clone();
        tokio::spawn(async move {
            while let Some(event) = rx.recv().await {
                match event {
                    WebDownloadEvent::PrepareDownloadAborted { .. } => {},
                    WebDownloadEvent::PrepareDownload { decision_tx, .. } => {
                        let _ = decision_tx.send(true);
                    }
                    WebDownloadEvent::FileDownload {
                        file_id,
                        content_tx,
                        ..
                    } => {
                        observed.fetch_add(1, Ordering::SeqCst);
                        let (tx, rx) = mpsc::channel(2);
                        let _ = content_tx.send(FileContent::Stream(rx));
                        if file_id == "stall" {
                            tokio::spawn(async move {
                                tx.closed().await;
                            });
                        } else {
                            let content = if file_id == "short" {
                                Bytes::from_static(b"x")
                            } else {
                                Bytes::from(format!("contents:{file_id}"))
                            };
                            let _ = tx.send(content).await;
                        }
                    }
                }
            }
        });
        let files = (0..count)
            .map(|i| {
                let id = i.to_string();
                let content = format!("contents:{id}");
                (
                    id.clone(),
                    FileDto {
                        id,
                        file_name: format!("folder-{}/子目录/{i}.txt", i % 20),
                        size: content.len() as u64,
                        file_type: "text/plain".into(),
                        sha256: None,
                        preview: None,
                        metadata: None,
                    },
                )
            })
            .collect();
        let (stop, rx) = oneshot::channel();
        let handle = start_with_port(
            0,
            None,
            ClientInfo {
                alias: "batch".into(),
                version: "2.2".into(),
                device_model: None,
                device_type: None,
                token: "test".into(),
            },
            None,
            None,
            WebConfig {
                mode: WebMode::Duplex {
                    download: WebDownloadConfig {
                        files,
                        pin: Some("1234".into()),
                        event_tx: tx,
                    },
                    allow_upload: false,
                },
                ..Default::default()
            },
            rx,
        )
        .await
        .unwrap();
        let url = format!("http://127.0.0.1:{}", handle.port());
        let client = reqwest::Client::builder()
            .no_proxy()
            .timeout(Duration::from_secs(60))
            .build()
            .unwrap();
        Self {
            handle,
            url,
            client,
            temp,
            stop: Some(stop),
            reads,
        }
    }
    async fn session(&self) -> String {
        self.client
            .post(format!(
                "{}/api/localsend/v2/prepare-download?pin=1234",
                self.url
            ))
            .send()
            .await
            .unwrap()
            .json::<serde_json::Value>()
            .await
            .unwrap()["sessionId"]
            .as_str()
            .unwrap()
            .into()
    }
    async fn configure(&self, revision: u64, password: Option<String>, active: bool) {
        let entry = json!({"id":"11111111-1111-4111-8111-111111111111","name":"Folder","slug":"folder","root":self.temp,"generation":revision,"visible":false,"passwordHash":password});
        self.handle.configure_directory_workspaces(&json!({"revision":revision,"enabled":true,"workspaces":if active{vec![entry]}else{vec![]}}).to_string()).await.unwrap();
    }
    async fn stop(mut self) {
        let _ = self.stop.take().unwrap().send(());
        self.handle.wait_stopped().await;
        std::fs::remove_dir_all(&self.temp).unwrap();
    }
}

#[tokio::test(flavor = "multi_thread")]
async fn browser_batch_and_folder_archives_preserve_original_bytes_and_authorization() {
    let f = Fixture::new(5000).await;
    let endpoint = format!("{}/api/legnasend/v1/web/archive", f.url);
    let session = f.session().await;
    assert_eq!(f.client.get(&endpoint).send().await.unwrap().status(), 400);
    assert_eq!(
        f.client
            .get(format!("{endpoint}?sessionId=wrong"))
            .send()
            .await
            .unwrap()
            .status(),
        403
    );
    let head = f
        .client
        .head(format!("{endpoint}?sessionId={session}"))
        .send()
        .await
        .unwrap();
    assert_eq!(head.status(), 200);
    let expected_len = head.headers()["content-length"]
        .to_str()
        .unwrap()
        .parse::<usize>()
        .unwrap();
    assert_eq!(f.reads.load(Ordering::SeqCst), 0);
    let all = f
        .client
        .get(format!("{endpoint}?sessionId={session}"))
        .send()
        .await
        .unwrap();
    assert_eq!(all.headers()["accept-ranges"], "none");
    let bytes = all.bytes().await.unwrap();
    assert_eq!(bytes.len(), expected_len);
    let files = zip_files(&bytes);
    assert_eq!(files.len(), 5000);
    for i in 0..5000 {
        assert_eq!(
            files[&format!("folder-{}/子目录/{i}.txt", i % 20)],
            format!("contents:{i}").as_bytes()
        );
    }
    if let Ok(root) = std::env::var("LEGNASEND_ARCHIVE_EVIDENCE") {
        std::fs::create_dir_all(&root).unwrap();
        std::fs::write(PathBuf::from(root).join("5000-files.zip"), &bytes).unwrap();
    }
    let form = format!("sessionId={session}&fileId=1&fileId=4999");
    let selected = f
        .client
        .post(&endpoint)
        .header("content-type", "application/x-www-form-urlencoded")
        .body(form.clone())
        .send()
        .await
        .unwrap();
    assert_eq!(selected.status(), 200);
    assert_eq!(zip_files(&selected.bytes().await.unwrap()).len(), 2);
    let preflight = f
        .client
        .post(format!("{endpoint}?check=1"))
        .header("content-type", "application/x-www-form-urlencoded")
        .body(form.clone())
        .send()
        .await
        .unwrap();
    assert_eq!(
        preflight.json::<serde_json::Value>().await.unwrap()["entries"],
        2
    );
    // A browser prepares a bounded selection with POST, then downloads with a
    // short GET link. No document POST, archive Blob, or long query is needed.
    let prepared = f
        .client
        .post(format!("{endpoint}?prepare=1"))
        .header("content-type", "application/x-www-form-urlencoded")
        .body(form.clone())
        .send()
        .await
        .unwrap();
    assert_eq!(prepared.headers()["cache-control"], "no-store");
    let prepared = prepared.json::<serde_json::Value>().await.unwrap();
    assert_eq!(prepared["entries"], 2);
    let short = prepared["downloadUrl"].as_str().unwrap();
    assert!(short.len() < 200);
    let prepared_url = format!("{}{short}", f.url);
    let before = f.reads.load(Ordering::SeqCst);
    assert_eq!(
        f.client.head(&prepared_url).send().await.unwrap().status(),
        200
    );
    assert_eq!(f.reads.load(Ordering::SeqCst), before);
    for _ in 0..2 {
        let response = f.client.get(&prepared_url).send().await.unwrap();
        assert_eq!(response.status(), 200);
        let content = zip_files(&response.bytes().await.unwrap());
        assert_eq!(content.len(), 2);
        assert_eq!(content["folder-1/子目录/1.txt"], b"contents:1");
        assert_eq!(content["folder-19/子目录/4999.txt"], b"contents:4999");
    }
    let other_session = f.session().await;
    assert_eq!(
        f.client
            .get(prepared_url.replace(&session, &other_session))
            .send()
            .await
            .unwrap()
            .status(),
        410
    );
    for extra in ["&fileId=3", "&prefix=folder-1%2F", "&selection=extra"] {
        assert_eq!(
            f.client
                .get(format!("{prepared_url}{extra}"))
                .send()
                .await
                .unwrap()
                .status(),
            400
        );
    }
    assert_eq!(
        f.client
            .post(&endpoint)
            .header("content-type", "application/x-www-form-urlencoded")
            .body(prepared_url.split('?').nth(1).unwrap().to_string())
            .send()
            .await
            .unwrap()
            .status(),
        400
    );
    // More selected IDs than a valid GET query can hold, still a short link.
    let large = format!(
        "sessionId={session}{}",
        (0..5000)
            .map(|id| format!("&fileId={id}"))
            .collect::<String>()
    );
    assert!(large.len() > 8192);
    let prepared = f
        .client
        .post(format!("{endpoint}?prepare=1"))
        .header("content-type", "application/x-www-form-urlencoded")
        .body(large)
        .send()
        .await
        .unwrap()
        .json::<serde_json::Value>()
        .await
        .unwrap();
    assert_eq!(prepared["entries"], 5000);
    let response = f
        .client
        .get(format!(
            "{}{}",
            f.url,
            prepared["downloadUrl"].as_str().unwrap()
        ))
        .send()
        .await
        .unwrap();
    assert_eq!(zip_files(&response.bytes().await.unwrap()).len(), 5000);
    // Cache retains only eight selections; eviction produces a retryable 410.
    for _ in 0..8 {
        assert_eq!(
            f.client
                .post(format!("{endpoint}?prepare=1"))
                .header("content-type", "application/x-www-form-urlencoded")
                .body(form.clone())
                .send()
                .await
                .unwrap()
                .status(),
            200
        );
    }
    assert_eq!(
        f.client.get(&prepared_url).send().await.unwrap().status(),
        410
    );
    assert_eq!(
        f.client
            .post(&endpoint)
            .header("content-type", "application/x-www-form-urlencoded")
            .header("origin", "http://wrong.invalid")
            .body(form)
            .send()
            .await
            .unwrap()
            .status(),
        403
    );
    assert_eq!(
        f.client
            .post(&endpoint)
            .header("content-type", "application/x-www-form-urlencoded")
            .body(format!("sessionId={session}&fileId=unknown"))
            .send()
            .await
            .unwrap()
            .status(),
        410
    );
    assert_eq!(
        f.client
            .get(format!("{endpoint}?sessionId={session}&prefix=..%2F"))
            .send()
            .await
            .unwrap()
            .status(),
        400
    );
    assert_eq!(
        zip_files(
            &f.client
                .get(format!("{endpoint}?sessionId={session}&prefix=folder-1%2F"))
                .send()
                .await
                .unwrap()
                .bytes()
                .await
                .unwrap()
        )
        .len(),
        250
    );
    // Repeated selection is supported in GET as well; repeated sessions are not.
    let get_selected = f
        .client
        .get(format!("{endpoint}?sessionId={session}&fileId=2&fileId=3"))
        .send()
        .await
        .unwrap();
    assert_eq!(zip_files(&get_selected.bytes().await.unwrap()).len(), 2);
    assert_eq!(
        f.client
            .get(format!(
                "{endpoint}?sessionId={session}&sessionId={session}"
            ))
            .send()
            .await
            .unwrap()
            .status(),
        400
    );
    assert_eq!(
        f.client
            .post(&endpoint)
            .header("content-type", "application/x-www-form-urlencoded")
            .body("x".repeat(1024 * 1024 + 1))
            .send()
            .await
            .unwrap()
            .status(),
        413
    );
    let versioned = f
        .client
        .post(format!("{endpoint}?prepare=1"))
        .header("content-type", "application/x-www-form-urlencoded")
        .body(format!("sessionId={session}&fileId=1"))
        .send()
        .await
        .unwrap()
        .json::<serde_json::Value>()
        .await
        .unwrap();
    // Dropping the active archive cancels the current source and returns its permit.
    let stalled = FileDto {
        id: "stall".into(),
        file_name: "stall.txt".into(),
        size: 10,
        file_type: "text/plain".into(),
        sha256: None,
        preview: None,
        metadata: None,
    };
    f.handle
        .patch_web_workspace(HashMap::from([("stall".into(), stalled.clone())]), vec![])
        .await
        .unwrap();
    assert_eq!(
        f.client
            .get(format!(
                "{}{}",
                f.url,
                versioned["downloadUrl"].as_str().unwrap()
            ))
            .send()
            .await
            .unwrap()
            .status(),
        410
    );
    let mut response = f
        .client
        .get(format!("{endpoint}?sessionId={session}&fileId=stall"))
        .send()
        .await
        .unwrap();
    assert_eq!(response.status(), 200);
    assert!(response.chunk().await.unwrap().is_some());
    f.handle
        .patch_web_workspace(HashMap::new(), vec!["stall".into()])
        .await
        .unwrap();
    assert!(
        tokio::time::timeout(Duration::from_secs(2), response.bytes())
            .await
            .unwrap()
            .is_err()
    );
    let short = FileDto {
        id: "short".into(),
        file_name: "short.txt".into(),
        ..stalled
    };
    f.handle
        .patch_web_workspace(HashMap::from([("short".into(), short)]), vec![])
        .await
        .unwrap();
    assert!(f
        .client
        .get(format!("{endpoint}?sessionId={session}&fileId=short"))
        .send()
        .await
        .unwrap()
        .bytes()
        .await
        .is_err());
    f.handle.set_web_mode(WebMode::Disabled);
    assert_eq!(
        f.client
            .get(format!("{endpoint}?sessionId={session}"))
            .send()
            .await
            .unwrap()
            .status(),
        403
    );
    f.configure(1, None, true).await;
    let dir = format!(
        "{}/api/legnasend/v1/workspaces/11111111-1111-4111-8111-111111111111/archive",
        f.url
    );
    let response = f
        .client
        .get(format!("{dir}?generation=1"))
        .send()
        .await
        .unwrap();
    assert_eq!(response.status(), 200);
    let bytes = response.bytes().await.unwrap();
    let files = zip_files(&bytes);
    assert_eq!(files.len(), 4);
    assert!(files.contains_key("files/nested/empty/"));
    assert_eq!(files["files/nested/中文 %.txt"], b"unicode content");
    assert!(!files
        .keys()
        .any(|s| s.contains("private") || s.contains("escape")));
    if let Ok(root) = std::env::var("LEGNASEND_ARCHIVE_EVIDENCE") {
        std::fs::write(PathBuf::from(root).join("folder.zip"), &bytes).unwrap();
    }
    let nested = zip_files(
        &f.client
            .get(format!("{dir}?generation=1&path=nested"))
            .send()
            .await
            .unwrap()
            .bytes()
            .await
            .unwrap(),
    );
    assert_eq!(nested.len(), 3);
    assert!(nested.contains_key("nested/empty/"));
    assert_eq!(
        f.client
            .get(format!("{dir}?generation=1&path=../"))
            .send()
            .await
            .unwrap()
            .status(),
        400
    );
    assert_eq!(
        f.client
            .get(format!("{dir}?generation=2"))
            .send()
            .await
            .unwrap()
            .status(),
        409
    );
    let password = localsend::http::server::directory_auth::hash_password("123456".into())
        .await
        .unwrap();
    f.configure(2, Some(password), true).await;
    assert_eq!(
        f.client
            .head(format!("{dir}?generation=2"))
            .send()
            .await
            .unwrap()
            .status(),
        401
    );
    let unlock = f
        .client
        .post(format!(
            "{}/api/legnasend/v1/workspaces/11111111-1111-4111-8111-111111111111/unlock",
            f.url
        ))
        .json(&json!({"generation":2,"password":"123456"}))
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
        .to_string();
    let protected = f
        .client
        .get(format!("{dir}?generation=2"))
        .header("cookie", &cookie)
        .send()
        .await
        .unwrap();
    assert_eq!(zip_files(&protected.bytes().await.unwrap()).len(), 4);
    // Renaming uses a fresh generation; removing protection revokes old grants.
    f.configure(
        3,
        Some(
            localsend::http::server::directory_auth::hash_password("new-pass".into())
                .await
                .unwrap(),
        ),
        true,
    )
    .await;
    assert_eq!(
        f.client
            .head(format!("{dir}?generation=3"))
            .header("cookie", cookie)
            .send()
            .await
            .unwrap()
            .status(),
        401
    );
    f.configure(4, None, false).await;
    assert_eq!(
        f.client
            .get(format!("{dir}?generation=3"))
            .send()
            .await
            .unwrap()
            .status(),
        404
    );
    f.stop().await;
}
