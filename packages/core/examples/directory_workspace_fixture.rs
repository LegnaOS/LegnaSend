//! Local generated-directory fixture; lifecycle control uses stdin, not a public admin API.
use localsend::http::server::{ServerConfigV2, start_with_port, v2::ServerEventV2, web::WebConfig};
use localsend::http::state::ClientInfo;
use serde_json::json;
use std::{
    collections::HashMap,
    sync::{Arc, Mutex},
};
use std::{
    io::{self, BufRead},
    path::PathBuf,
};
use tokio::sync::{mpsc, oneshot};

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let root = PathBuf::from(
        std::env::args()
            .nth(1)
            .expect("generated fixture root required"),
    );
    let (stop, rx) = oneshot::channel();
    let approval_enabled = std::env::var("LEGNASEND_FIXTURE_APPROVAL").as_deref() == Ok("1");
    let pending: Arc<Mutex<HashMap<String, oneshot::Sender<bool>>>> =
        Arc::new(Mutex::new(HashMap::new()));
    let (event_tx, mut events) = mpsc::channel(32);
    if approval_enabled {
        let pending = pending.clone();
        tokio::spawn(async move {
            while let Some(event) = events.recv().await {
                match event {
                    ServerEventV2::DirectoryUploadApproval {
                        request_id,
                        request,
                        decision_tx,
                    } => {
                        let request: serde_json::Value = serde_json::from_str(&request).unwrap();
                        pending
                            .lock()
                            .unwrap()
                            .insert(request_id.clone(), decision_tx);
                        println!(
                            "{}",
                            json!({"approval":request_id,"count":request["files"].as_array().map(Vec::len),"expiresAt":request["expiresAt"]})
                        );
                    }
                    ServerEventV2::DirectoryUploadApprovalAborted { request_id } => {
                        pending.lock().unwrap().remove(&request_id);
                        println!("{}", json!({"aborted":request_id}));
                    }
                    _ => {}
                }
            }
        });
    }

    let server = start_with_port(
        std::env::var("LEGNASEND_FIXTURE_PORT")
            .ok()
            .and_then(|v| v.parse().ok())
            .unwrap_or(0),
        None,
        ClientInfo {
            alias: "Directory fixture".into(),
            version: "2.2".into(),
            device_model: None,
            device_type: None,
            token: "fixture".into(),
        },
        None,
        approval_enabled.then_some(ServerConfigV2 {
            pin: None,
            verify_checksums: false,
            event_tx,
        }),
        WebConfig::default(),
        rx,
    )
    .await?;
    let upload_enabled = std::env::var("LEGNASEND_FIXTURE_UPLOAD").as_deref() == Ok("1");
    let mut a = json!({"id":"11111111-1111-4111-8111-111111111111","name":"设计资源 · Design","slug":"design","root":root.join("a"),"generation":1,"visible":true,"allowUpload":upload_enabled,"uploadApproval":approval_enabled});
    let b = json!({"id":"22222222-2222-4222-8222-222222222222","name":"私人资料 · Private","slug":"private","root":root.join("b"),"generation":1,"visible":false});
    let mut revision = 1;
    server
        .configure_directory_workspaces(
            &json!({"revision":revision,"enabled":true,"workspaces":[a.clone(),b.clone()]})
                .to_string(),
        )
        .await?;
    println!("http://127.0.0.1:{}/", server.port());
    for line in io::stdin().lock().lines() {
        let line = line?;
        if line == "quit" {
            break;
        }
        if let Some((decision, id)) = line.split_once(' ') {
            if matches!(decision, "approve" | "reject") {
                let sender = pending.lock().unwrap().remove(id);
                let delivered =
                    sender.is_some_and(|sender| sender.send(decision == "approve").is_ok());
                println!("{}", json!({"decision":id,"delivered":delivered}));
                continue;
            }
        }
        revision += 1;
        let entries = match line.as_str() {
            "close-a" => vec![b.clone()],
            "restore" => vec![a.clone(), b.clone()],
            "disable-upload" | "enable-upload" => {
                a["generation"] = json!(a["generation"].as_u64().unwrap() + 1);
                a["allowUpload"] = json!(line == "enable-upload");
                vec![a.clone(), b.clone()]
            }
            "protect-a" | "rotate-a" => {
                a["generation"] = json!(a["generation"].as_u64().unwrap() + 1);
                let password = if line == "protect-a" {
                    "fixture-password"
                } else {
                    "changed-password"
                };
                a["passwordHash"] = json!(
                    localsend::http::server::directory_auth::hash_password(password.into()).await?
                );
                vec![a.clone(), b.clone()]
            }
            _ => continue,
        };
        println!(
            "{}",
            server
                .configure_directory_workspaces(
                    &json!({"revision":revision,"enabled":true,"workspaces":entries}).to_string()
                )
                .await?
        );
    }
    let _ = stop.send(());
    server.wait_stopped().await;
    Ok(())
}
