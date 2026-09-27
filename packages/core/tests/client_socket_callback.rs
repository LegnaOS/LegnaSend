#![cfg(feature = "http")]
use std::{
    io,
    sync::{
        Arc,
        atomic::{AtomicUsize, Ordering},
    },
    time::Duration,
};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::TcpListener,
};

async fn endpoint(count: usize) -> (String, tokio::task::JoinHandle<()>) {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let url = format!("http://{}/", listener.local_addr().unwrap());
    let server = tokio::spawn(async move {
        for _ in 0..count {
            let (mut socket, _) = listener.accept().await.unwrap();
            let mut buf = vec![0; 4096];
            let mut len = 0;
            while !buf[..len].windows(4).any(|v| v == b"\r\n\r\n") {
                len += socket.read(&mut buf[len..]).await.unwrap();
            }
            socket
                .write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nOK")
                .await
                .unwrap();
        }
    });
    (url, server)
}

#[tokio::test]
async fn callback_runs_before_connect_for_each_new_socket_and_is_client_local() {
    let _ = rustls::crypto::ring::default_provider().install_default();
    let (url, server) = endpoint(3).await;
    let calls = Arc::new(AtomicUsize::new(0));
    let observed = calls.clone();
    let client = reqwest::Client::builder()
        .no_proxy()
        .socket_callback(move |socket| {
            assert!(
                socket.peer_addr().is_err(),
                "callback must run before connection establishment"
            );
            socket.set_tcp_nodelay(true)?;
            observed.fetch_add(1, Ordering::SeqCst);
            Ok(())
        })
        .build()
        .unwrap();
    for _ in 0..2 {
        assert_eq!(
            client.get(&url).send().await.unwrap().text().await.unwrap(),
            "OK"
        );
    }
    let other = reqwest::Client::builder().no_proxy().build().unwrap();
    assert_eq!(
        other.get(&url).send().await.unwrap().text().await.unwrap(),
        "OK"
    );
    server.await.unwrap();
    assert_eq!(calls.load(Ordering::SeqCst), 2);
}

#[tokio::test]
async fn binding_error_never_falls_back_or_opens_a_connection() {
    let _ = rustls::crypto::ring::default_provider().install_default();
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let url = format!("http://{}/", listener.local_addr().unwrap());
    let count = Arc::new(AtomicUsize::new(0));
    let c = count.clone();
    let client = reqwest::Client::builder()
        .no_proxy()
        .timeout(Duration::from_secs(2))
        .socket_callback(move |_| {
            c.fetch_add(1, Ordering::SeqCst);
            Err(io::Error::new(
                io::ErrorKind::AddrNotAvailable,
                "binding-rejected",
            ))
        })
        .build()
        .unwrap();
    let error = client.get(&url).send().await.unwrap_err();
    let mut source: &dyn std::error::Error = &error;
    let mut errors = String::new();
    loop {
        errors.push_str(&source.to_string());
        if let Some(next) = source.source() {
            source = next;
        } else {
            break;
        }
    }
    assert!(errors.contains("binding-rejected"), "{errors}");
    assert!(count.load(Ordering::SeqCst) > 0);
    assert!(
        tokio::time::timeout(Duration::from_millis(150), listener.accept())
            .await
            .is_err()
    );
    // A later independent unbound client still works; no process-global socket policy changed.
    let success = tokio::spawn(async move {
        let (mut socket, _) = listener.accept().await.unwrap();
        let mut request = [0; 4096];
        socket.read(&mut request).await.unwrap();
        socket
            .write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nOK")
            .await
            .unwrap();
    });
    assert_eq!(
        reqwest::Client::builder()
            .no_proxy()
            .build()
            .unwrap()
            .get(url)
            .send()
            .await
            .unwrap()
            .text()
            .await
            .unwrap(),
        "OK"
    );
    success.await.unwrap();
}

#[tokio::test]
async fn callback_is_preserved_through_tls_wrapping() {
    let _ = rustls::crypto::ring::default_provider().install_default();
    let cert = localsend::crypto::cert::generate_self_signed().unwrap();
    use rustls::pki_types::{CertificateDer, PrivateKeyDer, pem::PemObject};
    let tls = rustls::ServerConfig::builder()
        .with_no_client_auth()
        .with_single_cert(
            vec![CertificateDer::from_pem_slice(cert.certificate_pem.as_bytes()).unwrap()],
            PrivateKeyDer::from_pem_slice(cert.private_key_pem.as_bytes()).unwrap(),
        )
        .unwrap();
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let url = format!("https://{}/", listener.local_addr().unwrap());
    let server = tokio::spawn(async move {
        let (socket, _) = listener.accept().await.unwrap();
        let mut tls = tokio_rustls::TlsAcceptor::from(Arc::new(tls))
            .accept(socket)
            .await
            .unwrap();
        let mut request = [0; 4096];
        tls.read(&mut request).await.unwrap();
        tls.write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nOK")
            .await
            .unwrap();
    });
    let count = Arc::new(AtomicUsize::new(0));
    let c = count.clone();
    // Fixture certificates use device identities, not DNS names. This test only
    // checks connector wrapping; production certificate pinning stays unchanged.
    let client = reqwest::Client::builder()
        .no_proxy()
        .danger_accept_invalid_certs(true)
        .timeout(Duration::from_secs(3))
        .socket_callback(move |socket| {
            assert!(socket.peer_addr().is_err());
            c.fetch_add(1, Ordering::SeqCst);
            Ok(())
        })
        .build()
        .unwrap();
    assert_eq!(
        client.get(url).send().await.unwrap().text().await.unwrap(),
        "OK"
    );
    server.await.unwrap();
    assert_eq!(count.load(Ordering::SeqCst), 1);
}
