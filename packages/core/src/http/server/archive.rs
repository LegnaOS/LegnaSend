//! Browser-requested ZIP downloads only. Original LocalSend file transfers do
//! not use this container. STORE + ZIP64 permit bounded streaming without seek.
use super::common::{error::AppError, response::BoxedBody};
use bytes::Bytes;
use http_body_util::{BodyExt, StreamBody};
use hyper::{Response, StatusCode, body::Frame, header};
use std::{
    collections::HashSet,
    future::Future,
    io,
    time::{Duration, Instant},
};
use tokio::sync::{Semaphore, SemaphorePermit, mpsc};
use tokio_stream::{StreamExt, wrappers::ReceiverStream};

pub(super) const MAX_ENTRIES: usize = 100_000;
const MAX_NAMES: usize = 16 * 1024 * 1024;
static ACTIVE: Semaphore = Semaphore::const_new(2);
pub(super) fn permit() -> Result<SemaphorePermit<'static>, AppError> {
    ACTIVE
        .try_acquire()
        .map_err(|_| AppError::Status(StatusCode::TOO_MANY_REQUESTS))
}

pub(super) struct Entry<T> {
    pub name: String,
    pub size: u64,
    pub source: T,
}
pub(super) struct Plan<T> {
    pub entries: Vec<Entry<T>>,
    names: HashSet<String>,
    bytes: usize,
}
impl<T> Plan<T> {
    pub fn new() -> Self {
        Self {
            entries: Vec::new(),
            names: HashSet::new(),
            bytes: 0,
        }
    }
    pub fn push(&mut self, entry: Entry<T>) -> Result<(), AppError> {
        valid_name(&entry.name)?;
        self.bytes += entry.name.len();
        if self.entries.len() >= MAX_ENTRIES || self.bytes > MAX_NAMES {
            return Err(AppError::Status(StatusCode::PAYLOAD_TOO_LARGE));
        }
        if !self
            .names
            .insert(entry.name.trim_end_matches('/').to_lowercase())
        {
            return Err(AppError::Message(
                StatusCode::CONFLICT,
                "Conflicting archive paths".into(),
            ));
        }
        self.entries.push(entry);
        Ok(())
    }
    pub fn finish(mut self) -> Result<Vec<Entry<T>>, AppError> {
        // A file and a parent directory cannot occupy the same path. Explicit
        // directory records and their children are allowed, including empty dirs.
        let files: HashSet<_> = self
            .entries
            .iter()
            .filter(|e| !e.name.ends_with('/'))
            .map(|e| e.name.to_lowercase())
            .collect();
        for entry in &self.entries {
            let name = entry.name.trim_end_matches('/').to_lowercase();
            for (i, _) in name.match_indices('/') {
                if files.contains(&name[..i]) {
                    return Err(AppError::Status(StatusCode::CONFLICT));
                }
            }
        }
        self.entries.sort_by(|a, b| a.name.cmp(&b.name));
        Ok(self.entries)
    }
}

pub(super) fn valid_name(name: &str) -> Result<(), AppError> {
    let path = name.strip_suffix('/').unwrap_or(name);
    if path.is_empty()
        || name.len() > 4096
        || path.contains(['\\', ':', '<', '>', '"', '|', '?', '*'])
        || path.chars().any(char::is_control)
    {
        return Err(AppError::BadRequest("Unsafe archive path".into()));
    }
    for part in path.split('/') {
        let base = part.split('.').next().unwrap().to_ascii_uppercase();
        if part.is_empty()
            || part == "."
            || part == ".."
            || part.ends_with([' ', '.'])
            || [
                "CON", "PRN", "AUX", "NUL", "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7",
                "COM8", "COM9", "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8",
                "LPT9",
            ]
            .contains(&base.as_str())
        {
            return Err(AppError::BadRequest("Unsafe archive path".into()));
        }
    }
    Ok(())
}
fn u16le(out: &mut Vec<u8>, n: u16) {
    out.extend(n.to_le_bytes());
}
fn u32le(out: &mut Vec<u8>, n: u32) {
    out.extend(n.to_le_bytes());
}
fn u64le(out: &mut Vec<u8>, n: u64) {
    out.extend(n.to_le_bytes());
}
fn local(name: &str, size: u64) -> Vec<u8> {
    let mut b = Vec::new();
    u32le(&mut b, 0x04034b50);
    u16le(&mut b, 45);
    u16le(&mut b, 0x808);
    u16le(&mut b, 0);
    u16le(&mut b, 0);
    u16le(&mut b, 33);
    u32le(&mut b, 0);
    u32le(&mut b, u32::MAX);
    u32le(&mut b, u32::MAX);
    u16le(&mut b, name.len() as u16);
    u16le(&mut b, 20);
    b.extend(name.as_bytes());
    u16le(&mut b, 1);
    u16le(&mut b, 16);
    u64le(&mut b, size);
    u64le(&mut b, size);
    b
}
fn descriptor(crc: u32, size: u64) -> Vec<u8> {
    let mut b = Vec::new();
    u32le(&mut b, 0x08074b50);
    u32le(&mut b, crc);
    u64le(&mut b, size);
    u64le(&mut b, size);
    b
}
fn central(name: &str, size: u64, crc: u32, offset: u64) -> Vec<u8> {
    let mut b = Vec::new();
    u32le(&mut b, 0x02014b50);
    u16le(&mut b, 45);
    u16le(&mut b, 45);
    u16le(&mut b, 0x808);
    u16le(&mut b, 0);
    u16le(&mut b, 0);
    u16le(&mut b, 33);
    u32le(&mut b, crc);
    u32le(&mut b, u32::MAX);
    u32le(&mut b, u32::MAX);
    u16le(&mut b, name.len() as u16);
    u16le(&mut b, 28);
    u16le(&mut b, 0);
    u16le(&mut b, 0);
    u16le(&mut b, 0);
    u32le(&mut b, if name.ends_with('/') { 16 } else { 0 });
    u32le(&mut b, u32::MAX);
    b.extend(name.as_bytes());
    u16le(&mut b, 1);
    u16le(&mut b, 24);
    u64le(&mut b, size);
    u64le(&mut b, size);
    u64le(&mut b, offset);
    b
}
fn end(count: u64, size: u64, offset: u64) -> Vec<u8> {
    let mut b = Vec::new();
    u32le(&mut b, 0x06064b50);
    u64le(&mut b, 44);
    u16le(&mut b, 45);
    u16le(&mut b, 45);
    u32le(&mut b, 0);
    u32le(&mut b, 0);
    u64le(&mut b, count);
    u64le(&mut b, count);
    u64le(&mut b, size);
    u64le(&mut b, offset);
    u32le(&mut b, 0x07064b50);
    u32le(&mut b, 0);
    u64le(&mut b, offset + size);
    u32le(&mut b, 1);
    u32le(&mut b, 0x06054b50);
    u16le(&mut b, 0);
    u16le(&mut b, 0);
    u16le(&mut b, u16::MAX);
    u16le(&mut b, u16::MAX);
    u32le(&mut b, u32::MAX);
    u32le(&mut b, u32::MAX);
    u16le(&mut b, 0);
    b
}
fn length<T>(entries: &[Entry<T>]) -> Result<u64, AppError> {
    entries.iter().try_fold(98u64, |n, e| {
        n.checked_add(e.size)
            .and_then(|n| n.checked_add(148 + 2 * e.name.len() as u64))
            .ok_or(AppError::Status(StatusCode::PAYLOAD_TOO_LARGE))
    })
}
async fn send(tx: &mpsc::Sender<io::Result<Bytes>>, bytes: Bytes) -> io::Result<()> {
    for part in bytes.chunks(64 * 1024) {
        tx.send(Ok(Bytes::copy_from_slice(part)))
            .await
            .map_err(|_| io::Error::other("Download closed"))?;
    }
    Ok(())
}

pub(super) fn response<T, F, Fut>(
    entries: Vec<Entry<T>>,
    name: &str,
    check: bool,
    permit: SemaphorePermit<'static>,
    mut open: F,
) -> Result<Response<BoxedBody>, AppError>
where
    T: Send + 'static,
    F: FnMut(T) -> Fut + Send + 'static,
    Fut: Future<Output = Result<BoxedBody, AppError>> + Send + 'static,
{
    let len = length(&entries)?;
    let encoded = percent_encoding::utf8_percent_encode(name, percent_encoding::NON_ALPHANUMERIC);
    let mut builder = Response::builder()
        .header(header::CONTENT_TYPE, "application/zip")
        .header(
            header::CONTENT_DISPOSITION,
            format!("attachment; filename=\"LegnaSend.zip\"; filename*=UTF-8''{encoded}"),
        )
        .header(header::CONTENT_LENGTH, len)
        .header(header::ACCEPT_RANGES, "none")
        .header(header::CACHE_CONTROL, "no-store")
        .header("x-content-type-options", "nosniff")
        .header("x-legnasend-archive-entries", entries.len());
    if check {
        builder = builder.header("x-legnasend-archive-bytes", len);
        return Ok(builder
            .body(super::common::response::full_body(Bytes::new()))
            .unwrap());
    }
    let (tx, rx) = mpsc::channel(2);
    tokio::spawn(async move {
        let _permit = permit;
        let produce = async {
            let mut directory = Vec::with_capacity(entries.len());
            let mut offset = 0u64;
            for entry in entries {
                let header = local(&entry.name, entry.size);
                let start = offset;
                offset += header.len() as u64;
                // Open before the entry header so failed authorization/source
                // lookup never emits an apparently complete empty file.
                let mut body = tokio::time::timeout(Duration::from_secs(30), open(entry.source))
                    .await
                    .map_err(|_| io::Error::other("Source timed out"))?
                    .map_err(io::Error::other)?;
                send(&tx, header.into()).await?;
                let mut crc = crc32fast::Hasher::new();
                let mut read = 0u64;
                while let Some(frame) = tokio::time::timeout(Duration::from_secs(30), body.frame())
                    .await
                    .map_err(|_| io::Error::other("Source timed out"))?
                {
                    let frame = frame?;
                    if let Ok(bytes) = frame.into_data() {
                        read = read
                            .checked_add(bytes.len() as u64)
                            .ok_or_else(|| io::Error::other("Source size"))?;
                        if read > entry.size {
                            return Err(io::Error::other("Source changed"));
                        }
                        crc.update(&bytes);
                        send(&tx, bytes).await?;
                    }
                }
                if read != entry.size {
                    return Err(io::Error::other("Source changed or access ended"));
                }
                let crc = crc.finalize();
                send(&tx, descriptor(crc, read).into()).await?;
                offset += read + 24;
                directory.push(central(&entry.name, read, crc, start));
            }
            let start = offset;
            let count = directory.len() as u64;
            for record in directory {
                offset += record.len() as u64;
                send(&tx, record.into()).await?;
            }
            send(&tx, end(count, offset - start, start).into()).await
        };
        tokio::select! {
            _=tx.closed()=>{},
            result=produce=>if let Err(e)=result {let _=tx.send(Err(e)).await;},
        }
    });
    Ok(builder
        .body(StreamBody::new(ReceiverStream::new(rx).map(|r| r.map(Frame::data))).boxed())
        .unwrap())
}

pub(super) fn scan_deadline() -> Instant {
    Instant::now() + Duration::from_secs(15)
}

#[cfg(test)]
mod tests {
    use super::super::common::response::full_body;
    use super::*;
    #[test]
    fn paths_and_conflicting_prefixes_are_rejected() {
        for name in [
            "../a", "/a", "C:/a", "a\\b", "a//b", "CON.txt", "a/../b", "a\n", "a?.txt", "x|y",
        ] {
            assert!(valid_name(name).is_err(), "{name:?}");
        }
        assert!(valid_name("中文 空格/empty/").is_ok());
        let mut plan = Plan::new();
        plan.push(Entry {
            name: "a".into(),
            size: 0,
            source: (),
        })
        .unwrap();
        assert!(
            plan.push(Entry {
                name: "A".into(),
                size: 0,
                source: ()
            })
            .is_err()
        );
        let mut plan = Plan::new();
        plan.push(Entry {
            name: "a".into(),
            size: 0,
            source: (),
        })
        .unwrap();
        plan.push(Entry {
            name: "a/b".into(),
            size: 0,
            source: (),
        })
        .unwrap();
        assert!(plan.finish().is_err());
    }
    #[test]
    fn zip64_sizes_and_offsets_are_not_truncated() {
        let size = u32::MAX as u64 + 42;
        let entry = Entry {
            name: "large.bin".into(),
            size,
            source: (),
        };
        assert_eq!(length(&[entry]).unwrap(), size + 98 + 148 + 18);
        let record = central("large.bin", size, 1, size + 1000);
        assert_eq!(
            u64::from_le_bytes(record[record.len() - 8..].try_into().unwrap()),
            size + 1000
        );
        assert!(
            length(&[Entry {
                name: "large".into(),
                size: u64::MAX,
                source: ()
            }])
            .is_err()
        );
    }
    #[tokio::test]
    async fn errors_never_finish_a_partial_archive_and_dropping_body_frees_permit() {
        let response = super::response(
            vec![Entry {
                name: "short".into(),
                size: 4,
                source: (),
            }],
            "x.zip",
            false,
            permit().unwrap(),
            |_| async { Ok(full_body("x")) },
        )
        .unwrap();
        assert!(response.into_body().collect().await.is_err());
        tokio::task::yield_now().await;
        let response = super::response(
            vec![Entry {
                name: "stalled".into(),
                size: 4,
                source: (),
            }],
            "x.zip",
            false,
            permit().unwrap(),
            |_| async { std::future::pending::<Result<BoxedBody, AppError>>().await },
        )
        .unwrap();
        drop(response);
        tokio::time::sleep(Duration::from_millis(30)).await;
        assert_eq!(ACTIVE.available_permits(), 2);
        let response = super::response(
            vec![Entry {
                name: "zero".into(),
                size: 0,
                source: (),
            }],
            "x.zip",
            false,
            permit().unwrap(),
            |_| async { Ok(full_body(Bytes::new())) },
        )
        .unwrap();
        let size = response.headers()[header::CONTENT_LENGTH]
            .to_str()
            .unwrap()
            .parse::<usize>()
            .unwrap();
        assert_eq!(
            response
                .into_body()
                .collect()
                .await
                .unwrap()
                .to_bytes()
                .len(),
            size
        );
    }
}
