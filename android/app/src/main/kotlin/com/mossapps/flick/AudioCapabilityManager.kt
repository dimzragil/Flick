package com.mossapps.flick

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioDeviceInfo
import android.media.AudioFormat
import android.media.AudioManager
import android.media.MediaCodecList
import android.media.Spatializer
import android.media.audiofx.AudioEffect
import android.os.Build
import java.util.UUID

/**
 * Manages device audio spatialization and Dolby Atmos (E-AC-3 JOC) hardware capability detection.
 * Logic mirrors the reverse-engineered TIDAL Android capability detection (defpackage.oh4 / kh4)
 * and verifies licensed Dolby audio processing effects to prevent false positives.
 */
class AudioCapabilityManager(private val context: Context) {
    private val audioManager = context.getSystemService(Context.AUDIO_SERVICE) as? AudioManager

    // Known Dolby Mobile / Dolby Atmos effect UUIDs
    private val dolbyEffectUuids = setOf(
        UUID.fromString("46d279d9-9be7-453d-9d7c-ef937f675587"), // Dolby Audio / Atmos processing
        UUID.fromString("40f66c8b-5aa5-4e44-ab07-08117f3b0e7a"), // Dolby Surround / DAP
        UUID.fromString("9d492208-37d7-11e6-a977-0002a5d5c51b")  // Dolby Mobile effect
    )

    fun getAudioCapabilities(): Map<String, Any?> {
        val hasSpatializer = checkSpatializerSupport()
        val hasSpeakerEncoding = checkSpeakerEncodingSupport()
        val hasDecoder = checkMediaCodecSupport()
        val hasDolbyEffect = checkDolbyAudioEffectSupport()

        // Strict Policy:
        // A device supports Dolby Atmos ONLY if:
        // 1. Android Spatializer (API 32+) can spatialize E-AC-3 JOC 5.1, OR
        // 2. The device has a licensed Dolby Audio/Atmos processing engine (AudioEffect) AND EAC3 decoder, OR
        // 3. The built-in speaker specifically advertises ENCODING_E_AC3_JOC (18) AND has EAC3 decoder + Dolby effect.
        // A generic MediaCodec decoder or an HDMI/virtual encoding flag in HAL does NOT qualify.
        val isDolbyAtmosSupported = hasSpatializer || (hasDecoder && hasDolbyEffect) || (hasSpeakerEncoding && hasDecoder && hasDolbyEffect)

        return mapOf(
            "isDolbyAtmosSupported" to isDolbyAtmosSupported,
            "hasSpatializer" to hasSpatializer,
            "hasEac3JocDecoder" to hasDecoder,
            "hasDeviceEncoding" to hasSpeakerEncoding,
            "hasDolbyEffect" to hasDolbyEffect
        )
    }

    private fun checkSpatializerSupport(): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU && audioManager != null) {
            return try {
                val spatializer = audioManager.spatializer
                if (!spatializer.isAvailable || !spatializer.isEnabled) return false
                if (spatializer.immersiveAudioLevel == Spatializer.SPATIALIZER_IMMERSIVE_LEVEL_NONE) return false

                val attributes = AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                    .build()
                val format = AudioFormat.Builder()
                    .setEncoding(AudioFormat.ENCODING_E_AC3_JOC)
                    .setChannelMask(AudioFormat.CHANNEL_OUT_5POINT1)
                    .setSampleRate(48000)
                    .build()
                spatializer.canBeSpatialized(attributes, format)
            } catch (_: Throwable) {
                false
            }
        }
        return false
    }

    /**
     * Specifically checks if the built-in speaker device advertises ENCODING_E_AC3_JOC (18),
     * mirroring TIDAL's defpackage.kh4 which inspects audioDeviceInfo.getType() == 2 (TYPE_BUILTIN_SPEAKER).
     */
    private fun checkSpeakerEncodingSupport(): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P && audioManager != null) {
            return try {
                val devices = audioManager.getDevices(AudioManager.GET_DEVICES_OUTPUTS)
                devices.any { device ->
                    // AudioDeviceInfo.TYPE_BUILTIN_SPEAKER = 2
                    device.type == AudioDeviceInfo.TYPE_BUILTIN_SPEAKER && device.encodings.contains(18)
                }
            } catch (_: Throwable) {
                false
            }
        }
        return false
    }

    private fun checkMediaCodecSupport(): Boolean {
        return try {
            val codecList = MediaCodecList(MediaCodecList.REGULAR_CODECS)
            codecList.codecInfos.any { info ->
                !info.isEncoder && info.supportedTypes.any { type ->
                    type.equals("audio/eac3-joc", ignoreCase = true) ||
                    type.equals("audio/ac4", ignoreCase = true)
                }
            }
        } catch (_: Throwable) {
            false
        }
    }

    /**
     * Checks if the device has a licensed Dolby Audio or Dolby Atmos effect engine installed.
     * OEM devices with genuine Dolby Atmos (Samsung, Xiaomi, OnePlus, Motorola, Sony, etc.)
     * register Dolby audio effect descriptors in AudioEffect.queryEffects().
     */
    private fun checkDolbyAudioEffectSupport(): Boolean {
        return try {
            val descriptors = AudioEffect.queryEffects() ?: return false
            descriptors.any { desc ->
                dolbyEffectUuids.contains(desc.type) ||
                dolbyEffectUuids.contains(desc.uuid) ||
                desc.implementor?.contains("Dolby", ignoreCase = true) == true ||
                desc.name?.contains("Dolby", ignoreCase = true) == true ||
                desc.name?.contains("Atmos", ignoreCase = true) == true
            }
        } catch (_: Throwable) {
            false
        }
    }
}
