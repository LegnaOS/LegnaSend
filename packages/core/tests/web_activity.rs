#![cfg(feature = "http")]
use bytes::Bytes;
use localsend::http::server::{
    ServerConfigV2, start_with_port,
    web::{WebConfig, WebDownloadConfig, WebDownloadEvent, WebMode},
};
use localsend::http::state::ClientInfo;
use localsend::model::transfer::{FileContent, FileDto};
use serde_json::Value;
use std::{collections::HashMap, time::Duration};
use tokio::sync::{mpsc, oneshot};

fn file(id: &str, size: u64) -> FileDto {
    FileDto {
        id: id.into(),
        file_name: format!("{id}.bin"),
        size,
        file_type: "application/octet-stream".into(),
        sha256: None,
        preview: None,
        metadata: None,
    }
}
#[tokio::test]
async fn real_response_ranges_head_preview_zip_and_scoped_cancel() {
    let directory =
        std::env::temp_dir().join(format!("legnasend-web-activity-{}", uuid::Uuid::new_v4()));
    std::fs::create_dir(&directory).unwrap();
    let path = directory.join("small.bin");
    tokio::fs::write(&path, b"abcdefghijklmnop").await.unwrap();
    let (events, mut receive) = mpsc::channel(16);
    tokio::spawn(async move {
        while let Some(event) = receive.recv().await {
            match event {
                WebDownloadEvent::PrepareDownload { decision_tx, .. } => {
                    let _ = decision_tx.send(true);
                }
                WebDownloadEvent::PrepareDownloadAborted { .. } => {}
                WebDownloadEvent::FileDownload {
                    file_id,
                    content_tx,
                    ..
                } => {
                    if file_id == "small" {
                        let _ = content_tx.send(FileContent::Path(path.clone()));
                    } else {
                        let (tx, rx) = mpsc::channel(1);
                        let _ = content_tx.send(FileContent::Stream(rx));
                        tokio::spawn(async move {
                            for _ in 0..1000 {
                                if tx.send(Bytes::from(vec![7; 4096])).await.is_err() {
                                    break;
                                }
                                tokio::time::sleep(Duration::from_millis(5)).await;
                            }
                        });
                    }
                }
            }
        }
    });
    let (v2, _v2rx) = mpsc::channel(16);
    let (stop, stopped) = oneshot::channel();
    let handle = start_with_port(
        0,
        None,
        ClientInfo {
            alias: "Activity".into(),
            version: "2.2".into(),
            device_model: None,
            device_type: None,
            token: "fingerprint".into(),
        },
        None,
        Some(ServerConfigV2 {
            pin: None,
            verify_checksums: true,
            event_tx: v2,
        }),
        WebConfig {
            mode: WebMode::Download(WebDownloadConfig {
                files: HashMap::from([
                    ("small".into(), file("small", 16)),
                    ("slow".into(), file("slow", 4096000)),
                ]),
                pin: None,
                event_tx: events,
            }),
            ..Default::default()
        },
        stopped,
    )
    .await
    .unwrap();
    let base = format!("http://127.0.0.1:{}", handle.port());
    let client = reqwest::Client::builder().no_proxy().build().unwrap();
    let approved: Value = client
        .post(format!("{base}/api/localsend/v2/prepare-download"))
        .send()
        .await
        .unwrap()
        .json()
        .await
        .unwrap();
    let session = approved["sessionId"].as_str().unwrap();
    let url = format!("{base}/api/localsend/v2/download?sessionId={session}&fileId=small");
    assert_eq!(client.head(&url).send().await.unwrap().status(), 200);
    assert_eq!(
        client
            .get(format!("{url}&preview=1"))
            .send()
            .await
            .unwrap()
            .bytes()
            .await
            .unwrap()
            .len(),
        16
    );
    // Native media elements carry the HEAD identity in the preview URL since
    // they cannot attach If-Match to their subsequent browser Range requests.
    let metadata = client.head(&url).send().await.unwrap();
    let tag = metadata.headers()["etag"].to_str().unwrap();
    let pinned = format!(
        "{url}&preview=1&version={}",
        percent_encoding::utf8_percent_encode(tag, percent_encoding::NON_ALPHANUMERIC)
    );
    let preview_range = client
        .get(&pinned)
        .header("range", "bytes=3-7")
        .send()
        .await
        .unwrap();
    assert_eq!(preview_range.status(), 206);
    assert_eq!(&preview_range.bytes().await.unwrap()[..], b"defgh");
    assert_eq!(
        client
            .get(format!("{url}&preview=1&version=%22stale%22"))
            .send()
            .await
            .unwrap()
            .status(),
        412
    );
    assert_eq!(
        client
            .get(&pinned)
            .header("if-match", "\"different\"")
            .send()
            .await
            .unwrap()
            .status(),
        412
    );
    assert_eq!(handle.web_download_activity(), "[]");
    let range = client
        .get(&url)
        .header("range", "bytes=3-7")
        .send()
        .await
        .unwrap();
    assert_eq!(range.status(), 206);
    assert_eq!(&range.bytes().await.unwrap()[..], b"defgh");
    let list: Value = serde_json::from_str(&handle.web_download_activity()).unwrap();
    assert_eq!(list[0]["total"], 5);
    assert_eq!(list[0]["transferred"], 5);
    assert_eq!(list[0]["phase"], "succeeded");
    let zip = client
        .get(format!(
            "{base}/api/legnasend/v1/web/archive?sessionId={session}&fileId=small"
        ))
        .send()
        .await
        .unwrap();
    assert_eq!(zip.status(), 200);
    let zip_length = zip.bytes().await.unwrap().len();
    let list: Value = serde_json::from_str(&handle.web_download_activity()).unwrap();
    // An archive is a single outer response, not double-counted source reads.
    assert_eq!(list.as_array().unwrap().len(), 2);
    assert_eq!(list[1]["transferred"], zip_length);
    assert_eq!(list[1]["phase"], "succeeded");
    let invalid = client
        .get(&url)
        .header("range", "bytes=99-100")
        .send()
        .await
        .unwrap();
    assert_eq!(invalid.status(), 416);
    let _ = invalid.bytes().await.unwrap();
    let list: Value = serde_json::from_str(&handle.web_download_activity()).unwrap();
    assert_eq!(list.as_array().unwrap().last().unwrap()["phase"], "failed");
    let slow_url = format!("{base}/api/localsend/v2/download?sessionId={session}&fileId=slow");
    let response = client.get(&slow_url).send().await.unwrap();
    let list: Value = serde_json::from_str(&handle.web_download_activity()).unwrap();
    let running = list
        .as_array()
        .unwrap()
        .iter()
        .find(|r| r["phase"] == "transferring")
        .unwrap();
    let id = running["id"].as_str().unwrap();
    assert!(handle.cancel_web_download(id));
    assert!(!handle.cancel_web_download(id));
    assert!(response.bytes().await.is_err());
    assert_eq!(
        client
            .get(&url)
            .send()
            .await
            .unwrap()
            .bytes()
            .await
            .unwrap()
            .len(),
        16
    );
    assert_eq!(
        client
            .get(format!("{base}/api/localsend/v2/info"))
            .send()
            .await
            .unwrap()
            .status(),
        200
    );
    let list: Value = serde_json::from_str(&handle.web_download_activity()).unwrap();
    assert_eq!(
        list.as_array()
            .unwrap()
            .iter()
            .find(|r| r["id"] == id)
            .unwrap()["phase"],
        "canceled"
    );
    let _ = stop.send(());
    let _ = std::fs::remove_dir_all(directory);
}
