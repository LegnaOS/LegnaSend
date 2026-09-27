//! Serves explicitly named generated media/text fixtures for local browser QA.
use localsend::http::server::{
    ServerConfigV2,
    common::save::FileUploadTarget,
    start_with_port,
    v2::{PrepareUploadDecisionV2, ServerEventV2},
    web::{WebConfig, WebDownloadConfig, WebDownloadEvent, WebMode},
};
use localsend::http::state::ClientInfo;
use localsend::model::transfer::{FileContent, FileDto};
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::Arc;
use tokio::io::AsyncBufReadExt;
use tokio::sync::{mpsc, oneshot};

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let root = PathBuf::from(
        std::env::args()
            .nth(1)
            .expect("Provide the generated fixture directory"),
    );
    let duplex = std::env::var("LEGNASEND_FIXTURE_MODE").ok().as_deref() == Some("duplex");
    let upload = std::env::var("LEGNASEND_FIXTURE_MODE").ok().as_deref() == Some("upload");
    let pin = std::env::var("LEGNASEND_FIXTURE_PIN").ok();
    let count = std::env::var("LEGNASEND_FIXTURE_COUNT")
        .ok()
        .and_then(|v| v.parse::<usize>().ok())
        .unwrap_or(0)
        .min(50_000);
    let specs = [
        ("video", "demo.mp4", "video/mp4"),
        ("audio", "demo.wav", "audio/wav"),
        ("image", "demo.png", "image/png"),
        ("text", "demo.txt", "text/plain"),
        ("markdown", "demo.md", "text/markdown"),
        ("gbk", "gbk.txt", "text/plain"),
    ];
    let mut files = HashMap::new();
    let mut paths = HashMap::new();
    for (id, name, mime) in specs {
        let path = root.join(name);
        if !path.exists() {
            continue;
        }
        files.insert(
            id.to_string(),
            FileDto {
                id: id.into(),
                file_name: name.into(),
                file_type: mime.into(),
                size: std::fs::metadata(&path)?.len(),
                sha256: None,
                preview: None,
                metadata: None,
            },
        );
        paths.insert(id.to_string(), path);
    }
    let download_delay = std::env::var("LEGNASEND_FIXTURE_DOWNLOAD_DELAY_MS")
        .ok()
        .and_then(|v| v.parse::<u64>().ok())
        .unwrap_or(0)
        .min(5_000);
    let seeds: Vec<_> = files.values().cloned().collect();
    for i in 0..count {
        if seeds.is_empty() {
            break;
        }
        let mut file = seeds[i % seeds.len()].clone();
        let path = paths[&file.id].clone();
        file.id = format!("fixture-{i:05}");
        file.file_name = format!("{:05}-{}", i, file.file_name);
        paths.insert(file.id.clone(), path);
        files.insert(file.id.clone(), file);
    }
    let (v2_tx, mut v2_rx) = mpsc::channel(32);
    let output = root.join("received");
    tokio::spawn(async move {
        while let Some(event) = v2_rx.recv().await {
            match event {
                ServerEventV2::PrepareUpload {
                    files, decision_tx, ..
                } => {
                    let valid = files.len() <= 10_000
                        && files.values().all(|f| {
                            !f.file_name.contains(['\\', ':', '\0'])
                                && f.file_name
                                    .split('/')
                                    .all(|part| !part.is_empty() && part != "." && part != "..")
                        })
                        && files
                            .values()
                            .try_fold(0u64, |sum, f| sum.checked_add(f.size))
                            .is_some_and(|sum| sum <= 32 * 1024 * 1024);
                    let decision = if valid {
                        PrepareUploadDecisionV2::Accept(files.keys().cloned().collect())
                    } else {
                        PrepareUploadDecisionV2::Decline
                    };
                    let _ = decision_tx.send(decision);
                }
                ServerEventV2::FileUpload {
                    session_id,
                    file,
                    target_tx,
                    ..
                } => {
                    let path = output.join(session_id).join(&file.file_name);
                    if tokio::fs::create_dir_all(path.parent().unwrap())
                        .await
                        .is_err()
                    {
                        continue;
                    }
                    let (result_tx, result_rx) = oneshot::channel();
                    let _ = target_tx.send(FileUploadTarget::Path {
                        path: path.clone(),
                        result_tx,
                        progress_tx: None,
                    });
                    tokio::spawn(async move {
                        if let Ok(Ok(())) = result_rx.await {
                            println!("Received {}", path.display());
                        }
                    });
                }
                _ => {}
            }
        }
    });
    let (events, mut rx) = mpsc::channel(32);
    let (stop, stopping) = oneshot::channel();
    let server = start_with_port(
        std::env::var("LEGNASEND_FIXTURE_PORT")
            .ok()
            .and_then(|v| v.parse().ok())
            .unwrap_or(0),
        None,
        ClientInfo {
            alias: "LegnaSend preview fixture".into(),
            version: "2.2".into(),
            device_model: None,
            device_type: None,
            token: "fixture".into(),
        },
        None,
        (upload || duplex).then(|| ServerConfigV2 {
            pin: pin.clone(),
            verify_checksums: true,
            event_tx: v2_tx,
        }),
        WebConfig {
            mode: if duplex {
                WebMode::Duplex {
                    download: WebDownloadConfig {
                        files,
                        pin,
                        event_tx: events,
                    },
                    allow_upload: true,
                }
            } else if upload {
                WebMode::Upload
            } else {
                WebMode::Download(WebDownloadConfig {
                    files,
                    pin,
                    event_tx: events,
                })
            },
            ..Default::default()
        },
        stopping,
    )
    .await?;
    let paths = Arc::new(tokio::sync::RwLock::new(paths));
    let download_paths = paths.clone();
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
                    let path = download_paths.read().await.get(&file_id).cloned();
                    if let Some(path) = path {
                        tokio::time::sleep(std::time::Duration::from_millis(download_delay)).await;
                        let _ = content_tx.send(FileContent::Path(path.clone()));
                    }
                }
            }
        }
    });
    println!("http://127.0.0.1:{}/", server.port());
    // Explicit local-stdin control for lifecycle QA; never exposed as an HTTP route.
    if std::env::var("LEGNASEND_FIXTURE_CONTROL").ok().as_deref() == Some("1") {
        let mut input = tokio::io::BufReader::new(tokio::io::stdin()).lines();
        loop {
            let command = tokio::select! {
                _ = tokio::signal::ctrl_c() => break,
                line = input.next_line() => match line? { Some(line) => line, None => break },
            };
            let result = match command.as_str() {
                "replace-text" => {
                    let path = root.join("demo-next.txt");
                    let size = tokio::fs::metadata(&path).await?.len();
                    paths.write().await.insert("text-next".into(), path);
                    server
                        .patch_web_workspace(
                            HashMap::from([(
                                "text-next".into(),
                                FileDto {
                                    id: "text-next".into(),
                                    file_name: "demo-next.txt".into(),
                                    size,
                                    file_type: "text/plain".into(),
                                    sha256: None,
                                    preview: None,
                                    metadata: None,
                                },
                            )]),
                            vec!["text".into()],
                        )
                        .await
                }
                "withdraw-text" => {
                    server
                        .patch_web_workspace(HashMap::new(), vec!["text-next".into()])
                        .await
                }
                "withdraw-markdown" => {
                    server
                        .patch_web_workspace(HashMap::new(), vec!["markdown".into()])
                        .await
                }
                _ => anyhow::bail!("Unknown fixture control"),
            };
            println!(
                "CONTROL {command} {}",
                if result.is_ok() { "ok" } else { "error" }
            );
        }
    } else {
        tokio::signal::ctrl_c().await?;
    }
    let _ = stop.send(());
    server.wait_stopped().await;
    Ok(())
}
