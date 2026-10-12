//! Best-effort realtime scheduling for audio-driving threads.
//!
//! The render loops (USB direct, DSD offload) block on the HAL/ioctl most of
//! the time, so a FIFO slot is safe and keeps their write cadence honest.
//! Producer threads that do blocking file I/O only get a nice bump: a
//! CPU-bound decoder must never hold a FIFO slot against the render loop.

/// Raise the current thread to render priority: `SCHED_FIFO` (prio 2) with a
/// nice -16 fallback when the scheduler policy is denied. No-op off Android.
/// Returns the `sched_setscheduler` error (the nice fallback still applied).
#[cfg(target_os = "android")]
pub fn raise_audio_render_priority() -> Result<(), std::io::Error> {
    let param = libc::sched_param { sched_priority: 2 };
    unsafe {
        let result = libc::sched_setscheduler(0, libc::SCHED_FIFO, &param);
        if result != 0 {
            let err = std::io::Error::last_os_error();
            crate::dev_eprintln!(
                "[AudioSched] SCHED_FIFO failed (errno={}): {}",
                err.raw_os_error().unwrap_or(-1),
                err
            );
            libc::setpriority(libc::PRIO_PROCESS, 0, -16);
            crate::dev_eprintln!("[AudioSched] set nice=-16");
            return Err(err);
        }
    }
    crate::dev_eprintln!("[AudioSched] SCHED_FIFO priority=2 acquired");
    Ok(())
}

/// Producer-side priority: nice -16 only. No-op off Android.
#[cfg(target_os = "android")]
pub fn raise_audio_decode_priority() {
    unsafe {
        libc::setpriority(libc::PRIO_PROCESS, 0, -16);
    }
}

#[cfg(not(target_os = "android"))]
pub fn raise_audio_render_priority() -> Result<(), std::io::Error> {
    Ok(())
}

#[cfg(not(target_os = "android"))]
pub fn raise_audio_decode_priority() {}

// ---------------------------------------------------------------------------
// CPU affinity (thermal-aware thread placement, cf. UAPP's sched_setaffinity)
// ---------------------------------------------------------------------------

/// Pin the current thread to the given CPU indices via `sched_setaffinity`.
/// Best-effort: on failure logs and returns the error; the thread keeps
/// running with its previous affinity. No-op off Android.
#[cfg(target_os = "android")]
pub fn set_thread_affinity(cpus: &[usize]) -> Result<(), std::io::Error> {
    if cpus.is_empty() {
        return Ok(());
    }
    unsafe {
        let mut set: libc::cpu_set_t = std::mem::zeroed();
        for &cpu in cpus {
            libc::CPU_SET(cpu, &mut set);
        }
        let ret = libc::sched_setaffinity(0, std::mem::size_of::<libc::cpu_set_t>(), &set);
        if ret != 0 {
            let err = std::io::Error::last_os_error();
            crate::dev_eprintln!("[AudioSched] sched_setaffinity({:?}) failed: {}", cpus, err);
            return Err(err);
        }
    }
    crate::dev_eprintln!("[AudioSched] affinity pinned to {:?}", cpus);
    Ok(())
}

#[cfg(not(target_os = "android"))]
pub fn set_thread_affinity(_cpus: &[usize]) -> Result<(), std::io::Error> {
    Ok(())
}

/// Render-thread treatment: SCHED_FIFO (or nice fallback) + pin to
/// efficiency cores. Best-effort; never panics. Call once at the top of
/// every audio render loop (USB direct, AudioTrack, DSD offload).
#[cfg(target_os = "android")]
pub fn apply_render_thread_treatment() {
    let _ = raise_audio_render_priority();
    let cores = efficiency_cores();
    if !cores.is_empty() {
        let _ = set_thread_affinity(&cores);
    }
}

/// Decode/download-thread treatment: nice bump + pin to efficiency cores.
/// Best-effort; never panics. Call once at the top of decoder threads.
#[cfg(target_os = "android")]
pub fn apply_decode_thread_treatment() {
    raise_audio_decode_priority();
    let cores = efficiency_cores();
    if !cores.is_empty() {
        let _ = set_thread_affinity(&cores);
    }
}

#[cfg(not(target_os = "android"))]
pub fn apply_render_thread_treatment() {}

#[cfg(not(target_os = "android"))]
pub fn apply_decode_thread_treatment() {}

/// Indices of currently-online efficiency (little) cores, detected by
/// comparing `cpuinfo_max_freq`. Cores that are offline are excluded, so the
/// result is always safe to pass to [`set_thread_affinity`].
/// Falls back to all online cores when detection fails. No-op off Android
/// (returns empty).
#[cfg(target_os = "android")]
pub fn efficiency_cores() -> Vec<usize> {
    let online = read_cpu_list("/sys/devices/system/cpu/online");
    if online.is_empty() {
        return Vec::new();
    }
    let mut freqs: Vec<(usize, u64)> = online
        .iter()
        .filter_map(|&cpu| {
            let path = format!(
                "/sys/devices/system/cpu/cpu{}/cpufreq/cpuinfo_max_freq",
                cpu
            );
            std::fs::read_to_string(&path)
                .ok()?
                .trim()
                .parse::<u64>()
                .ok()
                .map(|f| (cpu, f))
        })
        .collect();
    if freqs.is_empty() {
        return online;
    }
    freqs.sort_by_key(|&(_, f)| f);
    // Efficiency cluster = cores at the lowest max frequency.
    let min_freq = freqs[0].1;
    freqs
        .into_iter()
        .take_while(|&(_, f)| f == min_freq)
        .map(|(cpu, _)| cpu)
        .collect()
}

#[cfg(not(target_os = "android"))]
pub fn efficiency_cores() -> Vec<usize> {
    Vec::new()
}

/// Parse a Linux CPU list like "0-3" or "0,2,4-5" into indices.
#[cfg_attr(not(target_os = "android"), allow(dead_code))]
fn read_cpu_list(path: &str) -> Vec<usize> {
    let text = std::fs::read_to_string(path).unwrap_or_default();
    let mut out = Vec::new();
    for part in text.trim().split(',') {
        let part = part.trim();
        if part.is_empty() {
            continue;
        }
        if let Some((a, b)) = part.split_once('-') {
            if let (Ok(lo), Ok(hi)) = (a.trim().parse::<usize>(), b.trim().parse::<usize>()) {
                out.extend(lo..=hi);
            }
        } else if let Ok(cpu) = part.parse::<usize>() {
            out.push(cpu);
        }
    }
    out.sort_unstable();
    out.dedup();
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    fn write_temp_list(contents: &str) -> String {
        let mut p = std::env::temp_dir();
        p.push(format!("flick_cpu_list_test_{}.txt", std::process::id()));
        let mut f = std::fs::File::create(&p).unwrap();
        f.write_all(contents.as_bytes()).unwrap();
        p.to_string_lossy().into_owned()
    }

    #[test]
    fn parses_cpu_list_ranges() {
        let p = write_temp_list("0-3\n");
        assert_eq!(read_cpu_list(&p), vec![0, 1, 2, 3]);
        let p = write_temp_list("0,2,4-5\n");
        assert_eq!(read_cpu_list(&p), vec![0, 2, 4, 5]);
        let p = write_temp_list("7\n");
        assert_eq!(read_cpu_list(&p), vec![7]);
        let p = write_temp_list("bogus\n");
        assert!(read_cpu_list(&p).is_empty());
    }

    #[test]
    fn efficiency_cores_never_panics() {
        let cores = efficiency_cores();
        assert!(cores.iter().all(|&c| c < 256));
    }
}
