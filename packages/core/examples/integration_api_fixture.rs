//! Generated-fixture server. Policy commands use local stdin, not a public admin route.
use localsend::http::server::{
    integration::{ApiConfig, KeyRecord, Limits, Scope, WorkspaceGrant},
    start_with_port,
    web::WebConfig,
};
use localsend::http::state::ClientInfo;
use serde_json::json;
use sha2::{Digest, Sha256};
use std::{
    io::{self, BufRead},
    path::PathBuf,
};
use tokio::sync::oneshot;
#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let root = PathBuf::from(
        std::env::args()
            .nth(1)
            .expect("Generated fixture root required"),
    );
    // The test driver creates this secret in memory. Do not print or write it.
    let secret = std::env::var("LEGNASEND_FIXTURE_API_TOKEN")
        .map_err(|_| anyhow::anyhow!("Fixture token environment variable required"))?;
    let id = secret
        .split('.')
        .nth(1)
        .ok_or_else(|| anyhow::anyhow!("Invalid fixture token"))?
        .to_owned();
    let verifier = Sha256::digest(secret.as_bytes())
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect();
    let mut key = KeyRecord {
        id,
        name: "Local contract test".into(),
        verifier,
        grant: WorkspaceGrant {
            scopes: vec![
                Scope::Service,
                Scope::Workspaces,
                Scope::Files,
                Scope::Requests,
            ],
            workspaces: vec!["*".into()],
        },
        expires_at: None,
        created_at: 1,
        enabled: true,
        limits: None,
    };
    if std::env::var("LEGNASEND_FIXTURE_API_UPLOAD").as_deref() == Ok("1") {
        key.grant.scopes.push(Scope::Upload);
    }
    let (stop, rx) = oneshot::channel();
    let server = start_with_port(
        0,
        None,
        ClientInfo {
            alias: "Integration fixture".into(),
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
    .await?;
    server.configure_directory_workspaces(&json!({"revision":1,"enabled":true,"workspaces":[{"id":"11111111-1111-4111-8111-111111111111","name":"Public test","slug":"public","root":root.join("a"),"generation":1,"visible":true},{"id":"22222222-2222-4222-8222-222222222222","name":"Hidden test","slug":"hidden","root":root.join("b"),"generation":1,"visible":false}]}).to_string()).await?;
    let mut config = ApiConfig {
        revision: 1,
        enabled: true,
        global_limits: Limits {
            per_second: 1000,
            per_minute: 60000,
            concurrent: 16,
        },
        key_limits: Limits {
            per_second: 1000,
            per_minute: 60000,
            concurrent: 8,
        },
        keys: vec![key],
        ..ApiConfig::default()
    };
    server
        .configure_integration_api(&serde_json::to_string(&config)?)
        .await?;
    println!("http://127.0.0.1:{}/", server.port());
    for line in io::stdin().lock().lines() {
        let line = line?;
        if line == "quit" {
            break;
        }
        match line.as_str() {
            "anonymous" => config.auth_required = false,
            "revoke" => config.keys.clear(),
            "disable" => config.enabled = false,
            _ => continue,
        };
        config.revision += 1;
        println!(
            "{}",
            server
                .configure_integration_api(&serde_json::to_string(&config)?)
                .await?
        );
    }
    let _ = stop.send(());
    server.wait_stopped().await;
    Ok(())
}
