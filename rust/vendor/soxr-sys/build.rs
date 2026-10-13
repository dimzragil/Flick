//! Build script for soxr-sys: compiles the vendored libsoxr C sources.
//!
//! libsoxr is the SoX Resampler Library (LGPL-2.1), the same resampler engine
//! bundled by UAPP (as libausoxr.so). We vendor the C sources and compile them
//! with the `cc` crate so the build works uniformly for host (tests) and for
//! Android targets via cargo-ndk / cargokit (which set CC_<target> for us).
//!
//! Only the scalar constant-rate engines are enabled (CR32 for <=20-bit,
//! CR64 for >20-bit precision). The SIMD variants (CR32S/CR64S) and the
//! variable-rate engine (VR32) are disabled to keep the build portable across
//! all Android ABIs without per-target SIMD flags; the algorithms and output
//! quality are identical, only throughput differs.

use std::env;
use std::fs;
use std::path::PathBuf;

fn main() {
    let manifest_dir = PathBuf::from(env::var("CARGO_MANIFEST_DIR").unwrap());
    let soxr_src = manifest_dir.join("soxr");
    let out_dir = PathBuf::from(env::var("OUT_DIR").unwrap());

    // Static soxr-config.h (upstream generates this with CMake; we pin the
    // options we need so no CMake step is required on any build machine).
    let config_h = r#"/* SoX Resampler Library - static configuration for Flick.
 * Generated options mirror upstream's CMake defaults, minus the engines we
 * deliberately disable (see build.rs). Licence: LGPL v2.1. */
#if !defined soxr_config_included
#define soxr_config_included

#define AVCODEC_FOUND 0
#define AVUTIL_FOUND 0
#define WITH_PFFFT 0

#define HAVE_FENV_H 1
#define HAVE_STDBOOL_H 1
#define HAVE_STDINT_H 1
#define HAVE_LRINT 1
#define HAVE_BIGENDIAN 0

#define WITH_CR32 1
#define WITH_CR32S 0
#define WITH_CR64 1
#define WITH_CR64S 0
#define WITH_VR32 0

#define WITH_HI_PREC_CLOCK 1
#define WITH_FLOAT_STD_PREC_CLOCK 0
#define WITH_DEV_TRACE 0

#endif
"#;
    fs::write(out_dir.join("soxr-config.h"), config_h).unwrap();

    // C sources compiled into the static lib. fft4g64.c textually includes
    // fft4g.c; cr32.c / cr64.c textually include cr-core.c, so those two are
    // *not* listed here (they must still be present in the source dir).
    let sources = [
        "soxr.c",
        "data-io.c",
        "dbesi0.c",
        "filter.c",
        "fft4g64.c",
        "fft4g32.c",
        "cr.c",
        "cr32.c",
        "cr64.c",
    ];

    let mut build = cc::Build::new();
    build
        .warnings(false)
        .opt_level(2)
        .define("SOXR_LIB", None)
        .include(&soxr_src)
        .include(&out_dir); // for the generated soxr-config.h

    for src in &sources {
        let path = soxr_src.join(src);
        assert!(path.exists(), "missing vendored soxr source: {src}");
        build.file(path);
    }

    build.compile("soxr");

    println!("cargo:rerun-if-changed=build.rs");
    println!("cargo:rerun-if-changed=soxr");
}
