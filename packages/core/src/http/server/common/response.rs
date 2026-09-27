use bytes::Bytes;
use http_body_util::combinators::BoxBody;
use http_body_util::{BodyExt, Full};
use hyper::{Response, StatusCode, http};
use serde::Serialize;

/// Response body that is either fully buffered or streamed (e.g. file downloads).
pub(crate) type BoxedBody = BoxBody<Bytes, std::io::Error>;

/// Creates a fully buffered response body.
pub(crate) fn full_body(bytes: impl Into<Bytes>) -> BoxedBody {
    Full::new(bytes.into())
        .map_err(std::io::Error::other)
        .boxed()
}

/// Creates an empty response body.
pub(crate) fn empty_body() -> BoxedBody {
    full_body(Bytes::new())
}

pub(crate) struct JsonResponse<T: Serialize> {
    pub(crate) status: StatusCode,
    pub(crate) body: T,
}

impl<T: Serialize> JsonResponse<T> {
    pub(crate) fn into_response(self) -> Response<BoxedBody> {
        let mut response = Response::new(empty_body());
        *response.status_mut() = self.status;

        response.headers_mut().insert(
            http::header::CONTENT_TYPE,
            http::HeaderValue::from_static("application/json"),
        );

        *response.body_mut() =
            full_body(serde_json::to_string(&self.body).unwrap_or_else(|_| "{}".to_string()));

        response
    }
}

/// Finish a rejected workspace upload or explicit archive/preview control without
/// silently abandoning an HTTP/1
/// keep-alive body. Hyper's cheap drain polls once and otherwise closes the read
/// side; if body bytes are still in flight, clients can mistake that connection
/// for a reusable one. Only a small, known body gets a bounded grace period.
/// Never read an unlimited/chunked body, or solicit an Expect body after denial.
/// Called only after workspace/integration dispatch, never original-v2 routes.
pub(crate) async fn finish_rejected_directory_upload(
    req: &mut hyper::Request<hyper::body::Incoming>,
    response: &mut Response<BoxedBody>,
) {
    use hyper::{Method, Version, body::Body, header};
    const MAX_DRAIN: u64 = 64 * 1024;
    const DRAIN_GRACE: std::time::Duration = std::time::Duration::from_millis(100);
    if req.method() != Method::POST
        || ![
            "/upload",
            "/prepare-archive",
            "/cancel-archive",
            "/prepare-preview",
            "/close-preview",
        ]
        .iter()
        .any(|suffix| req.uri().path().ends_with(suffix))
        || !(response.status().is_client_error() || response.status().is_server_error())
        || !matches!(req.version(), Version::HTTP_10 | Version::HTTP_11)
        || req.body().is_end_stream()
    {
        return;
    }
    let length = req
        .headers()
        .get(header::CONTENT_LENGTH)
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.parse::<u64>().ok());
    let may_drain = length.is_some_and(|length| length <= MAX_DRAIN)
        && !req.headers().contains_key(header::TRANSFER_ENCODING)
        && !req.headers().contains_key(header::EXPECT);
    if may_drain {
        let drained = tokio::time::timeout(DRAIN_GRACE, async {
            let mut read = 0u64;
            while let Some(frame) = req.body_mut().frame().await {
                let Ok(frame) = frame else {
                    return false;
                };
                if let Some(bytes) = frame.data_ref() {
                    read = read.saturating_add(bytes.len() as u64);
                    if read > MAX_DRAIN {
                        return false;
                    }
                }
            }
            true
        })
        .await;
        if matches!(drained, Ok(true)) {
            return;
        }
    }
    // Do not invite pooled clients to reuse a stream whose request body was not
    // exhausted. Large/slow bodies are rejected without waiting for their EOF.
    response
        .headers_mut()
        .insert(header::CONNECTION, http::HeaderValue::from_static("close"));
}
