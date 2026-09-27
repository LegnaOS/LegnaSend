#![cfg(feature = "http")]
//! Keep process spawning out of the parallel unit-test binary: a spawned child
//! can briefly inherit another thread's locked open-file descriptions on Unix.
use bytes::Bytes;
use futures_util::{stream, StreamExt};
use localsend::http::server::common::save::FileUploadTarget;
use localsend::http::server::v2::{PrepareUploadDecisionV2, ServerEventV2};
use localsend::http::server::web::WebConfig;
use localsend::http::server::{start_with_port, ServerConfigV2};
use localsend::http::state::ClientInfo;
use localsend::receive_registry::{cleanup, cleanup_now, configure, configure_retention_policy, inspect, inspect_now};
use serde_json::{json, Value};
use std::{path::PathBuf, time::Duration};
use tokio::sync::{mpsc, oneshot};

struct Root(PathBuf);
impl Drop for Root {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}
struct ChildGuard(std::process::Child);
impl Drop for ChildGuard {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

#[test]
fn killed_http_receiver_leaves_only_registered_remnants_for_next_startup() {
    let root = Root(
        std::env::temp_dir().join(format!("legnasend-registry-crash-{}", uuid::Uuid::new_v4())),
    );
    let destination = root.0.join("Downloads 中文 %");
    std::fs::create_dir_all(&destination).unwrap();
    std::fs::write(destination.join("user.ls"), b"keep user").unwrap();
    std::fs::write(destination.join("published.bin"), b"keep final").unwrap();
    // Spawn before this process has any registry file locks.
    let mut child = ChildGuard(
        std::process::Command::new(std::env::current_exe().unwrap())
            .args(["--exact", "crash_writer_helper", "--nocapture"])
            .env("LEGNASEND_REGISTRY_CRASH_FIXTURE", &root.0)
            .spawn()
            .unwrap(),
    );
    for _ in 0..1500 {
        if root.0.join("ready").exists() {
            break;
        }
        assert!(
            child.0.try_wait().unwrap().is_none(),
            "Receiver exited before partial upload"
        );
        std::thread::sleep(Duration::from_millis(10));
    }
    assert!(root.0.join("ready").exists());
    configure(root.0.join("registry")).unwrap();
    let active = cleanup(100).unwrap();
    assert_eq!(active.active, 1, "{active:?}");
    assert_eq!(active.removed_files, 0);
    configure_retention_policy("manual", None).unwrap();
    assert_eq!(cleanup_now(100).unwrap().active, 1, "Explicit now never overrides live locks");
    child.0.kill().unwrap();
    assert!(!child.0.wait().unwrap().success());
    let retained = cleanup(100).unwrap();
    assert_eq!(retained.reasons["retention_manual"], 1, "{retained:?}");
    assert_eq!(retained.removed_files, 0);
    configure_retention_policy("days", Some(1)).unwrap();
    let retained = inspect(100).unwrap();
    assert_eq!(retained.reasons["retention_period"], 1, "Real child persisted its registration age");
    let preview = inspect_now(100).unwrap();
    assert_eq!(preview.entries[0].disposition, "candidate");
    assert_eq!(preview.removed_files, 0);
    assert_eq!(preview.removed_records, 0);
    assert!(preview.planned_bytes >= 64 * 1024);
    let report = cleanup_now(100).unwrap();
    assert_eq!(report.removed_files, 1, "{report:?}");
    assert_eq!(report.removed_records, 1);
    assert_eq!(report.failed, 0);
    assert!(report.unlinked_bytes >= 64 * 1024);
    assert!(!destination.join("incoming.bin").exists());
    assert_eq!(
        std::fs::read(destination.join("user.ls")).unwrap(),
        b"keep user"
    );
    assert_eq!(
        std::fs::read(destination.join("published.bin")).unwrap(),
        b"keep final"
    );
    assert_eq!(std::fs::read_dir(destination).unwrap().count(), 2);
    assert_eq!(
        std::fs::read_dir(root.0.join("registry")).unwrap().count(),
        0
    );
}

#[tokio::test]
async fn crash_writer_helper() {
    let Some(root) = std::env::var_os("LEGNASEND_REGISTRY_CRASH_FIXTURE").map(PathBuf::from) else {
        return;
    };
    configure(root.join("registry")).unwrap();
    let (events, mut incoming) = mpsc::channel(16);
    let (progress, mut bytes_written) = mpsc::channel(16);
    let destination = root.join("Downloads 中文 %").join("incoming.bin");
    tokio::spawn(async move {
        while let Some(event) = incoming.recv().await {
            match event {
                ServerEventV2::PrepareUpload {
                    files, decision_tx, ..
                } => {
                    let _ = decision_tx.send(PrepareUploadDecisionV2::Accept(
                        files.keys().cloned().collect(),
                    ));
                }
                ServerEventV2::FileUpload { target_tx, .. } => {
                    let (result_tx, result_rx) = oneshot::channel();
                    let _ = target_tx.send(FileUploadTarget::CachedPath {
                        path: destination.clone(),
                        result_tx,
                        progress_tx: Some(progress.clone()),
                    });
                    tokio::spawn(async move {
                        let _ = result_rx.await;
                    });
                }
                _ => {}
            }
        }
    });
    let (_stop, stopped) = oneshot::channel();
    let server = start_with_port(
        0,
        None,
        ClientInfo {
            alias: "Crash fixture".into(),
            version: "2.2".into(),
            device_model: None,
            device_type: None,
            token: "receiver".into(),
        },
        None,
        Some(ServerConfigV2 {
            pin: None,
            verify_checksums: true,
            event_tx: events,
        }),
        WebConfig::default(),
        stopped,
    )
    .await
    .unwrap();
    let client = reqwest::Client::builder().no_proxy().build().unwrap();
    let base = format!("http://127.0.0.1:{}/api/localsend/v2", server.port());
    let session: Value = client.post(format!("{base}/prepare-upload")).json(&json!({
        "info": {"alias":"sender", "version":"2.2", "fingerprint":"sender", "port":53317, "protocol":"http", "download":false},
        "files": {"incoming": {"id":"incoming", "fileName":"incoming.bin", "size":4*1024*1024, "fileType":"application/octet-stream"}}
    })).send().await.unwrap().error_for_status().unwrap().json().await.unwrap();
    let body = stream::once(async { Ok::<_, std::io::Error>(Bytes::from(vec![7; 1024 * 1024])) })
        .chain(stream::pending());
    tokio::spawn(async move {
        let mut url = reqwest::Url::parse(&format!("{base}/upload")).unwrap();
        url.query_pairs_mut().extend_pairs([
            ("sessionId", session["sessionId"].as_str().unwrap()),
            ("fileId", "incoming"),
            ("token", session["files"]["incoming"].as_str().unwrap()),
        ]);
        let _ = client
            .post(url)
            .body(reqwest::Body::wrap_stream(body))
            .send()
            .await;
    });
    tokio::time::timeout(Duration::from_secs(10), async {
        loop {
            let bytes = bytes_written
                .recv()
                .await
                .expect("Upload ended before writing");
            if bytes > 0 {
                break;
            }
        }
    })
    .await
    .unwrap();
    std::fs::write(root.join("ready"), b"ready").unwrap();
    // The request has no EOF. The parent terminates this actual HTTP receiver.
    std::future::pending::<()>().await;
}
