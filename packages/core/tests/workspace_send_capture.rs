#![cfg(feature = "http")]
use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
use localsend::http::{
    server::{start_with_port, web::WebConfig},
    state::ClientInfo,
};
use serde_json::{Value, json};
#[tokio::test]
async fn captures_only_versioned_regular_files_and_never_follows_links_or_overwrites() {
    let base = std::env::temp_dir().join(format!("workspace-send-{}", uuid::Uuid::new_v4()));
    std::fs::create_dir_all(base.join("source/sub")).unwrap();
    std::fs::create_dir(base.join("stage")).unwrap();
    std::fs::write(base.join("source/sub/文件.txt"), b"original bytes").unwrap();
    let (tx, rx) = tokio::sync::oneshot::channel();
    let server = start_with_port(
        0,
        None,
        ClientInfo {
            alias: "fixture".into(),
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
    let id = uuid::Uuid::new_v4().to_string();
    let file_id = URL_SAFE_NO_PAD.encode("sub/文件.txt");
    server.configure_directory_workspaces(&json!({"revision":1,"enabled":true,"workspaces":[{"id":id,"name":"test","slug":"source","root":base.join("source"),"generation":1,"visible":true}]}).to_string()).await.unwrap();
    let client = reqwest::Client::builder().no_proxy().build().unwrap();
    let url = format!(
        "http://127.0.0.1:{}/api/legnasend/v1/workspaces/{id}/files/{file_id}/content?generation=1",
        server.port()
    );
    let head = client.head(&url).send().await.unwrap();
    assert_eq!(head.status(), 200);
    let tag = head.headers()["etag"].to_str().unwrap().to_string();
    let selection = json!([{"id":file_id,"version":tag}]).to_string();
    let stage = base.join("stage").to_str().unwrap().to_owned();
    let result: Value = serde_json::from_str(
        &server
            .capture_workspace_sources(&id, 1, &selection, stage.clone())
            .await
            .unwrap(),
    )
    .unwrap();
    assert_eq!(result["files"][0]["name"], "sub/文件.txt");
    assert!(!result.to_string().contains(base.to_str().unwrap()));
    assert_eq!(
        std::fs::read(base.join("stage/source-0")).unwrap(),
        b"original bytes"
    );
    assert!(
        server
            .capture_workspace_sources(&id, 1, &selection, stage.clone())
            .await
            .is_err()
    );
    assert_eq!(
        std::fs::read(base.join("stage/source-0")).unwrap(),
        b"original bytes"
    );
    std::fs::write(base.join("source/sub/文件.txt"), b"changed").unwrap();
    std::fs::create_dir(base.join("next")).unwrap();
    assert!(
        server
            .capture_workspace_sources(
                &id,
                1,
                &selection,
                base.join("next").to_str().unwrap().into()
            )
            .await
            .is_err()
    );
    assert!(
        std::fs::read_dir(base.join("next"))
            .unwrap()
            .next()
            .is_none()
    );
    for path in ["../outside", "/tmp/outside", "sub/../outside", ".ls"] {
        let value = json!([{"id":URL_SAFE_NO_PAD.encode(path),"version":tag}]).to_string();
        assert!(
            server
                .capture_workspace_sources(&id, 1, &value, stage.clone())
                .await
                .is_err()
        );
    }
    #[cfg(unix)]
    {
        std::os::unix::fs::symlink(base.join("stage/source-0"), base.join("source/link")).unwrap();
        let value = json!([{"id":URL_SAFE_NO_PAD.encode("link"),"version":tag}]).to_string();
        assert!(
            server
                .capture_workspace_sources(
                    &id,
                    1,
                    &value,
                    base.join("next").to_str().unwrap().into()
                )
                .await
                .is_err()
        );
    }
    assert!(
        server
            .capture_workspace_sources(&id, 2, &selection, stage)
            .await
            .is_err()
    );
    let _ = tx.send(());
    server.wait_stopped().await;
    std::fs::remove_dir_all(base).unwrap();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn stopping_the_real_server_interrupts_capture_and_rejects_stale_handles() {
    use std::{sync::Arc, time::Duration};
    let base = std::env::temp_dir().join(format!("workspace-send-stop-{}", uuid::Uuid::new_v4()));
    std::fs::create_dir_all(base.join("source")).unwrap();
    std::fs::create_dir(base.join("stage")).unwrap();
    std::fs::create_dir(base.join("after-stop")).unwrap();
    // A sparse source makes a full-file copy observably longer than waiting for
    // its first output buffer without allocating a GiB of fixture data up front.
    let source_size = 1u64 << 30;
    std::fs::File::create(base.join("source/large.bin"))
        .unwrap()
        .set_len(source_size)
        .unwrap();
    let (stop, receiver) = tokio::sync::oneshot::channel();
    let server = Arc::new(
        start_with_port(
            0,
            None,
            ClientInfo {
                alias: "stop fixture".into(),
                version: "2.2".into(),
                device_model: None,
                device_type: None,
                token: "fixture".into(),
            },
            None,
            None,
            WebConfig::default(),
            receiver,
        )
        .await
        .unwrap(),
    );
    let workspace = uuid::Uuid::new_v4().to_string();
    let file = URL_SAFE_NO_PAD.encode("large.bin");
    server.configure_directory_workspaces(&json!({"revision":1,"enabled":true,"workspaces":[{"id":workspace,"name":"test","slug":"source","root":base.join("source"),"generation":1,"visible":true}]}).to_string()).await.unwrap();
    let client = reqwest::Client::builder().no_proxy().build().unwrap();
    let metadata = client.head(format!("http://127.0.0.1:{}/api/legnasend/v1/workspaces/{workspace}/files/{file}/content?generation=1", server.port())).send().await.unwrap();
    assert_eq!(metadata.status(), 200);
    let selection =
        json!([{"id":file,"version":metadata.headers()["etag"].to_str().unwrap()}]).to_string();
    let capture = {
        let server = server.clone();
        let workspace = workspace.clone();
        let selection = selection.clone();
        let stage = base.join("stage").to_str().unwrap().to_string();
        tokio::spawn(async move {
            server
                .capture_workspace_sources(&workspace, 1, &selection, stage)
                .await
        })
    };
    let output = base.join("stage/source-0");
    tokio::time::timeout(Duration::from_secs(10), async {
        while !std::fs::metadata(&output).is_ok_and(|m| m.len() > 0) {
            assert!(
                !capture.is_finished(),
                "capture ended before the stop probe"
            );
            tokio::time::sleep(Duration::from_millis(1)).await;
        }
    })
    .await
    .unwrap();
    stop.send(()).unwrap();
    server.wait_stopped().await;
    let error = tokio::time::timeout(Duration::from_secs(10), capture)
        .await
        .unwrap()
        .unwrap()
        .unwrap_err();
    assert_eq!(error.to_string(), "server_stopped");
    let copied = std::fs::metadata(&output).unwrap().len();
    assert!(
        copied > 0 && copied < source_size,
        "stopped capture copied {copied} of {source_size}"
    );
    let stale = server
        .capture_workspace_sources(
            &workspace,
            1,
            &selection,
            base.join("after-stop").to_str().unwrap().to_string(),
        )
        .await
        .unwrap_err();
    assert_eq!(stale.to_string(), "server_stopped");
    assert!(
        std::fs::read_dir(base.join("after-stop"))
            .unwrap()
            .next()
            .is_none()
    );
    println!(
        "stopped workspace capture after {copied} of {source_size} bytes; stale handle rejected"
    );
    std::fs::remove_dir_all(base).unwrap();
}
