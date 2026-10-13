//! Sample rate conversion.
//!
//! Primary engine: the SoX Resampler Library (libsoxr) at very-high quality
//! (28-bit precision) — the same resampler UAPP bundles as `libausoxr.so`.
//! If SoX fails to initialise, we fall back to the pure-Rust rubato resampler
//! so playback never breaks.
//!
//! Resampling only happens on fallback paths (e.g. the DAC does not support
//! the track's sample rate, or IR files need adapting). Bit-perfect USB
//! playback never resamples.

use std::ffi::c_void;
use std::ptr;

use rubato::{FastFixedIn, PolynomialDegree, Resampler as RubatoResampler};

/// Default system output sample rate (48kHz is standard for modern audio)
pub const DEFAULT_OUTPUT_SAMPLE_RATE: u32 = 48000;

// ---------------------------------------------------------------------------
// SoX backend (libsoxr via soxr-sys)
// ---------------------------------------------------------------------------

/// Safe wrapper around a libsoxr instance (interleaved f32 in/out).
struct SoxrCore {
    handle: soxr_sys::Soxr,
    channels: usize,
    ratio: f64,
    /// Staging buffer for one `soxr_process` output burst (interleaved).
    staging: Vec<f32>,
    /// Resampled output waiting to be collected (interleaved).
    output_queue: Vec<f32>,
    is_flushed: bool,
}

// soxr instances may be moved between threads, but must never be used
// concurrently (same contract as the rubato backend).
unsafe impl Send for SoxrCore {}

impl SoxrCore {
    fn new(input_rate: u32, output_rate: u32, channels: usize) -> Result<Self, String> {
        if input_rate == 0 || output_rate == 0 {
            return Err(format!(
                "soxr: sample rates must be non-zero ({input_rate} -> {output_rate})"
            ));
        }
        if channels == 0 {
            return Err("soxr: channel count must be non-zero".to_string());
        }

        let io_spec =
            unsafe { soxr_sys::soxr_io_spec(soxr_sys::SOXR_FLOAT32_I, soxr_sys::SOXR_FLOAT32_I) };
        let q_spec = unsafe { soxr_sys::soxr_quality_spec(soxr_sys::SOXR_VHQ, 0) };
        let runtime_spec = unsafe { soxr_sys::soxr_runtime_spec(1) };

        let mut error: soxr_sys::SoxrError = ptr::null();
        let handle = unsafe {
            soxr_sys::soxr_create(
                input_rate as f64,
                output_rate as f64,
                channels as u32,
                &mut error,
                &io_spec,
                &q_spec,
                &runtime_spec,
            )
        };
        if handle == soxr_sys::null_handle() {
            let msg = unsafe { soxr_sys::error_string(error) };
            return Err(format!("soxr_create failed: {msg}"));
        }
        let err_msg = unsafe { soxr_sys::error_string(soxr_sys::soxr_error(handle)) };
        if !err_msg.is_empty() {
            unsafe { soxr_sys::soxr_delete(handle) };
            return Err(format!("soxr_create reported: {err_msg}"));
        }

        let engine = unsafe { soxr_sys::engine_name(handle) };
        log::info!(
            "[RESAMPLER] soxr backend ready: engine={engine} quality=VHQ(28-bit) \
             {input_rate}->{output_rate}Hz ch={channels}"
        );

        Ok(Self {
            handle,
            channels,
            ratio: output_rate as f64 / input_rate as f64,
            staging: Vec::new(),
            output_queue: Vec::new(),
            is_flushed: false,
        })
    }

    /// Push interleaved input through soxr, appending to `output_queue`.
    fn push_input(&mut self, input: &[f32]) -> Result<(), String> {
        debug_assert_eq!(input.len() % self.channels, 0);
        let total_frames = input.len() / self.channels;
        let mut done_frames = 0usize;

        while done_frames < total_frames {
            let in_frames = total_frames - done_frames;
            let want_out = (in_frames as f64 * self.ratio).ceil() as usize + 64;
            self.staging.resize(want_out * self.channels, 0.0);

            let mut idone = 0usize;
            let mut odone = 0usize;
            let err = unsafe {
                soxr_sys::soxr_process(
                    self.handle,
                    input.as_ptr().add(done_frames * self.channels) as *const c_void,
                    in_frames,
                    &mut idone,
                    self.staging.as_mut_ptr() as *mut c_void,
                    want_out,
                    &mut odone,
                )
            };
            let msg = unsafe { soxr_sys::error_string(err) };
            if !msg.is_empty() {
                return Err(format!("soxr_process failed: {msg}"));
            }
            self.output_queue
                .extend_from_slice(&self.staging[..odone * self.channels]);
            done_frames += idone;
            if idone == 0 && odone == 0 {
                // Buffers are sized to guarantee progress; bail out instead
                // of spinning forever if that assumption ever breaks.
                return Err("soxr_process made no progress".to_string());
            }
        }
        Ok(())
    }

    /// Signal end-of-input and drain the filter delay into `output_queue`.
    fn drain(&mut self) -> Result<(), String> {
        for _ in 0..64 {
            let want_out = 4096usize;
            self.staging.resize(want_out * self.channels, 0.0);

            let mut idone = 0usize;
            let mut odone = 0usize;
            let err = unsafe {
                soxr_sys::soxr_process(
                    self.handle,
                    ptr::null(),
                    0,
                    &mut idone,
                    self.staging.as_mut_ptr() as *mut c_void,
                    want_out,
                    &mut odone,
                )
            };
            let msg = unsafe { soxr_sys::error_string(err) };
            if !msg.is_empty() {
                return Err(format!("soxr flush failed: {msg}"));
            }
            self.output_queue
                .extend_from_slice(&self.staging[..odone * self.channels]);
            if odone == 0 {
                break;
            }
        }
        Ok(())
    }

    fn clear(&mut self) {
        let err = unsafe { soxr_sys::soxr_clear(self.handle) };
        let msg = unsafe { soxr_sys::error_string(err) };
        if !msg.is_empty() {
            log::warn!("[RESAMPLER] soxr_clear failed: {msg}");
        }
        self.output_queue.clear();
        self.is_flushed = false;
    }

    fn delay_frames(&self) -> usize {
        unsafe { soxr_sys::soxr_delay(self.handle) as usize }
    }

    fn engine(&self) -> String {
        unsafe { soxr_sys::engine_name(self.handle) }
    }
}

impl Drop for SoxrCore {
    fn drop(&mut self) {
        unsafe { soxr_sys::soxr_delete(self.handle) };
    }
}

// ---------------------------------------------------------------------------
// rubato fallback backend (pure Rust, kept from the original implementation)
// ---------------------------------------------------------------------------

/// Wrapper around rubato's resampler, used only if SoX initialisation fails.
struct RubatoCore {
    resampler: FastFixedIn<f32>,
    channels: usize,
    chunk_size: usize,
    /// Pre-allocated input buffers (one per channel)
    input_buffers: Vec<Vec<f32>>,
    /// Pre-allocated output buffers (one per channel)
    output_buffers: Vec<Vec<f32>>,
    /// Pending input samples waiting to be processed (interleaved)
    input_queue: Vec<f32>,
    /// Pending output samples ready to be returned (interleaved)
    output_queue: Vec<f32>,
    /// Whether the stream has ended and we've flushed
    is_flushed: bool,
}

impl RubatoCore {
    fn new(
        input_rate: u32,
        output_rate: u32,
        channels: usize,
        chunk_size: usize,
    ) -> Result<Self, String> {
        let resample_ratio = output_rate as f64 / input_rate as f64;

        // Calculate output size based on ratio
        let max_output_frames = (chunk_size as f64 * resample_ratio * 1.1) as usize + 10;

        let resampler = FastFixedIn::new(
            resample_ratio,
            1.0,                      // No additional ratio adjustment
            PolynomialDegree::Septic, // High quality interpolation
            chunk_size,
            channels,
        )
        .map_err(|e| format!("Failed to create rubato resampler: {e}"))?;

        Ok(Self {
            resampler,
            channels,
            chunk_size,
            input_buffers: vec![vec![0.0; chunk_size]; channels],
            output_buffers: vec![vec![0.0; max_output_frames]; channels],
            input_queue: Vec::new(),
            output_queue: Vec::new(),
            is_flushed: false,
        })
    }

    /// Process a chunk of interleaved audio samples.
    ///
    /// Input samples are buffered internally. Resampling happens only when
    /// enough frames have accumulated (>= chunk_size). Output is also buffered,
    /// so multiple calls may be needed to drain all produced samples.
    fn process_interleaved(&mut self, input: &[f32], output: &mut [f32]) -> Result<usize, String> {
        if self.is_flushed {
            // After flush, just drain any remaining output_queue
            return Ok(drain_queue(&mut self.output_queue, output));
        }

        // Queue incoming samples
        if !input.is_empty() {
            self.input_queue.extend_from_slice(input);
        }

        // Process as many full chunks as we have
        let frames_per_chunk = self.chunk_size;
        let samples_per_chunk = frames_per_chunk * self.channels;

        while self.input_queue.len() >= samples_per_chunk {
            // Deinterleave input into channel buffers
            for ch in 0..self.channels {
                for frame in 0..frames_per_chunk {
                    self.input_buffers[ch][frame] = self.input_queue[frame * self.channels + ch];
                }
            }
            // Remove processed samples from queue
            self.input_queue.drain(0..samples_per_chunk);

            // Perform resampling
            let input_refs: Vec<&[f32]> = self.input_buffers.iter().map(|b| b.as_slice()).collect();
            let (_, output_frames) = self
                .resampler
                .process_into_buffer(&input_refs, &mut self.output_buffers, None)
                .map_err(|e| format!("Resampling error: {e}"))?;

            // Interleave output into queue
            for frame_idx in 0..output_frames {
                for ch in 0..self.channels {
                    self.output_queue.push(self.output_buffers[ch][frame_idx]);
                }
            }
        }

        Ok(drain_queue(&mut self.output_queue, output))
    }

    /// Flush any remaining samples through the resampler.
    fn flush(&mut self, output: &mut [f32]) -> Result<usize, String> {
        if self.is_flushed {
            return Ok(drain_queue(&mut self.output_queue, output));
        }

        // Process remaining input padded with zeros
        if !self.input_queue.is_empty() {
            let remaining_frames = self.input_queue.len() / self.channels;

            // Deinterleave remaining input
            for ch in 0..self.channels {
                for frame in 0..remaining_frames {
                    self.input_buffers[ch][frame] = self.input_queue[frame * self.channels + ch];
                }
                // Pad with zeros
                for frame in remaining_frames..self.chunk_size {
                    self.input_buffers[ch][frame] = 0.0;
                }
            }
            self.input_queue.clear();

            let input_refs: Vec<&[f32]> = self.input_buffers.iter().map(|b| b.as_slice()).collect();
            let (_, output_frames) = self
                .resampler
                .process_into_buffer(&input_refs, &mut self.output_buffers, None)
                .map_err(|e| format!("Resampling flush error: {e}"))?;

            for frame_idx in 0..output_frames {
                for ch in 0..self.channels {
                    self.output_queue.push(self.output_buffers[ch][frame_idx]);
                }
            }
        }

        self.is_flushed = true;

        Ok(drain_queue(&mut self.output_queue, output))
    }

    /// Reset the resampler state (call between tracks).
    fn reset(&mut self) {
        self.resampler.reset();
        self.input_queue.clear();
        self.output_queue.clear();
        self.is_flushed = false;
    }

    /// Get the latency introduced by resampling in samples.
    fn latency_frames(&self) -> usize {
        self.resampler.output_delay()
    }
}

// ---------------------------------------------------------------------------
// Public wrapper: SoX first, rubato fallback, passthrough fast-path
// ---------------------------------------------------------------------------

enum Backend {
    Passthrough,
    Soxr(SoxrCore),
    Rubato(RubatoCore),
}

/// Sample-rate converter. Prefers the SoX resampler; falls back to rubato if
/// SoX cannot initialise; bypasses both when rates already match.
pub struct AudioResampler {
    backend: Backend,
    input_rate: u32,
    output_rate: u32,
    channels: usize,
}

impl AudioResampler {
    /// Create a new resampler.
    ///
    /// # Arguments
    /// * `input_rate` - Sample rate of the input audio
    /// * `output_rate` - Desired output sample rate
    /// * `channels` - Number of audio channels
    /// * `chunk_size` - Processing chunk size (only used by the rubato fallback)
    pub fn new(
        input_rate: u32,
        output_rate: u32,
        channels: usize,
        chunk_size: usize,
    ) -> Result<Self, String> {
        if input_rate == 0 || output_rate == 0 {
            return Err(format!(
                "invalid sample rates: {input_rate} -> {output_rate}"
            ));
        }
        if channels == 0 {
            return Err("channel count must be non-zero".to_string());
        }

        let backend = if input_rate == output_rate {
            Backend::Passthrough
        } else {
            match SoxrCore::new(input_rate, output_rate, channels) {
                Ok(core) => Backend::Soxr(core),
                Err(e) => {
                    log::warn!("[RESAMPLER] soxr init failed ({e}); falling back to rubato");
                    Backend::Rubato(RubatoCore::new(
                        input_rate,
                        output_rate,
                        channels,
                        chunk_size,
                    )?)
                }
            }
        };

        Ok(Self {
            backend,
            input_rate,
            output_rate,
            channels,
        })
    }

    /// Which engine is actually doing the work: "passthrough", "soxr" or "rubato".
    pub fn backend_name(&self) -> &'static str {
        match &self.backend {
            Backend::Passthrough => "passthrough",
            Backend::Soxr(_) => "soxr",
            Backend::Rubato(_) => "rubato",
        }
    }

    /// Check if resampling is actually needed.
    #[inline]
    pub fn needs_resampling(&self) -> bool {
        self.input_rate != self.output_rate
    }

    /// Get the input sample rate.
    #[inline]
    pub fn input_rate(&self) -> u32 {
        self.input_rate
    }

    /// Get the output sample rate.
    #[inline]
    pub fn output_rate(&self) -> u32 {
        self.output_rate
    }

    /// Get the number of channels.
    #[inline]
    pub fn channels(&self) -> usize {
        self.channels
    }

    /// Process a chunk of interleaved audio samples.
    ///
    /// # Arguments
    /// * `input` - Interleaved input samples (e.g., [L, R, L, R, ...])
    /// * `output` - Pre-allocated output buffer for interleaved samples
    ///
    /// # Returns
    /// Number of output samples written (interleaved, so divide by channels for frames)
    pub fn process_interleaved(
        &mut self,
        input: &[f32],
        output: &mut [f32],
    ) -> Result<usize, String> {
        match &mut self.backend {
            Backend::Passthrough => {
                let copy_len = input.len().min(output.len());
                output[..copy_len].copy_from_slice(&input[..copy_len]);
                Ok(copy_len)
            }
            Backend::Soxr(core) => {
                if core.is_flushed {
                    return Ok(drain_queue(&mut core.output_queue, output));
                }
                if !input.is_empty() {
                    core.push_input(input)?;
                }
                Ok(drain_queue(&mut core.output_queue, output))
            }
            Backend::Rubato(core) => core.process_interleaved(input, output),
        }
    }

    /// Flush any remaining samples through the resampler.
    ///
    /// Call this when the input stream has ended to process the final partial
    /// block and any filter delay.
    ///
    /// # Arguments
    /// * `output` - Pre-allocated output buffer for interleaved samples
    ///
    /// # Returns
    /// Number of output samples written
    pub fn flush(&mut self, output: &mut [f32]) -> Result<usize, String> {
        match &mut self.backend {
            Backend::Passthrough => Ok(0),
            Backend::Soxr(core) => {
                if !core.is_flushed {
                    core.drain()?;
                    core.is_flushed = true;
                }
                Ok(drain_queue(&mut core.output_queue, output))
            }
            Backend::Rubato(core) => core.flush(output),
        }
    }

    /// Reset the resampler state (call between tracks).
    pub fn reset(&mut self) {
        match &mut self.backend {
            Backend::Passthrough => {}
            Backend::Soxr(core) => core.clear(),
            Backend::Rubato(core) => core.reset(),
        }
    }

    /// Get the latency introduced by resampling in samples.
    pub fn latency_frames(&self) -> usize {
        match &self.backend {
            Backend::Passthrough => 0,
            Backend::Soxr(core) => core.delay_frames(),
            Backend::Rubato(core) => {
                if self.needs_resampling() {
                    core.latency_frames()
                } else {
                    0
                }
            }
        }
    }
}

/// Move as many queued samples as fit into the caller's buffer.
fn drain_queue(queue: &mut Vec<f32>, output: &mut [f32]) -> usize {
    let to_copy = queue.len().min(output.len());
    output[..to_copy].copy_from_slice(&queue[..to_copy]);
    queue.drain(..to_copy);
    to_copy
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::f32::consts::PI;

    fn generate_sine(freq_hz: f32, sample_rate: u32, frames: usize) -> Vec<f32> {
        (0..frames)
            .map(|frame| {
                let phase = 2.0 * PI * freq_hz * frame as f32 / sample_rate as f32;
                phase.sin()
            })
            .collect()
    }

    fn tone_magnitude(samples: &[f32], sample_rate: u32, freq_hz: f32) -> f32 {
        let omega = 2.0 * PI * freq_hz / sample_rate as f32;
        let mut real = 0.0f32;
        let mut imag = 0.0f32;

        for (index, &sample) in samples.iter().enumerate() {
            let phase = omega * index as f32;
            real += sample * phase.cos();
            imag -= sample * phase.sin();
        }

        2.0 * real.hypot(imag) / samples.len() as f32
    }

    fn detect_dominant_frequency(
        samples: &[f32],
        sample_rate: u32,
        center_freq_hz: f32,
        search_radius_hz: f32,
        step_hz: f32,
    ) -> (f32, f32) {
        let min_freq = center_freq_hz - search_radius_hz;
        let steps = ((2.0 * search_radius_hz) / step_hz).round() as usize;

        let mut best_frequency = min_freq;
        let mut best_magnitude = f32::NEG_INFINITY;

        for step in 0..=steps {
            let freq_hz = min_freq + step as f32 * step_hz;
            let magnitude = tone_magnitude(samples, sample_rate, freq_hz);
            if magnitude > best_magnitude {
                best_frequency = freq_hz;
                best_magnitude = magnitude;
            }
        }

        (best_frequency, best_magnitude)
    }

    fn resample_sine_segment(input_rate: u32, output_rate: u32, freq_hz: f32) -> Vec<f32> {
        let input_frames = 16_384;
        let mut resampler = AudioResampler::new(input_rate, output_rate, 1, input_frames).unwrap();
        let input = generate_sine(freq_hz, input_rate, input_frames);
        let output_capacity =
            ((input_frames as f64 * output_rate as f64 / input_rate as f64) as usize) + 1024;
        let mut output = vec![0.0; output_capacity];

        let written = resampler.process_interleaved(&input, &mut output).unwrap();
        let window_frames = 2048usize;
        let start_frame = (resampler.latency_frames() + 256).min(written - window_frames);

        output[start_frame..start_frame + window_frames].to_vec()
    }

    /// Resample a spectrally-pure sine and return the full output.
    fn resample_pure_tone(input_rate: u32, output_rate: u32, freq_hz: f64) -> Vec<f32> {
        let input_frames = 65_536;
        let mut resampler = AudioResampler::new(input_rate, output_rate, 1, 4096).unwrap();
        assert_eq!(
            resampler.backend_name(),
            "soxr",
            "stopband test requires the soxr backend"
        );
        let input = generate_sine_precise(freq_hz, input_rate, input_frames);
        let mut out = Vec::new();
        let mut tmp = vec![0.0; 8192];

        // Feed in uneven chunks to exercise the streaming path.
        for chunk in input.chunks(5000) {
            let n = resampler.process_interleaved(chunk, &mut tmp).unwrap();
            out.extend_from_slice(&tmp[..n]);
        }
        loop {
            let n = resampler.flush(&mut tmp).unwrap();
            if n == 0 {
                break;
            }
            out.extend_from_slice(&tmp[..n]);
        }
        out
    }

    #[test]
    fn test_passthrough() {
        let mut resampler = AudioResampler::new(48000, 48000, 2, 1024).unwrap();
        assert!(!resampler.needs_resampling());
        assert_eq!(resampler.backend_name(), "passthrough");

        let input: Vec<f32> = (0..200).map(|i| i as f32 / 200.0).collect();
        let mut output = vec![0.0; 200];

        let written = resampler.process_interleaved(&input, &mut output).unwrap();
        assert_eq!(written, 200);
        assert_eq!(input, output);
    }

    #[test]
    fn test_upsampling() {
        let resampler = AudioResampler::new(44100, 48000, 2, 1024).unwrap();
        assert!(resampler.needs_resampling());
    }

    #[test]
    fn test_soxr_is_default_backend() {
        // SoX must initialise in the test environment; it is the primary engine.
        let resampler = AudioResampler::new(44100, 48000, 2, 1024).unwrap();
        assert_eq!(resampler.backend_name(), "soxr");
    }

    #[test]
    fn test_soxr_uses_64bit_engine_for_vhq() {
        // VHQ (28-bit) must select the 64-bit double-precision engine.
        let core = SoxrCore::new(96000, 48000, 2).unwrap();
        let engine = core.engine();
        assert!(
            engine.contains("64"),
            "expected 64-bit soxr engine for VHQ, got '{engine}'"
        );
    }

    #[test]
    fn test_invalid_rates_rejected() {
        assert!(AudioResampler::new(0, 48000, 2, 1024).is_err());
        assert!(AudioResampler::new(44100, 0, 2, 1024).is_err());
        assert!(AudioResampler::new(44100, 48000, 0, 1024).is_err());
    }

    #[test]
    fn test_resampler_preserves_sine_frequency_ratio() {
        let freq_hz = 750.0;
        let analysis = resample_sine_segment(44_100, 48_000, freq_hz);
        let (detected_freq_hz, magnitude) =
            detect_dominant_frequency(&analysis, 48_000, freq_hz, 20.0, 0.25);
        let frequency_ratio = detected_freq_hz / freq_hz;

        assert!(
            magnitude > 0.8,
            "fundamental collapsed after resampling: {magnitude}"
        );
        assert!(
            (frequency_ratio - 1.0).abs() < 0.005,
            "sample-rate mismatch detected: expected {:.3} Hz, measured {:.3} Hz (ratio {:.6})",
            freq_hz,
            detected_freq_hz,
            frequency_ratio,
        );
    }

    #[test]
    fn test_resampler_keeps_sine_harmonics_low() {
        let freq_hz = 750.0;
        let analysis = resample_sine_segment(44_100, 48_000, freq_hz);
        let fundamental = tone_magnitude(&analysis, 48_000, freq_hz);
        let harmonic_sum: f32 = [2.0f32, 3.0, 4.0, 5.0]
            .iter()
            .map(|multiplier| tone_magnitude(&analysis, 48_000, freq_hz * multiplier))
            .sum();
        let harmonic_ratio = harmonic_sum / fundamental.max(f32::EPSILON);

        assert!(
            fundamental > 0.8,
            "fundamental collapsed after resampling: {fundamental}"
        );
        assert!(
            harmonic_ratio < 0.02,
            "sine-wave distortion too high after resampling: harmonic ratio {:.6}",
            harmonic_ratio,
        );
    }

    /// Spectrally-pure sine via phasor recurrence (no growing phase error like
    /// naive f32 `sin(2πft)` accumulation, which degrades into spurs past -100 dB
    /// for long high-frequency tones). Renormalized periodically to stop drift.
    fn generate_sine_precise(freq_hz: f64, sample_rate: u32, frames: usize) -> Vec<f32> {
        let delta = 2.0 * std::f64::consts::PI * freq_hz / sample_rate as f64;
        let (sin_d, cos_d) = delta.sin_cos();
        let (mut sin_p, mut cos_p) = (0.0f64, 1.0f64);
        (0..frames)
            .map(|i| {
                let s = sin_p as f32;
                let ns = sin_p * cos_d + cos_p * sin_d;
                let nc = cos_p * cos_d - sin_p * sin_d;
                if i % 1024 == 1023 {
                    let inv = 1.0 / (ns * ns + nc * nc).sqrt();
                    sin_p = ns * inv;
                    cos_p = nc * inv;
                } else {
                    sin_p = ns;
                    cos_p = nc;
                }
                s
            })
            .collect()
    }

    /// f64-precision magnitude measurement for stopband analysis (the f32
    /// version's numerical noise floor sits around -100 dB, which would mask
    /// the true rejection of a high-quality resampler).
    fn tone_magnitude_f64(samples: &[f32], sample_rate: u32, freq_hz: f64) -> f64 {
        let omega = 2.0 * std::f64::consts::PI * freq_hz / sample_rate as f64;
        let mut real = 0.0f64;
        let mut imag = 0.0f64;

        for (index, &sample) in samples.iter().enumerate() {
            let phase = omega * index as f64;
            real += sample as f64 * phase.cos();
            imag -= sample as f64 * phase.sin();
        }

        2.0 * real.hypot(imag) / samples.len() as f64
    }

    #[test]
    fn test_soxr_stopband_rejection() {
        // 30 kHz tone at 96 kHz input is above the 48 kHz output Nyquist: a
        // proper resampler must push it (and its 18 kHz alias) below -120 dB.
        let reference = resample_pure_tone(96_000, 48_000, 5_000.0);
        let stopband = resample_pure_tone(96_000, 48_000, 30_000.0);

        // Skip the filter transient at the start of each capture.
        let skip = 8192;
        let ref_win = &reference[skip..skip + 16384];
        let stop_win = &stopband[skip..skip + 16384];

        let ref_mag = tone_magnitude_f64(ref_win, 48_000, 5_000.0);
        assert!(ref_mag > 0.9, "passband reference collapsed: {ref_mag}");

        let residual_direct = tone_magnitude_f64(stop_win, 48_000, 30_000.0);
        let residual_alias = tone_magnitude_f64(stop_win, 48_000, 18_000.0);
        let worst = residual_direct.max(residual_alias);
        let rejection_db = 20.0 * (ref_mag / worst.max(1e-9)).log10();

        assert!(
            rejection_db > 120.0,
            "soxr stopband rejection too weak: {rejection_db:.1} dB \
             (direct={residual_direct:.2e}, alias={residual_alias:.2e})"
        );
    }

    #[test]
    fn test_rubato_fallback_still_works() {
        // The fallback backend must remain functional even though SoX is primary.
        let mut core = RubatoCore::new(44_100, 48_000, 1, 1024).unwrap();
        let input = generate_sine(750.0, 44_100, 4096);
        let mut output = vec![0.0; 8192];
        let written = core.process_interleaved(&input, &mut output).unwrap();
        assert!(written > 0, "rubato fallback produced no output");
        let mut flush_buf = vec![0.0; 8192];
        let _ = core.flush(&mut flush_buf).unwrap();
    }

    #[test]
    fn test_resampler_buffers_variable_input_sizes() {
        let input_rate = 44_100;
        let output_rate = 48_000;
        let channels = 2;
        let chunk_size = 1024;
        let mut resampler =
            AudioResampler::new(input_rate, output_rate, channels, chunk_size).unwrap();

        // Feed input in small chunks that don't line up with chunk_size
        let total_input_frames = chunk_size * 10 + 512; // 10752 frames
        let input: Vec<f32> = (0..total_input_frames * channels)
            .map(|i| (i % 100) as f32 / 100.0)
            .collect();

        let mut output = vec![0.0; total_input_frames * channels * 4];

        let mut total_written = 0;
        let mut input_offset = 0;

        // Feed 100-frame chunks
        while input_offset < input.len() {
            let end = (input_offset + 100 * channels).min(input.len());
            let chunk = &input[input_offset..end];
            let mut out_chunk = vec![0.0; chunk.len() * 2 + 256];
            let written = resampler
                .process_interleaved(chunk, &mut out_chunk)
                .unwrap();
            output[total_written..total_written + written].copy_from_slice(&out_chunk[..written]);
            total_written += written;
            input_offset += chunk.len();
        }

        // Flush remaining samples
        let mut flush_buf = vec![0.0; chunk_size * channels * 4];
        loop {
            let written = resampler.flush(&mut flush_buf).unwrap();
            if written == 0 {
                break;
            }
            output[total_written..total_written + written].copy_from_slice(&flush_buf[..written]);
            total_written += written;
        }

        // Should have produced a reasonable amount of output
        let output_frames = total_written / channels;
        let expected_ratio = output_rate as f64 / input_rate as f64;
        let actual_ratio = output_frames as f64 / total_input_frames as f64;

        // Allow extra output up to one chunk_size worth due to final zero-padded flush.
        let max_expected_ratio =
            expected_ratio * (1.0 + chunk_size as f64 / total_input_frames as f64);
        assert!(
            actual_ratio <= max_expected_ratio && actual_ratio >= expected_ratio * 0.95,
            "output ratio out of range: expected {:.4}..{:.4}, got {:.4} (output_frames={}, input_frames={})",
            expected_ratio * 0.95,
            max_expected_ratio,
            actual_ratio,
            output_frames,
            total_input_frames
        );
    }

    #[test]
    fn test_resampler_does_not_drop_samples_across_packets() {
        let input_rate = 48_000;
        let output_rate = 44_100;
        let channels = 1;
        let chunk_size = 4096;
        let mut resampler =
            AudioResampler::new(input_rate, output_rate, channels, chunk_size).unwrap();

        // First packet: exactly chunk_size frames
        let packet1 = vec![1.0f32; chunk_size];
        let mut out1 = vec![0.0; chunk_size * 2];
        let _written1 = resampler.process_interleaved(&packet1, &mut out1).unwrap();

        // Second packet: 100 frames (should be buffered, not error)
        let packet2 = vec![2.0f32; 100];
        let mut out2 = vec![0.0; 100 * 2];
        let _written2 = resampler.process_interleaved(&packet2, &mut out2).unwrap();

        // Third packet: enough to reach chunk_size
        let packet3 = vec![3.0f32; chunk_size - 100];
        let mut out3 = vec![0.0; chunk_size * 2];
        let written3 = resampler.process_interleaved(&packet3, &mut out3).unwrap();

        // written2 should be 0 or very small (buffered), written3 should include
        // output from both packet2 and packet3 combined with any queued output.
        assert!(
            written3 > 0,
            "expected output after accumulating to chunk_size, got written3={}",
            written3
        );

        // Flush may or may not produce additional output depending on whether
        // the output_queue was fully drained by process_interleaved.
        let mut flush_buf = vec![0.0; chunk_size * 2];
        let _flush_written = resampler.flush(&mut flush_buf).unwrap();
    }
}
