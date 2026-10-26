//! Seekable HTTP [`MediaSource`] for remote audio streaming.
//!
//! Data is fetched with ranged GETs (up to 1 MiB of range per request) on a
//! background worker and handed to the consumer *progressively*: every chunk is
//! published to the shared buffer as soon as the socket yields it, so the
//! demuxer can probe a FLAC stream from the first few kilobytes instead of
//! waiting for a whole 1 MiB block to land. The resource length is published
//! from `Content-Range`/`Content-Length` the moment the response headers arrive,
//! so `is_seekable()` and `byte_len()` are authoritative before the body is
//! transferred.
//!
//! `seek` drops the buffer and records the target offset; the worker issues
//! `Range: bytes=N-` and refills. Total length is resolved from the first
//! ranged response. All fields are `Sync` (no persistent reader handle), so the
//! struct is `Send + Sync` without a `Mutex`.

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

const BLOCK_SIZE: usize = 1024 * 1024; // 1 MiB of range requested per GET

/// Progressive delivery granularity. Chunks reach the shared buffer as they
/// arrive; this only caps how much a single socket read can hand over, trading
/// lock traffic against flow-control resolution. 64 KiB is ~25 ms of 24/192
/// FLAC — far below any audible buffering threshold.
const STREAMING_CHUNK_SIZE: usize = 64 * 1024;

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

/// A ranged GET whose body has not been consumed yet.
struct RangeResponse {
    resp: ureq::Response,
    /// Resource length advertised by the server: the `Content-Range` total for
    /// a 206, or `Content-Length` for a 200 full body.
    total_len: Option<u64>,
    /// The server ignored `Range` and is sending the whole resource.
    whole_resource: bool,
}

/// Issue the ranged GET for `bytes=offset..=(offset + max_len - 1)` and parse
/// the advertised resource length from the response headers, without touching
/// the body. `Ok(None)` means the server rejected the range as unsatisfiable,
/// i.e. the offset is at or past EOF.
fn open_range(
    url: &str,
    headers: &HashMap<String, String>,
    offset: u64,
    max_len: usize,
) -> io::Result<Option<RangeResponse>> {
    let end = offset + max_len as u64 - 1;
    let mut req = http_agent().get(url);
    for (k, v) in headers {
        if k.to_ascii_lowercase().starts_with("x-flick-") {
            continue;
        }
        req = req.set(k, v);
    }
    req = req.set("Range", &format!("bytes={}-{}", offset, end));

    let resp = match req.call() {
        Ok(r) => r,
        Err(ureq::Error::Status(416, _)) => {
            // Range Not Satisfiable: offset is past EOF.
            return Ok(None);
        }
        Err(e) => return Err(io::Error::other(format!("HTTP GET failed: {}", e))),
    };

    let status = resp.status();
    if status == 206 {
        let total_len = resp
            .header("Content-Range")
            .and_then(|cr| cr.split('/').nth(1))
            .and_then(|s| s.parse::<u64>().ok());
        Ok(Some(RangeResponse {
            resp,
            total_len,
            whole_resource: false,
        }))
    } else {
        // Server ignored Range (200 OK full body). Only valid at offset 0.
        if offset != 0 {
            return Err(io::Error::new(
                io::ErrorKind::UnexpectedEof,
                "server does not support Range requests; cannot serve offset",
            ));
        }
        let total_len = resp
            .header("Content-Length")
            .and_then(|s| s.parse::<u64>().ok());
        Ok(Some(RangeResponse {
            resp,
            total_len,
            whole_resource: true,
        }))
    }
}

/// Fetch one block via ranged GET, atomically. Returns `(data, total_len,
/// is_complete)`: `total_len` is the resource length when the server reports
/// it, `is_complete` is true when no further fetches are needed (server ignored
/// Range and sent the whole body, or the range hit EOF).
///
/// Only [`HttpMediaSource`] reads blocks atomically; [`PrefetchingMediaSource`]
/// streams the same response progressively instead.
fn fetch_block(
    url: &str,
    headers: &HashMap<String, String>,
    offset: u64,
    max_len: usize,
) -> io::Result<(Vec<u8>, Option<u64>, bool)> {
    let Some(response) = open_range(url, headers, offset, max_len)? else {
        return Ok((Vec::new(), None, true));
    };
    let RangeResponse {
        resp,
        total_len,
        whole_resource,
    } = response;

    let mut buf = Vec::new();
    resp.into_reader().read_to_end(&mut buf)?;

    let is_complete = whole_resource || buf.is_empty();
    Ok((buf, total_len, is_complete))
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
// stages). A background worker thread continuously fetches up to 1 MiB of
// range per request ahead of the read cursor into a shared deque, handing each
// arriving chunk over as soon as the socket delivers it; `read()` is served
// purely from memory and only blocks when the prefetcher has not yet caught up.
//
// Why chunk-level hand-off matters: probing a FLAC stream needs the `fLaC`
// marker plus the metadata blocks (a few KiB). Publishing a whole 1 MiB block
// only after `read_to_end` returned made every play start pay the full block
// download before symphonia could inspect byte 0 — seconds on a slow link, and
// always slower than the DASH path's small init + first segment.
//
// Why prefetching at all: previously the decoder thread performed a blocking
// ranged GET every time its 1 MiB window was exhausted. On mobile-network
// jitter a single slow fetch starved the 5 s PCM ring (only ~1.25 s at
// 192 kHz), producing audible stutter ("macet-macet"). With prefetching,
// network jitter is absorbed by the prefetch buffer and never stalls decode.

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

/// How one progressive range stream ended.
enum StreamEnd {
    /// The requested range (or the whole body) was delivered; fetch the next.
    RangeDone,
    /// The resource ended (short body, known length reached, or 416).
    Eof,
    /// Superseded by `stop` or a seek; nothing was published past the abort.
    Aborted,
}

/// Stream one ranged GET straight into the shared deque.
///
/// The response headers publish the authoritative length before any body byte
/// is moved, and the body is appended chunk by chunk (never more than
/// `PREFETCH_CAPACITY` ahead of the decoder). `stop` and `generation` are
/// re-checked between chunks, so a seek or teardown abandons the response
/// promptly and none of its late bytes can corrupt the buffer.
fn stream_range(
    url: &str,
    headers: &HashMap<String, String>,
    pair: &Arc<(Mutex<PrefetchShared>, Condvar)>,
    stop: &AtomicBool,
    generation: u64,
    offset: u64,
    max_len: usize,
) -> io::Result<StreamEnd> {
    let (lock, cvar) = &**pair;

    let Some(response) = open_range(url, headers, offset, max_len)? else {
        // 416: the offset is past EOF.
        let mut g = lock.lock().unwrap();
        if stop.load(Ordering::Relaxed) || g.generation != generation {
            return Ok(StreamEnd::Aborted);
        }
        g.eof = true;
        cvar.notify_all();
        return Ok(StreamEnd::Eof);
    };
    let RangeResponse {
        resp,
        total_len,
        whole_resource,
    } = response;

    // Headers are in: publish the length now, before the body moves, so
    // `is_seekable()`/`byte_len()` are authoritative for the probe.
    {
        let mut g = lock.lock().unwrap();
        if stop.load(Ordering::Relaxed) || g.generation != generation {
            return Ok(StreamEnd::Aborted);
        }
        if total_len.is_some() {
            g.len = total_len;
        }
        cvar.notify_all();
    }

    let mut reader = resp.into_reader();
    let mut chunk = vec![0u8; STREAMING_CHUNK_SIZE];
    let mut delivered = 0u64;

    loop {
        // Flow control before pulling more off the socket: the network stage
        // must never run more than PREFETCH_CAPACITY ahead of the decoder.
        {
            let mut g = lock.lock().unwrap();
            while g.deque.len() >= PREFETCH_CAPACITY {
                g = cvar.wait(g).unwrap();
                if stop.load(Ordering::Relaxed) || g.generation != generation {
                    return Ok(StreamEnd::Aborted);
                }
            }
            if stop.load(Ordering::Relaxed) || g.generation != generation {
                return Ok(StreamEnd::Aborted);
            }
        }

        let n = match reader.read(&mut chunk) {
            Ok(0) => break,
            Ok(n) => n,
            Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
            // Bytes already published stay valid, and `fetch_pos` marks exactly
            // where this response stopped, so a retry resumes there.
            Err(e) => return Err(e),
        };

        let mut g = lock.lock().unwrap();
        if stop.load(Ordering::Relaxed) || g.generation != generation {
            return Ok(StreamEnd::Aborted);
        }
        // Invariant: `deque_start + deque.len() == fetch_pos`. Only the worker
        // appends and only the foreground drains the head, so appending here
        // keeps a later retry byte-exact.
        g.deque.extend(chunk[..n].iter().copied());
        g.fetch_pos += n as u64;
        cvar.notify_all();
        delivered += n as u64;
    }

    let mut g = lock.lock().unwrap();
    if stop.load(Ordering::Relaxed) || g.generation != generation {
        return Ok(StreamEnd::Aborted);
    }
    let reached_total = g.len.is_some_and(|len| g.fetch_pos >= len);
    let short_body = delivered < max_len as u64;
    let eof =
        reached_total || delivered == 0 || (g.len.is_none() && (whole_resource || short_body));
    if eof {
        g.eof = true;
    }
    cvar.notify_all();
    drop(g);

    Ok(if eof {
        StreamEnd::Eof
    } else {
        StreamEnd::RangeDone
    })
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

        // 2. Stream the range into the shared deque without holding the lock
        //    across a network read; chunks are released as they arrive.
        match stream_range(&url, &headers, &pair, &stop, generation, offset, BLOCK_SIZE) {
            Ok(StreamEnd::RangeDone | StreamEnd::Eof) => {
                consecutive_errors = 0;
                // `eof` (when reached) is already published; the next iteration
                // re-reads the shared state before fetching again.
            }
            Ok(StreamEnd::Aborted) => {
                // stop or a seek-reset superseded this fetch: drop the response
                // and let the next iteration re-read the shared state.
                continue;
            }
            Err(e) => {
                // A seek to a new position deserves a fresh error budget.
                if lock.lock().unwrap().generation != generation {
                    consecutive_errors = 0;
                    continue;
                }
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
    use std::time::Instant;

    /// Deterministic, position-dependent payload: a shifted or duplicated chunk
    /// shows up as a byte mismatch.
    fn test_data(len: usize) -> &'static [u8] {
        let data: Vec<u8> = (0..len as u32).map(|i| (i % 251) as u8).collect();
        Box::leak(data.into_boxed_slice())
    }

    /// Release-once latch the test server blocks on while it pretends to be a
    /// slow link, so "did the client get bytes early?" is a real assertion.
    #[derive(Default)]
    struct Gate {
        open: Mutex<bool>,
        cvar: Condvar,
    }

    impl Gate {
        fn new() -> Arc<Self> {
            Arc::new(Self::default())
        }

        fn release(&self) {
            *self.open.lock().unwrap() = true;
            self.cvar.notify_all();
        }

        /// Blocks until released or `timeout` elapses, so a regression fails an
        /// assertion instead of hanging the suite.
        fn wait(&self, timeout: Duration) {
            let mut open = self.open.lock().unwrap();
            let deadline = Instant::now() + timeout;
            while !*open {
                let now = Instant::now();
                if now >= deadline {
                    return;
                }
                let (guard, _) = self.cvar.wait_timeout(open, deadline - now).unwrap();
                open = guard;
            }
        }
    }

    #[derive(Clone)]
    struct ServerBehaviour {
        /// Answer 200 with the whole body, ignoring the Range request.
        ignore_range: bool,
        /// Bytes written before the gate opens.
        prefix_len: usize,
        /// How long the body stalls once the gate is armed.
        stall: Duration,
        /// When set, the body pauses after `prefix_len` bytes.
        gate: Option<Arc<Gate>>,
    }

    impl Default for ServerBehaviour {
        fn default() -> Self {
            Self {
                ignore_range: false,
                prefix_len: 0,
                stall: Duration::from_secs(4),
                gate: None,
            }
        }
    }

    impl ServerBehaviour {
        /// Serve headers, then `prefix_len` bytes, then stall for up to
        /// `stall` (or until the gate is released).
        fn stalled(prefix_len: usize, stall: Duration) -> (Self, Arc<Gate>) {
            let gate = Gate::new();
            (
                Self {
                    prefix_len,
                    stall,
                    gate: Some(Arc::clone(&gate)),
                    ..Self::default()
                },
                gate,
            )
        }

        fn stalled_ignoring_range(prefix_len: usize, stall: Duration) -> (Self, Arc<Gate>) {
            let (mut behaviour, gate) = Self::stalled(prefix_len, stall);
            behaviour.ignore_range = true;
            (behaviour, gate)
        }
    }

    // ponytail: in-process HTTP/1.1 server honoring Range; no ureq mock needed.
    // One thread per connection so a stalled body cannot block a later request.
    fn spawn_server_with(data: &'static [u8], behaviour: ServerBehaviour) -> String {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = listener.local_addr().unwrap();
        let url = format!("http://{}/track", addr);
        thread::spawn(move || {
            for stream in listener.incoming() {
                let Ok(mut stream) = stream else { continue };
                let behaviour = behaviour.clone();
                thread::spawn(move || serve_one(&mut stream, data, &behaviour));
            }
        });
        url
    }

    fn spawn_server(data: &'static [u8]) -> String {
        spawn_server_with(data, ServerBehaviour::default())
    }

    fn serve_one(stream: &mut TcpStream, data: &[u8], behaviour: &ServerBehaviour) {
        let mut buf = [0u8; 1024];
        let n = stream.read(&mut buf).unwrap_or(0);
        let req = String::from_utf8_lossy(&buf[..n]);
        let range = req
            .lines()
            .find(|l| l.to_ascii_lowercase().starts_with("range:"))
            .and_then(|l| l.split(':').nth(1))
            .map(|s| s.trim().to_string());

        let (status, headers, body_range) = match range.as_deref() {
            Some(r) if !behaviour.ignore_range && r.starts_with("bytes=") => {
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
        if stream.write_all(resp.as_bytes()).is_err() {
            return;
        }

        let body = &data[body_range];
        let prefix = behaviour.prefix_len.min(body.len());
        if stream.write_all(&body[..prefix]).is_err() {
            return;
        }
        if let Some(gate) = &behaviour.gate {
            let _ = stream.flush();
            gate.wait(behaviour.stall);
        }
        // The client may have closed the socket (seek/teardown): ignore errors.
        let _ = stream.write_all(&body[prefix..]);
        let _ = stream.flush();
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
            || !src.pair.0.lock().unwrap().deque.is_empty(),
            "prefetched bytes",
        );
    }

    #[test]
    fn prefetch_publishes_length_before_any_body_byte() {
        // The probe needs `is_seekable()`/`byte_len()` to be authoritative, and
        // it must not wait for the body to learn them.
        let data = test_data(BLOCK_SIZE);
        let (behaviour, gate) = ServerBehaviour::stalled(0, Duration::from_secs(4));
        let url = spawn_server_with(data, behaviour);
        let src = PrefetchingMediaSource::new(url, HashMap::new());

        wait_for(
            || src.byte_len() == Some(data.len() as u64),
            "length from response headers",
        );
        assert!(src.is_seekable());
        assert!(
            src.pair.0.lock().unwrap().deque.is_empty(),
            "length must come from headers, not from downloaded body bytes"
        );

        gate.release();
    }

    #[test]
    fn prefetch_serves_first_chunk_before_the_block_completes() {
        // The regression this file exists for: a 1 MiB ranged GET must not gate
        // the first bytes. The server stalls with 64 KiB out; a read must return
        // immediately instead of waiting for the rest of the block.
        let data = test_data(BLOCK_SIZE);
        let (behaviour, gate) = ServerBehaviour::stalled(64 * 1024, Duration::from_secs(4));
        let url = spawn_server_with(data, behaviour);
        let mut src = PrefetchingMediaSource::new(url, HashMap::new());

        let mut got = [0u8; 16 * 1024];
        let started = Instant::now();
        let n = src.read(&mut got).unwrap();
        let elapsed = started.elapsed();
        gate.release();

        assert_eq!(n, got.len());
        assert_eq!(&got[..n], &data[..n]);
        assert!(
            elapsed < Duration::from_secs(2),
            "first read waited for the whole 1 MiB block: {:?}",
            elapsed
        );

        // Everything after the stall still arrives, byte-exact.
        let mut total = n;
        let mut rest = vec![0u8; 32 * 1024];
        loop {
            let n = src.read(&mut rest).unwrap();
            if n == 0 {
                break;
            }
            assert_eq!(&rest[..n], &data[total..total + n]);
            total += n;
        }
        assert_eq!(total, data.len());
    }

    #[test]
    fn prefetch_streams_200_ok_body_progressively() {
        // A CDN that ignores Range must not freeze probing until the whole file
        // is in memory.
        let data = test_data(BLOCK_SIZE);
        let (behaviour, gate) =
            ServerBehaviour::stalled_ignoring_range(64 * 1024, Duration::from_secs(4));
        let url = spawn_server_with(data, behaviour);
        let mut src = PrefetchingMediaSource::new(url, HashMap::new());

        wait_for(
            || src.byte_len() == Some(data.len() as u64),
            "length from Content-Length",
        );

        let mut got = [0u8; 8192];
        let started = Instant::now();
        let n = src.read(&mut got).unwrap();
        let elapsed = started.elapsed();
        gate.release();

        assert_eq!(&got[..n], &data[..n]);
        assert!(
            elapsed < Duration::from_secs(2),
            "200 OK body was not served progressively: {:?}",
            elapsed
        );

        let mut total = n;
        let mut rest = vec![0u8; 32 * 1024];
        loop {
            let n = src.read(&mut rest).unwrap();
            if n == 0 {
                break;
            }
            assert_eq!(&rest[..n], &data[total..total + n]);
            total += n;
        }
        assert_eq!(total, data.len());
    }

    #[test]
    fn prefetch_seek_discards_inflight_stream() {
        // A seek during an active multi-chunk download must bump the generation,
        // abandon the stale response, and serve the new position without any of
        // the old body leaking into the buffer. (An in-flight `read` can only be
        // abandoned at the next chunk boundary — the abort window is now one
        // 64 KiB chunk instead of an entire 1 MiB block.)
        let data = test_data(BLOCK_SIZE);
        let (behaviour, gate) = ServerBehaviour::stalled(64 * 1024, Duration::from_secs(4));
        let url = spawn_server_with(data, behaviour);
        let mut src = PrefetchingMediaSource::new(url, HashMap::new());
        wait_for(|| src.byte_len() == Some(data.len() as u64), "length");

        // First chunk arrives while the response is still stalled mid-body.
        let mut got = [0u8; 8 * 1024];
        assert_eq!(src.read(&mut got).unwrap(), got.len());

        // Seek far outside the buffered window: slow path + generation bump.
        let target = 700_000u64;
        src.seek(SeekFrom::Start(target)).unwrap();
        {
            let g = src.pair.0.lock().unwrap();
            assert_eq!(g.generation, 1, "seek must invalidate the in-flight fetch");
            assert_eq!(g.fetch_pos, target);
            assert_eq!(g.deque_start, target);
            assert!(g.deque.is_empty());
            assert!(!g.eof);
        }

        // Let the aborted response finish: its remaining ~1 MiB must be
        // discarded, not appended after the new range.
        gate.release();

        let mut buf = vec![0u8; 32 * 1024];
        let n = src.read(&mut buf).unwrap();
        assert_eq!(
            &buf[..n],
            &data[target as usize..target as usize + n],
            "post-seek bytes do not match the new position"
        );

        // Drain to EOF: stale chunks from the aborted range must never surface.
        let mut pos = target as usize + n;
        loop {
            let n = src.read(&mut buf).unwrap();
            if n == 0 {
                break;
            }
            assert_eq!(&buf[..n], &data[pos..pos + n]);
            pos += n;
        }
        assert_eq!(pos, data.len());
    }

    /// Minimal 16-bit mono PCM WAV. Content-probed by symphonia exactly like
    /// the remote streams this module serves, so `probe_http` can be driven
    /// end-to-end without a binary fixture.
    fn wav_bytes(samples: usize) -> Vec<u8> {
        let data_len = (samples * 2) as u32;
        let mut v = Vec::with_capacity(44 + data_len as usize);
        v.extend_from_slice(b"RIFF");
        v.extend_from_slice(&(36 + data_len).to_le_bytes());
        v.extend_from_slice(b"WAVEfmt ");
        v.extend_from_slice(&16u32.to_le_bytes());
        v.extend_from_slice(&1u16.to_le_bytes()); // PCM
        v.extend_from_slice(&1u16.to_le_bytes()); // mono
        v.extend_from_slice(&44_100u32.to_le_bytes());
        v.extend_from_slice(&(44_100u32 * 2).to_le_bytes());
        v.extend_from_slice(&2u16.to_le_bytes());
        v.extend_from_slice(&16u16.to_le_bytes());
        v.extend_from_slice(b"data");
        v.extend_from_slice(&data_len.to_le_bytes());
        v.resize(44 + data_len as usize, 0);
        v
    }

    #[test]
    fn probe_http_does_not_wait_for_the_first_block() {
        // Acceptance test for the start-latency bug: probing a remote stream
        // must finish on the first few kilobytes, not after a whole 1 MiB GET.
        let data: &'static [u8] = Box::leak(wav_bytes(900_000).into_boxed_slice());
        let (behaviour, gate) = ServerBehaviour::stalled(64 * 1024, Duration::from_secs(4));
        let url = spawn_server_with(data, behaviour);

        let started = Instant::now();
        let probe = crate::audio::decoder::probe_http(&url, HashMap::new())
            .expect("probe should succeed from the first chunk");
        let elapsed = started.elapsed();
        gate.release();

        assert_eq!(probe.source_info.original_sample_rate, 44_100);
        assert!(
            elapsed < Duration::from_secs(2),
            "probe waited for the whole 1 MiB block: {:?}",
            elapsed
        );
    }

    #[test]
    fn prefetch_strips_flick_internal_headers() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = listener.local_addr().unwrap();
        let url = format!("http://{}/track", addr);
        let pair = Arc::new((Mutex::new(Vec::new()), Condvar::new()));
        let pair_clone = Arc::clone(&pair);

        thread::spawn(move || {
            if let Ok((mut stream, _)) = listener.accept() {
                let mut buf = [0u8; 1024];
                let n = stream.read(&mut buf).unwrap_or(0);
                let req = String::from_utf8_lossy(&buf[..n]).to_string();
                let _ = stream.write_all(b"HTTP/1.1 206 Partial Content\r\nContent-Range: bytes 0-3/4\r\nContent-Length: 4\r\n\r\ntest");
                let mut g = pair_clone.0.lock().unwrap();
                g.extend_from_slice(req.as_bytes());
                pair_clone.1.notify_all();
            }
        });

        let mut headers = HashMap::new();
        headers.insert("x-flick-sample-rate".to_string(), "44100".to_string());
        headers.insert("x-flick-bit-depth".to_string(), "16".to_string());
        headers.insert("Custom-Allowed".to_string(), "allowed-val".to_string());

        let _ = fetch_block(&url, &headers, 0, 4);

        let g = pair.0.lock().unwrap();
        let captured = String::from_utf8_lossy(&g).to_lowercase();
        assert!(!captured.contains("x-flick-sample-rate"));
        assert!(!captured.contains("x-flick-bit-depth"));
        assert!(captured.contains("custom-allowed"));
    }
}
