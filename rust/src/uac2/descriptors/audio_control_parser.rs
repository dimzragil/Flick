use super::constants::*;
use super::helpers::{read_u16_le, read_u32_le, require_len};
use super::parser_trait::DescriptorParser;
use super::types::*;
use super::validation::{
    validate_ac_interface_header, validate_feature_unit, validate_input_terminal,
    validate_output_terminal,
};
use crate::uac2::error::Uac2Error;
use flutter_rust_bridge::frb;

#[frb(opaque)]
pub struct AudioControlParser;

impl AudioControlParser {
    pub fn parse_ac_header(&self, data: &[u8]) -> Result<AcInterfaceHeader, Uac2Error> {
        const HEADER_LEN: usize = 9;
        require_len(data, HEADER_LEN)?;
        if data[1] != USB_DT_CS_INTERFACE || data[2] != UAC2_AC_HEADER {
            return Err(Uac2Error::InvalidDescriptor("not CS_AC header".to_string()));
        }
        let h = AcInterfaceHeader {
            bcd_adc: read_u16_le(data, 3),
            b_category: data[5],
            w_total_length: read_u16_le(data, 6),
            bm_controls: read_u16_le(data, 8),
        };
        validate_ac_interface_header(&h)?;
        Ok(h)
    }

    pub fn parse_ac_header_v1(&self, data: &[u8]) -> Result<AcInterfaceHeaderV1, Uac2Error> {
        require_len(data, 9)?;
        if data[1] != USB_DT_CS_INTERFACE || data[2] != UAC_AC_HEADER {
            return Err(Uac2Error::InvalidDescriptor(
                "not UAC1 AC header".to_string(),
            ));
        }
        let bcd_adc = read_u16_le(data, 3);
        let w_total_length = read_u16_le(data, 5);
        let b_in_collection = data[7];
        let len = data[0] as usize;
        let ba_interface_nr: Vec<u8> = data[8..len].to_vec();
        Ok(AcInterfaceHeaderV1 {
            bcd_adc,
            w_total_length,
            b_in_collection,
            ba_interface_nr,
        })
    }

    fn detect_and_parse_ac_header(&self, data: &[u8]) -> Result<AudioControlDescriptor, Uac2Error> {
        if data.len() >= 9 {
            // UAC 2.0 header has bCategory at byte 5; for UAC 1.0 the bCollectors field is different
            // UAC 1.0 layout: [0]=len [1]=DT_CS_IFACE [2]=HEADER [3-4]=bcdADC [5-6]=wTotalLength [7]=bInCollection [8+]=baInterfaceNr
            // UAC 2.0 layout: [0]=len [1]=DT_CS_IFACE [2]=HEADER [3-4]=bcdADC [5]=bCategory [6-7]=wTotalLength [8-9]=bmControls
            let _bcd_adc = read_u16_le(data, 3);
            let uac1_len = 8 + data.get(7).copied().unwrap_or(0) as usize;
            if data[0] as usize == uac1_len && data.len() >= uac1_len {
                return self
                    .parse_ac_header_v1(data)
                    .map(AudioControlDescriptor::HeaderV1);
            }
            self.parse_ac_header(data)
                .map(AudioControlDescriptor::HeaderV2)
        } else {
            self.parse_ac_header(data)
                .map(AudioControlDescriptor::HeaderV2)
        }
    }

    pub fn parse_input_terminal(&self, data: &[u8]) -> Result<InputTerminal, Uac2Error> {
        const LEN: usize = 15;
        require_len(data, LEN)?;
        if data[1] != USB_DT_CS_INTERFACE || data[2] != UAC2_INPUT_TERMINAL {
            return Err(Uac2Error::InvalidDescriptor(
                "not input terminal".to_string(),
            ));
        }
        let t = InputTerminal {
            b_terminal_id: data[3],
            w_terminal_type: read_u16_le(data, 4),
            b_assoc_terminal: data[6],
            b_c_source_id: data[7],
            b_nr_channels: read_u16_le(data, 8),
            w_channel_config: read_u32_le(data, 10),
            i_terminal: data[14],
        };
        validate_input_terminal(&t)?;
        Ok(t)
    }

    pub fn parse_output_terminal(&self, data: &[u8]) -> Result<OutputTerminal, Uac2Error> {
        const LEN: usize = 9;
        require_len(data, LEN)?;
        if data[1] != USB_DT_CS_INTERFACE || data[2] != UAC2_OUTPUT_TERMINAL {
            return Err(Uac2Error::InvalidDescriptor(
                "not output terminal".to_string(),
            ));
        }
        let t = OutputTerminal {
            b_terminal_id: data[3],
            w_terminal_type: read_u16_le(data, 4),
            b_assoc_terminal: data[6],
            b_source_id: data[7],
            i_terminal: data[8],
        };
        validate_output_terminal(&t)?;
        Ok(t)
    }

    pub fn parse_feature_unit(&self, data: &[u8]) -> Result<FeatureUnit, Uac2Error> {
        const MIN_LEN: usize = 6;
        require_len(data, MIN_LEN)?;
        if data[1] != USB_DT_CS_INTERFACE || data[2] != UAC2_FEATURE_UNIT {
            return Err(Uac2Error::InvalidDescriptor("not feature unit".to_string()));
        }
        let len = data[0] as usize;
        require_len(data, len)?;

        // Try UAC2 format first: Table 4-13
        // bLength = 6 + (ch + 1)*4 (with iFeature) or 5 + (ch + 1)*4 (without iFeature).
        // bmaControls(ch) are 4-byte LE bitmaps starting at offset 5.
        if let Ok(fu) = self.parse_feature_unit_uac2(data) {
            return Ok(fu);
        }

        // Try UAC1 format: Table 4-7
        if let Ok(fu) = self.parse_feature_unit_uac1(data) {
            return Ok(fu);
        }

        Err(Uac2Error::InvalidDescriptor(
            format!("invalid feature unit descriptor length: {}", len),
        ))
    }

    pub fn parse_feature_unit_uac2(&self, data: &[u8]) -> Result<FeatureUnit, Uac2Error> {
        const MIN_LEN: usize = 6;
        require_len(data, MIN_LEN)?;
        if data[1] != USB_DT_CS_INTERFACE || data[2] != UAC2_FEATURE_UNIT {
            return Err(Uac2Error::InvalidDescriptor("not feature unit".to_string()));
        }
        let len = data[0] as usize;
        require_len(data, len)?;

        // UAC2 Table 4-13:
        // bLength = 6 + (ch + 1)*4 (where ch >= 0, so len >= 10 and (len - 6) % 4 == 0)
        if len < 10 || (len - 6) % 4 != 0 {
            return Err(Uac2Error::InvalidDescriptor(format!(
                "invalid UAC2 feature unit descriptor length: {}",
                len
            )));
        }
        let n = (len - 6) / 4;

        let bma_controls: Vec<u32> = (0..n).map(|i| read_u32_le(data, 5 + i * 4)).collect();
        let f = FeatureUnit {
            b_unit_id: data[3],
            b_source_id: data[4],
            b_control_size: 4,
            bma_controls,
        };
        validate_feature_unit(&f)?;
        Ok(f)
    }

    pub fn parse_feature_unit_uac1(&self, data: &[u8]) -> Result<FeatureUnit, Uac2Error> {
        const MIN_LEN: usize = 7;
        require_len(data, MIN_LEN)?;
        if data[1] != USB_DT_CS_INTERFACE || data[2] != UAC2_FEATURE_UNIT {
            return Err(Uac2Error::InvalidDescriptor("not feature unit".to_string()));
        }
        let len = data[0] as usize;
        require_len(data, len)?;

        let b_control_size = data[5] as usize;
        if b_control_size < 1 || b_control_size > 3 || len < 7 + b_control_size || (len - 7) % b_control_size != 0 {
            return Err(Uac2Error::InvalidDescriptor(format!("invalid UAC1 bControlSize: {b_control_size}")));
        }

        let n = (len - 7) / b_control_size;
        let bma_controls: Vec<u32> = (0..n).map(|i| {
            let offset = 6 + i * b_control_size;
            let mut val = 0u32;
            for b in 0..b_control_size {
                val |= (data[offset + b] as u32) << (b * 8);
            }
            val
        }).collect();

        let f = FeatureUnit {
            b_unit_id: data[3],
            b_source_id: data[4],
            b_control_size: b_control_size as u8,
            bma_controls,
        };
        validate_feature_unit(&f)?;
        Ok(f)
    }

    pub fn parse_clock_source(&self, data: &[u8]) -> Result<ClockSource, Uac2Error> {
        const LEN: usize = 8;
        require_len(data, LEN)?;
        if data[1] != USB_DT_CS_INTERFACE || data[2] != UAC2_CLOCK_SOURCE {
            return Err(Uac2Error::InvalidDescriptor("not clock source".to_string()));
        }
        Ok(ClockSource {
            b_clock_id: data[3],
            bm_attributes: data[4],
            bm_controls: data[5],
            b_assoc_terminal: data[6],
            i_clock_source: data[7],
        })
    }

    pub fn parse_clock_selector(&self, data: &[u8]) -> Result<ClockSelector, Uac2Error> {
        const MIN_LEN: usize = 7;
        require_len(data, MIN_LEN)?;
        if data[1] != USB_DT_CS_INTERFACE || data[2] != UAC2_CLOCK_SELECTOR {
            return Err(Uac2Error::InvalidDescriptor(
                "not clock selector".to_string(),
            ));
        }
        let len = data[0] as usize;
        require_len(data, len)?;
        let b_nr_in_pins = data[5];
        let expected_len = 7 + b_nr_in_pins as usize;
        if len < expected_len {
            return Err(Uac2Error::InvalidDescriptor(
                "clock selector length mismatch".to_string(),
            ));
        }
        let ba_c_source_id: Vec<u8> = data[6..6 + b_nr_in_pins as usize].to_vec();
        let bm_controls_offset = 6 + b_nr_in_pins as usize;
        let bm_controls = data.get(bm_controls_offset).copied().unwrap_or(0);
        let i_clock_selector = data.get(bm_controls_offset + 1).copied().unwrap_or(0);
        Ok(ClockSelector {
            b_clock_id: data[3],
            b_nr_in_pins,
            ba_c_source_id,
            bm_controls,
            i_clock_selector,
        })
    }

    pub fn parse_clock_multiplier(&self, data: &[u8]) -> Result<ClockMultiplier, Uac2Error> {
        const LEN: usize = 7;
        require_len(data, LEN)?;
        if data[1] != USB_DT_CS_INTERFACE || data[2] != UAC2_CLOCK_MULTIPLIER {
            return Err(Uac2Error::InvalidDescriptor(
                "not clock multiplier".to_string(),
            ));
        }
        Ok(ClockMultiplier {
            b_clock_id: data[3],
            b_c_source_id: data[4],
            bm_controls: data[5],
            i_clock_multiplier: data[6],
        })
    }

    pub fn parse_mixer_unit(&self, data: &[u8]) -> Result<MixerUnit, Uac2Error> {
        const MIN_LEN: usize = 10;
        require_len(data, MIN_LEN)?;
        if data[1] != USB_DT_CS_INTERFACE || data[2] != UAC_MIXER_UNIT {
            return Err(Uac2Error::InvalidDescriptor("not mixer unit".to_string()));
        }
        let len = data[0] as usize;
        require_len(data, len)?;
        let b_nr_in_pins = data[5];
        // For UAC1: fixed length; we'll be lenient
        let ba_source_id: Vec<u8> = data[6..6 + b_nr_in_pins as usize].to_vec();
        let channels_offset = 6 + b_nr_in_pins as usize;
        let b_nr_channels = if channels_offset + 1 < len {
            read_u16_le(data, channels_offset)
        } else {
            2
        };
        let w_channel_config = if channels_offset + 3 < len {
            read_u32_le(data, channels_offset + 2)
        } else {
            0
        };
        let i_mixer_offset = channels_offset + 6;
        let i_mixer = data.get(i_mixer_offset).copied().unwrap_or(0);
        let bm_controls: Vec<u8> = data[i_mixer_offset + 1..len].to_vec();
        Ok(MixerUnit {
            b_unit_id: data[3],
            b_nr_in_pins,
            ba_source_id,
            b_nr_channels,
            w_channel_config,
            i_mixer,
            bm_controls,
        })
    }

    pub fn parse_selector_unit(&self, data: &[u8]) -> Result<SelectorUnit, Uac2Error> {
        const MIN_LEN: usize = 6;
        require_len(data, MIN_LEN)?;
        if data[1] != USB_DT_CS_INTERFACE || data[2] != UAC_SELECTOR_UNIT {
            return Err(Uac2Error::InvalidDescriptor(
                "not selector unit".to_string(),
            ));
        }
        let len = data[0] as usize;
        require_len(data, len)?;
        let b_nr_in_pins = data[5];
        let ba_source_id: Vec<u8> = data[6..6 + b_nr_in_pins as usize].to_vec();
        let i_sel_offset = 6 + b_nr_in_pins as usize;
        let i_selector = data.get(i_sel_offset).copied().unwrap_or(0);
        let bm_controls = data.get(i_sel_offset + 1).copied();
        Ok(SelectorUnit {
            b_unit_id: data[3],
            b_nr_in_pins,
            ba_source_id,
            i_selector,
            bm_controls,
        })
    }

    pub fn parse_effect_unit(&self, data: &[u8]) -> Result<EffectUnit, Uac2Error> {
        const LEN: usize = 8;
        require_len(data, LEN)?;
        if data[1] != USB_DT_CS_INTERFACE || data[2] != UAC_EFFECT_UNIT {
            return Err(Uac2Error::InvalidDescriptor("not effect unit".to_string()));
        }
        Ok(EffectUnit {
            b_unit_id: data[3],
            b_source_id: data[4],
            b_effect_id: read_u16_le(data, 5),
            i_effect: data[7],
        })
    }

    pub fn parse_processing_unit(&self, data: &[u8]) -> Result<ProcessingUnit, Uac2Error> {
        const MIN_LEN: usize = 10;
        require_len(data, MIN_LEN)?;
        if data[1] != USB_DT_CS_INTERFACE || data[2] != UAC_PROCESSING_UNIT {
            return Err(Uac2Error::InvalidDescriptor(
                "not processing unit".to_string(),
            ));
        }
        let len = data[0] as usize;
        require_len(data, len)?;
        let b_nr_channels = read_u16_le(data, 7);
        let w_channel_config = read_u32_le(data, 9);
        let i_processing = data.get(13).copied().unwrap_or(0);
        let bm_controls = data[14..len].to_vec();
        Ok(ProcessingUnit {
            b_unit_id: data[3],
            b_source_id: data[4],
            w_process_type: read_u16_le(data, 5),
            b_nr_channels,
            w_channel_config,
            i_processing,
            bm_controls,
        })
    }

    pub fn parse_extension_unit(&self, data: &[u8]) -> Result<ExtensionUnit, Uac2Error> {
        const MIN_LEN: usize = 13;
        require_len(data, MIN_LEN)?;
        if data[1] != USB_DT_CS_INTERFACE || data[2] != UAC_EXTENSION_UNIT {
            return Err(Uac2Error::InvalidDescriptor(
                "not extension unit".to_string(),
            ));
        }
        let len = data[0] as usize;
        require_len(data, len)?;
        let b_nr_in_pins = data[7];
        let ba_source_id: Vec<u8> = data[8..8 + b_nr_in_pins as usize].to_vec();
        let ch_offset = 8 + b_nr_in_pins as usize;
        let b_nr_channels = read_u16_le(data, ch_offset);
        let w_channel_config = read_u32_le(data, ch_offset + 2);
        let i_extension = data.get(ch_offset + 6).copied().unwrap_or(0);
        let bm_controls = data[ch_offset + 7..len].to_vec();
        Ok(ExtensionUnit {
            b_unit_id: data[3],
            w_extension_code: read_u16_le(data, 5),
            b_nr_in_pins,
            ba_source_id,
            b_nr_channels,
            w_channel_config,
            i_extension,
            bm_controls,
        })
    }
}

impl DescriptorParser for AudioControlParser {
    type Output = AudioControlDescriptor;

    fn parse(&self, data: &[u8]) -> Result<Self::Output, Uac2Error> {
        if data.len() < 3 {
            return Err(Uac2Error::InvalidDescriptor(
                "descriptor too short".to_string(),
            ));
        }
        if data[1] != USB_DT_CS_INTERFACE {
            return Err(Uac2Error::InvalidDescriptor("not CS interface".to_string()));
        }
        match data[2] {
            UAC_AC_HEADER => self.detect_and_parse_ac_header(data),
            UAC_INPUT_TERMINAL => self
                .parse_input_terminal(data)
                .map(AudioControlDescriptor::InputTerminal),
            UAC_OUTPUT_TERMINAL => self
                .parse_output_terminal(data)
                .map(AudioControlDescriptor::OutputTerminal),
            UAC_FEATURE_UNIT => self
                .parse_feature_unit(data)
                .map(AudioControlDescriptor::FeatureUnit),
            UAC2_CLOCK_SOURCE => self
                .parse_clock_source(data)
                .map(AudioControlDescriptor::ClockSource),
            UAC2_CLOCK_SELECTOR => self
                .parse_clock_selector(data)
                .map(AudioControlDescriptor::ClockSelector),
            UAC2_CLOCK_MULTIPLIER => self
                .parse_clock_multiplier(data)
                .map(AudioControlDescriptor::ClockMultiplier),
            UAC_MIXER_UNIT => self
                .parse_mixer_unit(data)
                .map(AudioControlDescriptor::MixerUnit),
            UAC_SELECTOR_UNIT => self
                .parse_selector_unit(data)
                .map(AudioControlDescriptor::SelectorUnit),
            UAC_EFFECT_UNIT => self
                .parse_effect_unit(data)
                .map(AudioControlDescriptor::EffectUnit),
            UAC_PROCESSING_UNIT => self
                .parse_processing_unit(data)
                .map(AudioControlDescriptor::ProcessingUnit),
            UAC_EXTENSION_UNIT => self
                .parse_extension_unit(data)
                .map(AudioControlDescriptor::ExtensionUnit),
            _ => Err(Uac2Error::InvalidDescriptor(format!(
                "unknown AC descriptor subtype {}",
                data[2]
            ))),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::uac2::constants::{FEATURE_MUTE, FEATURE_VOLUME};

    #[test]
    fn test_parse_feature_unit_uac2_stereo() {
        let parser = AudioControlParser;
        // 18-byte UAC2 Stereo Feature Unit descriptor (JadeAudio JA11 layout):
        // [0]: bLength = 18
        // [1]: bDescriptorType = CS_INTERFACE (0x24)
        // [2]: bDescriptorSubtype = FEATURE_UNIT (0x06)
        // [3]: bUnitID = 0x05
        // [4]: bSourceID = 0x02
        // [5..8]: bmaControls(0) = 0x0000000F (master mute + volume)
        // [9..12]: bmaControls(1) = 0x0000000F (ch1 mute + volume)
        // [13..16]: bmaControls(2) = 0x0000000F (ch2 mute + volume)
        // [17]: iFeature = 0x00
        let data = [
            18, 0x24, 0x06, 0x05, 0x02,
            0x0F, 0x00, 0x00, 0x00,
            0x0F, 0x00, 0x00, 0x00,
            0x0F, 0x00, 0x00, 0x00,
            0x00,
        ];

        let fu = parser.parse_feature_unit(&data).expect("Failed to parse UAC2 stereo FU");
        assert_eq!(fu.b_unit_id, 0x05);
        assert_eq!(fu.b_source_id, 0x02);
        assert_eq!(fu.b_control_size, 4);
        assert_eq!(fu.bma_controls.len(), 3);
        assert_eq!(fu.bma_controls[0], 0x0F);
        assert!(fu.bma_controls[0] & FEATURE_VOLUME != 0);
        assert!(fu.bma_controls[0] & FEATURE_MUTE != 0);
    }

    #[test]
    fn test_parse_feature_unit_uac1() {
        let parser = AudioControlParser;
        // 9-byte UAC1 Feature Unit descriptor (master + ch1, bControlSize = 1):
        // [0]: bLength = 9
        // [1]: bDescriptorType = 0x24
        // [2]: bDescriptorSubtype = 0x06
        // [3]: bUnitID = 0x02
        // [4]: bSourceID = 0x01
        // [5]: bControlSize = 1
        // [6]: bmaControls(0) = 0x03 (mute + volume in UAC1)
        // [7]: bmaControls(1) = 0x00
        // [8]: iFeature = 0x00
        let data = [
            9, 0x24, 0x06, 0x02, 0x01,
            1, 0x03, 0x00, 0x00,
        ];

        let fu = parser.parse_feature_unit(&data).expect("Failed to parse UAC1 FU");
        assert_eq!(fu.b_unit_id, 0x02);
        assert_eq!(fu.b_source_id, 0x01);
        assert_eq!(fu.b_control_size, 1);
        assert_eq!(fu.bma_controls.len(), 2);
        assert_eq!(fu.bma_controls[0], 0x03);
        assert!(fu.bma_controls[0] & FEATURE_VOLUME != 0);
        assert!(fu.bma_controls[0] & FEATURE_MUTE != 0);
    }
}
