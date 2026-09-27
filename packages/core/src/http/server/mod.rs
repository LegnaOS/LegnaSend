mod archive;
pub mod common;
mod diagram_assets;
pub mod directories;
pub mod directory_auth;
pub mod integration;
pub mod internal;
mod peer_ip;
mod receive_resume;
pub mod v2;
pub mod v3;
pub mod web;

pub use peer_ip::PeerIp;
pub use receive_resume::RecoveryTargetLookup;
pub use web::activity::WebActivityHistory;

use crate::crypto::cert::{fingerprint_from_cert_der, public_key_from_cert_der};
use crate::http::server::internal::{InternalConfig, InternalState};
use crate::http::server::v2::ServerEventV2;
use crate::http::server::web::{WebConfig, WebShare};
use crate::http::state::ClientInfo;
use common::client_cert_verifier::CustomClientCertVerifier;
use common::error::AppError;
use common::response;
use common::response::BoxedBody;
use common::session::SessionStateV2;
use hyper::body::Incoming;
use hyper::{Method, Request, Response, StatusCode};
use hyper_util::rt::{TokioExecutor, TokioIo};
use hyper_util::server::conn::auto::Builder;
use lru::LruCache;
use rustls::pki_types::pem::PemObject;
use rustls::pki_types::{CertificateDer, PrivateKeyDer};
use std::fmt::Debug;
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr};
use std::num::NonZeroUsize;
use std::ops::Deref;
use std::sync::Arc;
use tokio::sync::{Mutex, mpsc, oneshot};
use tokio_util::sync::CancellationToken;
use tokio_util::task::TaskTracker;
use web::WebState;

/// Configuration for the v2 (legacy) protocol endpoints.
pub struct ServerConfigV2 {
    /// Optional PIN that senders must provide via the `pin` query parameter.
    pub pin: Option<String>,

    /// Whether the SHA-256 checksums that senders provide for their files are
    /// verified after receiving. When disabled, received files are not hashed
    /// and a mismatch is not detected.
    pub verify_checksums: bool,

    /// Channel on which the server emits events that must be handled by the application.
    pub event_tx: mpsc::Sender<ServerEventV2>,
}

/// Runtime state of the v2 protocol endpoints.
pub(crate) struct V2State {
    /// Optional PIN required for prepare-upload requests.
    pub(crate) pin: Option<String>,

    /// Whether sender-provided SHA-256 checksums are verified after receiving.
    pub(crate) verify_checksums: bool,

    /// Channel on which server events are emitted to the application.
    pub(crate) event_tx: mpsc::Sender<ServerEventV2>,

    /// The single upload session slot. Only one session can be active at a time.
    pub(crate) session: Mutex<Option<SessionStateV2>>,
    pub(crate) resumes: receive_resume::Registry,

    /// Wakes the one listener-owned idle watchdog after native activity.
    pub(crate) session_changed: tokio::sync::Notify,

    /// Terminates idle maintenance and obsolete event delivery on listener stop.
    pub(crate) stopped: CancellationToken,

    /// Maps client IPs to the number of failed PIN attempts.
    pub(crate) pin_attempts: Mutex<LruCache<IpAddr, u32>>,
}

#[derive(Clone)]
pub struct AppState {
    /// Information about server's device.
    info: Arc<Mutex<ClientInfo>>,

    /// Runtime state of the browser-facing pages and web download.
    web: Arc<WebState>,
    directories: Arc<directories::DirectoryRegistry>,
    integration: Arc<integration::Registry>,
    tls: bool,

    /// State for application-internal endpoints.
    internal: Option<Arc<InternalState>>,

    /// Maps client identifiers to nonces that have been received from remote.
    received_nonce_map: Arc<Mutex<LruCache<String, Vec<u8>>>>,

    /// Maps client identifiers to nonces that are expected to be received from remote.
    generated_nonce_map: Arc<Mutex<LruCache<String, Vec<u8>>>>,

    /// State of the v2 protocol endpoints. `None` disables the v2 routes.
    v2: Option<Arc<V2State>>,
}

impl AppState {
    fn new(
        info: Arc<Mutex<ClientInfo>>,
        internal_config: Option<InternalConfig>,
        v2_config: Option<ServerConfigV2>,
        web_config: WebConfig,
        tls: bool,
        activity_history: WebActivityHistory,
    ) -> Self {
        let v2 = v2_config.map(|config| {
            Arc::new(V2State {
                pin: config.pin,
                verify_checksums: config.verify_checksums,
                event_tx: config.event_tx,
                session: Mutex::new(None),
                resumes: receive_resume::Registry::default(),
                session_changed: tokio::sync::Notify::new(),
                stopped: CancellationToken::new(),
                pin_attempts: Mutex::new(LruCache::new(NonZeroUsize::new(200).unwrap())),
            })
        });

        let internal = internal_config.map(|config| Arc::new(InternalState::new(config)));

        let web = Arc::new(WebState::with_activity_history(
            web_config,
            activity_history,
        ));
        Self {
            info,
            tls,
            web: web.clone(),
            directories: Arc::new(directories::DirectoryRegistry::new(
                web.activities.clone(),
                v2.as_ref().map(|state| state.event_tx.clone()),
            )),
            integration: Arc::new(integration::Registry::new()),
            internal,
            received_nonce_map: Arc::new(Mutex::new(LruCache::new(
                NonZeroUsize::new(200).unwrap(),
            ))),
            generated_nonce_map: Arc::new(Mutex::new(LruCache::new(
                NonZeroUsize::new(200).unwrap(),
            ))),
            v2,
        }
    }
}

/// A handle to a running server for interactions initiated by the application
/// (as opposed to the event channels which are driven by incoming requests).
pub struct ServerHandle {
    cancel: CancellationToken,
    console: integration::console::Console,
    web: Arc<WebState>,
    directories: Arc<directories::DirectoryRegistry>,
    integration: Arc<integration::Registry>,
    v2: Option<Arc<V2State>>,

    /// The port the listeners are bound to.
    port: u16,

    /// Whether the IPv6 listener could be bound within the selected scope.
    ipv6_bound: bool,
    bind_scope: BindScope,

    /// The task running the accept loops. Completes after a stop has been
    /// requested, the listeners have been dropped and all connections have
    /// been closed.
    task: Mutex<Option<tokio::task::JoinHandle<()>>>,
}

impl ServerHandle {
    pub async fn supports_receive_recovery_target(
        &self,
        approved_directory: String,
        requested_name: String,
    ) -> anyhow::Result<bool> {
        receive_resume::supports_target(approved_directory, requested_name).await
    }

    pub async fn lookup_receive_recovery_target(
        &self,
        session_id: &str,
        file_id: &str,
        expected_attempt_id: &str,
        approved_directory: String,
        requested_name: String,
    ) -> anyhow::Result<RecoveryTargetLookup> {
        let v2 = self
            .v2
            .as_ref()
            .ok_or_else(|| anyhow::anyhow!("Server is stopped"))?;
        if v2.stopped.is_cancelled() {
            anyhow::bail!("Server is stopped");
        }
        v2.resumes
            .lookup_target(
                session_id,
                file_id,
                expected_attempt_id,
                approved_directory,
                requested_name,
            )
            .await
    }

    /// Host-only, bounded HTTP response activity; not browser save acknowledgements.
    pub fn web_download_activity(&self) -> String {
        self.web.activities.snapshot()
    }

    /// Cancels one HTTP response, preserving its approved session and other files.
    pub fn cancel_web_download(&self, id: &str) -> bool {
        self.web.activities.cancel(id)
    }

    /// Atomically withdraw selected files and publish fresh IDs, without restarting sessions.
    pub async fn patch_web_workspace(
        &self,
        files: std::collections::HashMap<String, crate::model::transfer::FileDto>,
        remove_file_ids: Vec<String>,
    ) -> anyhow::Result<()> {
        self.web.patch_files(files, remove_file_ids, None).await
    }

    /// The host opts in only after installing a persisted management event handler.
    pub fn set_workspace_management_available(&self, available: bool) {
        self.integration.set_management_available(available);
    }

    /// Execute a bounded local console request against this listener's real API.
    pub async fn integration_api_request(&self, request: &str) -> anyhow::Result<String> {
        self.console.execute(self.port, request).await
    }

    /// Owned local source is never part of external API JSON or request history.
    pub async fn integration_api_request_with_file(
        &self,
        request: &str,
        source: Option<std::fs::File>,
    ) -> anyhow::Result<String> {
        self.console
            .execute_with_file(self.port, request, source)
            .await
    }

    /// Replace only the temporary share, preserving directories, API and native sessions.
    pub fn set_web_mode(&self, mode: web::WebMode) {
        self.web.set_mode(mode);
    }

    /// Application-only API policy update; does not restart the listener.
    pub async fn configure_integration_api(&self, config: &str) -> anyhow::Result<String> {
        self.integration.configure(config)
    }

    /// Redacted local management snapshot, never includes credential verifiers.
    pub fn integration_api_snapshot(&self) -> String {
        self.integration.snapshot().to_string()
    }

    /// Application-only directory catalog update. No listener or legacy session restart.
    pub async fn configure_directory_workspaces(&self, config: &str) -> anyhow::Result<String> {
        self.directories.configure(config).await
    }

    /// Internal application control, never a remotely exposed configuration endpoint.
    /// Existing IDs cannot be replaced, keeping accepted sessions and reads stable.
    pub async fn update_web_workspace(
        &self,
        files: std::collections::HashMap<String, crate::model::transfer::FileDto>,
        allow_upload: bool,
    ) -> anyhow::Result<()> {
        self.web.append_files(files, allow_upload).await
    }

    /// The port the listeners are bound to. Relevant when the server was
    /// started with port 0, where the OS picks the port.
    pub fn port(&self) -> u16 {
        self.port
    }

    /// The socket addresses this server can be reached at: every address of
    /// the non-loopback interfaces, restricted to the address families that
    /// are actually bound. The listeners themselves only know the wildcard
    /// addresses, so the concrete addresses come from interface enumeration.
    ///
    /// Link-local IPv6 addresses are skipped: peers can only use them together
    /// with their own scope, which this device cannot know.
    ///
    /// Empty when the interfaces cannot be enumerated. An explicitly loopback-only
    /// listener instead returns only its actually bound loopback address families.
    pub fn local_addresses(&self) -> Vec<SocketAddr> {
        if matches!(self.bind_scope, BindScope::Loopback) {
            let mut addresses = vec![SocketAddr::new(Ipv4Addr::LOCALHOST.into(), self.port)];
            if self.ipv6_bound {
                addresses.push(SocketAddr::new(Ipv6Addr::LOCALHOST.into(), self.port));
            }
            return addresses;
        }
        let Ok(interfaces) = if_addrs::get_if_addrs() else {
            return Vec::new();
        };
        let mut addresses: Vec<SocketAddr> = interfaces
            .into_iter()
            .filter(|interface| !interface.is_loopback())
            .filter_map(|interface| match interface.ip() {
                IpAddr::V4(address) => Some(SocketAddr::new(address.into(), self.port)),
                IpAddr::V6(address) if self.ipv6_bound && !address.is_unicast_link_local() => {
                    Some(SocketAddr::new(address.into(), self.port))
                }
                IpAddr::V6(_) => None,
            })
            .collect();
        addresses.sort();
        addresses.dedup();
        addresses
    }

    /// Waits until the server task has terminated, the listeners are closed
    /// and all connections have been dropped, so that the port can be bound again.
    /// Must be called after requesting a stop via the stop channel.
    pub async fn wait_stopped(&self) {
        if let Some(task) = self.task.lock().await.take() {
            let _ = task.await;
        }
    }

    /// Private bridge operation: capture approved directory entries as owned files.
    pub async fn capture_workspace_sources(
        &self,
        workspace_id: &str,
        generation: u64,
        files: &str,
        destination: String,
    ) -> anyhow::Result<String> {
        self.directories
            .capture_sources(
                workspace_id,
                generation,
                files,
                destination,
                self.cancel.clone(),
            )
            .await
    }

    /// Cancels the active v2 upload session if it matches `session_id`,
    /// e.g. because the user aborted the transfer on the receiving side.
    ///
    /// CachedPath uploads stop and clean their uncommitted receive files.
    /// Legacy stream/path/descriptor targets retain their existing semantics;
    /// new requests fail and a new session can be created.
    /// No [ServerEventV2::SessionEnd] is emitted: the application initiated
    /// the cancellation itself.
    ///
    /// Returns `true` when a session was cancelled.
    pub async fn cancel_v2_session(&self, session_id: &str) -> bool {
        let Some(v2) = &self.v2 else {
            return false;
        };
        v2.resumes.revoke_session(session_id);
        let mut slot = v2.session.lock().await;
        match slot.as_ref() {
            Some(SessionStateV2::Active(session)) if session.session_id == session_id => {
                session.cancel.cancel();
                *slot = None;
                v2.session_changed.notify_one();
                true
            }
            _ => false,
        }
    }
}

/// Binds the server to the specified port on both IPv4 and IPv6 addresses.
pub async fn start_with_port(
    port: u16,
    tls_config: Option<TlsConfig>,
    info: ClientInfo,
    internal_config: Option<InternalConfig>,
    v2_config: Option<ServerConfigV2>,
    web_config: WebConfig,
    stop_rx: oneshot::Receiver<()>,
) -> anyhow::Result<ServerHandle> {
    start_with_port_policy(
        port,
        tls_config,
        info,
        internal_config,
        v2_config,
        web_config,
        stop_rx,
        false,
        WebActivityHistory::default(),
        BindScope::Wildcard,
    )
    .await
}

/// Starts on the preferred port, falling back only when it is already in use.
pub async fn start_with_port_or_available(
    port: u16,
    tls_config: Option<TlsConfig>,
    info: ClientInfo,
    internal_config: Option<InternalConfig>,
    v2_config: Option<ServerConfigV2>,
    web_config: WebConfig,
    stop_rx: oneshot::Receiver<()>,
) -> anyhow::Result<ServerHandle> {
    start_with_port_policy(
        port,
        tls_config,
        info,
        internal_config,
        v2_config,
        web_config,
        stop_rx,
        true,
        WebActivityHistory::default(),
        BindScope::Wildcard,
    )
    .await
}

/// Host opt-in for a bounded history surviving listener replacement. Ordinary
/// constructors remain isolated; callers must not share histories across users.
pub async fn start_with_port_or_available_with_activity_history(
    port: u16,
    tls_config: Option<TlsConfig>,
    info: ClientInfo,
    internal_config: Option<InternalConfig>,
    v2_config: Option<ServerConfigV2>,
    web_config: WebConfig,
    stop_rx: oneshot::Receiver<()>,
    activity_history: WebActivityHistory,
) -> anyhow::Result<ServerHandle> {
    start_with_port_policy(
        port,
        tls_config,
        info,
        internal_config,
        v2_config,
        web_config,
        stop_rx,
        true,
        activity_history,
        BindScope::Wildcard,
    )
    .await
}

/// Explicit loopback-only listener for host-local integrations and fixtures.
/// Uses the same original v2 server, without exposing a physical interface.
pub async fn start_loopback_with_port(
    port: u16,
    tls_config: Option<TlsConfig>,
    info: ClientInfo,
    internal_config: Option<InternalConfig>,
    v2_config: Option<ServerConfigV2>,
    web_config: WebConfig,
    stop_rx: oneshot::Receiver<()>,
) -> anyhow::Result<ServerHandle> {
    start_with_port_policy(
        port,
        tls_config,
        info,
        internal_config,
        v2_config,
        web_config,
        stop_rx,
        false,
        WebActivityHistory::default(),
        BindScope::Loopback,
    )
    .await
}

#[derive(Clone, Copy)]
enum BindScope {
    Wildcard,
    Loopback,
}
impl BindScope {
    fn ipv4(self) -> Ipv4Addr {
        match self {
            Self::Wildcard => Ipv4Addr::UNSPECIFIED,
            Self::Loopback => Ipv4Addr::LOCALHOST,
        }
    }
    fn ipv6(self) -> Ipv6Addr {
        match self {
            Self::Wildcard => Ipv6Addr::UNSPECIFIED,
            Self::Loopback => Ipv6Addr::LOCALHOST,
        }
    }
}

async fn start_with_port_policy(
    port: u16,
    tls_config: Option<TlsConfig>,
    info: ClientInfo,
    internal_config: Option<InternalConfig>,
    v2_config: Option<ServerConfigV2>,
    web_config: WebConfig,
    stop_rx: oneshot::Receiver<()>,
    fallback_on_conflict: bool,
    activity_history: WebActivityHistory,
    bind_scope: BindScope,
) -> anyhow::Result<ServerHandle> {
    // Installed before returning, so that a client built right after (which
    // skips the install when a provider exists) does not race the accept task.
    let _ = rustls::crypto::ring::default_provider().install_default();

    let ipv4_socket_addr = SocketAddr::new(bind_scope.ipv4().into(), port);
    let info = Arc::new(Mutex::new(info));
    let state = AppState::new(
        info.clone(),
        internal_config,
        v2_config,
        web_config,
        tls_config.is_some(),
        activity_history,
    );

    let ipv4_listener = match tokio::net::TcpListener::bind(ipv4_socket_addr).await {
        Ok(listener) => listener,
        Err(error) if fallback_on_conflict && error.kind() == std::io::ErrorKind::AddrInUse => {
            tracing::warn!("HTTP port {port} is occupied; requesting an available port");
            tokio::net::TcpListener::bind((bind_scope.ipv4(), 0)).await?
        }
        Err(error) => return Err(error.into()),
    };
    // With port 0, the IPv6 listener must reuse the port the IPv4 listener got.
    let ipv4_socket_addr = ipv4_listener.local_addr()?;
    let bound_port = ipv4_socket_addr.port();
    state.integration.set_port(bound_port);
    let ipv6_socket_addr = SocketAddr::new(bind_scope.ipv6().into(), bound_port);
    let ipv6_listener = match bind_ipv6_only(ipv6_socket_addr) {
        Ok(listener) => Some(listener),
        Err(err) => {
            tracing::warn!("Failed to start server on {}: {err:#}", ipv6_socket_addr);
            None
        }
    };
    let ipv6_bound = ipv6_listener.is_some();

    let cancel = CancellationToken::new();
    let connections = TaskTracker::new();

    let console = integration::console::Console::new(tls_config.clone(), cancel.clone());
    let task = tokio::spawn({
        let state = state.clone();
        let cancel = cancel.clone();
        let connections = connections.clone();
        let v2_event_tx = state.v2.as_ref().map(|v2| v2.event_tx.clone());
        async move {
            let v2_state = state.v2.clone();
            let directory_state = state.directories.clone();
            let idle_task = v2_state
                .as_ref()
                .map(|state| tokio::spawn(v2::watch_active_idle(state.clone())));
            tokio::select! {
                result = start_server_with_listener(ipv4_listener, tls_config.clone(), state.clone(), cancel.clone(), connections.clone()) => {
                    if let Err(err) = result {
                        tracing::error!("Server listener failed on {}: {err:#}", ipv4_socket_addr);
                        // Tell the application, so it can restart the server.
                        // `try_send` because this task must reach its end even
                        // when nobody consumes events anymore, so that
                        // `wait_stopped` cannot hang.
                        if let Some(event_tx) = v2_event_tx {
                            let _ = event_tx.try_send(ServerEventV2::ListenerFailed {
                                error: format!("{err:#}"),
                            });
                        }
                    }
                    tracing::info!("Server stopped on: {}", ipv4_socket_addr);
                }
                _ = async {
                    if let Some(listener) = ipv6_listener {
                        if let Err(err) = start_server_with_listener(listener, tls_config, state, cancel.clone(), connections.clone()).await {
                            tracing::error!("IPv6 server listener failed on {}: {err:#}", ipv6_socket_addr);
                        }
                    }

                    // Keep the future running forever, so we continue using "ipv4 only" even if ipv6 fails.
                    tokio::time::sleep(std::time::Duration::from_secs(u64::MAX)).await;
                } => {}
                _ = stop_rx => {}
            }

            // Hard-drop connections that are still being served, so that no
            // client keeps talking to the stopped server.
            cancel.cancel();
            directory_state.stop().await;
            if let Some(v2) = &v2_state {
                v2::stop_native_sessions(v2).await;
            }
            connections.close();
            connections.wait().await;
            if let Some(idle_task) = idle_task {
                let _ = idle_task.await;
            }
        }
    });

    Ok(ServerHandle {
        cancel,
        console,
        web: state.web.clone(),
        directories: state.directories.clone(),
        integration: state.integration.clone(),
        v2: state.v2.clone(),
        port: bound_port,
        ipv6_bound,
        bind_scope,
        task: Mutex::new(Some(task)),
    })
}

/// Binds an IPv6 listener with `IPV6_V6ONLY` enabled.
///
/// Without this flag, some systems (e.g. macOS) bind IPv6 wildcard sockets in
/// dual-stack mode, which conflicts with the separate IPv4 listener on the same port.
fn bind_ipv6_only(socket_addr: SocketAddr) -> anyhow::Result<tokio::net::TcpListener> {
    let socket = socket2::Socket::new(
        socket2::Domain::IPV6,
        socket2::Type::STREAM,
        Some(socket2::Protocol::TCP),
    )?;
    socket.set_only_v6(true)?;
    #[cfg(not(windows))]
    socket.set_reuse_address(true)?;
    socket.set_nonblocking(true)?;
    socket.bind(&socket_addr.into())?;
    socket.listen(1024)?;
    Ok(tokio::net::TcpListener::from_std(socket.into())?)
}

#[derive(Clone, Debug)]
pub struct TlsConfig {
    pub cert: String,
    pub private_key: String,
}

/// How long the accept loop waits after a failure that would repeat
/// immediately, doubling up to [`ACCEPT_BACKOFF_MAX`].
const ACCEPT_BACKOFF_MIN: std::time::Duration = std::time::Duration::from_millis(50);
const ACCEPT_BACKOFF_MAX: std::time::Duration = std::time::Duration::from_secs(1);

/// How many times in a row accepting may fail with a per-connection error
/// before the listener itself is considered broken. A healthy listener
/// interleaves such errors with successful accepts; only a dead one (e.g. a
/// socket the OS invalidated during app suspension, whose exact error code is
/// OS-specific) produces them in an endless, immediate sequence.
const ACCEPT_FAILURE_LIMIT: u32 = 100;

/// Whether the failed accept concerned only the connection being accepted, so
/// the next one can be attempted right away.
fn is_transient_accept_error(err: &std::io::Error) -> bool {
    matches!(
        err.kind(),
        std::io::ErrorKind::ConnectionAborted
            | std::io::ErrorKind::ConnectionReset
            | std::io::ErrorKind::Interrupted
    )
}

/// Whether the failed accept means the process momentarily ran out of
/// resources (a subnet scan opens a few hundred sockets), which resolves once
/// they are freed again.
fn is_resource_accept_error(err: &std::io::Error) -> bool {
    if err.kind() == std::io::ErrorKind::OutOfMemory {
        return true;
    }
    #[cfg(unix)]
    return matches!(
        err.raw_os_error(),
        Some(libc::EMFILE | libc::ENFILE | libc::ENOBUFS | libc::ENOMEM)
    );
    #[cfg(windows)]
    return matches!(
        err.raw_os_error(),
        Some(10024 /* WSAEMFILE */ | 10055 /* WSAENOBUFS */)
    );
    #[allow(unreachable_code)]
    false
}

async fn start_server_with_listener(
    incoming: tokio::net::TcpListener,
    tls_config: Option<TlsConfig>,
    app_state: AppState,
    cancel: CancellationToken,
    connections: TaskTracker,
) -> anyhow::Result<()> {
    // Browsers have no client certificate, so presenting one is optional while
    // the web pages are served. A certificate that is presented is still verified.
    let mandatory_client_auth = true;

    // Browser eligibility is selected for each new connection, so activating a
    // directory workspace does not force a listener restart. Presented peer
    // certificates still go through the existing verifier in both configurations.
    let browser_tls = tls_config
        .as_ref()
        .map(|tls| create_tls_config(tls, false))
        .transpose()?;
    let tls_acceptor = match tls_config {
        Some(tls_config) => Some(
            create_tls_config(&tls_config, mandatory_client_auth).inspect_err(|err| {
                tracing::error!("failed to create tls config: {err:#}");
            })?,
        ),
        None => None,
    };

    tracing::info!(
        "Started server on {} (TLS: {})",
        incoming.local_addr()?,
        tls_acceptor.is_some()
    );

    let mut accept_backoff = ACCEPT_BACKOFF_MIN;
    let mut accept_failures = 0u32;
    loop {
        let (tcp_stream, remote_addr) = match incoming.accept().await {
            Ok(accepted) => {
                accept_backoff = ACCEPT_BACKOFF_MIN;
                accept_failures = 0;
                // Disable Nagle: it delays small responses (reqwest already does this on the client side).
                let _ = accepted.0.set_nodelay(true);
                accepted
            }
            // Accepting fails for two kinds of reasons that say nothing about
            // the listener, which must both keep the loop alive: the peer went
            // away before the handshake completed (retried right away, but
            // bounded by [ACCEPT_FAILURE_LIMIT] because a listener the OS
            // invalidated during app suspension may report an OS-specific
            // error that looks per-connection), or the process momentarily ran
            // out of resources (a subnet scan opens a few hundred sockets).
            // Exhaustion would otherwise spin: the pending connection stays in
            // the backlog and fails again immediately, so back off before
            // retrying, without a limit — it says nothing about the listener,
            // however long it lasts.
            //
            // Every other error means the listening socket itself is broken.
            // Retrying that forever would leave the application believing it
            // can still receive, so give up and let the caller report it.
            Err(err) => {
                if is_resource_accept_error(&err) {
                    tracing::warn!("Could not accept a connection: {err:#}");
                    tokio::time::sleep(accept_backoff).await;
                    accept_backoff = (accept_backoff * 2).min(ACCEPT_BACKOFF_MAX);
                    continue;
                }
                accept_failures += 1;
                if is_transient_accept_error(&err) && accept_failures < ACCEPT_FAILURE_LIMIT {
                    tracing::warn!("Could not accept a connection: {err:#}");
                    continue;
                }
                return Err(anyhow::Error::from(err).context(format!(
                    "accepting connections failed {accept_failures} time(s) in a row"
                )));
            }
        };

        let tls_acceptor = if app_state
            .directories
            .enabled
            .load(std::sync::atomic::Ordering::Acquire)
            || !matches!(app_state.web.share(), WebShare::Disabled)
        {
            browser_tls.clone()
        } else {
            tls_acceptor.clone()
        };
        let app_state = app_state.clone();
        let cancel = cancel.clone();
        connections.spawn(async move {
            let serve = serve_connection(tcp_stream, remote_addr, tls_acceptor, app_state);
            tokio::select! {
                _ = serve => {}
                // Hard-drop the connection when the server is stopped.
                _ = cancel.cancelled() => {}
            }
        });
    }
}

async fn serve_connection(
    tcp_stream: tokio::net::TcpStream,
    remote_addr: SocketAddr,
    tls_acceptor: Option<tokio_rustls::TlsAcceptor>,
    app_state: AppState,
) {
    let res = match tls_acceptor {
        Some(tls_acceptor) => {
            let tls_stream = match tls_acceptor.accept(tcp_stream).await {
                Ok(tls_stream) => tls_stream,
                Err(err) => {
                    tracing::warn!("TLS handshake error: {err:#}");
                    return;
                }
            };

            let client_info = {
                let (_, server_connection) = tls_stream.get_ref();
                RequestClientInfo {
                    ip: PeerIp::from_remote_addr(&remote_addr),
                    // No certificate when client auth is optional (web pages served)
                    // and the client (e.g. a browser) did not present one.
                    cert: server_connection
                        .deref()
                        .deref()
                        .peer_certificates()
                        .and_then(|certs| certs.first().map(|cert| cert.to_vec())),
                }
            };

            Builder::new(TokioExecutor::new())
                .serve_connection(
                    TokioIo::new(tls_stream),
                    hyper::service::service_fn(move |mut req: Request<Incoming>| {
                        req.extensions_mut()
                            .insert::<RequestClientInfo>(client_info.clone());
                        req.extensions_mut().insert::<AppState>(app_state.clone());
                        handle_request(req)
                    }),
                )
                .await
        }
        None => {
            Builder::new(TokioExecutor::new())
                .serve_connection(
                    TokioIo::new(tcp_stream),
                    hyper::service::service_fn(move |mut req: Request<Incoming>| {
                        req.extensions_mut()
                            .insert::<RequestClientInfo>(RequestClientInfo {
                                ip: PeerIp::from_remote_addr(&remote_addr),
                                cert: None,
                            });
                        req.extensions_mut().insert::<AppState>(app_state.clone());
                        handle_request(req)
                    }),
                )
                .await
        }
    };

    if let Err(err) = res {
        tracing::warn!("Failed to serve connection: {err:#}");
    }
}

fn create_tls_config(
    tls_config: &TlsConfig,
    mandatory_client_auth: bool,
) -> anyhow::Result<tokio_rustls::TlsAcceptor> {
    let config = {
        let certs = vec![CertificateDer::from_pem_slice(&tls_config.cert.as_bytes())?];
        let key = PrivateKeyDer::from_pem_slice(&tls_config.private_key.as_bytes())?;

        rustls::ServerConfig::builder()
            .with_client_cert_verifier(Arc::new(CustomClientCertVerifier::try_new(
                &tls_config.cert,
                mandatory_client_auth,
            )?))
            .with_single_cert(certs, key)?
    };
    Ok(tokio_rustls::TlsAcceptor::from(Arc::new(config)))
}

#[derive(Clone, Debug)]
pub struct RequestClientInfo {
    /// The IP address of the client, including the IPv6 scope when present.
    ip: PeerIp,

    /// The client certificate in DER format.
    cert: Option<Vec<u8>>,
}

impl RequestClientInfo {
    /// The SHA-256 fingerprint (uppercase hex) of the client certificate
    /// verified during the mTLS handshake.
    /// `None` when the server runs without TLS.
    fn cert_fingerprint(&self) -> Option<String> {
        self.cert.as_deref().map(fingerprint_from_cert_der)
    }

    fn extract_public_key(&self) -> Option<String> {
        match &self.cert {
            Some(cert) => match public_key_from_cert_der(cert) {
                Ok(public_key) => Some(public_key),
                Err(err) => {
                    tracing::warn!("Failed to extract public key from certificate: {err:#}");
                    None
                }
            },
            None => None,
        }
    }

    fn identifier(&self) -> String {
        self.extract_public_key()
            .unwrap_or_else(|| self.ip.to_string())
    }
}

async fn handle_request(req: Request<Incoming>) -> Result<Response<BoxedBody>, hyper::Error> {
    Ok(handle_request_inner(req).await.unwrap_or_else(|err| {
        tracing::error!("Error handling request: {err:?}");
        err.to_response()
    }))
}

async fn handle_request_inner(mut req: Request<Incoming>) -> Result<Response<BoxedBody>, AppError> {
    let Some(state) = req.extensions_mut().remove::<AppState>() else {
        return Err(AppError::Status(StatusCode::INTERNAL_SERVER_ERROR));
    };

    let Some(client_info) = req.extensions_mut().remove::<RequestClientInfo>() else {
        return Err(AppError::Status(StatusCode::INTERNAL_SERVER_ERROR));
    };

    if let Some(mut response) = integration::route(&mut req, &state, &client_info).await {
        response::finish_rejected_directory_upload(&mut req, &mut response).await;
        return Ok(response);
    }
    if let Some(result) = directories::route(&mut req, &state, &client_info).await {
        let mut response = result.unwrap_or_else(|error| {
            tracing::error!("Error handling directory request: {error:?}");
            error.to_response()
        });
        response::finish_rejected_directory_upload(&mut req, &mut response).await;
        return Ok(response);
    }
    if req
        .uri()
        .path()
        .starts_with("/api/legnasend/v1/receive-resume/")
    {
        return receive_resume::route(req, state, client_info).await;
    }
    let v2_enabled = state.v2.is_some();

    match (req.method(), req.uri().path()) {
        (&Method::GET, "/" | "/share") => Ok(web::index(&state)),
        (&Method::GET, "/download") => Ok(web::direction_page(&state, false)),
        (&Method::GET, "/upload") => Ok(web::direction_page(&state, true)),
        (&Method::GET, "/web-status.json") => web::workspace_status(&state).await,
        (&Method::GET, "/i18n.json") => web::i18n(&state),
        (&Method::GET, path) if path.starts_with("/assets/vendor/diagrams/") => {
            web::diagram_asset(path)
        }
        (&Method::GET, "/assets/text-preview.js") => web::text_preview_script(&state),
        (
            &Method::GET,
            path @ ("/assets/theme.js"
            | "/assets/theme.css"
            | "/assets/web-ui.js"
            | "/assets/web-ui.css"
            | "/assets/web-i18n.js"
            | "/assets/workspace.js"
            | "/assets/web-upload.js"
            | "/assets/download-engine.js"
            | "/assets/download-ui.js"
            | "/assets/text-search.js"
            | "/assets/text-reader.css"
            | "/assets/sha256.js"
            | "/assets/ls-cache.js"
            | "/assets/download-registry.js"
            | "/assets/batch-downloads.js"
            | "/assets/persistent-downloads.js"
            | "/assets/persistent-download-ui.js"
            | "/assets/persistent-downloads.css"
            | "/assets/preview-support.js"
            | "/assets/media-preview.js"
            | "/assets/media-preview.css"
            | "/assets/image-source.js"
            | "/assets/image-preview.js"
            | "/assets/image-preview.css"
            | "/assets/diagram-preview.js"
            | "/assets/diagram-preview.css"
            | "/assets/diagram-frame.html"
            | "/assets/diagram-frame.js"
            | "/assets/diagram-frame.css"
            | "/assets/diagram-config.js"
            | "/assets/markdown-preview.js"
            | "/assets/markdown-worker.js"
            | "/assets/markdown-stream.js"
            | "/assets/markdown-stream-worker.js"
            | "/assets/markdown-blocks.js"
            | "/assets/markdown-inline-window.js"
            | "/assets/markdown-table-header.js"
            | "/assets/vendor/marked.umd.js"
            | "/assets/vendor/marked-LICENSE.txt"),
        ) => web::ui_asset(path),
        (&Method::GET | &Method::HEAD | &Method::POST, "/api/legnasend/v1/web/archive") => {
            web::archive(req, state, client_info).await
        }
        (&Method::POST, "/api/localsend/v2/prepare-download") => {
            web::prepare_download(req, state, client_info).await
        }
        (&Method::GET | &Method::HEAD, "/api/localsend/v2/download") => {
            web::download(req, state, client_info).await
        }
        (&Method::POST, "/api/localsend/v2/register") => {
            if !v2_enabled {
                return Err(AppError::Status(StatusCode::NOT_FOUND));
            }

            Ok(v2::register(req.into_body(), state, client_info)
                .await?
                .into_response())
        }
        // Old clients (v1.17 and earlier) probe unknown peers on the v1 route
        (&Method::GET, "/api/localsend/v1/info") | (&Method::GET, "/api/localsend/v2/info") => {
            if !v2_enabled {
                return Err(AppError::Status(StatusCode::NOT_FOUND));
            }

            Ok(v2::info(state).await?.into_response())
        }
        (&Method::POST, "/api/localsend/v2/prepare-upload") => {
            if !v2_enabled {
                return Err(AppError::Status(StatusCode::NOT_FOUND));
            }

            v2::prepare_upload(req, state, client_info).await
        }
        (&Method::POST, "/api/localsend/v2/upload") => {
            if !v2_enabled {
                return Err(AppError::Status(StatusCode::NOT_FOUND));
            }

            v2::upload(req, state, client_info).await
        }
        (&Method::POST, "/api/localsend/v2/cancel") => {
            if !v2_enabled {
                return Err(AppError::Status(StatusCode::NOT_FOUND));
            }

            v2::cancel(req, state, client_info).await
        }
        // The versioned path is retained for compatibility, but this endpoint is internal.
        (&Method::POST, "/api/localsend/v2/show") => internal::show(req, state).await,
        (&Method::POST, "/api/localsend/v3/nonce") => {
            Ok(v3::nonce_exchange(req.into_body(), state, client_info)
                .await?
                .into_response())
        }
        (&Method::POST, "/api/localsend/v3/register") => {
            Ok(v3::register(req.into_body(), state, client_info)
                .await?
                .into_response())
        }
        _ => {
            let mut res = Response::new(response::empty_body());
            *res.status_mut() = StatusCode::NOT_FOUND;
            Ok(res)
        }
    }
}
