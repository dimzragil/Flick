//! Raw FFI bindings to the vendored SoX Resampler Library (libsoxr 0.1.3).
//!
//! Hand-written (no bindgen) to keep the build dependency-free: only the
//! small subset of the API used by Flick's resampler is declared. Layouts are
//! taken from upstream `src/soxr.h`.

use std::ffi::{c_char, c_double, c_int, c_ulong, c_void};
use std::ptr;

/// Opaque resampler instance.
pub type Soxr = *mut c_void;
/// `0` = no error; otherwise a NUL-terminated message owned by the instance.
pub type SoxrError = *const c_char;

/// I/O datatypes (only the interleaved variants are used by Flick).
pub const SOXR_FLOAT32_I: c_int = 0;
#[allow(dead_code)]
pub const SOXR_FLOAT64_I: c_int = 1;

/// Standard quality recipes.
#[allow(dead_code)]
pub const SOXR_HQ: c_ulong = 4; /* 'High quality' (20-bit). */
pub const SOXR_VHQ: c_ulong = 6; /* 'Very high quality' (28-bit). */

#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct SoxrIoSpec {
    pub itype: c_int,
    pub otype: c_int,
    pub scale: c_double,
    pub e: *mut c_void,
    pub flags: c_ulong,
}

#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct SoxrQualitySpec {
    pub precision: c_double,
    pub phase_response: c_double,
    pub passband_end: c_double,
    pub stopband_begin: c_double,
    pub e: *mut c_void,
    pub flags: c_ulong,
}

#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct SoxrRuntimeSpec {
    pub log2_min_dft_size: u32,
    pub log2_large_dft_size: u32,
    pub coef_size_kbytes: u32,
    pub num_threads: u32,
    pub e: *mut c_void,
    pub flags: c_ulong,
}

#[link(name = "soxr")]
extern "C" {
    pub fn soxr_create(
        input_rate: c_double,
        output_rate: c_double,
        num_channels: u32,
        error: *mut SoxrError,
        io_spec: *const SoxrIoSpec,
        q_spec: *const SoxrQualitySpec,
        runtime_spec: *const SoxrRuntimeSpec,
    ) -> Soxr;

    pub fn soxr_process(
        resampler: Soxr,
        input: *const c_void,
        ilen: usize,
        idone: *mut usize,
        output: *mut c_void,
        olen: usize,
        odone: *mut usize,
    ) -> SoxrError;

    pub fn soxr_error(resampler: Soxr) -> SoxrError;
    pub fn soxr_delete(resampler: Soxr);
    pub fn soxr_clear(resampler: Soxr) -> SoxrError;
    pub fn soxr_delay(resampler: Soxr) -> c_double;
    pub fn soxr_engine(resampler: Soxr) -> *const c_char;

    pub fn soxr_quality_spec(recipe: c_ulong, flags: c_ulong) -> SoxrQualitySpec;
    pub fn soxr_io_spec(itype: c_int, otype: c_int) -> SoxrIoSpec;
    pub fn soxr_runtime_spec(num_threads: u32) -> SoxrRuntimeSpec;
}

/// Convert a `soxr_error_t` to a Rust string (empty string = no error).
///
/// # Safety
/// `err` must be null or a valid NUL-terminated string owned by a live soxr
/// instance.
pub unsafe fn error_string(err: SoxrError) -> String {
    if err.is_null() {
        return String::new();
    }
    unsafe {
        std::ffi::CStr::from_ptr(err)
            .to_string_lossy()
            .into_owned()
    }
}

/// Query the active engine name (e.g. "CR64S", "CR32").
///
/// # Safety
/// `handle` must be a live soxr instance.
pub unsafe fn engine_name(handle: Soxr) -> String {
    if handle.is_null() {
        return String::from("none");
    }
    unsafe {
        let ptr = soxr_engine(handle);
        if ptr.is_null() {
            return String::from("unknown");
        }
        std::ffi::CStr::from_ptr(ptr).to_string_lossy().into_owned()
    }
}

/// Null handle sentinel used before successful creation.
pub fn null_handle() -> Soxr {
    ptr::null_mut()
}
