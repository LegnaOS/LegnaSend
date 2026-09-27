#![cfg(feature = "http")]
//! Real killed-process recovery. No recursive destination scan or extension ownership assumptions.
use localsend::http::server::{start_with_port, web::WebConfig};
use localsend::http::state::ClientInfo;
use localsend::receive_registry::{cleanup, configure};
use serde_json::json;
use std::{path::PathBuf, time::Duration};
use tokio::{io::AsyncWriteExt, sync::oneshot};

struct Child(std::process::Child);
impl Drop for Child {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}
struct Root(PathBuf);
impl Drop for Root {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}
#[test]
fn registered_directory_upload_is_cleaned_after_kill_but_active_unknown_and_final_are_preserved() {
    let root =
        Root(std::env::temp_dir().join(format!("legnasend-upload-crash-{}", uuid::Uuid::new_v4())));
    let dest = root.0.join("destination");
    std::fs::create_dir_all(&dest).unwrap();
    for name in [
        "user.ls",
        ".legnasend-receive-user.part",
        ".legnasend-upload-old.part",
        "final.txt",
    ] {
        std::fs::write(dest.join(name), b"user-owned bytes").unwrap();
    }
    let mut child = Child(
        std::process::Command::new(std::env::current_exe().unwrap())
            .args(["--exact", "directory_upload_crash_child", "--nocapture"])
            .env("LEGNASEND_DIRECTORY_UPLOAD_CRASH", &root.0)
            .spawn()
            .unwrap(),
    );
    for _ in 0..1500 {
        if root.0.join("ready").exists() {
            break;
        }
        assert!(
            child.0.try_wait().unwrap().is_none(),
            "Upload child exited before partial bytes"
        );
        std::thread::sleep(Duration::from_millis(10));
    }
    assert!(root.0.join("ready").exists());
    configure(root.0.join("registry")).unwrap();
    let active = cleanup(100).unwrap();
    assert_eq!(active.active, 1, "{active:?}");
    assert_eq!(active.removed_files, 0);
    child.0.kill().unwrap();
    child.0.wait().unwrap();
    let cleaned = cleanup(100).unwrap();
    assert_eq!(cleaned.removed_files, 1, "{cleaned:?}");
    assert_eq!(cleaned.removed_records, 1);
    assert_eq!(
        cleaned.reasons.get("interrupted_directory_upload"),
        Some(&1)
    );
    assert!(cleaned.unlinked_bytes >= 65536);
    assert_eq!(cleaned.failed, 0);
    assert!(!dest.join("incoming.txt").exists());
    for name in [
        "user.ls",
        ".legnasend-receive-user.part",
        ".legnasend-upload-old.part",
        "final.txt",
    ] {
        assert_eq!(std::fs::read(dest.join(name)).unwrap(), b"user-owned bytes");
    }
    assert_eq!(std::fs::read_dir(dest).unwrap().count(), 4);
    assert_eq!(cleanup(100).unwrap().removed_files, 0);
}
#[tokio::test]
async fn directory_upload_crash_child() {
    let Some(root) = std::env::var_os("LEGNASEND_DIRECTORY_UPLOAD_CRASH").map(PathBuf::from) else {
        return;
    };
    configure(root.join("registry")).unwrap();
    let (_stop, rx) = oneshot::channel();
    let server = start_with_port(
        0,
        None,
        ClientInfo {
            alias: "Crash upload".into(),
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
    let id = "11111111-1111-4111-8111-111111111111";
    server.configure_directory_workspaces(&json!({"revision":1,"enabled":true,"workspaces":[{"id":id,"name":"Crash","slug":"crash","root":root.join("destination"),"generation":1,"visible":true,"allowUpload":true}]}).to_string()).await.unwrap();
    let mut socket = tokio::net::TcpStream::connect(("127.0.0.1", server.port()))
        .await
        .unwrap();
    socket.write_all(format!("POST /api/legnasend/v1/workspaces/{id}/upload?generation=1&path=incoming.txt HTTP/1.1\r\nHost: 127.0.0.1:{}\r\nX-LegnaSend-Upload: 1\r\nContent-Type: application/octet-stream\r\nContent-Length: 1048576\r\n\r\n",server.port()).as_bytes()).await.unwrap();
    socket.write_all(&vec![42; 65536]).await.unwrap();
    for _ in 0..500 {
        if std::fs::read_dir(root.join("destination"))
            .unwrap()
            .any(|entry| {
                let entry = entry.unwrap();
                entry
                    .file_name()
                    .to_string_lossy()
                    .starts_with(".legnasend-receive-")
                    && entry.metadata().is_ok_and(|m| m.len() >= 65536)
            })
        {
            std::fs::write(root.join("ready"), b"ready").unwrap();
            std::future::pending::<()>().await;
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    panic!("Partial upload never reached disk");
}
