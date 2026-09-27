//! Manual, real-app compatibility fixture; production v2 client and server.
//! Run with a test-output directory and the original app's HTTPS port.
use localsend::{
    crypto::{cert::generate_self_signed, hash::sha256_hex},
    http::{
        client::LsHttpClientV2,
        dto_v2::{PrepareUploadRequestDtoV2, RegisterDtoV2},
        server::{
            ServerConfigV2, TlsConfig,
            common::save::FileUploadTarget,
            start_with_port,
            v2::{PrepareUploadDecisionV2, ServerEventV2},
            web::WebConfig,
        },
        state::ClientInfo,
    },
    model::{
        discovery::{DeviceType, ProtocolType},
        transfer::FileDto,
    },
};
use std::{collections::HashMap, path::PathBuf, time::Duration};
use tokio::sync::{mpsc, oneshot};
use tokio_util::sync::CancellationToken;
#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let root = PathBuf::from(
        std::env::args()
            .nth(1)
            .expect("Test output directory required"),
    );
    std::fs::create_dir_all(&root)?;
    let peer_port: u16 = std::env::args().nth(2).unwrap_or("53317".into()).parse()?;
    let cert = generate_self_signed()?;
    let (events, mut receive) = mpsc::channel(16);
    let (stop, stopped) = oneshot::channel();
    let (done_tx, mut done_rx) = mpsc::channel(1);
    let handle = start_with_port(
        0,
        Some(TlsConfig {
            cert: cert.certificate_pem.clone(),
            private_key: cert.private_key_pem.clone(),
        }),
        ClientInfo {
            alias: "LegnaSend Interop Fixture".into(),
            version: "2.2".into(),
            device_model: Some("Isolated protocol test".into()),
            device_type: Some(DeviceType::Headless),
            token: cert.fingerprint.clone(),
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
    .await?;
    println!(
        "{}",
        serde_json::json!({"fixturePort":handle.port(),"protocol":"https","root":root})
    );
    tokio::spawn(async move {
        while let Some(event) = receive.recv().await {
            match event {
                ServerEventV2::PrepareUpload {
                    info,
                    ip,
                    files,
                    decision_tx,
                    cert_fingerprint,
                    ..
                } => {
                    println!(
                        "{}",
                        serde_json::json!({"incomingAlias":info.alias,"incomingVersion":info.version,"verifiedCertificate":cert_fingerprint.is_some(),"files":files})
                    );
                    if !ip.ip.is_loopback()
                        || files.len() != 1
                        || !files.values().all(|file| {
                            file.file_name == "LegnaSend-中文-😀.txt" && file.size == 47
                        })
                    {
                        let _ = decision_tx.send(PrepareUploadDecisionV2::Decline);
                        continue;
                    }
                    let accepted = files.keys().cloned().collect();
                    let _ = decision_tx.send(PrepareUploadDecisionV2::Accept(accepted));
                }
                ServerEventV2::FileUpload {
                    file, target_tx, ..
                } => {
                    // Test fixture writes only a leaf filename beneath its explicit output root.
                    let name = PathBuf::from(&file.file_name)
                        .file_name()
                        .unwrap()
                        .to_owned();
                    let path = root.join(name);
                    let (result_tx, result_rx) = oneshot::channel();
                    let _ = target_tx.send(FileUploadTarget::Path {
                        path: path.clone(),
                        result_tx,
                        progress_tx: None,
                    });
                    let done = done_tx.clone();
                    tokio::spawn(async move {
                        match result_rx.await {
                            Ok(Ok(())) => {
                                let bytes = std::fs::read(&path).unwrap();
                                println!(
                                    "{}",
                                    serde_json::json!({"receivedPath":path,"bytes":bytes.len(),"sha256":sha256_hex(&bytes)})
                                );
                                let _ = done.send(()).await;
                            }
                            other => eprintln!("receive failed: {other:?}"),
                        }
                    });
                }
                _ => {}
            }
        }
    });
    let discovery = LsHttpClientV2::try_new(
        &cert.private_key_pem,
        &cert.certificate_pem,
        None,
        Some(Duration::from_secs(10)),
    )?;
    let info = discovery
        .info(ProtocolType::Https, "127.0.0.1", peer_port)
        .await?;
    println!("{}", serde_json::json!({"originalPeer":info}));
    let client = LsHttpClientV2::try_new(
        &cert.private_key_pem,
        &cert.certificate_pem,
        Some(info.fingerprint.clone()),
        None,
    )?;
    let registration = RegisterDtoV2 {
        alias: "LegnaSend Interop Fixture".into(),
        version: "2.2".into(),
        device_model: Some("Isolated protocol test".into()),
        device_type: Some(DeviceType::Headless),
        fingerprint: cert.fingerprint,
        port: handle.port(),
        protocol: ProtocolType::Https,
        download: false,
    };
    client
        .register(
            ProtocolType::Https,
            "127.0.0.1",
            peer_port,
            registration.clone(),
        )
        .await?;
    let bytes = "LegnaSend to original LocalSend · 中文 😀\n"
        .as_bytes()
        .to_vec();
    let file = FileDto {
        id: "unicode".into(),
        file_name: "LegnaSend-中文-😀.txt".into(),
        size: bytes.len() as u64,
        file_type: "text/plain".into(),
        sha256: Some(sha256_hex(&bytes)),
        preview: None,
        metadata: None,
    };
    println!("Waiting for original app receive approval");
    let result = client
        .prepare_upload(
            ProtocolType::Https,
            "127.0.0.1",
            peer_port,
            None,
            PrepareUploadRequestDtoV2 {
                info: registration,
                files: HashMap::from([("unicode".into(), file)]),
            },
            None,
            CancellationToken::new(),
        )
        .await?;
    let response = result
        .response
        .ok_or_else(|| anyhow::anyhow!("Original peer accepted no file"))?;
    client
        .upload(
            ProtocolType::Https,
            "127.0.0.1",
            peer_port,
            None,
            &response.session_id,
            "unicode",
            &response.files["unicode"],
            localsend::reqwest::Body::from(bytes.clone()),
            CancellationToken::new(),
        )
        .await?;
    println!(
        "{}",
        serde_json::json!({"sentToOriginal":true,"bytes":bytes.len(),"sha256":sha256_hex(&bytes)})
    );
    println!("Use original app Send UI to send a fixture file to LegnaSend Interop Fixture");
    tokio::time::timeout(Duration::from_secs(600), done_rx.recv()).await?;
    let _ = stop.send(());
    Ok(())
}
