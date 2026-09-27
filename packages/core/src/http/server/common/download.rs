//! Bounded, seek-based download bodies. Range parsing never allocates file-sized buffers.
use super::error::AppError;
use super::response::{BoxedBody, full_body};
use crate::crypto::hash::sha256_hex;
use crate::model::transfer::{FileContent, FileDto};
use bytes::Bytes;
use http_body_util::{BodyExt, StreamBody};
use hyper::body::Frame;
use hyper::{HeaderMap, Response, StatusCode, header};
use std::io::{self, SeekFrom};
use tokio::io::{AsyncReadExt, AsyncSeekExt};
use tokio::sync::mpsc;
use tokio_stream::{StreamExt, wrappers::ReceiverStream};

const CHUNK_SIZE: usize = 64 * 1024;
const READ_AHEAD: usize = 2;

enum Source {
    File(tokio::fs::File, Option<String>),
    Stream(mpsc::Receiver<Bytes>),
}

#[derive(Debug, PartialEq)]
pub(crate) enum RangeSelection {
    Full,
    Partial { start: u64, len: u64 },
    Unsatisfiable,
}

/// A single range per request is enough for parallel clients (one request per
/// chunk). Unsupported units/multi-range fields are ignored, not mislabelled 206.
pub(crate) fn select_range(value: &str, size: u64) -> RangeSelection {
    let Some((unit, spec)) = value.split_once('=') else {
        return RangeSelection::Full;
    };
    if !unit.eq_ignore_ascii_case("bytes") {
        return RangeSelection::Full;
    }
    if spec.contains(',') {
        return RangeSelection::Full;
    }
    let Some((start, end)) = spec.trim().split_once('-') else {
        return RangeSelection::Unsatisfiable;
    };
    fn number(s: &str) -> Option<u64> {
        if s.is_empty() || !s.bytes().all(|b| b.is_ascii_digit()) {
            return None;
        }
        Some(s.bytes().fold(0_u64, |n, b| {
            n.saturating_mul(10).saturating_add(u64::from(b - b'0'))
        }))
    }
    if size == 0 {
        return RangeSelection::Unsatisfiable;
    }
    if start.is_empty() {
        return match number(end) {
            Some(n) if n > 0 => RangeSelection::Partial {
                start: size.saturating_sub(n),
                len: n.min(size),
            },
            _ => RangeSelection::Unsatisfiable,
        };
    }
    let Some(start) = number(start) else {
        return RangeSelection::Unsatisfiable;
    };
    let end = if end.is_empty() {
        size - 1
    } else {
        let Some(end) = number(end) else {
            return RangeSelection::Unsatisfiable;
        };
        end.min(size - 1)
    };
    if start >= size || end < start {
        return RangeSelection::Unsatisfiable;
    }
    RangeSelection::Partial {
        start,
        len: end - start + 1,
    }
}

/// Metadata validator, not a checksum of the content. Nanosecond change time and
/// inode are included on Unix, so replacing a same-length file changes the tag.
pub(crate) fn file_stamp(metadata: &std::fs::Metadata, id: &str) -> String {
    let mut stamp = format!(
        "{id}:{}:{:?}:{:?}",
        metadata.len(),
        metadata.modified(),
        metadata.created()
    );
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        stamp.push_str(&format!(
            ":{}:{}:{}:{}",
            metadata.dev(),
            metadata.ino(),
            metadata.ctime(),
            metadata.ctime_nsec()
        ));
    }
    format!("\"{}\"", sha256_hex(stamp.as_bytes()))
}

async fn open_source(content: FileContent, file: &FileDto) -> Result<Source, AppError> {
    let opened = match content {
        FileContent::Stream(rx) => return Ok(Source::Stream(rx)),
        FileContent::Path(path) => tokio::fs::File::open(path).await.map_err(|error| {
            AppError::Status(if error.kind() == io::ErrorKind::NotFound {
                StatusCode::NOT_FOUND
            } else {
                StatusCode::INTERNAL_SERVER_ERROR
            })
        })?,
        FileContent::OpenedFile(file) => tokio::fs::File::from_std(file),
        #[cfg(target_os = "android")]
        FileContent::Fd(fd) => {
            use std::os::fd::FromRawFd;
            // SAFETY: FileContent owns this descriptor for this request.
            tokio::fs::File::from_std(unsafe { std::fs::File::from_raw_fd(fd) })
        }
    };
    let mut opened = opened;
    let metadata = opened
        .metadata()
        .await
        .map_err(|_| AppError::Status(StatusCode::INTERNAL_SERVER_ERROR))?;
    if metadata.is_file() && metadata.len() != file.size {
        return Err(AppError::Message(
            StatusCode::CONFLICT,
            "Shared file changed; share it again.".into(),
        ));
    }
    let seekable = metadata.is_file() && opened.seek(SeekFrom::Start(0)).await.is_ok();
    Ok(Source::File(
        opened,
        seekable.then(|| file_stamp(&metadata, &file.id)),
    ))
}

pub(crate) fn preview_mime(mime: &str) -> Option<&str> {
    match mime {
        "image/png" | "image/jpeg" | "image/gif" | "image/webp" | "image/avif" | "image/bmp"
        | "video/mp4" | "video/webm" | "video/ogg" | "video/quicktime" | "audio/mpeg"
        | "audio/mp4" | "audio/wav" | "audio/x-wav" | "audio/ogg" | "audio/webm" | "audio/flac"
        | "audio/aac" => Some(mime),
        "text/plain" | "text/markdown" | "text/x-markdown" => Some("text/plain; charset=utf-8"),
        _ => None,
    }
}

pub(crate) async fn response(
    content: FileContent,
    file: &FileDto,
    headers: &HeaderMap,
    head: bool,
    preview: bool,
    encoded_name: &str,
) -> Result<Response<BoxedBody>, AppError> {
    response_inner(content, file, headers, head, preview, encoded_name, true).await
}

/// Document-provider descriptors have no trustworthy cross-request version.
/// Reuse bounded streaming without offering validators or range continuation.
pub(crate) async fn response_unversioned(
    content: FileContent,
    file: &FileDto,
    headers: &HeaderMap,
    head: bool,
    encoded_name: &str,
) -> Result<Response<BoxedBody>, AppError> {
    response_inner(content, file, headers, head, false, encoded_name, false).await
}
async fn response_inner(
    content: FileContent,
    file: &FileDto,
    headers: &HeaderMap,
    head: bool,
    preview: bool,
    encoded_name: &str,
    versioned: bool,
) -> Result<Response<BoxedBody>, AppError> {
    let mut source = open_source(content, file).await?;
    if !versioned {
        if let Source::File(_, stamp) = &mut source {
            *stamp = None;
        }
    }
    let etag = match &source {
        Source::File(_, stamp) => stamp.clone(),
        _ => None,
    };
    if let Some(condition) = headers.get(header::IF_MATCH) {
        let matches = condition.to_str().ok().is_some_and(|v| {
            v.trim() == "*" || v.split(',').any(|tag| Some(tag.trim()) == etag.as_deref())
        });
        if !matches {
            return Err(AppError::Status(StatusCode::PRECONDITION_FAILED));
        }
    }
    let allow_range = !head
        && etag.is_some()
        && headers
            .get(header::IF_RANGE)
            .map(|condition| condition.to_str().ok() == etag.as_deref())
            .unwrap_or(true);
    let range = if allow_range {
        if headers.get_all(header::RANGE).iter().count() > 1 {
            RangeSelection::Full
        } else {
            headers
                .get(header::RANGE)
                .and_then(|v| v.to_str().ok())
                .map(|v| select_range(v, file.size))
                .unwrap_or(RangeSelection::Full)
        }
    } else {
        RangeSelection::Full
    };
    let (status, start, len) = match range {
        RangeSelection::Full => (StatusCode::OK, 0, file.size),
        RangeSelection::Partial { start, len } => (StatusCode::PARTIAL_CONTENT, start, len),
        RangeSelection::Unsatisfiable => (StatusCode::RANGE_NOT_SATISFIABLE, 0, 0),
    };
    if let Source::File(opened, Some(_)) = &mut source {
        opened
            .seek(SeekFrom::Start(start))
            .await
            .map_err(|_| AppError::Status(StatusCode::INTERNAL_SERVER_ERROR))?;
    }
    let body = if head || len == 0 {
        full_body(Bytes::new())
    } else {
        stream_body(source, len, file.id.clone())
    };
    let mut response = Response::new(body);
    *response.status_mut() = status;
    let result_headers = response.headers_mut();
    result_headers.insert(
        header::ACCEPT_RANGES,
        if etag.is_some() { "bytes" } else { "none" }
            .parse()
            .unwrap(),
    );
    result_headers.insert(header::CONTENT_LENGTH, len.into());
    result_headers.insert(header::CACHE_CONTROL, "private, no-store".parse().unwrap());
    result_headers.insert("x-content-type-options", "nosniff".parse().unwrap());
    if let Some(etag) = etag {
        result_headers.insert(header::ETAG, etag.parse().unwrap());
    }
    if status == StatusCode::PARTIAL_CONTENT {
        result_headers.insert(
            header::CONTENT_RANGE,
            format!("bytes {start}-{}/{}", start + len - 1, file.size)
                .parse()
                .unwrap(),
        );
    } else if status == StatusCode::RANGE_NOT_SATISFIABLE {
        result_headers.insert(
            header::CONTENT_RANGE,
            format!("bytes */{}", file.size).parse().unwrap(),
        );
    }
    let mime = if preview {
        preview_mime(&file.file_type)
    } else {
        None
    };
    result_headers.insert(
        header::CONTENT_TYPE,
        mime.unwrap_or("application/octet-stream").parse().unwrap(),
    );
    result_headers.insert(
        header::CONTENT_DISPOSITION,
        format!(
            "{}; filename=\"{encoded_name}\"; filename*=UTF-8''{encoded_name}",
            if mime.is_some() {
                "inline"
            } else {
                "attachment"
            }
        )
        .parse()
        .map_err(|_| AppError::Status(StatusCode::INTERNAL_SERVER_ERROR))?,
    );
    Ok(response)
}

fn stream_body(source: Source, length: u64, id: String) -> BoxedBody {
    let (tx, rx) = mpsc::channel::<Result<Bytes, io::Error>>(READ_AHEAD);
    tokio::spawn(async move {
        let result = send_content(source, length, &id, &tx).await;
        if let Err(error) = result {
            let _ = tx.send(Err(error)).await;
        }
    });
    StreamBody::new(ReceiverStream::new(rx).map(|result| result.map(Frame::data))).boxed()
}

async fn send_content(
    mut source: Source,
    mut remaining: u64,
    id: &str,
    tx: &mpsc::Sender<Result<Bytes, io::Error>>,
) -> io::Result<()> {
    let mut buffer = vec![0_u8; CHUNK_SIZE];
    while remaining > 0 {
        let chunk = match &mut source {
            Source::File(file, stamp) => {
                let cap = remaining.min(CHUNK_SIZE as u64) as usize;
                let count = tokio::select! {
                    biased;
                    _ = tx.closed() => return Ok(()),
                    read = file.read(&mut buffer[..cap]) => read?,
                };
                if count == 0 {
                    return Err(io::Error::new(
                        io::ErrorKind::UnexpectedEof,
                        "Download source ended early",
                    ));
                }
                // Verify before releasing the last bytes, not after Content-Length completes.
                if count as u64 == remaining {
                    if let Some(expected) = stamp {
                        if file_stamp(&file.metadata().await?, id) != *expected {
                            return Err(io::Error::other("Download source changed"));
                        }
                    }
                }
                Bytes::copy_from_slice(&buffer[..count])
            }
            Source::Stream(rx) => tokio::select! {
                biased;
                _ = tx.closed() => return Ok(()),
                chunk = rx.recv() => chunk.ok_or_else(|| io::Error::new(io::ErrorKind::UnexpectedEof, "Download source ended early"))?,
            },
        };
        if chunk.len() as u64 > remaining {
            return Err(io::Error::other("Download source exceeds declared size"));
        }
        remaining -= chunk.len() as u64;
        if tx.send(Ok(chunk)).await.is_err() {
            return Ok(());
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn range_boundaries() {
        for (header, start, len) in [
            ("bytes=0-0", 0, 1),
            ("bytes=3-6", 3, 4),
            ("bytes=8-", 8, 2),
            ("bytes=-3", 7, 3),
            ("bytes=-99999999999999999999999", 0, 10),
            ("bytes=0-99999999999999999999999", 0, 10),
        ] {
            assert_eq!(
                select_range(header, 10),
                RangeSelection::Partial { start, len }
            );
        }
        for header in [
            "bytes=10-",
            "bytes=9-3",
            "bytes=-0",
            "bytes=a-b",
            "bytes=",
            "bytes=99999999999999999999999-",
        ] {
            assert_eq!(select_range(header, 10), RangeSelection::Unsatisfiable);
        }
        assert_eq!(select_range("bytes=0-0", 0), RangeSelection::Unsatisfiable);
        assert_eq!(select_range("items=0-1", 10), RangeSelection::Full);
        assert_eq!(select_range("bytes=0-1,4-5", 10), RangeSelection::Full);
    }
    #[test]
    fn active_documents_are_not_served_inline() {
        for mime in [
            "text/html",
            "image/svg+xml",
            "application/xhtml+xml",
            "application/javascript",
        ] {
            assert_eq!(preview_mime(mime), None);
        }
        assert_eq!(preview_mime("video/mp4"), Some("video/mp4"));
    }
    fn dto(size: u64) -> FileDto {
        FileDto {
            id: "fixture".into(),
            file_name: "fixture.bin".into(),
            size,
            file_type: "application/octet-stream".into(),
            sha256: None,
            preview: None,
            metadata: None,
        }
    }

    #[tokio::test]
    async fn short_stream_errors_and_dropped_body_releases_source() {
        let (tx, rx) = mpsc::channel(2);
        tx.send(Bytes::from_static(b"short")).await.unwrap();
        drop(tx);
        let response = response(
            FileContent::Stream(rx),
            &dto(10),
            &HeaderMap::new(),
            false,
            false,
            "fixture",
        )
        .await
        .unwrap();
        assert!(response.into_body().collect().await.is_err());
        let (tx, rx) = mpsc::channel(2);
        let response = super::response(
            FileContent::Stream(rx),
            &dto(100),
            &HeaderMap::new(),
            false,
            false,
            "fixture",
        )
        .await
        .unwrap();
        drop(response);
        tokio::time::timeout(std::time::Duration::from_secs(2), tx.closed())
            .await
            .unwrap();
    }

    #[tokio::test]
    async fn owned_file_seeks_and_detects_mutation_before_completion() {
        let path = std::env::temp_dir().join(format!("legnasend-range-{}", uuid::Uuid::new_v4()));
        let size = CHUNK_SIZE * 10;
        std::fs::write(&path, vec![1; size]).unwrap();
        let mut headers = HeaderMap::new();
        headers.insert(header::RANGE, "bytes=100-103".parse().unwrap());
        let partial = response(
            FileContent::OpenedFile(std::fs::File::open(&path).unwrap()),
            &dto(size as u64),
            &headers,
            false,
            false,
            "fixture",
        )
        .await
        .unwrap();
        assert_eq!(partial.status(), StatusCode::PARTIAL_CONTENT);
        assert_eq!(
            partial
                .into_body()
                .collect()
                .await
                .unwrap()
                .to_bytes()
                .as_ref(),
            &[1, 1, 1, 1]
        );
        let mut full = response(
            FileContent::Path(path.clone()),
            &dto(size as u64),
            &HeaderMap::new(),
            false,
            false,
            "fixture",
        )
        .await
        .unwrap()
        .into_body();
        // Reading one frame leaves the bounded read-ahead queue blocked before EOF.
        full.frame().await.unwrap().unwrap();
        std::fs::write(&path, vec![2; size]).unwrap();
        assert!(full.collect().await.is_err());
        std::fs::remove_file(path).unwrap();
    }

    #[tokio::test]
    async fn empty_files_and_inline_mime_are_explicit() {
        let path = std::env::temp_dir().join(format!("legnasend-empty-{}", uuid::Uuid::new_v4()));
        std::fs::write(&path, []).unwrap();
        let mut file = dto(0);
        file.file_type = "video/mp4".into();
        let result = response(
            FileContent::Path(path.clone()),
            &file,
            &HeaderMap::new(),
            false,
            true,
            "video.mp4",
        )
        .await
        .unwrap();
        assert_eq!(result.status(), StatusCode::OK);
        assert_eq!(result.headers()[header::CONTENT_TYPE], "video/mp4");
        assert!(
            result.headers()[header::CONTENT_DISPOSITION]
                .to_str()
                .unwrap()
                .starts_with("inline;")
        );
        let mut headers = HeaderMap::new();
        headers.insert(header::RANGE, "bytes=0-0".parse().unwrap());
        let result = response(
            FileContent::Path(path.clone()),
            &file,
            &headers,
            false,
            true,
            "video.mp4",
        )
        .await
        .unwrap();
        assert_eq!(result.status(), StatusCode::RANGE_NOT_SATISFIABLE);
        assert_eq!(result.headers()[header::CONTENT_RANGE], "bytes */0");
        file.file_type = "text/html".into();
        let result = response(
            FileContent::Path(path.clone()),
            &file,
            &HeaderMap::new(),
            false,
            true,
            "page.html",
        )
        .await
        .unwrap();
        assert_eq!(
            result.headers()[header::CONTENT_TYPE],
            "application/octet-stream"
        );
        assert!(
            result.headers()[header::CONTENT_DISPOSITION]
                .to_str()
                .unwrap()
                .starts_with("attachment;")
        );
        std::fs::remove_file(path).unwrap();
    }
}
