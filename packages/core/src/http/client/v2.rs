use super::{ClientError, ResponseExt, ResultWithPublicKey};
use crate::http::client::url::{ApiVersion, TargetUrl};
use crate::http::dto_v2::{
    InfoResponseDtoV2, PrepareDownloadResponseDtoV2, PrepareUploadRequestDtoV2,
    PrepareUploadResponseDtoV2, PrepareUploadResultV2, RegisterDtoV2, RegisterResponseDtoV2,
};
use crate::model::discovery::ProtocolType;
use futures_util::StreamExt;
use reqwest::{Response, StatusCode};
use tokio::io::AsyncWriteExt;
use tokio_util::sync::CancellationToken;

/// HTTP client for LocalSend Protocol v2.2.
pub struct LsHttpClientV2 {
    pub(super) client: reqwest::Client,
    route: Option<super::route::LocalRoute>,
}

impl LsHttpClientV2 {
    /// Creates a new HTTP client for v2.2 protocol.
    ///
    /// # Arguments
    /// * `private_key` - PEM-encoded private key for client certificate
    /// * `cert` - PEM-encoded certificate for client authentication
    /// * `expected_fingerprint` - SHA-256 fingerprint (uppercase hex) the peer
    ///   certificate must have. Enforced during the TLS handshake, so nothing
    ///   is sent to a mismatching peer. [`None`] accepts any valid certificate
    ///   and must only be used for discovery.
    /// * `timeout` - Optional total request timeout (e.g. for discovery scans)
    ///
    /// # Returns
    /// A new client instance or an error if TLS setup fails.
    pub fn try_new(
        private_key: &str,
        cert: &str,
        expected_fingerprint: Option<String>,
        timeout: Option<std::time::Duration>,
    ) -> Result<Self, ClientError> {
        Self::try_new_with_route(private_key, cert, expected_fingerprint, timeout, None, None)
    }

    pub fn try_new_with_route(
        private_key: &str,
        cert: &str,
        expected_fingerprint: Option<String>,
        timeout: Option<std::time::Duration>,
        local_address: Option<String>,
        interface_name: Option<String>,
    ) -> Result<Self, ClientError> {
        Self::try_new_with_network_route(
            private_key,
            cert,
            expected_fingerprint,
            timeout,
            local_address,
            interface_name,
            None,
            None,
        )
    }
    pub fn try_new_with_network_route(
        private_key: &str,
        cert: &str,
        expected_fingerprint: Option<String>,
        timeout: Option<std::time::Duration>,
        local_address: Option<String>,
        interface_name: Option<String>,
        android_network_handle: Option<String>,
        android_network_epoch: Option<String>,
    ) -> Result<Self, ClientError> {
        let route = super::route::LocalRoute::parse(local_address, interface_name)?;
        let route = match route {
            Some(route) => {
                Some(route.with_android_network(android_network_handle, android_network_epoch)?)
            }
            None if android_network_handle.is_some() || android_network_epoch.is_some() => {
                return Err(std::io::Error::new(
                    std::io::ErrorKind::InvalidInput,
                    "local-route-invalid: Android Network requires a source/interface",
                )
                .into());
            }
            None => None,
        };
        let client = super::create_reqwest_client_with_route(
            private_key,
            cert,
            expected_fingerprint,
            timeout,
            route.as_ref(),
        )?;
        Ok(Self { client, route })
    }
    pub(super) fn validate_route(&self) -> Result<(), ClientError> {
        self.route.as_ref().map_or(Ok(()), |route| route.validate())
    }

    /// Creates a new HTTP client without TLS client certificate.
    ///
    /// Use this for HTTP-only connections or when client authentication is not needed.
    pub fn try_new_without_cert() -> Result<Self, ClientError> {
        let _ = rustls::crypto::ring::default_provider().install_default();

        let client = reqwest::Client::builder()
            .use_rustls_tls()
            .danger_accept_invalid_certs(true)
            .tls_info(true)
            // Same as `create_reqwest_client`: peers are local, never proxy
            // and never redirect.
            .no_proxy()
            .redirect(reqwest::redirect::Policy::none())
            .build()?;

        Ok(Self {
            client,
            route: None,
        })
    }

    /// Registers with another device for discovery.
    ///
    /// POST /api/localsend/v2/register
    ///
    /// # Arguments
    /// * `protocol` - HTTP or HTTPS
    /// * `ip` - Target device IP address
    /// * `port` - Target device port
    /// * `payload` - Device information to register
    ///
    /// # Returns
    /// Registration result containing the remote device info and optional public key.
    pub async fn register(
        &self,
        protocol: ProtocolType,
        ip: &str,
        port: u16,
        payload: RegisterDtoV2,
    ) -> Result<ResultWithPublicKey<RegisterResponseDtoV2>, ClientError> {
        self.validate_route()?;
        let url = TargetUrl {
            version: ApiVersion::V2,
            protocol: protocol.as_str(),
            host: ip.to_string(),
            port,
            path: "/register",
            params: &[],
        }
        .to_string();

        let res = self
            .client
            .post(&url)
            .header("Content-Type", "application/json")
            .body(serde_json::to_string(&payload)?)
            .send()
            .await?;

        if res.status() != StatusCode::OK {
            return res.into_error().await;
        }

        let (public_key, cert_fingerprint) = match protocol {
            ProtocolType::Https => (
                Some(super::verify_cert_from_res(&res, None)?),
                Some(super::cert_fingerprint_from_res(&res)?),
            ),
            _ => (None, None),
        };

        let body = res.json::<RegisterResponseDtoV2>().await?;

        Ok(ResultWithPublicKey {
            public_key,
            cert_fingerprint,
            body,
        })
    }

    /// Prepares a file upload session with the receiver.
    ///
    /// POST /api/localsend/v2/prepare-upload
    ///
    /// The receiver will decide if this request gets accepted, partially accepted, or rejected.
    ///
    /// # Arguments
    /// * `protocol` - HTTP or HTTPS
    /// * `ip` - Receiver's IP address
    /// * `port` - Receiver's port
    /// * `public_key` - Expected public key for verification (HTTPS only)
    /// * `payload` - Upload request with device info and file metadata
    /// * `pin` - Optional PIN if required by receiver
    /// * `cancel` - Cancellation token; cancelling it aborts the request with
    ///   [`ClientError::Cancelled`]. Aborting closes the connection, which
    ///   tells the receiver that the sender is no longer waiting for a
    ///   decision.
    ///
    /// # Returns
    /// Session ID and accepted file tokens, or an error.
    ///
    /// # Errors
    /// * 204 - No file transfer needed (e.g. text-only transfer)
    /// * 400 - Invalid body
    /// * 401 - PIN required or invalid
    /// * 403 - Rejected by user
    /// * 409 - Blocked by another session
    /// * 429 - Too many requests
    /// * 500 - Unknown error
    pub async fn prepare_upload(
        &self,
        protocol: ProtocolType,
        ip: &str,
        port: u16,
        public_key: Option<String>,
        payload: PrepareUploadRequestDtoV2,
        pin: Option<&str>,
        cancel: CancellationToken,
    ) -> Result<PrepareUploadResultV2, ClientError> {
        let pin_params: &[(&'static str, &str)] = match &pin {
            Some(pin) => &[("pin", pin)],
            None => &[],
        };
        self.validate_route()?;
        let url = TargetUrl {
            version: ApiVersion::V2,
            protocol: protocol.as_str(),
            host: ip.to_string(),
            port,
            path: "/prepare-upload",
            params: pin_params,
        }
        .to_string();

        let send = self
            .client
            .post(&url)
            .header("Content-Type", "application/json")
            .body(serde_json::to_string(&payload)?)
            .send();

        let res = tokio::select! {
            res = send => res?,
            _ = cancel.cancelled() => return Err(ClientError::Cancelled),
        };

        if protocol == ProtocolType::Https {
            super::verify_cert_from_res(&res, public_key)?;
        }

        let status = res.status();

        if status.as_u16() >= 400 {
            return res.into_error().await;
        }

        if status == StatusCode::NO_CONTENT {
            return Ok(PrepareUploadResultV2 {
                status_code: status.as_u16(),
                response: None,
            });
        }

        let body = res.json::<PrepareUploadResponseDtoV2>().await?;

        Ok(PrepareUploadResultV2 {
            status_code: status.as_u16(),
            response: Some(body),
        })
    }

    /// Uploads a file to the receiver.
    ///
    /// POST /api/localsend/v2/upload?sessionId=...&fileId=...&token=...
    ///
    /// Use the session_id, file_id, and token from prepare_upload response.
    /// This method can be called in parallel for multiple files.
    ///
    /// # Arguments
    /// * `protocol` - HTTP or HTTPS
    /// * `ip` - Receiver's IP address
    /// * `port` - Receiver's port
    /// * `session_id` - Session ID from prepare_upload
    /// * `file_id` - File ID to upload
    /// * `token` - File-specific token from prepare_upload
    /// * `body` - The streaming request body carrying the file content
    /// * `cancel` - Cancellation token; cancelling it aborts the upload with [`ClientError::Cancelled`]
    ///
    /// # Errors
    /// * 400 - Missing parameters
    /// * 403 - Invalid token or IP address
    /// * 409 - Blocked by another session
    /// * 422 - Checksum mismatch
    /// * 500 - Unknown error
    pub async fn upload(
        &self,
        protocol: ProtocolType,
        ip: &str,
        port: u16,
        public_key: Option<String>,
        session_id: &str,
        file_id: &str,
        token: &str,
        body: reqwest::Body,
        cancel: CancellationToken,
    ) -> Result<(), ClientError> {
        self.validate_route()?;
        let url = TargetUrl {
            version: ApiVersion::V2,
            protocol: protocol.as_str(),
            host: ip.to_string(),
            port,
            path: "/upload",
            params: &[
                ("sessionId", session_id),
                ("fileId", file_id),
                ("token", token),
            ],
        }
        .to_string();

        let res = tokio::select! {
            res = self.client.post(&url).body(body).send() => res?,
            _ = cancel.cancelled() => return Err(ClientError::Cancelled),
        };

        if protocol == ProtocolType::Https {
            super::verify_cert_from_res(&res, public_key)?;
        }

        if res.status() != StatusCode::OK {
            return res.into_error().await;
        }

        // Some original peers return a small JSON acknowledgement rather than an
        // empty body. Dropping it at the headers discards HTTP/1 keep-alive and
        // can force a new TLS handshake for every tiny file.
        consume_upload_ack(res, &cancel).await
    }

    /// Cancels an ongoing file transfer session.
    ///
    /// POST /api/localsend/v2/cancel?sessionId=...
    ///
    /// # Arguments
    /// * `protocol` - HTTP or HTTPS
    /// * `ip` - Receiver's IP address
    /// * `port` - Receiver's port
    /// * `session_id` - Session ID to cancel
    pub async fn cancel(
        &self,
        protocol: ProtocolType,
        ip: &str,
        port: u16,
        session_id: &str,
    ) -> Result<(), ClientError> {
        self.validate_route()?;
        let url = TargetUrl {
            version: ApiVersion::V2,
            protocol: protocol.as_str(),
            host: ip.to_string(),
            port,
            path: "/cancel",
            params: &[("sessionId", session_id)],
        }
        .to_string();

        self.client.post(&url).send().await?;

        Ok(())
    }

    /// Gets device info from a remote device.
    ///
    /// GET /api/localsend/v2/info
    ///
    /// This is primarily for debugging purposes.
    ///
    /// # Arguments
    /// * `protocol` - HTTP or HTTPS
    /// * `ip` - Target device IP address
    /// * `port` - Target device port
    ///
    /// # Returns
    /// Device information including alias, version, device type, fingerprint, etc.
    pub async fn info(
        &self,
        protocol: ProtocolType,
        ip: &str,
        port: u16,
    ) -> Result<InfoResponseDtoV2, ClientError> {
        self.validate_route()?;
        let url = TargetUrl {
            version: ApiVersion::V2,
            protocol: protocol.as_str(),
            host: ip.to_string(),
            port,
            path: "/info",
            params: &[],
        }
        .to_string();

        let res = self.client.get(&url).send().await?;

        if res.status() != StatusCode::OK {
            return res.into_error().await;
        }

        let body = res.json::<InfoResponseDtoV2>().await?;

        Ok(body)
    }

    /// Prepares to download files from a sender (Download API).
    ///
    /// POST /api/localsend/v2/prepare-download
    ///
    /// This is used in reverse file transfer mode where the sender hosts the files
    /// and receivers download them.
    ///
    /// # Arguments
    /// * `protocol` - HTTP or HTTPS
    /// * `ip` - Sender's IP address
    /// * `port` - Sender's port
    /// * `session_id` - Optional existing session ID (for browser refresh scenarios)
    /// * `pin` - Optional PIN if required by sender
    ///
    /// # Returns
    /// Sender info, session ID, and available files.
    ///
    /// # Errors
    /// * 401 - PIN required or invalid
    /// * 403 - Rejected
    /// * 429 - Too many requests
    /// * 500 - Unknown error
    pub async fn prepare_download(
        &self,
        protocol: ProtocolType,
        ip: &str,
        port: u16,
        session_id: Option<&str>,
        pin: Option<&str>,
    ) -> Result<PrepareDownloadResponseDtoV2, ClientError> {
        let mut params: Vec<(&'static str, &str)> = Vec::new();
        if let Some(session_id) = session_id {
            params.push(("sessionId", session_id));
        }
        if let Some(pin) = pin {
            params.push(("pin", pin));
        }
        self.validate_route()?;
        let url = TargetUrl {
            version: ApiVersion::V2,
            protocol: protocol.as_str(),
            host: ip.to_string(),
            port,
            path: "/prepare-download",
            params: &params,
        }
        .to_string();

        let res = self.client.post(&url).send().await?;

        if res.status() != StatusCode::OK {
            return res.into_error().await;
        }

        let body = res.json::<PrepareDownloadResponseDtoV2>().await?;

        Ok(body)
    }

    /// Downloads a file from a sender (Download API).
    ///
    /// GET /api/localsend/v2/download?sessionId=...&fileId=...
    ///
    /// This method can be called in parallel for multiple files.
    ///
    /// # Arguments
    /// * `protocol` - HTTP or HTTPS
    /// * `ip` - Sender's IP address
    /// * `port` - Sender's port
    /// * `session_id` - Session ID from prepare_download
    /// * `file_id` - File ID to download
    ///
    /// # Returns
    /// Response containing the file data stream.
    pub async fn download(
        &self,
        protocol: ProtocolType,
        ip: &str,
        port: u16,
        session_id: &str,
        file_id: &str,
    ) -> Result<Response, ClientError> {
        self.validate_route()?;
        let url = TargetUrl {
            version: ApiVersion::V2,
            protocol: protocol.as_str(),
            host: ip.to_string(),
            port,
            path: "/download",
            params: &[("sessionId", session_id), ("fileId", file_id)],
        }
        .to_string();

        let res = self.client.get(&url).send().await?;

        if res.status() != StatusCode::OK {
            return res.into_error().await;
        }

        Ok(res)
    }

    /// Downloads a file to a writer (convenience method).
    ///
    /// # Arguments
    /// * `protocol` - HTTP or HTTPS
    /// * `ip` - Sender's IP address
    /// * `port` - Sender's port
    /// * `session_id` - Session ID from prepare_download
    /// * `file_id` - File ID to download
    /// * `writer` - AsyncWrite destination for file data
    ///
    /// # Returns
    /// Total bytes written.
    pub async fn download_to_writer<W: tokio::io::AsyncWrite + Unpin>(
        &self,
        protocol: ProtocolType,
        ip: &str,
        port: u16,
        session_id: &str,
        file_id: &str,
        writer: &mut W,
    ) -> Result<u64, ClientError> {
        let response = self
            .download(protocol, ip, port, session_id, file_id)
            .await?;

        let mut stream = response.bytes_stream();
        let mut total_bytes = 0u64;

        while let Some(chunk) = stream.next().await {
            let chunk = chunk?;
            writer.write_all(&chunk).await?;
            total_bytes += chunk.len() as u64;
        }

        writer.flush().await?;

        Ok(total_bytes)
    }
}

const UPLOAD_ACK_MAX_BYTES: u64 = 64 * 1024;
const UPLOAD_ACK_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(10);

/// Consume, but do not interpret or accumulate, an optional success body.
/// EOF is required: a truncated response or a bound violation is not success.
async fn consume_upload_ack(
    mut response: Response,
    cancel: &CancellationToken,
) -> Result<(), ClientError> {
    let too_large = || {
        std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            "Upload acknowledgement body exceeds 64 KiB",
        )
    };
    if response
        .content_length()
        .is_some_and(|length| length > UPLOAD_ACK_MAX_BYTES)
    {
        return Err(too_large().into());
    }
    let drain = async {
        let mut received = 0u64;
        while let Some(chunk) = response.chunk().await? {
            received = received.saturating_add(chunk.len() as u64);
            if received > UPLOAD_ACK_MAX_BYTES {
                return Err(ClientError::from(too_large()));
            }
        }
        Ok(())
    };
    tokio::select! {
        biased;
        result = tokio::time::timeout(UPLOAD_ACK_TIMEOUT, drain) => result.unwrap_or_else(|_| Err(std::io::Error::new(std::io::ErrorKind::TimedOut, "Upload acknowledgement body timed out").into())),
        _ = cancel.cancelled() => Err(ClientError::Cancelled),
    }
}

#[cfg(test)]
mod upload_ack_tests {
    use super::*;
    use bytes::Bytes;
    fn response(body: reqwest::Body) -> Response {
        hyper::Response::builder()
            .status(200)
            .body(body)
            .unwrap()
            .into()
    }
    #[tokio::test]
    async fn ready_eof_wins_simultaneous_cancel_but_pending_ack_is_cancelled() {
        let cancel = CancellationToken::new();
        cancel.cancel();
        assert!(
            consume_upload_ack(response(reqwest::Body::from("{}")), &cancel)
                .await
                .is_ok()
        );
        let pending = reqwest::Body::wrap_stream(futures_util::stream::pending::<
            Result<Bytes, std::io::Error>,
        >());
        assert!(matches!(
            consume_upload_ack(response(pending), &cancel).await,
            Err(ClientError::Cancelled)
        ));
    }
    #[tokio::test(start_paused = true)]
    async fn acknowledgement_deadline_is_total_and_does_not_wait_forever() {
        let body = reqwest::Body::wrap_stream(futures_util::stream::pending::<
            Result<Bytes, std::io::Error>,
        >());
        let start = tokio::time::Instant::now();
        assert!(
            matches!(consume_upload_ack(response(body),&CancellationToken::new()).await,Err(ClientError::Io(error)) if error.kind()==std::io::ErrorKind::TimedOut)
        );
        assert_eq!(start.elapsed(), UPLOAD_ACK_TIMEOUT);
    }
    #[tokio::test]
    async fn unknown_length_acknowledgement_enforces_exact_byte_limit() {
        for size in [UPLOAD_ACK_MAX_BYTES, UPLOAD_ACK_MAX_BYTES + 1] {
            let body =
                reqwest::Body::wrap_stream(futures_util::stream::iter([Ok::<_, std::io::Error>(
                    Bytes::from(vec![0; size as usize]),
                )]));
            let result = consume_upload_ack(response(body), &CancellationToken::new()).await;
            assert_eq!(result.is_ok(), size == UPLOAD_ACK_MAX_BYTES);
        }
    }
}
