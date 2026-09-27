#![cfg(feature = "http")]
//! HTTP/1 response draining: real sockets, real TLS, and accepted connection counts.
use localsend::{
    crypto::cert::generate_self_signed,
    http::client::{ClientError, LsHttpClientV2},
    model::discovery::ProtocolType,
};
use rustls::pki_types::{CertificateDer, PrivateKeyDer, pem::PemObject};
use std::{
    sync::{
        Arc,
        atomic::{AtomicUsize, Ordering},
    },
    time::Duration,
};
use tokio::{
    io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt},
    net::TcpListener,
    sync::Notify,
};
use tokio_util::sync::CancellationToken;
#[derive(Clone, Copy)]
enum Reply {
    Empty,
    Length,
    Chunked,
    Truncated,
    TooLarge,
    ChunkedTooLarge,
    Endless,
}
struct Fixture {
    port: u16,
    protocol: ProtocolType,
    client: LsHttpClientV2,
    accepts: Arc<AtomicUsize>,
    requests: Arc<AtomicUsize>,
    headers_sent: Arc<Notify>,
    cancel: CancellationToken,
}
impl Fixture {
    async fn new(tls: bool, reply: Reply) -> Self {
        let identity = generate_self_signed().unwrap();
        let _ = rustls::crypto::ring::default_provider().install_default();
        let acceptor = if tls {
            let config = rustls::ServerConfig::builder()
                .with_no_client_auth()
                .with_single_cert(
                    vec![
                        CertificateDer::from_pem_slice(identity.certificate_pem.as_bytes())
                            .unwrap(),
                    ],
                    PrivateKeyDer::from_pem_slice(identity.private_key_pem.as_bytes()).unwrap(),
                )
                .unwrap();
            Some(tokio_rustls::TlsAcceptor::from(Arc::new(config)))
        } else {
            None
        };
        let client = LsHttpClientV2::try_new(
            &identity.private_key_pem,
            &identity.certificate_pem,
            tls.then_some(identity.fingerprint.clone()),
            None,
        )
        .unwrap();
        let listener = TcpListener::bind((std::net::Ipv4Addr::LOCALHOST, 0))
            .await
            .unwrap();
        let port = listener.local_addr().unwrap().port();
        let accepts = Arc::new(AtomicUsize::new(0));
        let requests = Arc::new(AtomicUsize::new(0));
        let headers_sent = Arc::new(Notify::new());
        let cancel = CancellationToken::new();
        let (counter, received, notified, stop) = (
            accepts.clone(),
            requests.clone(),
            headers_sent.clone(),
            cancel.clone(),
        );
        tokio::spawn(async move {
            let mut jobs = tokio::task::JoinSet::new();
            loop {
                tokio::select! {
                 _=stop.cancelled()=>{jobs.abort_all();break;},
                 Some(_)=jobs.join_next(),if !jobs.is_empty()=>{},
                 connection=listener.accept()=>{let Ok((socket,peer))=connection else{break};assert!(peer.ip().is_loopback());socket.set_nodelay(true).unwrap();counter.fetch_add(1,Ordering::SeqCst);let acceptor=acceptor.clone();let received=received.clone();let notified=notified.clone();jobs.spawn(async move {if let Some(acceptor)=acceptor{if let Ok(socket)=acceptor.accept(socket).await{let _=serve(socket,reply,received,notified).await;}}else{let _=serve(socket,reply,received,notified).await;}});}
                }
            }
        });
        Self {
            port,
            protocol: if tls {
                ProtocolType::Https
            } else {
                ProtocolType::Http
            },
            client,
            accepts,
            requests,
            headers_sent,
            cancel,
        }
    }
    async fn upload(&self, cancel: CancellationToken) -> Result<(), ClientError> {
        self.client
            .upload(
                self.protocol,
                "127.0.0.1",
                self.port,
                None,
                "session",
                "file",
                "token",
                localsend::reqwest::Body::from("payload"),
                cancel,
            )
            .await
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        self.cancel.cancel();
    }
}
async fn serve(
    mut socket: impl AsyncRead + AsyncWrite + Unpin,
    reply: Reply,
    requests: Arc<AtomicUsize>,
    headers_sent: Arc<Notify>,
) -> std::io::Result<()> {
    let mut buffered = Vec::<u8>::new();
    loop {
        let header_end = loop {
            if let Some(end) = buffered.windows(4).position(|w| w == b"\r\n\r\n") {
                break end + 4;
            }
            let mut read = [0; 4096];
            let n = socket.read(&mut read).await?;
            if n == 0 {
                return Ok(());
            }
            buffered.extend_from_slice(&read[..n]);
            assert!(buffered.len() < 16384);
        };
        let headers = std::str::from_utf8(&buffered[..header_end]).unwrap();
        assert!(headers.starts_with("POST /api/localsend/v2/upload?"));
        let length = headers
            .lines()
            .find_map(|line| {
                line.split_once(':')
                    .filter(|(key, _)| key.eq_ignore_ascii_case("content-length"))
                    .map(|(_, v)| v.trim().parse::<usize>().unwrap())
            })
            .unwrap();
        while buffered.len() < header_end + length {
            let mut read = [0; 4096];
            let n = socket.read(&mut read).await?;
            if n == 0 {
                return Ok(());
            }
            buffered.extend_from_slice(&read[..n]);
        }
        assert_eq!(&buffered[header_end..header_end + length], b"payload");
        buffered.drain(..header_end + length);
        requests.fetch_add(1, Ordering::SeqCst);
        let headers = match reply {
            Reply::Empty => "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n",
            Reply::Length | Reply::Truncated => {
                "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 2\r\n\r\n"
            }
            Reply::TooLarge => "HTTP/1.1 200 OK\r\nContent-Length: 65537\r\n\r\n",
            _ => "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n",
        };
        socket.write_all(headers.as_bytes()).await?;
        socket.flush().await?;
        headers_sent.notify_one();
        match reply {
            Reply::Empty => {}
            Reply::Length => {
                tokio::time::sleep(Duration::from_millis(10)).await;
                socket.write_all(b"{}").await?;
                socket.flush().await?;
            }
            Reply::Chunked => {
                tokio::time::sleep(Duration::from_millis(10)).await;
                socket.write_all(b"1\r\n{\r\n").await?;
                socket.flush().await?;
                tokio::time::sleep(Duration::from_millis(10)).await;
                socket.write_all(b"1\r\n}\r\n0\r\n\r\n").await?;
                socket.flush().await?;
            }
            Reply::Truncated => {
                socket.write_all(b"{").await?;
                socket.shutdown().await?;
                return Ok(());
            }
            Reply::ChunkedTooLarge => {
                socket.write_all(b"10001\r\n").await?;
                socket.write_all(&vec![0; 65537]).await?;
                socket.write_all(b"\r\n0\r\n\r\n").await?;
                socket.flush().await?;
            }
            Reply::TooLarge | Reply::Endless => {
                std::future::pending::<()>().await;
            }
        }
    }
}
async fn assert_reuses(tls: bool, reply: Reply) {
    let f = Fixture::new(tls, reply).await;
    for _ in 0..12 {
        f.upload(CancellationToken::new()).await.unwrap();
    }
    assert_eq!(f.requests.load(Ordering::SeqCst), 12);
    let accepted = f.accepts.load(Ordering::SeqCst);
    eprintln!("tls={tls} accepted={accepted} requests=12");
    assert_eq!(
        accepted, 1,
        "Each success body must be consumed before returning its socket to the client pool"
    );
}
#[tokio::test]
async fn content_length_ack_reuses_http_connection() {
    assert_reuses(false, Reply::Length).await;
}
#[tokio::test]
async fn chunked_ack_reuses_http_connection() {
    assert_reuses(false, Reply::Chunked).await;
}
#[tokio::test]
async fn content_length_ack_reuses_https_connection() {
    assert_reuses(true, Reply::Length).await;
}
#[tokio::test]
async fn chunked_ack_reuses_https_connection() {
    assert_reuses(true, Reply::Chunked).await;
}
#[tokio::test]
async fn empty_success_remains_compatible() {
    let f = Fixture::new(false, Reply::Empty).await;
    for _ in 0..12 {
        f.upload(CancellationToken::new()).await.unwrap();
    }
    assert_eq!(f.accepts.load(Ordering::SeqCst), 1);
}
#[tokio::test]
async fn malformed_or_oversized_success_body_is_not_false_success() {
    for reply in [Reply::Truncated, Reply::TooLarge, Reply::ChunkedTooLarge] {
        let f = Fixture::new(false, reply).await;
        let result =
            tokio::time::timeout(Duration::from_secs(1), f.upload(CancellationToken::new()))
                .await
                .unwrap();
        assert!(
            result.is_err(),
            "200 headers alone must not hide an invalid acknowledgement body"
        );
        assert_eq!(
            f.requests.load(Ordering::SeqCst),
            1,
            "Acknowledgement failure must not resend an upload"
        );
    }
}
#[tokio::test]
async fn cancellation_interrupts_a_success_body_that_never_finishes() {
    let f = Fixture::new(true, Reply::Endless).await;
    let cancel = CancellationToken::new();
    let control = async {
        f.headers_sent.notified().await;
        // Cancel after headers have had time to reach the client, not merely
        // while its original send() future is still awaiting those headers.
        tokio::time::sleep(Duration::from_millis(20)).await;
        cancel.cancel();
    };
    let (result, _) = tokio::time::timeout(Duration::from_secs(1), async {
        tokio::join!(f.upload(cancel.clone()), control)
    })
    .await
    .unwrap();
    assert!(matches!(result, Err(ClientError::Cancelled)));
}
