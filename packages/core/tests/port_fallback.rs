#![cfg(feature = "http")]
use localsend::http::server::web::WebConfig;
use localsend::http::server::{start_with_port, start_with_port_or_available};
use localsend::http::state::ClientInfo;
use tokio::sync::oneshot;

fn info() -> ClientInfo {
    ClientInfo {
        alias: "Coexistence test".into(),
        version: "2.2".into(),
        device_model: None,
        device_type: None,
        token: "test".into(),
    }
}

#[tokio::test]
async fn occupied_preferred_port_falls_back_without_stealing_the_listener() {
    let occupied = std::net::TcpListener::bind((std::net::Ipv4Addr::UNSPECIFIED, 0)).unwrap();
    let preferred = occupied.local_addr().unwrap().port();
    let (_tx, rx) = oneshot::channel();
    let server = start_with_port_or_available(
        preferred,
        None,
        info(),
        None,
        None,
        WebConfig::default(),
        rx,
    )
    .await
    .unwrap();
    assert_ne!(server.port(), preferred);
    assert_ne!(server.port(), 0);
    assert_eq!(occupied.local_addr().unwrap().port(), preferred);
    let response = localsend::reqwest::Client::new()
        .get(format!("http://127.0.0.1:{}/", server.port()))
        .send()
        .await
        .unwrap();
    assert_eq!(response.status().as_u16(), 403); // live server, sharing disabled
}

#[tokio::test]
async fn strict_port_api_still_reports_conflicts() {
    let occupied = std::net::TcpListener::bind((std::net::Ipv4Addr::UNSPECIFIED, 0)).unwrap();
    let (_tx, rx) = oneshot::channel();
    assert!(start_with_port(
        occupied.local_addr().unwrap().port(),
        None,
        info(),
        None,
        None,
        WebConfig::default(),
        rx
    )
    .await
    .is_err());
}
