use once_cell::sync::Lazy;
use parking_lot::RwLock;
use rusb::SyncType;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum UsbAudioQuirk {
    IgnoreBrokenClockSource,
    ForceAsyncFeedback,
    DisableNativeDsd,
    IgnoreInvalidSampleRate,
    Force48kHzOnly,
    RequireVerifiedRate,
    SettleDelayMs(u64),
    PreferPadded24BitTransport,
    DsdSubslotSize(u8),
    DsdBigEndian,
    DsdBitReverse,
    ForceIsochronousSyncType(SyncType),
    SkipFeedbackValidation,
    AssumeSynchEndpointZero,
    IgnoreMuteControl,
    IgnoreVolumeControl,
    PreferInterfaceAlt(u8),
    SkipClockValidation,
    RequireInterfaceClaim(u8),
    /// Cap the negotiated PCM sample rate at the given Hz. For DACs whose
    /// descriptors advertise bogus maximum rates. (Concept ported from
    /// UAPP's field-tested "Forcing highest sample rate to 384000Hz for
    /// iFi micro"; reimplemented here as a generic per-device rate cap.)
    ForceMaxSampleRateHz(u32),
    /// Force PCM playback bit depth to the given number of bits. For DACs
    /// that misreport their supported bit depth. Applies to PCM only —
    /// never to DSD/DoP streams.
    ForceBitDepth(u8),
}

#[derive(Debug, Clone)]
pub struct QuirkEntry {
    pub vendor_id: u16,
    pub product_id: u16,
    pub product_name_contains: &'static str,
    pub quirks: &'static [UsbAudioQuirk],
}

pub struct QuirkDatabase {
    entries: RwLock<Vec<QuirkEntry>>,
}

impl QuirkDatabase {
    pub fn new() -> Self {
        Self {
            entries: RwLock::new(Vec::new()),
        }
    }

    pub fn add(
        &self,
        vendor_id: u16,
        product_id: u16,
        product_name_contains: &'static str,
        quirks: &'static [UsbAudioQuirk],
    ) {
        self.entries.write().push(QuirkEntry {
            vendor_id,
            product_id,
            product_name_contains,
            quirks,
        });
    }

    /// Look up quirks for a device. A `vendor_id` or `product_id` of `0x0000`
    /// in an entry acts as a wildcard (matches any device), so entries can
    /// match by product name alone — useful for devices behind generic
    /// bridge chips (e.g. XMOS) that don't expose a unique VID/PID.
    pub fn lookup(
        &self,
        vendor_id: u16,
        product_id: u16,
        product_name: &str,
    ) -> Vec<UsbAudioQuirk> {
        let mut result = Vec::new();
        for entry in self.entries.read().iter() {
            if (entry.vendor_id == 0x0000 || entry.vendor_id == vendor_id)
                && (entry.product_id == 0x0000 || entry.product_id == product_id)
                && (entry.product_name_contains.is_empty()
                    || product_name.contains(entry.product_name_contains))
            {
                result.extend_from_slice(entry.quirks);
            }
        }
        result
    }

    pub fn has_quirk(
        &self,
        vendor_id: u16,
        product_id: u16,
        product_name: &str,
        quirk: UsbAudioQuirk,
    ) -> bool {
        self.lookup(vendor_id, product_id, product_name)
            .iter()
            .any(|q| *q == quirk)
    }

    pub fn find_quirk_by_type(
        &self,
        vendor_id: u16,
        product_id: u16,
        product_name: &str,
        quirk: UsbAudioQuirk,
    ) -> bool {
        self.has_quirk(vendor_id, product_id, product_name, quirk)
    }
}

/// Apply `ForceMaxSampleRateHz` / `ForceBitDepth` quirks to a requested
/// playback format, in place.
///
/// - `ForceMaxSampleRateHz(max)`: clamp a PCM request above `max` down to
///   `max` (some DACs advertise bogus maximum rates).
/// - `ForceBitDepth(bits)`: override the PCM bit depth (some DACs misreport
///   their supported depth).
///
/// DSD/DoP streams are never touched (`is_dsd == true`): their "sample
/// rate" lives in the DSD bit-rate domain, not PCM Hz. Every applied quirk
/// is logged so a misbehaving device can be traced back to its entry.
///
/// Kept free of Android-only types so it stays unit-testable on host.
pub fn apply_format_quirks(
    quirks: &[UsbAudioQuirk],
    product_name: &str,
    sample_rate: &mut u32,
    bit_depth: &mut u8,
    is_dsd: bool,
) {
    if is_dsd {
        return;
    }

    for quirk in quirks {
        match quirk {
            UsbAudioQuirk::ForceMaxSampleRateHz(max_hz) => {
                if *sample_rate > *max_hz {
                    log::info!(
                        "[USB] quirk ForceMaxSampleRateHz({}Hz) applied to '{}': capping {}Hz -> {}Hz",
                        max_hz,
                        product_name,
                        sample_rate,
                        max_hz,
                    );
                    *sample_rate = *max_hz;
                }
            }
            UsbAudioQuirk::ForceBitDepth(bits) => {
                if *bit_depth != *bits {
                    log::info!(
                        "[USB] quirk ForceBitDepth({}-bit) applied to '{}': overriding {}-bit -> {}-bit",
                        bits,
                        product_name,
                        bit_depth,
                        bits,
                    );
                    *bit_depth = *bits;
                }
            }
            _ => {}
        }
    }
}

pub static QUIRK_DATABASE: Lazy<QuirkDatabase> = Lazy::new(|| {
    let db = QuirkDatabase::new();

    // MOONDROP Dawn Pro: dual CS43131, XMOS-style bridge, DSD_U32_BE
    db.add(
        12230, // vendor_id 0x2FC6
        61546, // product_id 0xF09A
        "MOONDROP Dawn Pro",
        &[
            UsbAudioQuirk::RequireVerifiedRate,
            UsbAudioQuirk::SettleDelayMs(50),
            UsbAudioQuirk::PreferPadded24BitTransport,
            UsbAudioQuirk::DsdSubslotSize(4),
            UsbAudioQuirk::DsdBigEndian,
        ],
    );

    // Fosi Audio DS2: Savitech USB bridge with broken UAC2 clock control.
    // GET_RANGE returns zero subranges (I/O error), GET_CUR always returns 0Hz
    // even after a successful SET_CUR. The DAC operates correctly at the
    // requested rate — it just doesn't report it back via standard controls.
    // Trust SET_CUR and skip all clock validation/readback.
    db.add(
        9770, // vendor_id 0x262A (Savitech)
        1,    // product_id 0x0001
        "",   // match any product name with this VID/PID
        &[
            UsbAudioQuirk::SkipClockValidation,
            UsbAudioQuirk::IgnoreInvalidSampleRate,
        ],
    );

    // iFi micro/nano/xDSD family: XMOS-based bridge reports unreliable
    // maximum sample rates. Field-tested behavior (as observed in UAPP:
    // "Forcing highest sample rate to 384000Hz for iFi micro") is to cap
    // negotiation at 384kHz rather than trusting the descriptor.
    // Matched by product name with wildcard VID/PID because these devices
    // expose the generic XMOS VID/PID, not a unique iFi one.
    // Trade-off: 768kHz-capable iFi models are capped at 384kHz — the same
    // trade-off the reference implementation makes. Sources at or below
    // 384kHz are unaffected (the cap is a no-op for them).
    db.add(
        0x0000, // wildcard vendor_id: match by product name only
        0x0000, // wildcard product_id: match by product name only
        "iFi",
        &[UsbAudioQuirk::ForceMaxSampleRateHz(384_000)],
    );

    db
});

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn dawn_pro_quirks_found_by_vid_pid() {
        let quirks = QUIRK_DATABASE.lookup(12230, 61546, "MOONDROP Dawn Pro");
        assert!(quirks.contains(&UsbAudioQuirk::RequireVerifiedRate));
        assert!(quirks.contains(&UsbAudioQuirk::PreferPadded24BitTransport));
        assert!(quirks.contains(&UsbAudioQuirk::DsdBigEndian));
    }

    #[test]
    fn unknown_device_returns_empty() {
        let quirks = QUIRK_DATABASE.lookup(0x0000, 0x0000, "Unknown");
        assert!(quirks.is_empty());
    }

    #[test]
    fn fosi_ds2_quirks_registered() {
        let quirks = QUIRK_DATABASE.lookup(9770, 1, "Fosi Audio DS2");
        assert!(quirks.contains(&UsbAudioQuirk::SkipClockValidation));
        assert!(quirks.contains(&UsbAudioQuirk::IgnoreInvalidSampleRate));
    }

    #[test]
    fn has_quirk_check() {
        assert!(QUIRK_DATABASE.has_quirk(
            12230,
            61546,
            "MOONDROP Dawn Pro",
            UsbAudioQuirk::RequireVerifiedRate
        ));
        assert!(!QUIRK_DATABASE.has_quirk(
            12230,
            61546,
            "MOONDROP Dawn Pro",
            UsbAudioQuirk::Force48kHzOnly
        ));
    }

    #[test]
    fn ifi_rate_cap_matched_by_name_with_wildcard_ids() {
        // iFi devices sit behind a generic XMOS bridge: match by name alone.
        let quirks = QUIRK_DATABASE.lookup(0x20B1, 0x0008, "iFi micro iDSD");
        assert!(quirks.contains(&UsbAudioQuirk::ForceMaxSampleRateHz(384_000)));

        let quirks = QUIRK_DATABASE.lookup(0x1234, 0x5678, "iFi nano iDSD LE");
        assert!(quirks.contains(&UsbAudioQuirk::ForceMaxSampleRateHz(384_000)));
    }

    #[test]
    fn ifi_entry_does_not_match_unrelated_devices() {
        let quirks = QUIRK_DATABASE.lookup(0x20B1, 0x0008, "XMOS Generic DAC");
        assert!(!quirks.contains(&UsbAudioQuirk::ForceMaxSampleRateHz(384_000)));

        let quirks = QUIRK_DATABASE.lookup(0x0000, 0x0000, "Unknown");
        assert!(quirks.is_empty());
    }

    #[test]
    fn wildcard_entry_requires_name_match() {
        // Wildcard VID/PID alone is not enough — the product name must match.
        let quirks = QUIRK_DATABASE.lookup(0x9999, 0x9999, "Some Other DAC");
        assert!(!quirks.contains(&UsbAudioQuirk::ForceMaxSampleRateHz(384_000)));
    }

    #[test]
    fn rate_cap_clamps_above_max() {
        let mut rate = 768_000u32;
        let mut depth = 32u8;
        apply_format_quirks(
            &[UsbAudioQuirk::ForceMaxSampleRateHz(384_000)],
            "iFi micro iDSD",
            &mut rate,
            &mut depth,
            false,
        );
        assert_eq!(rate, 384_000);
        // Bit depth untouched by a rate quirk.
        assert_eq!(depth, 32);
    }

    #[test]
    fn rate_cap_is_noop_at_or_below_max() {
        let mut rate = 384_000u32;
        let mut depth = 24u8;
        apply_format_quirks(
            &[UsbAudioQuirk::ForceMaxSampleRateHz(384_000)],
            "iFi micro iDSD",
            &mut rate,
            &mut depth,
            false,
        );
        assert_eq!(rate, 384_000);

        rate = 96_000;
        apply_format_quirks(
            &[UsbAudioQuirk::ForceMaxSampleRateHz(384_000)],
            "iFi micro iDSD",
            &mut rate,
            &mut depth,
            false,
        );
        assert_eq!(rate, 96_000);
    }

    #[test]
    fn bit_depth_override_applies_to_pcm() {
        let mut rate = 96_000u32;
        let mut depth = 16u8;
        apply_format_quirks(
            &[UsbAudioQuirk::ForceBitDepth(24)],
            "Test DAC",
            &mut rate,
            &mut depth,
            false,
        );
        assert_eq!(depth, 24);
        assert_eq!(rate, 96_000);
    }

    #[test]
    fn dsd_streams_are_never_touched() {
        let quirks = [
            UsbAudioQuirk::ForceMaxSampleRateHz(48_000),
            UsbAudioQuirk::ForceBitDepth(16),
        ];
        // DoP stream.
        let mut rate = 176_400u32;
        let mut depth = 24u8;
        apply_format_quirks(&quirks, "Test DAC", &mut rate, &mut depth, true);
        assert_eq!(rate, 176_400);
        assert_eq!(depth, 24);

        // Native DSD stream (bit_depth == 1).
        let mut rate = 2_822_400u32;
        let mut depth = 1u8;
        apply_format_quirks(&quirks, "Test DAC", &mut rate, &mut depth, true);
        assert_eq!(rate, 2_822_400);
        assert_eq!(depth, 1);
    }

    #[test]
    fn no_quirks_leaves_format_unchanged() {
        let mut rate = 192_000u32;
        let mut depth = 24u8;
        apply_format_quirks(&[], "Plain DAC", &mut rate, &mut depth, false);
        assert_eq!(rate, 192_000);
        assert_eq!(depth, 24);
    }
}
