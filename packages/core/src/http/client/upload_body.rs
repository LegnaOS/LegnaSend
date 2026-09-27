use crate::model::transfer::FileContent;
use bytes::Bytes;
use futures_util::StreamExt;
use hyper::body::{Body, Frame, SizeHint};
use std::io::{self, Read};
use std::pin::Pin;
use std::task::{Context, Poll};
use tokio_stream::wrappers::ReceiverStream;

/// Per active upload, never an all-files cache. Match the native scheduler's
/// small-file threshold; large and non-regular sources remain streamed.
const SMALL_FILE_LIMIT: u64 = 256 * 1024;

enum Source {
    Small(Bytes),
    Stream(FileContent),
}

// The synchronous Android ownership step must precede the future's first poll.
#[allow(clippy::manual_async_fn)]
pub(super) fn build(
    content: FileContent,
    progress: impl Fn(u64) + Send + 'static,
) -> impl std::future::Future<Output = io::Result<reqwest::Body>> + Send {
    // Take ownership synchronously: select! may drop this future without ever
    // polling it when a transfer was already cancelled. Raw SAF descriptors
    // otherwise have no destructor and would leak on that path.
    #[cfg(target_os = "android")]
    let content = match content {
        FileContent::Fd(fd) => {
            use std::os::fd::FromRawFd;
            // The caller transfers one owned descriptor, as in into_receiver.
            FileContent::OpenedFile(unsafe { std::fs::File::from_raw_fd(fd) })
        }
        content => content,
    };
    async move {
        // Keep application streams streaming, without a blocking-pool hop.
        let source = match content {
            FileContent::Stream(_) => Source::Stream(content),
            content => tokio::task::spawn_blocking(move || prepare(content))
                .await
                .map_err(io::Error::other)??,
        };
        Ok(match source {
            Source::Small(bytes) => reqwest::Body::wrap(SmallBody {
                bytes: Some(bytes),
                progress: std::sync::Mutex::new(Box::new(progress)),
            }),
            Source::Stream(content) => {
                let mut sent = 0;
                reqwest::Body::wrap_stream(ReceiverStream::new(content.into_receiver()).map(
                    move |chunk| {
                        sent += chunk.len() as u64;
                        progress(sent);
                        Ok::<_, io::Error>(chunk)
                    },
                ))
            }
        })
    }
}

fn prepare(content: FileContent) -> io::Result<Source> {
    let file = match content {
        FileContent::Path(path) => std::fs::File::open(path)?,
        FileContent::OpenedFile(file) => file,
        #[cfg(target_os = "android")]
        FileContent::Fd(fd) => {
            use std::os::fd::FromRawFd;
            // Ownership is identical to FileContent::into_receiver: one owned
            // descriptor is consumed and closed, including early errors.
            unsafe { std::fs::File::from_raw_fd(fd) }
        }
        FileContent::Stream(_) => return Ok(Source::Stream(content)),
    };
    let metadata = file.metadata()?;
    if !metadata.is_file() || metadata.len() > SMALL_FILE_LIMIT {
        return Ok(Source::Stream(FileContent::OpenedFile(file)));
    }
    // One bounded blocking read replaces open/read/EOF channel hand-offs for
    // tiny files. Reading an extra byte detects growth; never load an arbitrarily
    // grown source, truncate it silently, or change the advertised v2 file size.
    Ok(Source::Small(read_small(file, metadata.len() as usize)?))
}

fn read_small(file: impl Read, capacity: usize) -> io::Result<Bytes> {
    let mut bytes = Vec::with_capacity(capacity.min(SMALL_FILE_LIMIT as usize));
    file.take(SMALL_FILE_LIMIT + 1).read_to_end(&mut bytes)?;
    if bytes.len() as u64 > SMALL_FILE_LIMIT {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "Upload source exceeded the small-file buffer",
        ));
    }
    Ok(Bytes::from(bytes))
}

/// Exact-size body with progress only when HTTP polls the bytes, not while
/// opening the file or before the pinned TLS handshake. Standard Content-Length
/// avoids the streamed tiny-file EOF tail; endpoints and file bytes are unchanged.
struct SmallBody {
    bytes: Option<Bytes>,
    progress: std::sync::Mutex<Box<dyn Fn(u64) + Send>>,
}

impl Body for SmallBody {
    type Data = Bytes;
    type Error = io::Error;

    fn poll_frame(
        mut self: Pin<&mut Self>,
        _: &mut Context<'_>,
    ) -> Poll<Option<Result<Frame<Bytes>, io::Error>>> {
        Poll::Ready(self.bytes.take().map(|bytes| {
            (self.progress.get_mut().unwrap_or_else(|e| e.into_inner()))(bytes.len() as u64);
            Ok(Frame::data(bytes))
        }))
    }

    fn is_end_stream(&self) -> bool {
        self.bytes.is_none()
    }

    fn size_hint(&self) -> SizeHint {
        SizeHint::with_exact(self.bytes.as_ref().map_or(0, |bytes| bytes.len() as u64))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use http_body_util::BodyExt;
    use std::sync::{
        atomic::{AtomicU64, Ordering},
        Arc,
    };

    #[test]
    fn growth_stops_at_budget_instead_of_silently_truncating() {
        let mut input = io::Cursor::new(vec![7; SMALL_FILE_LIMIT as usize + 1024]);
        assert_eq!(
            read_small(&mut input, 4096).unwrap_err().kind(),
            io::ErrorKind::InvalidData
        );
        assert_eq!(input.position(), SMALL_FILE_LIMIT + 1);
    }

    #[tokio::test]
    async fn small_files_have_exact_bytes_and_deferred_progress() {
        for size in [0, 4096, SMALL_FILE_LIMIT as usize] {
            let path =
                std::env::temp_dir().join(format!("legnasend-small-{}", uuid::Uuid::new_v4()));
            let expected = vec![19; size];
            std::fs::write(&path, &expected).unwrap();
            let progress = Arc::new(AtomicU64::new(u64::MAX));
            let observed = progress.clone();
            let body = build(FileContent::Path(path.clone()), move |n| {
                observed.store(n, Ordering::SeqCst);
            })
            .await
            .unwrap();
            assert_eq!(body.size_hint().exact(), Some(size as u64));
            assert_eq!(progress.load(Ordering::SeqCst), u64::MAX);
            let bytes = body.collect().await.unwrap().to_bytes();
            assert_eq!(bytes.as_ref(), expected);
            assert_eq!(progress.load(Ordering::SeqCst), size as u64);
            std::fs::remove_file(path).unwrap();
        }
    }

    #[tokio::test]
    async fn large_files_stay_streamed_and_missing_sources_fail() {
        let path = std::env::temp_dir().join(format!("legnasend-large-{}", uuid::Uuid::new_v4()));
        let expected = vec![23; SMALL_FILE_LIMIT as usize + 1];
        std::fs::write(&path, &expected).unwrap();
        let body = build(FileContent::Path(path.clone()), |_| {})
            .await
            .unwrap();
        assert_eq!(body.size_hint().exact(), None);
        assert_eq!(body.collect().await.unwrap().to_bytes().as_ref(), expected);
        std::fs::remove_file(&path).unwrap();
        assert!(build(FileContent::Path(path), |_| {}).await.is_err());
    }

    #[tokio::test]
    async fn application_streams_keep_unknown_length_and_chunk_progress() {
        let (tx, rx) = tokio::sync::mpsc::channel(2);
        tx.send(Bytes::from_static(b"abc")).await.unwrap();
        tx.send(Bytes::from_static(b"def")).await.unwrap();
        drop(tx);
        let body = build(FileContent::Stream(rx), |_| {}).await.unwrap();
        assert_eq!(body.size_hint().exact(), None);
        assert_eq!(body.collect().await.unwrap().to_bytes().as_ref(), b"abcdef");
    }
}
