//! Seekable HTTP [`MediaSource`] for remote audio streaming.
//!
//! Issues block-granularity ranged GETs (~1 MiB). `seek` drops the buffer and
//! records the target offset; the next `read` issues `Range: bytes=N-` and
//! refills. Total length is resolved from `Content-Range` on the first ranged
//! response. All fields are `Sync` (no persistent reader handle), so the struct
//! is `Send + Sync` without a `Mutex`.

use std::collections::HashMap;
use std::collections::VecDeque;
use std::io::{self, Read, Seek, SeekFrom};
use std::sync::{
    atomic::{AtomicBool, Ordering},
    Arc, Condvar, Mutex,
};
use std::thread;
use std::time::Duration;
use symphonia::core::io::MediaSource;

const BLOCK_SIZE: usize = 1024 * 1024; // 1 MiB

/// Prefetch buffer sizing (time-based, cf. UAPP's `i_networkBufferSizeSeconds`).
///
/// Target: 15 seconds of audio buffered ahead of the decoder, sized for the
/// highest plausible TIDAL bitrate (~10 Mbps for 192 kHz / 24-bit stereo
/// FLAC). At lower bitrates the same byte budget covers proportionally more
/// seconds (e.g. ~90 s at 44.1 kHz / 16-bit). A fixed byte size would give
/// wildly different time coverage per track; time is the correct unit for
/// a jitter buffer.
const PREFETCH_TARGET_SECS: u64 = 15;
const PREFETCH_MAX_BYTES_PER_SEC: u64 = 1_250_000; // ~10 Mbps
const PREFETCH_CAPACITY: usize = (PREFETCH_TARGET_SECS * PREFETCH_MAX_BYTES_PER_SEC) as usize;

/// Rewind window kept behind the read cursor so the small backward seeks
/// symphonia performs during probing are served from memory instead of
/// triggering a prefetch reset + re-download.
const PREFETCH_REWIND_WINDOW: usize = 1024 * 1024; // 1 MiB

// ponytail: global timeouts so a stalled network can't pin the command thread.
pub(crate) fn http_agent() -> &'static ureq::Agent {
    static AGENT: std::sync::OnceLock<ureq::Agent> = std::sync::OnceLock::new();
    AGENT.get_or_init(|| {
        ureq::AgentBuilder::new()
            .timeout_connect(Duration::from_secs(10))
            .timeout_read(Duration::from_secs(30))
            .build()
    })
}

/// Fetch one block via ranged GET. Returns `(data, total_len, is_complete)`:
/// `total_len` is the resource length when the server reports it,
/// `is_complete` is true when no further fetches are needed (server ignored
/// Range and sent the whole body, or the range hit EOF).
fn fetch_block(
    url: &str,
    headers: &HashMap<String, String>,
    offset: u64,
    max_len: usize,
) -> io::Result<(Vec<u8>, Option<u64>, bool)> {
    let end = offset + max_len as u64 - 1;
    let mut req = http_agent().get(url);
    for (k, v) in headers {
        req = req.set(k, v);
    }
    req = req.set("Range", &format!("bytes={}-{}", offset, end));

    let resp = match req.call() {
        Ok(r) => r,
        Err(ureq::Error::Status(416, _)) => {
            // Range Not Satisfiable: offset is past EOF.
            return Ok((Vec::new(), None, true));
        }
        Err(e) => return Err(io::Error::other(format!("HTTP GET failed: {}", e))),
    };

    let status = resp.status();
    let content_range = resp.header("Content-Range").map(|s| s.to_string());
    let content_length = resp.header("Content-Length").map(|s| s.to_string());

    let mut buf = Vec::new();
    resp.into_reader().read_to_end(&mut buf)?;

    if status == 206 {
        let total = content_range
            .as_deref()
            .and_then(|cr| cr.split('/').nth(1))
            .and_then(|s| s.parse::<u64>().ok());
        let is_empty = buf.is_empty();
        Ok((buf, total, is_empty))
    } else {
        // Server ignored Range (200 OK full body). Only valid at offset 0.
        if offset != 0 {
            return Err(io::Error::new(
                io::ErrorKind::UnexpectedEof,
                "server does not support Range requests; cannot serve offset",
            ));
        }
        let total = content_length.and_then(|s| s.parse::<u64>().ok());
        Ok((buf, total, true))
    }
}

pub struct HttpMediaSource {
    url: String,
    headers: HashMap<String, String>,
    pos: u64,
    len: Option<u64>,
    buf: Vec<u8>,
    buf_start: u64,
}

impl HttpMediaSource {
    pub fn new(url: String, headers: HashMap<String, String>) -> Self {
        Self {
            url,
            headers,
            pos: 0,
            len: None,
            buf: Vec::new(),
            buf_start: 0,
        }
    }

    fn ensure_buffered(&mut self) -> io::Result<()> {
        if !self.buf.is_empty()
            && self.pos >= self.buf_start
            && self.pos < self.buf_start + self.buf.len() as u64
        {
            return Ok(());
        }

        let (buf, total, _) = fetch_block(&self.url, &self.headers, self.pos, BLOCK_SIZE)?;
        if let Some(t) = total {
            self.len = Some(t);
        }
        self.buf_start = self.pos;
        self.buf = buf;
        Ok(())
    }
}

impl Read for HttpMediaSource {
    fn read(&mut self, dst: &mut [u8]) -> io::Result<usize> {
        if dst.is_empty() {
            return Ok(0);
        }
        if let Some(len) = self.len {
            if self.pos >= len {
                return Ok(0);
            }
        }
        self.ensure_buffered()?;
        if self.buf.is_empty() {
            return Ok(0);
        }
        let offset_in_buf = (self.pos - self.buf_start) as usize;
        let available = &self.buf[offset_in_buf..];
        let n = available.len().min(dst.len());
        dst[..n].copy_from_slice(&available[..n]);
        self.pos += n as u64;
        Ok(n)
    }
}

impl Seek for HttpMediaSource {
    fn seek(&mut self, pos: SeekFrom) -> io::Result<u64> {
        let new_pos = match pos {
            SeekFrom::Start(n) => n as i64,
            SeekFrom::End(n) => self
                .len
                .map(|l| l as i64 + n)
                .ok_or_else(|| io::Error::new(io::ErrorKind::Unsupported, "length unknown"))?,
            SeekFrom::Current(n) => self.pos as i64 + n,
        };
        if new_pos < 0 {
            return Err(io::Error::new(io::ErrorKind::InvalidInput, "negative seek"));
        }
        self.pos = new_pos as u64;
        self.buf.clear();
        Ok(self.pos)
    }
}

impl MediaSource for HttpMediaSource {
    fn is_seekable(&self) -> bool {
        self.len.is_some()
    }
    fn byte_len(&self) -> Option<u64> {
        self.len
    }
}

// ---------------------------------------------------------------------------
// PrefetchingMediaSource
// ---------------------------------------------------------------------------
//
// A [`MediaSource`] wrapper that decouples network I/O from the decoder
// thread (conceptually UAPP's `DoubleBuffer`: separate network and decode
// stages). A background worker thread continuously fetches 1 MiB blocks
// ahead of the read cursor into a shared deque; `read()` is served purely
// from memory and only blocks when the prefetcher has not yet caught up.
//
// Why: previously the decoder thread performed a blocking ranged GET every
// time its 1 MiB window was exhausted. On mobile-network jitter a single
// slow fetch starved the 5 s PCM ring (only ~1.25 s at 192 kHz), producing
// audible stutter ("macet-macet"). With prefetching, network jitter is
// absorbed by the prefetch buffer and never stalls decode.

struct PrefetchShared {
    deque: VecDeque<u8>,
    /// File offset of `deque[0]`.
    deque_start: u64,
    /// Next byte the foreground will serve.
    pos: u64,
    /// Next byte the worker should fetch.
    fetch_pos: u64,
    len: Option<u64>,
    eof: bool,
    error: Option<String>,
    /// Bumped on seek-reset; the worker discards in-flight fetches from an
    /// older generation.
    generation: u64,
}

/// Seekable, prefetching HTTP [`MediaSource`]. All blocking network I/O
/// happens on an internal worker thread; the owning (decoder) thread only
/// touches the shared deque.
pub struct PrefetchingMediaSource {
    pair: Arc<(Mutex<PrefetchShared>, Condvar)>,
    stop: Arc<AtomicBool>,
}

impl PrefetchingMediaSource {
    pub fn new(url: String, headers: HashMap<String, String>) -> Self {
        let pair = Arc::new((
            Mutex::new(PrefetchShared {
                deque: VecDeque::new(),
                deque_start: 0,
                pos: 0,
                fetch_pos: 0,
                len: None,
                eof: false,
                error: None,
                generation: 0,
            }),
            Condvar::new(),
        ));
        let stop = Arc::new(AtomicBool::new(false));

        let worker_pair = Arc::clone(&pair);
        let worker_stop = Arc::clone(&stop);
        thread::Builder::new()
            .name("http-prefetch".to_string())
            .spawn(move || prefetch_worker(url, headers, worker_pair, worker_stop))
            .expect("failed to spawn http-prefetch thread");

        Self { pair, stop }
    }
}

impl Drop for PrefetchingMediaSource {
    fn drop(&mut self) {
        // Signal the worker; it is detached and exits on its next state
        // check (we deliberately do not join: a join could block the audio
        // thread for up to the HTTP read timeout).
        self.stop.store(true, Ordering::Relaxed);
        self.pair.1.notify_all();
    }
}

fn prefetch_worker(
    url: String,
    headers: HashMap<String, String>,
    pair: Arc<(Mutex<PrefetchShared>, Condvar)>,
    stop: Arc<AtomicBool>,
) {
    let (lock, cvar) = &*pair;
    let mut consecutive_errors = 0u32;

    loop {
        // 1. Decide the next fetch offset (holding the lock).
        let (offset, generation) = {
            let mut g = lock.lock().unwrap();
            loop {
                if stop.load(Ordering::Relaxed) {
                    return;
                }
                if g.eof || g.error.is_some() {
                    // Nothing to fetch; wait for a seek-reset or stop.
                    g = cvar.wait(g).unwrap();
                    continue;
                }
                if let Some(len) = g.len {
                    if g.fetch_pos >= len {
                        g.eof = true;
                        cvar.notify_all();
                        g = cvar.wait(g).unwrap();
                        continue;
                    }
                }
                if g.deque.len() >= PREFETCH_CAPACITY {
                    // Buffer full; wait until the foreground drains it.
                    g = cvar.wait(g).unwrap();
                    continue;
                }
                break;
            }
            (g.fetch_pos, g.generation)
        };

        // 2. Fetch without holding the lock.
        match fetch_block(&url, &headers, offset, BLOCK_SIZE) {
            Ok((data, total_len, is_complete)) => {
                consecutive_errors = 0;
                let mut g = lock.lock().unwrap();
                if stop.load(Ordering::Relaxed) {
                    return;
                }
                if g.generation != generation {
                    // A seek-reset happened mid-fetch; discard stale data.
                    continue;
                }
                if let Some(t) = total_len {
                    g.len = Some(t);
                }
                if !data.is_empty() {
                    g.deque.extend(data.iter());
                    g.fetch_pos += data.len() as u64;
                }
                if is_complete || data.is_empty() {
                    g.eof = true;
                }
                cvar.notify_all();
            }
            Err(e) => {
                consecutive_errors += 1;
                if consecutive_errors >= 5 {
                    let mut g = lock.lock().unwrap();
                    g.error = Some(format!("prefetch failed after 5 attempts: {}", e));
                    cvar.notify_all();
                    return;
                }
                // Backoff (1 s, 2 s, 4 s, 8 s), wakeable by seek/stop.
                let backoff = Duration::from_secs(1u64 << consecutive_errors.min(4));
                let g = lock.lock().unwrap();
                let (g, _) = cvar.wait_timeout(g, backoff).unwrap();
                drop(g);
                if stop.load(Ordering::Relaxed) {
                    return;
                }
                // A seek-reset also clears the error streak implicitly by
                // changing generation; the next loop iteration re-reads state.
            }
        }
    }
}

impl Read for PrefetchingMediaSource {
    fn read(&mut self, dst: &mut [u8]) -> io::Result<usize> {
        if dst.is_empty() {
            return Ok(0);
        }
        let (lock, cvar) = &*self.pair;
        let mut g = lock.lock().unwrap();
        loop {
            if let Some(len) = g.len {
                if g.pos >= len {
                    return Ok(0);
                }
            }
            let deque_end = g.deque_start + g.deque.len() as u64;
            if g.pos >= g.deque_start && g.pos < deque_end {
                let off = (g.pos - g.deque_start) as usize;
                let n = (g.deque.len() - off).min(dst.len());
                // Copy out, handling the VecDeque wrap-around.
                let (front, back) = g.deque.as_slices();
                if off < front.len() {
                    let k = (front.len() - off).min(n);
                    dst[..k].copy_from_slice(&front[off..off + k]);
                    if k < n {
                        dst[k..n].copy_from_slice(&back[..n - k]);
                    }
                } else {
                    let boff = off - front.len();
                    dst[..n].copy_from_slice(&back[boff..boff + n]);
                }
                g.pos += n as u64;

                // Compact the consumed prefix, retaining a rewind window
                // for the decoder's small backward seeks.
                let consumed = (g.pos - g.deque_start) as usize;
                let drop_n = consumed.saturating_sub(PREFETCH_REWIND_WINDOW);
                if drop_n > 0 {
                    g.deque.drain(..drop_n);
                    g.deque_start += drop_n as u64;
                }
                cvar.notify_one(); // freed space for the worker
                return Ok(n);
            }
            if g.eof {
                return Ok(0);
            }
            if let Some(ref e) = g.error {
                return Err(io::Error::other(e.clone()));
            }
            // Wait for the worker to deliver data.
            let (guard, timeout) = cvar.wait_timeout(g, Duration::from_secs(30)).unwrap();
            g = guard;
            if timeout.timed_out() {
                return Err(io::Error::new(
                    io::ErrorKind::TimedOut,
                    "prefetch stall: no data within 30 s",
                ));
            }
        }
    }
}

impl Seek for PrefetchingMediaSource {
    fn seek(&mut self, pos: SeekFrom) -> io::Result<u64> {
        let (lock, cvar) = &*self.pair;
        // Resolve the target first (may fail without holding the lock).
        let target_i64 = match pos {
            SeekFrom::Start(n) => n as i64,
            SeekFrom::Current(n) => lock.lock().unwrap().pos as i64 + n,
            SeekFrom::End(n) => {
                let len =
                    lock.lock().unwrap().len.ok_or_else(|| {
                        io::Error::new(io::ErrorKind::Unsupported, "length unknown")
                    })?;
                len as i64 + n
            }
        };
        if target_i64 < 0 {
            return Err(io::Error::new(io::ErrorKind::InvalidInput, "negative seek"));
        }
        let target = target_i64 as u64;

        let mut g = lock.lock().unwrap();
        let deque_end = g.deque_start + g.deque.len() as u64;
        if target >= g.deque_start && target < deque_end {
            // Fast path: target is already buffered (covers the decoder's
            // small probe seeks without disturbing the worker).
            g.pos = target;
        } else {
            // Slow path: reset prefetch state; the worker re-fetches from
            // the new position. The total length is unaffected.
            g.deque.clear();
            g.deque_start = target;
            g.pos = target;
            g.fetch_pos = target;
            g.eof = false;
            g.error = None;
            g.generation += 1;
        }
        cvar.notify_all();
        Ok(target)
    }
}

impl MediaSource for PrefetchingMediaSource {
    fn is_seekable(&self) -> bool {
        self.pair.0.lock().unwrap().len.is_some()
    }
    fn byte_len(&self) -> Option<u64> {
        self.pair.0.lock().unwrap().len
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;
    use std::net::{TcpListener, TcpStream};
    use std::thread;

    // ponytail: in-process HTTP/1.1 server honoring Range; no ureq mock needed.
    fn spawn_server(data: &'static [u8]) -> String {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = listener.local_addr().unwrap();
        let url = format!("http://{}/track", addr);
        thread::spawn(move || {
            for stream in listener.incoming() {
                let mut stream = stream.unwrap();
                serve_one(&mut stream, data);
            }
        });
        url
    }

    fn serve_one(stream: &mut TcpStream, data: &[u8]) {
        let mut buf = [0u8; 1024];
        let n = stream.read(&mut buf).unwrap_or(0);
        let req = String::from_utf8_lossy(&buf[..n]);
        let range = req
            .lines()
            .find(|l| l.to_ascii_lowercase().starts_with("range:"))
            .and_then(|l| l.split(':').nth(1))
            .map(|s| s.trim().to_string());

        let (status, headers, body_range) = match range.as_deref() {
            Some(r) if r.starts_with("bytes=") => {
                let spec = &r[6..];
                let (lo_s, hi_s) = spec.split_once('-').unwrap_or((spec, ""));
                let lo: usize = lo_s.parse().unwrap_or(0);
                let hi: usize = if hi_s.is_empty() {
                    data.len().saturating_sub(1)
                } else {
                    hi_s.parse().unwrap_or(data.len() - 1)
                };
                let hi = hi.min(data.len() - 1);
                (
                    "206 Partial Content",
                    format!(
                        "Content-Range: bytes {}-{}/{}\r\nContent-Length: {}\r\n",
                        lo,
                        hi,
                        data.len(),
                        hi - lo + 1
                    ),
                    lo..=hi,
                )
            }
            _ => (
                "200 OK",
                format!("Content-Length: {}\r\n", data.len()),
                0..=data.len() - 1,
            ),
        };
        let resp = format!(
            "HTTP/1.1 {}\r\n{}Accept-Ranges: bytes\r\nConnection: close\r\n\r\n",
            status, headers
        );
        stream.write_all(resp.as_bytes()).unwrap();
        stream.write_all(&data[body_range]).unwrap();
        stream.flush().unwrap();
    }

    #[test]
    fn sequential_read_and_len() {
        let data: Vec<u8> = (0..200_000u32).map(|i| (i % 251) as u8).collect();
        let data_box: &'static [u8] = Box::leak(data.into_boxed_slice());
        let url = spawn_server(data_box);
        let mut src = HttpMediaSource::new(url, HashMap::new());

        let mut got = [0u8; 4096];
        let mut total = 0usize;
        loop {
            let n = src.read(&mut got).unwrap();
            if n == 0 {
                break;
            }
            assert_eq!(&got[..n], &data_box[total..total + n]);
            total += n;
        }
        assert_eq!(total, data_box.len());
        assert_eq!(src.byte_len(), Some(data_box.len() as u64));
        assert!(src.is_seekable());
    }

    #[test]
    fn seek_then_read() {
        let data: Vec<u8> = (0..150_000u32).map(|i| (i % 251) as u8).collect();
        let data_box: &'static [u8] = Box::leak(data.into_boxed_slice());
        let url = spawn_server(data_box);
        let mut src = HttpMediaSource::new(url, HashMap::new());

        src.seek(SeekFrom::Start(70_000)).unwrap();
        let mut got = [0u8; 1024];
        let n = src.read(&mut got).unwrap();
        assert_eq!(n, 1024);
        assert_eq!(&got[..n], &data_box[70_000..71_024]);

        // Seek back to start.
        src.seek(SeekFrom::Start(0)).unwrap();
        let n = src.read(&mut got).unwrap();
        assert_eq!(&got[..n], &data_box[0..1024]);
    }

    // --- PrefetchingMediaSource tests ---

    fn wait_for<F: Fn() -> bool>(f: F, what: &str) {
        for _ in 0..200 {
            if f() {
                return;
            }
            thread::sleep(Duration::from_millis(10));
        }
        panic!("timed out waiting for {}", what);
    }

    #[test]
    fn prefetch_sequential_read_matches() {
        let data: Vec<u8> = (0..300_000u32).map(|i| (i % 251) as u8).collect();
        let data_box: &'static [u8] = Box::leak(data.into_boxed_slice());
        let url = spawn_server(data_box);
        let mut src = PrefetchingMediaSource::new(url, HashMap::new());

        // The worker should learn the total length from the first fetch.
        wait_for(|| src.byte_len() == Some(data_box.len() as u64), "length");
        assert!(src.is_seekable());

        let mut got = [0u8; 8192];
        let mut total = 0usize;
        loop {
            let n = src.read(&mut got).unwrap();
            if n == 0 {
                break;
            }
            assert_eq!(&got[..n], &data_box[total..total + n]);
            total += n;
        }
        assert_eq!(total, data_box.len());
    }

    #[test]
    fn prefetch_seek_forward_then_read() {
        let data: Vec<u8> = (0..300_000u32).map(|i| (i % 251) as u8).collect();
        let data_box: &'static [u8] = Box::leak(data.into_boxed_slice());
        let url = spawn_server(data_box);
        let mut src = PrefetchingMediaSource::new(url, HashMap::new());
        wait_for(|| src.byte_len().is_some(), "length");

        // Forward seek past the initially prefetched window -> slow path.
        src.seek(SeekFrom::Start(250_000)).unwrap();
        let mut got = [0u8; 1024];
        let n = src.read(&mut got).unwrap();
        assert_eq!(n, 1024);
        assert_eq!(&got[..n], &data_box[250_000..251_024]);
    }

    #[test]
    fn prefetch_backward_seek_within_window() {
        let data: Vec<u8> = (0..300_000u32).map(|i| (i % 251) as u8).collect();
        let data_box: &'static [u8] = Box::leak(data.into_boxed_slice());
        let url = spawn_server(data_box);
        let mut src = PrefetchingMediaSource::new(url, HashMap::new());
        wait_for(|| src.byte_len().is_some(), "length");

        // Read ahead, then seek a little backward (fast path: served from memory).
        let mut got = [0u8; 4096];
        let mut total = 0usize;
        for _ in 0..10 {
            total += src.read(&mut got).unwrap();
        }
        assert!(total > 5000);
        src.seek(SeekFrom::Start((total - 1000) as u64)).unwrap();
        let n = src.read(&mut got).unwrap();
        assert_eq!(&got[..n], &data_box[total - 1000..total - 1000 + n]);
    }

    #[test]
    fn prefetch_fills_before_first_read() {
        // Fast-start property: the worker begins fetching at construction,
        // so data is already waiting when the decoder performs its first read.
        let data: Vec<u8> = (0..300_000u32).map(|i| (i % 251) as u8).collect();
        let data_box: &'static [u8] = Box::leak(data.into_boxed_slice());
        let url = spawn_server(data_box);
        let src = PrefetchingMediaSource::new(url, HashMap::new());
        wait_for(
            || src.pair.0.lock().unwrap().deque.len() > 0,
            "prefetched bytes",
        );
    }
}
