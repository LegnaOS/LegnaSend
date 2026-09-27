#![cfg(feature = "http")]
use localsend::{
    crypto::cert::generate_self_signed,
    http::client::{LsHttpClient, LsHttpClientV2, LsHttpClientVersion},
    model::discovery::ProtocolType,
};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio_util::sync::CancellationToken;
fn loopback() -> if_addrs::Interface {
    if_addrs::get_if_addrs()
        .unwrap()
        .into_iter()
        .find(|i| i.ip() == std::net::IpAddr::V4(std::net::Ipv4Addr::LOCALHOST))
        .unwrap()
}
#[test]
fn automatic_legacy_constructors_and_invalid_routes() {
    let c = generate_self_signed().unwrap();
    let lo = loopback();
    assert!(
        LsHttpClient::new(
            &c.private_key_pem,
            &c.certificate_pem,
            LsHttpClientVersion::V2,
            None,
            None
        )
        .is_ok()
    );
    assert!(
        LsHttpClient::new(
            &c.private_key_pem,
            &c.certificate_pem,
            LsHttpClientVersion::V3,
            None,
            None
        )
        .is_ok()
    );
    for (ip, name) in [
        (Some("127.0.0.1"), None),
        (None, Some(lo.name.as_str())),
        (Some("127.0.0.1"), Some("missing-legna-interface")),
        (Some("invalid"), Some(lo.name.as_str())),
        (Some("0.0.0.0"), Some(lo.name.as_str())),
        (Some("192.0.2.1"), Some(lo.name.as_str())),
        (Some("127.0.0.1%bad"), Some(lo.name.as_str())),
    ] {
        assert!(
            LsHttpClientV2::try_new_with_route(
                &c.private_key_pem,
                &c.certificate_pem,
                None,
                None,
                ip.map(str::to_owned),
                name.map(str::to_owned)
            )
            .is_err()
        );
    }
    let invalid = LsHttpClientV2::try_new_with_route(
        &c.private_key_pem,
        &c.certificate_pem,
        None,
        None,
        Some("::1%lo0".into()),
        Some(lo.name.clone()),
    )
    .err()
    .unwrap();
    assert!(invalid.to_string().starts_with("local-route-invalid:"));
    let unavailable = LsHttpClientV2::try_new_with_route(
        &c.private_key_pem,
        &c.certificate_pem,
        None,
        None,
        Some("192.0.2.1".into()),
        Some(lo.name.clone()),
    )
    .err()
    .unwrap();
    assert!(
        unavailable
            .to_string()
            .starts_with("local-route-unavailable:")
    );
    assert!(
        LsHttpClient::new_with_route(
            &c.private_key_pem,
            &c.certificate_pem,
            LsHttpClientVersion::V3,
            None,
            None,
            Some("127.0.0.1".into()),
            Some(lo.name)
        )
        .is_err()
    );
}
#[tokio::test]
async fn loopback_source_constraint_uploads_over_original_v2() {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let server = tokio::spawn(async move {
        let (mut socket, peer) = listener.accept().await.unwrap();
        assert_eq!(peer.ip(), std::net::Ipv4Addr::LOCALHOST);
        let mut bytes = Vec::new();
        loop {
            let mut byte = [0];
            socket.read_exact(&mut byte).await.unwrap();
            bytes.push(byte[0]);
            if bytes.ends_with(b"\r\n\r\n") {
                break;
            }
        }
        assert!(String::from_utf8_lossy(&bytes).starts_with("POST /api/localsend/v2/upload?"));
        let mut body = [0; 7];
        socket.read_exact(&mut body).await.unwrap();
        assert_eq!(&body, b"payload");
        socket
            .write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n{}")
            .await
            .unwrap();
    });
    let cert = generate_self_signed().unwrap();
    let client = LsHttpClientV2::try_new_with_route(
        &cert.private_key_pem,
        &cert.certificate_pem,
        None,
        None,
        Some("127.0.0.1".into()),
        Some(loopback().name),
    )
    .unwrap();
    client
        .upload(
            ProtocolType::Http,
            "127.0.0.1",
            port,
            None,
            "session",
            "file",
            "token",
            reqwest::Body::from("payload"),
            CancellationToken::new(),
        )
        .await
        .unwrap();
    server.await.unwrap();
}
