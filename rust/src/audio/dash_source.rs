//! Direct-CDN DASH [`MediaSource`].
//!
//! TIDAL's Hi-Res tracks are delivered as DASH: an initialization segment plus
//! an ordered list of media segments, each its own CDN object. The decoder
//! pipeline consumes one progressive, ranged-readable stream, so this source
//! fetches the segments itself (straight from the CDN, no local server) and
//! presents them as that single logical byte stream.
//!
//! The plan is not parsed from an MPD here. Dart already parses the manifest
//! (`DashManifestParser`) to pick a Representation, and hands the resulting
//! init URL plus ordered segment URLs over the existing `(url, headers)`
//! bridge call — the Rust side would otherwise need a second XML parser and a
//! second copy of the representation-selection rules. One parser, one
//! ordering: both engines fetch the same objects in the same order.
//!
//! Buffering: a background worker fetches segments in order into a bounded
//! window (memory, never disk). Reads are served from that window; a seek
//! inside it is instant, a backward seek re-fetches only the segment that
//! contains the target, and a forward seek past the window skips segments in
//! order. Skipped bytes still cost bandwidth — the CDN exposes no size
//! metadata the source could use to jump — but they are never written
//! anywhere, and the worker keeps prefetching while playback is steady.

use std::collections::HashMap;
use std::io::{self, Read, Seek, SeekFrom};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::thread;
use std::time::Duration;

use symphonia::core::io::MediaSource;

use crate::audio::http_source::http_agent;

/// Bytes retained ahead of the read cursor. At the highest plausible TIDAL
/// bitrate (~10 Mbps) this is ~25 s of audio — more than the 15 s the
/// BTS prefetcher targets, at a memory cost a phone can absorb.
const DASH_BUFFER_CAPACITY: usize = 32 * 1024 * 1024;

/// Rewind window kept behind the read cursor, so the decoder's small backward
/// probe seeks never trigger a refetch (mirrors the BTS prefetcher).
const DASH_REWIND_WINDOW: usize = 1024 * 1024;

/// Per-segment attempts before the source surfaces a fatal read error.
const SEGMENT_ATTEMPTS: u32 = 3;

const HEADER_INIT: &str = "x-flick-dash-init";
const HEADER_SEGMENTS: &str = "x-flick-dash-segments";

/// `dash://<trackId>` — the descriptor TidalService builds for the Rust
/// engine. The plan itself travels in the companion headers.
pub fn is_dash_descriptor(url: &str) -> bool {
    url.starts_with("dash://")
}

/// Init URL + ordered media segment URLs + the HTTP headers to send with each
/// fetch (auth for non-TIDAL sources, nothing for the TIDAL CDN).
pub struct DashPlan {
    init_url: String,
    segment_urls: Vec<String>,
    headers: HashMap<String, String>,
}

impl DashPlan {
    /// Build a plan from a descriptor's headers map, or return an error
    /// describing exactly which part of the plan is missing.
    pub fn from_headers(headers: &HashMap<String, String>) -> Result<Self, String> {
        let init_url = headers
            .iter()
            .find(|(k, _)| k.eq_ignore_ascii_case(HEADER_INIT))
            .map(|(_, v)| v.trim().to_string())
            .filter(|v| !v.is_empty())
            .ok_or_else(|| format!("DASH plan is missing {}", HEADER_INIT))?;

        let raw_segments = headers
            .iter()
            .find(|(k, _)| k.eq_ignore_ascii_case(HEADER_SEGMENTS))
            .map(|(_, v)| v.as_str())
            .ok_or_else(|| format!("DASH plan is missing {}", HEADER_SEGMENTS))?;

        let segment_urls: Vec<String> = raw_segments
            .split('\n')
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .map(str::to_string)
            .collect();
        if segment_urls.is_empty() {
            return Err("DASH plan has no media segments".to_string());
        }

        // `x-flick-*` is out-of-band metadata for this process, never a CDN
        // request header; forwarding it would be noise on every segment GET.
        let mut http_headers = HashMap::new();
        for (k, v) in headers {
            if k.to_ascii_lowercase().starts_with("x-flick-") {
                continue;
            }
            http_headers.insert(k.clone(), v.clone());
        }

        Ok(Self {
            init_url,
            segment_urls,
            headers: http_headers,
        })
    }

    /// Number of logical segments: index 0 is the initialization segment.
    fn len(&self) -> usize {
        self.segment_urls.len() + 1
    }

    fn url(&self, index: usize) -> &str {
        if index == 0 {
            &self.init_url
        } else {
            &self.segment_urls[index - 1]
        }
    }
}

struct DashShared {
    plan: Arc<DashPlan>,
    /// Retained window: logical bytes `[base, base + buf.len())`.
    buf: Vec<u8>,
    base: u64,
    /// End of everything fetched so far (retained or skipped).
    end: u64,
    /// Read cursor in logical byte space.
    pos: u64,
    /// Logical start of each fetched segment; index 0 is the init segment.
    starts: Vec<Option<u64>>,
    /// Next segment index the worker should fetch.
    next_seg: usize,
    /// Retain bytes at or after this offset; skipped bytes are discarded.
    retain_from: u64,
    /// Set once every segment has been fetched.
    total: Option<u64>,
    eof: bool,
    error: Option<String>,
    /// Bumped on every seek reset so an in-flight fetch from the old position
    /// is discarded instead of corrupting the window.
    generation: u64,
    skipped_segments: u64,
}

impl DashShared {
    fn is_fetched(&self, logical: u64) -> bool {
        logical >= self.base && logical < self.end
    }
}

/// Seekable, prefetching DASH [`MediaSource`] backed only by CDN GETs.
pub struct DashMediaSource {
    pair: Arc<(Mutex<DashShared>, Condvar)>,
    stop: Arc<AtomicBool>,
}

impl DashMediaSource {
    pub fn from_headers(headers: &HashMap<String, String>) -> Result<Self, String> {
        let plan = Arc::new(DashPlan::from_headers(headers)?);
        let len = plan.len();
        let pair = Arc::new((
            Mutex::new(DashShared {
                plan,
                buf: Vec::new(),
                base: 0,
                end: 0,
                pos: 0,
                starts: vec![None; len],
                next_seg: 0,
                retain_from: 0,
                total: None,
                eof: false,
                error: None,
                generation: 0,
                skipped_segments: 0,
            }),
            Condvar::new(),
        ));
        let stop = Arc::new(AtomicBool::new(false));

        let worker_pair = Arc::clone(&pair);
        let worker_stop = Arc::clone(&stop);
        thread::Builder::new()
            .name("dash-prefetch".to_string())
            .spawn(move || dash_worker(worker_pair, worker_stop))
            .map_err(|e| format!("failed to spawn dash-prefetch thread: {}", e))?;

        Ok(Self { pair, stop })
    }
}

impl Drop for DashMediaSource {
    fn drop(&mut self) {
        // Detached worker: it observes the flag on its next state check and
        // exits. Joining here could block the audio thread for a full HTTP
        // read timeout.
        self.stop.store(true, Ordering::Relaxed);
        self.pair.1.notify_all();
    }
}

fn fetch_segment(url: &str, headers: &HashMap<String, String>) -> io::Result<Vec<u8>> {
    let mut req = http_agent().get(url);
    for (k, v) in headers {
        req = req.set(k, v);
    }
    let resp = req
        .call()
        .map_err(|e| io::Error::other(format!("DASH GET failed: {}", e)))?;
    if resp.status() != 200 {
        return Err(io::Error::other(format!(
            "DASH segment HTTP {}",
            resp.status()
        )));
    }
    let mut buf = Vec::new();
    resp.into_reader().read_to_end(&mut buf)?;
    Ok(buf)
}

fn fetch_segment_with_retry(url: &str, headers: &HashMap<String, String>) -> io::Result<Vec<u8>> {
    let mut last_error = None;
    for attempt in 1..=SEGMENT_ATTEMPTS {
        match fetch_segment(url, headers) {
            Ok(bytes) => return Ok(bytes),
            Err(e) => {
                last_error = Some(e);
                if attempt < SEGMENT_ATTEMPTS {
                    thread::sleep(Duration::from_secs(1 << (attempt - 1)));
                }
            }
        }
    }
    Err(last_error.unwrap_or_else(|| io::Error::other("DASH segment fetch failed")))
}

fn dash_worker(pair: Arc<(Mutex<DashShared>, Condvar)>, stop: Arc<AtomicBool>) {
    let (lock, cvar) = &*pair;

    loop {
        // 1. Decide what to fetch next (holding the lock).
        let (index, url, headers, generation) = {
            let mut g = lock.lock().unwrap();
            loop {
                if stop.load(Ordering::Relaxed) {
                    return;
                }
                if g.error.is_some() {
                    g = cvar.wait(g).unwrap();
                    continue;
                }
                if g.next_seg >= g.plan.len() {
                    if g.total.is_none() {
                        g.total = Some(g.end);
                    }
                    g.eof = true;
                    // A reader waiting past the final byte (e.g. one that just
                    // seeked past EOF) must wake up to see the total.
                    cvar.notify_all();
                    g = cvar.wait(g).unwrap();
                    continue;
                }
                if g.buf.len() >= DASH_BUFFER_CAPACITY {
                    g = cvar.wait(g).unwrap();
                    continue;
                }
                break;
            }
            let index = g.next_seg;
            let url = g.plan.url(index).to_string();
            let headers = g.plan.headers.clone();
            (index, url, headers, g.generation)
        };

        // 2. Fetch outside the lock: a seek can land meanwhile.
        let fetched = fetch_segment_with_retry(&url, &headers);

        // 3. Append (or skip) under the lock.
        let mut g = lock.lock().unwrap();
        if stop.load(Ordering::Relaxed) {
            return;
        }
        if g.generation != generation {
            // A seek reset happened mid-fetch; this segment belongs to the old
            // position and was already discarded by the seek.
            cvar.notify_all();
            continue;
        }
        match fetched {
            Ok(bytes) => {
                let len = bytes.len() as u64;
                let seg_start = g.end;
                g.starts[index] = Some(seg_start);
                let seg_end = seg_start + len;

                if seg_end <= g.retain_from {
                    // Entirely before the requested offset: advance the logical
                    // stream without keeping a byte of it.
                    g.end = seg_end;
                    g.base = g.end;
                    g.skipped_segments += 1;
                } else {
                    let skip = g.retain_from.saturating_sub(seg_start) as usize;
                    if skip > 0 {
                        g.buf.extend_from_slice(&bytes[skip..]);
                        g.base = seg_start + skip as u64;
                    } else {
                        g.buf.extend_from_slice(&bytes);
                    }
                    g.end = seg_end;
                    // Everything from here on is retained in full.
                    g.retain_from = 0;
                }
                g.next_seg = index + 1;
                if g.next_seg >= g.plan.len() {
                    g.total = Some(g.end);
                }
                cvar.notify_all();
            }
            Err(e) => {
                g.error = Some(format!("DASH segment {} failed: {}", index, e));
                cvar.notify_all();
                return;
            }
        }
    }
}

impl Read for DashMediaSource {
    fn read(&mut self, dst: &mut [u8]) -> io::Result<usize> {
        if dst.is_empty() {
            return Ok(0);
        }
        let (lock, cvar) = &*self.pair;
        let mut g = lock.lock().unwrap();
        loop {
            if let Some(total) = g.total {
                if g.pos >= total {
                    return Ok(0);
                }
            }
            if g.pos < g.base {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidInput,
                    "DASH read before retained window",
                ));
            }
            if g.is_fetched(g.pos) {
                let offset = (g.pos - g.base) as usize;
                let available = &g.buf[offset..];
                let n = available.len().min(dst.len());
                dst[..n].copy_from_slice(&available[..n]);
                g.pos += n as u64;

                // Compact the consumed prefix, keeping the rewind window.
                let consumed = (g.pos - g.base) as usize;
                let drop_n = consumed.saturating_sub(DASH_REWIND_WINDOW);
                if drop_n > 0 {
                    g.buf.drain(..drop_n);
                    g.base += drop_n as u64;
                }
                cvar.notify_one();
                return Ok(n);
            }
            if g.eof && g.end <= g.pos {
                return Ok(0);
            }
            if let Some(ref e) = g.error {
                return Err(io::Error::other(e.clone()));
            }
            let (guard, timeout) = cvar.wait_timeout(g, Duration::from_secs(30)).unwrap();
            g = guard;
            if timeout.timed_out() {
                return Err(io::Error::new(
                    io::ErrorKind::TimedOut,
                    "DASH prefetch stall: no data within 30 s",
                ));
            }
        }
    }
}

impl Seek for DashMediaSource {
    fn seek(&mut self, pos: SeekFrom) -> io::Result<u64> {
        let (lock, cvar) = &*self.pair;
        let target = {
            let g = lock.lock().unwrap();
            match pos {
                SeekFrom::Start(n) => n as i64,
                SeekFrom::Current(n) => g.pos as i64 + n,
                SeekFrom::End(n) => g.total.map(|t| t as i64 + n).ok_or_else(|| {
                    io::Error::new(io::ErrorKind::Unsupported, "DASH length unknown")
                })?,
            }
        };
        if target < 0 {
            return Err(io::Error::new(io::ErrorKind::InvalidInput, "negative seek"));
        }
        let target = target as u64;

        let mut g = lock.lock().unwrap();

        // Fast path: inside the retained window.
        if g.pos_or_window_contains(target) {
            g.pos = target;
            return Ok(target);
        }

        // Restart the fetch plan at the segment containing (or, when seeking
        // past the fetched prefix, following) the target.
        let (index, start) = if target >= g.end {
            (g.next_seg, g.end)
        } else {
            match (0..g.next_seg)
                .rev()
                .find(|&i| g.starts[i].map(|s| s <= target).unwrap_or(false))
            {
                Some(i) => (i, g.starts[i].unwrap()),
                None => (0, 0),
            }
        };

        g.buf.clear();
        g.base = start;
        g.end = start;
        g.pos = target;
        g.next_seg = index;
        g.retain_from = target;
        g.total = None;
        g.eof = false;
        g.error = None;
        g.generation += 1;
        // A refetch may be needed before the reader gets its bytes back.
        cvar.notify_all();
        Ok(target)
    }
}

impl DashShared {
    fn pos_or_window_contains(&self, target: u64) -> bool {
        target >= self.base && target <= self.end
    }
}

impl MediaSource for DashMediaSource {
    fn is_seekable(&self) -> bool {
        // While streaming (total is None), report unseekable so Symphonia's isomp4
        // reader treats the stream as progressive fragmented MP4 (mvex + moof + mdat)
        // rather than failing probe because byte_len is unknown.
        // Once all segments have arrived, total length is known and seekable is true.
        self.pair.0.lock().unwrap().total.is_some()
    }

    fn byte_len(&self) -> Option<u64> {
        self.pair.0.lock().unwrap().total
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;
    use std::net::{TcpListener, TcpStream};

    /// The stand-in CDN: a path -> body table served by an in-process HTTP
    /// server, so the tests exercise the real ranged/non-ranged GET path.
    fn spawn_cdn(segments: Vec<(&'static str, &'static [u8])>) -> String {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = listener.local_addr().unwrap();
        let base = format!("http://{}", addr);
        thread::spawn(move || {
            for stream in listener.incoming() {
                let mut stream = stream.unwrap();
                serve_one(&mut stream, &segments);
            }
        });
        base
    }

    fn serve_one(stream: &mut TcpStream, segments: &[(&'static str, &'static [u8])]) {
        let mut buf = [0u8; 2048];
        let n = stream.read(&mut buf).unwrap_or(0);
        let req = String::from_utf8_lossy(&buf[..n]);
        let path = req
            .lines()
            .next()
            .and_then(|l| l.split_whitespace().nth(1))
            .unwrap_or("/");

        match segments.iter().find(|(p, _)| *p == path) {
            Some((_, body)) => {
                let resp = format!(
                    "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                    body.len()
                );
                stream.write_all(resp.as_bytes()).unwrap();
                stream.write_all(body).unwrap();
            }
            None => {
                stream
                    .write_all(
                        b"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
                    )
                    .unwrap();
            }
        }
        stream.flush().unwrap();
    }

    const INIT: &[u8] = b"INIT";
    const S1_LEN: usize = 300_000;
    const S2_LEN: usize = 200_000;
    const S3_LEN: usize = 400_000;
    const TOTAL: usize = 4 + S1_LEN + S2_LEN + S3_LEN;

    fn bodies() -> (Vec<u8>, Vec<u8>, Vec<u8>) {
        (vec![0x11; S1_LEN], vec![0x22; S2_LEN], vec![0x33; S3_LEN])
    }

    fn spawn_standard_cdn() -> String {
        let (s1, s2, s3) = bodies();
        let s1: &'static [u8] = Box::leak(s1.into_boxed_slice());
        let s2: &'static [u8] = Box::leak(s2.into_boxed_slice());
        let s3: &'static [u8] = Box::leak(s3.into_boxed_slice());
        spawn_cdn(vec![("/init", INIT), ("/s1", s1), ("/s2", s2), ("/s3", s3)])
    }

    fn plan(base: &str) -> HashMap<String, String> {
        let mut headers = HashMap::new();
        headers.insert(HEADER_INIT.to_string(), format!("{}/init", base));
        headers.insert(
            HEADER_SEGMENTS.to_string(),
            format!("{}/s1\n{}/s2\n{}/s3", base, base, base),
        );
        headers
    }

    fn read_all(src: &mut DashMediaSource) -> Vec<u8> {
        let mut out = Vec::new();
        let mut chunk = [0u8; 8192];
        loop {
            let n = src.read(&mut chunk).unwrap();
            if n == 0 {
                break;
            }
            out.extend_from_slice(&chunk[..n]);
        }
        out
    }

    fn read_at(src: &mut DashMediaSource, offset: u64, len: usize) -> Vec<u8> {
        src.seek(SeekFrom::Start(offset)).unwrap();
        let mut out = vec![0u8; len];
        let mut got = 0;
        while got < len {
            let n = src.read(&mut out[got..]).unwrap();
            if n == 0 {
                break;
            }
            got += n;
        }
        out.truncate(got);
        out
    }

    #[test]
    fn concatenates_init_then_segments_in_order() {
        let base = spawn_standard_cdn();
        let mut src = DashMediaSource::from_headers(&plan(&base)).unwrap();
        let all = read_all(&mut src);
        assert_eq!(all.len(), TOTAL);
        assert_eq!(&all[..4], INIT);
        assert_eq!(&all[4..8], &[0x11; 4]);
        assert_eq!(all[4 + S1_LEN], 0x22);
        assert_eq!(all[4 + S1_LEN + S2_LEN], 0x33);

        // Length is only known once every segment has been fetched.
        for _ in 0..500 {
            if src.byte_len() == Some(TOTAL as u64) {
                break;
            }
            thread::sleep(Duration::from_millis(10));
        }
        assert_eq!(src.byte_len(), Some(TOTAL as u64));
        assert!(src.is_seekable());
        assert_eq!(src.read(&mut [0u8; 4]).unwrap(), 0);
    }

    #[test]
    fn worker_fills_ahead_without_any_read() {
        let base = spawn_standard_cdn();
        let src = DashMediaSource::from_headers(&plan(&base)).unwrap();
        // Prefetch is the whole point: bytes must arrive before the decoder
        // asks for them (this is what absorbs CDN jitter at track start).
        for _ in 0..500 {
            if src.byte_len().is_some() {
                break;
            }
            thread::sleep(Duration::from_millis(10));
        }
        assert_eq!(src.byte_len(), Some(TOTAL as u64));
    }

    #[test]
    fn seek_inside_the_window_is_exact() {
        let base = spawn_standard_cdn();
        let mut src = DashMediaSource::from_headers(&plan(&base)).unwrap();
        assert_eq!(read_all(&mut src).len(), TOTAL);

        // Byte 6 is inside s1 (which starts at 4).
        let got = read_at(&mut src, 6, 4);
        assert_eq!(got, vec![0x11; 4]);
    }

    #[test]
    fn seek_backward_refetches_the_containing_segment() {
        let base = spawn_standard_cdn();
        let mut src = DashMediaSource::from_headers(&plan(&base)).unwrap();
        assert_eq!(read_all(&mut src).len(), TOTAL);

        // Deep into s3, then back to s1: the segment map must resolve the
        // target without replaying the whole stream from zero.
        assert_eq!(read_at(&mut src, 700_000, 8), vec![0x33; 8]);
        let got = read_at(&mut src, 100, 8);
        assert_eq!(got, vec![0x11; 8]);
    }

    #[test]
    fn forward_seek_skips_to_the_target_segment() {
        let base = spawn_standard_cdn();
        let mut src = DashMediaSource::from_headers(&plan(&base)).unwrap();
        // Seek immediately: the target lies past whatever the worker has
        // fetched, so the source must skip segments to reach it.
        let got = read_at(&mut src, (4 + S1_LEN + 10) as u64, 8);
        assert_eq!(got, vec![0x22; 8]);
        // And the stream continues correctly from there.
        let tail = read_at(&mut src, (4 + S1_LEN + S2_LEN) as u64, 8);
        assert_eq!(tail, vec![0x33; 8]);
    }

    #[test]
    fn seek_past_end_reads_zero() {
        let base = spawn_standard_cdn();
        let mut src = DashMediaSource::from_headers(&plan(&base)).unwrap();
        assert_eq!(read_all(&mut src).len(), TOTAL);
        src.seek(SeekFrom::Start(TOTAL as u64 + 5_000)).unwrap();
        assert_eq!(src.read(&mut [0u8; 8]).unwrap(), 0);
    }

    #[test]
    fn rejects_a_plan_without_segments() {
        let mut headers = HashMap::new();
        headers.insert(HEADER_INIT.to_string(), "http://x/init".to_string());
        headers.insert(HEADER_SEGMENTS.to_string(), "\n  \n".to_string());
        assert!(DashPlan::from_headers(&headers).is_err());
        assert!(DashMediaSource::from_headers(&headers).is_err());
    }

    #[test]
    fn plan_does_not_forward_flick_headers_to_the_cdn() {
        let mut headers = HashMap::new();
        headers.insert(HEADER_INIT.to_string(), "http://x/init".to_string());
        headers.insert(HEADER_SEGMENTS.to_string(), "http://x/s1".to_string());
        headers.insert("x-flick-sample-rate".to_string(), "96000".to_string());
        headers.insert("Authorization".to_string(), "Bearer t".to_string());
        let plan = DashPlan::from_headers(&headers).unwrap();
        assert_eq!(plan.headers.len(), 1);
        assert_eq!(
            plan.headers.get("Authorization").map(String::as_str),
            Some("Bearer t")
        );
    }

    #[test]
    fn describes_dash_descriptors_only() {
        assert!(is_dash_descriptor("dash://123"));
        assert!(!is_dash_descriptor("https://cdn.tidal.com/track.flac"));
    }

    #[test]
    fn is_unseekable_while_prefetching_until_total_is_known() {
        let base = spawn_standard_cdn();
        let mut src = DashMediaSource::from_headers(&plan(&base)).unwrap();
        // Immediately upon construction before all segments are drained,
        // length is unknown and seekable is false (or true if the background worker
        // fetched all segments instantly).
        if src.byte_len().is_none() {
            assert!(!src.is_seekable());
        }
        // Drain everything
        let all = read_all(&mut src);
        assert_eq!(all.len(), TOTAL);
        assert!(src.byte_len().is_some());
        assert!(src.is_seekable());
    }
}
