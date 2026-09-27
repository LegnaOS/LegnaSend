//! Local application request console. Uses real HTTP and the existing pinned TLS client.
use super::PREFIX;
use super::contract::{OPERATIONS, Operation};
use crate::http::server::TlsConfig;
use percent_encoding::{NON_ALPHANUMERIC, utf8_percent_encode};
use rustls::pki_types::{CertificateDer, pem::PemObject};
use serde::Deserialize;
use serde_json::json;
use std::{
    collections::BTreeMap,
    fs::File,
    path::Path,
    time::{Duration, Instant},
};
use tokio::sync::{OnceCell, Semaphore};
use tokio_util::sync::CancellationToken;

const PATH_ESCAPE: &percent_encoding::AsciiSet = &NON_ALPHANUMERIC
    .remove(b'-')
    .remove(b'_')
    .remove(b'.')
    .remove(b'~');
const MAX_BODY: usize = 256 * 1024;
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Request {
    operation: String,
    #[serde(default)]
    head: bool,
    #[serde(default)]
    parameters: BTreeMap<String, String>,
    #[serde(default)]
    token: String,
    range: Option<String>,
    if_match: Option<String>,
    upload_path: Option<String>,
    upload_size: Option<u64>,
    body: Option<serde_json::Value>,
}
impl Request {
    fn parse(raw: &str) -> anyhow::Result<(Self, Operation)> {
        anyhow::ensure!(
            raw.len() <= 2 * 1024 * 1024 + 16 * 1024,
            "Console request too large"
        );
        let request: Self =
            serde_json::from_str(raw).map_err(|_| anyhow::anyhow!("Invalid console request"))?;
        let operation = OPERATIONS
            .into_iter()
            .find(|op| op.id() == request.operation)
            .ok_or_else(|| anyhow::anyhow!("Unknown console operation"))?;
        let raw_limit = match operation {
            Operation::PrepareArchive => 2 * 1024 * 1024 + 16 * 1024,
            Operation::WorkspaceSend => 72 * 1024,
            Operation::WorkspaceState | Operation::Files => 24 * 1024,
            _ => 16 * 1024,
        };
        anyhow::ensure!(raw.len() <= raw_limit, "Console request too large");
        anyhow::ensure!(
            !request.head || matches!(operation, Operation::Content | Operation::Archive),
            "Invalid console method"
        );
        anyhow::ensure!(
            request.token.len() <= 512 && request.token.bytes().all(|c| (33..=126).contains(&c)),
            "Invalid credential"
        );
        for (name, value) in &request.parameters {
            anyhow::ensure!(
                super::contract::valid_parameter_text(operation, name, value),
                "Invalid console parameter"
            );
            let in_path = operation.path().contains(&format!("{{{name}}}"));
            anyhow::ensure!(
                in_path || operation.queries().contains(&name.as_str()),
                "Unknown console parameter"
            );
        }
        anyhow::ensure!(
            operation != Operation::Archive
                || !request.parameters.contains_key("selection")
                || !(request.parameters.contains_key("path")
                    || request.parameters.contains_key("ids")),
            "Ticket and inline selection are exclusive"
        );
        let mut query = form_urlencoded::Serializer::new(String::new());
        for (name, value) in &request.parameters {
            if operation.queries().contains(&name.as_str()) {
                query.append_pair(name, value);
            }
        }
        anyhow::ensure!(
            query.finish().len() <= super::contract::query_byte_limit(operation),
            "Console query too large"
        );
        for field in [&request.range, &request.if_match].into_iter().flatten() {
            anyhow::ensure!(
                field.len() <= 1024 && reqwest::header::HeaderValue::from_str(field).is_ok(),
                "Invalid console header"
            );
        }
        anyhow::ensure!(
            operation == Operation::Content
                || (request.range.is_none() && request.if_match.is_none()),
            "Unexpected console header"
        );
        anyhow::ensure!(
            operation == Operation::Upload
                || (request.upload_path.is_none() && request.upload_size.is_none()),
            "Unexpected upload source"
        );
        if let Some(path) = &request.upload_path {
            anyhow::ensure!(
                path.len() <= 8192
                    && Path::new(path).is_absolute()
                    && !path.chars().any(char::is_control),
                "Invalid upload source"
            );
        }
        anyhow::ensure!(
            request.body.is_none()
                || matches!(
                    operation,
                    Operation::ManageWorkspace
                        | Operation::CreateWorkspace
                        | Operation::SendTransfer
                        | Operation::RetryTransfer
                        | Operation::UpdateSettings
                        | Operation::CreateKey
                        | Operation::ManageKey
                        | Operation::ClearRequests
                        | Operation::ControlNativeTask
                        | Operation::RetrySourceEndNotice
                        | Operation::WorkspaceSend
                        | Operation::PrepareArchive
                        | Operation::CancelArchive
                        | Operation::PreparePreview
                        | Operation::ClosePreview
                ),
            "Unexpected request body"
        );
        anyhow::ensure!(
            request.body.as_ref().is_none_or(|body| body.is_object()
                && body.to_string().len()
                    <= if operation == Operation::PrepareArchive {
                        2 * 1024 * 1024
                    } else if operation == Operation::WorkspaceSend {
                        65536
                    } else {
                        8192
                    }),
            "Invalid management body"
        );
        if matches!(
            operation,
            Operation::PreparePreview | Operation::ClosePreview
        ) {
            let field = if operation == Operation::PreparePreview {
                "id"
            } else {
                "lease"
            };
            let body = request
                .body
                .as_ref()
                .and_then(|v| v.as_object())
                .ok_or_else(|| anyhow::anyhow!("Preview body required"))?;
            anyhow::ensure!(
                body.len() == 1
                    && body.get(field).and_then(|v| v.as_str()).is_some_and(|v| {
                        uuid::Uuid::parse_str(v).is_ok_and(|id| id.to_string() == v)
                    }),
                "Invalid preview body"
            );
        }
        if matches!(
            operation,
            Operation::PrepareArchive | Operation::CancelArchive
        ) {
            let body = request
                .body
                .as_ref()
                .and_then(|v| v.as_object())
                .ok_or_else(|| anyhow::anyhow!("Archive body required"))?;
            if operation == Operation::CancelArchive {
                anyhow::ensure!(
                    body.len() == 1
                        && body
                            .get("selection")
                            .and_then(|v| v.as_str())
                            .is_some_and(
                                |v| uuid::Uuid::parse_str(v).is_ok_and(|id| id.to_string() == v)
                            ),
                    "Invalid archive ticket"
                );
            } else {
                let path = body
                    .get("path")
                    .and_then(|v| v.as_str())
                    .ok_or_else(|| anyhow::anyhow!("Archive parent required"))?;
                let ids = body
                    .get("ids")
                    .and_then(|v| v.as_array())
                    .ok_or_else(|| anyhow::anyhow!("Archive IDs required"))?;
                let mut seen = std::collections::HashSet::new();
                anyhow::ensure!(
                    body.len() == 2
                        && path.len() <= 4096
                        && !path.contains('\0')
                        && !ids.is_empty()
                        && ids.len() <= 20000
                        && ids
                            .iter()
                            .all(|v| v.as_str().is_some_and(|id| !id.is_empty()
                                && id.len() <= 4096
                                && !id.chars().any(char::is_control)
                                && seen.insert(id))),
                    "Invalid archive selection"
                );
            }
        }
        if operation.is_transfer() {
            super::transfer_management::validate_payload(operation, request.body.as_ref())
                .map_err(|_| anyhow::anyhow!("Invalid transfer body"))?;
        }
        Ok((request, operation))
    }
    fn path(&self, operation: Operation) -> anyhow::Result<String> {
        let mut path = operation.path().to_owned();
        for name in [
            "workspaceId",
            "fileId",
            "deviceId",
            "transferId",
            "keyId",
            "requestId",
            "taskId",
            "noticeId",
        ] {
            let placeholder = format!("{{{name}}}");
            if path.contains(&placeholder) {
                let value = self
                    .parameters
                    .get(name)
                    .filter(|v| !v.is_empty())
                    .ok_or_else(|| anyhow::anyhow!("Missing path parameter"))?;
                anyhow::ensure!(
                    !matches!(value.as_str(), "." | ".."),
                    "Invalid path parameter"
                );
                path = path.replace(
                    &placeholder,
                    &utf8_percent_encode(value, PATH_ESCAPE).to_string(),
                );
            }
        }
        Ok(path)
    }
}

pub(crate) struct Console {
    tls: Option<TlsConfig>,
    client: OnceCell<reqwest::Client>,
    upload_client: OnceCell<reqwest::Client>,
    slot: Semaphore,
    stopped: CancellationToken,
}
impl Console {
    pub(crate) fn new(tls: Option<TlsConfig>, stopped: CancellationToken) -> Self {
        Self {
            tls,
            client: OnceCell::new(),
            upload_client: OnceCell::new(),
            slot: Semaphore::new(1),
            stopped,
        }
    }
    pub(crate) async fn execute(&self, port: u16, raw: &str) -> anyhow::Result<String> {
        self.execute_with_file(port, raw, None).await
    }
    pub(crate) async fn execute_with_file(
        &self,
        port: u16,
        raw: &str,
        owned_source: Option<File>,
    ) -> anyhow::Result<String> {
        // The owned argument is dropped on malformed JSON, busy/stop, cancellation and every early return.
        let _slot = self
            .slot
            .try_acquire()
            .map_err(|_| anyhow::anyhow!("Console is busy"))?;
        let (request, operation) = Request::parse(raw)?;
        let path = request.path(operation)?;
        let upload = operation == Operation::Upload;
        let (source, source_size) = prepare_source(&request, upload, owned_source)
            .map_err(|_| anyhow::anyhow!("Invalid upload source"))?;
        let management = operation.is_management();
        let deadline = if management {
            Duration::from_secs(35)
        } else if upload {
            upload_deadline(source_size)
        } else {
            Duration::from_secs(12)
        };
        let started = Instant::now();
        let operation = async {
            let client = (if upload || management {
                &self.upload_client
            } else {
                &self.client
            })
            .get_or_try_init(|| async {
                let _ = rustls::crypto::ring::default_provider().install_default();
                if let Some(tls) = &self.tls {
                    let cert = CertificateDer::from_pem_slice(tls.cert.as_bytes())?;
                    crate::http::client::create_reqwest_client(
                        &tls.private_key,
                        &tls.cert,
                        Some(crate::crypto::cert::fingerprint_from_cert_der(&cert)),
                        if upload || management {
                            None
                        } else {
                            Some(Duration::from_secs(10))
                        },
                    )
                    .map_err(anyhow::Error::from)
                } else {
                    let builder = reqwest::Client::builder()
                        .no_proxy()
                        .redirect(reqwest::redirect::Policy::none());
                    let builder = if upload || management {
                        builder
                    } else {
                        builder.timeout(Duration::from_secs(10))
                    };
                    builder.build().map_err(anyhow::Error::from)
                }
            })
            .await?;
            // The host and port come only from this ServerHandle. No URL supplied by the UI.
            let url = format!(
                "{}://127.0.0.1:{port}{PREFIX}{path}",
                if self.tls.is_some() { "https" } else { "http" }
            );
            let mut url = reqwest::Url::parse(&url)?;
            {
                let mut query = url.query_pairs_mut();
                for (key, value) in &request.parameters {
                    if operation.queries().contains(&key.as_str()) {
                        query.append_pair(key, value);
                    }
                }
            }
            let mut builder = client.request(
                if operation.is_post() {
                    reqwest::Method::POST
                } else if request.head {
                    reqwest::Method::HEAD
                } else {
                    reqwest::Method::GET
                },
                url,
            );
            if upload {
                builder = builder
                    .header("Content-Type", "application/octet-stream")
                    .header("Content-Length", source_size);
                if let Some(source) = source {
                    builder = builder.body(stream_source(source, source_size));
                } else {
                    builder = builder.body(Vec::new());
                }
            }
            if matches!(
                operation,
                Operation::ManageWorkspace
                    | Operation::CreateWorkspace
                    | Operation::SendTransfer
                    | Operation::RetryTransfer
                    | Operation::UpdateSettings
                    | Operation::CreateKey
                    | Operation::ManageKey
                    | Operation::ClearRequests
                    | Operation::ControlNativeTask
                    | Operation::RetrySourceEndNotice
                    | Operation::WorkspaceSend
                    | Operation::PrepareArchive
                    | Operation::CancelArchive
                    | Operation::PreparePreview
                    | Operation::ClosePreview
            ) {
                builder = if let Some(body) = &request.body {
                    builder
                        .header("Content-Type", "application/json")
                        .body(body.to_string())
                } else {
                    builder.header("Content-Length", "0").body(Vec::new())
                };
            }
            if !request.token.is_empty() {
                builder = builder.bearer_auth(&request.token);
            }
            if let Some(value) = &request.range {
                builder = builder.header("Range", value);
            } else if operation == Operation::Content && !request.head {
                builder = builder.header("Range", "bytes=0-4095");
            }
            if let Some(value) = &request.if_match {
                builder = builder.header("If-Match", value);
            }
            let mut response = builder.send().await?;
            let status = response.status().as_u16();
            let redact = |s: &str| {
                let mut text = s.to_owned();
                for secret in [&request.token, request.upload_path.as_deref().unwrap_or("")] {
                    if !secret.is_empty() {
                        text = text.replace(secret, "[redacted]");
                    }
                }
                text
            };
            let headers: BTreeMap<_, _> = [
                "content-type",
                "content-length",
                "content-range",
                "etag",
                "retry-after",
                "x-legnasend-remaining-second",
                "x-legnasend-remaining-minute",
            ]
            .into_iter()
            .filter_map(|key| {
                response
                    .headers()
                    .get(key)
                    .and_then(|v| v.to_str().ok())
                    .map(|v| (key, redact(v)))
            })
            .collect();
            let binary = matches!(operation, Operation::Content | Operation::Archive)
                && !request.head
                && (200..300).contains(&status);
            let limit = if binary { 4096 } else { MAX_BODY };
            let mut bytes = Vec::new();
            let mut truncated = false;
            while let Some(chunk) = response.chunk().await? {
                let remaining = limit - bytes.len();
                bytes.extend_from_slice(&chunk[..chunk.len().min(remaining)]);
                if chunk.len() > remaining {
                    truncated = true;
                    break;
                }
            }
            let mut body = if binary {
                bytes.iter().map(|b| format!("{b:02x}")).collect::<String>()
            } else {
                redact(&String::from_utf8_lossy(&bytes))
            };
            if let Some(password) = request
                .body
                .as_ref()
                .and_then(|body| body.get("password"))
                .and_then(serde_json::Value::as_str)
            {
                if !password.is_empty() {
                    body = body.replace(password, "[REDACTED]");
                    let escaped = serde_json::to_string(password).unwrap();
                    body = body.replace(&escaped[1..escaped.len() - 1], "[REDACTED]");
                }
            }
            // Redaction may expand short invalid credentials. Keep the displayed text bounded too.
            if !binary && body.len() > MAX_BODY {
                let mut end = MAX_BODY;
                while !body.is_char_boundary(end) {
                    end -= 1;
                }
                body.truncate(end);
                truncated = true;
            }
            Ok::<_,anyhow::Error>(json!({"status":status,"headers":headers,"body":body,"binary":binary,
                "bytes":bytes.len(),"truncated":truncated,"elapsedMs":started.elapsed().as_millis()}).to_string())
        };
        tokio::select! {
            biased;
            _ = self.stopped.cancelled() => Err(anyhow::anyhow!("Console service stopped")),
            result = tokio::time::timeout(deadline, operation) => result
                .map_err(|_| anyhow::anyhow!("Console request timed out"))?
                .map_err(|_| anyhow::anyhow!("Console request failed")),
        }
    }
}

fn upload_deadline(size: u64) -> Duration {
    Duration::from_secs(
        60u64
            .saturating_add(size.div_ceil(1024 * 1024))
            .min(6 * 60 * 60),
    )
}
fn prepare_source(
    request: &Request,
    upload: bool,
    owned: Option<File>,
) -> anyhow::Result<(Option<File>, u64)> {
    if !upload {
        anyhow::ensure!(owned.is_none(), "Unexpected upload descriptor");
        return Ok((None, 0));
    }
    if request
        .parameters
        .get("directory")
        .is_some_and(|value| value == "true")
    {
        anyhow::ensure!(
            owned.is_none()
                && request.upload_path.is_none()
                && request.upload_size.unwrap_or(0) == 0,
            "Directory upload has a body"
        );
        return Ok((None, 0));
    }
    anyhow::ensure!(
        owned.is_none() || request.upload_path.is_none(),
        "Ambiguous upload source"
    );
    let descriptor_source = owned.is_some();
    let file = if let Some(file) = owned {
        file
    } else {
        let path = request
            .upload_path
            .as_ref()
            .ok_or_else(|| anyhow::anyhow!("Missing upload source"))?;
        anyhow::ensure!(
            std::fs::symlink_metadata(path)?.is_file(),
            "Upload source is not a regular file"
        );
        let mut options = std::fs::OpenOptions::new();
        options.read(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK);
        }
        let file = options.open(path)?;
        // Windows and providers can lack O_NOFOLLOW; recheck the current path as well.
        anyhow::ensure!(
            std::fs::symlink_metadata(path)?.is_file(),
            "Upload source changed"
        );
        file
    };
    let metadata = file.metadata()?;
    // SAF read-only providers may expose a sequential pipe; only trusted owned
    // descriptors with a caller-known exact length may take that path.
    let size = if metadata.is_file() {
        metadata.len()
    } else {
        anyhow::ensure!(descriptor_source, "Upload source is not a regular file");
        request
            .upload_size
            .ok_or_else(|| anyhow::anyhow!("Sequential upload requires a known size"))?
    };
    anyhow::ensure!(
        request.upload_size.is_none_or(|expected| expected == size),
        "Upload source size changed"
    );
    Ok((Some(file), size))
}
fn stream_source(source: File, expected: u64) -> reqwest::Body {
    use tokio::io::{AsyncReadExt, AsyncSeekExt};
    let seekable = source.metadata().is_ok_and(|metadata| metadata.is_file());
    let stream = futures_util::stream::try_unfold(
        (tokio::fs::File::from_std(source), 0u64, false),
        move |(mut source, total, started)| async move {
            if !started && seekable {
                source.seek(std::io::SeekFrom::Start(0)).await?;
            }
            let mut buffer = vec![0u8; 64 * 1024];
            let count = source.read(&mut buffer).await?;
            if count == 0 {
                if total != expected {
                    return Err(std::io::Error::other("Upload source size changed"));
                }
                return Ok(None);
            }
            if count as u64 > expected.saturating_sub(total) {
                return Err(std::io::Error::other("Upload source size changed"));
            }
            buffer.truncate(count);
            Ok::<_, std::io::Error>(Some((
                bytes::Bytes::from(buffer),
                (source, total + count as u64, true),
            )))
        },
    );
    reqwest::Body::wrap_stream(stream)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn source_end_retry_console_preserves_body_and_notice_path() {
        let id = "11111111-1111-4111-8111-111111111111";
        let body = json!({"version":id,"requestId":id});
        let (request, op) = Request::parse(
            &json!({"operation":"retrySourceEndNotice","parameters":{"noticeId":id},"body":body})
                .to_string(),
        )
        .unwrap();
        assert_eq!(op, Operation::RetrySourceEndNotice);
        assert_eq!(request.body, Some(body));
        assert_eq!(
            request.path(op).unwrap(),
            format!("/native-tasks/source-end/{id}/retry")
        );
        assert!(
            Request::parse(&json!({"operation":"listSourceEndNotices","body":{}}).to_string())
                .is_err()
        );
    }
    #[test]
    fn only_catalog_operations_and_parameters_are_accepted() {
        for value in [
            r#"{"operation":"postFile"}"#,
            r#"{"operation":"getStatus","head":true}"#,
            r#"{"operation":"getStatus","url":"http://elsewhere"}"#,
            r#"{"operation":"getStatus","parameters":{"token":"secret"}}"#,
            r#"{"operation":"getStatus","token":"secret\n"}"#,
        ] {
            assert!(Request::parse(value).is_err());
        }
        let (request, op) =
            Request::parse(r#"{"operation":"getWorkspace","parameters":{"workspaceId":"a/b ?#"}}"#)
                .unwrap();
        assert_eq!(request.path(op).unwrap(), "/workspaces/a%2Fb%20%3F%23");
        let (request, op) = Request::parse(
            r#"{"operation":"getWorkspace","parameters":{"workspaceId":"abc-_.~123"}}"#,
        )
        .unwrap();
        assert_eq!(request.path(op).unwrap(), "/workspaces/abc-_.~123");
    }
    #[test]
    fn localized_contract_declares_matching_state_and_normal_budgets() {
        for language in ["en", "zh-CN", "zh-TW", "zh-HK"] {
            let doc = super::super::contract::document(language);
            let state = &doc["paths"]["/workspaces/{workspaceId}/state"]["get"];
            assert_eq!(state["x-legnasend-max-query-bytes"], 24576);
            let ids = state["parameters"]
                .as_array()
                .unwrap()
                .iter()
                .find(|p| p["name"] == "ids")
                .unwrap();
            assert_eq!(ids["schema"]["maxLength"], 8192);
            assert_eq!(ids["schema"]["x-legnasend-max-utf8-bytes"], 8192);
            let description = ids["schema"]["description"].as_str().unwrap();
            assert!(description.contains("64") && description.contains("8192"));
            assert!(description.contains(if language == "en" {
                "not local paths or URLs"
            } else if language == "zh-CN" {
                "不是本地路径或网址"
            } else {
                "不是本機路徑或網址"
            }));
            let files = &doc["paths"]["/workspaces/{workspaceId}/files"]["get"];
            assert_eq!(files["x-legnasend-max-query-bytes"], 24 * 1024);
            let filter = files["parameters"]
                .as_array()
                .unwrap()
                .iter()
                .find(|p| p["name"] == "filter")
                .unwrap();
            assert_eq!(filter["schema"]["maxLength"], 256);
            let content = &doc["paths"]["/workspaces/{workspaceId}/files/{fileId}/content"]["get"];
            let range = content["parameters"]
                .as_array()
                .unwrap()
                .iter()
                .find(|p| p["name"] == "Range")
                .unwrap();
            assert_eq!(range["schema"]["maxLength"], 1024);
        }
    }
    #[test]
    fn state_id_budget_is_not_the_generic_parameter_budget() {
        fn raw(operation: &str, name: &str, value: String) -> String {
            json!({"operation":operation,"parameters":{name:value}}).to_string()
        }
        for size in [4096, 8192] {
            assert!(Request::parse(&raw("getWorkspaceState", "ids", "a".repeat(size))).is_ok());
        }
        assert!(Request::parse(&raw("getWorkspaceState", "ids", "a".repeat(8193))).is_err());
        assert!(Request::parse(&raw("listFiles", "cursor", "a".repeat(4096))).is_ok());
        assert!(Request::parse(&raw("listFiles", "cursor", "a".repeat(4097))).is_err());
        assert!(Request::parse(&raw("listFiles", "ids", "a".repeat(8192))).is_err());
        assert!(Request::parse(&raw("listFiles", "anchor", "a".repeat(8192))).is_ok());
        assert!(Request::parse(&raw("listFiles", "anchor", "a".repeat(8193))).is_err());
        assert!(
            Request::parse(&raw("getWorkspaceState", "url", "https://elsewhere".into())).is_err()
        );
        for ids in [
            "../path".to_owned(),
            "https://host".to_owned(),
            "你好".to_owned(),
            "a,,b".to_owned(),
            vec!["a"; 65].join(","),
        ] {
            assert!(Request::parse(&raw("getWorkspaceState", "ids", ids)).is_err());
        }
        let escaped = json!({"operation":"getWorkspaceState","parameters":{"workspaceId":"11111111-1111-4111-8111-111111111111","generation":"1","path":"\"".repeat(4096),"ids":"a".repeat(8192)}}).to_string();
        assert!(escaped.len() > 16 * 1024 && escaped.len() < 24 * 1024);
        assert!(Request::parse(&escaped).is_ok());
    }
    #[test]
    fn console_lengths_count_scalars_and_decoded_bytes_then_bound_encoded_query() {
        let raw = |operation: &str, name: &str, value: String| {
            json!({"operation":operation,"parameters":{name:value}}).to_string()
        };
        assert!(Request::parse(&raw("listFiles", "filter", "😀".repeat(256))).is_ok());
        assert!(Request::parse(&raw("listFiles", "filter", "a".repeat(257))).is_err());
        assert!(Request::parse(&raw("getWorkspaceState", "path", "😀".repeat(1024))).is_ok());
        assert!(Request::parse(&raw("getWorkspaceState", "path", "😀".repeat(1025))).is_err());
        assert!(Request::parse(&raw("getWorkspaceState", "path", "a\u{0085}b".into())).is_err());
        // All decoded inputs fit individually; escaping still has a separate budget.
        assert!(Request::parse(&raw("listFiles", "path", "%".repeat(4096))).is_ok());
        assert!(Request::parse(&raw("listFiles", "path", "%".repeat(4097))).is_err());
        assert!(Request::parse(&raw("getWorkspaceState", "path", "%".repeat(4096))).is_ok());
    }
    #[test]
    fn upload_budget_and_source_validation_are_bounded() {
        assert_eq!(upload_deadline(0), Duration::from_secs(60));
        assert_eq!(upload_deadline(1), Duration::from_secs(61));
        assert_eq!(upload_deadline(u64::MAX), Duration::from_secs(6 * 60 * 60));
        for raw in [
            r#"{"operation":"getStatus","uploadPath":"/private/source"}"#,
            r#"{"operation":"uploadFile","uploadPath":"relative"}"#,
            r#"{"operation":"uploadFile","uploadUri":"content://private/file"}"#,
            r#"{"operation":"uploadFile","uploadFd":123}"#,
        ] {
            assert!(Request::parse(raw).is_err());
        }
    }
    #[cfg(unix)]
    #[tokio::test]
    async fn owned_descriptor_closes_on_invalid_request_and_unpolled_future() {
        use std::os::fd::AsRawFd;
        let console = Console::new(None, CancellationToken::new());
        let file = File::open("/dev/null").unwrap();
        let fd = file.as_raw_fd();
        assert!(
            console
                .execute_with_file(1, "invalid-json", Some(file))
                .await
                .is_err()
        );
        assert_eq!(unsafe { libc::fcntl(fd, libc::F_GETFD) }, -1);
        let file = File::open("/dev/null").unwrap();
        let fd = file.as_raw_fd();
        let future = console.execute_with_file(1, "invalid-json", Some(file));
        drop(future);
        assert_eq!(unsafe { libc::fcntl(fd, libc::F_GETFD) }, -1);
    }
    #[tokio::test]
    async fn busy_console_rejects_overlap_and_stop_cancels_an_active_request() {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        let stopped = CancellationToken::new();
        let console = std::sync::Arc::new(Console::new(None, stopped.clone()));
        let first = tokio::spawn({
            let console = console.clone();
            async move { console.execute(port, r#"{"operation":"getStatus"}"#).await }
        });
        let (_socket, _) = tokio::time::timeout(Duration::from_secs(2), listener.accept())
            .await
            .unwrap()
            .unwrap();
        let error = console
            .execute(port, r#"{"operation":"getStatus"}"#)
            .await
            .unwrap_err();
        assert_eq!(error.to_string(), "Console is busy");
        stopped.cancel();
        let result = tokio::time::timeout(Duration::from_secs(1), first)
            .await
            .unwrap()
            .unwrap();
        assert_eq!(result.unwrap_err().to_string(), "Console service stopped");
    }
}

#[cfg(test)]
mod local_route_console_tests {
    use super::*;
    #[test]
    fn route_id_passes_shared_body_validation_but_arbitrary_interface_does_not() {
        let id = uuid::Uuid::new_v4().to_string();
        let mut request = json!({"operation":"sendSelection","parameters":{},"body":{"deviceId":id,"selectionVersion":id,"requestId":id,"localRouteId":id}});
        assert!(Request::parse(&request.to_string()).is_ok());
        request["body"]["localRouteId"] = json!("en0");
        assert!(Request::parse(&request.to_string()).is_err());
    }
}

#[cfg(test)]
mod preview_archive_console_tests {
    use super::*;
    #[test]
    fn preview_body_and_archive_head_are_real_bounded_operations() {
        let id = uuid::Uuid::new_v4().to_string();
        for (operation, field) in [
            ("prepareDocumentPreview", "id"),
            ("closeDocumentPreview", "lease"),
        ] {
            let mut value = json!({"operation":operation,"parameters":{"workspaceId":id,"generation":"1"},"body":{field:id}});
            assert!(Request::parse(&value.to_string()).is_ok());
            value["body"][field] = json!("file:///arbitrary");
            assert!(Request::parse(&value.to_string()).is_err());
        }
        let value = json!({"operation":"downloadWorkspaceArchive","head":true,"parameters":{"workspaceId":id,"generation":"1","ids":format!("[\"{id}\"]")}});
        assert!(Request::parse(&value.to_string()).is_ok());
    }
}

#[cfg(test)]
mod archive_ticket_console_tests {
    use super::*;
    #[test]
    fn large_selection_budget_is_explicit_and_not_granted_to_other_operations() {
        let ids: Vec<_> = (0..20000)
            .map(|i| format!("00000000-0000-4000-8000-{i:012x}"))
            .collect();
        let mut value = json!({"operation":"prepareWorkspaceArchive","parameters":{"workspaceId":"11111111-1111-4111-8111-111111111111","generation":"1"},"body":{"path":"","ids":ids}});
        let raw = value.to_string();
        assert!(raw.len() > 72 * 1024);
        assert!(Request::parse(&raw).is_ok());
        value["operation"] = json!("getStatus");
        assert!(Request::parse(&value.to_string()).is_err());
        value["operation"] = json!("prepareWorkspaceArchive");
        value["body"]["ids"][1] = value["body"]["ids"][0].clone();
        assert!(Request::parse(&value.to_string()).is_err());
        value["body"]["ids"] = json!(["a"]);
        value["body"]["path"] = json!("界".repeat(1366));
        assert!(Request::parse(&value.to_string()).is_err());
        value["body"] = json!({"path":"","ids":["a"],"url":"https://outside"});
        assert!(Request::parse(&value.to_string()).is_err());
        let cancel = json!({"operation":"cancelWorkspaceArchive","parameters":{"workspaceId":"11111111-1111-4111-8111-111111111111","generation":"1"},"body":{"selection":"11111111-1111-4111-8111-111111111111"}});
        assert!(Request::parse(&cancel.to_string()).is_ok());
        let mixed = json!({"operation":"downloadWorkspaceArchive","parameters":{"workspaceId":"11111111-1111-4111-8111-111111111111","generation":"1","selection":"11111111-1111-4111-8111-111111111111","path":""}});
        assert!(Request::parse(&mixed.to_string()).is_err());
    }
}
