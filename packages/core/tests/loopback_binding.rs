#![cfg(feature = "http")]
use localsend::http::{
    server::{start_loopback_with_port, web::WebConfig},
    state::ClientInfo,
};
use std::net::{IpAddr, Ipv4Addr};
use tokio::sync::oneshot;
#[tokio::test]
async fn explicit_loopback_only_reports_bound_loopback_addresses_and_serves_both_families() {
    let (stop, rx) = oneshot::channel();
    let server = start_loopback_with_port(
        0,
        None,
        ClientInfo {
            alias: "Loopback fixture".into(),
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
    let addresses = server.local_addresses();
    assert!(!addresses.is_empty());
    assert_eq!(addresses[0].ip(), IpAddr::V4(Ipv4Addr::LOCALHOST));
    let client = localsend::reqwest::Client::builder()
        .no_proxy()
        .build()
        .unwrap();
    for address in &addresses {
        assert!(address.ip().is_loopback());
        assert_eq!(address.port(), server.port());
        assert_eq!(
            client
                .get(format!("http://{address}/"))
                .send()
                .await
                .unwrap()
                .status(),
            403
        );
    }
    // A physical address must not reach this explicitly loopback-only listener.
    if let Some(ip) = if_addrs::get_if_addrs()
        .unwrap()
        .into_iter()
        .map(|i| i.ip())
        .find(|ip| ip.is_ipv4() && !ip.is_loopback())
    {
        // A firewall may drop rather than reject a local physical-address
        // connection. Either outcome is unreachable; only a live socket fails.
        assert!(!matches!(
            tokio::time::timeout(
                std::time::Duration::from_secs(1),
                tokio::net::TcpStream::connect((ip, server.port()))
            )
            .await,
            Ok(Ok(_))
        ));
    }
    stop.send(()).unwrap();
    server.wait_stopped().await;
}
